# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/github"

class Fetcher::Channels::GithubTest < ActiveSupport::TestCase
  PUBLIC_IP = "93.184.216.34"

  setup do
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
end
