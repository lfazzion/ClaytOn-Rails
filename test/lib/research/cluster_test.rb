# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/research/cluster"
require_relative "../../../lib/research/fusion"


class ResearchClusterTest < ActiveSupport::TestCase
  # Helper: monta um candidato no formato do contrato do Fusion.
  #
  # A1: o Cluster usa `local_relevance` (0-1) como score de TRABALHO.
  # O `rrf_score` do Fusion é ~0.016-0.05 (1/(60+rank) por stream), nunca
  # 0.5-0.95 como os testes antigos fingiam. Os fixtures abaixo refletem
  # o regime real: rrf_score realista (1.0/61 etc.) e local_relevance
  # carregando a "força" do candidato.
  #
  # Para os testes de "ordenar por score" e "score = 0.95", populamos
  # `local_relevance` (não rrf_score) com os valores que o teste quer ver
  # refletidos no output — preservando a INTENCAO (qual candidato é o
  # "líder" e qual o seu score de saída).
  def make_candidate(key:, title: nil, snippet: nil, sources: ["web"], rrf_score: 1.0 / 61.0,
                     url: "https://example.com/#{key}", local_relevance: 0.5,
                     freshness: 0.5, source_quality: 0.6, engagement: nil,
                     author: nil, provenance: [], text: nil, content: nil,
                     extra: {})
    {
      "key"              => key,
      "title"            => title,
      "snippet"          => snippet,
      "url"              => url,
      "source"           => sources.is_a?(Array) ? sources.first : sources,
      "sources"          => sources,
      "local_relevance"  => local_relevance,
      "freshness"        => freshness,
      "source_quality"   => source_quality,
      "engagement"       => engagement,
      "rrf_score"        => rrf_score,
      "author"           => author,
      "provenance"       => provenance,
      "text"             => text,
      "content"          => content
    }.merge(extra)
  end

  # PORTA 1 — Similaridade híbrida
  test "Similarity: textos proximos tem similaridade alta" do
    sim = Research::Cluster::Similarity.hybrid(
      "Apple unveils new M5 chip with massive performance gains",
      "Apple launches new M5 chip with massive performance gains"
    )
    assert sim > 0.7, "textos quase-iguais devem ter similarity > 0.7, obtido: #{sim}"
  end

  test "Similarity: textos diferentes tem similaridade baixa" do
    sim = Research::Cluster::Similarity.hybrid(
      "Apple unveils new M5 chip with massive performance gains",
      "Best chocolate cake recipe for birthday party"
    )
    assert sim < 0.2, "textos sem sobreposicao devem ter similarity < 0.2, obtido: #{sim}"
  end

  test "Similarity: texto vazio ou nil retorna 0.0 sem erro" do
    a = Research::Cluster::Similarity::PreparedText.from_raw("", Research::Relevance::STOPWORDS)
    b = Research::Cluster::Similarity::PreparedText.from_raw(nil, Research::Relevance::STOPWORDS)
    assert_equal 0.0, Research::Cluster::Similarity.similarity(a, b)
  end

  test "clustering herda a similaridade alta: dois titulos quase-iguais agrupam" do
    a = make_candidate(key: "a", title: "SpaceX Starship reaches orbit on tenth test flight",
                       snippet: "details about the launch", sources: ["reddit"],
                       local_relevance: 0.7, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "b", title: "SpaceX Starship reaches orbit on tenth test flight",
                       snippet: "slightly different coverage", sources: ["hackernews"],
                       local_relevance: 0.6, rrf_score: 1.0 / 62.0)
    out = Research::Cluster.cluster([a, b], intent: "breaking_news")
    assert_equal 1, out.size, "dois titulos quase-iguais devem cair no mesmo grupo"
    assert_equal %w[a b], out.first["keys"]
  end

  # PORTA 2 — cluster_mode "none" e intent nao-agrupavel
  test "cluster_mode none devolve um cluster por candidato" do
    list = [
      make_candidate(key: "a", title: "Story A", sources: ["reddit"], local_relevance: 0.9),
      make_candidate(key: "b", title: "Story B", sources: ["x"],      local_relevance: 0.8),
      make_candidate(key: "c", title: "Story C", sources: ["youtube"], local_relevance: 0.7)
    ]
    out = Research::Cluster.cluster(list, intent: "breaking_news", cluster_mode: "none")
    assert_equal 3, out.size
    assert_equal %w[cluster-1 cluster-2 cluster-3], out.map { |c| c["cluster_id"] }
    assert_equal [list[0]["key"]], out[0]["keys"]
    assert_equal [list[1]["key"]], out[1]["keys"]
    assert_equal [list[2]["key"]], out[2]["keys"]
    # Mesma ordenacao (1 por candidato, sem merge)
    assert_equal [list[0], list[1], list[2]], out.flat_map { |c| c["items"] }
  end

  # A3: identity_clusters (intent nao-clusterable OU cluster_mode "none")
  # usa SÓ cand["title"] como titulo do cluster — NUNCA text_for (title+snippet).
  # Antes, identity_clusters chamava text_for, que cola snippet no titulo e
  # torna "tutorial" e "tutorial de hooks" parecidos. Agora a saida fica
  # controlada.
  test "identity_clusters usa apenas o title (sem colar snippet) para cluster_mode none" do
    cand = make_candidate(
      key: "a", title: "Tutorial R",
      snippet: "passo a passo com 200 linhas de exemplo e screenshots",
      sources: ["reddit"], local_relevance: 0.9
    )
    out = Research::Cluster.cluster([cand], intent: "breaking_news", cluster_mode: "none")
    assert_equal 1, out.size
    assert_equal "Tutorial R", out.first["title"],
                 "title do cluster identity = exatamente cand['title'] (sem snippet colado)"
  end

  test "identity_clusters usa apenas o title para intent nao-clusterable" do
    cand = make_candidate(
      key: "a", title: "React hooks guide",
      snippet: "aprenda useState useEffect useMemo useCallback",
      sources: ["reddit"], local_relevance: 0.9
    )
    out = Research::Cluster.cluster([cand], intent: "tutorial")
    assert_equal 1, out.size
    assert_equal "React hooks guide", out.first["title"],
                 "title do cluster identity = exatamente cand['title'] (sem snippet colado)"
  end

  # PORTA 3 — Threshold breaking_news (0.42) vs outros (0.48)
  test "breaking_news tem threshold menor: titulos com overlap parcial agrupam em breaking_news mas nao em opinion" do
    # Par calibrado experimentalmente (medido com Similarity.hybrid):
    #   ngram jaccard ~ 0.434, token jaccard ~ 0.364, hybrid ~ 0.434
    # -> passa 0.42 (breaking_news) e NAO passa 0.48 (opinion).
    a = make_candidate(key: "a", title: "Apple unveils new Vision Pro with massive performance upgrade",
                       sources: ["reddit"], local_relevance: 0.7, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "b", title: "Apple reveals Vision Pro with major performance gains",
                       sources: ["hackernews"], local_relevance: 0.65, rrf_score: 1.0 / 62.0)

    out_breaking = Research::Cluster.cluster([a, b], intent: "breaking_news")
    assert_equal 1, out_breaking.size,
                 "breaking_news (threshold 0.42) deve agrupar: #{out_breaking.map { |c| c['keys'] }.inspect}"
    assert_equal %w[a b], out_breaking.first["keys"]

    out_opinion = Research::Cluster.cluster([a, b], intent: "opinion")
    assert_equal 2, out_opinion.size,
                 "opinion (threshold 0.48) deve manter separados: #{out_opinion.map { |c| c['keys'] }.inspect}"
  end

  # PORTA 4 — Grupo ordena por local_relevance desc (A1) e lider e o de maior
  test "grupo ordena por local_relevance desc e lider e o de maior local_relevance" do
    a = make_candidate(key: "low",  title: "Quantum chip news alpha", sources: ["reddit"],
                       local_relevance: 0.50, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "high", title: "Quantum chip news alpha", sources: ["hackernews"],
                       local_relevance: 0.95, rrf_score: 1.0 / 62.0)
    c = make_candidate(key: "mid",  title: "Quantum chip news alpha", sources: ["x"],
                       local_relevance: 0.70, rrf_score: 1.0 / 63.0)
    list = [a, b, c] # entrada DESORDENADA
    out = Research::Cluster.cluster(list, intent: "breaking_news")
    assert_equal 1, out.size
    assert_equal %w[high mid low], out.first["keys"]
    # O lider e' o de maior local_relevance: sua key vem primeiro em "keys"
    # e seu titulo e' o do cluster.
    assert_equal "high", out.first["keys"].first
    assert_equal "Quantum chip news alpha", out.first["title"]
    # A1: score = max(local_relevance) do grupo, NAO max(rrf_score).
    assert_in_delta 0.95, out.first["score"], 1e-9
    # Items vem ordenados por local_relevance desc
    assert_equal %w[high mid low], out.first["items"].map { |i| i["key"] }
  end

  # PORTA 5 — MMR selecao diversa
  test "MMR: grupo com duplicatas quase-exatas escolhe representantes diversos" do
    # Top 3 quase-duplicatas tem local_relevance muito proximo (0.95/0.93/0.91).
    # O 4o quase-duplicata (d4) tem local_relevance menor (0.85) e NAO deve entrar
    # porque v1 e v2 tem mais diversificacao com a mesma faixa de score.
    base = "OpenAI announces GPT-6 with trillion parameter architecture"
    candidates = [
      make_candidate(key: "d1", title: base, sources: ["reddit"], local_relevance: 0.95, rrf_score: 1.0 / 61.0),
      make_candidate(key: "d2", title: base, sources: ["x"], local_relevance: 0.93, rrf_score: 1.0 / 62.0),
      make_candidate(key: "d3", title: base, sources: ["hackernews"], local_relevance: 0.91, rrf_score: 1.0 / 63.0),
      make_candidate(key: "d4", title: base, sources: ["youtube"], local_relevance: 0.85, rrf_score: 1.0 / 64.0),
      make_candidate(key: "v1", title: "Trillion parameter architecture revealed in OpenAI GPT-6 announcement",
                     sources: ["web"], local_relevance: 0.80, rrf_score: 1.0 / 65.0),
      make_candidate(key: "v2", title: "GPT-6 trillion parameter architecture revealed by OpenAI team",
                     sources: ["rss"], local_relevance: 0.78, rrf_score: 1.0 / 66.0)
    ]
    out = Research::Cluster.cluster(candidates, intent: "breaking_news")
    assert_equal 1, out.size, "todos os 6 devem cair no mesmo grupo greedy: #{out.map { |c| c['keys'] }.inspect}"
    reps = out.first["representative_ids"]
    assert_equal 3, reps.size

    # O representante #1 deve ser o de maior local_relevance.
    assert_equal "d1", reps[0]

    # Propriedade-chave do MMR: dos 4 quase-duplicatas d1/d2/d3/d4, no
    # MAXIMO 1 pode aparecer como representante alem do d1 (que ja
    # entra como #1).
    near_dupes_in_reps = reps.count { |r| %w[d1 d2 d3 d4].include?(r) }
    assert near_dupes_in_reps <= 2,
           "MMR trouxe #{near_dupes_in_reps} quase-duplicatas em #{reps.inspect} (max 2 permitido, incluindo o lider d1)"

    # Pelo menos uma das variacoes (v1 ou v2) deve entrar no top-3.
    assert(reps.include?("v1") || reps.include?("v2"),
           "MMR deve trazer pelo menos uma variacao diversa: #{reps.inspect}")
  end

  # PORTA 6 — Uncertainty
  test "cluster de 1 fonte => single-source mesmo com local_relevance alto" do
    a = make_candidate(key: "a", title: "Mars rover finds water ice underground",
                       sources: ["reddit"], local_relevance: 0.90, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "b", title: "Mars rover finds water ice beneath surface",
                       sources: ["reddit"], local_relevance: 0.85, rrf_score: 1.0 / 62.0)
    out = Research::Cluster.cluster([a, b], intent: "breaking_news")
    assert_equal 1, out.size
    assert_equal "single-source", out.first["uncertainty"]
  end

  # A1: thin-evidence agora é decidido por local_relevance (NAO rrf_score).
  # A intencao do teste e': "cluster multi-fonte com score < 0.55 ->
  # thin-evidence". Antes, rrf_score 0.40/0.42 estava em escala "falsa"
  # e o teste so passava por isso. Agora usamos local_relevance 0.40/0.42
  # para preservar a intencao.
  test "cluster multi-fonte com max local_relevance < 0.55 => thin-evidence" do
    a = make_candidate(key: "a", title: "Subtle update to obscure framework released",
                       sources: ["reddit"], local_relevance: 0.40, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "b", title: "Subtle update to obscure framework released quietly",
                       sources: ["hackernews"], local_relevance: 0.42, rrf_score: 1.0 / 62.0)
    out = Research::Cluster.cluster([a, b], intent: "breaking_news")
    assert_equal 1, out.size
    assert_equal "thin-evidence", out.first["uncertainty"]
  end

  # A1: o teste historico "cluster multi-fonte forte => uncertainty nil"
  # afirmava isso com rrf_score 0.88/0.82/0.75. Esse valor era o SINAL
  # (antes, o Cluster usava rrf_score como score). Agora o sinal vem de
  # local_relevance: populamos 0.88/0.82/0.75 em local_relevance e mantemos
  # rrf_score em faixa realista.
  test "cluster multi-fonte forte => uncertainty nil (A1: local_relevance 0.88/0.82/0.75)" do
    a = make_candidate(key: "a", title: "Federal Reserve raises interest rates by 25 basis points",
                       sources: ["reddit"], local_relevance: 0.88, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "b", title: "Federal Reserve raises interest rates by 25 basis points",
                       sources: ["hackernews"], local_relevance: 0.82, rrf_score: 1.0 / 62.0)
    c = make_candidate(key: "c", title: "Fed raises interest rates 25 basis points amid inflation concerns",
                       sources: ["x"], local_relevance: 0.75, rrf_score: 1.0 / 63.0)
    out = Research::Cluster.cluster([a, b, c], intent: "breaking_news")
    assert_equal 1, out.size
    assert_nil out.first["uncertainty"]
  end

  # A6: idempotencia do sort dentro de um grupo. sort_by do Ruby NAO e'
  # estavel; com 4 candidatos no mesmo local_relevance (empate exato),
  # o antigo `sort_by { |c| -score_of(c) }` podia devolver qualquer
  # ordem. Agora ha tie-break por key.
  test "A6: empate de local_relevance => desempate por key, saida estavel" do
    candidates = [
      make_candidate(key: "k3", title: "Same story event 3", sources: ["a"], local_relevance: 0.7),
      make_candidate(key: "k1", title: "Same story event 1", sources: ["b"], local_relevance: 0.7),
      make_candidate(key: "k4", title: "Same story event 4", sources: ["c"], local_relevance: 0.7),
      make_candidate(key: "k2", title: "Same story event 2", sources: ["d"], local_relevance: 0.7)
    ]
    # Roda 5x e exige a mesma ordem de keys.
    orders = Array.new(5) do
      out = Research::Cluster.cluster(candidates, intent: "breaking_news")
      assert_equal 1, out.size
      out.first["keys"]
    end
    assert orders.all? { |o| o == orders.first },
           "ordem de keys nao e' estavel: #{orders.inspect}"
    # E a ordem canonica e' lex por key (tie-break explicito).
    assert_equal %w[k1 k2 k3 k4], orders.first
  end

  # A5: normalize Unicode preserva acentos. O regex ASCII antigo
  # ([^a-z0-9\s]) quebrava "proteção" -> "prote o" e "informação" -> "informa o",
  # gerando tokens disjuntos das grafias sem acento e derrubando a
  # similaridade. O [:word:] do Ruby é Unicode-aware e preserva as letras.
  # (NOTA: testar a normalize DIRETAMENTE — um teste de agrupamento com
  # frases quase idênticas não acusa nessa mutação, porque o n-gram de 3
  # chars do resto da frase ainda passa do threshold.)
  test "A5: normalize preserva acentos (regex nao quebra tokens)" do
    norm = Research::Cluster::Similarity.normalize("Governo sanciona lei de proteção à informação")
    assert_includes norm, "proteção"
    assert_includes norm, "informação"
    refute_includes norm, "prote o"
    refute_includes norm, "informa o"
  end

  # PORTA 7 — nil-safety
  test "candidato sem title (nil) nao derruba e similaridade com outros fica 0" do
    a = make_candidate(key: "a", title: "Climate summit reaches historic agreement",
                       sources: ["reddit"], local_relevance: 0.8, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "b", title: nil, sources: ["x"],
                       local_relevance: 0.7, rrf_score: 1.0 / 62.0)
    c = make_candidate(key: "c", title: "Different topic entirely about cooking recipes",
                       sources: ["hackernews"], local_relevance: 0.6, rrf_score: 1.0 / 63.0)
    list = [a, b, c]
    out = nil
    begin
      out = Research::Cluster.cluster(list, intent: "breaking_news")
    rescue StandardError => e
      flunk "cluster nao deveria levantar com title nil, mas levantou: #{e.class}: #{e.message}"
    end
    assert_equal 3, out.size, "b (sem titulo) deve ficar em grupo proprio: #{out.map { |c| c['keys'] }.inspect}"
  end

  # PORTA 8 — sources união ordenada e única
  test "sources do cluster e uniao ordenada e unica" do
    a = make_candidate(key: "a", title: "Apple announces new Vision Pro launch date",
                       sources: ["reddit", "web"], local_relevance: 0.9, rrf_score: 1.0 / 61.0)
    b = make_candidate(key: "b", title: "Apple announces new Vision Pro launch date official",
                       sources: ["hackernews", "web", "reddit"], local_relevance: 0.8,
                       rrf_score: 1.0 / 62.0)
    c = make_candidate(key: "c", title: "Apple announces new Vision Pro launch",
                       sources: ["x", "reddit"], local_relevance: 0.7, rrf_score: 1.0 / 63.0)
    list = [a, b, c]
    out = Research::Cluster.cluster(list, intent: "breaking_news")
    assert_equal 1, out.size
    # Uniao: hackernews, reddit, web, x. Ordenada: hackernews, reddit, web, x.
    assert_equal %w[hackernews reddit web x], out.first["sources"]
  end
end

class ResearchFusionClusterIntegrationTest < ActiveSupport::TestCase
  # Item com relevance_score (campo que o Scorer.sort grava - ver
  # lib/research/scorer.rb:80). Sem local_relevance direto: o Fusion
  # precisa ler relevance_score (A1 da revisao opus-5-high).
  def hn_item(title:, url:, source: "hackernews", item_id:, author: "alice",
              relevance_score: 0.7, points: 50, comments: 10)
    {
      "title"    => title,
      "url"      => url,
      "source"   => source,
      "item_id"  => item_id,
      "author"   => author,
      "points"   => points,
      "comments" => comments,
      "metadata" => { "source" => source, "item_id" => item_id },
      "relevance_score" => relevance_score
    }
  end

  test "A1 integracao: cluster multi-fonte forte vindo do Fusion NAO sai thin-evidence" do
    a = hn_item(
      title: "Federal Reserve raises interest rates by 25 basis points",
      url: "https://example.com/fed-1", source: "hackernews", item_id: "1",
      relevance_score: 0.88
    )
    b = hn_item(
      title: "Federal Reserve raises interest rates by 25 basis points",
      url: "https://example.com/fed-2", source: "reddit", item_id: "2",
      author: "bob", relevance_score: 0.82
    )
    c = hn_item(
      title: "Fed raises interest rates 25 basis points amid inflation concerns",
      url: "https://example.com/fed-3", source: "x", item_id: "3",
      author: "carol", relevance_score: 0.75
    )

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [a],
        "q1:reddit"     => [b],
        "q1:x"          => [c]
      },
      pool_limit: 10
    )
    assert_equal 3, pool.size
    pool_by_source = pool.each_with_object({}) { |c, h| h[c["source"]] = c["local_relevance"] }
    assert_in_delta 0.88, pool_by_source["hackernews"], 1e-9
    assert_in_delta 0.82, pool_by_source["reddit"],     1e-9
    assert_in_delta 0.75, pool_by_source["x"],          1e-9

    clusters = Research::Cluster.cluster(pool, intent: "breaking_news")
    assert_equal 1, clusters.size
    assert_nil clusters.first["uncertainty"],
               "cluster multi-fonte forte NAO deve sair thin-evidence (regressao A1): #{clusters.first.inspect}"
    assert_in_delta 0.88, clusters.first["score"], 1e-9,
                    "score = max(local_relevance) do grupo, NAO max(rrf_score) que seria ~0.05"
  end
end
