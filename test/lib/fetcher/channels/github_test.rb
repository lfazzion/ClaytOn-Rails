# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/github"

class Fetcher::Channels::GithubTest < ActiveSupport::TestCase
  PUBLIC_IP = "93.184.216.34"

  setup do
    Rails.cache.clear
    Fetcher::SsrfGuard.stubs(:resolve_all).returns([PUBLIC_IP])
  end

  test "1. URL valida de issue/PR devolve hash com markdown montado e metadata source github" do
    issue_payload = {
      "title" => "Fix memory leak in GC",
      "state" => "open",
      "user" => { "login" => "developer1" },
      "created_at" => "2026-08-01T12:00:00Z",
      "labels" => [{ "name" => "bug" }, { "name" => "gc" }],
      "body" => "Memory leak occurs when calling GC.compact repeatedly.",
      "comments" => 1
    }

    comments_payload = [
      { "user" => { "login" => "maintainer" }, "body" => "Fixed in PR #42." }
    ]

    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100")
      .with(headers: { "Accept" => "application/vnd.github+json" })
      .to_return(status: 200, body: JSON.generate(issue_payload), headers: { "Content-Type" => "application/json" })

    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100/comments?per_page=20")
      .to_return(status: 200, body: JSON.generate(comments_payload), headers: { "Content-Type" => "application/json" })

    result = Fetcher::Channels::Github.call(url: "https://github.com/rails/rails/issues/100")

    assert_not_nil result
    assert_equal "https://github.com/rails/rails/issues/100", result[:url]
    assert_equal "Fix memory leak in GC", result[:title]
    assert_includes result[:content], "# Fix memory leak in GC"
    assert_includes result[:content], "@developer1"
    assert_includes result[:content], "Memory leak occurs"
    assert_includes result[:content], "@maintainer"
    assert_equal "github", result[:metadata]["source"]
    assert_equal "issue", result[:metadata]["kind"]
    assert_equal "rails", result[:metadata]["owner"]
    assert_equal "rails", result[:metadata]["repo"]
    assert_equal 100, result[:metadata]["number"]
    assert_nil result[:error]
  end

  test "2. URL de outro dominio devolve nil" do
    assert_nil Fetcher::Channels::Github.call(url: "https://gitlab.com/rails/rails/issues/100")
  end

  test "3. URL do dominio mas de path nao suportado devolve nil" do
    assert_nil Fetcher::Channels::Github.call(url: "https://github.com/rails/rails")
    assert_nil Fetcher::Channels::Github.call(url: "https://github.com/rails/rails/discussions/100")
    assert_nil Fetcher::Channels::Github.call(url: "https://github.com/settings/profile")
    # sufixo após o número não é issue/PR válida (âncora total)
    assert_nil Fetcher::Channels::Github.call(url: "https://github.com/rails/rails/issues/100/comments")
    # owner/repo inválidos
    assert_nil Fetcher::Channels::Github.call(url: "https://github.com/../rails/issues/100")
    assert_nil Fetcher::Channels::Github.call(url: "https://github.com/rails/.. /issues/100")
  end

  test "4. API responde erro (500 ou 403) levanta excecao nomeada herdando de Channels::Error" do
    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100")
      .to_return(status: 403, body: JSON.generate({ "message" => "Rate limit exceeded" }))

    # 403 = cota anônima estourada: o canal se declara incompetente (nil) e o
    # ExtractService escala para o HTML — NÃO é erro duro.
    assert_nil Fetcher::Channels::Github.call(url: "https://github.com/rails/rails/issues/100")
  end

  test "4b. 404 levanta IssueNotFound (não é fallback)" do
    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100")
      .to_return(status: 404, body: JSON.generate({ "message" => "Not Found" }))

    err = assert_raises(Fetcher::Channels::Github::IssueNotFound) do
      Fetcher::Channels::Github.call(url: "https://github.com/rails/rails/issues/100")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end

  test "5. API de comentários com erro levanta ApiError (não [] silencioso)" do
    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100")
      .to_return(status: 200, body: JSON.generate({ "title" => "Issue", "state" => "open",
        "user" => { "login" => "dev" }, "created_at" => "2026-01-01", "body" => "corpo",
        "labels" => [], "comments" => 3 }))
    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100/comments?per_page=20")
      .to_return(status: 500, body: "erro")

    err = assert_raises(Fetcher::Channels::Github::ApiError) do
      Fetcher::Channels::Github.call(url: "https://github.com/rails/rails/issues/100")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end

  test "6. comentários com JSON inválido levantam ApiError (não resumo falso)" do
    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100")
      .to_return(status: 200, body: JSON.generate({ "title" => "Issue", "state" => "open",
        "user" => { "login" => "dev" }, "created_at" => "2026-01-01", "body" => "corpo",
        "labels" => [], "comments" => 1 }))
    stub_request(:get, "https://api.github.com/repos/rails/rails/issues/100/comments?per_page=20")
      .to_return(status: 200, body: "isto nao e json")

    err = assert_raises(Fetcher::Channels::Github::ApiError) do
      Fetcher::Channels::Github.call(url: "https://github.com/rails/rails/issues/100")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end

  test "7. search com query vazia devolve []" do
    assert_equal [], Fetcher::Channels::Github.search(query: "   ")
  end

  test "8. search fake achata reactions, envia token nos headers e filtra por created:>=" do
    old_gh_token = ENV.delete("GH_TOKEN")
    ENV["GITHUB_TOKEN"] = "token123fake"

    payload = {
      "items" => [
        {
          "html_url" => "https://github.com/rails/rails/issues/500",
          "title" => "Solid Queue performance",
          "reactions" => { "total_count" => 15, "+1" => 12 },
          "comments" => 7,
          "user" => { "login" => "tenderlove" },
          "created_at" => "2026-08-05T10:00:00Z"
        }
      ]
    }

    req_stub = stub_request(:get, %r{\Ahttps://api\.github\.com/search/issues\?})
      .with(headers: { "Authorization" => "Bearer token123fake", "Accept" => "application/vnd.github+json" })
      .to_return(status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" })

    results = Fetcher::Channels::Github.search(query: "solid queue")

    assert_requested req_stub
    assert_equal 1, results.size
    item = results.first

    assert_equal "https://github.com/rails/rails/issues/500", item["url"]
    assert_equal "Solid Queue performance", item["title"]
    assert_equal "github", item["source"]
    assert_equal 15, item["reactions"], "reactions deve vir achatado como Numeric (total_count)"
    refute_kind_of Hash, item["reactions"], "reactions NAO pode ser um Hash"
    assert_equal 7, item["comments"]
    assert_equal "tenderlove", item["author"]
    assert_equal "2026-08-05T10:00:00Z", item["created_at"]
  ensure
    ENV.delete("GITHUB_TOKEN")
    ENV["GH_TOKEN"] = old_gh_token if old_gh_token
  end

  test "9. search quando API responde 403, 429 ou 5xx devolve [] com warn log" do
    stub_request(:get, %r{\Ahttps://api\.github\.com/search/issues\?})
      .to_return(status: 403, body: JSON.generate({ "message" => "API rate limit exceeded" }))

    log_output = capture_log { Fetcher::Channels::Github.search(query: "rails") }
    assert_equal [], Fetcher::Channels::Github.search(query: "rails")
  end

  test "10. search quando rate limit local e excedido levanta RateLimited" do
    Fetcher::HostRateLimiter.stubs(:exceeded?).with("api.github.com", max: Fetcher::Channels::Github::MAX_PER_WINDOW).returns(true)

    err = assert_raises(Fetcher::Channels::Github::RateLimited) do
      Fetcher::Channels::Github.search(query: "rails")
    end
    assert_kind_of Fetcher::Channels::Error, err
  end

  private

  def capture_log
    old_logger = Rails.logger
    strio = StringIO.new
    Rails.logger = Logger.new(strio)
    yield
    strio.string
  ensure
    Rails.logger = old_logger
  end
end
