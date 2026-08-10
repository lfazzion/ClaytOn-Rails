# frozen_string_literal: true

require "json"
require "time"
require "uri"
require_relative "registry"
require_relative "../browser_session"
require_relative "../cookie_jar"
require_relative "../host_rate_limiter"
require_relative "../safe_http_client"

module Fetcher
  module Channels
    # Post do X (Twitter) por espelho público, sem credencial nenhuma.
    #
    # Medido em 04/08/2026 deste IP, com controle: `x.com/jack/status/20` deslogado
    # devolve HTTP 200 com 163 KB de casca de SPA e SEM o texto do post; o mesmo
    # post pelo espelho devolve o texto, o autor e os contadores. É a mesma forma
    # do RSS — o caminho que serve sem identidade — e por isso vem antes das outras
    # duas portas do X: a API oficial virou pay-per-use em 06/02/2026 (~US$ 0,005
    # por post lido, tier gratuito fechado para contas novas) e o caminho por
    # cookie de sessão (`auth_token`/`ct0`) cabe no jar mas põe a conta em risco.
    #
    # Espelho é infraestrutura de terceiro: pode sumir, e saber o que se lê passa
    # por ele. `X_MIRROR_HOST` troca de espelho sem tocar em código.
    #
    # Só URL de post. Perfil, busca e home devolvem nil e caem no caminho comum.
    module X
      class NotFound < Error; end

      # Handle que não é handle não pode virar navegação: `x.com/<frase do
      # usuário>` abriria página de perfil inexistente e gastaria Chrome (e cota
      # da conta do dono) para ler um 404.
      class InvalidHandle < Error
        def initialize(bruto)
          super("#{bruto.inspect} não é um perfil do X — o handle tem 1 a 15 caracteres [A-Za-z0-9_]")
        end
      end

      # Rajada no X é assinatura de bot, e quem responde por ela é a CONTA
      # PESSOAL do dono (a sessão é dele), não só o IP. Estourar o teto é erro
      # nomeado; devolver lista vazia faria o modelo concluir "esse perfil não
      # tem posts".
      class RateLimited < Error
        def initialize(host, budget = TIMELINE_BUDGET)
          scope_suffix = budget[:scope] ? " [#{budget[:scope]}]" : ""
          super("rate limit local: #{host} atingiu #{budget[:max]} leitura(s)/min " \
                "ou #{budget[:per_hour]}/hora#{scope_suffix} — repita daqui a pouco")
        end
      end

      # Página que não deu para ler NÃO é perfil sem posts. Deslogado o x.com
      # devolve casca de SPA (medido em 04/08: 163 KB sem o texto), e seletor que
      # mudou devolve zero artigos — os dois são indistinguíveis de "não postou
      # nada" se virarem lista vazia.
      class TimelineFailed < Error
        SEM_ARTIGO = "veio sem nenhum post — sessão não aplicada, perfil vazio ou seletor mudou"
        # Sintoma diferente, causa diferente: aqui os artigos ESTÃO na página e
        # nenhum entregou permalink de post. Repost de terceiro tem permalink do
        # X (o do autor original) e passaria, então isso não é "timeline só de
        # repost" — é o link do carimbo de hora com outro nome.
        SEM_PERMALINK = "trouxe artigos e nenhum permalink de post legível — o seletor do link mudou " \
                        "ou a página não é a timeline"

        def initialize(sintoma = SEM_ARTIGO)
          super("timeline de x.com #{sintoma}")
        end
      end

      class SearchFailed < Error
        SEM_PERMALINK = "trouxe artigos e nenhum permalink de post legível — o seletor do link mudou " \
                        "ou a página não é a da busca"

        def initialize(sintoma = "veio ilegível — o seletor mudou ou a página não é a da busca")
          super("busca de x.com #{sintoma}")
        end
      end

      DEFAULT_MIRROR = "api.fxtwitter.com"
      # `/i/status/123` é a forma sem autor que o próprio X gera ao compartilhar.
      STATUS_PATH = %r{\A/(?<user>[A-Za-z0-9_]{1,15}|i)/status(?:es)?/(?<id>\d+)}
      SUMMARY_CHARS = 4_000

      HANDLE = /\A[A-Za-z0-9_]{1,15}\z/
      COOKIE_DOMAIN  = "x.com"
      CANONICAL_HOST = "x.com"
      # Dois caminhos, dois custos, dois baldes. O espelho (`fetch`) não usa a
      # sessão do dono e usa o teto da casa; a timeline e a busca usam, e são elas
      # que precisam de freio. Um balde só fazia o extract de um permalink derrubar
      # a leitura de timeline/busca do bot — medido em 06/08.
      #
      # 4/min com 30/h para cada serviço mantém o teto da conta em ~60/h agregado,
      # com folga para bot e reader caírem no mesmo minuto. Os 30 saem da nossa demanda
      # medida (nada agendado lê o X), NÃO de medida da tolerância do X.
      TIMELINE_BUDGET = { scope: "timeline", max: 4, per_hour: 30 }.freeze
      SEARCH_BUDGET   = { scope: "search", max: 4, per_hour: 30 }.freeze
      MIRROR_BUDGET   = { scope: "mirror", max: HostRateLimiter::MAX_PER_WINDOW }.freeze

      # Orçamento do caminho que o `/internal/extract` usa: permalink por espelho.
      def self.extract_budget = MIRROR_BUDGET
      # Teto de posts por leitura. Conservador porque cada passada de rolagem é
      # mais tempo com a sessão do dono aberta numa página que conta interação.
      MAX_RESULTADOS = 20
      # Passadas totais do laço de leitura. MEDIDO AO VIVO em 05/08/2026 com a
      # sessão do dono: as primeiras passadas são gastas só esperando a SPA
      # hidratar (a primeira leitura devolve ZERO artigo; aos ~6s a mesma página
      # tem quatro), então o orçamento de ROLAGEM não pode ser comido por isso.
      # Passada de espera não faz requisição; só a de rolagem faz.
      ULTIMA_PASSADA = 6
      # Quanto esperar entre uma leitura vazia e a próxima, enquanto a página não
      # hidrata. 1s por passada dá uma folga da ordem dos ~6s medidos em 05/08.
      HYDRATION_PAUSE = 1.0
      SCROLL_PASSES = 3
      # Mesma incerteza: sem medição, meio segundo é o suficiente para um lote de
      # itens virtualizados renderizar sem virar espera longa com a página aberta.
      SCROLL_PAUSE = 0.5

      # Extração da TIMELINE. Seletores VERIFICADOS AO VIVO em 05/08/2026 contra
      # o perfil real, com a sessão do dono: `article[data-testid="tweet"]` achou
      # 4 artigos, o `<a>` do `<time>` entregou permalink de post em todos, e o
      # `[data-testid="User-Name"]` trouxe o handle. Ainda assim cada campo tem
      # try/catch próprio: o X reempacota o front sem avisar, e seletor que mudou
      # de nome tem que virar campo nulo, nunca exceção que derruba a leitura
      # inteira. É a mesma forma do `SEARCH_JS` do Reddit.
      #
      # O permalink sai do `<a>` que CONTÉM o `<time>` — é o link do carimbo de
      # hora, o único que aponta para o post em si; os outros `a[href*="/status/"]`
      # de um artigo são do post citado ou do "ver thread". Devolvemos o `href`
      # absoluto e é o Ruby que decide o que é do perfil pedido: reescrever host
      # aqui produziria URL do X que não existe para post promovido.
      #
      # Heredoc com terminador entre aspas: `\n` e `\d` precisam chegar ao
      # navegador como estão.
      TIMELINE_JS = <<~'JS'
        (function () {
          function txt(el) {
            try { return el && el.innerText != null ? el.innerText.trim() : null; } catch (e) { return null; }
          }
          function permalink(art) {
            try {
              var as = art.querySelectorAll('a[href*="/status/"]');
              var reserva = null;
              for (var i = 0; i < as.length; i++) {
                if (!reserva) reserva = as[i].href;
                if (as[i].querySelector("time")) return as[i].href;
              }
              return reserva;
            } catch (e) { return null; }
          }
          function quando(art) {
            try {
              var t = art.querySelector("time");
              return t ? t.getAttribute("datetime") : null;
            } catch (e) { return null; }
          }
          function autor(art) {
            try {
              var t = txt(art.querySelector('[data-testid="User-Name"]'));
              return t ? t.split("\n")[0].trim() : null;
            } catch (e) { return null; }
          }
          // Post do tipo "Article" (formato longo) NAO tem [data-testid="tweetText"]:
          // medido ao vivo em 05/08/2026, o post fixado voltava com texto nulo enquanto
          // titulo e chamada estavam visiveis. A reserva clona o artigo e REMOVE os
          // blocos conhecidos (cabecalho, avatar, barra de acoes) em vez de tentar
          // adivinhar onde o texto esta — assim nao depende do idioma da interface,
          // que muda com o cookie `lang`.
          function reserva(art) {
            try {
              var c = art.cloneNode(true);
              var lixo = ["socialContext", "User-Name", "Tweet-User-Avatar", "caret",
                          "reply", "retweet", "like", "bookmark", "app-text-transition-container"];
              for (var i = 0; i < lixo.length; i++) {
                var nos = c.querySelectorAll('[data-testid="' + lixo[i] + '"]');
                for (var j = 0; j < nos.length; j++) { if (nos[j].parentNode) nos[j].parentNode.removeChild(nos[j]); }
              }
              var t = (c.innerText || "").replace(/\s+/g, " ").trim();
              return t.length > 0 ? t.slice(0, 600) : null;
            } catch (e) { return null; }
          }
          function contador(art, nome) {
            try {
              var el = art.querySelector('[data-testid="' + nome + '"]');
              if (!el) return null;
              return { label: el.getAttribute("aria-label"), text: txt(el) };
            } catch (e) { return null; }
          }
          try {
            var out = [];
            var arts = document.querySelectorAll('article[data-testid="tweet"]');
            for (var i = 0; i < arts.length; i++) {
              var a = arts[i];
              out.push({
                url: permalink(a),
                text: txt(a.querySelector('[data-testid="tweetText"]')),
                text_reserva: reserva(a),
                author: autor(a),
                created_at: quando(a),
                likes: contador(a, "like"),
                retweets: contador(a, "retweet"),
                replies: contador(a, "reply")
              });
            }
            var empty = document.querySelector('[data-testid="empty_state_header_text"]') != null;
            return JSON.stringify({ items: out, empty: empty });
          } catch (e) {
            return null;
          }
        })()
      JS

      SCROLL_JS = <<~'JS'
        (function () {
          try { window.scrollTo(0, document.body.scrollHeight); return true; } catch (e) { return false; }
        })()
      JS

      # Sufixos que o X usa no texto do contador. "mil"/"mi" é a forma pt-BR,
      # "K"/"M" a inglesa. O que não estiver aqui vira nil — chutar a ordem de
      # grandeza seria pior que não medir.
      ABREVIACOES = { "mil" => 1_000, "mi" => 1_000_000, "bi" => 1_000_000_000,
                      "k" => 1_000, "m" => 1_000_000, "b" => 1_000_000_000 }.freeze

      class << self
        def call(url:, response: nil)
          alvo = status_from(url)
          return nil if alvo.nil?

          build(url, fetch(alvo))
        end

        # Público de propósito, como nos outros canais: é por aqui que o teste
        # entra com um payload de mentira, sem rede.
        def build(url, payload)
          tweet = payload.is_a?(Hash) ? payload["tweet"] : nil
          raise NotFound, "post não encontrado, removido ou de conta protegida" if tweet.blank?

          autor = tweet["author"] || {}
          {
            url:      tweet["url"].presence || url,
            title:    titulo(tweet, autor),
            content:  render(tweet, autor),
            metadata: {
              "source"         => "x",
              "kind"           => "tweet",
              "author"         => autor["name"].to_s,
              "screen_name"    => autor["screen_name"].to_s,
              # Contador ausente fica nil, NUNCA 0: zero é uma medição, ausência não.
              "likes"          => tweet["likes"],
              "retweets"       => tweet["retweets"],
              "replies"        => tweet["replies"],
              "views"          => tweet["views"],
              "lang"           => tweet["lang"].to_s,
              "created_at"     => iso(tweet["created_timestamp"]),
              "is_reply"       => tweet["replying_to"].present?,
              "has_quote"      => tweet["quote"].present?,
              "community_note" => tweet["community_note"].present?
            }
          }
        end

        # Posts recentes de um PERFIL, renderizados no Chrome com a sessão do
        # dono. Não é busca por assunto: busca de timeline no X não tem caminho
        # gratuito e o GraphQL exige `x-client-transaction-id`, gerado por
        # algoritmo client-side que as bibliotecas que o reimplementam vivem
        # quebrando. Por isso navegador REAL — o Chrome executa o JS oficial e
        # gera o cabeçalho sozinho.
        #
        # Mesmo contrato de `Youtube.search` e `Reddit.search`: Array de Hash de
        # chaves STRING.
        def timeline(user:, limit: 10)
          handle = handle!(user)
          # Portões antes de gastar Chrome, na ordem do mais barato: sem sessão
          # não há caminho (deslogado o x.com devolve casca de SPA), e o
          # limitador INCREMENTA, então só pode correr depois do que pode abortar.
          CookieJar.require!(COOKIE_DOMAIN)
          raise RateLimited, COOKIE_DOMAIN if HostRateLimiter.exceeded?(COOKIE_DOMAIN, **TIMELINE_BUDGET)

          BrowserSession.with_page("https://#{CANONICAL_HOST}/#{handle}") do |page|
            from_timeline_page(page: page, user: handle, limit: limit)
          end
        end

        # Público pelo mesmo motivo de `Reddit.from_search_page`: é por aqui que
        # o teste entra sem precisar de um Chrome.
        def from_timeline_page(page:, user:, limit: MAX_RESULTADOS)
          handle = handle!(user)
          n = clamp_limit(limit)
          res = coletar(page, n)
          brutos = res[:items]
          # Zero artigos não é "perfil sem posts" — ver `TimelineFailed`.
          raise TimelineFailed if brutos.empty?

          lidos = brutos.filter_map { |bruto| item(bruto) }
          # Ler artigo e não tirar permalink de nenhum é página ilegível, não
          # "perfil sem posts" — ver `SEM_PERMALINK`. Sem este portão, seletor de
          # link trocado devolveria [] com cara de resposta, que é a mesma falha
          # silenciosa que o portão de cima evita.
          raise TimelineFailed, TimelineFailed::SEM_PERMALINK if lidos.empty?

          # Depois do filtro de AUTOR a lista pode ficar vazia sem ser falha:
          # timeline só de repost de terceiro é isso mesmo, e aí quem esvaziou
          # foi o filtro, não a página.
          lidos.select { |lido| lido["screen_name"].casecmp?(handle) }.first(n)
        end

        # Busca por assunto no X (Twitter), renderizada no Chrome com a sessão do
        # dono.
        #
        # Mesmo contrato de `Youtube.search` e `Reddit.search`: Array de Hash de
        # chaves STRING.
        def search(query:, limit: 10)
          termo = query.to_s.strip
          return [] if termo.empty?

          CookieJar.require!(COOKIE_DOMAIN)
          raise RateLimited.new(COOKIE_DOMAIN, SEARCH_BUDGET) if HostRateLimiter.exceeded?(COOKIE_DOMAIN, **SEARCH_BUDGET)

          BrowserSession.with_page(search_url(termo)) do |page|
            from_search_page(page: page, limit: limit)
          end
        end

        # Público pelo mesmo motivo de `from_timeline_page`: é por aqui que o
        # teste entra sem precisar de um Chrome.
        def from_search_page(page:, limit: MAX_RESULTADOS)
          n = clamp_limit(limit)
          res = coletar(page, n, error_class: SearchFailed)
          brutos = res[:items]
          if brutos.empty?
            return [] if res[:empty]

            raise SearchFailed
          end

          lidos = brutos.filter_map { |bruto| item(bruto) }
          raise SearchFailed, SearchFailed::SEM_PERMALINK if lidos.empty?

          lidos.first(n)
        end

        # Devolve [usuario, id] ou nil. `nil` significa "não é post meu" — perfil,
        # busca e home seguem pelo caminho comum.
        def status_from(url)
          uri = URI.parse(url.to_s)
          return nil unless host_do_x?(uri.host)

          casou = STATUS_PATH.match(uri.path.to_s)
          casou && [casou[:user], casou[:id]]
        rescue URI::InvalidURIError
          nil
        end

        private

        def search_url(termo)
          "https://#{CANONICAL_HOST}/search?#{URI.encode_www_form(q: termo, f: 'live', src: 'typed_query')}"
        end

        # Aceita com e sem "@" e valida o formato ANTES de qualquer gasto.
        def handle!(bruto)
          limpo = bruto.to_s.strip.delete_prefix("@")
          raise InvalidHandle, bruto unless limpo.match?(HANDLE)

          limpo
        end

        def texto(bruto)
          principal = bruto["text"]
          return principal if principal.is_a?(String) && !principal.strip.empty?

          reserva = bruto["text_reserva"]
          reserva if reserva.is_a?(String) && !reserva.strip.empty?
        end

        def clamp_limit(limit)
          [[limit.to_i, 1].max, MAX_RESULTADOS].min
        end

        # Lê a página, rola, lê de novo — parando assim que juntar o que foi
        # pedido ou quando a contagem para de crescer. A chave do dedup é o
        # permalink; item sem permalink entra pelo próprio hash, porque ele ainda
        # conta como "vi um artigo" (é o que separa página ilegível de perfil sem
        # post).
        def coletar(page, alvo, error_class: TimelineFailed)
          vistos = {}
          rolagens = 0
          vazio_detectado = false

          (ULTIMA_PASSADA + 1).times do |passada|
            lote_data = parse_lote(page.evaluate(TIMELINE_JS))
            raise error_class unless lote_data.is_a?(Hash)

            lote = lote_data[:items]
            vazio_detectado ||= lote_data[:empty]

            antes = vistos.size
            lote.each { |bruto| vistos[bruto.is_a?(Hash) ? (bruto["url"] || bruto) : bruto] ||= bruto }
            # `vistos.any?` no meio da condição é o conserto de 05/08: com a lista
            # AINDA vazia, "a contagem não cresceu" não significa que acabou —
            # significa que a página não hidratou. Ver `aguardar_hidratacao`.
            break if vistos.size >= alvo || (vistos.any? && vistos.size == antes) || (vazio_detectado && vistos.empty?) || passada == ULTIMA_PASSADA

            # Enquanto não veio artigo nenhum, rolar não adianta: não há lista
            # virtualizada para avançar, só React que ainda não montou. Espera —
            # e a espera tem orçamento SEPARADO da rolagem, senão uma página lenta
            # gastaria em hidratação o que deveria render posts. `SCROLL_PASSES`
            # continua sendo o teto de rolagens, que é o que custa requisição.
            if vistos.empty?
              aguardar_hidratacao
            else
              break if rolagens >= SCROLL_PASSES

              rolar(page)
              rolagens += 1
            end
          end
          { items: vistos.values, empty: vazio_detectado }
        end

        # `x.com` e SPA React: o `go_to` volta quando o documento carrega, ANTES de
        # a timeline montar. MEDIDO AO VIVO em 05/08/2026 com a sessao do dono: a
        # primeira leitura devolve ZERO artigo e, seis segundos depois, a MESMA
        # pagina tem quatro. Sem esta espera, a leitura inteira levantava
        # `TimelineFailed` com sessao valida e perfil cheio.
        #
        # Espera passiva de proposito: nao ha requisicao nova, so tempo — entao ela
        # nao consome cota da conta do dono nem provoca o alvo. O `old.reddit.com`
        # nao precisa disto porque e HTML renderizado no servidor.
        def aguardar_hidratacao
          Kernel.sleep(HYDRATION_PAUSE)
        end

        def rolar(page)
          page.evaluate(SCROLL_JS)
          # A lista é virtualizada: sem pausa o próximo `evaluate` lê o mesmo DOM
          # de antes da rolagem e a leitura termina cedo achando que acabou.
          Kernel.sleep(SCROLL_PAUSE)
        rescue StandardError => e
          # Rolagem que falhou não invalida o que já foi lido.
          Rails.logger.warn "[Fetcher::Channels::X] rolagem falhou: #{e.class}: #{e.message}"
        end

        def parse_lote(bruto)
          parsed = bruto.is_a?(Array) || bruto.is_a?(Hash) ? bruto : JSON.parse(bruto.to_s)
          if parsed.is_a?(Array)
            { items: parsed, empty: false }
          elsif parsed.is_a?(Hash)
            {
              items: Array(parsed["items"] || parsed[:items]),
              empty: !!(parsed["empty"] || parsed[:empty])
            }
          else
            nil
          end
        rescue JSON::ParserError
          nil
        end

        # Só decodifica. O descarte por autor (repost e post promovido de
        # terceiro aparecem na timeline e não são posts deste perfil) mora no
        # chamador de propósito: aqui, "não é do perfil" e "não deu para ler"
        # virariam o mesmo nil, e é justamente essa diferença que separa
        # resposta legítima de página ilegível.
        def item(bruto)
          return nil unless bruto.is_a?(Hash)

          url, autor_do_post = permalink(bruto["url"])
          return nil if url.nil?

          {
            "url"         => url,
            # nil quando o elemento não estava lá (post só de imagem, ou seletor
            # que mudou); "" continua sendo "" quando o texto veio vazio de fato.
            # A reserva só entra quando o `tweetText` não veio — post do tipo
            # "Article" não o tem (medido em 05/08 no post fixado). Nunca sobrepõe
            # o texto normal: a reserva carrega sobras de layout que o `tweetText`
            # não tem.
            "text"        => texto(bruto),
            "author"      => (bruto["author"].strip.presence if bruto["author"].is_a?(String)),
            "screen_name" => autor_do_post,
            "created_at"  => iso8601(bruto["created_at"]),
            # Contador ilegível é nil, NUNCA 0: zero seria um post sem nenhuma
            # interação, que é outro fato.
            "likes"       => contador(bruto["likes"]),
            "retweets"    => contador(bruto["retweets"]),
            "replies"     => contador(bruto["replies"])
          }
        end

        # Devolve [url canônica, handle do autor] ou nil. Item cujo permalink não
        # é do X é descartado: reescrever o host de um link promovido (t.co, por
        # exemplo) produziria uma URL do X que não existe — o Reddit já paga essa
        # conta em `permalink`.
        def permalink(bruto)
          uri = URI.parse(bruto.to_s)
          return nil unless host_do_x?(uri.host)

          casou = STATUS_PATH.match(uri.path.to_s)
          return nil if casou.nil? || casou[:user] == "i"

          # Reconstruída a partir dos grupos: corta sufixo de mídia
          # (`/photo/1`), query de rastreio e o host legado.
          ["https://#{CANONICAL_HOST}/#{casou[:user]}/status/#{casou[:id]}", casou[:user]]
        rescue URI::InvalidURIError, URI::InvalidComponentError
          nil
        end

        def iso8601(bruto)
          Time.iso8601(bruto.to_s).utc.iso8601
        rescue ArgumentError, TypeError
          nil
        end

        # O `aria-label` do botão traz o número EXATO ("1234 Likes"); o texto
        # visível é abreviado ("1.2K", "3,4 mil") e só dá para decodificar em
        # aproximação. Preferimos o exato e caímos na aproximação; o que não der
        # para ler fica nil.
        #
        # Contador zerado do X não mostra número nenhum, e isso é
        # indistinguível de "não consegui ler" — nil nos dois casos, porque
        # inventar o 0 é justamente o que a regra da casa proíbe.
        def contador(bruto)
          return nil unless bruto.is_a?(Hash)

          exato(bruto["label"]) || exato(bruto["text"]) || abreviado(bruto["text"])
        end

        def exato(bruto)
          token = bruto.to_s[/\d[\d.,]*/]
          return nil if token.nil?
          # Só inteiro puro ou grupos de milhar completos. "1.2" cairia aqui como
          # 12 — é decimal de abreviação, e quem trata é `abreviado`.
          return nil unless token.match?(/\A\d+\z/) || token.match?(/\A\d{1,3}(?:[.,]\d{3})+\z/)

          token.delete(".,").to_i
        end

        def abreviado(bruto)
          casou = /\A(\d+(?:[.,]\d+)?)\s*(mil|mi|bi|k|m|b)\b/i.match(bruto.to_s.strip)
          fator = casou && ABREVIACOES[casou[2].downcase]
          return nil if fator.nil?

          (casou[1].tr(",", ".").to_f * fator).round
        end

        def host_do_x?(host)
          h = host.to_s.downcase.delete_prefix("www.")
          %w[x.com twitter.com mobile.twitter.com].include?(h)
        end

        def mirror
          ENV.fetch("X_MIRROR_HOST", DEFAULT_MIRROR)
        end

        # Passa pelo SafeHttpClient como manda a casa: revalidação por hop e teto
        # de bytes. O host é fixo, mas o caminho carrega dados de uma URL não
        # confiável — e o regex de `STATUS_PATH` é o que garante que só usuário e
        # dígitos chegam aqui.
        def fetch((user, id))
          resposta = SafeHttpClient.get("https://#{mirror}/#{user}/status/#{id}")
          raise NotFound, "post não encontrado, removido ou de conta protegida" if resposta.status == 404
          raise SafeHttpClient::Error, "espelho do X devolveu HTTP #{resposta.status}" if resposta.status >= 400

          JSON.parse(resposta.body.to_s)
        rescue JSON::ParserError
          raise SafeHttpClient::Error, "espelho do X devolveu resposta que não é JSON"
        end

        def titulo(tweet, autor)
          nome = autor["name"].presence || autor["screen_name"].presence || "desconhecido"
          "Post de #{nome} (@#{autor['screen_name']})".squeeze(" ").strip
        end

        def render(tweet, autor)
          partes = ["# Post de #{autor['name']} (@#{autor['screen_name']})", corpo(tweet)]

          citado = tweet["quote"]
          if citado.present?
            quem = citado["author"] || {}
            partes << "## Citando @#{quem['screen_name']}\n\n#{corpo(citado)}"
          end

          # Nota da comunidade é correção de contexto sobre o próprio post. Omiti-la
          # entregaria a afirmação sem o que a contesta.
          nota = texto_de(tweet["community_note"]).strip
          partes << "## Nota da comunidade\n\n#{nota}" if nota.present?

          partes << rodape(tweet)
          partes.compact_blank.join("\n\n")
        end

        # `raw_text` NÃO é String: o espelho devolve
        # `{display_text_range, facets, text}` — conferido ao vivo. O teste com
        # fixture inventado passava mesmo com o tipo errado; só a prova ao vivo
        # pegou (`undefined method 'strip' for an instance of Hash`).
        def corpo(tweet)
          texto = texto_de(tweet["raw_text"]).presence || tweet["text"].to_s
          texto = texto.strip
          texto.length > SUMMARY_CHARS ? "#{texto[0, SUMMARY_CHARS]}…" : texto
        end

        # Aceita String, Hash com "text", ou nada — o espelho já mudou de forma uma
        # vez e o canal não pode quebrar por isso.
        def texto_de(campo)
          case campo
          when String then campo
          when Hash   then campo["text"].to_s
          end.to_s
        end

        def rodape(tweet)
          numeros = {
            "curtidas" => tweet["likes"], "reposts" => tweet["retweets"],
            "respostas" => tweet["replies"], "visualizações" => tweet["views"]
          }.filter_map { |rotulo, valor| "#{valor} #{rotulo}" unless valor.nil? }

          [numeros.join(" · "), iso(tweet["created_timestamp"])].compact_blank.join(" — ")
        end

        def iso(timestamp)
          timestamp && Time.at(timestamp.to_i).utc.iso8601
        end
      end
    end
  end
end
