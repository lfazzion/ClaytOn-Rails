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
      # 25.000 desde 28/09/2026: a conta @daemon403 virou X Premium, e com Premium o X aceita posts
      # e respostas de até 25.000 caracteres (fonte: help.x.com/en/using-x/types-of-posts,
      # "Longer posts … up to 25,000 characters"). Antes disso eram 280 (conta sem Premium).
      # Isto é o teto da CASA; se o texto estourar, o X ainda pode recusar com 186.
      MAX_CHARS = 25_000
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

      # ── A BARREIRA DE RETOMADA DA ESCRITA ─────────────────────────────────────
      #
      # Regra da casa, e ela é sobre o QUE A CASA SABE, não sobre o que o X quis dizer:
      #
      #   **escrita 2xx sem id utilizável = POSSIVELMENTE FEITO. Confira antes de repetir.**
      #
      # A 2xx chega depois do envio: o X recebeu o pedido e respondeu. Se o corpo não traz o id
      # utilizável (não é JSON, ou o JSON não tem `rest_id`/`tweet_results`), a casa não tem como
      # dizer que a ação NÃO saiu — e reportar isso como "falhou" é afirmar o que não se sabe.
      # Repetir às cegas aqui é DESTRUTIVO no X: o `postar` cria OUTRO post, o `editar` cria
      # OUTRA VERSÃO do mesmo post (cada edição gasta uma das `.allowed` da janela do Premium), e
      # o `curtir`/`repostar` repetem o efeito. Por isso os dois lados ficam `Incerto` — a mesma
      # classe da falha de rede depois do envio (`falha_de_rede!`), que é a mesma dúvida com o
      # corpo a menos — e não um tipo novo: o porteiro do experimento-x JÁ conta `erro:Incerto`
      # como "pode ter chegado ao X".
      #
      # O que NÃO entra aqui: código de RECUSA/RESTRIÇÃO do X (186, 187, 226...), 401/403, 429 e
      # falha local antes do envio. Nesses o X disse que não fez, e mandar conferir seria treinar
      # o operador a ignorar o aviso.
      AVISO_PODE_TER_SAIDO = "pode TER saido no X; confira o post ANTES de repetir"
      # O custo de repetir às cegas, por ação. `postar` e `editar` é que duplicam de verdade: o
      # postar cria OUTRO post e o editar outra VERSÃO do mesmo post.
      CUSTO_REPETIR_POSTAR = "repetir as cegas cria OUTRO post"
      CUSTO_REPETIR_EDITAR = "repetir as cegas cria OUTRA versao do post (nova edicao na janela)"

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

      # ── O QUE É "ID UTILIZÁVEL" (a definição fechada, e ela mora AQUI, não em cada fluxo) ──
      #
      # Um id do X só serve se dá para ABRIR o post com ele. Quatro formas são recusadas, e as
      # quatro já caíram nesta casa em formas diferentes (a r1 achou `tweet_results` vazio, a r2
      # achou `rest_id: ""`), então a lista é fechada e nomeada aqui:
      #
      #   1. AUSENTE  — o `result` não tem `rest_id`, ou o `tweet_results` inteiro não veio;
      #   2. VAZIO    — `""`; em Ruby `""` é truthy, então a condição antiga (`id.nil?`) aceitava
      #      isto como SUCESSO e montava `https://x.com/i/status/` (uma url que parece post);
      #   3. SÓ ESPAÇOS — `"   "`, que passa por `to_s` e vira url idem;
      #   4. ZERO     — o inteiro `0` (truthy, e monta `/i/status/0`, que também parece url).
      #      A string `"0"` cai na mesma regra: id do X é a sequência de dígitos do snowflake,
      #      então zero não é post de ninguém. Isto é um SUPERSET do pedido da r2 (que pedia o
      #      inteiro `0`), e a casa não rejeita id real nenhum com ele.
      #
      # Tudo que não for utilizável é `Incerto` — NUNCA sucesso — porque a 2xx já prova que o
      # pedido chegou ao X (a regra de cima). Recusar aqui não é dizer "falhou": é dizer "não
      # tenho como dizer, confira antes de repetir".
      def id_utilizavel?(id)
        return false if id.nil?
        return false if id.is_a?(Integer) && id.zero?

        texto = id.to_s.strip
        return false if texto.empty?

        # `to_i` de um id do X é o próprio id (só dígitos), então isto é "não é zero". A string
        # `"0"` e o inteiro `0` caem aqui; nenhum id real cai.
        !texto.to_i.zero?
      end

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
        # `tweet_results: {}` com HTTP 200: o X engoliu o post sem erro. Isto NAO e "falhou": a
        # 2xx prova que o pedido chegou, e sem o `tweet_results` a casa não sabe se o post saiu —
        # então sai como Incerto, com o aviso de conferir. Repetir às cegas aqui criava OUTRO
        # post do mesmo texto no X.
        #
        # A condição é `id_utilizavel?` e NÃO `id.nil?`: em Ruby `""`, `"   "` e `0` são truthy,
        # e qualquer um dos três montava uma url de aparência válida (`/i/status/`, `/i/status/0`)
        # e saía como SUCESSO. A definição fechada está em `id_utilizavel?`.
        id = resultados.is_a?(Hash) ? resultados.dig("result", "rest_id") : nil
        raise Incerto, "CreateTweet: #{CUSTO_REPETIR_POSTAR} (rest_id=#{id.inspect}); #{AVISO_PODE_TER_SAIDO}" unless
          id_utilizavel?(id)

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
        # Mesma barreira do `postar`: `retweet_results: {}` (ou sem `rest_id`) com 2xx é o X
        # engolindo a chamada, não o X dizendo que não repostou. Repetir aqui refaz o repost.
        # E a MESMA definição de id utilizável do `postar` (`id_utilizavel?`): o `rest_id: ""`
        # que o X devolveu era aceito como sucesso e o `repostar` devolvia o id do ARGUMENTO
        # como se o repost tivesse saído.
        repost_id = resultados.is_a?(Hash) ? resultados.dig("result", "rest_id") : nil
        raise Incerto, "CreateRetweet: repetir as cegas refaz o repost (rest_id=#{repost_id.inspect}); " \
                       "#{AVISO_PODE_TER_SAIDO}" unless id_utilizavel?(repost_id)

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
        dados = interpreta!(resposta, "friendships/create", escrita: true)
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
        # `escrita: true`: este `graphql!` é o caminho das MUTAÇÕES (CreateTweet, CreateRetweet,
        # DeleteTweet, FavoriteTweet). Um 2xx sem JSON aqui é o mesmo `Incerto` da falha de rede
        # depois do envio, não um "corpo não é JSON" calado.
        interpreta!(resposta, operacao, escrita: true)
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
      #
      # `escrita:` é o que separa "não sei se saiu" de "falhou". Numa LEITURA um 2xx sem JSON é
      # só um `ResponseError`: nada foi criado no X, não há o que conferir, e avisar ali seria
      # treinar o operador a ignorar o aviso. Numa ESCRITA a 2xx veio DEPOIS do envio — o X
      # recebeu o pedido e respondeu sem o id utilizável, e a casa não pode afirmar que a ação
      # não saiu (ver a regra em `AVISO_PODE_TER_SAIDO`).
      def interpreta!(resposta, operacao, escrita: false)
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
          unless dados.is_a?(Hash)
            # 2xx sem corpo utilizável numa ESCRITA: chegou ao X e a resposta não diz o que ele
            # fez. Não é "falhou" — e o `Incerto` diz isso na cara de quem decide repetir.
            #
            # O custo aqui é o do POSTAR porque a camada compartilhada não sabe que operação é.
            # A edição é a única que repete para OUTRA VERSÃO do mesmo post, e ela corrige a
            # frase no `XEditar#graphql_da_edicao!` (que envolve este `Incerto` e acrescenta o
            # custo dela) — assim o aviso não mente para nenhum dos dois caminhos.
            raise Incerto, "#{operacao}: resposta 2xx sem JSON utilizavel; #{CUSTO_REPETIR_POSTAR}; " \
                           "#{AVISO_PODE_TER_SAIDO}" if escrita

            raise ResponseError, "#{operacao}: corpo não é JSON"
          end

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
