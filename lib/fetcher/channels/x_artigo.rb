# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require_relative "registry"
require_relative "../cookie_jar"
require_relative "../host_rate_limiter"
require_relative "../safe_http_client"
require_relative "../ssrf_guard"
require_relative "x_escrita"
require_relative "x_graphql"

module Fetcher
  module Channels
    # Publicação de **X Article** (artigo longo) pelo MESMO caminho que o repo já usa para postar,
    # curtir e seguir: o GraphQL interno com os cookies da sessão (`auth_token` + `ct0`).
    # NÃO é a REST API v2 oficial (`POST /2/articles/draft` + `/2/articles/{id}/publish`), que
    # exigiria token OAuth de aplicação e plano de API — a conta aqui é de navegador, não de
    # aplicação.
    #
    # O caminho tem QUATRO chamadas, e a ordem é o contrato: o rascunho nasce vazio e o `rest_id`
    # que o X devolve é o que amarra as três seguintes.
    #
    #   1. ArticleEntityDraftCreate   -> rascunho VAZIO; devolve o `rest_id` do artigo
    #   2. ArticleEntityUpdateTitle   -> `articleEntityId` + `title`
    #   3. ArticleEntityUpdateContent -> `article_entity` + `content_state`
    #   4. ArticleEntityPublish       -> `visibilitySetting` + `conversationControl`
    #
    # ── ESTRUTURA seguida (referência `edihasaj/slash-x`, MIT, `src/twitter/articles.ts`) ──
    #   - articles.ts:93-94  `articleDraftCreate`: variáveis
    #     `{ content_state: { blocks: [], entity_map: [] }, title: '' }` — o rascunho nasce
    #     sem título e sem corpo, e o id vem em
    #     `articleentity_create_draft.article_entity_results.result.rest_id` (linhas 30-35);
    #   - articles.ts:105     `articleUpdateTitle`: `{ articleEntityId, title }` (camelCase);
    #   - articles.ts:108     `articleUpdateContent`: `{ article_entity, content_state }` — aqui a
    #     variável é SNAKE_CASE, e é a forma do GraphQL, não um descuido da referência;
    #   - articles.ts:111     `articlePublish`: `{ articleEntityId, visibilitySetting,
    #     conversationControl: { mode } }`, e o post que carrega o artigo em
    #     `articleentity_publish...result.metadata.tweet_results.result.rest_id` (linhas 36-38);
    #   - articles.ts:33-38   `rest_id` só é aceito se for String de dígitos.
    # As quatro vão por POST em `/i/api/graphql/{queryId}/{Operacao}` com
    # `{ variables, features, queryId }` no corpo, e o `queryId` é resolvido em RUNTIME por
    # operação (`XQueryIdResolver`), nunca fixo.
    #
    # ── O `content_state` ─────────────────────────────────────────────────────
    # Estilo DraftJS com chaves em **snake_case**: `blocks[]` (cada um com `data`, `text`, `key`,
    # `type`, `entity_ranges`, `inline_style_ranges`) e `entity_map[]` (as entidades não-textuais,
    # referenciadas pelo índice em `entity_ranges.key`). Formato medido no SDK de modelagem do X
    # (context-plugins/x-api-v2-python-sdk, `doc/models/article-create-draft-content-state*.md`:
    # `entities[].key` é "índice no array de entidades", `mutability` IMMUTABLE/MUTABLE/SEGMENTED,
    # `type` POST/LINK/IMAGE/EMOJI/MARKDOWN/DIVIDER/LATEX, `Style` BOLD/ITALIC/STRIKETHROUGH).
    #
    # O texto do bloco é o texto VISÍVEL, sem os marcadores: é sobre ele que os offsets de
    # `entity_ranges` e `inline_style_ranges` contam.
    #
    # O QUE ESTA CONVERSÃO **NÃO** SUPORTA (recusa com FormatoInvalido, antes de gastar trava ou
    # rede). Recusar calado seria pior: o artigo sairia publicado com o código e a tabela
    # simplesmente SUMIDOS, e ninguém leria a falha.
    #   - **bloco de código** (```…```): exigiria entidade `markdown`, com o peso do bloco
    #     (o X impõe teto de markdown por artigo, 10.000, segundo o SDK);
    #   - **tabela** (GFM com pipes): no X a tabela É `type: markdown` com a tabela dentro —
    #     não existe tipo de bloco para ela;
    #   - **imagem** (![](…)): exigiria upload de mídia (`tweet_image`) antes; este canal não sobe
    #     arquivo, só escreve texto.
    # Pin (fixar o artigo) também não entra: as fontes da missão não confirmam a operação.
    #
    # MODIFICAÇÃO INLINE: o que o texto não entende vira texto literal. '*' só vira itálico entre
    # caracteres de palavra, ao contrário do CommonMark (que exige fronteira): `user_id_str`,
    # `query_id` e `2 * 3` são texto comum neste repo, e itálico silencioso corromperia o texto.
    module XArtigo
      COOKIE_DOMAIN = "x.com"
      # Trava local PRÓPRIA: publicar um artigo são 4 chamadas de escrita, o peso de 4 posts. O
      # `scope` novo impede que o feed derrube o balde do artigo (e o contrário).
      BUDGET = { scope: "graphql_artigo", max: 4, per_hour: 20 }.freeze
      # Flags das mutações de artigo (referência: `buildArticleEntityFeatures`, features.ts:2-11).
      FEATURES = {
        "profile_label_improvements_pcf_label_in_post_enabled" => true,
        "responsive_web_profile_redirect_enabled" => false,
        "rweb_tipjar_consumption_enabled" => false,
        "verified_phone_label_enabled" => false,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled" => false,
        "responsive_web_graphql_timeline_navigation_enabled" => true
      }.freeze
      # Enums de visibilidade e de conversa (referência, articles.ts:8-9). `Public` é decisão de
      # NEGÓCIO: `x:artigo` é explícito, e artigo não publicado é rascunho.
      VISIBILIDADES = %w[Public Followers MentionedUsers CommunityTweet Subscribers].freeze
      CONVERSAS = %w[All ByInvitation Community Verified Subscribers Following].freeze
      VISIBILIDADE_PADRAO = "Public"
      CONVERSA_PADRAO = "ByInvitation"
      OPERACAO_RASCUNHO = "ArticleEntityDraftCreate"
      OPERACAO_TITULO = "ArticleEntityUpdateTitle"
      OPERACAO_CONTEUDO = "ArticleEntityUpdateContent"
      OPERACAO_PUBLICAR = "ArticleEntityPublish"
      # Onde o `rest_id` mora em cada resposta, a partir da raiz `data`. Rascunho e publicação
      # trazem o artigo aninhado em `article_entity_results.result`; título e conteúdo trazem o id
      # direto (articles.ts:30-34). O primeiro elemento é SEMPRE "data" — é a raiz da resposta, e
      # um caminho que a pulasse devolveria nil em toda chamada, com 200 do X.
      RESULTADOS = {
        OPERACAO_RASCUNHO => %w[data articleentity_create_draft article_entity_results result rest_id],
        OPERACAO_TITULO => %w[data articleentity_update_title rest_id],
        OPERACAO_CONTEUDO => %w[data articleentity_update_content_state rest_id],
        OPERACAO_PUBLICAR => %w[data articleentity_publish article_entity_results result rest_id]
      }.freeze
      # O post que carrega o artigo publicado (articles.ts:36-38).
      CAMINHO_TWEET = %w[data articleentity_publish article_entity_results result metadata
                          tweet_results result rest_id].freeze
      CABECALHOS = ["header-one", "header-two", "header-three"].freeze
      # Marcação inline, na ordem de reconhecimento. O itálico exige caractere de palavra nos dois
      # lados (por isso não casa em `2 * 3`) e `!` fica de fora: a imagem é recusada antes.
      INLINE = /
        \[(?<link_texto>[^\]\n]+)\]\((?<link_url>[^)\s]+)\)
        | \*\*(?<grosso>[^*\n]+)\*\*
        | ~~(?<riscado>[^~\n]+)~~
        | \*(?<fino>\w[^*\n]*\w|\w)\*
      /x
      E = XEscrita

      # Entrada recusada por estar no formato NÃO suportado (código, tabela, imagem) ou vazia.
      # Filha de `Channels::Error`, então o envelope do `x:*` (`XComando.executa`) a tipa sem
      # exceção crua: `{"erro", "tipo": "FormatoInvalido"}`.
      class FormatoInvalido < ::Fetcher::Channels::Error; end

      module_function

      # ── Interface pública ───────────────────────────────────────────────────

      # Publica o artigo e devolve `{"id","tweet_id","url"}`. `tweet_id` e `url` são nil quando o X
      # publica sem devolver o post que carrega o artigo: id inventado seria pior que id ausente.
      def publicar(titulo:, corpo:, visibilidade: VISIBILIDADE_PADRAO, conversa: CONVERSA_PADRAO)
        titulo = titulo.to_s.strip
        raise FormatoInvalido, "titulo do artigo vazio" if titulo.empty?

        checa_visibilidade(visibilidade, conversa)
        # A conversão valida o formato ANTES de gastar trava local ou rede; a checagem de
        # vazamento de cookie vem sobre o texto que de fato vai sair.
        estado = content_state(corpo)
        E.recusa_vazamento!(titulo)
        E.recusa_vazamento!(texto_cheio(estado))

        rascunho = rascunho!
        atualiza_titulo!(rascunho, titulo)
        atualiza_conteudo!(rascunho, estado)
        publicado = publica!(rascunho, visibilidade, conversa)

        tweet_id = published_tweet_id(publicado)
        { "id" => rascunho, "tweet_id" => tweet_id, "url" => (tweet_id ? "https://x.com/i/status/#{tweet_id}" : nil) }
      end

      # ── Conversão texto -> content_state (PURA, sem rede) ────────────────────
      #
      # Função pura: mesma entrada, mesma saída, nenhum pedido. É o que permite testar o formato
      # inteiro sem stub de sessão. O nome é o do GraphQL, e não uma reimplementação de nada
      # nosso: o `content_state` é o contrato do X, não uma escolha da casa.
      def content_state(texto)
        texto = texto.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
        recusa_formato!(texto)
        blocos = []
        paragrafo = []

        empurra_paragrafo = lambda do
          next if paragrafo.empty?

          blocos << monta_bloco("unstyled", paragrafo.join(" "))
          paragrafo = []
        end

        texto.split("\n", -1).each do |linha|
          linha = linha.sub(/\s+$/, "")
          if linha.strip.empty?
            empurra_paragrafo.call
          elsif (cabecalho = linha.match(/^(\#+)\s+(.*)$/))
            empurra_paragrafo.call
            blocos << monta_bloco(CABECALHOS[[cabecalho[1].length, 3].min - 1], cabecalho[2].strip)
          elsif (citacao = linha.match(/^>\s?(.*)$/))
            empurra_paragrafo.call
            blocos << monta_bloco("blockquote", citacao[1].strip)
          elsif (item = lista(linha))
            empurra_paragrafo.call
            blocos << monta_bloco(item[:tipo], item[:texto])
          else
            paragrafo << linha.strip
          end
        end
        empurra_paragrafo.call

        # O `entity_map` é do ARTIGO, não do bloco: as chaves de `entity_ranges` são índices nele.
        # Por isso as entidades são reindexadas aqui, na ordem em que os blocos aparecem — a
        # collecting acontece uma vez, sobre todos os blocos, e nunca dentro do bloco.
        entidades = []
        blocos.each { |bloco| reindexa_entidades!(bloco, entidades) }

        { "blocks" => blocos, "entity_map" => entidades }
      end

      # Reindexa as entidades de um bloco contra o `entity_map` do artigo. `aplica_inline` numera
      # as entidades do PRÓPRIO bloco (0, 1, 2...), então a partir do segundo bloco com link os
      # números divergiriam e o `entity_ranges.key` apontaria para a entidade errada.
      def reindexa_entidades!(bloco, entidades)
        bloco["entity_ranges"].each do |intervalo|
          local = entidade_do_bloco!(bloco, intervalo["key"])
          intervalo["key"] = entidades.length
          entidades << { "key" => entidades.length, "value" => local["value"] }
        end
        # O mapa local sai do bloco: o Hash que vai para o X tem SÓ as seis chaves do DraftJS.
        bloco.delete("_entidades")
        bloco
      end

      # Entidade local de um bloco, por índice. Vive em "_entidades" só entre a montagem do bloco
      # e a reindexação, dentro de `content_state`; nunca chega ao X.
      def entidade_do_bloco!(bloco, indice)
        bloco.fetch("_entidades").fetch(indice) do
          raise E::ResponseError, "content_state: entidade #{indice} ausente no bloco #{bloco['key']}"
        end
      end

      # `- item`/`* item`/`+ item` = não ordenada; `1. item`/`2) item` = ordenada. A linha volta
      # já sem o marcador, com o texto visível.
      def lista(linha)
        if (achado = linha.match(/^[\s]*[-*+]\s+(.*)$/))
          { tipo: "unordered-list-item", texto: achado[1].strip }
        elsif (achado = linha.match(/^[\s]*\d+[.)]\s+(.*)$/))
          { tipo: "ordered-list-item", texto: achado[1].strip }
        end
      end

      # ── As quatro chamadas ──────────────────────────────────────────────────

      # Passo 1: rascunho VAZIO (articles.ts:93-94). O X cria o artigo sem título e sem corpo; o
      # `rest_id` que volta é o que amarra título, conteúdo e publicação.
      def rascunho!
        dados = graphql!(OPERACAO_RASCUNHO,
                         { "content_state" => { "blocks" => [], "entity_map" => [] }, "title" => "" })
        rest_id!(dados, OPERACAO_RASCUNHO)
      end

      # Passo 2: título (articles.ts:105) — variável em camelCase.
      def atualiza_titulo!(id, titulo)
        confere_mesmo_artigo!(graphql!(OPERACAO_TITULO, { "articleEntityId" => id, "title" => titulo }),
                              OPERACAO_TITULO, id)
      end

      # Passo 3: corpo (articles.ts:108) — a variável do artigo é snake_case NESTE passo.
      def atualiza_conteudo!(id, estado)
        confere_mesmo_artigo!(graphql!(OPERACAO_CONTEUDO, { "article_entity" => id, "content_state" => estado }),
                              OPERACAO_CONTEUDO, id)
      end

      # Passo 4: publicar (articles.ts:111). Devolve os dados crus para o caller ler o `tweet_id`.
      def publica!(id, visibilidade, conversa)
        dados = graphql!(OPERACAO_PUBLICAR,
                         { "articleEntityId" => id, "visibilitySetting" => visibilidade,
                           "conversationControl" => { "mode" => conversa } })
        confere_mesmo_artigo!(dados, OPERACAO_PUBLICAR, id)
        dados
      end

      def published_tweet_id(dados) = digs(dados, *CAMINHO_TWEET)

      # O `rest_id` que o X devolve, conferido: só dígitos (articles.ts:30-31) e nunca vazio.
      # Sem esta conferência, um `{"data":{}}` calado passaria e a etapa seguinte mandaria
      # `articleEntityId` vazio ao X.
      def rest_id!(dados, operacao)
        id = digs(dados, *RESULTADOS.fetch(operacao))
        if id.to_s.empty?
          raise E::ResponseError, "#{operacao}: X nao devolveu rest_id do artigo (#{resumo(dados)})"
        end
        raise E::ResponseError, "#{operacao}: rest_id invalido (#{id.inspect})" unless id.match?(/\A\d+\z/)

        id
      end

      # Cada passo tem de devolver O MESMO artigo do rascunho. Sem esta conferência, um
      # `{"data":{}}` calado deixaria o artigo publicado vazio, e ninguém veria.
      def confere_mesmo_artigo!(dados, operacao, esperado)
        id = rest_id!(dados, operacao)
        return id if id == esperado

        raise E::ResponseError, "#{operacao}: X devolveu o artigo #{id}, nao o #{esperado} do rascunho"
      end

      # POST GraphQL com o `queryId` resolvido em RUNTIME por operação (`E.com_query_id`, o mesmo
      # mecanismo de `x_escrita`/`x_conta`): 404/422 é queryId velho, o X não executou nada, e a
      # casa redescobre UMA vez. Trava local e tipagem dos erros são as do `XEscrita` — inclusive
      # o `Incerto` (falha depois do envio pode ter publicado algo no X).
      def graphql!(operacao, variaveis)
        gate!
        resposta = E.com_query_id(operacao) do |query_id|
          headers = XGraphql.build_headers(variaveis, FEATURES, query_id: query_id, operation: operacao, method: "POST")
          SafeHttpClient.post("https://#{COOKIE_DOMAIN}/i/api/graphql/#{query_id}/#{operacao}",
                              json: { "variables" => variaveis, "features" => FEATURES, "queryId" => query_id },
                              headers: headers)
        end
        E.interpreta!(resposta, operacao)
      rescue SafeHttpClient::Error, SsrfGuard::Blocked => e
        E.falha_de_rede!(e, operacao)
      end

      # Trava local: sessão viva + teto PRÓPRIO do artigo (4 chamadas de escrita por artigo).
      def gate!
        CookieJar.require!(COOKIE_DOMAIN)
        raise E::RateLimited, "trava local: #{BUDGET[:max]}/min ou #{BUDGET[:per_hour]}/hora de artigo " \
                               "(scope #{BUDGET[:scope]})" if HostRateLimiter.exceeded?(COOKIE_DOMAIN, **BUDGET)
      end

      # ── Bloco DraftJS ──────────────────────────────────────────────────────

      # Mapa grupo-do-regex -> estilo, na ordem em que os grupos aparecem em `INLINE`.
      ESTILOS = [["grosso", "BOLD"], ["riscado", "STRIKETHROUGH"], ["fino", "ITALIC"]].freeze
      # Acumulador de uma passada de `aplica_inline`: os intervalos do bloco e as entidades que
      # eles referenciam. Struct em vez de Hash porque `entity_ranges` e `_entidades` não podem
      # se misturar por engano de digitação — um é para o X, o outro morre na reindexação.
      Ranges = Struct.new(:entity_ranges, :inline_style_ranges, :entidades)

      # Um bloco de texto, com a chave de 5 caracteres hex da referência
      # (`randomBytes(3).toString('hex').slice(0,5)`, markdown-to-draftjs.ts:22-26). A marcação
      # inline do texto vira `inline_style_ranges`/`entity_ranges` sobre o texto visível.
      #
      # As entidades ficam em "_entidades" (índice local do bloco) e são promovidas ao
      # `entity_map` do ARTIGO em `reindexa_entidades!`, que a chave "_entidades" apaga do bloco
      # antes de ele ir para o X — o Hash que sai tem SÓ as seis chaves do DraftJS.
      def monta_bloco(tipo, texto)
        achado = Ranges.new([], [], [])
        visivel = aplica_inline(texto.to_s, achado)
        { "data" => {}, "text" => visivel, "key" => SecureRandom.hex(3)[0, 5], "type" => tipo,
          "entity_ranges" => achado.entity_ranges, "inline_style_ranges" => achado.inline_style_ranges,
          "_entidades" => achado.entidades }
      end

      # Percorre o texto UMA vez, montando o texto visível e os intervalos ao mesmo tempo: o
      # offset é o comprimento do texto JÁ montado, então um link e um negrito no mesmo parágrafo
      # não se atropelam por pertencerem a contas diferentes.
      def aplica_inline(texto, achado)
        visivel = +""
        posicao = 0
        while (caso = INLINE.match(texto, posicao))
          achados = caso.named_captures
          visivel << texto[posicao...caso.begin(0)]

          if (rotulo = achados["link_texto"])
            inicio = visivel.length
            visivel << rotulo
            achado.entity_ranges << { "key" => achado.entidades.length, "offset" => inicio, "length" => rotulo.length }
            achado.entidades << { "value" => { "data" => { "url" => achados["link_url"], "caption" => rotulo },
                                               "mutability" => "MUTABLE", "type" => "LINK" } }
          else
            grupo, estilo = ESTILOS.find { |nome, _| achados[nome] }
            interno = achados[grupo]
            inicio = visivel.length
            visivel << interno
            achado.inline_style_ranges << { "offset" => inicio, "length" => interno.length, "style" => estilo }
          end
          posicao = caso.end(0)
        end
        visivel << texto[posicao..]
        visivel
      end

      # ── Validação de formato ───────────────────────────────────────────────

      # Todas as recusas começam com a MESMA fórmula — "formato nao suportado: <qual> (<por que>)" —
      # para que quem lê a mensagem saiba o QUE foi recusado e por quê, e não só que algo foi.
      def recusa_formato!(texto)
        raise FormatoInvalido, "corpo do artigo vazio" if texto.strip.empty?

        if texto.match?(/^ {0,3}```/)
          raise FormatoInvalido, "formato nao suportado: bloco de codigo (exigiria entidade markdown no content_state)"
        end
        if texto.lines.any? { |linha| linha.match?(/^ {0,3}\|.*\|\s*$/) }
          raise FormatoInvalido, "formato nao suportado: tabela (no X a tabela e entidade markdown, nao bloco)"
        end
        if texto.match?(/!\[[^\]\n]*\]\([^)\s]*\)/)
          raise FormatoInvalido, "formato nao suportado: imagem (exigiria upload de midia, tweet_image)"
        end
        nil
      end

      def checa_visibilidade(visibilidade, conversa)
        raise ArgumentError, "visibilidade deve ser uma de: #{VISIBILIDADES.join(', ')}" unless
          VISIBILIDADES.include?(visibilidade.to_s)
        raise ArgumentError, "conversa deve ser uma de: #{CONVERSAS.join(', ')}" unless
          CONVERSAS.include?(conversa.to_s)
        nil
      end

      # O texto que vai para o X, para a conferência de vazamento de cookie.
      def texto_cheio(estado)
        estado["blocks"].map { |bloco| bloco["text"] }.join("\n")
      end

      def digs(dados, *caminho)
        caminho.reduce(dados) { |no, passo| no.is_a?(Hash) ? no[passo] : nil }
      end

      # Resumo curto da resposta para a mensagem de erro: o corpo inteiro pode ser enorme.
      def resumo(dados) = JSON.generate(dados.to_s[0, 200])
    end
  end
end
