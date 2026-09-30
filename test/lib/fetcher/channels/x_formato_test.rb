# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_formato"

class Fetcher::Channels::XFormatoTest < ActiveSupport::TestCase
  X = Fetcher::Channels::XFormato

  # tweet_artigo.json: captura REAL de 2026-09-29 (UserTweetsAndReplies com articles_preview_enabled),
  # podada: autor anonimizado, título e prévia cortados em 40 caracteres.
  def artigo = JSON.parse(File.read(Rails.root.join("test/fixtures/x/tweet_artigo.json")))

  test "artigo real: formato, titulo e previa do bloco article (o full_text e so o t.co)" do
    assert_equal({ "formato" => "artigo",
                   "artigo" => { "titulo" => "The Second Brain Is Not a Storage System",
                                 "previa" => "Most people who build a second brain mak" } }, X.campos(artigo))
  end

  test "artigo sem o bloco article ainda e reconhecido pelo link x.com/i/article" do
    tweet = artigo.except("article")
    assert_equal({ "formato" => "artigo", "artigo" => { "titulo" => nil, "previa" => nil } }, X.campos(tweet))
  end

  test "texto do artigo e titulo + previa, nao o t.co" do
    assert_equal "The Second Brain Is Not a Storage System\n\nMost people who build a second brain mak", X.texto(artigo)
  end

  test "post longo: formato longo e texto inteiro do note_tweet" do
    tweet = { "legacy" => { "full_text" => "cortado…" },
              "note_tweet" => { "note_tweet_results" => { "result" => { "text" => "texto inteiro" } } } }
    assert_equal({ "formato" => "longo" }, X.campos(tweet))
    assert_equal "texto inteiro", X.texto(tweet)
  end

  test "post curto: formato curto e texto do full_text" do
    tweet = { "legacy" => { "full_text" => "oi https://t.co/x",
                            "entities" => { "urls" => [{ "expanded_url" => "https://example.com/a" }] } } }
    assert_equal({ "formato" => "curto" }, X.campos(tweet))
    assert_equal "oi https://t.co/x", X.texto(tweet)
  end
end
