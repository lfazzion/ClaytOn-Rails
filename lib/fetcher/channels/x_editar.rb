# frozen_string_literal: true

require_relative "x_escrita"

module Fetcher
  module Channels
    # Edição de um post JÁ PUBLICADO no X (conta Premium).
    #
    # ── O QUE O X FAZ, e onde isso foi medido (28/09/2026) ────────────────────────
    #
    # A edição de post publicado NÃO tem mutação própria. Varri os 649 chunks de bundle que o
    # `x.com/home` referencia (ver `scripts/proofs` e o relatório do card) e extraí 342
    # `operationName` com o regex do `XQueryIdResolver`: existem `EditDraftTweet` e
    # `EditScheduledTweet` (rascunho e agendado) e `TweetEditHistory` (a consulta de histórico),
    # e os demais `*Edit*` são de Community/Birdwatch/List/Bookmark. NENHUMA operação de edição
    # de post publicado.
    #
    # O que existe, no construtor de variáveis do `CreateTweet` (main.d0bb33e09c6a2565a.js, o
    # único literal `tweet_text:` de todo o conjunto):
    #
    #   edit_options: (isTrue("subscriptions_feature_labs_1004") ||
    #                 isTrue("responsive_web_edit_tweet_enabled")) && t.previous_tweet_id
    #                 ? { previous_tweet_id: t.previous_tweet_id }
    #                 : void 0
    #
    # Ou seja: **editar é `CreateTweet` com `edit_options.previous_tweet_id`**, e o `queryId` é o
    # MESMO do postar (`E.com_query_id("CreateTweet")`, resolvido em runtime — nada fixo aqui).
    # Sem `edit_options` a mesma chamada é um post novo; é por isso que a variável não é
    # opcional: mandá-la vazia trocaria a edição por uma postagem duplicada.
    #
    # ── O QUE A EDIÇÃO PRODUZ NO X (o que o bundle diz, e o que NÃO dá para saber sem publicar)
    #
    # O `edit_control` que volta na resposta é o mesmo objeto que o cliente do X lê
    # (main.d0bb33e09c6a2565a.js, dois trechos medidos):
    #
    #   { initial_tweet_id, edit_tweet_ids, editable_until_msecs, is_edit_eligible,
    #     edits_remaining }
    #
    # E o cliente trata `edit_tweet_ids` como a CADEIA de versões, não como o id único:
    #   - `getTweetLatestVersionId = e => e.edit_control?.edit_tweet_ids?.[len-1] || e.id_str`
    #     e o permalink canônico é montado com esse ÚLTIMO elemento;
    #   - `isEdited = ids && (ids.length > 1 || !ids.includes(id_atual))`;
    #   - `edit_revision_count = ids.length - 1` e `edit_version = ids.indexOf(rest_id)`, com
    #     `initial_tweet_id = ids[0]`;
    #   - as versões ANTIGAS são escondidas do feed (`disableEdit` sobre `ids.slice(0, -1)`).
    #
    # Duas consequências que a casa assume como contrato, e que valem até a primeira edição real
    # (o smoke é do dono, depois da revisão):
    #   1. **A edição cria um post NOVO, com id NOVO.** O `rest_id` que volta no
    #      `create_tweet.tweet_results.result` é o da nova versão; o id pedido é o
    #      `initial_tweet_id` da cadeia, não o id do texto novo.
    #   2. **O post antigo não some do ponto de vista do id**: ele é a primeira versão da cadeia
    #      e o X o esconde do feed, mas o id continua respondendo (é o `initial_tweet_id` que o
    #      próprio cliente expõe). Por isso a url devolvida aqui é a do id NOVO.
    #
    # ── A JANELA DE 1H E O NÚMERO DE EDIÇÕES ───────────────────────────────────
    # A janela de 1 hora e o número limitado de alterações vêm da ajuda do X
    # (help.x.com/en/using-x/x-premium) e o X não confia em quem pergunta: o STADO vem no
    # `edit_control` (`editable_until_msecs`, `is_edit_eligible`, `edits_remaining`). A casa não
    # recalcula a janela — ela **lê e devolve** o que o X disse, e trata `is_edit_eligible: false`
    # / `edits_remaining: 0` como recusa, em vez de tentar de novo.
    #
    # ── O QUE NÃO É SUPORTADO (por escolha, e cada uma recusada com erro tipado) ──
    #   - mídia: a edição troca só o TEXTO. `media_entities` vai vazio, como no `postar`; quem
    #     precisa mexer em imagem apaga e posta de novo (`x:apagar` + `x:postar`).
    #   - responder/hashtag/assunto: o `postar` monta essas variáveis opcionais; a edição
    #     deliberadamente NÃO as envia, para que uma edição nunca mude a topologia do post.
    #
    # MODIFICAÇÃO INLINE: nada é convertido; o texto vai como vai, para o X (mesma regra do
    # `postar`: teto de casa `MAX_CHARS`, conferência de vazamento de sessão antes da rede).
    module XEditar
      COOKIE_DOMAIN = "x.com"
      # A mutação é a do postar, então a TRAVA é a do postar: editar é postar com uma variável
      # a mais. Bucket separado só o `XArtigo` (que gasta 4 chamadas por artigo).
      BUDGET = Fetcher::Channels::XEscrita::BUDGET
      # Teto de casa, o MESMO do `postar` (25.000 desde que a conta virou Premium). Não é
      # teto do X: se o texto estourar, o X ainda pode recusar com 186.
      MAX_CHARS = Fetcher::Channels::XEscrita::MAX_CHARS
      # A operação é a do postar. Fica nomeada aqui porque é o contrato do canal, e porque o
      # teste afirma que a URL é a de `CreateTweet` — o mesmo operationName e o mesmo queryId.
      OPERACAO = "CreateTweet"
      E = Fetcher::Channels::XEscrita

      # Onde a resposta traz o que a casa devolve, a partir da raiz `data`. `edit_control` é o
      # objeto que o próprio cliente do X lê (ver o bloco do topo do arquivo).
      CAMINHO_TWEET = %w[data create_tweet tweet_results result].freeze
      CAMINHO_EDIT_CONTROL = %w[data create_tweet tweet_results result edit_control].freeze

      module_function

      # ── Interface pública ───────────────────────────────────────────────────

      # Edita o post `id:` para `texto:` e devolve
      # `{"id" => <id novo>, "id_anterior" => <id pedido>, "url", "versoes" => [...],
      #   "edicoes_restantes" => Integer, "editavel_ate_ms" => String}`.
      #
      # `id_anterior` e o `initial_tweet_id` da cadeia: o id que foi pedido. `id` é o texto NOVO
      # (o `rest_id` do CreateTweet), e é dele que sai a `url` — o permalink canônico do X é o
      # da última versão (main.d0bb33e09c6a2565a.js, `getTweetLatestVersionPermalink`).
      #
      # O `edit_control` volta ausente/null quando o X não o manda; nesse caso as três chaves de
      # estado saem `nil` em vez de valor inventado (mesma regra do `XArtigo#publicar` para
      # `tweet_id`).
      def editar(id:, texto:)
        id = checa_id(id)
        texto = texto.to_s.strip
        raise E::Recusado, "texto vazio" if texto.empty?
        raise E::Recusado, "texto com #{texto.length} caracteres (máx. #{MAX_CHARS})" if texto.length > MAX_CHARS

        E.recusa_vazamento!(texto)
        variaveis = {
          "tweet_text" => texto,
          "edit_options" => { "previous_tweet_id" => id },
          "dark_request" => false,
          "media" => { "media_entities" => [], "possibly_sensitive" => false },
          "semantic_annotation_ids" => []
        }
        dados = E.graphql!(OPERACAO, variaveis, features: Fetcher::Channels::XConversation::FEATURES)
        resultados = dados.dig("data", "create_tweet", "tweet_results")
        # `tweet_results: {}` com HTTP 200: o X engoliu a chamada sem erro. Numa edição isso
        # significa que o texto novo pode ter saído (e o post virado outra versão) sem a casa
        # ter o id: o `Restrito` é a mesma supressão que o `postar` reconhece, e a mensagem de
        # quem chamou tem de conferir o post antes de repetir.
        raise E::Restrito, "CreateTweet (edicao): X devolveu tweet_results vazio (post suprimido)" if resultados == {}

        id_novo = resultados.is_a?(Hash) ? resultados.dig("result", "rest_id") : nil
        # 2xx SEM rest_id é o caminho que chegou ao X e nao confirma: o X pode ter editado. A
        # mensagem diz isso, porque repetir às cegas edita duas vezes (e o `Incerto`, do
        # `XEscrita`, é o mesmo cuidado para a falha de rede depois do envio).
        if id_novo.nil?
          raise E::ResponseError, "CreateTweet (edicao): X nao devolveu rest_id do texto novo " \
                                  "(o post #{id} pode JA ter sido editado; confira antes de repetir)"
        end

        estado = estado_edit_control(dados.dig(*CAMINHO_EDIT_CONTROL))
        {
          "id" => id_novo.to_s,
          "id_anterior" => id,
          "url" => "https://x.com/i/status/#{id_novo}"
        }.merge(estado)
      end

      # O `edit_control` que volta na mutação tem TRÊS formas no cliente do X, e o próprio
      # bundle as normaliza para uma só (main.d0bb33e09c6a2565a.js, medido):
      #
      #   v.edit_control = c.initial ? c.initial
      #                   : c.edit?.edit_control_initial
      #                     ? { initial_tweet_id: c.edit.initial_tweet_id,
      #                         edit_tweet_ids: c.edit.edit_control_initial.edit_tweet_ids, ... }
      #                     : void 0
      #
      # Ou seja: o wire pode vir já achatado, sob `initial`, ou aninhado em
      # `edit.edit_control_initial`. Esta casa normaliza igual, e devolve `{}` quando o campo
      # não veio — NIL é melhor que valor inventado (mesma regra do `XArtigo` para `tweet_id`).
      #
      # ── O QUE AQUI É SUPOSTO, E O QUE É MEDIDO ──────────────────────────────
      # Os NOMES dos campos e a existência das três formas vêm do bundle (medido). O lugar de
      # `edit_control` NA RESPOSTA DA MUTAÇÃO `CreateTweet` é a suposição: a forma achatada vem
      # da leitura do grafo (`edit_control` é campo do tipo Tweet) e a mutação pode devolver a
      # mesma coisa ou a forma `edit.edit_control_initial`. Ler as três e devolver nil no
      # resto é o que faz a suposição inofensiva: o id novo e o id pedido saem de qualquer jeito,
      # e as chaves de estado saem nil em vez de erradas. O smoke no X (do dono, depois da
      # revisão) é o que fecha essa suposição.
      def estado_edit_control(bruto)
        return { "versoes" => nil, "edicoes_restantes" => nil, "editavel_ate_ms" => nil } unless bruto.is_a?(Hash)

        achatado = bruto["initial"].is_a?(Hash) ? bruto["initial"] : bruto
        aninhado = bruto["edit"].is_a?(Hash) ? bruto["edit"] : nil
        interno = aninhado&.fetch("edit_control_initial", nil)
        estado = interno.is_a?(Hash) ? interno : achatado
        {
          "versoes" => lista(estado["edit_tweet_ids"]),
          "edicoes_restantes" => inteiro(estado["edits_remaining"]),
          "editavel_ate_ms" => estado["editable_until_msecs"]&.to_s
        }
      end

      # Só o que é do tipo certo: um `edits_remaining` stringified no meio de um Integer
      # quebraria quem lê o JSON, e um `edit_tweet_ids` que não é lista viraria `versoes: {}`.
      def lista(valor) = valor.is_a?(Array) ? valor.map(&:to_s) : nil

      def inteiro(valor)
        return valor if valor.is_a?(Integer)
        return nil unless valor.is_a?(String) && valor.match?(/\A-?\d+\z/)

        valor.to_i
      end

      # O `id` vem do terminal (task `x:editar ID=`), então é entrada não confiável: ele vai
      # para a URL do GraphQL (via `edit_options.previous_tweet_id`) e volta em toda mensagem.
      # Só dígitos, como o `rest_id` que o X devolve. VAZIO é recusado, e não tratado como
      # "não informado": em Ruby `""` é truthy, e o `RASCUNHO=` vazio do artigo já mostrou o
      # que acontece quando isso passa (aqui, a edição viraria post novo duplicado).
      def checa_id(id)
        valor = id.to_s.strip
        raise ArgumentError, "id do post deve ser o id numerico do X (so digitos), veio #{id.inspect}" unless
          valor.match?(/\A\d+\z/)

        valor
      end
    end
  end
end
