# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require_relative "registry"
require_relative "youtube"
require_relative "x_escrita"
require_relative "../cookie_jar"
require_relative "../session_cookies"
require_relative "../host_rate_limiter"
require_relative "../safe_http_client"
require_relative "../ssrf_guard"

module Fetcher
  module Channels
    # Escrita no YouTube pela sessão do jar: por ora só CURTIR (o agente do experimento-x treina o feed
    # de recomendações curtindo o que presta). Comentar/postar/descurtir não existem aqui de propósito.
    #
    # A conta é a MESMA da transcrição do ClaytOn (descartável, do dono): banir aqui derruba lá. Por isso a
    # trava local é apertada; os limites de negócio moram no porteiro do experimento-x, não aqui.
    #
    # ── O CONTRATO (medido ao vivo em 2026-09-29, conta do jar, 1 tentativa) ──────────────────────────
    #   POST https://www.youtube.com/youtubei/v1/like/like?prettyPrint=false   (corpo JSON)
    #   {"context":{"client":{"clientName":"WEB","clientVersion":"2.20260928.03.00","hl":"en"}},
    #    "target":{"videoId":"<id>"}}
    #   Cabeçalhos: Cookie (o jar inteiro), Authorization (SAPISIDHASH + SAPISID1PHASH + SAPISID3PHASH, como o
    #   yt-dlp: `<esquema> <ts>_<sha1("<ts> <cookie> https://www.youtube.com")>`), X-Origin e Origin
    #   (https://www.youtube.com), X-Goog-AuthUser: 0, X-YouTube-Client-Name: 1, X-YouTube-Client-Version.
    #   Sucesso: HTTP 200 JSON com `frameworkUpdates.entityBatchUpdate.mutations[].payload.likeStatusEntity
    #   .likeStatus == "LIKE"`; o `entityKey` é base64 (urlsafe) e carrega o id do vídeo. Vem também
    #   `actions[].runAttestationCommand.ids[].encryptedVideoId`, que NÃO é usado como prova.
    #   Não medido: a resposta a id inexistente (custaria uma segunda curtida).
    #
    # Curtir é idempotente (repetir não desfaz nem duplica), por isso o `Incerto` aqui é só o aviso de que
    # a dúvida existe, e não a barreira de retomada que o `postar` do X exige.
    module YoutubeEscrita
      COOKIE_DOMAIN = "youtube.com"
      ORIGIN = "https://www.youtube.com"
      LIKE_URL = "#{ORIGIN}/youtubei/v1/like/like?prettyPrint=false".freeze
      # Versão do cliente web medida em 2026-09-29 (`INNERTUBE_CLIENT_VERSION` do HTML de youtube.com; o
      # yt-dlp 2026.08.19 manda 2.20260708.00.00 e o YouTube aceita as duas). Se o YouTube passar a recusar
      # versão velha, a curtida sai `Recusado` (400): atualize esta constante pela do HTML.
      CLIENT_VERSION = "2.20260928.03.00"
      # Frugal de propósito (conta compartilhada com a transcrição): 2/min e 30/hora.
      BUDGET = { scope: "youtube_escrita", max: 2, per_hour: 30 }.freeze
      # yt-dlp: SAPISID, com fallback para __Secure-3PAPISID (o YouTube também cai nele).
      ESQUEMAS = [
        ["SAPISIDHASH", %w[SAPISID __Secure-3PAPISID]],
        ["SAPISID1PHASH", %w[__Secure-1PAPISID]],
        ["SAPISID3PHASH", %w[__Secure-3PAPISID]]
      ].freeze

      class Error < ::Fetcher::Channels::Error; end
      class Recusado < Error; end
      class RateLimited < Error; end
      class ResponseError < Error; end
      # O pedido pode ter chegado ao YouTube e a resposta se perdeu (curtir é idempotente, mas a dúvida fica).
      class Incerto < Error; end

      module_function

      def curtir(id:)
        id = Youtube.video_id!(id)
        cookies, = SessionCookies.for(COOKIE_DOMAIN)
        headers = monta_headers(cookies, id)
        gate!
        resposta = begin
          SafeHttpClient.post(LIKE_URL, json: corpo(id), headers: headers)
        rescue SafeHttpClient::Error, SsrfGuard::Blocked => e
          falha_de_rede!(e)
        end
        confirma!(resposta, id)
        { "id" => id }
      end

      def corpo(id)
        { "context" => { "client" => { "clientName" => "WEB", "clientVersion" => CLIENT_VERSION, "hl" => "en" } },
          "target" => { "videoId" => id } }
      end

      # Sessão sem cookie de assinatura é sessão morta para a escrita: `Expired` antes de qualquer rede.
      def monta_headers(cookies, id)
        valor = ->(nome) { cookies.find { |c| c["name"] == nome }&.fetch("value", nil).to_s.then { |v| v.empty? ? nil : v } }
        agora = Time.now.to_i.to_s
        autorizacao = ESQUEMAS.filter_map do |esquema, nomes|
          segredo = nomes.filter_map { |n| valor.call(n) }.first
          next unless segredo

          "#{esquema} #{agora}_#{Digest::SHA1.hexdigest("#{agora} #{segredo} #{ORIGIN}")}"
        end
        raise CookieJar::Expired, COOKIE_DOMAIN if autorizacao.empty?

        {
          "cookie" => cookies.map { |c| "#{c['name']}=#{c['value']}" }.join("; "),
          "authorization" => autorizacao.join(" "),
          "x-origin" => ORIGIN, "origin" => ORIGIN, "referer" => "#{ORIGIN}/watch?v=#{id}",
          "x-goog-authuser" => "0",
          "x-youtube-client-name" => "1", "x-youtube-client-version" => CLIENT_VERSION
        }
      end

      def gate!
        raise RateLimited, "trava local: #{BUDGET[:max]}/min ou #{BUDGET[:per_hour]}/hora de curtidas no YouTube" if
          HostRateLimiter.exceeded?(COOKIE_DOMAIN, **BUDGET)
      end

      # Mesma regra do X: antes do envio (DNS, SSRF, connect) a curtida não aconteceu → ResponseError; depois
      # do envio (timeout de leitura, reset, corpo grande) pode ter acontecido → Incerto.
      def falha_de_rede!(erro)
        detalhe = "like/like (#{erro.class.name}#{erro.cause ? " <- #{erro.cause.class.name}" : ''}): #{erro.message}"
        raise Incerto, "resultado incerto em #{detalhe}; pode TER saido no YouTube (curtir e idempotente: " \
                       "repetir nao duplica, mas confira o video)" if XEscrita.pos_envio?(erro)

        raise ResponseError, "falha de rede em #{detalhe}"
      end

      def confirma!(resposta, id)
        case resposta.status.to_i
        when 401, 403 then raise CookieJar::Expired, COOKIE_DOMAIN
        when 429 then raise RateLimited, "like/like: 429 do YouTube"
        when 400..499 then raise Recusado, "like/like: YouTube recusou (HTTP #{resposta.status})"
        when 200..299 then nil
        else raise ResponseError, "like/like: HTTP #{resposta.status}"
        end
        dados = begin
          JSON.parse(resposta.body.to_s)
        rescue JSON::ParserError
          nil
        end
        return if curtida_confirmada?(dados, id)

        raise ResponseError, "like/like: 2xx sem likeStatus LIKE para #{id} na resposta (curtir e idempotente: " \
                             "repetir nao duplica, mas confira o video)"
      end

      # O marcador medido: alguma mutação com `likeStatusEntity.likeStatus == "LIKE"` cuja chave (base64
      # urlsafe) carrega o id do vídeo. Cada nível é conferido (`Hash#dig` estoura em tipo inesperado).
      def curtida_confirmada?(dados, id)
        lote = dados.is_a?(Hash) ? dados["frameworkUpdates"] : nil
        lote = lote.is_a?(Hash) ? lote["entityBatchUpdate"] : nil
        mutacoes = lote.is_a?(Hash) ? lote["mutations"] : nil
        return false unless mutacoes.is_a?(Array)

        mutacoes.any? do |m|
          entidade = m.is_a?(Hash) && m["payload"].is_a?(Hash) ? m["payload"]["likeStatusEntity"] : nil
          entidade.is_a?(Hash) && entidade["likeStatus"] == "LIKE" && chave_do_video?(m["entityKey"] || entidade["key"], id)
        end
      end

      def chave_do_video?(chave, id)
        bruto = URI.decode_www_form_component(chave.to_s)
        Base64.urlsafe_decode64(bruto).include?(id)
      rescue ArgumentError
        false
      end
    end
  end
end
