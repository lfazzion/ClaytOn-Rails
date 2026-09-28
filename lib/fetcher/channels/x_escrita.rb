# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require_relative "registry"
require_relative "../cookie_jar"
require_relative "../host_rate_limiter"
require_relative "../safe_http_client"
require_relative "../ssrf_guard"
require_relative "x_graphql"
require_relative "x_conversation"

module Fetcher
  module Channels
    # Escrita no X pela sessão do jar (conta descartável): postar, responder, curtir, repostar, seguir
    # e apagar. Quem chama de fora é o porteiro do experimento-x (`bin/rails x:*`), que aplica os
    # limites de negócio; aqui só entram a trava local da casa e a tipagem dos erros do X.
    module XEscrita
      COOKIE_DOMAIN = "x.com"
      BUDGET = { scope: "graphql_escrita", max: 4, per_hour: 60 }.freeze
      MAX_CHARS = 280 # conta sem Premium; URL conta 23 no X, então o X ainda pode recusar (186)
      FOLLOW_PATH = "/i/api/1.1/friendships/create.json"
      MIN_SEGREDO = 8 # valores de cookie mais curtos que isso dariam falso positivo

      # Códigos do X que indicam que a conta está sob restrição (não é culpa do texto):
      # 226 parece automatizado · 326 conta travada · 64 suspensa · 185/344 limite diário do X ·
      # 161 limite de follows da conta.
      CODIGOS_RESTRICAO = [226, 326, 64, 185, 344, 161].freeze
      # Códigos que recusam ESTE texto/alvo: 186 longo · 187 duplicado · 385/433 reply não permitido ·
      # 162 bloqueado de seguir · 108 usuário não existe · 160 pedido de follow já feito ·
      # 139 já curtido · 327 já repostado · 144 post não existe.
      CODIGOS_RECUSA = [186, 187, 385, 433, 162, 108, 160, 139, 327, 144].freeze
      # HTTP que, no GraphQL, quer dizer queryId velho: o X não executou nada, então dá para
      # redescobrir o queryId e repetir UMA vez. Nunca 403/429 (sessão ou limite: repetir piora).
      STATUS_QUERY_ID_VELHO = [404, 422].freeze
      # Falhas de rede DEPOIS de o pedido sair: a ação pode ter sido feita no X (Incerto).
      # OpenTimeout é subclasse de Timeout::Error, mas é antes do envio: fica de fora (checado antes).
      FALHAS_POS_ENVIO = [Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, Errno::ECONNRESET,
                          Errno::EPIPE, EOFError].freeze

      class Error < ::Fetcher::Channels::Error; end
      class Recusado < Error; end
      class RateLimited < Error; end
      class RateLimitedRemote < Error; end
      class AuthError < Error; end
      class Restrito < Error; end
      class ResponseError < Error; end
      # O pedido pode ter chegado ao X e a resposta se perdeu: NÃO repetir às cegas (post duplicado).
      class Incerto < Error; end

      module_function

      def postar(texto:, em_resposta_a: nil)
        texto = texto.to_s.strip
        raise Recusado, "texto vazio" if texto.empty?
        raise Recusado, "texto com #{texto.length} caracteres (máx. #{MAX_CHARS})" if texto.length > MAX_CHARS

        recusa_vazamento!(texto)
        variaveis = {
          "tweet_text" => texto, "dark_request" => false,
          "media" => { "media_entities" => [], "possibly_sensitive" => false },
          "semantic_annotation_ids" => []
        }
        if em_resposta_a
          variaveis["reply"] = { "in_reply_to_tweet_id" => em_resposta_a.to_s, "exclude_reply_user_ids" => [] }
        end
        dados = graphql!("CreateTweet", variaveis, features: XConversation::FEATURES)
        resultados = dados.dig("data", "create_tweet", "tweet_results")
        # `tweet_results: {}` com HTTP 200: o X engoliu o post sem erro (supressão da conta).
        raise Restrito, "CreateTweet: X devolveu tweet_results vazio (post suprimido)" if resultados == {}

        id = resultados.is_a?(Hash) ? resultados.dig("result", "rest_id") : nil
        raise ResponseError, "CreateTweet sem rest_id na resposta" if id.nil?

        { "id" => id.to_s, "url" => "https://x.com/i/status/#{id}" }
      end

      # Forma medida em 2026-09-27: `{"data":{"favorite_tweet":"Done"}}`.
      def curtir(id:)
        dados = graphql!("FavoriteTweet", { "tweet_id" => id.to_s })
        confirmacao = dados.dig("data", "favorite_tweet")
        raise ResponseError, "FavoriteTweet sem confirmação (favorite_tweet=#{confirmacao.inspect})" unless confirmacao == "Done"

        { "id" => id.to_s }
      end

      # Forma medida em 2026-09-27: `data.create_retweet.retweet_results.result.rest_id` (id do repost).
      def repostar(id:)
        dados = graphql!("CreateRetweet", { "tweet_id" => id.to_s, "dark_request" => false })
        resultados = dados.dig("data", "create_retweet", "retweet_results")
        raise Restrito, "CreateRetweet: X devolveu retweet_results vazio (repost suprimido)" if resultados == {}

        repost_id = resultados.is_a?(Hash) ? resultados.dig("result", "rest_id") : nil
        raise ResponseError, "CreateRetweet sem rest_id do repost na resposta" if repost_id.nil?

        { "id" => id.to_s }
      end

      # Forma medida em 2026-09-27: `{"data":{"delete_tweet":{"tweet_results":{}}}}` — o `{}` é o normal aqui.
      def apagar(id:)
        dados = graphql!("DeleteTweet", { "tweet_id" => id.to_s, "dark_request" => false })
        raise ResponseError, "DeleteTweet sem delete_tweet na resposta" unless dados.dig("data", "delete_tweet").is_a?(Hash)

        { "id" => id.to_s }
      end

      # Forma medida em 2026-09-27: o REST devolve o usuário seguido (com `following` ainda false).
      def seguir(usuario_id:)
        gate!
        headers = XGraphql.build_headers({}, {}, query_id: nil, operation: "friendships/create",
                                                 method: "POST", path: FOLLOW_PATH)
        resposta = SafeHttpClient.post("https://#{COOKIE_DOMAIN}#{FOLLOW_PATH}",
                                       form: { "user_id" => usuario_id.to_s }, headers: headers)
        dados = interpreta!(resposta, "friendships/create")
        unless dados["id_str"].to_s == usuario_id.to_s
          raise ResponseError, "friendships/create: resposta não traz o usuário #{usuario_id}"
        end

        { "usuario_id" => usuario_id.to_s }
      rescue SafeHttpClient::Error, SsrfGuard::Blocked => e
        falha_de_rede!(e, "friendships/create")
      end

      def graphql!(operacao, variaveis, features: nil)
        gate!
        resposta = com_query_id(operacao) do |query_id|
          headers = XGraphql.build_headers(variaveis, features || {}, query_id: query_id,
                                                                      operation: operacao, method: "POST")
          corpo = { "variables" => variaveis, "queryId" => query_id }
          corpo["features"] = features if features
          SafeHttpClient.post("https://#{COOKIE_DOMAIN}/i/api/graphql/#{query_id}/#{operacao}",
                              json: corpo, headers: headers)
        end
        interpreta!(resposta, operacao)
      rescue SafeHttpClient::Error, SsrfGuard::Blocked => e
        falha_de_rede!(e, operacao)
      end

      # Resolve o queryId e faz o pedido (bloco). Em 404/422 o queryId está velho e o X não executou
      # nada: força a redescoberta UMA vez e, se o id mudou, repete UMA vez. Devolve a última resposta.
      def com_query_id(operacao)
        resolver = XQueryIdResolver.new
        query_id = resolver.resolve(operacao)
        raise ResponseError, "queryId de #{operacao} não encontrado nos bundles do X" if query_id.nil?

        resposta = yield query_id
        return resposta unless STATUS_QUERY_ID_VELHO.include?(resposta.status.to_i)

        novo = resolver.resolve(operacao, force: true)
        return resposta if novo.nil? || novo == query_id

        yield novo
      end

      # Antes do envio (DNS, SSRF, connect) a ação não aconteceu: ResponseError. Depois do envio
      # (timeout de leitura, conexão resetada, corpo grande demais) ela pode ter acontecido: Incerto.
      def falha_de_rede!(erro, operacao)
        detalhe = "#{operacao} (#{erro.class.name}#{erro.cause ? " <- #{erro.cause.class.name}" : ''}): #{erro.message}"
        raise Incerto, "resultado incerto em #{detalhe}" if pos_envio?(erro)

        raise ResponseError, "falha de rede em #{detalhe}"
      end

      def pos_envio?(erro)
        return true if erro.is_a?(SafeHttpClient::BodyTooLarge)

        causa = erro.cause
        return false if causa.nil? || causa.is_a?(Net::OpenTimeout)

        FALHAS_POS_ENVIO.any? { |classe| causa.is_a?(classe) }
      end

      def gate!
        CookieJar.require!(COOKIE_DOMAIN)
        raise RateLimited, "trava local: #{BUDGET[:max]}/min ou #{BUDGET[:per_hour]}/hora de escrita" if
          HostRateLimiter.exceeded?(COOKIE_DOMAIN, **BUDGET)
      end

      # O X manda erro de negócio em `errors[]` até com HTTP 200: os códigos vêm antes do status.
      def interpreta!(resposta, operacao)
        dados = begin
          JSON.parse(resposta.body.to_s)
        rescue JSON::ParserError
          nil
        end
        erros = dados.is_a?(Hash) ? Array(dados["errors"]) : []
        codigos = erros.map { |e| e["code"] || e.dig("extensions", "code") }.compact.map(&:to_i)
        mensagem = erros.map { |e| e["message"] }.compact.join(" | ")
        if (codigos & CODIGOS_RESTRICAO).any?
          raise Restrito, "#{operacao}: X sinalizou restrição (#{codigos.join(',')}): #{mensagem}"
        end
        raise Recusado, "#{operacao}: X recusou (#{codigos.join(',')}): #{mensagem}" if (codigos & CODIGOS_RECUSA).any?

        case resposta.status.to_i
        when 429 then raise RateLimitedRemote, "#{operacao}: 429 do X"
        when 401, 403 then raise AuthError, "#{operacao}: HTTP #{resposta.status} (sessão/txid/csrf)"
        when 200..299
          raise ResponseError, "#{operacao}: erro do X: #{mensagem}" if erros.any? && dados["data"].to_h.empty?
          raise ResponseError, "#{operacao}: corpo não é JSON" unless dados.is_a?(Hash)

          dados
        else raise ResponseError, "#{operacao}: HTTP #{resposta.status}"
        end
      end

      def recusa_vazamento!(texto)
        segredos = CookieJar.for(COOKIE_DOMAIN).map { |c| c["value"].to_s }.select { |v| v.length >= MIN_SEGREDO }
        raise Recusado, "texto contém valor da sessão do X" if segredos.any? { |v| texto.include?(v) }
      end
    end
  end
end
