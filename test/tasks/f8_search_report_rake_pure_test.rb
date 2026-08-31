# frozen_string_literal: true

# Testes PUROS do rake `search:report` (F8) — sem Rails, sem docker, ruby puro.
#
# Cobre o aceite do brief D5-F8-v2:
#   "1 teste pequeno: rake sobre um log sintético de 3 linhas
#    [WebSearchMetric] -> tabela com contagem/soma corretas"
#
# A lógica do rake está em `SearchReport::Aggregator` (lib/tasks/search_report_aggregator.rb).
# Este teste carrega o módulo diretamente e exercita parse / aggregate /
# median contra um log sintético.

require "minitest/autorun"
require "json"
require "stringio"
require "tempfile"

require_relative "../../lib/tasks/search_report_aggregator"

class F8SearchReportRakePureTest < Minitest::Test
  # 3 linhas sintéticas, 2 grupos:
  #   - 2x (origin=nil,  provider=searxng, type=auto): latências 100, 300,
  #     trust_primary 1, trust_ugc 2, sem cost
  #   - 1x (origin=discord, provider=tavily, type=news): latency 250,
  #     cost 5, trust_unknown 3
  SYNTHETIC_LOG = <<~LOG.freeze
    [WebSearchMetric] {"v":1,"ts":"2026-08-31T00:00:00.000Z","origin":null,"provider":"searxng","type":"auto","query_len":5,"results_count":2,"latency_ms":100,"source":"searxng","engine":"github","trust_primary":1,"trust_ugc":1,"trust_unknown":0,"unresponsive_count":0,"from_cache":false}
    [WebSearchMetric] {"v":1,"ts":"2026-08-31T00:00:01.000Z","origin":null,"provider":"searxng","type":"auto","query_len":7,"results_count":1,"latency_ms":300,"source":"searxng","engine":"github","trust_primary":0,"trust_ugc":1,"trust_unknown":0,"unresponsive_count":0,"from_cache":false}
    [WebSearchMetric] {"v":1,"ts":"2026-08-31T00:00:02.000Z","origin":"discord","provider":"tavily","type":"news","query_len":12,"results_count":3,"latency_ms":250,"source":"router","engine":"tavily","cost_usd":5,"trust_primary":0,"trust_ugc":0,"trust_unknown":3,"unresponsive_count":0,"from_cache":false}
  LOG

  def setup
    @log = Tempfile.new(["search_metrics", ".log"])
    @log.write(SYNTHETIC_LOG)
    @log.flush
  end

  def teardown
    @log.close
    @log.unlink
  end

  def test_parse_3_linhas_sem_descartar
    metrics = SearchReport::Aggregator.parse_metrics(@log.path)
    assert_equal 3, metrics.size, "as 3 linhas devem ser parseadas"

    assert metrics.first.key?("origin")
    assert_nil metrics.first["origin"], "origin null preservado (origem=nil no JSON)"
    assert_equal "discord", metrics.last["origin"]
  end

  def test_aggregate_por_origin_provider_type
    metrics = SearchReport::Aggregator.parse_metrics(@log.path)
    buckets = SearchReport::Aggregator.aggregate(metrics)

    assert_equal 2, buckets.size, "2 grupos distintos (searxng×auto origin=nil; tavily×news origin=discord)"

    key_searxng = [nil, "searxng", "auto"]
    key_tavily  = ["discord", "tavily", "news"]
    assert buckets.key?(key_searxng)
    assert buckets.key?(key_tavily)

    searxng = buckets[key_searxng]
    assert_equal 2,         searxng[:count]
    assert_equal [100, 300], searxng[:latencies]
    assert_equal 0.0,        searxng[:cost_usd], "sem cost_usd nas linhas → soma é 0.0"
    assert_equal false,     searxng[:has_cost], "has_cost=false quando nenhum item tinha cost_usd"
    assert_equal 1,         searxng[:trust_primary]
    assert_equal 2,         searxng[:trust_ugc]
    assert_equal 0,         searxng[:trust_unknown]

    tavily = buckets[key_tavily]
    assert_equal 1,     tavily[:count]
    assert_equal [250], tavily[:latencies]
    assert_equal 5.0,   tavily[:cost_usd]
    assert_equal true,  tavily[:has_cost]
    assert_equal 0,     tavily[:trust_primary]
    assert_equal 0,     tavily[:trust_ugc]
    assert_equal 3,     tavily[:trust_unknown]
  end

  def test_mediana_latencia_por_grupo
    metrics = SearchReport::Aggregator.parse_metrics(@log.path)
    buckets = SearchReport::Aggregator.aggregate(metrics)

    key_searxng = [nil, "searxng", "auto"]
    assert_equal 200.0, SearchReport::Aggregator.median(buckets[key_searxng][:latencies]),
                 "mediana de [100, 300] = 200.0 (par = média dos centrais)"

    key_tavily = ["discord", "tavily", "news"]
    assert_equal 250, SearchReport::Aggregator.median(buckets[key_tavily][:latencies]),
                 "mediana de [250] = 250 (ímpar = elemento central)"
  end

  def test_print_table_tem_contagem_e_soma_corretas
    metrics = SearchReport::Aggregator.parse_metrics(@log.path)
    buckets = SearchReport::Aggregator.aggregate(metrics)

    io = StringIO.new
    SearchReport::Aggregator.print_table(buckets, total: metrics.size, io: io)
    out = io.string

    # Cabeçalho e total:
    assert_includes out, "origin",  "cabeçalho da tabela"
    assert_includes out, "provider"
    assert_includes out, "type"
    assert_includes out, "count"
    assert_includes out, "med_lat_ms"
    assert_includes out, "cost_usd"
    assert_includes out, "total de buscas executadas: 3"

    # Linhas de dados — assertivas literais:
    #   searxng×auto origin=- (nil vira "-"), count 2, med_lat_ms 200.0, cost_usd "-" (sem cost), trust_pri 1, trust_ugc 2, trust_unk 0
    #   tavily×news origin=discord, count 1, med_lat_ms 250, cost_usd 5, trust_pri 0, trust_ugc 0, trust_unk 3
    assert_match(/-\s+searxng\s+auto\s+2\s+200\.0\s+-\s+1\s+2\s+0/, out,
                 "linha do grupo searxng×auto com medianas/custos corretos")
    assert_match(/discord\s+tavily\s+news\s+1\s+250\s+5\s+0\s+0\s+3/, out,
                 "linha do grupo tavily×news com cost 5 e trust_unknown 3")
  end

  def test_sem_dados_quando_log_vazio_ou_ausente
    empty = Tempfile.new(["empty", ".log"])
    empty.close
    assert_equal [], SearchReport::Aggregator.parse_metrics(empty.path),
                 "arquivo vazio → []"
    empty.unlink

    ghost = Tempfile.new(["ghost", ".log"])
    ghost_path = ghost.path
    ghost.close
    ghost.unlink
    assert_equal [], SearchReport::Aggregator.parse_metrics(ghost_path),
                 "arquivo inexistente → [] (alinhado a 'sem dados' do rake)"
  end

  def test_linha_malformada_e_cache_hit_sao_descartados
    mixed = Tempfile.new(["mixed", ".log"])
    mixed.write(<<~LOG)
      lixo qualquer sem prefixo

      [WebSearchMetric] {"v":1,"ts":"2026-08-31T00:00:00.000Z","origin":null,"provider":"searxng","type":"auto","query_len":1,"results_count":1,"latency_ms":50,"source":"searxng","engine":"x","trust_primary":1,"trust_ugc":0,"trust_unknown":0,"unresponsive_count":0,"from_cache":false}
      [WebSearchMetric] isto nao e json
      [WebSearchMetric] {"v":1,"ts":"2026-08-31T00:00:01.000Z","origin":null,"provider":"searxng","type":"auto","query_len":1,"results_count":1,"latency_ms":50,"source":"searxng","engine":"x","trust_primary":0,"trust_ugc":0,"trust_unknown":0,"unresponsive_count":0,"from_cache":true}
    LOG
    mixed.flush

    metrics = SearchReport::Aggregator.parse_metrics(mixed.path)
    assert_equal 1, metrics.size, "só a linha válida conta (malformada descartada; cache hit descartado)"
    assert_equal false, metrics.first["from_cache"]

    mixed.close
    mixed.unlink
  end
end