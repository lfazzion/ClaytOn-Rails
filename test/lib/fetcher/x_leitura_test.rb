# frozen_string_literal: true

require "test_helper"

class Fetcher::XLeituraTest < ActiveSupport::TestCase
  test "tweet_id aceita id puro e link de post" do
    assert_equal "2102068192550191407", Fetcher::XLeitura.tweet_id("2102068192550191407")
    assert_equal "2102068192550191407",
                 Fetcher::XLeitura.tweet_id("https://x.com/fulano/status/2102068192550191407?s=20")
  end

  test "tweet_id sem id levanta ArgumentError" do
    assert_raises(ArgumentError) { Fetcher::XLeitura.tweet_id("https://x.com/fulano") }
  end

  test "buscar roda cada consulta, espera entre elas e nao depois da ultima" do
    Fetcher::Channels::XGraphql.expects(:search).with(query: "a", limit: 5).returns([{ "url" => "u1" }])
    Fetcher::Channels::XGraphql.expects(:search).with(query: "b", limit: 5).returns([])
    esperas = []

    r = Fetcher::XLeitura.buscar(%w[a b], limite: 5, intervalo: 16, dormir: ->(s) { esperas << s })

    assert_equal [{ "consulta" => "a", "posts" => [{ "url" => "u1" }], "erro" => nil },
                  { "consulta" => "b", "posts" => [], "erro" => nil }], r
    assert_equal [16], esperas
  end

  test "buscar isola a falha de uma consulta e segue para a proxima" do
    Fetcher::Channels::XGraphql.stubs(:search).with(query: "ruim", limit: 20)
                               .raises(Fetcher::Channels::XGraphql::GraphQLError, "HTTP 422")
    Fetcher::Channels::XGraphql.stubs(:search).with(query: "boa", limit: 20).returns([{ "url" => "u" }])

    r = Fetcher::XLeitura.buscar(%w[ruim boa], dormir: ->(_) {})

    assert_match(/XGraphql::GraphQLError: .*HTTP 422/, r[0]["erro"])
    assert_equal [], r[0]["posts"]
    assert_equal [{ "url" => "u" }], r[1]["posts"]
  end

  test "conversa_texto poe o post raiz primeiro e os comentarios numerados depois" do
    conversa = {
      "root" => { "id" => "10", "author" => "autor", "text" => "post raiz",
                  "created_at" => "2026-09-24T12:00:00Z", "likes" => 5, "replies" => 2 },
      "replies" => [
        { "id" => "11", "author" => "leitor", "text" => "nenhum presta",
          "created_at" => "2026-09-24T13:00:00Z", "likes" => 1, "replies" => 0 },
        { "id" => "12", "author" => nil, "text" => "sem autor", "created_at" => nil, "likes" => nil, "replies" => nil }
      ],
      "cursor" => nil
    }

    texto = Fetcher::XLeitura.conversa_texto(conversa)

    assert_match %r{\A# Post 10 — https://x\.com/i/status/10\n}, texto
    assert_includes texto, "[1] @autor · ♥5 · ↳2 · 2026-09-24 12:00 UTC\npost raiz"
    assert_includes texto, "## Comentários (2)"
    assert_includes texto, "[2] @leitor · ♥1 · ↳0 · 2026-09-24 13:00 UTC\nnenhum presta"
    assert_includes texto, "[3] @? · ♥? · ↳?\nsem autor"
    assert texto.index("post raiz") < texto.index("nenhum presta")
  end

  test "conversa le pelo XConversation com o id extraido do link" do
    Fetcher::Channels::XConversation.expects(:fetch).with(tweet_id: "2102068192550191407", limit: 3).returns({ "root" => nil })

    assert_equal({ "root" => nil }, Fetcher::XLeitura.conversa("https://x.com/a/status/2102068192550191407", limite: 3))
  end
end
