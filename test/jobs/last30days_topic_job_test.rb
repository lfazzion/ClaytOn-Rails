# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/discord_api_client"
require_relative "../../app/services/discord_message_chunker"
require_relative "../../app/jobs/last30days_topic_job"
require_relative "../../app/models/topic"
require_relative "../../app/models/topic_delivery"

class Last30DaysTopicJobTest < ActiveSupport::TestCase
  setup do
    ENV["DISCORD_DIGEST_CHANNEL_ID"] = "123456"
    @topic = Topic.create!(name: "Ruby on Rails", active: true)
  end

  teardown do
    ENV.delete("DISCORD_DIGEST_CHANNEL_ID")
  end

  test "perform com resultados monta mensagem com dedupe" do
    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]
    gh_results = [{ "title" => "Rails Repo Updates", "url" => "https://github.com/rails/rails", "source" => "github" }]
    pm_results = []

    Fetcher::Channels::Hackernews.stubs(:search).with(query: @topic.name, limit: 10).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).with(query: @topic.name, limit: 10).returns(gh_results)
    Fetcher::Channels::Polymarket.stubs(:search).with(query: @topic.name, limit: 10).returns(pm_results)

    DiscordApiClient.expects(:send_message).with("123456", regexp_matches(/Rails 8.1 Released/)).returns(true)

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    assert res[:sent]
    assert_equal @topic.id, res[:topic_id]

    assert_equal 2, TopicDelivery.where(topic_id: @topic.id).count

    # 2a execucao: tudo dedupe -> sent: false, nao envia mensagem
    res2 = job.perform(@topic.id, "123456")
    refute res2[:sent]
  end

  test "perform fonte que falha segue com as outras" do
    hn_results = [{ "title" => "Rails Post", "url" => "https://news.ycombinator.com/item?id=99", "source" => "hackernews" }]

    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).raises(StandardError.new("GitHub API error"))
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.stubs(:send_message).returns(true)

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    assert res[:sent]
    assert_equal 1, TopicDelivery.where(topic_id: @topic.id).count
  end

  test "perform quando tudo ja entregue nao envia" do
    url_key = Research::Fusion.normalize_url("https://rubyonrails.org/8.1")
    TopicDelivery.create!(topic_id: @topic.id, url_key: url_key, sent_at: 1.day.ago)

    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]

    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.expects(:send_message).never

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    refute res[:sent]
  end

  test "perform com topico removido loga sem erro" do
    non_existent_id = 999_999
    job = Last30DaysTopicJob.new

    res = job.perform(non_existent_id, "123456")
    refute res[:sent]
  end

  # Achado 5: sent_at deve ser ATUALIZADO em re-execuções (não apenas no create)
  test "perform atualiza sent_at em re-execucao para item ja existente" do
    url_key = Research::Fusion.normalize_url("https://rubyonrails.org/8.1")
    # Simula entrega antiga (> 7 dias) — já saiu da janela de dedupe
    old_time = 8.days.ago
    TopicDelivery.create!(topic_id: @topic.id, url_key: url_key, sent_at: old_time)

    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]
    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])
    DiscordApiClient.stubs(:send_message).returns(true)

    freeze_time = Time.current
    Time.stubs(:current).returns(freeze_time)

    job = Last30DaysTopicJob.new
    job.perform(@topic.id, "123456")

    td = TopicDelivery.find_by!(topic_id: @topic.id, url_key: url_key)
    # sent_at deve ter sido atualizado para agora (não manter old_time)
    assert_in_delta freeze_time.to_i, td.sent_at.to_i, 2,
                    "sent_at deve ser atualizado na re-entrega, mas manteve o valor antigo"
  end

  # Achado 6: sem channel_id (nil), nao grava TopicDelivery e retorna sent: false
  test "perform sem channel_id nao grava entregas e retorna sent false" do
    ENV.delete("DISCORD_DIGEST_CHANNEL_ID")

    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]
    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.expects(:send_message).never
    # channel_id nil passado diretamente (Achado 8: DigestJob passa o id resolvido)
    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, nil)

    refute res[:sent], "Esperado sent: false quando channel_id é nil"
    assert_equal 0, TopicDelivery.where(topic_id: @topic.id).count,
                 "Nenhuma entrega deve ser gravada quando channel_id é nil"
  end

  # Achado 4: job grava SOMENTE as url_keys que aparecem na mensagem (limitadas pelo builder)
  test "perform grava apenas url_keys que aparecem na mensagem apos truncamento" do
    # Montar clusters sintéticos: 10 clusters × 4 itens cada (40 itens total)
    # MessageBuilder mostra MAX_CLUSTERS=8 × MAX_ITEMS_PER_CLUSTER=3 = 24 itens
    # Portanto só 24 url_keys devem ser gravadas, não 40

    all_items = []
    clusters = (1..10).map do |i|
      items = (1..4).map do |j|
        item = { "title" => "Item #{i}-#{j}", "url" => "https://example.com/#{i}/#{j}", "source" => "github",
                 "key" => "key-#{i}-#{j}" }
        all_items << item
        item
      end
      {
        "cluster_id" => "cluster-#{i}",
        "title" => "Cluster #{i}",
        "sources" => ["github"],
        "score" => (1.0 - (i * 0.05)),
        "uncertainty" => nil,
        "items" => items
      }
    end

    # Stub do Fusion e Cluster para retornar clusters sintéticos diretamente
    Research::Fusion.stubs(:fuse).returns([{ "key" => "k", "title" => "t", "score" => 0.5 }])
    Research::Cluster.stubs(:cluster).returns(clusters)
    Fetcher::Channels::Hackernews.stubs(:search).returns([])
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.stubs(:send_message).returns(true)

    job = Last30DaysTopicJob.new
    job.perform(@topic.id, "123456")

    count = TopicDelivery.where(topic_id: @topic.id).count
    # 8 clusters × 3 itens = 24, NÃO 10×4=40
    assert_equal 24, count,
                 "Esperado exatamente 24 entregas (MAX_CLUSTERS 8 × MAX_ITEMS 3), mas gravou #{count}"
  end

  # Achado 5 (PR #36): o job DELEGA o chunking ao DiscordMessageChunker (helper
  # único). O algoritmo migrou para o unit test do chunker
  # (test/services/discord_message_chunker_test.rb); aqui verifica-se o
  # contrato de integração: 1 chamada ao helper + 1 send_message por chunk.
  test "perform delega chunking ao DiscordMessageChunker e envia 1 mensagem por chunk" do
    clusters = [
      {
        "cluster_id" => "cluster-1",
        "title" => "Cluster 1",
        "sources" => ["github"],
        "score" => 1.0,
        "uncertainty" => nil,
        "items" => [{ "title" => "Item 1", "url" => "https://example.com/1", "source" => "github", "key" => "key-1" }]
      }
    ]

    Research::Fusion.stubs(:fuse).returns([{ "key" => "k", "title" => "t", "score" => 0.5 }])
    Research::Cluster.stubs(:cluster).returns(clusters)
    Fetcher::Channels::Hackernews.stubs(:search).returns([])
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordMessageChunker.expects(:chunk).returns(["chunk_um", "chunk_dois"])
    DiscordApiClient.expects(:send_message).with("123456", "chunk_um").returns(true)
    DiscordApiClient.expects(:send_message).with("123456", "chunk_dois").returns(true)

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    assert res[:sent]
  end
end
