# frozen_string_literal: true

require "nokogiri"
require "uri"

module Fetcher
  # Abre UMA página da web para o agente do porteiro (`bin/rails x:ler URL=<url>`).
  #
  # O caminho é o guardado da casa: `Fetcher::SafeHttpClient` (SsrfGuard a cada redirect, IP pinado,
  # tetos de bytes e de tempo, nenhum header/cookie do chamador). Aqui NÃO há cliente HTTP próprio.
  #
  # Devolve só `url` (final, depois dos redirects), `titulo`, `texto` (markdown, cortado em
  # MAX_TEXTO) e metadados do corte. Cabeçalhos, cookies e corpo cru NUNCA saem daqui.
  #
  # MAX_TEXTO = 30.000 caracteres: ~7-8 mil tokens (≈4 caracteres/token), o que cabe um artigo
  # longo ou um README inteiro (típicos: 3-15 mil) sem entupir o contexto do agente; paper em HTML
  # passa disso e vem `truncado: true` com o `caracteres_total` à vista, e o agente sabe que leu
  # só o começo. Finito de propósito: 20 leituras/24 h x 30 mil = teto de ~160 mil tokens/dia.
  module XLer
    MAX_TEXTO = 30_000
    MAX_TITULO = 300
    MAX_URL = 2048

    class Erro < StandardError; end
    class UrlInvalida < Erro; end
    class Bloqueado < Erro; end
    class TempoEsgotado < Erro; end
    class CorpoGrande < Erro; end
    class HttpErro < Erro; end
    class TipoNaoSuportado < Erro; end
    class SemTexto < Erro; end

    module_function

    def ler(url:, cliente: SafeHttpClient)
      url = url.to_s.strip
      valida!(url)
      resposta = busca(url, cliente)
      raise HttpErro, "a página respondeu HTTP #{resposta.status}" unless resposta.success?

      texto, titulo = extrai(resposta)
      raise SemTexto, "a página não tem texto legível (talvez seja montada por JavaScript, que este leitor não executa)" if texto.empty?

      total = texto.length
      {
        "url" => resposta.final_url.to_s,
        "titulo" => titulo.to_s.strip[0, MAX_TITULO],
        "texto" => texto[0, MAX_TEXTO],
        "caracteres_total" => total,
        "truncado" => total > MAX_TEXTO
      }
    end

    def valida!(url)
      raise UrlInvalida, "URL vazia" if url.empty?
      raise UrlInvalida, "URL acima de #{MAX_URL} caracteres" if url.length > MAX_URL

      uri = URI.parse(url)
      raise UrlInvalida, "só http e https são lidos" unless %w[http https].include?(uri.scheme)
      raise UrlInvalida, "URL sem domínio" if uri.host.to_s.empty?
      raise UrlInvalida, "URL com usuário/senha embutidos não é lida" if uri.userinfo
    rescue URI::InvalidURIError
      raise UrlInvalida, "URL malformada"
    end

    # Traduz as falhas do caminho guardado para frases que o agente entende — sem repassar o
    # `message` cru das exceções de rede (pode carregar IP interno e detalhes da pilha).
    def busca(url, cliente)
      cliente.get(url)
    rescue SsrfGuard::Blocked => e
      raise Bloqueado, "a casa não abre este endereço (#{e.reason}); só sites públicos de http/https"
    rescue SafeHttpClient::RequestTimeout
      raise TempoEsgotado, "a página não respondeu a tempo"
    rescue SafeHttpClient::BodyTooLarge
      raise CorpoGrande, "a página é grande demais para ler (teto de 5 MB baixados / 10 MB descomprimidos)"
    rescue SafeHttpClient::TooManyRedirects
      raise HttpErro, "a página redireciona demais (mais de #{SafeHttpClient::MAX_REDIRECTS} redirects ou loop)"
    rescue SafeHttpClient::Error
      raise HttpErro, "não consegui baixar a página (falha de rede ou TLS)"
    end

    def extrai(resposta)
      raise TipoNaoSuportado, "PDF não é lido por este leitor; procure a página HTML (ex.: /abs/ no arXiv)" if resposta.pdf?

      if resposta.html?
        titulo = titulo_de(resposta.body)
        [MarkdownConverter.call(resposta.body).to_s.strip, titulo]
      elsif resposta.content_type.start_with?("text/", "application/json")
        [resposta.body.to_s.strip, ""]
      else
        raise TipoNaoSuportado, "tipo de conteúdo não lido: #{resposta.content_type.to_s[0, 60]}"
      end
    end

    def titulo_de(html)
      doc = Nokogiri::HTML(html.to_s)
      (doc.at_css("title")&.text.to_s.strip.presence ||
        doc.at_css("meta[property='og:title']")&.[]("content").to_s.strip.presence ||
        doc.at_css("h1")&.text.to_s.strip).to_s.gsub(/\s+/, " ")
    end
  end
end
