# frozen_string_literal: true

require "net/http"
require "json"
require "date"

# Roteador de busca multi-API (Linkup → Exa → Tavily) para fallback do SearXNG.
#
# Contexto: o WebSearchTool busca via SearXNG local. Quando o SearXNG falha
# (erro HTTP, engines fora do ar, zero resultados), este router é chamado
# ANTES de devolver o erro — ele tenta as APIs externas em ordem de fallback.
# Se alguma servir, o resultado entra como success normal.
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
  # Ordem de especialidade: Linkup (factual single-hop) → Exa (semântico/papers) → Tavily (lookup rápido).
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

  # Regexes de especialidade para continuação de cascata após 200 vazio (miss).
  EXA_SPECIALTY_PATTERN = /paper|arxiv|pubmed|semelhante|o que [eé]|conceitual|machine learning|pesquisa/i
  TAVILY_SPECIALTY_PATTERN = /como instalar|gem install|pattern matching|documenta[cç][aã]o|lookup|instala[cç][aã]o/i

  # Timeout idêntico ao do WebSearchTool (Spec 1.a).
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 20
  # F1 do plano v2 (30/08/2026): teto do router desce a 5 (era 10), mesmo
  # teto do WebSearchTool. Camada única no cleitin: clamp em UM lugar só,
  # repetido é divergência esperando para acontecer.
  MAX_RESULTS  = 5

  # Mapa de time_range (day/week/month/year) → dias para recuar a data inicial.
  TIME_RANGE_DAYS = { "day" => 1, "week" => 7, "month" => 30, "year" => 365 }.freeze

  # ── Classificador de especialidade ─────────────────────────────────────────

  # Identifica a especialidade da query para decidir se continua a cascata após miss vazio.
  # @return [:exa, :tavily, nil]
  def self.specialty_for(query)
    q = query.to_s
    if q.match?(EXA_SPECIALTY_PATTERN)
      :exa
    elsif q.match?(TAVILY_SPECIALTY_PATTERN)
      :tavily
    else
      nil
    end
  end

  def self.current_date
    if defined?(Time.current) && Time.current
      Time.current.in_time_zone("America/Sao_Paulo").to_date
    else
      Date.today
    end
  end

  # ── API pública (usada pelo WebSearchTool#run) ─────────────────────────────

  # Tenta as APIs externas em ordem de fallback.
  #
  # Contrato (decisão do maestro, 30/08/2026, plano v2 F2 — alinha a
  # comportamento da tool com o que o plano promete):
  #
  # `specialty:` presente e HABILITADO (provider em PROVIDERS + provider com
  #   chave em ENV + !quota_exceeded?):
  #     UMA tentativa. Sucesso → retorna. Fail OU 200-vazio → retorna nil
  #     (NÃO cascata; a cota do preferred já foi cobrada no attempt).
  #
  # `specialty:` presente mas NÃO habilitado (sem chave / cota zerada /
  #   valor fora do PROVIDERS):
  #     Degrada para cascata padrão (linkup → exa → tavily), idêntica ao
  #     caminho sem specialty. Comportamento defensivo: o caller pediu um
  #     provedor que não está disponível, então cai no legado.
  #
  # `specialty:` ausente (`auto`):
  #     Fluxo legado intacto: cascata padrão (linkup → exa → tavily), com a
  #     regra de especialidade por regex (`specialty_for(query)`) que filtra
  #     a fila após 200-vazio (papers → exa, lookup → tavily, factual
  #     genérica → para no linkup).
  #
  # @return [Hash, nil] { results:, engine:, cost: } em sucesso, ou nil se todas falharem.
  def self.call(query:, limit: 5, time_range: nil, today: current_date, specialty: nil)
    providers = ordered_providers
    return nil if providers.empty? # sem nenhuma chave → router desligado (Spec 1.d)

    limit = clamp_limit(limit)
    tr = time_range if TIME_RANGE_DAYS.key?(time_range.to_s)
    reasons = []
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # ── Caminho A: specialty habilitado → UMA tentativa, sem cascata ─────────
    # Essa é a diferença material do contrato: se o caller disse QUAL provedor
    # usar (via `type:` do schema), só esse provedor paga. Se ele falhar ou
    # devolver vazio, a cota já foi cobrada no attempt — chamar outro seria
    # gastar cota fora do tipo escolhido (violação do plano v2 F2).
    if specialty_enabled?(specialty, providers)
      result, reason = attempt(specialty, query, limit, tr, today)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      if result.is_a?(Hash) && result[:results].any?
        Rails.logger.info(
          "[SearchApiRouter] #{specialty} (specialty) serviu a busca por #{query.inspect}" \
          " (custo: #{result[:cost]}, latência: #{elapsed_ms}ms)"
        )
        return result
      elsif result.is_a?(Hash)
        # 200 vazio no specialty habilitado: miss. NÃO cascata — retorna nil
        # e o caller (WebSearchTool) cai no erro "busca indisponível".
        reasons << "#{specialty}: 200 vazio (miss de specialty)"
        Rails.logger.warn("[SearchApiRouter] specialty #{specialty} miss para #{query.inspect}; sem cascata")
      else
        reasons << "#{specialty}: #{reason}"
        Rails.logger.warn("[SearchApiRouter] specialty #{specialty} falhou para #{query.inspect}: #{reason}; sem cascata")
      end

      Rails.logger.warn("[SearchApiRouter] specialty habilitado falhou para #{query.inspect}: #{reasons.join(' | ')}")
      return nil
    end

    # ── Caminho B: specialty ausente OU não habilitado → cascata padrão ──────
    # Mesmo se o caller pediu um specialty que não estava habilitado, caímos
    # aqui e aplicamos a cascata padrão (linkup → exa → tavily) com a regra
    # de regex (`specialty_for(query)`) que decide se o 200-vazio de um
    # provider deve avançar para outro de especialidade compatível.
    query_specialty = specialty_for(query)

    # Specialty explícito que NÃO está habilitado NÃO interfere na cascata
    # padrão (o caller pediu, mas o provider não estava disponível). A
    # cascata segue a ordem de fallback por chave presente.
    providers_to_try = providers.dup

    until providers_to_try.empty?
      provider = providers_to_try.shift

      next if quota_exceeded?(provider) # cota do mês esgotada → pula direto (fast-path)

      result, reason = attempt(provider, query, limit, tr, today)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      if result.is_a?(Hash) && result[:results].any?
        Rails.logger.info(
          "[SearchApiRouter] #{provider} serviu a busca por #{query.inspect}" \
          " (custo: #{result[:cost]}, latência: #{elapsed_ms}ms)"
        )
        return result
      elsif result.is_a?(Hash)
        # 200 com results=[] -> miss. Avança a cascata SÓ SE a query casar
        # com a especialidade do próximo (regex `query_specialty`). Sem
        # match: para a cascata (factual genérico / type=auto sem regex).
        if query_specialty
          providers_to_try.select! { |p| p == query_specialty }
        else
          providers_to_try.clear
        end
        reasons << "#{provider}: 200 vazio (miss)"
      else
        # Falha (HTTP não-200, timeout, parse, OU quota_exceeded sob
        # concorrência entre a pre-check e o reserve). Em qualquer caso,
        # não há resultado pra devolver — segue para o próximo provider
        # da cascata, respeitando a regra de especialidade.
        reasons << "#{provider}: #{reason}"
        if reason == "quota_exceeded"
          # Cota estourou entre o fast-path e o reserve: marca como pulado,
          # mas NÃO filtra a cascata por especialidade — é o mesmo
          # comportamento de `next if quota_exceeded?`.
          Rails.logger.info("[SearchApiRouter] #{provider} cota estourou durante attempt; pulando")
          # Não cascata adicional: a regra de especialidade pós-200-vazio
          # não se aplica a falhas pré-HTTP. Mantém a fila intacta.
        else
          Rails.logger.warn("[SearchApiRouter] #{provider} falhou para #{query.inspect}: #{reason}")
        end
      end
    end

    Rails.logger.warn("[SearchApiRouter] todas as APIs falharam para #{query.inspect}: #{reasons.join(' | ')}")
    nil
  end

  # ── Helpers do contrato de specialty ────────────────────────────────────────

  # `specialty:` só está habilitado se: (1) for um provider válido da
  # cascata paga, (2) tiver chave em ENV (provider apareceu em
  # `ordered_providers`), e (3) NÃO estiver com cota zerada do mês.
  # Sem essas três condições, o caminho A é pulado e o B (cascata padrão)
  # entra — degrada graciosamente.
  def self.specialty_enabled?(specialty, providers)
    return false if specialty.nil?
    return false unless PROVIDERS.include?(specialty)
    return false unless providers.include?(specialty)
    return false if quota_exceeded?(specialty)

    true
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
  def self.time_filter_for(provider, time_range, today: current_date)
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

  # Tenta UMA API: 1 retry só em timeout/5xx; 401/400/429/cota esgotada NÃO retry.
  #
  # F3a (Refinamento F2 + E10): a reserva de quota virou atômica via
  # `SearchApiQuota.reserve_quota!`, chamada ANTES do HTTP. Isso funde
  # `exceeded?` + `increment` numa única transação, eliminando o TOCTOU do
  # bug E10 (dois `with_lock` separados davam janela para dois providers
  # acreditarem que a cota estava livre).
  #
  # Fluxo:
  #   1. `reserve_quota!` → false: retorna [:quota_exceeded] (sem HTTP, sem cobrança).
  #   2. HTTP não-200 / timeout / erro de rede → `rollback_quota!` + retorna falha.
  #   3. HTTP 200 (mesmo com results vazio) → COBRADO. Sem rollback.
  #
  # Retry: no caminho recursivo (retried=true) NÃO chama reserve_quota! de
  # novo — a reserva original cobre o retry. Apenas re-tenta o HTTP.
  def self.attempt(provider, query, limit, time_range, today, score_threshold: SearchApiRouter.score_threshold, retried: false)
    unless retried
      # `reserve_quota!` já é fail-open lá dentro se o AR não estiver conectado,
      # mas aqui a função é estritamente "decide se pode gastar". Se a cota
      # está cheia, pula o provider sem gastar HTTP.
      reserved = reserve_quota_or_skip(provider)
      return [nil, "quota_exceeded"] if reserved == false
    end

    time_filter = time_filter_for(provider, time_range, today: today)
    response = http_post(provider, query, limit, time_filter)

    unless response[:ok]
      # 429/401/400 → pula (sem retry). timeout/5xx → 1 retry.
      retryable = response[:retryable]
      if retryable && !retried
        Rails.logger.warn("[SearchApiRouter] #{provider} retryável (#{response[:reason]}); 1 retry")
        # NÃO reservamos de novo no retry (a reserva original cobre o 1 retry).
        return attempt(provider, query, limit, time_range, today, score_threshold: score_threshold, retried: true)
      end
      # Falha terminal (sem retry ou retry esgotado): reverte a reserva.
      # Cobrimos: 1ª falha COM retry (rollback após o retry falhar) E
      # 1ª falha SEM retry (rollback imediato). Cobrir o caso `retried=true`
      # garante que reserva+retry+falha = sem cobrança.
      rollback_quota_silently(provider)
      return [nil, response[:reason]]
    end

    normalized = normalize_results(provider, response[:body], score_threshold: score_threshold)
    if normalized.empty?
      Rails.logger.info("[SearchApiRouter] #{provider} 200, 0 resultados úteis (vazio ou filtrados por score) — quota COBRADA (200 vazio cobra)")
    end

    # Sucesso (200 qualquer, inclusive vazio): quota já foi reservada em (1).
    # NÃO chama `increment_quota` aqui — reserva já incrementou.
    cost = extract_cost(provider, response[:body])
    [{ results: normalized, engine: provider.to_s, cost: cost }, nil]
  rescue StandardError => e
    # Erro inesperado (ex.: exception de parsing, NoMethodError). Reverte a
    # reserva. Como a reserva só ocorre uma vez (no caminho `!retried`), o
    # rollback aqui cobre tanto a 1ª tentativa quanto o retry — em ambos os
    # casos houve cobrança que precisa ser revertida.
    rollback_quota_silently(provider)
    [nil, "#{e.class}: #{e.message}"]
  end

  # Envelope fail-open do `reserve_quota!`. Se AR indisponível ou erro de
  # banco, retornamos `true` (fail-open: a busca não é bloqueada por erro de
  # cota). Se a cota realmente está cheia, `reserve_quota!` retorna `false`
  # e nós propagamos.
  def self.reserve_quota_or_skip(provider)
    return true unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.reserve_quota!(provider.to_s, ceiling: quota_ceiling(provider), month: current_month)
  rescue StandardError => e
    Rails.logger.warn("[SearchApiRouter] erro ao reservar cota de #{provider}: #{e.message}")
    true # fail-open
  end

  # Envelope fail-open do `rollback_quota!`. Falha ao reverter não derruba
  # a busca; só logamos.
  def self.rollback_quota_silently(provider)
    return unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.rollback_quota!(provider.to_s, month: current_month)
  rescue StandardError => e
    Rails.logger.warn("[SearchApiRouter] erro ao reverter cota de #{provider}: #{e.message}")
  end

  # Executa o POST HTTP da API. Devolve {ok:, body:, reason:, retryable:}.
  # Net::HTTP cru com endpoint constante (não é URL fornecida pelo usuário, risco SSRF baixo)
  # pois Fetcher::SafeHttpClient hoje é apenas GET.
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
        # `num_sentences: 2` (F1 plano v2): Exa sem teto por highlight pode
        # devolver parágrafos inteiros, fugindo do CONTENT_MAX_CHARS=200 do
        # WebSearchTool. Travado em 2 frases = bem abaixo do teto de 200
        # chars e mata o vetor de UGC comprido (D4).
        contents: { highlights: { num_sentences: 2 } }
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

  # ── Cota mensal por API (Spec 1.b / Refinamento SOTA 3 / F3a) ───────────────
  # Tabela `search_api_quotas` (api_name, month 'YYYY-MM', count).
  #
  # F3a introduziu `reserve_quota!` / `rollback_quota!` no modelo
  # `SearchApiQuota` para fundir check+increment numa única transação atômica
  # (corrige o TOCTOU do E10). O router chama `reserve_quota!` ANTES do HTTP
  # e reverte com `rollback_quota!` apenas em falha HTTP. `quota_exceeded?`
  # e `increment_quota` continuam aqui como helpers fail-open públicos
  # (chamados pelo fail-open check e pelo caminho legado de testes) e como
  # fast-path de cascata.

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
