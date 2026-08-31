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
  def test_normaliza_exa_usando_highlights_quando_presente
    raw = {
      "results" => [
        { "title" => "H", "url" => "https://ex.com/h", "highlights" => ["trecho destacado"], "text" => "corpo longo" },
        { "title" => "T", "url" => "https://ex.com/t", "text" => "só texto" }
      ]
    }
    out = SearchApiRouter.normalize_results(:exa, raw, score_threshold: 0.7)
    assert_equal 2, out.size
    assert_equal "exa", out.first[:engine]
    assert_equal "trecho destacado", out.first[:content]
    assert_equal "só texto", out.last[:content]
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

  # F1 do plano v2 (30/08/2026): Exa sem teto por highlight pode devolver
  # paragrafos inteiros, fugindo do CONTENT_MAX_CHARS=200 do WebSearchTool.
  # Travado em 2 frases = bem abaixo do teto de 200 chars e mata o vetor de
  # UGC comprido (D4). O body vai serializado no `req.body`; lemos via JSON.parse
  # para validar a chave aninhada sem depender de HTTP real.
  def test_build_request_exa_carrega_num_sentences_2_em_highlights
    ENV["EXA_API_KEY"] = "ex_fake"
    _uri, req = SearchApiRouter.build_request(:exa, "papers sobre machine learning", 5, nil)

    body = JSON.parse(req.body)
    assert_equal 2, body.dig("contents", "highlights", "num_sentences"),
                 "Exa deve pedir num_sentences=2 no highlights (F1 plano v2)"
    assert_equal 5, body["numResults"], "numResults deve refletir o limit passado"
    assert_equal "auto", body["type"], "type padrao do body Exa continua sendo 'auto'"
  end
end
