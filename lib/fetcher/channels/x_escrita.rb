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
      # O caminho do DESFAZER do follow é o IRMÃO do `seguir`, não uma invenção: no bundle do X
      # (29/09/2026) o `unfollow` é `e.post("friendships/destroy", {…user_id:n,…}, {}, i)` e o
      # cliente versiona o nome em `/1.1/` fechando com `.json` — a MESMA montagem do
      # `friendships/create`, na MESMA família de endpoint.
      UNFOLLOW_PATH = "/i/api/1.1/friendships/destroy.json"
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
      # O custo do DESFAZER é o MENOR de todos, e é por isso que ele NÃO é mudo: repetir o
      # descurtir/deseguir não duplica nada no X (não cria post, não gasta a janela do Premium), mas
      # a PERGUNTA que o `Incerto` faz ("será que já desfez?") continua sem resposta, e responder
      # "não sei" sem dizer isso treina o operador a repetir em tudo. A frase diz a verdade útil:
      # repetir não faz estrago, mas a duvida continua até conferir.
      CUSTO_REPETIR_DESFAZER = "repetir o desfazer nao cria nada no X, mas a duvida continua: confira antes"
      # E o aviso é o do desfazer, e não o do postar: `AVISO_PODE_TER_SAIDO` manda "confira o POST",
      # e no `deseguir` não existe post nenhum para conferir — o que existe é o vínculo com a conta.
      AVISO_PODE_TER_SAIDO_DESFAZER = "pode TER saido no X; confira ANTES de repetir"

      # ── O TETO DO ID, e ELE FAZ PARTE DA DEFINIÇÃO ────────────────────────────
      #
      # A r4 (revisão sobre o commit `8a95260`) mediu que `18446744073709551616` (2^64) era
      # aceito como SUCESSO nos quatro fluxos. A definição anterior conferia SÓ A FORMA
      # (só dígitos, valor > 0) — e forma não é o mesmo que faixa: um id do X é um SNOWFLAKE,
      # e snowflake é por definição um inteiro de 64 bits SEM SINAL. O valor tem de caber entre
      # 1 e 2^64 − 1 = 18446744073709551615.
      #
      # Fora dessa faixa o número não é um id que o X emitiu, e a casa não pode montar
      # `/i/status/18446744073709551616`: essa url PARECE post e é o que induz o operador a
      # repetir (que cria OUTRO post). Vai `Incerto`, com o aviso de conferir.
      TETO_SNOWFLAKE = (2**64) - 1

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

      # ── O QUE É "ID UTILIZÁVEL" (a definição, e ela mora AQUI, não em cada fluxo) ──
      #
      # A DEFINIÇÃO, escrita POSITIVA — a FORMA do id, e não uma lista do que é proibido:
      #
      #   **um id do X é um snowflake: um INTEIRO DE 64 BITS SEM SINAL, MAIOR QUE ZERO.**
      #
      # Ou seja, o valor tem de caber entre 1 e `TETO_SNOWFLAKE` (2^64 − 1), em `Integer` ou
      # em `String` de dígitos (até 20; com 20, o valor tem de caber no teto). Tudo o mais é
      # recusado — float, `true`/`false`, array, hash, `nil`, e qualquer string com sinal,
      # ponto, letra, espaço ou pontuação.
      #
      # ── POR QUE POSITIVA, E NÃO A LISTA DO QUE É PROIBIDO ──
      # Esta regra já foi quebrada em QUATRO revisões seguidas, e a causa nunca foi um caso
      # faltando: foi o COMO ela estava escrita. A r1 achou `tweet_results` vazio, a r2 achou
      # `rest_id: ""`, a r3 (revisão `t_3581f942`) achou OITO formas a mais chegando ao SUCESSO
      # dos quatro fluxos: `-1`, `"-1"`, `"1.5"`, `"123abc"`, `"12 34"`, `"123/evil"`,
      # `"123?x=1"` e o float `1.5`. Cada uma era acrescentada à lista de proibidos, e a rodada
      # seguinte achava outra fora dela. A r4 achou o resto: o TETO DE 64 BITS, que é parte da
      # definição do snowflake e não estava no predicado — `2^64` saía como SUCESSO.
      #
      # **Lista do que é proibido nunca fecha** — sempre resta uma forma que ninguém pensou. Por
      # isso a lista saiu, e no lugar dela fica a ESPECIFICAÇÃO do id do X, com a forma E a
      # faixa: o snowflake é a especificação do id, e o teste de conformidade com ela é fechado
      # por construção. As oito formas do laudo da r3 não são oito casos especiais: são
      # consequência de não terem a forma do snowflake (sinal, ponto, letra, espaço,
      # pontuação) ou de nem serem número (float).
      #
      # ── POR QUE `to_i` NÃO PODE VALIDAR A FORMA (o bug medido) ──
      # A versão anterior dizia `!texto.to_i.zero?`, e `to_i` NÃO valida forma: ele lê o PREFIXO
      # numérico e ignora o resto. Por isso `"123abc".to_i == 123`, `"1.5".to_i == 1`,
      # `"12 34".to_i == 12` e `"-1".to_i == -1` — todos passavam como SUCESSO, e o `postar`
      # montava `https://x.com/i/status/123abc` (ou `/i/status/1.5`), que PARECE um post. O
      # `to_i` serve aqui só para o SEGUNDO critério (o valor), nunca para o primeiro (a forma).
      #
      # A âncora é `\A`/`\z` e não `\A`/`\Z`: `\Z` aceita a quebra de linha final, então
      # `"123\n"` — que `to_i` lê como `123` — passaria. E a string NÃO é `strip`ada antes do
      # teste: `" 123 "` não é snowflake, e `strip` aqui esconderia isso (o `strip` fica para o
      # `checa_id` da edição, que é entrada de terminal e tem outra mensagem de erro).
      #
      # O `to_i` continua sendo o que fecha a faixa, porque a string de 20 dígitos tem de caber
      # no teto: `100000000000000000000`.to_i é 10^20, que é MAIOR que 2^64 − 1. A comparação
      # é feita no inteiro, e é a mesma dos dois lados (Integer e String) — por isso a string
      # de 20 dígitos NÃO ganha um caminho mais permissivo que o inteiro.
      #
      # Tudo que não for utilizável é `Incerto` — NUNCA sucesso — porque a 2xx já prova que o
      # pedido chegou ao X (a regra de cima). Recusar aqui não é dizer "falhou": é dizer "não
      # tenho como dizer, confira antes de repetir".
      def id_utilizavel?(id)
        # snowflake de verdade: `Integer` > 0 E dentro da faixa de 64 bits sem sinal. Um float
        # NÃO entra mesmo que valha 1.5 — o id do X é inteiro, e aceitar float é aceitar um id
        # que o X nunca emitiu.
        return id.positive? && id <= TETO_SNOWFLAKE if id.is_a?(Integer)

        # String: os DOIS critérios, na ordem. Primeiro a forma (`\A\d+\z`), que é o que fecha
        # sinal/ponto/letra/espaço/pontuação; depois o valor, que é o que fecha "0", "00",
        # "-0" e o que está ACIMA de 2^64 − 1.
        id.is_a?(String) && id.match?(/\A\d+\z/) && id.to_i.positive? && id.to_i <= TETO_SNOWFLAKE
      end

      # ── O `dig` QUE NÃO ESTOURA (o achado 2 da r4, medido) ─────────────────────
      #
      # `Hash#dig` NÃO devolve `nil` para corpo inesperado: ele levanta `TypeError` no primeiro
      # nível que não é hash. Numa resposta 2xx com `result` escalar (`{"data":{"create_tweet":
      # {"tweet_results":{"result":"oops"}}}}`), `dados.dig("data", "create_tweet",
      # "tweet_results")` chega ao `"oops"` e o próximo `dig` estoura — e o `TypeError` ESCAPA
      # do canal como `TypeError`, não como `Incerto`.
      #
      # Isso é pior que a ambiguidade que o `Incerto` representa: quem chamou não descobre se o
      # post foi publicado. A casa não sabe se publicou, então tem de dizer que não sabe.
      #
      # Este é o mesmo caminho para os QUATRO fluxos (postar, responder, repostar, editar) e
      # também para a camada compartilhada (`curtir`/`apagar`): o `dig` aqui devolve `nil` para
      # qualquer tipo inesperado, e quem chama decide a partir do `nil`. A LEITURA
      # (`XConta`, `XArtigo`) também usa este `dig`, e continua `ResponseError` — a diferença
      # é o `escrita:`, não o `dig`.
      def dig_seguro(objeto, *caminho)
        return nil if caminho.empty?

        # Todo nível do caminho tem de ser hash ANTES de descer; no fim o valor sai como vier
        # (escalar, lista ou `nil`) e quem chama é que valida a forma dele.
        caminho[0...-1].each do |chave|
          return nil unless objeto.is_a?(Hash)

          objeto = objeto[chave]
        end
        objeto.is_a?(Hash) ? objeto[caminho.last] : nil
      end

      # ── O LIMITE SIMPLES E O CAMINHO LONGO (medido no bundle do X em 29/09/2026) ──────────
      #
      # O `CreateTweet` recusa acima de ~280 com o código 186 mesmo na conta Premium: o texto longo
      # vai por OUTRA operação, a `CreateNoteTweet`. O próprio cliente web decide assim
      # (`sendTweet`: `eo.tC(e, r)` → `CreateNoteTweet`, senão `CreateTweet`): nota se houver
      # richtext/mídia rica OU se o comprimento PONDERADO passar de 280 (`maxWeightedTweetLength`).
      # As `variables` são as MESMAS do CreateTweet (`e_()`: tweet_text, reply, media,
      # semantic_annotation_ids...); a resposta vem em `data.notetweet_create.tweet_results`
      # (a do curto é `data.create_tweet.tweet_results`). As `featureSwitches` das duas operações
      # no bundle são a mesma lista de 38 (o mesmo `XConversation::FEATURES` das duas).
      #
      # Peso: caractere fora dos intervalos de peso 1 do X (0-4351, 8192-8205, 8208-8223,
      # 8242-8247) conta 2 (CJK, emoji). URL NÃO é encurtada aqui (o X conta 23): a casa só pode
      # SUPERESTIMAR, e superestimar manda para o caminho longo, que aceita qualquer tamanho — o
      # erro perigoso seria subestimar e o CreateTweet devolver 186.
      LIMITE_SIMPLES = 280
      OPERACAO_CURTA = "CreateTweet"
      OPERACAO_LONGA = "CreateNoteTweet"
      # As duas operações do DESFAZER, com os nomes EXATOS que o bundle do X usa (lidos em
      # 29/09/2026; ver o bloco do desfazer, mais abaixo, que traz a citação do bundle). O
      # `queryId` NÃO fica aqui: ele rotaciona a cada deploy do X e é resolvido por nome em
      # runtime (`XQueryIdResolver`), como as outras mutações.
      OPERACAO_DESFAZER_CURTIDA = "UnfavoriteTweet"
      OPERACAO_DESFAZER_SEGUIR = "friendships/destroy"

      def peso_do_texto(texto)
        texto.each_char.sum do |c|
          o = c.ord
          (o <= 4351 || (8192..8205).cover?(o) || (8208..8223).cover?(o) || (8242..8247).cover?(o)) ? 1 : 2
        end
      end

      def texto_longo?(texto)
        peso_do_texto(texto) > LIMITE_SIMPLES
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
        longo = texto_longo?(texto)
        operacao = longo ? OPERACAO_LONGA : OPERACAO_CURTA
        chave = longo ? "notetweet_create" : "create_tweet"
        dados = begin
          graphql!(operacao, variaveis, features: XConversation::FEATURES)
        rescue Recusado, ResponseError => e
          raise e unless longo

          # Caminho longo recusado: legível, e o texto NUNCA é truncado nem reenviado pelo caminho
          # curto (que cortaria/recusaria com 186). O operador decide o que fazer.
          raise e.class, "caminho longo (#{OPERACAO_LONGA}, #{texto.length} caracteres) recusado pelo X; " \
                         "o texto NÃO foi publicado nem truncado; encurte-o ou confira se a conta tem " \
                         "posts longos: #{e.message}"
        end
        resultados = dig_seguro(dados, "data", chave, "tweet_results")
        # `tweet_results: {}` com HTTP 200: o X engoliu o post sem erro. Isto NAO e "falhou": a
        # 2xx prova que o pedido chegou, e sem o `tweet_results` a casa não sabe se o post saiu —
        # então sai como Incerto, com o aviso de conferir. Repetir às cegas aqui criava OUTRO
        # post do mesmo texto no X.
        #
        # A condição é `id_utilizavel?` e NÃO `id.nil?`: em Ruby `"", "   "` e `0` são truthy,
        # e qualquer um dos três montava uma url de aparência válida (`/i/status/`, `/i/status/0`)
        # e saía como SUCESSO. A DEFINIÇÃO (positiva: inteiro de 64 bits sem sinal, > 0) está em
        # `id_utilizavel?` — e o motivo de ela ser positiva está escrito lá.
        #
        # O `dig_seguro` é o que impede o `TypeError` de um `result` ESCALAR (`"oops"`): o
        # `Hash#dig` estoura nesse corpo, e `Incerto` é a resposta certa (achado 2 da r4).
        id = dig_seguro(resultados, "result", "rest_id")
        raise Incerto, "#{operacao}: #{CUSTO_REPETIR_POSTAR} (rest_id=#{id.inspect}); #{AVISO_PODE_TER_SAIDO}" unless
          id_utilizavel?(id)

        { "id" => id.to_s, "url" => "https://x.com/i/status/#{id}" }
      end

      # Forma medida em 2026-09-27: `{"data":{"favorite_tweet":"Done"}}`.
      def curtir(id:)
        dados = graphql!("FavoriteTweet", { "tweet_id" => id.to_s })
        # `dig_seguro` e não `dig`: um `data` escalar/lista no 2xx virava `TypeError` cru
        # (achado 2 da r4), e quem chamasse não saberia se o like saiu. Aqui o desfecho
        # continua `ResponseError` — o `curtir` confere o resultado SEMPRE, não tem ramo de
        # sucesso sem confirmação — mas a DUVIDA no formato do corpo tem de virar o erro
        # tipado do canal, nunca uma exceção que escapa.
        confirmacao = dig_seguro(dados, "data", "favorite_tweet")
        raise ResponseError, "FavoriteTweet sem confirmação (favorite_tweet=#{confirmacao.inspect})" unless confirmacao == "Done"

        { "id" => id.to_s }
      end

      # Forma medida em 2026-09-27: `data.create_retweet.retweet_results.result.rest_id` (id do repost).
      def repostar(id:)
        dados = graphql!("CreateRetweet", { "tweet_id" => id.to_s, "dark_request" => false })
        resultados = dig_seguro(dados, "data", "create_retweet", "retweet_results")
        # Mesma barreira do `postar`: `retweet_results: {}` (ou sem `rest_id`) com 2xx é o X
        # engolindo a chamada, não o X dizendo que não repostou. Repetir aqui refaz o repost.
        # E a MESMA definição de id utilizável do `postar` (`id_utilizavel?`, positiva: inteiro
        # de 64 bits sem sinal, > 0): o `rest_id: ""` que o X devolveu era aceito como sucesso, e
        # o `repostar` devolvia o id do ARGUMENTO como se o repost tivesse saído.
        repost_id = dig_seguro(resultados, "result", "rest_id")
        raise Incerto, "CreateRetweet: repetir as cegas refaz o repost (rest_id=#{repost_id.inspect}); " \
                       "#{AVISO_PODE_TER_SAIDO}" unless id_utilizavel?(repost_id)

        { "id" => id.to_s }
      end

      # Forma medida em 2026-09-27: `{"data":{"delete_tweet":{"tweet_results":{}}}}` — o `{}` é o normal aqui.
      def apagar(id:)
        dados = graphql!("DeleteTweet", { "tweet_id" => id.to_s, "dark_request" => false })
        # Mesmo `dig_seguro` do `curtir`: um `data` de tipo inesperado no 2xx virava `TypeError`
        # cru em vez do erro tipado do canal (achado 2 da r4).
        raise ResponseError, "DeleteTweet sem delete_tweet na resposta" unless
          dig_seguro(dados, "data", "delete_tweet").is_a?(Hash)

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

      # ── DESFAZER: a única mitigação que existe quando um sweep erra a seleção ────────────
      #
      # O canal escreve (`curtir`, `seguir`) e agora também DESFAZ o que escreveu. Sem isto, um
      # sweep que selecionou a pessoa errada não tinha saída: a única mitigação era conviver com o
      # erro. E o desfazer é o ÚNICO caminho barato de corrigir — apagou o post, ou a curtida está
      # lá para sempre.
      #
      # Os DOIS caminhos acima já tinham todas as guardas que o desfazer precisa; aqui cada uma é
      # a MESMA, e não uma versão frouxa do desfazer:
      #   - `gate!` (trava local) e `graphql!`/`interpreta!(..., escrita: true)`;
      #   - `id_utilizavel?`, a DEFINIÇÃO ÚNICA do id do X — que aqui é ENTRADA (vai nas
      #     `variables` do GraphQL e no formulário do REST), não saída. Fora da definição é recusado
      #     LOCAL e é `Recusado`, nunca `Incerto`: nada saiu, e a casa sabe que o X não fez nada;
      #   - `ResponseError` para a 2xx que chegou e NÃO confirma, e `Incerto` para a falha DEPOIS do
      #     envio — a mesma dúvida do `postar`, com o custo de repetir DELE (que aqui é o menor:
      #     desfazer duas vezes não muda o estado final).
      #
      # ── O CONTRATO, lido no bundle do X (29/09/2026), não inventado ────────────────────
      # Nada de nome de operação ou endpoint adivinhado. As quatro leituras foram pelo PRÓPRIO
      # resolver da casa (`XQueryIdResolver`: GET do HTML de `x.com/home` e dos bundles de JS,
      # com a sessão do jar) e nenhuma tocou escrita no X:
      #
      #   - `UnfavoriteTweet` EXISTE no bundle: chunk 137832,
      #     `{queryId:"ZYKSe-w7KEslx3JhSIk5LA", operationName:"UnfavoriteTweet",
      #       operationType:"mutation", metadata:{featureSwitches:[],fieldToggles:[]}}`. O
      #     `queryId` é resolvido por NOME em runtime (como as outras mutações — o id do X
      #     rotaciona a cada deploy), então o valor medido entra só como evidência de que a
      #     operação existe, e o cache de 404/422 continua igual.
      #   - As `variables` são `{ "tweet_id" => <id> }` — as MESMAS do `FavoriteTweet`: no bundle,
      #     `unlike(e,r){…t.graphQL(W(), { tweet_id: n, …})}` ao lado de
      #     `like(e,r){…t.graphQL(R(), { tweet_id: n, …})}`. E como os `featureSwitches` da
      #     operação são VAZIOS no bundle, nada além das `variables` é enviado.
      #   - A confirmação é `data.unfavorite_tweet == "Done"`: é o que o PRÓPRIO cliente do X
      #     compara (`"Done"!==e?.unfavorite_tweet`, "GQL Favorites: Failed to unfavorite tweet"),
      #     o espelho exato do `"Done"` do `favorite_tweet` que o `curtir` já conferia.
      #   - O `unfollow` é REST: `e.post("friendships/destroy", {…user_id:n,…}, {}, i)`, e o
      #     cliente versiona o nome em `/1.1/` fechando com `.json` (`post(e,t,r,i,n=".json")`).
      #
      # ── O QUE A CASA NÃO AFIRMA ──────────────────────────────────────────────────────
      # Nenhuma escrita real foi feita no X, então duas coisas continuam NÃO medidas: o texto
      # exato das recusas específicas do desfazer, e se o `friendships/destroy` responde além do
      # `id_str` do usuário. O teste usa a resposta espelhada do `friendships/create` (a mesma
      # família, e o `unfollow` do bundle reaproveita o MESMO parser `p` do `follow`), e a
      # conferência é a mesma do `seguir`: o `id_str` tem de ser o usuário pedido.
      def descurtir(id:)
        alvo = checa_id_de_desfazer!(id)
        dados = begin
          graphql!(OPERACAO_DESFAZER_CURTIDA, { "tweet_id" => alvo })
        rescue Incerto => e
          raise e.class, traduz_aviso_de_desfazer(e.message)
        end
        confirmacao = dig_seguro(dados, "data", "unfavorite_tweet")
        # A 2xx chegou DEPOIS do envio, então `nil`/valor inesperado aqui não é "falhou": é a mesma
        # dúvida da falha de rede, e `dig_seguro` garante que nenhum corpo de tipo inesperado
        # levante `TypeError` cru (achado 2 da r4) — o desfecho é sempre erro tipado do canal.
        raise Incerto, "#{OPERACAO_DESFAZER_CURTIDA}: 2xx sem confirmacao (unfavorite_tweet=#{confirmacao.inspect}); " \
                       "#{CUSTO_REPETIR_DESFAZER}; #{AVISO_PODE_TER_SAIDO_DESFAZER}" unless confirmacao == "Done"

        { "id" => alvo }
      end

      def deseguir(usuario_id:)
        alvo = checa_id_de_desfazer!(usuario_id)
        gate!
        headers = XGraphql.build_headers({}, {}, query_id: nil, operation: OPERACAO_DESFAZER_SEGUIR,
                                                 method: "POST", path: UNFOLLOW_PATH)
        resposta = SafeHttpClient.post("https://#{COOKIE_DOMAIN}#{UNFOLLOW_PATH}",
                                       form: { "user_id" => alvo }, headers: headers)
        dados = begin
          interpreta!(resposta, OPERACAO_DESFAZER_SEGUIR, escrita: true)
        rescue Incerto => e
          raise e.class, traduz_aviso_de_desfazer(e.message)
        end
        # Mesma conferência do `seguir`: um 2xx sem o usuário pedido é a DUVIDA (pode ter
        # desfollowed outra coisa, ou o X engoliu a chamada), não uma falha — e o `id_str` errado
        # é justamente o sinal de que algo saiu do esperado.
        raise Incerto, "#{OPERACAO_DESFAZER_SEGUIR}: 2xx sem confirmacao do usuario #{alvo} " \
                       "(id_str=#{dados.is_a?(Hash) ? dados["id_str"].inspect : dados.inspect}); " \
                       "#{CUSTO_REPETIR_DESFAZER}; #{AVISO_PODE_TER_SAIDO_DESFAZER}" unless
          dados.is_a?(Hash) && dados["id_str"].to_s == alvo

        { "usuario_id" => alvo }
      rescue SafeHttpClient::Error, SsrfGuard::Blocked => e
        falha_de_rede!(e, OPERACAO_DESFAZER_SEGUIR)
      end

      # O `interpreta!` monta o aviso de escrita com as frases do POSTAR, e as DUAS são MENTIRA
      # no desfazer: "repetir as cegas cria OUTRO post" (o desfazer não cria post nenhum) e
      # "confira o POST" (no `deseguir` não existe post para conferir — o que existe é o vínculo
      # com a conta).
      #
      # A tradução TROCA as duas frases pelo valor exato das constantes em vez de ACRESCENTAR as
      # do desfazer depois: acrescentar deixaria a frase falsa logo acima da verdadeira na mesma
      # linha, e quem lê na hora de decidir lê a primeira (foi o que a primeira rodada GREEN
      # mostrou). O resto da mensagem (o nome da operação, "resposta 2xx sem JSON utilizavel") é
      # verdade e fica.
      #
      # O `gsub` casa pelo VALOR das constantes, o que amarra a prosa ao código: se o
      # `interpreta!` mudar a frase, a troca deixa de casar e o teste do aviso falso volta a
      # falhar em vez de passar calado.
      def traduz_aviso_de_desfazer(mensagem)
        mensagem.gsub(CUSTO_REPETIR_POSTAR, CUSTO_REPETIR_DESFAZER)
                .gsub(AVISO_PODE_TER_SAIDO, AVISO_PODE_TER_SAIDO_DESFAZER)
      end

      # O id do X é ENTRADA no desfazer: ele vai para as `variables` do GraphQL e para o
      # formulário do REST. A DEFINIÇÃO é a de sempre (`id_utilizavel?`, snowflake de 64 bits sem
      # sinal, > 0) e não uma lista nova: o que muda é a CLASSE do desfecho, e por quê.
      #
      # No `postar` o id vem do X (saída) e um id ruim é `Incerto`, porque o X pode ter publicado
      # mesmo assim. Aqui o id vem do OPERADOR (entrada), a casa o confere ANTES da rede, e recusa
      # com `Recusado`: nada saiu, e a casa sabe que o X não fez nada. `Incerto` aqui seria
      # afirmar a dúvida que acabamos de desfazer.
      # A guarda olha o OBJETO QUE CHEGOU, e não a impressão dele. Converter antes de conferir
      # trocaria a definição do canal por uma regra frouxa: `id.to_s` de um objeto que só vira
      # snowflake quando impresso entraria como `String` e passaria, e a casa mandaria ao X um id
      # que ela não conferiu. `id_utilizavel?` aceita `Integer` e `String` e nada mais — então a
      # forma do id é conferida aqui, e a conversão vem DEPOIS, só para o envio.
      def checa_id_de_desfazer!(id)
        raise Recusado, "id invalido: #{id.inspect} — o desfazer quer o id NUMERICO do X " \
                        "(o mesmo das outras escritas), e nao um screen_name" unless id_utilizavel?(id)

        id.to_s
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
