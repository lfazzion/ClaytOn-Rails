# frozen_string_literal: true

# F8 (plano-fase2 D7, 30/08/2026): rake `search:report` que consolida o log
# estruturado `[WebSearchMetric]` gravado por `SearchMetric.record(...)`.
#
# Uso:
#   bin/rails search:report                       # default log/search_metrics.log
#   bin/rails search:report LOG_PATH=log/other.log
#
# Saída: tabela em stdout (sem dashboard), agrupada por origin × provider × type
# com:
#   - contagem       (# de buscas executadas, sem cache hit)
#   - mediana latency_ms
#   - soma cost_usd  (nil/ausente = grátis, não soma)
#   - trust counts   (soma de trust_primary / trust_ugc / trust_unknown)
#
# Se o log não existir ou não tiver linhas `[WebSearchMetric]`, imprime
# "sem dados" e exit 0.
#
# Toda a lógica de parse/agregação/mediana está em
# `lib/tasks/search_report_aggregator.rb` para ser testável sem Rails/docker.

require_relative "search_report_aggregator"

namespace :search do
  desc "Consolida o log [WebSearchMetric] em uma tabela por origin × provider × type"
  task report: :environment do
    log_path = ENV["LOG_PATH"].to_s.empty? ? "log/search_metrics.log" : ENV["LOG_PATH"]

    unless File.exist?(log_path)
      puts "sem dados"
      next
    end

    metrics = SearchReport::Aggregator.parse_metrics(log_path)
    if metrics.empty?
      puts "sem dados"
      next
    end

    aggregated = SearchReport::Aggregator.aggregate(metrics)
    SearchReport::Aggregator.print_table(aggregated, total: metrics.size)
  end
end