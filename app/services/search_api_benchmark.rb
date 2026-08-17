# frozen_string_literal: true

require_relative "search_api_router"

# Benchmark runner for testing Linkup, Exa, and Tavily APIs.
# Runs queries in isolation on each provider to compare results.
class SearchApiBenchmark
  def self.run(queries:, providers: SearchApiRouter::PROVIDERS, limit: 5, time_range: nil, output_format: nil)
    results = []

    Array(queries).each do |query|
      Array(providers).each do |provider|
        provider_sym = provider.to_sym
        result_entry = {
          provider: provider_sym.to_s,
          query: query,
          status: nil,
          http_status: nil,
          latency_ms: 0,
          cost: nil,
          results_count: 0,
          results: nil,
          error: nil
        }

        if SearchApiRouter.quota_exceeded?(provider_sym)
          result_entry[:status] = "quota_exceeded"
          results << result_entry
          next
        end

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # using the public attempt method from SearchApiRouter
        success_data, error_reason = SearchApiRouter.attempt(
          provider_sym,
          query,
          SearchApiRouter.clamp_limit(limit),
          time_range,
          SearchApiRouter.current_date
        )

        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        result_entry[:latency_ms] = elapsed_ms

        if success_data
          result_entry[:status] = "success"
          result_entry[:http_status] = 200
          result_entry[:cost] = success_data[:cost]
          result_entry[:results] = success_data[:results]
          result_entry[:results_count] = success_data[:results].size
        else
          result_entry[:status] = "error"
          result_entry[:error] = error_reason
          if error_reason.to_s =~ /HTTP (\d+)/
            result_entry[:http_status] = $1.to_i
          end
        end

        results << result_entry
      end
    end

    if output_format == :jsonl
      results.each { |r| puts r.to_json }
    elsif output_format == :json
      puts JSON.pretty_generate(results)
    end

    results
  end
end
