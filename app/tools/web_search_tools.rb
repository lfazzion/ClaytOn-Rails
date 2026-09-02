# frozen_string_literal: true

require "net/http"
require "json"
require "digest"
require "set"
require_relative "../services/search_api_cache"
require_relative "../services/search_metric"

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

  # ── Jitter e Backoff (L1 02/09/2026) ──────────────────────────────────────
  DEFAULT_JITTER_MS_MIN       = 250
  DEFAULT_JITTER_MS_MAX       = 800
  DEFAULT_JITTER_TURN_CAP_MS  = 4000
  DEFAULT_BACKOFF_MAX_MS      = 30000
  DEFAULT_BACKOFF_CLAMP_MS    = 8000
  DEFAULT_BACKOFF_LEVELS      = [5000, 15000, 30000].freeze
  BLOCK_SIGNAL_PATTERN        = /captcha|too many requests|403|429/i
  # L1-R1C: HTTP do próprio SearXNG (não das engines internas) que também
  # indica bloqueio — chega com payload nil (ver `fetch`), então precisa de
  # canal próprio em vez do regex acima (que roda sobre texto de mensagem).
  BLOCKED_HTTP_STATUSES       = [403, 429].freeze

  def self.jitter_ms_min
    ENV.fetch("SEARXNG_JITTER_MS_MIN", DEFAULT_JITTER_MS_MIN).to_i
  end

  def self.jitter_ms_max
    ENV.fetch("SEARXNG_JITTER_MS_MAX", DEFAULT_JITTER_MS_MAX).to_i
  end

  def self.jitter_turn_cap_ms
    ENV.fetch("SEARXNG_JITTER_TURN_CAP_MS", DEFAULT_JITTER_TURN_CAP_MS).to_i
  end

  def self.backoff_max_ms
    ENV.fetch("SEARXNG_BACKOFF_MAX_MS", DEFAULT_BACKOFF_MAX_MS).to_i
  end

  def self.backoff_clamp_ms
    ENV.fetch("SEARXNG_BACKOFF_CLAMP_MS", DEFAULT_BACKOFF_CLAMP_MS).to_i
  end

  def self.backoff_levels
    max_ms = backoff_max_ms
    DEFAULT_BACKOFF_LEVELS.map { |level| [level, max_ms].min }
  end

  def self.jitter_draw
    min = jitter_ms_min
    max = jitter_ms_max
    return 0 if max <= 0
    return min if min >= max

    rand(min..max)
  end

  def self.active_scope_key(scope_key = nil)
    scope_key || Thread.current[:cleitin_conversation_scope_key] || :_default
  end

  def self.searxng_turn_counts
    Thread.current[:cleitin_searxng_turn_counts] ||= Hash.new(0)
  end

  def self.searxng_jitter_totals
    Thread.current[:cleitin_searxng_jitter_totals] ||= Hash.new(0)
  end

  def self.reset_searxng_turn_state!(scope_key = nil)
    if scope_key
      searxng_turn_counts[scope_key] = 0
      searxng_jitter_totals[scope_key] = 0
    else
      key = Thread.current[:cleitin_conversation_scope_key]
      if key
        searxng_turn_counts[key] = 0
        searxng_jitter_totals[key] = 0
      else
        Thread.current[:cleitin_searxng_turn_counts] = Hash.new(0)
        Thread.current[:cleitin_searxng_jitter_totals] = Hash.new(0)
      end
      searxng_turn_counts[:_default] = 0
      searxng_jitter_totals[:_default] = 0
    end
  end

  def self.backoff_key(origin)
    "searxng_backoff:#{origin || :default}"
  end

  def self.pending_backoff_ms(origin)
    level = Rails.cache.read(backoff_key(origin))
    return nil if level.nil?

    levels = backoff_levels
    idx = [level.to_i, levels.size - 1].min
    levels[idx]
  end

  def self.searxng_block_signal?(payload, http_status: nil)
    return true if BLOCKED_HTTP_STATUSES.include?(http_status)
    return false if payload.nil?
    return true if payload[:searxng_blocked] == true

    results = payload[:results] || []
    unresponsive = payload[:unresponsive] || []

    return true if results.empty? && unresponsive.any?

    # L1-R1C: o regex tem que rodar sobre a MENSAGEM real do erro (ex.:
    # "Suspended: too many requests"), não sobre o nome da engine
    # ("brave") — `unresponsive_reasons` carrega o texto, `unresponsive`
    # só o nome.
    (payload[:unresponsive_reasons] || []).any? { |reason| reason.to_s.match?(BLOCK_SIGNAL_PATTERN) }
  end

  def self.register_backoff_outcome!(origin, payload, http_status: nil)
    key = backoff_key(origin)
    if searxng_block_signal?(payload, http_status: http_status)
      current_level = Rails.cache.read(key)
      levels = backoff_levels
      next_level = current_level.nil? ? 0 : [current_level.to_i + 1, levels.size - 1].min
      Rails.cache.write(key, next_level, expires_in: 1.hour)
    else
      Rails.cache.delete(key)
    end
  rescue StandardError => e
    Rails.logger.warn("[WebSearchTool] register_backoff_outcome! falhou: #{e.message}")
  end

  # Mapeia `type` da chamada para o provider preferencial.
  # `nil` para ausente/"auto"/valor fora do enum (defensivo: modelo pode
  # inventar valor). O WebSearchTool trata nil como fluxo atual.
  def self.provider_for_type(type)
    TYPE_TO_PROVIDER[type.to_s]
  end

  # Sem este parametro o SearXNG busca so em `general`, e metade dos engines
  # registrados mora em `it` (stackoverflow, github,askubuntu, superuser,
  # hackernews, mdn, npm, crates.io, docker hub) ou `science` (arxiv, pubmed).
  # Eles estavam no catalogo e nunca disparavam— o mesmo tipo de buraco calado
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

  def perform_wait(ms)
    return if ms.nil? || ms <= 0

    sleep(ms / 1000.0)
  end

  def apply_searxng_jitter!(scope_key = nil)
    key = self.class.active_scope_key(scope_key)
    count = self.class.searxng_turn_counts[key] || 0
    self.class.searxng_turn_counts[key] = count + 1

    return 0 if count == 0

    accumulated = self.class.searxng_jitter_totals[key] || 0
    cap = self.class.jitter_turn_cap_ms
    remaining = [cap - accumulated, 0].max
    return 0 if remaining <= 0

    draw = self.class.jitter_draw
    wait_ms = [draw, remaining].min
    if wait_ms > 0
      perform_wait(wait_ms)
      self.class.searxng_jitter_totals[key] = accumulated + wait_ms
    end
    wait_ms
  end

  def run(query:, limit: 5, time_range: nil, type: nil)
    q = query.to_s.strip
    return error("query vazia") if q.empty?
    return error("query muito longa") if q.length > 200

    limit = clamp(limit, 1, MAX_LIMIT)
    tr = ALLOWED_TIME_RANGES.include?(time_range.to_s) ? time_range.to_s : nil

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

    # F8 (plano-fase2 D7, 31/08/2026): cronômetro do run para a métrica
    # `latency_ms`. O helper `record_search_metric!` é chamado em CADA
    # return pós-fetch (busca executou). Cache hit / empty debounce hit /
    # query vazia ficam de fora (busca NÃO executou). O `started_at` é
    # definido uma vez aqui para que latency cubra SearXNG+fallback (a
    # busca completa, não só um hop).
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    jitter_ms = 0
    backoff_ms = 0
    skipped_searxng = false

    # L1 (02/09/2026): Verifica backoff pendente antes de tentar SearXNG
    pending_backoff = self.class.pending_backoff_ms(origin)
    clamp_limit_ms = self.class.backoff_clamp_ms

    if pending_backoff && pending_backoff > 0
      if pending_backoff > clamp_limit_ms
        # CLAMP: cooldown pendente > 8s -> pula SearXNG direto para o fallback pago
        skipped_searxng = true
        backoff_ms = pending_backoff
        jitter_ms = 0
        payload = nil
      else
        perform_wait(pending_backoff)
        backoff_ms = pending_backoff
      end
    end

    # L1: Se não pulou SearXNG, aplica jitter e faz fetch local
    unless skipped_searxng
      jitter_ms = apply_searxng_jitter!
      payload = fetch(q, limit, tr)
      self.class.register_backoff_outcome!(origin, payload, http_status: @last_http_status)
    end

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
      if SearchApiRouter.paid_search_limit_reached?
        record_search_metric!(
          q: q, results: nil, source: "router", cost_usd: nil,
          latency_ms: elapsed_ms(nil, started_at),
          unresponsive_count: (payload && payload[:unresponsive] || []).size,
          error: "teto_por_turno",
          type: resolved_type, provider: provider, origin: origin,
          jitter_ms: jitter_ms, backoff_ms: backoff_ms
        )
        return error("teto de buscas pagas atingido neste turno (#{SearchApiRouter.paid_search_limit})")
      end

      fallback = begin
        SearchApiRouter.call(query: q, limit: limit, time_range: tr, specialty: provider, origin: origin)
      rescue StandardError => e
        Rails.logger.error "[WebSearchTool] SearchApiRouter falhou: #{e.class}: #{e.message}"
        nil
      end

      if fallback && fallback[:results]&.any?
        fallback_results = fallback[:results].first(limit).map do |r|
          r.merge(content: r[:content])
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
        # F8: métrica do caminho specialty (provider=tavily/exa/linkup).
        record_search_metric!(
          q: q, results: fallback_results, source: "router",
          cost_usd: fallback[:cost], latency_ms: elapsed_ms(fallback, started_at),
          unresponsive_count: (payload && payload[:unresponsive] || []).size,
          error: nil, type: resolved_type, provider: provider, origin: origin,
          jitter_ms: jitter_ms, backoff_ms: backoff_ms
        )
        return success(fallback_results).merge(unresponsive: payload && payload[:unresponsive])
      end

      # F2: specialty explícito falhou/miss → NÃO cascata padrão. A cascata
      # inteira (linkup→exa→tavily) SEM specialty era o comportamento
      # legado; com `type:` explícito o caller já decidiu qual provedor.
      # tipo=auto (provider nil) → fluxo legado entra abaixo.
    elsif !provider && !platform_query?(q) &&
          (payload.nil? || (payload[:results].empty? && payload[:unresponsive].any?))
      if SearchApiRouter.paid_search_limit_reached?
        record_search_metric!(
          q: q, results: nil, source: "router", cost_usd: nil,
          latency_ms: elapsed_ms(nil, started_at),
          unresponsive_count: (payload && payload[:unresponsive] || []).size,
          error: "teto_por_turno",
          type: resolved_type, provider: provider, origin: origin,
          jitter_ms: jitter_ms, backoff_ms: backoff_ms
        )
        return error("teto de buscas pagas atingido neste turno (#{SearchApiRouter.paid_search_limit})")
      end

      # Fluxo legado preservado: sem `type`, cascata padrão do router.
      fallback = begin
        SearchApiRouter.call(query: q, limit: limit, time_range: tr, origin: origin)
      rescue StandardError => e
        Rails.logger.error "[WebSearchTool] SearchApiRouter falhou: #{e.class}: #{e.message}"
        nil
      end

      if fallback && fallback[:results]&.any?
        fallback_results = fallback[:results].first(limit).map do |r|
          r.merge(content: r[:content])
        end
        # F7 (plano-fase2 31/08/2026): ver comentário idêntico no path
        # specialty acima — `ensure_trust!` cobre o caso de stub/bypass.
        fallback_results = fallback_results.map { |r| ensure_trust!(r) }
        # F3c: TTL via SearchApiCache — auto=900s (15min),
        # factual=10800s (3h) etc., conforme tabela do plano-fase2 D2.
        SearchApiCache.write(query: q, limit: limit, time_range: tr,
                             type: resolved_type, provider: provider,
                             payload: fallback_results)
        # F8: métrica do caminho cascata padrão (provider efetivo decidido
        # pelo router — tavily/exa/linkup). `provider` local continua nil
        # (type=auto), mas a métrica carrega o provider que REALMENTE serviu
        # via fallback[:engine].
        record_search_metric!(
          q: q, results: fallback_results, source: "router",
          cost_usd: fallback[:cost], latency_ms: elapsed_ms(fallback, started_at),
          unresponsive_count: (payload && payload[:unresponsive] || []).size,
          error: nil, type: resolved_type,
          provider: fallback[:engine], origin: origin,
          jitter_ms: jitter_ms, backoff_ms: backoff_ms
        )
        return success(fallback_results).merge(unresponsive: payload && payload[:unresponsive])
      end
    end

    # fetch nil → "busca indisponível" (e erro original preservado se o router
    # também falhou — não dereferenciamos o nil do fallback acima).
    if payload.nil?
      record_search_metric!(
        q: q, results: nil, source: "searxng", cost_usd: nil,
        latency_ms: elapsed_ms(nil, started_at),
        unresponsive_count: 0, error: "indisponivel",
        type: resolved_type, provider: provider, origin: origin,
        jitter_ms: jitter_ms, backoff_ms: backoff_ms
      )
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

        record_search_metric!(
          q: q, results: nil, source: "router", cost_usd: nil,
          latency_ms: elapsed_ms(nil, started_at),
          unresponsive_count: unreachable.size, error: "nao_aconteceu",
          type: resolved_type, provider: provider, origin: origin,
          jitter_ms: jitter_ms, backoff_ms: backoff_ms
        )
        return error("busca não aconteceu: engines fora do ar (#{unreachable.join(', ')}) e nenhum " \
                     "resultado devolvido — tente de novo em alguns minutos")
      end

      begin
        Rails.cache.write(empty_cache_key(q, limit, tr, resolved_type, provider),
                          [], expires_in: EMPTY_CACHE_TTL)
      rescue StandardError => e
        Rails.logger.warn("[WebSearchTool] debounce write falhou: #{e.class}: #{e.message}")
      end
      record_search_metric!(
        q: q, results: nil, source: "searxng", cost_usd: nil,
        latency_ms: elapsed_ms(nil, started_at),
        unresponsive_count: 0, error: nil,
        type: resolved_type, provider: provider, origin: origin,
        jitter_ms: jitter_ms, backoff_ms: backoff_ms
      )
      return success([]).merge(unresponsive: unreachable)
    end

    verdict = RelevanceGuard.new(q).judge(results)
    if verdict.poisoned?
      Rails.logger.warn "[WebSearchTool] busca envenenada para #{q.inspect}: " \
                        "#{verdict.approved.size}/#{verdict.judged_count} aprovados"
      record_search_metric!(
        q: q, results: verdict.approved, source: "searxng", cost_usd: nil,
        latency_ms: elapsed_ms(nil, started_at),
        unresponsive_count: 0, error: "irrelevantes",
        type: resolved_type, provider: provider, origin: origin,
        jitter_ms: jitter_ms, backoff_ms: backoff_ms
      )
      return error("resultados irrelevantes: só #{verdict.approved.size} de #{verdict.judged_count} " \
                   "resultados cobriram os termos de #{q.inspect} — o buscador respondeu outra pergunta, " \
                   "reformule a query")
    end

    data = verdict.approved.first(limit)
    data = data.map { |r| ensure_trust!(r) }
    SearchApiCache.write(query: q, limit: limit, time_range: tr,
                         type: resolved_type, provider: provider,
                         payload: data)
    record_search_metric!(
      q: q, results: data, source: "searxng", cost_usd: nil,
      latency_ms: elapsed_ms(nil, started_at),
      unresponsive_count: unreachable.size, error: nil,
      type: resolved_type, provider: provider, origin: origin,
      engine: data.first && data.first[:engine],
      jitter_ms: jitter_ms, backoff_ms: backoff_ms
    )
    success(data).merge(unresponsive: unreachable)
  end

  private

  # F8 (plano-fase2 D7, 31/08/2026 / L1 02/09/2026): helper que consolida a emissão da
  # métrica. Chamado em cada return pós-fetch. É o ÚNICO ponto do tool que
  # fala com `SearchMetric` (defesa em profundidade — mudanças no schema
  # da métrica ficam isoladas aqui).
  def record_search_metric!(q:, results:, source:, cost_usd:, latency_ms:,
                            unresponsive_count:, error:, type:, provider:,
                            origin:, engine: "", jitter_ms: 0, backoff_ms: 0)
    primary, ugc, unknown = trust_counts(results)
    SearchMetric.record(
      origin: origin,
      provider: provider,
      type: type,
      query_len: q.to_s.length,
      results_count: results&.size.to_i,
      latency_ms: latency_ms,
      source: source,
      engine: engine,
      cost_usd: cost_usd,
      trust_primary: primary,
      trust_ugc: ugc,
      trust_unknown: unknown,
      unresponsive_count: unresponsive_count,
      jitter_ms: jitter_ms,
      backoff_ms: backoff_ms,
      error: error
    )
  end

  def trust_counts(results)
    return [0, 0, 0] if results.nil?

    counts = { primary: 0, ugc: 0, unknown: 0 }
    results.each do |r|
      trust = r[:trust] || SearchApiRouter.trust_for(r[:url])
      counts[trust] += 1 if counts.key?(trust)
    end
    [counts[:primary], counts[:ugc], counts[:unknown]]
  end

  def elapsed_ms(_fallback_unused, started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end

  def platform_query?(query)
    query.to_s.match?(PLATFORM_FALLBACK_BLOCK_PATTERN)
  end

  def empty_cache_key(query, limit, time_range, resolved_type, provider)
    payload = "#{query}|#{limit}|#{time_range}|#{resolved_type}|#{provider}"
    "web_search_empty:#{Digest::SHA256.hexdigest(payload)}"
  end

  def categories_for(query)
    query.to_s.match?(OPERATOR_PATTERN) ? NARROW_CATEGORIES : CATEGORIES
  end

  def guard_window(limit)
    [limit * 2, 10].max
  end

  def fetch(query, limit, time_range)
    @last_http_status = nil
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
      @last_http_status = response.code.to_i
      Rails.logger.warn "[WebSearchTool] HTTP #{response.code}"
      return nil
    end

    body = JSON.parse(response.body)
    results = body.fetch("results", []).first(guard_window(limit)).map do |r|
      {
        title:   r["title"],
        url:     r["url"],
        content: r["content"],
        engine:  r["engine"]
      }
    end

    { results: results, unresponsive: unresponsive_names(body), unresponsive_reasons: unresponsive_reasons(body) }
  rescue StandardError => e
    Rails.logger.error "[WebSearchTool] #{e.class}: #{e.message}"
    nil
  end

  def unresponsive_names(body)
    Array(body["unresponsive_engines"]).filter_map do |entry|
      name = entry.is_a?(Array) ? entry.first : entry
      name.to_s.strip
    end.reject(&:empty?).uniq
  end

  # L1-R1C: mensagem real do erro por engine (ex.: "Suspended: too many
  # requests"), separada do nome — `searxng_block_signal?` roda o regex
  # aqui, nunca em cima do nome da engine.
  def unresponsive_reasons(body)
    Array(body["unresponsive_engines"]).filter_map do |entry|
      entry.is_a?(Array) ? entry[1].to_s.strip : nil
    end.reject(&:empty?)
  end

  def ensure_trust!(item)
    return item if item.is_a?(Hash) && item.key?(:trust)

    item.merge(trust: SearchApiRouter.trust_for(item[:url]))
  end

  class RelevanceGuard
    RELEVANCE_FLOOR = 0.3
    MIN_APPROVED_RATIO = 0.25
    MIN_RESULTS_TO_JUDGE = 3
    MIN_QUERY_TERMS = 2
    PREFIX_MATCH_MIN_CHARS = 4
    SHARED_PREFIX_MIN_RATIO = 0.6
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
        return Verdict.new(approved: items.map { |i| i.merge(relevance: nil) },
                           judged_count: items.size, poisoned: false)
      end

      scored   = items.map { |i| i.merge(relevance: score(i)) }
      approved = scored.select { |i| i[:relevance] >= RELEVANCE_FLOOR }

      Verdict.new(approved: approved, judged_count: scored.size,
                  poisoned: approved.size.to_f / scored.size < MIN_APPROVED_RATIO)
    end

    def self.tokenize(text)
      text.to_s
          .unicode_normalize(:nfd)
          .gsub(/\p{Mn}/, "")
          .downcase
          .split(/[^a-z0-9]+/)
          .reject(&:empty?)
    end

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
