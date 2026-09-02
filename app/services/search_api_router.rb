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

  DEFAULT_PAID_SEARCH_LIMIT = 10
  PAID_SEARCH_LIMIT_ENV = "PAID_SEARCH_PER_TURN_LIMIT"

  # Regexes de especialidade para continuação de cascata após 200 vazio (miss).
  EXA_SPECIALTY_PATTERN = /paper|arxiv|pubmed|semelhante|o que [eé]|conceitual|machine learning|pesquisa/i
  # F4 do plano-fase2 (30/08/2026): `notícia`/`noticias`/`news`/`headline`/
  # `breaking` entram na lista Tavily. Antes só lookup técnico casava. Agora
  # o regex de Tavily captura o que ele já é pago pra fazer (recência +
  # manchetes) — a entrada é ADITIVA, não substitui nada. Sinais PT-BR
  # e EN convivem; ordem não importa (regex alternation).
  TAVILY_SPECIALTY_PATTERN = /como instalar|gem install|pattern matching|documenta[cç][aã]o|lookup|instala[cç][aã]o|not[ií]cia|noticias|news|headline|breaking/i

  # Timeout idêntico ao do WebSearchTool (Spec 1.a).
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 20
  # F1 do plano v2 (30/08/2026): teto do router desce a 5 (era 10), mesmo
  # teto do WebSearchTool. Camada única no cleitin: clamp em UM lugar só,
  # repetido é divergência esperando para acontecer.
  MAX_RESULTS  = 5

  # Mapa de time_range (day/week/month/year) → dias para recuar a data inicial.
  TIME_RANGE_DAYS = { "day" => 1, "week" => 7, "month" => 30, "year" => 365 }.freeze

  # ── Classificador `trust` (F7, plano-fase2 31/08/2026) ───────────────────
  # Categoriza hosts por nível de confiança para o leitor humano do chatbot:
  #
  #   :primary — fonte original/autoral (gov, jornal reputado, arxiv, repo).
  #              Pode ser citada como fato sem segunda fonte quando escassa.
  #   :ugc     — conteúdo gerado por usuário (reddit, x, linkedin, stackoverflow,
  #              forum.*). Pode ser fonte ÚNICA em técnico, mas não em notícia.
  #   :unknown — agregador/blog pessoal/wikipedia/mídia não listada. NÃO conta
  #              como fonte confiável sozinha — exige segunda fonte primária.
  #
  # Lista calibrada pela amostra E7 de 50 hosts (brief F7). Wildcards ficam em
  # TRUST_WILDCARDS (sufixo com ponto: `forum.` casa forum.alura.com.br,
  # `gov.` casa gov.br/gov.uk). Match exato em TRUST_TABLE é verificado
  # ANTES do wildcard — assim `reddit.com` continua :ugc mesmo se algum
  # futuro wildcard global existir.
  #
  # Contrato: a tabela é a única fonte do classificador. Adicionar/rotular
  # um novo host é aqui, não em código espalhado.
  TRUST_TABLE = {
    # UGC (conteúdo gerado por usuário)
    "reddit.com"        => :ugc,
    "x.com"             => :ugc,
    "twitter.com"       => :ugc,
    "linkedin.com"      => :ugc,
    "stackoverflow.com" => :ugc,
    # Primary (fonte original/autoral)
    "gov.br"        => :primary,
    "gov.uk"        => :primary,
    "arxiv.org"     => :primary,
    "reuters.com"   => :primary,
    "nature.com"    => :primary,
    "who.int"       => :primary,
    "imf.org"       => :primary,
    "nytimes.com"   => :primary,
    "apnews.com"    => :primary,
    "bcb.gov.br"    => :primary,
    "github.com"    => :primary
  }.freeze

  # Wildcards de sufixo: a chave é o sufixo COM ponto (inicial pra end_with,
  # sem ponto inicial pra start_with), e o match é `host.start_with?(chave)`
  # OU `host.end_with?(chave)` conforme a entrada. Cobre:
  #   `forum.alura.com.br`, `forum.example.org` — `start_with?("forum.")`
  #   `gov.br`, `www.gov.br`, `bcb.gov.br`, `gov.uk` — `end_with?(".gov*")`
  #
  # D4-F7-v2: o wildcard antigo era `"gov."` com `start_with?`, o que fazia
  # QUALQUER host começando com "gov." virar `:primary` — incluindo o
  # canônico `gov.example.evil` (host malicioso hipotético). A semântica
  # correta para gov é match por SUFIXO de TLD real: o host precisa TERMINAR
  # em `.gov`, `.gov.br`, `.gov.uk`. Isso é seguro porque `.gov` é restrito
  # por IANA — nenhum domínio malicioso comum termina em `.gov`.
  #
  # O `forum.` continua como `start_with?` (sufixo com ponto à direita):
  # `forum.X` é UGC por convenção — o sufixo é "forum." (não ".forum" nem
  # `.com`); nenhum host legítimo é "forum" como TLD. O `start_with?` é
  # seguro aqui porque exige o ponto à direita, então não casa "forum" solto
  # nem "forumXYZ" (sem ponto).
  #
  # Mantidos separados da TRUST_TABLE para o lookup ser óbvio (hash de
  # sufixos vs hash de hosts). Resultado da ordem de avaliação:
  # match exato > sufixo de TRUST_TABLE > TRUST_WILDCARDS_START >
  # TRUST_WILDCARDS_END > :unknown.
  TRUST_WILDCARDS_START = {
    "forum." => :ugc
  }.freeze
  TRUST_WILDCARDS_END = {
    ".gov"    => :primary,
    ".gov.br" => :primary,
    ".gov.uk" => :primary
  }.freeze
  # Alias preservado para compatibilidade de testes/inspect existentes;
  # união lógica (apenas leitura conceitual).
  TRUST_WILDCARDS = TRUST_WILDCARDS_START.merge(TRUST_WILDCARDS_END).freeze

  # Classifica o host por trust. Aceita URL completa ou só o hostname. Default
  # :unknown (agregador / blog pessoal / mídia não listada — o leitor humano
  # precisa de uma segunda fonte primária antes de afirmar). Nunca levanta:
  # input vazio/nil/whitespace cai em :unknown.
  #
  # Ordem de avaliação (defesa em profundidade):
  #   1. TRUST_TABLE[host] exato
  #   2. TRUST_TABLE por sufixo `.suffix` — `www.reddit.com` casa `.reddit.com`.
  #      NÃO usado para hosts curtos demais (≤ suffix.length) para evitar
  #      `x.com.br` casar `.x.com` (defesa testada em `x.com.br`).
  #   3a. TRUST_WILDCARDS_START por start_with (sufixo `xxx.`) — `forum.`
  #   3b. TRUST_WILDCARDS_END   por end_with   (sufixo `.xxx`) — `.gov` /
  #        `.gov.br` / `.gov.uk`. D4-F7-v2: era `start_with?("gov.")` e
  #        casava QUALQUER host começando com "gov." (inclusive
  #        `gov.example.evil`). Agora exige TERMINAR no TLD `.gov*` — `.gov`
  #        é restrito por IANA, então não há colisão com host malicioso.
  #   4. :unknown
  #
  # @param url_or_host [String, nil]
  # @return [Symbol] :primary, :ugc, ou :unknown
  def self.trust_for(url_or_host)
    host = host_from(url_or_host)
    return :unknown if host.empty?

    # 1. Match exato na tabela calibrada (caso `reddit.com`, `github.com`...).
    return TRUST_TABLE[host] if TRUST_TABLE.key?(host)

    # 2. Match por sufixo `.suffix` — `www.reddit.com` casa `.reddit.com`.
    #    Guarda: host precisa ser mais longo que o suffix para evitar
    #    `x.com.br` casar `.x.com` (string contém o suffix mas não é subdomínio).
    TRUST_TABLE.each do |suffix, label|
      next if host.length <= suffix.length
      return label if host.end_with?(".#{suffix}")
    end

    # 3a. Wildcard por PREFIXO (`xxx.`) — `forum.alura.com.br` casa.
    #     Sufixo termina com ponto, então exige fronteira de label.
    TRUST_WILDCARDS_START.each do |suffix, label|
      return label if host.start_with?(suffix)
    end

    # 3b. Wildcard por SUFIXO (`.xxx`) — `www.gov.br` casa `.gov.br`.
    #     D4-F7-v2: exige TLD real (host.end_with? — sem ambiguidade de prefix).
    TRUST_WILDCARDS_END.each do |suffix, label|
      return label if host.end_with?(suffix)
    end

    # 4. Default
    :unknown
  end

  # Extrai o hostname de uma URL ou devolve o próprio valor se já for hostname.
  # Robusto contra nil/whitespace/invalid URI — qualquer falha → "".
  def self.host_from(url_or_host)
    s = url_or_host.to_s.strip
    return "" if s.empty?

    # Se tem scheme, parseia como URI; senão, é hostname cru.
    if s.include?("://")
      begin
        uri = URI.parse(s)
        return uri.host.to_s.downcase.strip
      rescue URI::InvalidURIError
        return ""
      end
    end

    s.downcase
  end

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
  # F3b: `origin:` identifica o caller (`:discord` / `:mcp` / nil). É
  # propagado para `reserve_quota!` / `rollback_quota!` para alimentar a
  # métrica por origem (count_discord, count_mcp) e a exceção do piso 5%
  # pro bot. Default = nil (chamada sem origem).
  #
  # @return [Hash, nil] { results:, engine:, cost: } em sucesso, ou nil se todas falharem.
  def self.call(query:, limit: 5, time_range: nil, today: current_date, specialty: nil, origin: nil)
    return nil if paid_search_limit_reached?

    providers = ordered_providers
    return nil if providers.empty? # sem nenhuma chave → router desligado (Spec 1.d)

    increment_paid_search_count!

    limit = clamp_limit(limit)
    tr = time_range if TIME_RANGE_DAYS.key?(time_range.to_s)
    reasons = []
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # ── Caminho A: specialty habilitado → UMA tentativa, sem cascata ─────────
    # Essa é a diferença material do contrato: se o caller disse QUAL provedor
    # usar (via `type:` do schema), só esse provedor paga. Se ele falhar ou
    # devolver vazio, a cota já foi cobrada no attempt — chamar outro seria
    # gastar cota fora do tipo escolhido (violação do plano v2 F2).
    if specialty_enabled?(specialty, providers, origin: origin)
      result, reason = attempt(specialty, query, limit, tr, today, origin: origin)
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
    #
    # F4 do plano-fase2 (30/08/2026): o 1º pago da cascata passa a ser a
    # ESPECIALIDADE (quando `specialty_for(query)` casa). Antes era sempre
    # Linkup (1º do PROVIDERS estático). NUNCA alteramos PROVIDERS — só a
    # ordem de TRABALHO interna. Cobertura do plano:
    #   - arxiv + SearXNG down → Exa primeiro no pago
    #   - time_range=day + notícia no Discord → Tavily primeiro no pago
    #   - generic factual → Linkup primeiro (comportamento atual preservado)
    query_specialty = specialty_for(query)

    # Specialty explícito que NÃO está habilitado NÃO interfere na cascata
    # padrão (o caller pediu, mas o provider não estava disponível). A
    # cascata segue a ordem de fallback por chave presente.
    #
    # F4: reordenação interna (NÃO muda PROVIDERS). Quando `query_specialty`
    # é :tavily ou :exa, ele vira o 1º da fila; os demais pagam caem depois
    # na ordem original do PROVIDERS. Sem especialidade (factual genérico) a
    # fila permanece como `PROVIDERS` — Linkup 1º preservado.
    providers_to_try = reorder_by_specialty(providers, query_specialty)

    until providers_to_try.empty?
      provider = providers_to_try.shift

      next if quota_exceeded?(provider, origin: origin) # cota do mês esgotada → pula direto (fast-path)

      result, reason = attempt(provider, query, limit, tr, today, origin: origin)
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

  # F4 do plano-fase2 (30/08/2026): reordena a FILA de trabalho (NÃO o
  # PROVIDERS estático). Quando `specialty` é :tavily ou :exa, esse provider
  # vira o 1º da fila. Sem especialidade (nil) ou especialidade fora de
  # PROVIDERS, devolve `providers` na ordem original — comportamento
  # legado preservado.
  #
  # Importante: `providers` aqui é o resultado de `ordered_providers`
  # (filtrado por chave). Se `specialty` não estiver nessa lista (sem
  # chave), caímos no fallback de `PROVIDERS` para preservar a ordem
  # original e o caller não vê diferença.
  def self.reorder_by_specialty(providers, specialty)
    return providers.dup if specialty.nil?
    return providers.dup unless PROVIDERS.include?(specialty)
    return providers.dup unless providers.include?(specialty)

    [specialty, *providers.reject { |p| p == specialty }]
  end

  # `specialty:` só está habilitado se: (1) for um provider válido da
  # cascata paga, (2) tiver chave em ENV (provider apareceu em
  # `ordered_providers`), e (3) NÃO estiver com cota zerada do mês
  # (verificando via `quota_exceeded?(provider, origin:)` para que o piso
  # discord seja respeitado pelo fast-path — sem origin, comportamento
  # legado: teto único puro).
  # Sem essas condições, o caminho A é pulado e o B (cascata padrão)
  # entra — degrada graciosamente.
  def self.specialty_enabled?(specialty, providers, origin: nil)
    return false if specialty.nil?
    return false unless PROVIDERS.include?(specialty)
    return false unless providers.include?(specialty)
    return false if quota_exceeded?(specialty, origin: origin)

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
    url = r["url"]
    base = case provider
           when :tavily
             { title: r["title"], url: url, content: r["content"], engine: "tavily", _score: r["score"] }
           when :exa
             content = r["text"] || Array(r["highlights"]).first
             { title: r["title"], url: url, content: content, engine: "exa" }
           when :linkup
             { title: r["name"], url: url, content: r["content"], engine: "linkup" }
           else
             return nil
           end
    # F7 (plano-fase2 31/08/2026): classificador `trust` por host. Cada item
    # do resultado carrega o selo junto com title/url/content/engine, e chega
    # ao modelo do perfil via `Responder.from` (MCP) e `success(data)` (bot).
    # Default :unknown para hosts ausentes da lista calibrada — o leitor humano
    # precisa de uma segunda fonte primária antes de afirmar como fato.
    base[:trust] = trust_for(url)
    base
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
  #
  # F3b: `origin:` é passado para os envelopes de quota. O `attempt` é o
  # ÚNICO lugar no router que toca `reserve_quota_or_skip` / `rollback_quota_silently`
  # — origem chega aqui de `call(...)` via parâmetro keyword.
  def self.attempt(provider, query, limit, time_range, today, score_threshold: SearchApiRouter.score_threshold, retried: false, origin: nil)
    unless retried
      # `reserve_quota_or_skip` (envelope abaixo, :396-403) é o ponto
      # fail-open: se AR não estiver conectado OU o `reserve_quota!` levantar
      # erro, a busca segue (retorna `true`). Aqui a função é estritamente
      # "decide se pode gastar": se a cota está cheia, pula o provider sem
      # gastar HTTP. O fail-open do rollback vive em `:407-413`.
      reserved = reserve_quota_or_skip(provider, origin: origin)
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
        return attempt(provider, query, limit, time_range, today, score_threshold: score_threshold, retried: true, origin: origin)
      end
      # Falha terminal (sem retry ou retry esgotado): reverte a reserva.
      # Cobrimos: 1ª falha COM retry (rollback após o retry falhar) E
      # 1ª falha SEM retry (rollback imediato). Cobrir o caso `retried=true`
      # garante que reserva+retry+falha = sem cobrança.
      rollback_quota_silently(provider, origin: origin)
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
    rollback_quota_silently(provider, origin: origin)
    [nil, "#{e.class}: #{e.message}"]
  end

  # Envelope fail-open do `reserve_quota!`. Se AR indisponível ou erro de
  # banco, retornamos `true` (fail-open: a busca não é bloqueada por erro de
  # cota). Se a cota realmente está cheia, `reserve_quota!` retorna `false`
  # e nós propagamos.
  #
  # F3b: propaga `origin:` para que `reserve_quota!` saiba se a chamada
  # tem a exceção do piso (discord) ou é mcp/nil (teto puro).
  def self.reserve_quota_or_skip(provider, origin: nil)
    return true unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.reserve_quota!(provider.to_s, ceiling: quota_ceiling(provider), month: current_month, origin: origin)
  rescue StandardError => e
    Rails.logger.warn("[SearchApiRouter] erro ao reservar cota de #{provider}: #{e.message}")
    true # fail-open
  end

  # Envelope fail-open do `rollback_quota!`. Falha ao reverter não derruba
  # a busca; só logamos.
  #
  # F3b: `origin:` propaga para reverter o contador de origem certo
  # (count_discord / count_mcp) junto com o count principal.
  def self.rollback_quota_silently(provider, origin: nil)
    return unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.rollback_quota!(provider.to_s, month: current_month, origin: origin)
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
        contents: { text: true }
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
  #
  # F3b: usa `exceeded_with_origin?` (regra canônica D1) em vez do
  # `exceeded?` legado (F3a). O piso 96-100% é exclusivo de `:discord`:
  # com origin :discord, o fast-path só bloqueia se count >= ceiling
  # (sem overage); com origin :mcp/nil, bloqueia em count >= mcp_limit
  # (95% do teto, ou teto=0 → bloqueia sempre).
  #
  # Kill-switch (ceiling <= 0) é checado ANTES da disponibilidade do AR:
  # se o teto é 0, o método bloqueia MESMO sem banco conectado. Isso
  # garante que `ceiling=0` fecha o router (defesa em profundidade contra
  # alguém que desligaria o AR para contornar o teto — o teto é do
  # plano, não da infra).
  def self.quota_exceeded?(provider, origin: nil)
    ceiling = quota_ceiling(provider)
    return true if ceiling <= 0

    return false unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.exceeded_with_origin?(
      provider.to_s,
      ceiling: ceiling,
      origin: origin,
      month: current_month
    )
  rescue StandardError => e
    Rails.logger.warn "[SearchApiRouter] erro ao verificar cota de #{provider}: #{e.message}"
    false
  end

  # Fail-open intencional: falha no incremento de cota não derruba a busca do usuário.
  def self.increment_quota(provider)
    return unless defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    SearchApiQuota.increment(provider.to_s, month: current_month)
  rescue StandardError => e
    Rails.logger.warn("[SearchApiRouter] erro ao incrementar cota de #{provider}: #{e.message}")
  end

  # ── Controle de teto de buscas pagas por turno ────────────────────────────
  def self.paid_search_limit
    val = ENV[PAID_SEARCH_LIMIT_ENV]
    val.present? ? val.to_i : DEFAULT_PAID_SEARCH_LIMIT
  end

  def self.active_scope_key(scope_key = nil)
    scope_key || Thread.current[:cleitin_conversation_scope_key] || :_default
  end

  def self.paid_search_counts
    Thread.current[:cleitin_paid_search_counts] ||= Hash.new(0)
  end

  def self.paid_search_count(scope_key = nil)
    key = active_scope_key(scope_key)
    paid_search_counts[key] || 0
  end

  def self.paid_search_limit_reached?(scope_key = nil)
    paid_search_count(scope_key) >= paid_search_limit
  end

  def self.increment_paid_search_count!(scope_key = nil)
    key = active_scope_key(scope_key)
    paid_search_counts[key] = paid_search_count(key) + 1
  end

  def self.reset_paid_search_count!(scope_key = nil)
    if scope_key
      paid_search_counts[scope_key] = 0
    else
      key = Thread.current[:cleitin_conversation_scope_key]
      if key
        paid_search_counts[key] = 0
      else
        Thread.current[:cleitin_paid_search_counts] = Hash.new(0)
      end
      paid_search_counts[:_default] = 0
    end
  end
end
