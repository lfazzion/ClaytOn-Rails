# frozen_string_literal: true

require "json"
require "uri"
require_relative "registry"
require_relative "../browser_session"
require_relative "../host_rate_limiter"

module Fetcher
  module Channels
    # Thread do Reddit pela sessão do Chrome, sempre por `old.reddit.com`.
    #
    # Medido: `.json` anônimo devolve 403 com qualquer User-Agent, e o front novo
    # carrega comentário sob demanda. O `old.` renderiza no servidor e entrega a
    # árvore inteira num HTML só.
    module Reddit
      MAX_DEPTH    = 3
      MAX_COMMENTS = 120
      # Mesmo motivo do YouTube: a plataforma conta por conta, e rajada é
      # assinatura de bot. 2/min contra os 5/min da casa.
      MAX_PER_WINDOW = 2
      # Teto de itens por busca, espelhando `Youtube::MAX_RESULTADOS`. A página de
      # busca do `old.` traz 25 por vez; pedir mais exigiria paginar, e cada
      # página é outra requisição logada.
      MAX_RESULTADOS = 25
      SEARCH_HOST    = "old.reddit.com"
      # O permalink devolvido ao modelo é o canônico. `old.` é detalhe interno
      # desta casa (`old_reddit_url` reescreve de volta na leitura da thread), e
      # devolvê-lo faria o usuário receber um link de interface legada.
      CANONICAL_HOST = "www.reddit.com"

      POST_PATH = %r{\A/r/[^/]+/comments/[^/]+}

      # Busca em plataforma logada é onde rajada vira ban — a conta responde, não
      # só o IP. Estourar o teto é erro nomeado; devolver lista vazia faria o
      # modelo concluir "não existe nada sobre isso".
      class RateLimited < Error
        def initialize(host)
          super("rate limit local: #{host} atingiu #{MAX_PER_WINDOW} buscas/min — repita daqui a pouco")
        end
      end

      # Página de busca que não deu para ler NÃO é busca sem resultado. O
      # `try/catch` do `SEARCH_JS` devolve null quando um seletor muda de nome, e
      # devolver `[]` nesse caso faz o modelo responder "não existe nada sobre
      # isso" — o mesmo defeito que a casa já pagou uma vez, quando o `rescue` da
      # escalada de Chrome transformava erro em degradação silenciosa
      # (MEMORY.md, 2026-08-01). O caminho de LEITURA já separa os dois casos:
      # `from_page` devolve nil e o `ExtractService` nomeia o erro.
      class SearchFailed < Error
        def initialize
          super("página de busca do Reddit veio ilegível — o seletor mudou ou a página não é a da busca")
        end
      end

      # Notas sobre os seletores, porque duas armadilhas mataram a versão original:
      #
      # 1. `querySelector("> ...")` é SyntaxError: um seletor não pode começar com
      #    combinador. A forma válida é `:scope > ...`.
      # 2. Sem `:scope`, `.score.unvoted` de um comentário sem score próprio pegaria
      #    o score de um comentário FILHO — número errado e silencioso. O score do
      #    post vive em `.midcol`; o do comentário, na tagline dentro de `.entry`.
      #    A lista cobre os dois sem alcançar descendentes (que ficam sob `.child`).
      #
      # O corpo inteiro vai num try/catch: seletor que mudou vira null, que o Ruby
      # traduz em nil (erro nomeado), e não um JavaScriptError cru.
      EXTRACT_JS = <<~JS
        (function () {
          try {
            function txt(el) { return el ? el.innerText.trim() : ""; }
            function score(el) {
              var s = el && el.querySelector(":scope > .midcol .score.unvoted, :scope > .entry .score.unvoted");
              var t = s ? s.getAttribute("title") : null;
              return t ? parseInt(t, 10) : null;
            }
            var post = document.querySelector("#siteTable .thing.link");
            var out = {
              title: txt(document.querySelector("#siteTable .thing.link a.title")),
              subreddit: (location.pathname.split("/")[2] || ""),
              author: txt(post && post.querySelector(".author")),
              score: score(post),
              selftext: txt(document.querySelector("#siteTable .thing.link .usertext-body")),
              comments: []
            };
            var nodes = document.querySelectorAll(".commentarea .thing.comment");
            for (var i = 0; i < nodes.length; i++) {
              var n = nodes[i];
              var depth = 0;
              for (var p = n.parentElement; p; p = p.parentElement) {
                if (p.classList && p.classList.contains("child")) depth++;
              }
              out.comments.push({
                author: txt(n.querySelector(":scope > .entry .author")),
                score: score(n),
                depth: depth,
                body: txt(n.querySelector(":scope > .entry .usertext-body"))
              });
            }
            return JSON.stringify(out);
          } catch (e) {
            return null;
          }
        })()
      JS

      # Extração da página de BUSCA, que é outra página e outra marcação: o
      # container do resultado é `.search-result-link` — `#siteTable`, usado
      # acima, só existe na página de thread e aqui não casa com nada.
      #
      # Procedência dos seletores, para ninguém tratar como medição o que não é:
      # nenhum destes foi exercitado contra a página de busca ao vivo nesta
      # construção — só contra dublê. Enquanto a prova ao vivo não rodar, título
      # vazio ou score nil em massa é o sintoma esperado se algum filho
      # (`a.search-comments`, `a.search-title`, `.search-subreddit-link`,
      # `.search-score`) tiver outro nome hoje.
      #
      # Heredoc com terminador entre aspas de propósito: `\d` dentro de heredoc
      # comum vira `d` (escape desconhecido em string de aspas duplas) e as
      # expressões regulares abaixo casariam com a letra, não com dígito.
      SEARCH_JS = <<~'JS'
        (function () {
          try {
            function txt(el) { return el ? el.innerText.trim() : ""; }
            function num(el) {
              if (!el) return null;
              var t = txt(el);
              // "1.2k comments" não dá número exato. Melhor null (que vira nil
              // no Ruby) do que um número errado com cara de medição.
              if (/^[\d.,]+\s*[kKmM]/.test(t)) return null;
              var m = t.match(/^[\d.,]+/);
              if (!m) return null;
              var n = parseInt(m[0].replace(/[.,]/g, ""), 10);
              return isNaN(n) ? null : n;
            }
            var out = [];
            var nodes = document.querySelectorAll(".search-result-link");
            for (var i = 0; i < nodes.length; i++) {
              var n = nodes[i];
              // O href do título aponta para o link EXTERNO quando o post é de
              // link; só o de comentários é sempre o permalink da thread.
              var permalink = n.querySelector("a.search-comments");
              var titulo = n.querySelector("a.search-title");
              out.push({
                url: (permalink || titulo) ? (permalink || titulo).href : "",
                title: txt(titulo),
                subreddit: txt(n.querySelector(".search-subreddit-link")),
                score: num(n.querySelector(".search-score")),
                comments: num(n.querySelector(".search-comments"))
              });
            }
            return JSON.stringify(out);
          } catch (e) {
            return null;
          }
        })()
      JS

      class << self
        def call(url:, response: nil)
          target = old_reddit_url(url)
          return nil if target.nil?

          BrowserSession.with_page(target) { |page| from_page(page: page, url: target) }
        end

        # Público de propósito, igual ao canal de YouTube: toda a lógica está
        # aqui, e é por aqui que o teste entra sem precisar de um Chrome.
        def from_page(page:, url:)
          payload = parse(page.evaluate(EXTRACT_JS))
          return nil if payload.blank?

          build(url, payload)
        end

        # Busca dentro do próprio Reddit. Existe porque buscador web não indexa
        # permalink de plataforma: medido em 05/08, `site:reddit.com` no SearXNG
        # devolveu ZERO, e nenhum engine trouxe link de thread. Descoberta de
        # conteúdo do Reddit só acontece pela busca nativa.
        #
        # Mesmo contrato de `Youtube.search`: Array de Hash de chaves STRING.
        def search(query:, limit: 10)
          termo = query.to_s.strip
          return [] if termo.empty?

          n = clamp_limit(limit)
          # `exceeded?` INCREMENTA — só pode ser chamado uma vez por busca, e
          # antes de gastar browser.
          raise RateLimited, SEARCH_HOST if HostRateLimiter.exceeded?(SEARCH_HOST, max: MAX_PER_WINDOW)

          # `with_page` já resolve a sessão do domínio e levanta
          # `CookieJar::Expired` nomeando-o quando não há nenhuma — o Reddit
          # deslogado devolve página de busca sem resultado nenhum, que seria
          # indistinguível de "não achei".
          BrowserSession.with_page(search_url(termo)) { |page| from_search_page(page: page, limit: n) }
        end

        # Público pelo mesmo motivo de `from_page`: é por aqui que o teste entra
        # sem precisar de um Chrome.
        def from_search_page(page:, limit: MAX_RESULTADOS)
          itens = parse(page.evaluate(SEARCH_JS))
          # Erro nomeado, nunca lista vazia — ver `SearchFailed`. Array vazio de
          # verdade continua passando: busca que rodou e não achou nada é
          # resposta, não falha.
          raise SearchFailed unless itens.is_a?(Array)

          itens.filter_map { |raw| item_de_busca(raw) }.first(clamp_limit(limit))
        end

        private

        def clamp_limit(limit)
          [[limit.to_i, 1].max, MAX_RESULTADOS].min
        end

        def search_url(termo)
          # `sort=relevance` explícito: o padrão da busca do Reddit muda com o
          # tempo e já foi `new`, que devolve o que acabou de ser postado em vez
          # do que responde à pergunta.
          "https://#{SEARCH_HOST}/search?#{URI.encode_www_form(q: termo, sort: 'relevance')}"
        end

        def item_de_busca(raw)
          url = permalink(raw["url"])
          return nil if url.nil?

          {
            "url"       => url,
            "title"     => raw["title"].to_s,
            "subreddit" => raw["subreddit"].to_s.delete_prefix("r/"),
            # Vindos como null do JS quando não deu para ler — nil, nunca 0:
            # zero seria uma thread sem voto e sem comentário nenhum, que é outro
            # fato. `to_i` aqui apagaria a diferença.
            "score"     => (raw["score"].to_i if raw["score"].is_a?(Numeric)),
            "comments"  => (raw["comments"].to_i if raw["comments"].is_a?(Numeric))
          }
        end

        # Resultado sem permalink do Reddit não serve de resultado: reescrever o
        # host de um link externo (post de link, cujo título aponta para fora)
        # produziria uma URL do Reddit que não existe.
        def permalink(raw)
          uri = URI.parse(raw.to_s)
          host = uri.host.to_s.downcase
          return nil unless host == "reddit.com" || host.end_with?(".reddit.com")

          uri.host = CANONICAL_HOST
          uri.to_s
        rescue URI::InvalidURIError, URI::InvalidComponentError
          nil
        end

        def old_reddit_url(url)
          uri = URI.parse(url.to_s)
          return nil unless uri.path.to_s.match?(POST_PATH)

          uri.host = "old.reddit.com"
          uri.to_s
        rescue URI::InvalidURIError, URI::InvalidComponentError
          nil
        end

        def parse(raw)
          return raw if raw.is_a?(Hash)

          JSON.parse(raw.to_s)
        rescue JSON::ParserError
          nil
        end

        def build(url, payload)
          todos  = Array(payload["comments"])
          usados = todos.reject { |c| c["depth"].to_i > MAX_DEPTH }.first(MAX_COMMENTS)

          {
            url:      url,
            title:    payload["title"].to_s,
            content:  render(payload, usados),
            metadata: {
              "source"          => "reddit",
              "kind"            => "thread",
              "subreddit"       => payload["subreddit"].to_s,
              "score"           => payload["score"],
              "num_comments"    => usados.size,
              "comment_total"   => todos.size,
              "truncated_depth" => MAX_DEPTH
            }
          }
        end

        def render(payload, comentarios)
          cabeca = ["# #{payload['title']}", "por **#{payload['author']}** em r/#{payload['subreddit']}"]
          cabeca << payload["selftext"] if payload["selftext"].to_s.strip.present?

          corpo = comentarios.map do |c|
            indent = "  " * c["depth"].to_i
            "#{indent}- **#{c['author']}** (#{c['score']}): #{c['body']}"
          end

          (cabeca + ["## Comentários"] + corpo).join("\n\n")
        end
      end
    end
  end
end
