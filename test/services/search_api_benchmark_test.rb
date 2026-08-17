# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/search_api_benchmark"
require_relative "../../app/services/search_api_router"
require_relative "../../app/models/search_api_quota"

class SearchApiBenchmarkTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    SearchApiQuota.delete_all if defined?(SearchApiQuota) && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
    @saved_env = %w[
      TAVILY_API_KEY EXA_API_KEY LINKUP_API_KEY
      SEARCH_API_QUOTA_TAVILY SEARCH_API_QUOTA_EXA SEARCH_API_QUOTA_LINKUP
    ].to_h { |k| [k, ENV[k]] }
    ENV["TAVILY_API_KEY"] = "tv"
    ENV["EXA_API_KEY"] = "ex"
    ENV["LINKUP_API_KEY"] = "lk"
  end

  teardown do
    @saved_env&.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  test "runs benchmark and returns structured results for success" do
    stub_request(:post, "https://api.tavily.com/search")
      .with(body: hash_including(query: "rails"))
      .to_return(
        status: 200,
        body: { results: [{ title: "T1", url: "https://t1.com", content: "c", score: 0.9 }], usage: { credits: 1 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    results = SearchApiBenchmark.run(queries: ["rails"], providers: [:tavily], limit: 5)

    assert_equal 1, results.size
    res = results.first
    assert_equal "tavily", res[:provider]
    assert_equal "rails", res[:query]
    assert_equal "success", res[:status]
    assert res[:latency_ms].is_a?(Integer)
    assert_equal 1, res[:cost]
    assert_equal 1, res[:results_count]
    assert_equal "https://t1.com", res[:results].first[:url]
    assert_nil res[:error]
  end

  test "handles quota exceeded explicitly without calling API" do
    ENV["SEARCH_API_QUOTA_EXA"] = "0"

    # Exa should not be called
    stub_request(:post, "https://api.exa.ai/search").to_raise("Exa called but quota is 0")

    results = SearchApiBenchmark.run(queries: ["test"], providers: [:exa], limit: 5)

    res = results.first
    assert_equal "exa", res[:provider]
    assert_equal "quota_exceeded", res[:status]
    assert_nil res[:results]
    assert_equal 0, res[:results_count]
  end

  test "handles API error safely without leaking sensitive bodies" do
    stub_request(:post, "https://api.linkup.so/v1/search")
      .to_return(status: 500, body: "Secret server error")

    results = SearchApiBenchmark.run(queries: ["test"], providers: [:linkup], limit: 5)

    res = results.first
    assert_equal "linkup", res[:provider]
    assert_equal "error", res[:status]
    assert_match(/HTTP 500/, res[:error])
    refute_match(/Secret server error/, res[:error])
  end

  test "clamps limit using 1..10 rule" do
    req1 = stub_request(:post, "https://api.tavily.com/search")
      .with(body: hash_including(max_results: 1, query: "zero"))
      .to_return(status: 200, body: { results: [], usage: { credits: 1 } }.to_json, headers: { "Content-Type" => "application/json" })

    req2 = stub_request(:post, "https://api.tavily.com/search")
      .with(body: hash_including(max_results: 1, query: "negative"))
      .to_return(status: 200, body: { results: [], usage: { credits: 1 } }.to_json, headers: { "Content-Type" => "application/json" })

    req3 = stub_request(:post, "https://api.tavily.com/search")
      .with(body: hash_including(max_results: 10, query: "large"))
      .to_return(status: 200, body: { results: [], usage: { credits: 1 } }.to_json, headers: { "Content-Type" => "application/json" })

    # We assume these run and the stub constraints assert the body max_results
    SearchApiBenchmark.run(queries: ["zero"], providers: [:tavily], limit: 0)
    SearchApiBenchmark.run(queries: ["negative"], providers: [:tavily], limit: -5)
    SearchApiBenchmark.run(queries: ["large"], providers: [:tavily], limit: 15)

    assert_requested req1, times: 1
    assert_requested req2, times: 1
    assert_requested req3, times: 1
  end

  test "isolates providers without fallback mixing results" do
    # Linkup fails
    req_linkup = stub_request(:post, "https://api.linkup.so/v1/search")
      .to_return(status: 429)
    # Exa returns empty
    req_exa = stub_request(:post, "https://api.exa.ai/search")
      .to_return(status: 200, body: { results: [] }.to_json, headers: { "Content-Type" => "application/json" })
    # Tavily succeeds
    req_tavily = stub_request(:post, "https://api.tavily.com/search")
      .to_return(status: 200, body: { results: [{ title: "T1", url: "https://t1.com", content: "c", score: 0.9 }], usage: { credits: 1 } }.to_json, headers: { "Content-Type" => "application/json" })

    results = SearchApiBenchmark.run(queries: ["test_iso"], providers: [:linkup, :exa, :tavily], limit: 5)

    assert_requested req_linkup, times: 1
    assert_requested req_exa, times: 1
    assert_requested req_tavily, times: 1

    assert_equal 3, results.size

    res_linkup = results.find { |r| r[:provider] == "linkup" }
    assert_equal "error", res_linkup[:status]
    assert_nil res_linkup[:results]

    res_exa = results.find { |r| r[:provider] == "exa" }
    assert_equal "success", res_exa[:status]
    assert_equal [], res_exa[:results]

    res_tavily = results.find { |r| r[:provider] == "tavily" }
    assert_equal "success", res_tavily[:status]
    assert_equal 1, res_tavily[:results].size
    assert_equal "https://t1.com", res_tavily[:results].first[:url]
  end
end
