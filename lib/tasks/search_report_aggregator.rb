# frozen_string_literal: true

# F8 (plano-fase2 D7, 30/08/2026): agregador puro do log `[WebSearchMetric]`.
# Usado pelo rake `search:report` e testável sem Rails/docker.
#
# Saída: tabela (Hash) por origin × provider × type com:
#   - count        (Integer)
#   - latencies    (Array<Integer>; mediana calculada por `SearchReport::Aggregator.median`)
#   - cost_usd     (Float; soma — nil/ausente = grátis, não soma)
#   - has_cost     (Boolean)
#   - trust_primary / trust_ugc / trust_unknown (Integer)
#
# Linhas malformadas (JSON inválido) são descartadas silenciosamente.
# Cache hit (`from_cache: true`) também é descartado — defesa em
# profundidade; o log deveria só ter `from_cache: false`.

require "json"

module SearchReport
  module Aggregator
    module_function

    # Lê o log linha a linha; cada linha é "[WebSearchMetric] {json}".
    # Retorna [] se o arquivo não existir — alinhado ao contrato "sem dados"
    # do rake `search:report`.
    def parse_metrics(log_path)
      return [] unless File.exist?(log_path)

      metrics = []
      File.foreach(log_path) do |line|
        next unless line.include?("[WebSearchMetric]")

        json_part = line.sub(/.*\[WebSearchMetric\]\s*/, "")
        json_part = json_part.sub(/\s*\z/, "")
        begin
          payload = JSON.parse(json_part)
        rescue JSON::ParserError
          next
        end

        next if payload["from_cache"] == true

        metrics << payload
      end
      metrics
    end

    # Agrupa por (origin, provider, type). origin nil vira "-" só na exibição;
    # a chave de agregação mantém nil para agrupar corretamente.
    def aggregate(metrics)
      buckets = Hash.new do |h, k|
        h[k] = {
          count: 0,
          latencies: [],
          cost_usd: 0.0,
          has_cost: false,
          trust_primary: 0,
          trust_ugc: 0,
          trust_unknown: 0
        }
      end

      metrics.each do |m|
        key = [m["origin"], m["provider"], m["type"]]
        b = buckets[key]
        b[:count] += 1
        lat = m["latency_ms"]
        b[:latencies] << lat.to_i if lat
        cost = m["cost_usd"]
        if cost.is_a?(Numeric)
          b[:cost_usd] += cost.to_f
          b[:has_cost] = true
        end
        b[:trust_primary]  += m["trust_primary"].to_i
        b[:trust_ugc]      += m["trust_ugc"].to_i
        b[:trust_unknown]  += m["trust_unknown"].to_i
      end

      buckets
    end

    # Mediana: para contagem ímpar é o elemento central; par é a média dos dois
    # centrais. Latências são inteiras (ms); quando par e média não-inteira,
    # retorna Float com uma casa decimal de resolução.
    def median(values)
      return 0 if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      if sorted.size.odd?
        sorted[mid]
      else
        (sorted[mid - 1] + sorted[mid]) / 2.0
      end
    end

    def format_cost(value, has_cost)
      return "-" unless has_cost

      if value == value.to_i
        value.to_i.to_s
      else
        format("%.4f", value).sub(/0+\z/, "").sub(/\.\z/, "")
      end
    end

    # Imprime a tabela em `io` (default $stdout). Retorna nada — side-effect.
    def print_table(buckets, total:, io: $stdout)
      headers = ["origin", "provider", "type", "count", "med_lat_ms", "cost_usd", "trust_pri", "trust_ugc", "trust_unk"]
      rows = buckets.map do |(origin, provider, type), b|
        [
            origin.nil? ? "-" : origin.to_s,
            provider.to_s,
            type.to_s,
            b[:count].to_s,
            median(b[:latencies]).to_s,
            format_cost(b[:cost_usd], b[:has_cost]),
            b[:trust_primary].to_s,
            b[:trust_ugc].to_s,
            b[:trust_unknown].to_s
          ]
      end

      rows.sort_by! { |r| -r[3].to_i }

      widths = headers.each_with_index.map { |h, i| [h.length, *rows.map { |r| r[i].length }].max }

      fmt = widths.each_with_index.map { |w, i| i.zero? ? "%-#{w}s" : "%#{w}s" }.join("  ")
      sep = widths.map { |w| "-" * w }.join("  ")

      io.puts format(fmt, *headers)
      io.puts sep
      rows.each { |r| io.puts format(fmt, *r) }
      io.puts sep
      io.puts "total de buscas executadas: #{total}"
    end
  end
end