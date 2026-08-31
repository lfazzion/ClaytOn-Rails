# frozen_string_literal: true

require "minitest/autorun"

# Testes PUROS do SearchApiRouter — rodáveis com `ruby` puro (sem Rails/docker).
# Cobrem a lógica que NÃO depende de ActiveRecord/Net::HTTP:
#   normalização por API, dedupe por URL canônica, filtro de score (Tavily),
#   mapeamento de time_range e ordenação de fallback.
#
# O stub mínimo de Rails abaixo evita que o `require` do router quebre em ruby puro;
# não sobrescreve Rails.cache, Rails.logger ou Rails.env quando a suíte Rails estiver carregada.
unless defined?(Rails)
  module Rails
  end
end

unless Rails.respond_to?(:logger) && Rails.logger
  def Rails.logger
    @logger ||= Object.new.tap do |l|
      def l.info(*) = nil
      def l.warn(*) = nil
      def l.error(*) = nil
    end
  end
end

unless defined?(Rails::PureMemoryCacheStore)
  module Rails
    class PureMemoryCacheStore
      def initialize
        @data = {}
      end

      def read(key)
        @data[key]
      end

      def write(key, value, **_options)
        @data[key] = value
      end

      def clear
        @data.clear
      end
    end
  end
end

unless Rails.respond_to?(:cache) && Rails.cache
  def Rails.cache
    @pure_cache_instance ||= Rails::PureMemoryCacheStore.new
  end
end

unless Rails.respond_to?(:env)
  def Rails.env
    "test"
  end
end

require_relative "../../app/services/search_api_router"

class SearchApiRouterPureTest < Minitest::Test
  SEARCH_API_ENVS = %w[
    TAVILY_API_KEY
    EXA_API_KEY
    LINKUP_API_KEY
    SEARCH_API_QUOTA_TAVILY
    SEARCH_API_QUOTA_EXA
    SEARCH_API_QUOTA_LINKUP
    SEARCH_API_SCORE_THRESHOLD
  ].freeze

  def setup
    @saved_env = SEARCH_API_ENVS.to_h { |k| [k, ENV[k]] }
    SEARCH_API_ENVS.each { |k| ENV.delete(k) }
  end

  def teardown
    @saved_env.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end
  # ── Normalização Tavily (payload real da doc) ──────────────────────────────
  def test_normaliza_payload_real_do_tavily_com_engine_e_campos_mapeados
    raw = {
      "results" => [
        { "title" => "T1", "url" => "https://ex.com/a", "content" => "snippet", "score" => 0.9 },
        { "title" => "T2", "url" => "https://ex.com/b", "content" => "outro", "score" => 0.8 }
      ],
      "usage" => { "credits" => 2 }
    }
    out = SearchApiRouter.normalize_results(:tavily, raw, score_threshold: 0.7)
    assert_equal 2, out.size
    assert_equal "tavily", out.first[:engine]
    assert_equal "T1", out.first[:title]
    assert_equal "https://ex.com/a", out.first[:url]
    assert_equal "snippet", out.first[:content]
  end

  def test_filtro_de_score_descarta_resultados_tavily_abaixo_do_threshold
    raw = {
      "results" => [
        { "title" => "Alto", "url" => "https://ex.com/a", "content" => "c", "score" => 0.9 },
        { "title" => "Baixo", "url" => "https://ex.com/b", "content" => "c", "score" => 0.4 }
      ]
    }
    out = SearchApiRouter.normalize_results(:tavily, raw, score_threshold: 0.7)
    assert_equal 1, out.size
    assert_equal "Alto", out.first[:title]
  end

  def test_filtro_de_score_so_se_aplica_ao_tavily
    exa_raw = {
      "results" => [
        { "title" => "X", "url" => "https://ex.com/x", "text" => "corpo" }
      ]
    }
    out = SearchApiRouter.normalize_results(:exa, exa_raw, score_threshold: 0.99)
    assert_equal 1, out.size, "Exa não deve perder resultado por falta de score"
  end

  # ── Normalização Exa ──────────────────────────────────────────────────────
  def test_normaliza_exa_prefere_text_sobre_highlights
    raw = {
      "results" => [
        { "title" => "H", "url" => "https://ex.com/h", "highlights" => ["trecho destacado"], "text" => "corpo longo" },
        { "title" => "T", "url" => "https://ex.com/t", "text" => "só texto" }
      ]
    }
    out = SearchApiRouter.normalize_results(:exa, raw, score_threshold: 0.7)
    assert_equal 2, out.size
    assert_equal "exa", out.first[:engine]
    assert_equal "corpo longo", out.first[:content], "text deve ter prioridade sobre highlights"
    assert_equal "só texto", out.last[:content]
  end

  def test_normaliza_exa_usa_highlights_quando_text_falta
    raw = {
      "results" => [
        { "title" => "H", "url" => "https://ex.com/h", "highlights" => ["trecho destacado"] }
      ]
    }
    out = SearchApiRouter.normalize_results(:exa, raw, score_threshold: 0.7)
    assert_equal 1, out.size
    assert_equal "trecho destacado", out.first[:content]
  end

  # ── Normalização Linkup ───────────────────────────────────────────────────
  def test_normaliza_linkup_mapeando_name_para_title
    raw = {
      "results" => [
        { "name" => "L", "url" => "https://linkup.com/l", "content" => "conteúdo" }
      ]
    }
    out = SearchApiRouter.normalize_results(:linkup, raw, score_threshold: 0.7)
    assert_equal 1, out.size
    assert_equal "linkup", out.first[:engine]
    assert_equal "L", out.first[:title]
    assert_equal "https://linkup.com/l", out.first[:url]
  end

  # ── Dedupe por URL canônica (Refinamento SOTA 1) ───────────────────────────
  def test_dedupe_por_url_canonica_remove_query_e_barra_final
    raw = {
      "results" => [
        { "title" => "A", "url" => "https://ex.com/p?utm=1", "content" => "1" },
        { "title" => "B", "url" => "https://ex.com/p/", "content" => "2" },
        { "title" => "C", "url" => "https://ex.com/p", "content" => "3" }
      ]
    }
    out = SearchApiRouter.normalize_results(:tavily, raw, score_threshold: 0.0)
    assert_equal 1, out.size, "três URLs canônicas iguais devem virar 1"
    assert_equal "A", out.first[:title], "mantém a primeira ocorrência"
  end

  # ── Mapeamento time_range (Spec 1.f) ───────────────────────────────────────
  def test_time_range_tavily_vai_direto_no_body
    assert_equal "day", SearchApiRouter.time_filter_for(:tavily, "day", today: Date.new(2026, 8, 17))
    assert_equal "month", SearchApiRouter.time_filter_for(:tavily, "month", today: Date.new(2026, 8, 17))
  end

  def test_time_range_exa_vira_start_published_date_iso8601
    today = Date.new(2026, 8, 17)
    assert_equal "2026-08-16", SearchApiRouter.time_filter_for(:exa, "day", today: today)
    assert_equal "2026-08-10", SearchApiRouter.time_filter_for(:exa, "week", today: today)
    assert_equal "2026-07-18", SearchApiRouter.time_filter_for(:exa, "month", today: today)
    assert_equal "2025-08-17", SearchApiRouter.time_filter_for(:exa, "year", today: today)
  end

  def test_time_range_linkup_vira_from_date_iso8601
    today = Date.new(2026, 8, 17)
    assert_equal "2026-08-10", SearchApiRouter.time_filter_for(:linkup, "week", today: today)
  end

  def test_time_range_nil_nao_produz_filtro
    today = Date.new(2026, 8, 17)
    %i[tavily exa linkup].each do |p|
      assert_nil SearchApiRouter.time_filter_for(p, nil, today: today)
    end
  end

  # ── Clamp de limit (Spec 1.g) ──────────────────────────────────────────────
  def test_clamp_limit_respeita_1_a_5
    # F1 do plano v2 (30/08/2026): teto desce de 10 para 5. Camada única no
    # cleitin: o `WebSearchTool` (máx 5) e o `SearchApiRouter` (máx 5) batem
    # no mesmo número — `clamp_limit` é o gargalo final do router.
    assert_equal 1, SearchApiRouter.clamp_limit(0)
    assert_equal 1, SearchApiRouter.clamp_limit(-5)
    assert_equal 5, SearchApiRouter.clamp_limit(5)
    assert_equal 5, SearchApiRouter.clamp_limit(50)
  end

  # ── Ordenação de fallback / router desligado (Spec 1.d) ────────────────────
  def test_sem_nenhuma_chave_providers_vazio
    available = SearchApiRouter.ordered_providers(
      tavily: nil, exa: nil, linkup: nil
    )
    assert_empty available
  end

  def test_ordem_fallback_respeita_chaves_presentes
    available = SearchApiRouter.ordered_providers(
      tavily: "tv_key", exa: "ex_key", linkup: nil
    )
    assert_equal %i[exa tavily], available
  end

  def test_linkup_sem_chave_exa_vira_primeiro
    available = SearchApiRouter.ordered_providers(
      tavily: nil, exa: "ex_key", linkup: "lk_key"
    )
    assert_equal %i[linkup exa], available
  end

  # ── Classificador de especialidade (Item A) ──────────────────────────────
  def test_specialty_for_exa_queries
    assert_equal :exa, SearchApiRouter.specialty_for("papers sobre machine learning")
    assert_equal :exa, SearchApiRouter.specialty_for("arxiv transformers attention")
    assert_equal :exa, SearchApiRouter.specialty_for("pubmed covid vaccine")
    assert_equal :exa, SearchApiRouter.specialty_for("o que é Ruby on Rails")
    assert_equal :exa, SearchApiRouter.specialty_for("o que e machine learning")
    assert_equal :exa, SearchApiRouter.specialty_for("termo semelhante a Kubernetes")
    assert_equal :exa, SearchApiRouter.specialty_for("pesquisa sobre IA")
    assert_equal :exa, SearchApiRouter.specialty_for("artigo conceitual")
  end

  def test_specialty_for_tavily_queries
    assert_equal :tavily, SearchApiRouter.specialty_for("como instalar rails")
    assert_equal :tavily, SearchApiRouter.specialty_for("gem install devise")
    assert_equal :tavily, SearchApiRouter.specialty_for("ruby 3.4 pattern matching")
    assert_equal :tavily, SearchApiRouter.specialty_for("documentação do postgres")
    assert_equal :tavily, SearchApiRouter.specialty_for("documentacao do redis")
    assert_equal :tavily, SearchApiRouter.specialty_for("lookup de DNS")
    assert_equal :tavily, SearchApiRouter.specialty_for("instalação do docker")
    assert_equal :tavily, SearchApiRouter.specialty_for("instalacao do docker")
  end

  # F4 do plano-fase2 (30/08/2026): `specialty_for` ganha `notícia -> :tavily`
  # para que o Path B reordenado coloque Tavily como 1º pago em queries
  # noticiosas, mesmo sem `type:` explícito vindo do MCP. O contrato Tavily
  # original (lookup técnico) é preservado — `notícia/notícias/news` é
  # ADITIVO, não substitui.
  def test_specialty_for_tavily_queries_de_noticia_f4
    assert_equal :tavily, SearchApiRouter.specialty_for("última notícia do SpaceX agora")
    assert_equal :tavily, SearchApiRouter.specialty_for("noticias de hoje sobre IA")
    assert_equal :tavily, SearchApiRouter.specialty_for("breaking news bitcoin")
    assert_equal :tavily, SearchApiRouter.specialty_for("headline sobre o mercado")
  end

  # F4: queries de notícia COM time_range=day no Discord → Tavily primeiro
  # no pago via regex `notícia`, NÃO via `type`. Cobre a interação F2-F4:
  # specialty_for dispara pelo regex mesmo sem `type:` no schema.
  def test_specialty_for_noticia_no_discord_ignora_type_e_vai_tavily_primeiro
    assert_equal :tavily, SearchApiRouter.specialty_for("site:g1.globo.com última notícia agora"),
                 "regex de notícia deve classificar como Tavily independente do `type`"
  end

  def test_specialty_for_generic_factual_returns_nil
    assert_nil SearchApiRouter.specialty_for("preço do bitcoin hoje")
    assert_nil SearchApiRouter.specialty_for("qual o custo da OpenAI em 2025")
    assert_nil SearchApiRouter.specialty_for("quantos habitantes tem o Japão")
    assert_nil SearchApiRouter.specialty_for("company profile OpenAI")
    assert_nil SearchApiRouter.specialty_for("")
  end

  # F1 do plano v2 (30/08/2026): removido `num_sentences: 2` para devolver
  # text integral do Exa. O body agora não carrega mais `contents.highlights`.
  def test_build_request_exa_sem_num_sentences
    ENV["EXA_API_KEY"] = "ex_fake"
    _uri, req = SearchApiRouter.build_request(:exa, "papers sobre machine learning", 5, nil)

    body = JSON.parse(req.body)
    assert_nil body.dig("contents", "highlights", "num_sentences"),
             "Exa não deve mais pedir num_sentences (v2)"
    assert_equal 5, body["numResults"], "numResults deve refletir o limit passado"
    assert_equal "auto", body["type"], "type padrao do body Exa continua sendo 'auto'"
  end

  # ── F7 (plano-fase2 31/08/2026): campo `trust` na normalização ─────────────
  # Classificador primary|ugc|unknown por host. A lista calibrada pela
  # amostra E7 de 50 hosts está em `SearchApiRouter::TRUST_TABLE` (uma única
  # fonte) e é consultada por sufixo de hostname. Hospedeiro default: `:unknown`
  # (agregador / blog pessoal / mídia não listada).
  def test_trust_for_hosts_ugc
    assert_equal :ugc, SearchApiRouter.trust_for("https://reddit.com/r/ruby/x")
    assert_equal :ugc, SearchApiRouter.trust_for("https://www.reddit.com/r/ruby/x")
    assert_equal :ugc, SearchApiRouter.trust_for("https://old.reddit.com/")
    assert_equal :ugc, SearchApiRouter.trust_for("https://x.com/user/foo")
    assert_equal :ugc, SearchApiRouter.trust_for("https://twitter.com/user/status/1")
    assert_equal :ugc, SearchApiRouter.trust_for("https://www.linkedin.com/in/johndoe")
    assert_equal :ugc, SearchApiRouter.trust_for("https://stackoverflow.com/questions/1")
    assert_equal :ugc, SearchApiRouter.trust_for("https://forum.alura.com.br/t/x")
    assert_equal :ugc, SearchApiRouter.trust_for("https://forum.example.org/topic")
  end

  def test_trust_for_hosts_primary
    assert_equal :primary, SearchApiRouter.trust_for("https://gov.br/noticias/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://www.gov.br/pt-br")
    assert_equal :primary, SearchApiRouter.trust_for("https://arxiv.org/abs/1")
    assert_equal :primary, SearchApiRouter.trust_for("https://reuters.com/world/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://nature.com/articles/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://who.int/news/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://imf.org/external/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://nytimes.com/2026/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://apnews.com/article/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://bcb.gov.br/pt-br/x")
    assert_equal :primary, SearchApiRouter.trust_for("https://github.com/rails/rails")
    assert_equal :primary, SearchApiRouter.trust_for("https://www.bcb.gov.br/x")
  end

  def test_trust_for_host_desconhecido_e_unknown
    assert_equal :unknown, SearchApiRouter.trust_for("https://exemplo.com/x")
    assert_equal :unknown, SearchApiRouter.trust_for("https://blog.exemplo.com/post")
    assert_equal :unknown, SearchApiRouter.trust_for("https://medium.com/p/x")
    assert_equal :unknown, SearchApiRouter.trust_for("https://dev.to/article")
  end

  def test_trust_for_input_invalido_e_unknown_sem_levantar
    assert_equal :unknown, SearchApiRouter.trust_for(nil)
    assert_equal :unknown, SearchApiRouter.trust_for("")
    assert_equal :unknown, SearchApiRouter.trust_for("   ")
  end

  # Match por sufixo: forum.* casa qualquer forum.* mesmo TLD; `gov.*` casa
  # gov.br E gov.uk (defesa em profundidade, embora gov.uk não esteja na lista
  # calibrada — só `gov.*` no brief).
  def test_trust_for_match_por_sufixo_de_hostname
    assert_equal :ugc, SearchApiRouter.trust_for("https://forum.dev.to/t/x"),
                 "forum.* é UGC por sufixo mesmo que o host não esteja na lista"
    assert_equal :primary, SearchApiRouter.trust_for("https://gov.uk/news"),
                 "gov.* é primary por sufixo, independente do TLD (.uk)"
  end

  # `x.com` casa sufixo `x.com` (ugc) E não casa `x.com.br` (não está na lista).
  # Defesa contra falso positivo de substring — `x.com.br` ≠ `x.com`.
  def test_trust_for_x_com_br_nao_e_ugc
    refute_equal :ugc, SearchApiRouter.trust_for("https://x.com.br/noticia"),
                 "x.com.br não é x.com — não pode virar :ugc por substring"
    assert_equal :unknown, SearchApiRouter.trust_for("https://x.com.br/noticia"),
                 "x.com.br cai em :unknown por não estar na lista calibrada"
  end

  # `reddit.com` ugc NÃO pode aparecer como `:primary` mesmo se algum
  # mecanismo futuro permitir — defesa em profundidade.
  def test_trust_reddit_nunca_e_primary
    refute_equal :primary, SearchApiRouter.trust_for("https://reddit.com/")
    refute_equal :primary, SearchApiRouter.trust_for("https://www.reddit.com/")
  end

  # D4-F7-v2 (revisor r1 grok REPROVA): o wildcard antigo `"gov."` com
  # `start_with?` casava QUALQUER host que COMEÇASSE com "gov." — incluindo
  # `gov.example.evil`, que virava `:primary`. Semântica correta é match
  # por SUFIXO de TLD real: `host.end_with?(".gov")`, `".gov.br"`, etc.
  # Cobre os 4 casos canônicos do brief:
  #   - gov.example.evil → :unknown  (não termina em .gov/.gov.br)
  #   - www.gov.br       → :primary  (termina em .gov.br)
  #   - evil.com/gov.fake→ :unknown  (path com "gov." não casa; match é por HOST)
  #   - www.reddit.com   → :ugc      (sufixo `.reddit.com` continua valendo)
  def test_trust_wildcard_gov_nao_casa_subdominio_falso
    assert_equal :unknown, SearchApiRouter.trust_for("https://gov.example.evil/x"),
                 "gov.example.evil NÃO é gov — start_with?('gov.') era o bug; agora é :unknown"
    assert_equal :primary, SearchApiRouter.trust_for("https://www.gov.br/anexo"),
                 "www.gov.br é gov.br real — sufixo .gov.br casa"
    assert_equal :unknown, SearchApiRouter.trust_for("https://evil.com/gov.fake"),
                 "gov.fake no PATH não casa — match é por HOST, não pela URL inteira"
    assert_equal :ugc, SearchApiRouter.trust_for("https://www.reddit.com/r/x"),
                 "reddit.com continua :ugc — sufixo .reddit.com não foi afetado pelo fix"
  end

  # Tabela exposta como constante — single source of truth para o classificador.
  def test_trust_table_e_constante_exposta
    assert defined?(SearchApiRouter::TRUST_TABLE), "tabela deve ser constante pública do módulo"
    table = SearchApiRouter::TRUST_TABLE
    assert table.is_a?(Hash)
    assert_equal :ugc, table["reddit.com"], "reddit.com deve estar na tabela como :ugc"
    assert_equal :primary, table["github.com"], "github.com deve estar na tabela como :primary"
    assert_equal :primary, table["arxiv.org"], "arxiv.org deve estar na tabela como :primary"
    # sanidade: a lista calibrada (brief F7) tem TODOS os hosts do brief.
    %w[
      reddit.com x.com twitter.com linkedin.com stackoverflow.com
      gov.br arxiv.org reuters.com nature.com who.int imf.org
      nytimes.com apnews.com bcb.gov.br github.com
    ].each do |host|
      refute_nil table[host], "host #{host} deveria estar em TRUST_TABLE (brief F7)"
    end
  end

  # Cada item normalizado carrega `:trust` por host. Validação direta na
  # normalização (TDD: o resultado da API bruta vira lista com a chave).
  def test_normalize_results_inclui_campo_trust_por_item
    raw = {
      "results" => [
        { "title" => "T1", "url" => "https://reddit.com/r/ruby/x", "content" => "snip", "score" => 0.9 },
        { "title" => "T2", "url" => "https://github.com/rails/rails", "content" => "snip", "score" => 0.8 },
        { "title" => "T3", "url" => "https://exemplo.com/x", "content" => "snip", "score" => 0.7 }
      ]
    }
    out = SearchApiRouter.normalize_results(:tavily, raw, score_threshold: 0.5)
    assert_equal :ugc, out[0][:trust], "URL reddit.com deve vir com trust :ugc"
    assert_equal :primary, out[1][:trust], "URL github.com deve vir com trust :primary"
    assert_equal :unknown, out[2][:trust], "URL desconhecida deve vir com trust :unknown"
  end

  # Exa/Linkup também ganham :trust (todas as APIs do router passam pela mesma
  # normalização — sem `trust`, um item Tavily+um item Exa do mesmo host
  # ficariam com campos diferentes).
  def test_normalize_results_inclui_trust_emexa_e_linkup
    exa_raw = {
      "results" => [
        { "title" => "H", "url" => "https://arxiv.org/abs/1", "highlights" => ["t"] }
      ]
    }
    assert_equal :primary, SearchApiRouter.normalize_results(:exa, exa_raw, score_threshold: 0.5).first[:trust]

    linkup_raw = {
      "results" => [
        { "name" => "L", "url" => "https://reddit.com/r/x", "content" => "c" }
      ]
    }
    assert_equal :ugc, SearchApiRouter.normalize_results(:linkup, linkup_raw, score_threshold: 0.5).first[:trust]
  end

  # Dedupe canônica não pode perder o `trust`: como o dedupe mantém a
  # primeira ocorrência por URL canônica, o item mantido carrega o trust da
  # primeira ocorrência (e como dedupe é por URL, hosts são iguais — invariante).
  def test_dedupe_preserva_trust
    raw = {
      "results" => [
        { "title" => "A", "url" => "https://reddit.com/r/ruby/x?utm=1", "content" => "1", "score" => 0.9 },
        { "title" => "B", "url" => "https://reddit.com/r/ruby/x/", "content" => "2", "score" => 0.8 }
      ]
    }
    out = SearchApiRouter.normalize_results(:tavily, raw, score_threshold: 0.5)
    assert_equal 1, out.size
    assert_equal :ugc, out.first[:trust], "dedupe precisa preservar trust do item mantido"
  end
end
