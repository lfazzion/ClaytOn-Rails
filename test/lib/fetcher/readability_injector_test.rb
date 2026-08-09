# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/readability_injector"

class Fetcher::ReadabilityInjectorTest < ActiveSupport::TestCase
  ARTICLE = ("This is a long article about interesting things. " * 30).freeze
  SHORT   = "short blurb".freeze

  test "readability longa (>=500) é usada quando não é live" do
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: ARTICLE,
      body_text: "nav home footer",
      fallback_html: "<p>html</p>",
      live: false
    )
    assert_includes result[:content], "interesting things"
    assert_equal result[:content].length, result[:char_count]
  end

  test "readability curta (<500) cai pra body.innerText" do
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: SHORT,
      body_text: "Body text with #{ARTICLE}",
      fallback_html: "<p>html</p>",
      live: false
    )
    assert_includes result[:content], "Body text"
  end

  test "live=true prefere body.innerText mesmo com readability longa" do
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: ARTICLE,
      body_text: "Bitcoin $78,245.12 USD current price",
      fallback_html: "<p>x</p>",
      live: true
    )
    assert_includes result[:content], "$78,245.12"
  end

  test "readability vazia + body vazio → ruby-readability no HTML" do
    html = "<html><body><article><p>#{ARTICLE}</p></article></body></html>"
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: nil,
      body_text: nil,
      fallback_html: html,
      live: false
    )
    assert_operator result[:content].length, :>, 0
  end

  test "tudo vazio retorna content vazio sem crash" do
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: nil,
      body_text: nil,
      fallback_html: "",
      live: false
    )
    assert_equal "", result[:content]
    assert_equal 0, result[:char_count]
    assert_equal false, result[:truncated]
  end

  test "trunca em max_chars e marca truncated=true" do
    big = "a" * 20_000
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: big,
      body_text: nil,
      fallback_html: "",
      max_chars: 5000,
      live: false
    )
    assert_operator result[:char_count], :<=, 5000
    assert_equal true, result[:truncated]
  end

  test "trunca preferencialmente em boundary de parágrafo" do
    paragraphs = Array.new(10) { |i| "Paragraph #{i}. #{'x' * 200}" }.join("\n\n")
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: paragraphs,
      body_text: nil,
      fallback_html: "",
      max_chars: 800,
      live: false
    )
    # Quando trunca em boundary, o fim é exatamente "\n\n" ou o texto cabe inteiro no último parágrafo.
    assert result[:content].end_with?("\n\n") || !result[:content].include?("\n\n"),
           "Esperava terminar em boundary de parágrafo: #{result[:content][-50..]}"
  end

  test "não trunca quando conteúdo < max_chars" do
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: ARTICLE,
      body_text: nil,
      fallback_html: "",
      max_chars: 8000,
      live: false
    )
    assert_equal false, result[:truncated]
  end

  test "dedup de whitespace excessivo no body fallback" do
    messy = "word1   word2\n\n\n\n\nword3\t\t\tword4"
    result = Fetcher::ReadabilityInjector.extract(
      readability_text: nil,
      body_text: messy,
      fallback_html: "",
      live: false
    )
    assert_no_match(/\t/, result[:content])
    assert_no_match(/   /, result[:content])
    assert_no_match(/\n\n\n/, result[:content])
  end

  test "READABILITY_JS é string não-vazia carregada de vendor/" do
    assert_kind_of String, Fetcher::ReadabilityInjector::READABILITY_JS
    assert_operator Fetcher::ReadabilityInjector::READABILITY_JS.length, :>, 1000
    assert_includes Fetcher::ReadabilityInjector::READABILITY_JS, "Readability"
  end
end
