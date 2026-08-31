# frozen_string_literal: true

require "net/http"
require "json"
require "digest"
require "set"
require_relative "../services/search_api_cache"

class WebSearchTool < ToolBase
  description "Pesquisa web em tempo real via SearXNG. Use para fatos atuais, notícias, " \
              "preços, eventos, documentação externa — APENAS quando as tools internas não cobrirem. " \
              "NÃO indexa permalink de YouTube, Reddit nem X/Twitter (vídeo, thread, post, timeline) " \
              "— para ler dentro dessas plataformas use platform_search. " \
              "Passe time_range='day'|'week'|'month'|'year' para perguntas sobre 'último', 'agora', " \
              "'hoje', 'esta semana' (filtra por recência; senão buscador prioriza relevância e pode " \
              "devolver artigo antigo com bom SEO)."

  param :query, type: :string,  desc: "Consulta de busca (1-200 chars, não pode ser vazia)", required: true
  param :limit, type: :integer, desc: "Número máximo de resultados (1-5, padrão 5)", required: false
  param :time_range, type: :string,
        desc: "Filtro de recência: day|week|month|year. Use para último/agora/hoje/esta-semana.",
        required: false
  # F2 do plano v2 (30/08/2026): parâmetro `type` opcional no schema MCP e na
  # tool. Quando presente e ≠ "auto", a LLM do perfil classifica a QUERY e o
  # Rails escolhe o provedor — specialty_first. Quando ausente ou "auto",
  # comportamento atual preservado (local_first + fallback router por regex).
  # O enum é o mesmo do contrato MCP (lib/mcp_server/tools/web_search.rb).
  param :type, type: :string,
        desc: "Tipo da query p/ o router escolher provedor (news|entity|academic|factual|code|auto). " \
              "Default 'auto' = comportamento atual (SearXNG → fallback por regex).",
        required: false

  BASE_URL          = ENV.fetch("SEARXNG_URL", "http://searxng:8080/search")
  # F1 do plano v2 (30/08/2026): payload magro. 400 chars por snippet era a
  # tolerância antiga; o L5 mediu que 200 basta para a manchete caber, e o
  # snipamento menor reduz drasticamente o espaço que UGC/snippet ocupa no
  # contexto da conversa (D4 do plano). Teto UNICO aqui — MCP e Discord usam
  # a mesma constante (camada única no cleitin, plano v2 D6).
  CONTENT_MAX_CHARS = 200
  # F1: teto de 5 hits por busca (era 10). Plataforma única, sem fan-out
  # paralelo — `SearchApiRouter` também clampa em MAX_RESULTS=5.
  MAX_LIMIT         = 5
  # F3c do plano-fase2 (30/08/2026): TTL do cache de RESULTADO é derivado
  # do tipo+time_range via `SearchApiCache.ttl_for`. Não há constante de
  # TTL fixa aqui — o `run` chama `SearchApiCache.write` que decide.
  # F3c: debounce de VAZIO (não cache de conteúdo). TTL curto e fixo de 60s
  # é separado da tabela de tipos — absorve rajada de tool calls do mesmo
  # turno sem servir "não achei nada" congelado por 15min. NÃO passa pelo
  # `SearchApiCache.write` (que rejeita `[]` por contrato do F3c item 5 do
  # brief): é gravação direta, fim único da WEBSEARCH_TOOL.
  EMPTY_CACHE_TTL   = 1.minute
  ALLOWED_TIME_RANGES = %w[day week month year].freeze

  # F2 do plano v2 (30/08/2026): mapa type → provider. Tabela é o
  # CONTRATO com o schema MCP (lib/mcp_server/tools/web_search.rb).
  # "code" → :searxng = custo zero, doutrina 18/08 + L5: SearXNG local
  #   basta para StackOverflow/GitHub/MDN; API paga NUNCA.
  # "auto" → nil = comportamento atual preservado.
  TYPE_TO_PROVIDER = {
    "news"     => :tavily,
    "entity"   => :exa,
    "academic" => :exa,
    "factual"  => :linkup,
    "code"     => :searxng,
    "auto"     => nil
  }.freeze
  ALLOWED_TYPES = TYPE_TO_PROVIDER.keys.freeze

  # F2: subset de providers que disparam fallback via `SearchApiRouter.call`.
  # `:searxng` (code) é o custo zero, fica de fora. O `nil` (auto) cai no
  # fluxo legado (cascata padrão sem specialty).
  PROVIDERS_PAGOS = %i[tavily exa linkup].freeze

  # Mapeia `type` da chamada para o provider preferencial.
  # `nil` para ausente/"auto"/valor fora do enum (defensivo: modelo pode
  # inventar valor). O WebSearchTool trata nil como fluxo atual.
  def self.provider_for_type(type)
    TYPE_TO_PROVIDER[type.to_s]
  end

  # Sem este parametro o SearXNG busca so em `general`, e metade dos engines
  # registrados mora em `it` (stackoverflow, github, askubuntu, superuser,
  # hackernews, mdn, npm, crates.io, docker hub) ou `science` (arxiv, pubmed).
  # Eles estavam no catalogo e nunca disparavam — o mesmo tipo de buraco calado
  # que deixou `google` na lista por meses sem existir de fato.
  # Medido em 05/08/2026, query "ActiveRecord ConnectionNotEstablished":
  # `general` -> 13 resultados de 2 engines; `general,it` -> 24 de 5 engines.
  # A guarda de relevancia abaixo e o que torna essa largura segura: engine de
  # nicho respondendo fora de contexto e descartado por score, nao entregue.
  CATEGORIES = "general,it,science"

  # Operadores que só o engine general entende. Mandá-los para `it`/`science` faz
  # o engine de nicho responder à palavra solta: medido em 06/08, `site:x.com
  # EXM7777` trouxe 10 resultados do Docker Hub e 10 da MDN, aprovados pela guarda
  # porque o título deles contém "Site". UMA lista, usada nos dois lugares — duas
  # divergiriam.
  DOMAIN_OPERATORS  = %w[site inurl intitle filetype].freeze
  OPERATOR_PATTERN  = /(?:\A|\s)(?:#{DOMAIN_OPERATORS.join("|")}):/i
  NARROW_CATEGORIES = "general"

  # Hint de plataforma: Reddit/X/Twitter não são indexados pelas APIs externas
  # pagas (Linkup/Exa/Tavily). Queries com esses operadores NÃO devem gastar cota
  # no fallback externo quando o SearXNG falhar.
  PLATFORM_FALLBACK_BLOCK_PATTERN = /(?:\A|\s)(?:site:)?(?:www\.)?(?:reddit\.com|x\.com|twitter\.com)(?:\/[^\s]*)?(?:\s|$)/i

  def run(query:, limit: 5, time_range: nil, type: nil)
    q = query.to_s.strip
    return error("query vazia") if q.empty?
    return error("query muito longa") if q.length > 200

    limit = clamp(limit, 1, MAX_LIMIT)
    tr = ALLOWED_TIME_RANGES.include?(time_range.to_s) ? time_range.to_s : nil

    # F5a (30/08/2026): gate de teto por conversa ativa (plano-fase2 §D4).
    # Vale SÓ para o caminho Discord in-process (origem `:discord`). MCP,
    # testes e callers sem origem pulam o gate — D4 explicita que o teto é
    # do caminho Discord, e o teto MCP está no plugin do perfil (F5b, fora
    # deste PR). Memória curta e sem expor quota/API: apenas "atingiu o
    # limite, use /new".
    #
    # Este gate é early-return EXPLÍCITO e não incrementa contador:
    # recusa ≠ execução. O incremento é chamado SÓ nos pontos do fluxo
    # em que a busca foi de fato disparada (HTTP saiu / fallback custou),
    # ver comentários nos `increment_discord_search!` adiante. Não há
    # mais `ensure` global — D2-F5a-v7 removeu (ensure rodava em cache
    # hit e empty debounce, inflacionando o teto).
    if Thread.current[:cleitin_origin] == :discord
      limite = check_discord_conversation_limit!
      return error(limite) if limite
    end

    # F5a (30/08/2026): cache hit e empty debounce NÃO incrementam contador
    # — são a mesma busca cacheada (não execução nova) e absorção de rajada,
    # respectivamente. D4 é literal: "Cache hit NÃO incrementa". O
    # incremento é explícito nos returns ABAIXO do `begin`, nos pontos em
    # que a busca foi disparada de fato. Não há `ensure` global:
    # `ensure` em Ruby roda em QUALQUER return do método, inclusive
    # nestes dois early-returns, e isso inflaria o teto artificialmente.
    # (D2-F5a-v7 removeu o ensure.)
    #
    # F3b (30/08/2026): origem do caller lida do Thread.current. Setada em
    # `ChatSessionManager#ask` (caminho Discord/bot) ou `McpController#handle`
    # (caminho MCP) — fora desses dois entrypoints vale nil (caller sem
    # origem). Lida UMA vez aqui para propagar idêntica nas duas chamadas
    # ao router (specialty_first e cascata legado) e evitar divergência.
    origin = Thread.current[:cleitin_origin]

    # F2 do plano v2 (30/08/2026): classifica o `type` UMA vez, antes de
    # ramificar. `provider` é o que vai para o fallback (specialty_first),
    # ou nil quando o tipo é "auto"/inválido (comportamento atual preservado).
    # Código defensivo: modelo pode mandar valor fora do enum.
    #
    # F4 do plano-fase2 (30/08/2026): Discord NÃO tem `type:` no schema e
    # o caminho do bot não pode ser poluído. Quando origin=:discord, o
    # `type` injetado é IGNORADO: provider volta a nil e o run cai no
    # fluxo legado (cascata padrão sem specialty). MCP preserva o contrato
    # F2 — type→specialty_first permanece.
    if origin == :discord
      resolved_type = "auto"
      provider = nil
    else
      resolved_type = ALLOWED_TYPES.include?(type.to_s) ? type.to_s : "auto"
      provider = self.class.provider_for_type(resolved_type)
    end

    # F3c do plano-fase2 (30/08/2026): TTL por tipo∩time_range (plano D2).
    # `SearchApiCache` é o único ponto que decide TTL e que grava; aqui só
    # pedimos o read. A key inclui `provider` E `type` para não cruzar hit
    # SearXNG vs pago (uma query com type=news nunca pode servir um hit
    # que veio de Tavily num type anterior diferente).
    cached = SearchApiCache.read(query: q, limit: limit, time_range: tr,
                                 type: resolved_type, provider: provider)
    # `nil`, não `[]`: acerto de cache não mediu engine nenhum, e um `[]` aqui
    # afirmaria "nenhum caiu". Métrica ausente é nil, nunca zero.
    return success(cached).merge(unresponsive: nil) if cached

    # Debounce de VAZIO (60s, chave separada). Absorve rajada do mesmo turno
    # sem servir "não achei nada" congelado. NÃO é cache de conteúdo — é só
    # debounce — por isso fica em chave própria fora do SearchApiCache.
    # Exceção canônica D2 (plano-fase2, decisão do maestro 30/08): a tabela
    # TTL do plano diz "vazio | 1 min" e o `SearchApiCache` rejeita `[]`,
    # então a absorção de rajada fica aqui, em gravação direta da tool.
    # F3c fail-open (D1-F3c-v5): `Rails.cache.read` direto, fora do envelope
    # do SearchApiCache. Se o store explodir (Solid Cache lock, FileStore IO,
    # Memcached down), o cache NUNCA bloqueia a busca — mesmo padrão (f) do
    # SearchApiCache: trata como miss, segue para o fetch.
    empty_hit =
      begin
        Rails.cache.read(empty_cache_key(q, limit, tr, resolved_type, provider))
      rescue StandardError => e
        Rails.logger.warn("[WebSearchTool] debounce read falhou: #{e.class}: #{e.message}")
        nil
      end
    if empty_hit
      return success([]).merge(unresponsive: nil)
    end

    # F5a (30/08/2026): a partir daqui a busca é executada de fato (fetch
    # real no SearXNG ou fallback no router). O incremento do contador é
    # EXPLÍCITO em cada return de execução real — não há mais `ensure`
    # global. Caminho MCP (`cleitin_origin != :discord`) pula o gate ACIMA
    # E pula o incremento ABAIXO (o helper já checa a origem internamente;
    # mas as chamadas estão guardadas também por clareza). O contador só
    # NÃO é incrementado para os early-returns ACIMA do `begin` (cache
    # hit, query vazia, gate F5a, empty debounce) — buscas não executadas.
    begin
      payload = fetch(q, limit, tr)

    # F2: type=code (provider=searxng) ou qualquer provedor que não esteja na
    # cascata paga → NUNCA gasta API paga no fallback. SearXNG falhou =
    # erro original preservado. Doutrina 18/08 + L5: code é custo zero.
    pagar_api_paga = !provider.nil? && PROVIDERS_PAGOS.include?(provider)
    bloquear_router = provider == :searxng

    # Router só acionado quando o SearXNG falha: sucesso local nunca gasta cota externa.
    # Queries direcionadas a Reddit/X/Twitter bloqueiam fallback externo (plataformas não indexadas).
    if !bloquear_router && pagar_api_paga &&
       !platform_query?(q) &&
       (payload.nil? || (payload[:results].empty? && payload[:unresponsive].any?))
      fallback = begin
        SearchApiRouter.call(query: q, limit: limit, time_range: tr, specialty: provider, origin: origin)
      rescue StandardError => e
        Rails.logger.error "[WebSearchTool] SearchApiRouter falhou: #{e.class}: #{e.message}"
        nil
      end

      if fallback && fallback[:results]&.any?
        fallback_results = fallback[:results].first(limit).map do |r|
          r.merge(content: truncate(r[:content]))
        end
        # F7 (plano-fase2 31/08/2026): aplica `trust` aos itens vindos do
        # fallback. O `SearchApiRouter.normalize_results` já adiciona a chave
        # quando o router processa o payload cru da API paga — mas o stub em
        # teste e um futuro bypass do router poderiam devolver itens sem
        # trust. `ensure_trust!` cobre os dois casos sem custo no caminho
        # comum (no-op em item já rotulado).
        fallback_results = fallback_results.map { |r| ensure_trust!(r) }
        # Refinamento SOTA 5: o resultado do fallback passa pelo MESMO fluxo de
        # cache do run() (a TTL/key foi calculada antes do fetch). Gravamos
        # aqui para que a próxima chamada igual acerte o cache e não gaste cota.
        # `unresponsive` reflete a falha do SearXNG quando houve (nil se fetch nil).
        # F3c: TTL derivado do tipo via SearchApiCache — Tavily (news=600s)
        # não fica 15min congelado igual antes.
        SearchApiCache.write(query: q, limit: limit, time_range: tr,
                             type: resolved_type, provider: provider,
                             payload: fallback_results)
        # F5a: busca REAL disparada (custou API paga) → incrementa.
        increment_discord_search! if Thread.current[:cleitin_origin] == :discord
        return success(fallback_results).merge(unresponsive: payload && payload[:unresponsive])
      end

      # F2: specialty explícito falhou/miss → NÃO cascata padrão. A cascata
      # inteira (linkup→exa→tavily) SEM specialty era o comportamento
      # legado; com `type:` explícito o caller já decidiu qual provedor.
      # tipo=auto (provider nil) → fluxo legado entra abaixo.
    elsif !provider && !platform_query?(q) &&
          (payload.nil? || (payload[:results].empty? && payload[:unresponsive].any?))
      # Fluxo legado preservado: sem `type`, cascata padrão do router.
      fallback = begin
        SearchApiRouter.call(query: q, limit: limit, time_range: tr, origin: origin)
      rescue StandardError => e
        Rails.logger.error "[WebSearchTool] SearchApiRouter falhou: #{e.class}: #{e.message}"
        nil
      end

      if fallback && fallback[:results]&.any?
        fallback_results = fallback[:results].first(limit).map do |r|
          r.merge(content: truncate(r[:content]))
        end
        # F7 (plano-fase2 31/08/2026): ver comentário idêntico no path
        # specialty acima — `ensure_trust!` cobre o caso de stub/bypass.
        fallback_results = fallback_results.map { |r| ensure_trust!(r) }
        # F3c: TTL via SearchApiCache — auto=900s (15min),
        # factual=10800s (3h) etc., conforme tabela do plano-fase2 D2.
        SearchApiCache.write(query: q, limit: limit, time_range: tr,
                             type: resolved_type, provider: provider,
                             payload: fallback_results)
        # F5a: busca REAL disparada (custou API paga) → incrementa.
        increment_discord_search! if Thread.current[:cleitin_origin] == :discord
        return success(fallback_results).merge(unresponsive: payload && payload[:unresponsive])
      end
    end

    # fetch nil → "busca indisponível" (e erro original preservado se o router
    # também falhou — não dereferenciamos o nil do fallback acima).
    # F5a: HTTP disparado contra SearXNG (gastou) e router também não
    # respondeu (ou não foi tentado por regra). Decisão D4 do brief:
    # "HTTP disparado = gastou, incrementa".
    # D2-F5a-v8: este é o ÚNICO caminho em que o incremento vive aqui — payload
    # nil é o único caso em que o fluxo morre antes de chegar aos returns
    # específicos abaixo. Todos os outros caminhos pós-fetch já têm o próprio
    # incremento no return de saída (linhas 285/312/323/341), e o
    # `if payload.nil?` que vinha logo abaixo era a salvaguarda para não
    # dereferenciar nil. O incremento anterior era INCONDICIONAL e batia
    # também nos outros caminhos, dobrando a contagem.
    if payload.nil?
      increment_discord_search! if Thread.current[:cleitin_origin] == :discord
      return error("busca indisponível")
    end

    results     = payload[:results]
    unreachable = payload[:unresponsive]

    # Lista vazia COM engine caída não é "não achei nada" — é "a busca não aconteceu".
    # Sem essa distinção o modelo conclui que o fato não existe. Erro não é cacheado:
    # a próxima tentativa pode cair num engine vivo.
    if results.empty?
      if unreachable.any?
        Rails.logger.warn "[WebSearchTool] busca sem resultados com engines fora do ar: #{unreachable.join(', ')}"

        # Aqui chegamos só quando o fallback externo também falhou (ou não há
        # chave). Mantém o erro original do SearXNG; o router já foi tentado.
        # F5a: HTTP disparado e fallback tentado (gastou) → incrementa.
        # Decisão D4: "HTTP disparado = gastou, incrementa".
        increment_discord_search! if Thread.current[:cleitin_origin] == :discord
        return error("busca não aconteceu: engines fora do ar (#{unreachable.join(', ')}) e nenhum " \
                     "resultado devolvido — tente de novo em alguns minutos")
      end

      # F3c: vazio do SearXNG sem engine caída → debounce vazio de 60s
      # (TTL curto, fixo). NÃO passa pelo SearchApiCache.write — este
      # rejeita `[]` por contrato (item 5 do brief: "não cachear vazio
      # (buscar de novo custa cota mas evita servir 'não existe'
      # congelado)"). A gravação direta aqui serve só para absorver rajada
      # do mesmo turno, não para servir cacheamento durável. A key inclui
      # type+provider para não colidir com o cache de conteúdo principal.
      # F3c fail-open (D1-F3c-v5): mesmo padrão do read acima. Se o store
      # explodir aqui, NÃO derruba — o debounce vazio é absorvedor de rajada
      # do mesmo turno; falhar em gravar só significa que a próxima rajada
      # re-busca (aceitável). Lado oposto do SearchApiCache que tem envelope.
      begin
        Rails.cache.write(empty_cache_key(q, limit, tr, resolved_type, provider),
                          [], expires_in: EMPTY_CACHE_TTL)
      rescue StandardError => e
        Rails.logger.warn("[WebSearchTool] debounce write falhou: #{e.class}: #{e.message}")
      end
      # F5a: SearXNG respondeu com `[]` sem engine caída (HTTP saiu, gastou).
      # Pela D4 ("HTTP disparado = gastou, incrementa"), incrementa aqui
      # também. Esse caminho NÃO está nos "não incrementar" do brief 2d
      # (gate/cache hit/empty debounce) — é busca REAL que só não
      # devolveu resultados.
      increment_discord_search! if Thread.current[:cleitin_origin] == :discord
      return success([]).merge(unresponsive: unreachable)
    end

    verdict = RelevanceGuard.new(q).judge(results)
    if verdict.poisoned?
      Rails.logger.warn "[WebSearchTool] busca envenenada para #{q.inspect}: " \
                        "#{verdict.approved.size}/#{verdict.judged_count} aprovados"
      # F5a: HTTP disparado contra SearXNG e resultados chegaram (mesmo
      # que envenenados — busca de fato aconteceu). Decisão D4:
      # "HTTP disparado = gastou, incrementa".
      increment_discord_search! if Thread.current[:cleitin_origin] == :discord
      return error("resultados irrelevantes: só #{verdict.approved.size} de #{verdict.judged_count} " \
                   "resultados cobriram os termos de #{q.inspect} — o buscador respondeu outra pergunta, " \
                   "reformule a query")
    end

    # Resultados do SearXNG aprovados pela guarda. (Os resultados do fallback
    # externo NÃO passam pelo RelevanceGuard — ver comentário no SearchApiRouter
    # e no retorno de fallback acima: as APIs ranqueiam por relevância própria.)
    data = verdict.approved.first(limit)
    # F7 (plano-fase2 31/08/2026): classificador `trust` no resultado do
    # SearXNG local também. O router já adiciona via `normalize_results`, mas
    # o SearXNG é o caminho comum — sem esta linha, metade dos resultados
    # chegaria ao modelo sem o selo. `ensure_trust!` é no-op em item já
    # rotulado (defesa em profundidade).
    data = data.map { |r| ensure_trust!(r) }
    # F3c: TTL via SearchApiCache — news=600s, factual=10800s, entity/academic
    # =86400s, code/auto=900s; time_range aperta nunca alarga (plano-fase2 D2).
    SearchApiCache.write(query: q, limit: limit, time_range: tr,
                         type: resolved_type, provider: provider,
                         payload: data)
    # F5a: busca REAL disparada (HTTP saiu, SearXNG respondeu, guarda aprovou)
    # → incrementa. Único ponto de incremento do caminho "tudo deu certo" do
    # SearXNG local.
    increment_discord_search! if Thread.current[:cleitin_origin] == :discord
    success(data).merge(unresponsive: unreachable)
    end
  end

  private

  # F5a (30/08/2026): gate de teto por conversa ativa (plano-fase2 §D4).
  # Lê a conversa ATIVA do scope key gravado em `Thread.current` pelo
  # `ChatSessionManager#ask`. Se `web_search_count >= MAX`, devolve a mensagem
  # de recusa (curta, sugere /new, sem expor quota/API). Devolve nil se o
  # gate passa (busca pode prosseguir). Ausência de scope key (caller sem
  # origem Discord) também devolve nil — defesa em profundidade.
  WEB_SEARCH_LIMIT_MESSAGE = "🔎 Atingiu o limite de buscas desta conversa. " \
                            "Use `/new` para começar outra e continuar pesquisando."

  def check_discord_conversation_limit!
    scope_key = Thread.current[:cleitin_conversation_scope_key]
    return nil if scope_key.nil?

    conv = Conversation.active_for(scope_key)
    return nil if conv.nil?
    return nil if conv.web_search_count < Conversation::MAX_WEB_SEARCH_PER_CONVERSATION

    WEB_SEARCH_LIMIT_MESSAGE
  rescue StandardError => e
    # Falha de banco no gate é fail-open: teto é melhor-esforço, e derrubar
    # a busca por erro de contagem seria pior que deixar uma busca extra
    # passar. Loga e segue.
    Rails.logger.warn "[WebSearchTool] Falha no gate F5a: #{e.class}: #{e.message}"
    nil
  end

  # F5a: incrementa `web_search_count` da conversa ativa. Atômico via
  # `increment_counter` (UPDATE por PK) — não precisa reload. Falha de banco
  # aqui NÃO derruba a busca (a busca já foi executada e a resposta já está
  # a caminho); loga e segue. Sem scope key (não veio do bot) → no-op.
  def increment_discord_search!
    scope_key = Thread.current[:cleitin_conversation_scope_key]
    return if scope_key.nil?

    conv = Conversation.active_for(scope_key)
    return if conv.nil?

    Conversation.increment_counter(:web_search_count, conv.id)
  rescue StandardError => e
    Rails.logger.warn "[WebSearchTool] Falha ao incrementar F5a: #{e.class}: #{e.message}"
  end

  def platform_query?(query)
    query.to_s.match?(PLATFORM_FALLBACK_BLOCK_PATTERN)
  end

  # Chave do debounce vazio (60s). Separada da chave do SearchApiCache
  # porque este cache é só debounce, não cacheamento de conteúdo.
  def empty_cache_key(query, limit, time_range, resolved_type, provider)
    payload = "#{query}|#{limit}|#{time_range}|#{resolved_type}|#{provider}"
    "web_search_empty:#{Digest::SHA256.hexdigest(payload)}"
  end

  def categories_for(query)
    query.to_s.match?(OPERATOR_PATTERN) ? NARROW_CATEGORIES : CATEGORIES
  end

  # A guarda julga uma janela maior que o `limit` porque o lixo costuma vir empilhado no
  # topo (era o caso do bing): olhar só os 5 primeiros faria a fração de aprovados medir
  # o próprio envenenamento em vez de detectá-lo. O piso de 10 vale para limit pequeno.
  def guard_window(limit)
    [limit * 2, 10].max
  end

  def fetch(query, limit, time_range)
    uri = URI(BASE_URL)
    params = { q: query, format: "json", safesearch: 1, language: "pt-BR", categories: categories_for(query) }
    params[:time_range] = time_range if time_range
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 20

    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/json"

    response = http.request(req)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "[WebSearchTool] HTTP #{response.code}"
      return nil
    end

    body = JSON.parse(response.body)
    results = body.fetch("results", []).first(guard_window(limit)).map do |r|
      {
        title:   r["title"],
        url:     r["url"],
        content: truncate(r["content"]),
        engine:  r["engine"]
      }
    end

    { results: results, unresponsive: unresponsive_names(body) }
  rescue StandardError => e
    Rails.logger.error "[WebSearchTool] #{e.class}: #{e.message}"
    nil
  end

  # O SearXNG serializa cada engine caída como par ["nome", "motivo"]; versões antigas
  # mandam só a string. Aceita as duas formas para não perder o sinal num upgrade.
  def unresponsive_names(body)
    Array(body["unresponsive_engines"]).filter_map do |entry|
      name = entry.is_a?(Array) ? entry.first : entry
      name.to_s.strip
    end.reject(&:empty?).uniq
  end

  def truncate(text)
    return nil if text.nil?

    text.length > CONTENT_MAX_CHARS ? "#{text[0, CONTENT_MAX_CHARS]}…" : text
  end

  # F7 (plano-fase2 31/08/2026): aplica `trust` no item se ainda não tiver.
  # Idempotente — quando o router já normalizou o item, o `:trust` está lá
  # e o helper é no-op. Quando o item vem cru (SearXNG direto, stub de
  # teste, ou bypass futuro), calcula pelo host da URL. Cobre os 3 caminhos
  # (SearXNG, specialty fallback, cascata padrão) sem custo extra no comum.
  def ensure_trust!(item)
    return item if item.is_a?(Hash) && item.key?(:trust)

    item.merge(trust: SearchApiRouter.trust_for(item[:url]))
  end

  # Guarda lexical de relevância — Ruby puro, sem rede e sem modelo.
  #
  # Motivo: em 05/08/2026 a query "reddit ruby performance" voltou com páginas de login do
  # Roblox e cartas Pokémon (bug conhecido do bing, issue #4964 do SearXNG) e a tool as
  # devolveu com status de sucesso — o bot respondeu com confiança sobre a coisa errada.
  # O bing já saiu do conjunto de engines, mas nada no código sabia separar bom de lixo.
  class RelevanceGuard
    # Fração dos termos significativos da query que precisa aparecer em título+snippet.
    # 0.3 aceita 1 de 3 termos (0.33): numa query de 3 palavras, um resultado que cita
    # apenas "ruby" ainda pode ser a resposta certa. Derrubar resultado bom é pior que
    # deixar passar um mediano — o teto de qualidade quem dá é a fração agregada abaixo.
    RELEVANCE_FLOOR = 0.3

    # Abaixo desta fração de aprovados a busca INTEIRA é considerada envenenada. No caso
    # medido do Roblox a fração era 0 (nenhum dos 5 primeiros citava qualquer termo);
    # 0.25 fica bem acima disso e ainda deixa passar a busca em que só 1 de 4 casou.
    MIN_APPROVED_RATIO = 0.25

    # Com menos de 3 resultados não há amostra para julgar envenenamento — a fração vira
    # 0 ou 1 pelo acaso de um único item. Nesse caso a guarda se cala e devolve tudo:
    # derrubar o único resultado da busca custa mais do que o lixo que ela evitaria.
    MIN_RESULTS_TO_JUDGE = 3

    # Query de um termo só é tudo-ou-nada: 1 termo ausente = score 0 = busca reprovada.
    # "bitcoin" respondida por "Cotação do BTC hoje" seria descartada. Com menos de 2
    # termos significativos a guarda desliga.
    MIN_QUERY_TERMS = 2

    # Termo curto casa só por igualdade; de 4 caracteres em diante vale prefixo COMPARTILHADO.
    # Prefixo estrito (uma palavra começar com a outra) não cobre flexão portuguesa: "eleicao"
    # não é prefixo de "eleicoes" — o plural de -ção diverge no meio da palavra — e "ganhou"
    # não casa com "ganha". Medido ao vivo em 05/08/2026 contra o SearXNG desta máquina: na
    # query "quem ganhou a eleicao na Argentina" a manchete correta em 1º lugar (G1, "Partido
    # de Milei ... vence eleições legislativas na Argentina") ficava com 1 de 4 termos (0.25),
    # abaixo do piso, e era descartada; numa das coletas só 2 de 10 passaram e a busca INTEIRA
    # virou erro. O prefixo compartilhado casa "eleicao"/"eleicoes", "ganhou"/"ganha" e
    # "cache"/"caching", e continua não casando "reddit"/"roblox" nem "performance"/"platform"
    # (o caso Roblox segue reprovado).
    PREFIX_MATCH_MIN_CHARS = 4

    # O prefixo comum também precisa cobrir a maior parte da palavra mais curta, senão
    # "eleicao" casaria com "eleitoral" (4 de 7 é pouco: 4 < 0.6 * 7).
    SHARED_PREFIX_MIN_RATIO = 0.6

    # Termo de 1-2 letras não discrimina nada ("no", "os", "ia") e infla o denominador.
    # Exceção para quem tem dígito: "5g", "4k", "gpt5" são termos de busca de verdade.
    TERM_MIN_CHARS = 3

    STOPWORDS = %w[
      a o e as os um uma uns umas de do da dos das em no na nos nas ao aos por para com sem sob sobre
      entre que qual quais quando onde como porque pois mas ou se nao sim este esta esse essa isso isto
      aquele aquela seu sua meu minha nosso nossa ser sao foi era tem ter mais menos muito pouco tudo
      todo toda todos todas ja ainda depois antes pelo pela pelos pelas
      the an of in on at to for and or is are was were be by with from as it this that these those
      how what when where why which who i you your my our their there here about into over
    ].to_set.freeze

    Verdict = Struct.new(:approved, :judged_count, :poisoned, keyword_init: true) do
      def poisoned? = poisoned
    end

    def initialize(query)
      @terms = self.class.significant_terms(query)
    end

    def judge(items)
      unless judgeable?(items.size)
        # Métrica não medida é nil, nunca 0: um 0.0 aqui seria lido pelo modelo como
        # "resultado irrelevante", quando o que houve foi guarda desligada.
        return Verdict.new(approved: items.map { |i| i.merge(relevance: nil) },
                           judged_count: items.size, poisoned: false)
      end

      scored   = items.map { |i| i.merge(relevance: score(i)) }
      approved = scored.select { |i| i[:relevance] >= RELEVANCE_FLOOR }

      Verdict.new(approved: approved, judged_count: scored.size,
                  poisoned: approved.size.to_f / scored.size < MIN_APPROVED_RATIO)
    end

    # Acento é obrigatório aqui: as queries são em português e o título do resultado pode
    # vir sem acento (ou o contrário). NFD separa a marca diacrítica da letra base, e o
    # gsub de \p{Mn} a remove. O split por [^a-z0-9] também zera título em alfabeto não
    # latino — que foi exatamente um dos lixos medidos (resultado em chinês).
    def self.tokenize(text)
      text.to_s
          .unicode_normalize(:nfd)
          .gsub(/\p{Mn}/, "")
          .downcase
          .split(/[^a-z0-9]+/)
          .reject(&:empty?)
    end

    # Operador de domínio só conta como operador COM os dois-pontos — o mesmo
    # critério de `categories_for` (linhas 42-45 prometem uso simétrico da
    # lista). Palavra solta "site"/"inurl" numa query é termo de busca; derrubá-la
    # aqui sem estreitar a categoria faria a guarda julgar com um termo a menos.
    def self.significant_terms(query)
      operadores = query.to_s.match?(OPERATOR_PATTERN) ? DOMAIN_OPERATORS : []
      tokenize(query).uniq.reject do |term|
        STOPWORDS.include?(term) ||
          operadores.include?(term) ||
          (term.length < TERM_MIN_CHARS && !term.match?(/\d/))
      end
    end

    private

    def judgeable?(sample_size)
      @terms.size >= MIN_QUERY_TERMS && sample_size >= MIN_RESULTS_TO_JUDGE
    end

    # Pontua o snippet JÁ truncado em 400 chars, que é exatamente o texto que o modelo vai
    # ler. Julgar um texto maior que o entregue aprovaria resultado por evidência invisível.
    def score(item)
      doc = self.class.tokenize("#{item[:title]} #{item[:content]}")
      hits = @terms.count { |term| doc.any? { |word| match?(term, word) } }
      (hits.to_f / @terms.size).round(2)
    end

    def match?(term, word)
      return true if term == word
      return false if term.length < PREFIX_MATCH_MIN_CHARS || word.length < PREFIX_MATCH_MIN_CHARS

      shared = shared_prefix_length(term, word)
      shared >= PREFIX_MATCH_MIN_CHARS &&
        shared >= [term.length, word.length].min * SHARED_PREFIX_MIN_RATIO
    end

    def shared_prefix_length(one, other)
      limit = [one.length, other.length].min
      i = 0
      i += 1 while i < limit && one[i] == other[i]
      i
    end
  end
end
