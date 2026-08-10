# frozen_string_literal: true

require "test_helper"

class SentimentSourcesRedditTest < ActiveSupport::TestCase
  test "fetch coleta comentarios de threads do Reddit" do
    threads = [
      { "url" => "https://www.reddit.com/r/ruby/comments/abc123/cleitin_bot/", "title" => "Cleitin Bot", "score" => 10, "comments" => 5 }
    ]
    thread_data = {
      "url" => "https://old.reddit.com/r/ruby/comments/abc123/cleitin_bot/",
      "title" => "Cleitin Bot",
      "subreddit" => "ruby",
      "author" => "dev1",
      "comments" => [
        { "author" => "user1", "score" => 5, "depth" => 0, "posted_at" => "2026-08-10T10:00:00Z", "body" => "Excelente bot de teste" }
      ]
    }

    Fetcher::Channels::Reddit.expects(:search).with(query: "cleitin", limit: Research::Sentiment::Sources::Reddit::MAX_THREADS).returns(threads)
    Fetcher::Channels::Reddit.expects(:thread_comments).with(url: "https://www.reddit.com/r/ruby/comments/abc123/cleitin_bot/").returns(thread_data)
    Fetcher::HostRateLimiter.expects(:exceeded?).never

    items = Research::Sentiment::Sources::Reddit.fetch(query: "cleitin", limit: 10)

    assert_equal 1, items.size
    assert_equal "reddit", items.first[:source]
    assert_equal "user1", items.first[:author]
    assert_equal "Excelente bot de teste", items.first[:text]
    assert_not_nil items.first[:posted_at]
  end

  test "trata exceção RateLimited do canal interrompendo busca graciosamente" do
    threads = [
      { "url" => "https://www.reddit.com/r/ruby/comments/abc123/cleitin_bot/", "title" => "Cleitin Bot" }
    ]

    Fetcher::Channels::Reddit.expects(:search).returns(threads)
    Fetcher::Channels::Reddit.expects(:thread_comments).raises(Fetcher::Channels::Reddit::RateLimited.new("old.reddit.com"))

    items = Research::Sentiment::Sources::Reddit.fetch(query: "cleitin", limit: 10)
    assert_equal [], items
  end

  test "ignora threads com url vazia e realiza leituras das threads validas sequencialmente" do
    threads = [
      { "url" => "", "title" => "Thread Vazia" },
      { "url" => nil, "title" => "Thread Nil" },
      { "url" => "https://www.reddit.com/r/ruby/comments/valid1/cleitin_bot/", "title" => "Cleitin Bot 1" }
    ]
    thread_data = {
      "url" => "https://old.reddit.com/r/ruby/comments/valid1/cleitin_bot/",
      "title" => "Cleitin Bot 1",
      "comments" => [
        { "author" => "user1", "posted_at" => "2026-08-10T10:00:00Z", "body" => "Comentário valido na thread 1" }
      ]
    }

    Fetcher::Channels::Reddit.expects(:search).returns(threads)
    Fetcher::Channels::Reddit.expects(:thread_comments).with(url: "https://www.reddit.com/r/ruby/comments/valid1/cleitin_bot/").returns(thread_data)

    items = Research::Sentiment::Sources::Reddit.fetch(query: "cleitin", limit: 10)
    assert_equal 1, items.size
    assert_equal "Comentário valido na thread 1", items.first[:text]
  end
end
