# frozen_string_literal: true

require "digest"
require "timeout"
require_relative "channels/registry"
require_relative "cookie_jar"
require_relative "safe_http_client"
require_relative "markdown_converter"
require_relative "host_rate_limiter"
require_relative "ssrf_guard"
require_relative "ttl_policy"
require_relative "page_fetcher"

begin
  require "readability"
rescue LoadError
  # ruby-readability é opcional; sem ele o caminho estático usa o HTML inteiro.
end

module Fetcher
  # Extração de conteúdo para o endpoint /internal/extract.
  #
  # Estratégia barata-primeiro: fetch estático + Readability resolve documentação,
  # release notes e blog — a maioria do que um reader pede. Chrome só entra quando
  # o resultado vem magro (página client-side rendered) ou quando o host está na
  # lista de hard domains. Subir Chrome em toda página é lento e desnecessário.
  #
  # Toda URL vem de conteúdo não-confiável: a validação SSRF é por hop, dentro do
  # SafeHttpClient.
  class ExtractService
    DEFAULT_MAX_CHARS = 15_000
    MIN_MAX_CHARS     = 500
    MAX_MAX_CHARS     = 50_000
    # Abaixo disso o markdown estático não é conteúdo — é casca de SPA.
    THIN_CONTENT_CHARS = 400
    CACHE_PREFIX       = "page_extract:v2"
    CACHE_CONTENT_CAP  = MAX_MAX_CHARS
    # Teto TOTAL por URL, imposto em `call` (Timeout.timeout envolve toda a
    # extração). Não é só o teto do canal: `CHANNEL_TIMEOUT` também é o teto do
    # canal interno, mas o caminho comum (with_escalation) roda estático
    # (SafeHttpClient::TOTAL_TIMEOUT = 25s) E browser (PageFetcher::OVERALL_TIMEOUT
    # = 25s) SEQUENCIALMENTE quando o estático vem magro. Sem um teto externo,
    # o pior caso real por URL seria 25 + 25 = 50s — e duas ondas dariam 100s,
    # acima dos 90s do plugin do reader, que veria a chamada como timeout.
    # Este teto externo (igual a CHANNEL_TIMEOUT) garante o orçamento de ~40s por
    # URL; como ele começa ANTES do teto interno do canal (que só envolve
    # channel.call), com valores iguais o externo vence primeiro — o canal nunca
    # ganha tempo extra, e o caminho comum (estático + browser) fica coberto. A
    # conta do controller (2 ondas × 40s = 80s < 90s) só fecha por causa dele.
    CHANNEL_TIMEOUT    = 40
    # Alias com o nome que diz o papel: é o teto TOTAL imposto por URL, não o do
    # canal. O controller usa esta conta para dimensionar MAX_URLS.
    TOTAL_PER_URL_TIMEOUT = CHANNEL_TIMEOUT
    # Fatia mínima do container principal que o Readability precisa cobrir para
    # ser considerado a extração boa.
    MIN_ARTICLE_SHARE  = 0.4
    MAIN_SELECTORS     = ["main", "[role=main]", "article", "#content", "#main", ".content"].freeze
    # `metadata["source"]` é a identidade de quem extraiu, e é o que vira
    # `engine`. Os dois caminhos da casa têm nome interno diferente do publicado
    # ("browser" é o Chrome), então continuam traduzidos; canal publica o próprio
    # nome (`rss`, `youtube`, `reddit`), que é o que diz ao leitor de onde veio o
    # conteúdo — sem isso, transcrição e casca de página são indistinguíveis.
    ENGINE_BY_SOURCE   = { "browser" => "chrome", "static" => "static" }.freeze

    # O teto é obrigatório de propósito: com default, quem revertesse a chamada
    # para a forma de um argumento voltaria a reportar o teto da casa em host
    # cujo teto é outro — calado. Sem default, a reversão é um ArgumentError.
    class RateLimited < StandardError
      def initialize(host, teto)
        super("rate limit local: host #{host} atingiu #{teto} fetches/min")
      end
    end

    # Tipo de conteúdo que este endpoint não extrai (PDF, binário). Não escala
    # pro Chrome — escalar não muda o resultado.
    class Unsupported < StandardError; end

    class << self
      def call(url, max_chars: DEFAULT_MAX_CHARS)
        new(max_chars: max_chars).call(url)
      end
    end

    def initialize(max_chars: DEFAULT_MAX_CHARS)
      @max_chars = clamp_max_chars(max_chars)
    end

    # Sempre devolve um hash no contrato do plugin — erro vira campo, nunca exceção
    # que derrube o lote inteiro.
    #
    # O Timeout.timeout externo é o que dá valor REAL à premissa do controller
    # (2 ondas × TOTAL_PER_URL_TIMEOUT < 90s): sem ele, o caminho comum
    # (with_escalation) poderia gastar 25s (estático) + 25s (browser) = 50s por
    # URL e duas ondas estourariam o corte do reader. Ele também cobre canais que
    # esquecem de honrar o CHANNEL_TIMEOUT interno. `Timeout::Error` vira failure
    # como qualquer erro esperado — nunca um 500 no lote.
    def call(url)
      requested = url.to_s
      extracted = Timeout.timeout(TOTAL_PER_URL_TIMEOUT) { extract(requested) }
      success(requested, extracted)
    rescue Timeout::Error
      failure(requested, "extração excedeu #{TOTAL_PER_URL_TIMEOUT}s por URL")
    rescue SsrfGuard::Blocked => e
      failure(requested, e.reason)
    # `Channels::Error` e não `Channels::Youtube::NoTranscript`: o registro carrega
    # o canal sob demanda, então nomear a classe do canal aqui levantaria NameError
    # antes de o arquivo dele ter sido lido. Falha de canal é prevista — sai com a
    # mensagem limpa, sem o prefixo de classe do `rescue` de último recurso.
    rescue RateLimited, Unsupported, SafeHttpClient::Error, PageFetcher::FetchError,
           CookieJar::Expired, Channels::Error => e
      failure(requested, e.message)
    rescue StandardError => e
      Rails.logger.error "[Fetcher::ExtractService] #{requested}: #{e.class}: #{e.message}"
      failure(requested, "#{e.class}: #{e.message}")
    end

    private

    def clamp_max_chars(value)
      requested = value.to_i
      requested = DEFAULT_MAX_CHARS unless requested.positive?
      [[requested, MIN_MAX_CHARS].max, MAX_MAX_CHARS].min
    end

    def extract(url)
      uri  = SsrfGuard.validate!(url)
      host = uri.host.to_s.downcase

      cache_key = cache_key_for(uri)
      cached = Rails.cache.read(cache_key)
      return cached if cached

      # O canal é resolvido antes do limitador porque ele decide o teto: canal
      # autenticado bate numa plataforma que conta requisição por conta, não só
      # por IP. `exceeded?` INCREMENTA, então só pode ser chamado uma vez.
      channel = Channels::Registry.for_host(host)
      orcamento = budget_for(channel)
      raise RateLimited.new(host, orcamento[:max]) if HostRateLimiter.exceeded?(host, **orcamento)

      result = (channel && via_channel(channel, url)) ||
               (browser_first?(host) ? via_browser(url) : with_escalation(url))

      Rails.cache.write(cache_key, result, expires_in: TtlPolicy.for(host: host, path: uri.path))
      result
    end

    # Canal declara o próprio orçamento — chave E teto, não só o teto. Só o teto
    # deixaria os dois caminhos do mesmo host disputando o mesmo contador, que é
    # exatamente o defeito medido no x.com em 06/08.
    def budget_for(channel)
      return { max: HostRateLimiter::MAX_PER_WINDOW } if channel.nil?
      return channel.extract_budget if channel.respond_to?(:extract_budget)

      { max: channel.const_defined?(:MAX_PER_WINDOW) ? channel::MAX_PER_WINDOW : HostRateLimiter::MAX_PER_WINDOW }
    end

    # Devolve nil quando o canal se declara incompetente — content-type é palpite
    # e URL de canal do YouTube não é vídeo. Nos dois casos o caminho comum segue.
    def via_channel(channel, url)
      result = Timeout.timeout(CHANNEL_TIMEOUT) { channel.call(url: url) }
      return nil if result.nil?

      capped, total = cap(result[:content])
      result.merge(content: capped, metadata: (result[:metadata] || {}).merge("content_chars_total" => total))
    rescue Timeout::Error
      raise Unsupported, "canal #{channel} não respondeu em #{CHANNEL_TIMEOUT}s"
    end

    # Canal por content-type. O cabeçalho é palpite — `application/xml` cobre
    # sitemap e SOAP também —, então o canal confirma pelo conteúdo e devolve nil
    # quando não é dele.
    def via_content_type_channel(url, response)
      channel = Channels::Registry.for_content_type(response.content_type)
      return nil unless channel

      result = Timeout.timeout(CHANNEL_TIMEOUT) { channel.call(url: url, response: response) }
      return nil if result.nil?

      capped, total = cap(result[:content])
      result.merge(content: capped, metadata: (result[:metadata] || {}).merge("content_chars_total" => total))
    rescue Timeout::Error
      nil
    end

    # Caminho barato primeiro; escala pro Chrome só quando o estático vem magro.
    def with_escalation(url)
      static_error = nil
      static = begin
        via_static(url)
      rescue SafeHttpClient::Error => e
        static_error = e
        nil
      end

      # Resultado de canal por content-type é final mesmo curto: um feed com um
      # item só é conteúdo completo, não casca de SPA. Sem esta guarda, o feed
      # de exemplo com 1 item (bem abaixo de THIN_CONTENT_CHARS) escalava pro
      # Chrome — que não entende feed e devolveria a mesma página em HTML.
      return static if static && (channel_routed?(static) || static[:content].to_s.length >= THIN_CONTENT_CHARS)

      browser = begin
        via_browser(url)
      rescue StandardError => e
        Rails.logger.info "[Fetcher::ExtractService] escalada falhou em #{url}: #{e.class}: #{e.message}"
        nil
      end

      best = [static, browser].compact.max_by { |result| result[:content].to_s.length }
      return best if best

      raise static_error || SafeHttpClient::Error.new("nenhum conteúdo extraído")
    end

    # Distingue o hash que `via_static` monta sozinho (source "static") do hash
    # que um canal por content-type devolveu através dele.
    def channel_routed?(result)
      result[:metadata].is_a?(Hash) && result[:metadata]["source"] != "static"
    end

    def via_static(url)
      response = SafeHttpClient.get(url)

      raise Unsupported, "conteúdo é PDF — não suportado" if response.pdf?
      raise SafeHttpClient::Error, "HTTP #{response.status}" if response.status >= 400

      routed = via_content_type_channel(url, response)
      return routed if routed

      html = response.body.to_s
      return nil if html.strip.empty?

      markdown = markdown_from(html)
      capped, total = cap(markdown)

      {
        url:      response.final_url,
        title:    page_title(html),
        content:  capped,
        metadata: metadata_from(html).merge(
          "source" => "static", "status" => response.status, "content_type" => response.content_type,
          "content_chars_total" => total
        )
      }
    rescue SafeHttpClient::Error, SsrfGuard::Blocked, Unsupported
      raise
    rescue StandardError => e
      Rails.logger.warn "[Fetcher::ExtractService] estático falhou em #{url}: #{e.class}: #{e.message}"
      nil
    end

    # `max_chars: MAX_MAX_CHARS` e `rate_limit: false` são o par que fecha o
    # contrato deste serviço com o PageFetcher:
    # - o default do ReadabilityInjector (8k) cortaria o caminho browser sem
    #   dizer nada — o teto da casa já é o que o cache aceita, então pedir o
    #   teto não custa mais e não corta escondido;
    # - o rate limit JÁ foi cobrado aqui em `extract` (com o teto do canal);
    #   o PageFetcher cobrar de novo contaria em dobro na escalada.
    def via_browser(url)
      payload = PageFetcher.new(rate_limit: false).call(url, include_html: true, max_chars: MAX_MAX_CHARS)
      markdown = MarkdownConverter.call(payload[:article_html].to_s)
      from_payload = markdown.strip.empty?
      # Sem HTML de artigo (fallback nodriver, live host), o texto já é o conteúdo.
      markdown = payload[:content].to_s if from_payload

      capped, total = cap(markdown)
      metadata = {
        "source" => "browser",
        "cache_age_seconds" => payload[:cache_age_seconds],
        # No fallback, `payload[:char_count]` é o total ANTES do corte do
        # ReadabilityInjector; sem ele o corte de 50k do injector viraria
        # "li tudo" para quem compara content_chars_total com o que recebeu.
        "content_chars_total" => from_payload ? (payload[:char_count] || total) : total
      }

      {
        url:      payload[:url].to_s,
        title:    payload[:title].to_s,
        content:  capped,
        metadata: metadata
      }
    end

    # O Readability escolhe UM candidato e descarta o resto. Em documentação
    # gerada (Sphinx, javadoc), esse candidato costuma ser uma seção só — medido
    # em docs.python.org: 3.8k chars de uma página com dezenas de milhares, e o
    # começo da página fora. Quando a fatia é pequena demais, o container
    # principal da página vale mais que o palpite do Readability.
    def markdown_from(html)
      article  = MarkdownConverter.call(readability_html(html))
      fallback = MarkdownConverter.call(main_content_html(html))

      return fallback if article.length < fallback.length * MIN_ARTICLE_SHARE

      article.presence || fallback
    end

    def main_content_html(html)
      doc = Nokogiri::HTML(html)
      node = MAIN_SELECTORS.lazy.filter_map { |selector| doc.at_css(selector) }.first
      node ||= doc.at_css("body") || doc

      node = node.dup
      node.css("header, footer, aside, nav").each(&:remove)
      node.to_html
    rescue StandardError => e
      Rails.logger.warn "[Fetcher::ExtractService] main_content falhou: #{e.class}: #{e.message}"
      html.to_s
    end

    def readability_html(html)
      return "" unless defined?(Readability::Document)

      # `tags:` amplia o whitelist padrão (só div/p), senão títulos e listas somem.
      # `clean_conditionally: false` porque a heurística do ruby-readability
      # descarta <ul>/<table> por densidade de link — justamente o que o markdown
      # precisa preservar.
      Readability::Document.new(
        html,
        tags: %w[div p h1 h2 h3 h4 h5 h6 ul ol li pre code blockquote
                 table thead tbody tr th td a strong b em i br hr img],
        clean_conditionally: false,
        remove_empty_nodes: true
      ).content.to_s
    rescue StandardError => e
      Rails.logger.warn "[Fetcher::ExtractService] ruby-readability falhou: #{e.class}: #{e.message}"
      ""
    end

    def page_title(html)
      doc = Nokogiri::HTML(html)
      og = doc.at_css('meta[property="og:title"]')&.[]("content").to_s.strip
      return og unless og.empty?

      doc.at_css("title")&.text.to_s.strip
    rescue StandardError
      ""
    end

    def metadata_from(html)
      doc = Nokogiri::HTML(html)
      {
        "description"    => meta(doc, 'meta[name="description"]', "content"),
        "site_name"      => meta(doc, 'meta[property="og:site_name"]', "content"),
        "published_time" => meta(doc, 'meta[property="article:published_time"]', "content"),
        "language"       => doc.at_css("html")&.[]("lang").to_s.strip
      }.reject { |_k, v| v.to_s.empty? }
    rescue StandardError
      {}
    end

    def meta(doc, selector, attribute)
      doc.at_css(selector)&.[](attribute).to_s.strip
    end

    # Hard domain e live host vão direto ao Chrome, por motivos diferentes.
    #
    # Hard domain porque o estático leva bloqueio. Live host porque o VALOR que se
    # quer (preço, cotação) é renderizado por JS: a página serve HTML de sobra —
    # bem acima de THIN_CONTENT_CHARS — e o estático voltaria "gordo" e sem o
    # número, sem nunca escalar. É o caso de uso do `page_fetch` do chatbot, e
    # esta regra faltava aqui porque o reader raramente pede CoinGecko.
    def browser_first?(host)
      hard_domain?(host) || TtlPolicy.live_host?(host)
    end

    def hard_domain?(host)
      PageFetcher.hard_domains.any? { |d| host == d || host.end_with?(".#{d}") }
    end

    # Devolve [texto, tamanho_original]: o teto de 50k existe para o cache não
    # inchar, mas quem consome precisa saber quanto existia ANTES do corte para
    # decidir se vale repetir com limite maior. Medir depois (como era) fazia
    # uma transcrição de 120k virar `content_chars_total: 50000` e a tool
    # concluir que leu tudo — perda de 70k indistinguível de sucesso.
    def cap(text)
      body = text.to_s
      return [body, body.length] if body.length <= CACHE_CONTENT_CAP

      [body[0, CACHE_CONTENT_CAP], body.length]
    end

    def truncate(text)
      body = text.to_s
      return body if body.length <= @max_chars

      window = body[0, @max_chars]
      boundary = window.rindex("\n\n")
      boundary && boundary > @max_chars / 2 ? body[0, boundary] : window
    end

    def success(requested, extracted)
      # Quanto existia ANTES do corte. Sem isto quem consome sabe que truncou mas
      # nao sabe se perdeu 2% ou 80% — e nao tem como decidir se vale repedir com
      # limite maior. Transcricao de video passa facil de 30 mil caracteres.
      # Os caminhos gravam o total ANTES do cap de 50k no metadata (ver `cap`);
      # o fallback cobre cache antigo ou canal que nao declarou o campo.
      base_metadata = extracted[:metadata] || {}
      metadata = base_metadata.merge(
        "content_chars_total" => base_metadata["content_chars_total"] || extracted[:content].to_s.length
      )
      engine = engine_for(metadata)

      {
        requested_url: requested,
        url:           extracted[:url].presence || requested,
        title:         extracted[:title].to_s,
        content:       truncate(extracted[:content]),
        raw_content:   nil,
        # `rendered: false` quer dizer que o JavaScript da página NÃO rodou. O
        # chamador precisa disso para declarar leitura possivelmente incompleta
        # em vez de afirmar como se fosse completa — sem o campo, a degradação
        # para o caminho estático é indistinguível de sucesso.
        engine:        engine,
        rendered:      rendered_for(metadata, engine),
        metadata:      metadata,
        error:         nil
      }
    end

    def engine_for(metadata)
      source = metadata["source"].to_s
      ENGINE_BY_SOURCE.fetch(source) { source.presence || "static" }
    end

    # `rendered` continua significando "o JavaScript da página rodou", não "veio
    # de canal": feed é estático e canal sobre o Chrome logado lê dado embutido,
    # não a pintura da página. Canal que de fato renderizar declara
    # `metadata["rendered"]`; quem não declara herda o default do caminho comum.
    def rendered_for(metadata, engine)
      return metadata["rendered"] ? true : false if metadata.key?("rendered")

      engine == "chrome"
    end

    def failure(requested, message)
      {
        requested_url: requested,
        url:           requested,
        title:         nil,
        content:       nil,
        raw_content:   nil,
        engine:        nil,
        rendered:      false,
        metadata:      {},
        error:         message.to_s
      }
    end

    def cache_key_for(uri)
      canonical = "#{uri.scheme.to_s.downcase}://#{uri.host.to_s.downcase}#{uri.request_uri}"
      "#{CACHE_PREFIX}:#{Channels::Registry.fingerprint}:#{Digest::SHA1.hexdigest(canonical)}"
    end
  end
end
