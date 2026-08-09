# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/rss"
require_relative "../../../../lib/fetcher/safe_http_client" # o dublê usa o Struct Response

class Fetcher::Channels::RssTest < ActiveSupport::TestCase
  RSS2 = <<~XML
    <?xml version="1.0"?>
    <rss version="2.0"><channel>
      <title>Blog de Testes</title>
      <item>
        <title>Primeiro post</title>
        <link>https://exemplo.test/1</link>
        <description>&lt;p&gt;Resumo do primeiro post.&lt;/p&gt;</description>
        <pubDate>Mon, 03 Aug 2026 10:00:00 GMT</pubDate>
      </item>
      <item>
        <title>Segundo post</title>
        <link>https://exemplo.test/2</link>
        <description>Resumo do segundo.</description>
      </item>
    </channel></rss>
  XML

  ATOM = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Rust Blog</title>
      <entry>
        <title>Announcing Rust 2.0</title>
        <link href="https://blog.test/rust-2" rel="alternate"/>
        <updated>2026-08-01T12:00:00Z</updated>
        <summary>Resumo do anuncio.</summary>
      </entry>
    </feed>
  XML

  def response(body, content_type: "application/xml", final_url: "https://exemplo.test/feed")
    Fetcher::SafeHttpClient::Response.new(
      status: 200, final_url: final_url, content_type: content_type, body: body
    )
  end

  test "extrai itens de RSS 2.0" do
    result = Fetcher::Channels::Rss.call(url: "https://exemplo.test/feed", response: response(RSS2))

    assert_equal "Blog de Testes", result[:title]
    assert_equal "rss", result[:metadata]["source"]
    assert_equal "rss", result[:metadata]["format"]
    assert_equal 2, result[:metadata]["item_count"]
    assert_includes result[:content], "## Primeiro post"
    assert_includes result[:content], "https://exemplo.test/1"
    assert_includes result[:content], "Resumo do primeiro post."
    refute_includes result[:content], "<p>"
  end

  test "extrai entradas de Atom, inclusive o link do atributo href" do
    result = Fetcher::Channels::Rss.call(url: "https://blog.test/feed.xml", response: response(ATOM))

    assert_equal "Rust Blog", result[:title]
    assert_equal "atom", result[:metadata]["format"]
    assert_equal 1, result[:metadata]["item_count"]
    assert_includes result[:content], "## Announcing Rust 2.0"
    assert_includes result[:content], "https://blog.test/rust-2"
  end

  test "devolve nil para XML que nao e feed" do
    xml = '<?xml version="1.0"?><sitemapindex><sitemap><loc>https://x.test/</loc></sitemap></sitemapindex>'

    assert_nil Fetcher::Channels::Rss.call(url: "https://x.test/sitemap.xml", response: response(xml))
  end

  test "devolve nil para XML malformado" do
    assert_nil Fetcher::Channels::Rss.call(url: "https://x.test/f", response: response("<rss><channel"))
  end

  test "feed vazio e feed, nao nil" do
    xml = '<?xml version="1.0"?><rss version="2.0"><channel><title>Vazio</title></channel></rss>'
    result = Fetcher::Channels::Rss.call(url: "https://x.test/f", response: response(xml))

    assert_equal 0, result[:metadata]["item_count"]
    assert_equal "Vazio", result[:title]
  end

  test "corta em MAX_ITEMS e registra o corte" do
    itens = (1..40).map { |i| "<item><title>Post #{i}</title><link>https://x.test/#{i}</link></item>" }.join
    xml = %(<?xml version="1.0"?><rss version="2.0"><channel><title>Muitos</title>#{itens}</channel></rss>)

    result = Fetcher::Channels::Rss.call(url: "https://x.test/f", response: response(xml))

    assert_equal Fetcher::Channels::Rss::MAX_ITEMS, result[:metadata]["item_count"]
    assert_equal 40, result[:metadata]["item_total"]
    assert_equal true, result[:metadata]["truncated"]
  end

  test "sem response nao ha o que parsear" do
    assert_nil Fetcher::Channels::Rss.call(url: "https://x.test/f", response: nil)
  end
end
