# frozen_string_literal: true

require "net/http"
require "json"
require "date"

# Roteador de busca multi-API (Linkup → Exa → Tavily) para fallback do SearXNG.
#
# CONTEXTO (decisão do dono): o WebSearchTool busca via SearXNG local. Quando o
# SearXNG falha (erro HTTP, engines fora do ar, zero resultados), este router é
# chamado ANTES de devolver o erro — ele tenta as APIs externas em ordem de
# fallback. Se alguma servir, o resultado entra como success normal.
#
# POR QUE NÃO RELEVANCEGUARD AQUI: o RelevanceGuard do WebSearchTool existe para
# proteger contra envenenamento de engines scraper do SearXNG (caso Roblox/Pokémon
# de 05/08). As APIs pagas (Linkup/Exa/Tavily) ranqueiam por relevância própria
# treinada — não há o mesmo vetor de envenenamento. Aplicar a guarda lexical a
# elas descartaria resultados bons por critério que só faz sentido contra scrapers.
# Por isso os resultados do router NÃO passam pelo RelevanceGuard (ver web_search_tools.rb).
#
# FAN-OUT DE SUB-QUERIES E FUSÃO PARALELA ENTRE APIS: FORA do escopo deste router
# (Refinamento SOTA 4 / 6). Fusão paralela de APIs gastaria mais cota e traria
# complexidade sem ganho real — o fallback sequencial (SearXNG → Linkup → Exa → Tavily)
# já fornece redundância robusta. A decisão de decompor buscas ou fundir tópicos
# cabe ao LLM via múltiplas tool calls / multi-turn.
class SearchApiRouter
  # ── Configuração via ENV (Spec 1.c / 1.d) ─────────────────────────────────
  # Ordem de fallback: Linkup (melhor factualidade single-hop, SimpleQA 91%) →
  # Exa (busca neural, entidades, papers) → Tavily (lookup rápido, estável).
  # Decisão do dono + revisão Grok 4.6 medium (17/08): cada API foca na sua
  # especialidade, sem gastar cota desnecessariamente.
  PROVIDERS = %i[linkup exa tavily].freeze

  DEFAULT_QUOTA = {
    tavily: 1000,
    exa:    1400,
    linkup: 4000
  }.freeze

  API_KEY_ENV = {
    tavily: "TAVILY_API_KEY",
    exa:    "EXA_API_KEY",
    linkup: "LINKUP_API_KEY"
  }.freeze

  QUOTA_ENV = {
    tavily: "SEARCH_API_QUOTA_TAVILY",
    exa:    "SEARCH_API_QUOTA_EXA",
    linkup: "SEARCH_API_QUOTA_LINKUP"
  }.freeze

  SCORE_THRESHOLD_ENV = "SEARCH_API_SCORE_THRESHOLD"
  DEFAULT_SCORE_THRESHOLD = 0.7

  # Timeout idêntico ao do WebSearchTool (Spec 1.a).
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 20
  MAX_RESULTS  = 10

  # Mapa de time_range (day/week/month/year) → dias para recuar a data inicial.
  TIME_RANGE_DAYS = { "day" => 1, "week" => 7, "month" => 30, "year" => 365 }.freeze

  # ── API pública (usada pelo WebSearchTool#run) ─────────────────────────────

  # Tenta as APIs externas em ordem de fallback.
  # @return [Hash, nil] { results:, engine:, cost: } em sucesso, ou nil se todas falharem.
  def self.call(query:, limit: 5, time_range: nil)
    providers = ordered_providers
    return nil if providers.empty? # sem nenhuma chave → router desligado (Spec 1.d)

    limit = clamp_limit(limit)
    tr = time_range if TIME_RANGE_DAYS.key?(time_range.to_s)
    today = Date.today
    reasons = []
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    providers.each do |provider|
      next if quota_exceeded?(provider) # cota do mês esgotada → pula direto

      result, reason = attempt(provider, query, limit, tr, today)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      if result
        # Log estruturado: regra, provider, custo, latência — para auditoria do roteador.
        Rails.logger.info(
          "[SearchApiRouter] #{provider} serviu a busca por #{query.inspect}" \
          " (regra: default, custo: #{result[:cost]}, latência: #{elapsed_ms}ms)"
        )
        return result
      end

      reasons << "#{provider}: #{reason}"
      Rails.logger.warn("[SearchApiRouter] #{provider} falhou para #{query.inspect}: #{reason}")
    end

    Rails.logger.warn("[SearchApiRouter] todas as APIs falharam para #{query.inspect}: #{reasons.join(' | ')}")
    nil
  end

  # ── Providers habilitados (Spec 1.d) ───────────────────────────────────────

  # Ordem de fallback Linkup → Exa → Tavily, filtrando os que NÃO têm chave.
  # Sem args lê as chaves de ENV; chamado com kwargs planos (linkup:/exa:/tavily:)
  # para override em teste.
  def self.ordered_providers(**provider_keys)
    keys = provider_keys.empty? ? API_KEY_ENV.transform_values { |env| ENV[env] } : provider_keys
    PROVIDERS.select { |p| keys[p].to_s.strip.length.positive? }
  end

  # ── Normalização (Spec 1.e) ────────────────────────────────────────────────

  # Normaliza o payload cru de uma API em [{title:, url:, content:, engine:}].
  # Aplica dedupe por URL canônica (Refinamento SOTA 1) e o filtro de score do
  # Tavily (Refinamento SOTA 2). `score_threshold` vem de ENV (default 0.7).
  #
  # Recebe `score_threshold:` para poder ser testado em isolamento (ruby puro).
  def self.normalize_results(provider, raw, score_threshold: DEFAULT_SCORE_THRESHOLD)
    raw_results = Array(raw["results"])
    list = raw_results.filter_map { |r| normalize_one(provider, r) }
    list = dedupe_by_canonical_url(list)
    list = apply_score_filter(provider, list, score_threshold) if provider == :tavily
    list
  end

  def self.normalize_one(provider, r)
    case provider
    when :tavily
      { title: r["title"], url: r["url"], content: r["content"], engine: "tavily", _score: r["score"] }
    when :exa
      content = Array(r["highlights"]).first || r["text"]
      { title: r["title"], url: r["url"], content: content, engine: "exa" }
    when :linkup
      { title: r["name"], url: r["url"], content: r["content"], engine: "linkup" }
    else
      nil
    end
  end

  # Refinamento SOTA 1: remove query string e barra final ANTES de deduplicar,
  # mantendo a primeira ocorrência por URL canônica.
  def self.dedupe_by_canonical_url(list)
    seen = {}
    list.each do |item|
      canonical = canonical_url(item[:url])
      seen[canonical] ||= item
    end
    seen.values
  end

  def self.canonical_url(url)
    return "" if url.nil?

    base = url.to_s.split("?").first.to_s
    base.end_with?("/") ? base.chomp("/") : base
  end

  # Refinamento SOTA 2: descarta resultados Tavily com score < threshold.
  # SÓ Tavily expõe `score` comparável; Exa/Linkup não, por isso o filtro é
  # aplicado exclusivamente a eles (e chamado só para provider == :tavily).
  def self.apply_score_filter(_provider, list, threshold)
    list.select do |item|
      score = item[:_score]
      score.nil? ? true : score >= threshold
    end.map { |item| item.except(:_score) }
  end

  # ── Mapeamento de time_range (Spec 1.f) ────────────────────────────────────

  # Retorna o valor JÁ formatado para o body de cada API, ou nil se sem filtro.
  #   Tavily → time_range direto ("day"/"week"/...)
  #   Exa    → startPublishedDate ISO 8601 (hoje menos N dias)
  #   Linkup → fromDate ISO 8601 (hoje menos N dias)
  # `today:` permite teste determinístico.
  def self.time_filter_for(provider, time_range, today: Date.today)
    days = TIME_RANGE_DAYS[time_range.to_s]
    return nil if days.nil?

    case provider
    when :tavily
      time_range.to_s
    when :exa, :linkup
      (today - days).iso8601
    else
      nil
    end
  end

  # ── Clamp de limit (Spec 1.g) ──────────────────────────────────────────────
  def self.clamp_limit(n)
    [[n.to_i, 1].max, MAX_RESULTS].min
  end

  # ── Internals de rede e cota (cobertos pelos testes Rails/WebMock) ──────────

  # Tenta UMA API: 1 retry só em timeout/5xx (Refinamento SOTA 3); 401/400/429/
  # cota esgotada NÃO retry — o fallback é o tratamento.
  #
  # `score_threshold:` é recebido explicitamente (e não lido de ENV dentro do
  # método) para poder ser testado de forma isolada e determinística — ver
  # /test/services/search_api_router_fallback_pure_test.rb (Defeito 2). O default
  # chama a classe (SearchApiRouter.score_threshold) para não criar referência
  # circular ao próprio parâmetro.
  def self.attempt(provider, query, limit, time_range, today, score_threshold: SearchApiRouter.score_threshold, retried: false)
    time_filter = time_filter_for(provider, time_range, today: today)
    response = http_post(provider, query, limit, time_filter)

    unless response[:ok]
      # 429/401/400 → pula (sem retry). timeout/5xx → 1 retry (Refinamento SOTA 3).
      retryable = response[:retryable]
      if retryable && !retried
        Rails.logger.warn("[SearchApiRouter] #{provider} retryável (#{response[:reason]}); 1 retry")
        return attempt(provider, query, limit, time_range, today, score_threshold: score_threshold, retried: true)
      end
      return [nil, response[:reason]]
    end

    normalized = normalize_results(provider, response[:body], score_threshold: score_threshold)
    if normalized.empty?
      # HTTP 200, mas 0 resultados úteis (seja JSON results=[] vazio cru da API,
      # seja todos os resultados filtrados por score/lixo). Em ambos os casos a API
      # respondeu 200 com sucesso: incrementamos a cota, devolvemos {results: [],
      # engine: provider.to_s, cost:}, e NÃO caímos em fallback para Exa/Linkup.
      # O WebSearchTool preservará o erro original do SearXNG sem cachear sucesso.
      Rails.logger.info("[SearchApiRouter] #{provider} 200, 0 resultados úteis (vazio ou filtrados por score)")
    end

    increment_quota(provider)
    cost = extract_cost(provider, response[:body])
    [{ results: normalized, engine: provider.to_s, cost: cost }, nil]
  rescue StandardError => e
    [nil, "#{e.class}: #{e.message}"]
  end

  # Executa o POST HTTP da API. Devolve {ok:, body:, reason:, retryable:}.
  def self.http_post(provider, query, limit, time_filter)
    uri, req = build_request(provider, query, limit, time_filter)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    begin
      res = http.request(req)
    rescue Net::OpenTimeout, Net::ReadTimeout
      return { ok: false, reason: "timeout", retryable: true }
    rescue StandardError => e
      return { ok: false, reason: e.message, retryable: false }
    end

    unless res.is_a?(Net::HTTPSuccess)
      # Spec 1.a: timeout/5xx → 1 retry (retryable=true); 4xx (400/401/429) →
      # pula direto (retryable=false) — o fallback é o tratamento.
      retryable = (500..599).cover?(res.code.to_i)
      retry_after = (res["Retry-After"] || res["retry-after"]) if res.respond_to?(:[])
      reason = "HTTP #{res.code}"
      if retry_after && !retry_after.to_s.strip.empty?
        retry_val = retry_after.to_s.strip
        Rails.logger.warn("[SearchApiRouter] #{provider} retornou Retry-After: #{retry_val}")
        reason = "#{reason} (Retry-After: #{retry_val})"
      end
      return { ok: false, reason: reason, retryable: retryable }
    end

    begin
      body = JSON.parse(res.body)
    rescue JSON::ParserError
      return { ok: false, reason: "JSON inválido", retryable: false }
    end

    { ok: true, body: body, reason: nil, retryable: false }
  end

  def self.build_request(provider, query, limit, time_filter)
    case provider
    when :tavily
      uri = URI("https://api.tavily.com/search")
      body = {
        query: query, topic: "general", search_depth: "basic",
        max_results: limit, include_answer: false, include_raw_content: false,
        include_usage: true,
        # Refinamentos SOTA (SEARCH_API_SOTA_NOTES.md §1): economia de
        # crédito/token. `chunks_per_source: 1` ~500 tokens/URL (o basic já
        # devolve o chunk reranqueado); `auto_parameters` NUNCA true (poderia
        # escalar sozinho para advanced = 2 créditos). `include_answer:false`
        # permanece (Refinamento SOTA 4): o LLM raciocina sobre as fontes puras.
        # `include_usage: true` (Spec 1.h / SOTA §1) para expor usage.credits.
        chunks_per_source: 1, auto_parameters: false
      }
      body[:time_range] = time_filter if time_filter
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{ENV['TAVILY_API_KEY']}"
    when :exa
      uri = URI("https://api.exa.ai/search")
      body = {
        query: query, type: "auto", numResults: limit,
        contents: { highlights: true }
      }
      body[:startPublishedDate] = time_filter if time_filter
      req = Net::HTTP::Post.new(uri)
      req["x-api-key"] = ENV["EXA_API_KEY"]
    when :linkup
      uri = URI("https://api.linkup.so/v1/search")
      body = {
        q: query, depth: "standard", outputType: "searchResults", maxResults: limit
      }
      body[:fromDate] = time_filter if time_filter
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{ENV['LINKUP_API_KEY']}"
    else
      raise ArgumentError, "provider desconhecido: #{provider}"
    end
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req.body = JSON.generate(body)
    [uri, req]
  end

  # Custo quando a API expõe (Spec 1.h / Refinamento SOTA 7) — só para log.
  def self.extract_cost(provider, body)
    case provider
    when :tavily
      body.dig("usage", "credits")
    when :exa
      body.dig("costDollars")
    else
      nil
    end
  end

  # ── Cota mensal por API (Spec 1.b / Refinamento SOTA 3) ────────────────────
  # Tabela `search_api_quotas` (api_name, month 'YYYY-MM', count) com find_or_create
  # + increment DENTRO de with_lock (padrão validado pelo sol — ver cookie_jar.rb).

  def self.current_month
    if defined?(Time.current) && Time.current
      Time.current.in_time_zone("America/Sao_Paulo").strftime("%Y-%m")
    else
      Time.now.strftime("%Y-%m")
    end
  end

  def self.quota_ceiling(provider)
    ENV.fetch(QUOTA_ENV[provider], DEFAULT_QUOTA[provider].to_s).to_i
  end

  def self.score_threshold
    ENV.fetch(SCORE_THRESHOLD_ENV, DEFAULT_SCORE_THRESHOLD.to_s).to_f
  end

  # Fail-open intencional: se o banco estiver indisponível ou ocorrer erro
  # no modelo de cota, a busca externa não é bloqueada (retorna false).
  def self.quota_exceeded?(provider)
    return false unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.exceeded?(provider.to_s, quota_ceiling(provider), month: current_month)
  rescue StandardError => e
    Rails.logger.warn("[SearchApiRouter] erro ao verificar cota de #{provider}: #{e.message}")
    false
  end

  # Fail-open intencional: falha no incremento de cota não derruba a busca do usuário.
  def self.increment_quota(provider)
    return unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.increment(provider.to_s, month: current_month)
  rescue StandardError => e
    Rails.logger.warn("[SearchApiRouter] erro ao incrementar cota de #{provider}: #{e.message}")
  end
end
