# frozen_string_literal: true

require "net/http"
require "timeout"
require "uri"
require "zlib"
require_relative "ssrf_guard"

module Fetcher
  # GET HTTP endurecido contra SSRF, para URLs de origem não-confiável.
  #
  # Quatro propriedades que o `SsrfGuard.validate!` sozinho não dá:
  #
  #   1. Revalidação a CADA redirect — um site público que responde
  #      `302 Location: http://127.0.0.1/` não passa.
  #   2. Coerência resolve→conecta: o IP validado é o IP do socket
  #      (`Net::HTTP#ipaddr=`), fechando a janela de DNS rebinding em que a
  #      segunda resolução devolveria um IP interno.
  #   3. Bloqueio por IP resolvido (não por string) — herdado do SsrfGuard.
  #   4. Só http/https, inclusive depois de redirect.
  #
  # Mais: tetos de bytes baixados e descomprimidos, timeout total, e nenhum
  # header/cookie vindo do chamador — a requisição é montada aqui, ponto.
  class SafeHttpClient
    MAX_REDIRECTS          = 5
    MAX_COMPRESSED_BYTES   = 5 * 1024 * 1024
    MAX_DECOMPRESSED_BYTES = 10 * 1024 * 1024
    OPEN_TIMEOUT           = 5
    READ_TIMEOUT           = 12
    TOTAL_TIMEOUT          = 25
    USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " \
                 "Chrome/131.0.0.0 Safari/537.36"

    REDIRECT_CODES = [301, 302, 303, 307, 308].freeze

    class Error < StandardError; end
    class TooManyRedirects < Error; end
    class BodyTooLarge < Error; end
    class RequestTimeout < Error; end

    Response = Struct.new(:status, :final_url, :content_type, :body, :headers, keyword_init: true) do
      def html?
        content_type.to_s.empty? ||
          content_type.to_s.include?("html") ||
          content_type.to_s.include?("xml")
      end

      def pdf?
        content_type.to_s.include?("application/pdf")
      end

      def success?
        status.to_i.between?(200, 299)
      end
    end

    Hop = Struct.new(:status, :headers, :body, keyword_init: true)

    class << self
      def get(url, total_timeout: TOTAL_TIMEOUT, headers: {})
        new(total_timeout: total_timeout).get(url, headers: headers)
      end

      def post(url, json:, total_timeout: TOTAL_TIMEOUT, headers: {})
        new(total_timeout: total_timeout).post(url, json: json, headers: headers)
      end
    end

    def initialize(total_timeout: TOTAL_TIMEOUT)
      @total_timeout = total_timeout
    end

    def get(url, headers: {})
      Timeout.timeout(@total_timeout) { follow(url, headers: headers) }
    rescue Timeout::Error
      raise RequestTimeout, "timeout de #{@total_timeout}s"
    end

    def post(url, json:, headers: {})
      body = json.nil? ? "" : json.to_json
      Timeout.timeout(@total_timeout) { follow(url, headers: headers, body: body) }
    rescue Timeout::Error
      raise RequestTimeout, "timeout de #{@total_timeout}s"
    rescue JSON::GeneratorError => e
      raise Error, "JSON inválido (#{e.message})"
    end

    private

    def follow(url, headers: {}, body: nil)
      current = url.to_s
      seen = []
      # Headers extras (ex.: Authorization Bearer de uma API) são segredo da
      # ORIGEM original. Em redirect CROSS-ORIGIN (scheme, host ou porta
      # diferentes), reenviá-los vazaria o token para outro domínio — limpa.
      # Redirect same-origin (ex.: repo do GitHub transferido/renomeado) mantém
      # a autenticação: derrubá-la aí degradaria silenciosamente para o tier
      # anônimo ou quebraria recurso privado.
      current_origin = origin_of(current)

      (MAX_REDIRECTS + 1).times do
        # Revalidação por hop: scheme, host e IP são checados de novo aqui.
        resolution = SsrfGuard.resolve!(current)
        seen << current

        hop = perform(resolution, extra_headers: headers, body: body)
        location = hop.headers["location"]

        return build_response(hop, resolution.uri.to_s) unless redirect?(hop, location)

        current = next_location(resolution.uri, location)
        raise TooManyRedirects, "loop de redirect em #{current}" if seen.include?(current)

        # Só preserva headers se o próximo hop mantém a MESMA origem
        # (scheme + host + porta). Qualquer mudança — ou origem não resolvível
        # (fail-closed) — limpa o Authorization.
        next_origin = origin_of(current)
        headers = {} unless next_origin && next_origin == current_origin
      end

      raise TooManyRedirects, "mais de #{MAX_REDIRECTS} redirects"
    end

    def origin_of(url)
      uri = URI.parse(url.to_s)
      port = uri.port
      # Porta explícita igual à default do scheme normaliza para a mesma origem.
      default = uri.scheme == "https" ? 443 : 80
      port = default if port == default
      [uri.scheme, uri.host.to_s.downcase, port]
    rescue URI::Error
      nil
    end

    def redirect?(hop, location)
      REDIRECT_CODES.include?(hop.status) && !location.to_s.strip.empty?
    end

    # O Location é resolvido contra a URI atual; o esquema resultante volta pro
    # SsrfGuard na próxima volta do laço (file://, gopher:// morrem lá).
    def next_location(base_uri, location)
      URI.join(base_uri, location.to_s.strip).to_s
    rescue URI::Error => e
      raise Error, "Location inválido (#{e.message})"
    end

    def perform(resolution, extra_headers: {}, body: nil)
      uri = resolution.uri
      http = Net::HTTP.new(uri.host, uri.port)
      # Conecta NO IP validado. `uri.host` continua valendo para Host header,
      # SNI e verificação de certificado.
      http.ipaddr = resolution.ip
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      hop = nil
      http.start do |session|
        request = build_request(uri, extra_headers: extra_headers, body: body)
        session.request(request) do |response|
          hop = Hop.new(
            status: response.code.to_i,
            headers: downcased_headers(response),
            body: read_capped(response)
          )
        end
      end
      hop
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise RequestTimeout, "timeout de rede (#{e.class})"
    rescue BodyTooLarge, Error
      raise
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}"
    end

    def downcased_headers(response)
      response.to_hash.transform_keys(&:downcase).transform_values { |v| Array(v).first.to_s }
    end

    def build_request(uri, extra_headers: {}, body: nil)
      if body.nil?
        # GET: manter comportamento existente
        req = Net::HTTP::Get.new(
          uri.request_uri,
          "host" => uri.host,
          "user-agent" => USER_AGENT,
          "accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "accept-language" => "pt-BR,pt;q=0.9,en;q=0.8",
          "accept-encoding" => "gzip"
        )
      else
        # POST: JSON body
        req = Net::HTTP::Post.new(uri.request_uri, "host" => uri.host)
        req["user-agent"] = USER_AGENT
        req["accept"] = "*/*"
        req["accept-language"] = "pt-BR,pt;q=0.9,en;q=0.8"
        req["content-type"] = "application/json"
        req.body = body
      end
      extra_headers.each { |k, v| req[k.to_s] = v.to_s }
      req
    end

    # Headers no construtor de propósito: declarar `accept-encoding` ali é o que
    # desliga o `decode_content` do Net::HTTP. A descompressão é nossa — a dele
    # não respeita teto de bytes inflados.
    def read_capped(response)
      declared = response["content-length"].to_i
      raise BodyTooLarge, "Content-Length #{declared} > #{MAX_COMPRESSED_BYTES}" if declared > MAX_COMPRESSED_BYTES

      compressed = +""
      response.read_body do |chunk|
        compressed << chunk
        if compressed.bytesize > MAX_COMPRESSED_BYTES
          raise BodyTooLarge, "corpo excede #{MAX_COMPRESSED_BYTES} bytes baixados"
        end
      end

      if response["content-encoding"].to_s.downcase.include?("gzip")
        inflate_capped(compressed)
      else
        cap_plain(compressed)
      end
    end

    def cap_plain(body)
      raise BodyTooLarge, "corpo excede #{MAX_DECOMPRESSED_BYTES} bytes" if body.bytesize > MAX_DECOMPRESSED_BYTES

      body
    end

    def inflate_capped(compressed)
      inflater = Zlib::Inflate.new(32 + Zlib::MAX_WBITS)
      out = +""
      inflater.inflate(compressed) do |chunk|
        out << chunk
        if out.bytesize > MAX_DECOMPRESSED_BYTES
          raise BodyTooLarge, "corpo excede #{MAX_DECOMPRESSED_BYTES} bytes descomprimidos"
        end
      end
      out
    rescue Zlib::Error => e
      raise Error, "gzip inválido (#{e.message})"
    ensure
      begin
        inflater&.close
      rescue StandardError
        nil
      end
    end

    def build_response(hop, final_url)
      content_type = hop.headers["content-type"].to_s
      Response.new(
        status: hop.status,
        final_url: final_url,
        content_type: content_type.split(";").first.to_s.strip.downcase,
        body: force_utf8(hop.body.to_s, content_type),
        headers: hop.headers
      )
    end

    def force_utf8(body, content_type)
      charset = content_type[/charset=([^;\s]+)/i, 1]
      encoded = charset ? body.dup.force_encoding(charset) : body.dup.force_encoding(Encoding::UTF_8)
      encoded.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    rescue StandardError
      body.dup.force_encoding(Encoding::UTF_8).scrub("")
    end
  end
end
