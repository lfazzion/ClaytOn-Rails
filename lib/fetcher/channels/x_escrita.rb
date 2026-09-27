# frozen_string_literal: true

require "json"
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
      # 226 parece automatizado · 326 conta travada · 64 suspensa · 185/344 limite diário do X.
      CODIGOS_RESTRICAO = [226, 326, 64, 185, 344].freeze
      # Códigos que recusam ESTE texto/alvo: 186 longo · 187 duplicado · 385/433 reply não permitido.
      CODIGOS_RECUSA = [186, 187, 385, 433].freeze

      class Error < ::Fetcher::Channels::Error; end
      class Recusado < Error; end
      class RateLimited < Error; end
      class RateLimitedRemote < Error; end
      class AuthError < Error; end
      class Restrito < Error; end
      class ResponseError < Error; end

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
        id = dados.dig("data", "create_tweet", "tweet_results", "result", "rest_id")
        raise ResponseError, "CreateTweet sem rest_id na resposta" if id.nil?

        { "id" => id.to_s, "url" => "https://x.com/i/status/#{id}" }
      end

      def curtir(id:)
        graphql!("FavoriteTweet", { "tweet_id" => id.to_s })
        { "id" => id.to_s }
      end

      def repostar(id:)
        graphql!("CreateRetweet", { "tweet_id" => id.to_s, "dark_request" => false })
        { "id" => id.to_s }
      end

      def apagar(id:)
        graphql!("DeleteTweet", { "tweet_id" => id.to_s, "dark_request" => false })
        { "id" => id.to_s }
      end

      def seguir(usuario_id:)
        gate!
        headers = XGraphql.build_headers({}, {}, query_id: nil, operation: "friendships/create",
                                                 method: "POST", path: FOLLOW_PATH)
        resposta = SafeHttpClient.post("https://#{COOKIE_DOMAIN}#{FOLLOW_PATH}",
                                       form: { "user_id" => usuario_id.to_s }, headers: headers)
        interpreta!(resposta, "friendships/create")
        { "usuario_id" => usuario_id.to_s }
      end

      def graphql!(operacao, variaveis, features: nil)
        gate!
        query_id = XQueryIdResolver.new.resolve(operacao)
        raise ResponseError, "queryId de #{operacao} não encontrado nos bundles do X" if query_id.nil?

        headers = XGraphql.build_headers(variaveis, features || {}, query_id: query_id,
                                                                    operation: operacao, method: "POST")
        corpo = { "variables" => variaveis, "queryId" => query_id }
        corpo["features"] = features if features
        resposta = SafeHttpClient.post("https://#{COOKIE_DOMAIN}/i/api/graphql/#{query_id}/#{operacao}",
                                       json: corpo, headers: headers)
        interpreta!(resposta, operacao)
      rescue SafeHttpClient::Error, SsrfGuard::Blocked => e
        raise ResponseError, "falha de rede em #{operacao} (#{e.class.name}): #{e.message}"
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
