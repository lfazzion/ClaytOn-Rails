# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/last30days/message_builder"

class Last30DaysMessageBuilderTest < ActiveSupport::TestCase
  test "build com clusters e itens reais formata corretamente" do
    clusters = [
      {
        "cluster_id" => "cluster-1",
        "title" => "Nova versao do Ruby 4.0 lancada",
        "sources" => ["hackernews", "github"],
        "score" => 0.85,
        "uncertainty" => nil,
        "items" => [
          { "title" => "Ruby 4.0 Release Notes", "url" => "https://ruby-lang.org/4.0", "source" => "web" },
          { "title" => "HN Discussion Ruby 4.0", "url" => "https://news.ycombinator.com/item?id=123", "source" => "hackernews" }
        ]
      }
    ]

    result = Last30Days::MessageBuilder.build(clusters: clusters, topic_name: "Ruby")

    # build agora retorna um objeto com :text e :url_keys
    assert_respond_to result, :[]
    msg = result[:text]
    assert_includes msg, "Ruby 4.0 Release Notes"
    assert_includes msg, "https://ruby-lang.org/4.0"
    assert_includes msg, "https://news.ycombinator.com/item?id=123"
    assert_includes msg, "hackernews"
    assert_includes msg, "Ruby"
  end

  test "build retorna url_keys com as keys dos itens renderizados" do
    clusters = [
      {
        "cluster_id" => "cluster-1",
        "title" => "Nova versao do Ruby 4.0 lancada",
        "sources" => ["hackernews", "github"],
        "score" => 0.85,
        "uncertainty" => nil,
        "items" => [
          { "title" => "Ruby 4.0 Release Notes", "url" => "https://ruby-lang.org/4.0", "source" => "web" },
          { "title" => "HN Discussion Ruby 4.0", "url" => "https://news.ycombinator.com/item?id=123", "source" => "hackernews" }
        ]
      }
    ]

    result = Last30Days::MessageBuilder.build(clusters: clusters, topic_name: "Ruby")

    assert_kind_of Array, result[:url_keys]
    # As duas URLs dos 2 itens devem estar em url_keys
    assert_equal 2, result[:url_keys].length
    assert result[:url_keys].all? { |k| k.is_a?(String) && k.length > 0 }
  end

  test "build nao inclui url_keys de itens truncados pelo limite MAX_ITEMS_PER_CLUSTER" do
    # Cluster com 5 itens — só 3 aparecem (MAX_ITEMS_PER_CLUSTER=3)
    # url_keys deve ter apenas os 3 renderizados, não os 5
    cluster = {
      "cluster_id" => "cluster-1",
      "title" => "Noticia Multi",
      "sources" => ["github"],
      "score" => 0.90,
      "uncertainty" => nil,
      "items" => (1..5).map { |j|
        { "title" => "Item #{j}", "url" => "https://example.com/item/#{j}", "source" => "github" }
      }
    }

    result = Last30Days::MessageBuilder.build(clusters: [cluster], topic_name: "Tech")

    # Apenas 3 itens renderizados → apenas 3 keys
    assert_equal 3, result[:url_keys].length
    # Itens 4 e 5 não aparecem no texto
    refute_includes result[:text], "https://example.com/item/4"
    refute_includes result[:text], "https://example.com/item/5"
  end

  test "build nao inclui url_keys de clusters truncados pelo limite MAX_CLUSTERS" do
    # 10 clusters — só 8 aparecem (MAX_CLUSTERS=8)
    clusters = (1..10).map do |i|
      {
        "cluster_id" => "cluster-#{i}",
        "title" => "Cluster Titulo #{i}",
        "sources" => ["github"],
        "score" => (1.0 - (i * 0.05)),
        "uncertainty" => nil,
        "items" => [
          { "title" => "Item #{i}-1", "url" => "https://example.com/#{i}/1", "source" => "github" }
        ]
      }
    end

    result = Last30Days::MessageBuilder.build(clusters: clusters, topic_name: "Tech")

    # Clusters 9 e 10 fora → seus itens não nas url_keys
    refute result[:url_keys].include?(Research::Fusion.normalize_url("https://example.com/9/1")),
           "url_key do cluster 9 nao deve estar presente"
    refute result[:url_keys].include?(Research::Fusion.normalize_url("https://example.com/10/1")),
           "url_key do cluster 10 nao deve estar presente"
    # Clusters 1..8 devem ter seus itens
    assert_equal 8, result[:url_keys].length
  end

  test "build com uncertainty single-source exibe aviso de fonte unica" do
    clusters = [
      {
        "cluster_id" => "cluster-1",
        "title" => "Rumor sobre novo chip AI",
        "sources" => ["polymarket"],
        "score" => 0.70,
        "uncertainty" => "single-source",
        "items" => [
          { "title" => "Rumor AI Chip Market", "url" => "https://polymarket.com/event/ai-chip", "source" => "polymarket" }
        ]
      }
    ]

    result = Last30Days::MessageBuilder.build(clusters: clusters, topic_name: "AI Hardware")

    assert_includes result[:text], "⚠️ fonte única"
    assert_includes result[:text], "https://polymarket.com/event/ai-chip"
  end

  test "build sem clusters retorna estrutura com texto nada encontrado e url_keys vazio" do
    result = Last30Days::MessageBuilder.build(clusters: [], topic_name: "Quantum Computing")

    assert_equal "nada encontrado nas fontes para Quantum Computing", result[:text]
    assert_equal [], result[:url_keys]
  end

  test "build garante que urls vem estritamente dos itens" do
    clusters = [
      {
        "cluster_id" => "cluster-1",
        "title" => "Noticia X",
        "sources" => ["github"],
        "score" => 0.90,
        "uncertainty" => nil,
        "items" => [
          { "title" => "Item Repo X", "url" => "https://github.com/foo/bar", "source" => "github" }
        ]
      }
    ]

    result = Last30Days::MessageBuilder.build(clusters: clusters, topic_name: "OpenSource")
    msg = result[:text]

    urls_in_msg = msg.scan(%r{https?://\S+}).map { |u| u.chomp(")").chomp("]") }
    assert_equal ["https://github.com/foo/bar"], urls_in_msg
  end

  test "build limita a 8 clusters e 3 itens por cluster" do
    clusters = (1..10).map do |i|
      {
        "cluster_id" => "cluster-#{i}",
        "title" => "Cluster Titulo #{i}",
        "sources" => ["github"],
        "score" => (1.0 - (i * 0.05)),
        "uncertainty" => nil,
        "items" => (1..5).map do |j|
          { "title" => "Item #{i}-#{j}", "url" => "https://example.com/#{i}/#{j}", "source" => "github" }
        end
      }
    end

    result = Last30Days::MessageBuilder.build(clusters: clusters, topic_name: "Tech")
    msg = result[:text]

    assert_includes msg, "Cluster Titulo 1"
    assert_includes msg, "Cluster Titulo 8"
    refute_includes msg, "Cluster Titulo 9"
    refute_includes msg, "Cluster Titulo 10"

    # itens 1..3 incluídos, 4..5 não
    assert_includes msg, "https://example.com/1/1"
    assert_includes msg, "https://example.com/1/3"
    refute_includes msg, "https://example.com/1/4"
  end

  # Achado 7: recalcula sources e uncertainty nos itens FINAIS do cluster
  test "build recalcula uncertainty para single-source quando cluster original tinha 2 fontes mas so 1 sobrou" do
    # Cluster original tinha 2 fontes (github + hackernews), incerteza nil
    # Após dedupe externo, só resta 1 item de 1 fonte → deve exibir ⚠️ fonte única
    cluster = {
      "cluster_id" => "cluster-1",
      "title" => "Cluster multi-fonte com 1 item restante",
      "sources" => ["github", "hackernews"],  # fontes ORIGINAIS (pre-dedupe)
      "score" => 0.80,
      "uncertainty" => nil,                   # incerteza ORIGINAL (pre-dedupe)
      "items" => [
        # só 1 item sobrou após dedupe (o de github foi entregue, removido pelo job)
        { "title" => "HN Item", "url" => "https://news.ycombinator.com/item?id=999", "source" => "hackernews" }
      ]
    }

    result = Last30Days::MessageBuilder.build(clusters: [cluster], topic_name: "Tech")

    # Com só 1 fonte nos itens reais, deve recalcular como single-source
    assert_includes result[:text], "⚠️ fonte única",
                    "Esperado aviso de fonte única ao renderizar cluster com 1 item de 1 fonte"
  end

  test "build recalcula sources como uniao das fontes dos itens exibidos" do
    cluster = {
      "cluster_id" => "cluster-1",
      "title" => "Cluster",
      "sources" => ["github", "hackernews", "polymarket"],  # fontes ORIGINAIS (3 fontes)
      "score" => 0.80,
      "uncertainty" => nil,
      "items" => [
        { "title" => "Item HN", "url" => "https://news.ycombinator.com/item?id=1", "source" => "hackernews" },
        { "title" => "Item GH", "url" => "https://github.com/org/repo", "source" => "github" }
      ]
    }

    result = Last30Days::MessageBuilder.build(clusters: [cluster], topic_name: "Tech")

    # Apenas hackernews e github devem aparecer nas fontes (polymarket não tem item)
    assert_includes result[:text], "hackernews"
    assert_includes result[:text], "github"
    refute_includes result[:text], "polymarket",
                    "polymarket nao deve aparecer nas fontes pois nenhum item exibido vem dela"
  end

  # Achado 7 (defeito 1): item fundido por 2 streams carrega "sources" => [a, b]
  # e "source" escalar só com o vencedor — as DUAS fontes devem ser listadas
  # e o cluster NÃO pode ser marcado como fonte única.
  test "build lista todas as fontes de item fundido por streams e nao marca fonte unica" do
    cluster = {
      "cluster_id" => "cluster-1",
      "title" => "Rails 8.2 merger",
      "sources" => ["hackernews", "github"],
      "score" => 0.85,
      "uncertainty" => nil,
      "items" => [
        { "title" => "Rails 8.2 discussion", "url" => "https://news.ycombinator.com/item?id=42",
          "source" => "github",              # escalar = vencedor do merge (A9)
          "sources" => ["hackernews", "github"], # candidato fundido por 2 streams
          "local_relevance" => 0.85 }
      ]
    }

    result = Last30Days::MessageBuilder.build(clusters: [cluster], topic_name: "Ruby")
    msg = result[:text]

    assert_includes msg, "hackernews",
                    "fonte hackernews do array sources deve ser listada"
    assert_includes msg, "github",
                    "fonte github do array sources deve ser listada"
    refute_includes msg, "⚠️ fonte única",
                    "cluster corroborado por 2 streams nao pode ser fonte unica"
  end

  # Achado 7 (defeitos 2 e 3): dedupe removeu o item de score alto fora do builder;
  # o score exibido/usado no sort deve ser recalculado dos itens exibidos e,
  # se cair abaixo do limiar do Cluster, o cluster deve passar a thin-evidence.
  test "build recalcula score apos dedupe e marca thin-evidence quando score recalculado cai" do
    cluster = {
      "cluster_id" => "cluster-1",
      "title" => "Item restante fraco",
      "sources" => ["hackernews", "github"],
      "score" => 0.90,          # score ORIGINAL do cluster (pré-dedupe)
      "uncertainty" => nil,
      "items" => [
        # só o item fraco sobrou (o forte foi entregue → dedupe removeu).
        # Item restante é fundido por 2 streams (sources) — assim o thin-evidence
        # vem do SCORE recalculado, não de single-source por falta de fontes.
        { "title" => "HN branch", "url" => "https://news.ycombinator.com/item?id=7",
          "source" => "github", "sources" => ["hackernews", "github"], "local_relevance" => 0.40 }
      ]
    }

    result = Last30Days::MessageBuilder.build(clusters: [cluster], topic_name: "Ruby")
    msg = result[:text]

    assert_includes msg, "score: 0.4",
                    "score exibido deve ser o recalculado (0.40), nao o original 0.90"
    assert_includes msg, "⚠️ evidência fraca",
                    "score recalculado abaixo do limiar deve virar thin-evidence mesmo se o cluster original nao era"
    refute_includes msg, "⚠️ fonte única",
                    "com 2 fontes o aviso deve ser thin-evidence, nao single-source"
  end

  # Achado 7 (defeito 2): o SORT dos clusters deve usar o score recalculado,
  # não o max do cluster original (que pode ter tido itens removidos).
  test "build ordena clusters pelo score recalculado dos itens exibidos" do
    cluster_a = {
      "cluster_id" => "cluster-1",
      "title" => "Cluster A score original alto",
      "sources" => ["hackernews"],
      "score" => 0.95,
      "uncertainty" => nil,
      "items" => [
        { "title" => "Item A fraco", "url" => "https://example.com/a",
          "source" => "hackernews", "sources" => ["hackernews"], "local_relevance" => 0.30 }
      ]
    }
    cluster_b = {
      "cluster_id" => "cluster-2",
      "title" => "Cluster B score original baixo",
      "sources" => ["github"],
      "score" => 0.40,
      "uncertainty" => nil,
      "items" => [
        { "title" => "Item B forte", "url" => "https://example.com/b",
          "source" => "github", "sources" => ["github"], "local_relevance" => 0.80 }
      ]
    }

    result = Last30Days::MessageBuilder.build(clusters: [cluster_a, cluster_b], topic_name: "Ruby")
    msg = result[:text]

    # B (recalc 0.80) deve vir como ## 1. antes de A (recalc 0.30),
    # mesmo com scores originais invertidos (A 0.95 > B 0.40)
    assert_includes msg, "### 1. Cluster B score original baixo (score: 0.8",
                    "cluster com maior score recalculado deve ser o primeiro"
    idx_b = msg.index("Cluster B score original baixo")
    idx_a = msg.index("Cluster A score original alto")
    assert idx_b < idx_a, "sort deve usar score recalculado (B 0.80), nao o original (A 0.95)"
  end
end
