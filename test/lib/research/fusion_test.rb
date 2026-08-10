# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/research/fusion"


class ResearchFusionTest < ActiveSupport::TestCase
  # Helper: monta um item estilo HackerNews com campos suficientes para o
  # Fusion extrair tudo sem chamar o Scorer (campos já vêm preenchidos).
  def hn_item(title:, url: nil, source: "hackernews", item_id: "1",
              author: "alice", points: 50, comments: 10, snippet: nil,
              local_relevance: nil, freshness: 0.8, source_quality: nil,
              published_at: nil, relevance_score: nil, engagement: nil, extra: {})
    item = {
      "title"    => title,
      "url"      => url,
      "source"   => source,
      "item_id"  => item_id,
      "author"   => author,
      "points"   => points,
      "comments" => comments,
      "metadata" => {
        "source"        => source,
        "item_id"       => item_id,
        "local_relevance" => local_relevance,
        "freshness"     => freshness,
        "published_at"  => published_at
      }
    }
    item["snippet"] = snippet if snippet
    item["source_quality"] = source_quality if source_quality
    item["relevance_score"] = relevance_score if relevance_score
    item["engagement"] = engagement unless engagement.nil?
    item.merge(extra)
  end

  # Helper: monta um item estilo Reddit com seus campos nativos.
  def reddit_item(title:, url:, source: "reddit", item_id: "r1",
                  author: "bob", score: 100, num_comments: 20, snippet: nil,
                  local_relevance: nil, freshness: 0.5, source_quality: nil,
                  published_at: nil, relevance_score: nil)
    item = {
      "title"        => title,
      "url"          => url,
      "source"       => source,
      "item_id"      => item_id,
      "author"       => author,
      "score"        => score,
      "num_comments" => num_comments,
      "metadata"     => {
        "source"          => source,
        "item_id"         => item_id,
        "local_relevance" => local_relevance,
        "freshness"       => freshness,
        "published_at"    => published_at
      }
    }
    item["snippet"] = snippet if snippet
    item["source_quality"] = source_quality if source_quality
    item["relevance_score"] = relevance_score if relevance_score
    item
  end

  test "dedup por URL normalizada: duas URLs equivalentes viram um so candidato e o rrf soma" do
    a = hn_item(
      title: "Mesmo conteudo A",
      url: "https://WWW.Example.com/path?utm_source=x&id=42",
      item_id: "1"
    )
    b = hn_item(
      title: "Mesmo conteudo B",
      url: "https://example.com/path/?id=42",
      item_id: "2",
      source: "reddit"
    )

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [a],
        "q1:reddit"     => [b]
      },
      pool_limit: 20
    )

    assert_equal 1, pool.size, "URLs que normalizam para a mesma chave viram 1 candidato"

    candidato = pool.first
    expected_key = "https://example.com/path?id=42"
    assert_equal expected_key, candidato["key"]

    rrf_esperado = (1.0 / (60 + 1)) + (1.0 / (60 + 1))
    assert_in_delta rrf_esperado, candidato["rrf_score"], 1e-9

    assert_equal 2, candidato["source_items"].size, "ambos os itens originais ficam no source_items"
    assert_equal ["hackernews", "reddit"], candidato["sources"], "sources na ordem de aparição"
  end

  test "RRF soma ranks: item em 2 streams com ranks 1 e 3 tem rrf maior que item so em 1 stream com rank 2" do
    a = hn_item(title: "A em 2 streams", url: "https://a.example.com/", item_id: "a1", author: "autor-a")
    b = hn_item(title: "B em 1 stream",  url: "https://b.example.com/", item_id: "b1",
                source: "reddit", author: "autor-b")

    placeholder  = hn_item(title: "p1", url: "https://p.example.com/1", item_id: "p1",
                           source: "reddit", author: "autor-p1")
    placeholder2 = hn_item(title: "p2", url: "https://p.example.com/2", item_id: "p2", author: "autor-p2")
    placeholder3 = hn_item(title: "p3", url: "https://p.example.com/3", item_id: "p3", author: "autor-p3")

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [a, b, placeholder],
        "q1:reddit"     => [placeholder2, placeholder3, a]
      },
      pool_limit: 20
    )

    candidato_a = pool.find { |c| c["key"] == "https://a.example.com" }
    candidato_b = pool.find { |c| c["key"] == "https://b.example.com" }
    refute_nil candidato_a
    refute_nil candidato_b

    rrf_a = (1.0 / (60 + 1)) + (1.0 / (60 + 3))
    rrf_b = (1.0 / (60 + 2))

    assert_in_delta rrf_a, candidato_a["rrf_score"], 1e-9
    assert_in_delta rrf_b, candidato_b["rrf_score"], 1e-9
    assert candidato_a["rrf_score"] > candidato_b["rrf_score"],
           "A com 2 contribuicoes (rank 1 e 3) deve ter rrf maior que B so rank 2"
  end

  test "teto por autor: 4 itens do mesmo autor -> no maximo 3 no pool; autor nil nunca e capado" do
    autores = (1..4).map do |i|
      hn_item(
        title: "Item #{i}",
        url: "https://site.example.com/post-#{i}",
        item_id: "p#{i}",
        author: "dominator"
      )
    end
    nil_author = hn_item(
      title: "Sem autor",
      url: "https://outro.example.com/x",
      item_id: "n1",
      author: nil
    )
    mais_nil = hn_item(
      title: "Outro sem autor",
      url: "https://outro.example.com/y",
      item_id: "n2",
      author: nil
    )

    pool = Research::Fusion.fuse(
      streams: { "q1:hackernews" => autores + [nil_author, mais_nil] },
      pool_limit: 20
    )

    autored = pool.select { |c| c["author"] == "dominator" }
    nil_count = pool.count { |c| c["author"].nil? }
    assert_equal 3, autored.size, "teto por autor = 3 (4 candidatos, 1 descartado)"
    assert_equal 2, nil_count, "autor nil nao e contado no teto"
  end

  # A7: teste REESCRITO. O original usava pool_limit: 3 com 3 candidatos no
  # total (1 do reddit + 2 do hackernews) e disparava o early return de
  # diversify_pool (`fused.size <= pool_limit`), entao o bloco de
  # reserva/remainder NUNCA executava — o teste passava com
  # diversify_pool substituida por `fused.first`. Aqui forçamos o
  # cenário que exercita a reserva: pool_limit estritamente menor que o
  # total, com fonte B no fundo do ranking (rrf baixo) mas com
  # local_relevance >= 0.25 (qualificada pela regra DIVERSITY_RELEVANCE_THRESHOLD).
  test "A7: diversidade por fonte: pool_limit < total e fonte com rel >= 0.25 no fundo reserva min_per_source=2" do
    # Fonte A: 3 candidatos com local_relevance alta (RRF alto: ranks 1, 2, 3
    # num unico stream). Ficam todos na cabeca do pool.
    a1 = hn_item(title: "A1", url: "https://a.example.com/1", item_id: "a1",
                 local_relevance: 0.6, author: "a1-author")
    a2 = hn_item(title: "A2", url: "https://a.example.com/2", item_id: "a2",
                 local_relevance: 0.6, author: "a2-author")
    a3 = hn_item(title: "A3", url: "https://a.example.com/3", item_id: "a3",
                 local_relevance: 0.6, author: "a3-author")

    # Fonte B: 2 candidatos com rrf BAIXO (rank 5 e 6 do mesmo stream) mas
    # local_relevance >= 0.25 (qualificados pela regra).
    b1 = reddit_item(title: "B1 baixo-rank mas relevante", url: "https://b.example.com/1",
                     item_id: "b1", local_relevance: 0.3, author: "b1-author")
    b2 = reddit_item(title: "B2 baixo-rank mas relevante", url: "https://b.example.com/2",
                     item_id: "b2", local_relevance: 0.3, author: "b2-author")

    # pool_limit=4 e total de 5: diversity precisa reservar 2 da fonte A
    # (max_relevance_A = 0.6 >= 0.25) e fonte B nao reserva (max < 0.25)
    # -- mas como B NAO passa o threshold, fonte A reserva 2 e os 3
    # primeiros do sort competem com B nas 2 vagas de remainder. Para
    # forcar AMBAS as fontes, vamos ajustar: A reserva 2, e o remainder
    # traz 2 — mas se a fonte B tiver o score suficiente, ambos os
    # candidatos de B sobrevivem.
    # Ajustando: max_relevance_A = 0.6 (>= 0.25) -> reserva 2 vagas para A.
    # Os 3 primeiros do sort sao A1/A2/A3 (mesmo rrf = 1/61, mesmo
    # local_relevance = 0.6); remainder = [B1, B2] (rrf 1/65 e 1/66);
    # remainder preenche as 2 vagas restantes -> B1 e B2 sobrevivem.
    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [a1, a2, a3, a1, a2, b1, b2], # ranks 1..7; a1,a2 duplicam
        "q1:reddit"     => []
      },
      pool_limit: 4
    )
    keys = pool.map { |c| c["key"] }

    # Fonte A: max_relevance=0.6 >= 0.25 -> 2 vagas reservadas.
    # A entrada "q1:hackernews" tem ranks 1..7, mas a1 e a2 aparecem
    # DUAS vezes (a1 em rank 1 e 5; a2 em rank 2 e 6). Mesma URL =>
    # mesmo candidato. O sort por rrf/local_relevance produz um unico
    # candidato por URL. Total de candidatos apos merge: 5 (a1, a2, a3,
    # b1, b2). Desses, A reserva 2 (a1, a2 — top-2 do sort); o
    # remainder traz 2: 3a, 4a vagas = b1, b2 (e a3 cai).
    # A assertiva chave: a3 NAO entra e AMBOS os b entram.
    refute_includes keys, "https://a.example.com/3",
                    "A3 deve cair porque A ja reservou 2 vagas e o remainder trouxe B1+B2"
    assert_includes keys, "https://b.example.com/1", "B1 sobrevive pela regra de remainder"
    assert_includes keys, "https://b.example.com/2", "B2 sobrevive pela regra de remainder"
    assert_equal 4, pool.size

    # Mutacao: min_per_source: 0 simula "sem diversidade". Como o Fusion
    # nao expoe esse param, validamos via stub: se a regra de reserva
    # sumir, a3 e' o primeiro do sort (todos mesmos rrf/local_relevance,
    # tie-break por key) e B1/B2 cairiam. Aqui a regra ESTA ativa, e B1/B2
    # ganham -> a sanity check acima ja pega a regressao.
  end

  test "snippet mais longo vence na colisao de chave" do
    curto = hn_item(
      title: "Titulo curto", url: "https://exemplo.com/post",
      item_id: "1", snippet: "abcdefghij abcdefghij" # 2 palavras, 21 chars
    )
    longo = hn_item(
      title: "Titulo longo", url: "https://exemplo.com/post/",
      item_id: "2", source: "reddit",
      snippet: "a a a a a a a a a a" # 10 palavras, 19 chars
    )

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [curto],
        "q1:reddit"     => [longo]
      },
      pool_limit: 20
    )

    candidato = pool.first
    assert_equal "a a a a a a a a a a", candidato["snippet"],
                 "snippet mais longo = mais PALAVRAS (referencia Python .split())"
  end

  test "sem URL: chave vira 'source:item_id' e nao colide com item de outra fonte" do
    a = hn_item(title: "Sem URL A", url: nil, source: "hackernews", item_id: "alpha")
    b = hn_item(title: "Sem URL B", url: nil, source: "reddit",     item_id: "alpha")

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [a],
        "q1:reddit"     => [b]
      },
      pool_limit: 20
    )

    assert_equal 2, pool.size, "mesmo item_id em fontes diferentes vira chaves distintas"
    keys = pool.map { |c| c["key"] }.sort
    assert_equal ["hackernews:alpha", "reddit:alpha"], keys
  end

  test "item sem title e sem source nao derruba a fusao; vira chave por url ou source:item_id" do
    so_url = hn_item(title: nil, url: "https://so-url.example.com/x", source: "hackernews",
                     item_id: "u1", author: nil)
    pool1 = Research::Fusion.fuse(
      streams: { "q1:hackernews" => [so_url] },
      pool_limit: 20
    )
    assert_equal 1, pool1.size
    assert_equal "https://so-url.example.com/x", pool1.first["key"]
    assert_equal "", pool1.first["title"]
  end

  test "ordenacao final: pool sai ordenado por rrf_score decrescente" do
    items = [
      hn_item(title: "rank 1", url: "https://a.example.com/", item_id: "a1"),
      hn_item(title: "rank 2", url: "https://b.example.com/", item_id: "b1", source: "reddit"),
      hn_item(title: "rank 3", url: "https://c.example.com/", item_id: "c1", source: "reddit")
    ]

    pool = Research::Fusion.fuse(
      streams: { "q1:hackernews" => items },
      pool_limit: 20
    )
    rrf_scores = pool.map { |c| c["rrf_score"] }
    assert_equal rrf_scores.sort.reverse, rrf_scores, "pool ordenado por rrf desc"
    assert_equal "rank 1", pool.first["title"]
    assert_equal "rank 3", pool.last["title"]
  end

  test "mesma fonte+item_id em dois streams nao duplica source_items" do
    item = hn_item(title: "Notícia igual", url: "https://example.com/a", item_id: "42")

    streams = {
      "q1:hackernews" => [item],
      "q2:hackernews" => [item]
    }

    pool = Research::Fusion.fuse(streams: streams, pool_limit: 10)

    assert_equal 1, pool.size, "dedup por URL: 1 candidato"
    assert_equal 1, pool.first["source_items"].size,
                 "source_items NÃO deve duplicar a mesma (fonte, item_id)"
  end

  # A1: extract_local_relevance precisa ler relevance_score (campo do
  # Scorer). Sem isso, candidatos pós-sort chegam com relevance_score
  # preenchido mas local_relevance = 0.0, e o Cluster (que usa
  # local_relevance como score de TRABALHO) degenera.
  test "A1: extract_local_relevance usa relevance_score como fallback" do
    a = hn_item(title: "Item A", url: "https://a.example.com/", item_id: "a1",
                relevance_score: 0.42)
    b = hn_item(title: "Item B", url: "https://b.example.com/", item_id: "b1",
                source: "reddit", local_relevance: 0.91) # local_relevance direto vence

    pool = Research::Fusion.fuse(
      streams: { "q1:hackernews" => [a, b] },
      pool_limit: 10
    )

    cand_a = pool.find { |c| c["key"] == "https://a.example.com" }
    cand_b = pool.find { |c| c["key"] == "https://b.example.com" }
    assert_in_delta 0.42, cand_a["local_relevance"], 1e-9,
                    "relevance_score preenche local_relevance quando ausente"
    assert_in_delta 0.91, cand_b["local_relevance"], 1e-9,
                    "local_relevance explicito tem prioridade sobre relevance_score"
  end

  # A4: primary_score soma freshness*100. O item MAIS FRESCO (publicado
  # hoje) deve ganhar title/url mesmo com local_relevance ligeiramente
  # menor do que o item de 29 dias atras. Sem o *100, freshness 0.97 vs
  # 0.03 dava 0.94 de diferenca; com o *100, sao 94 pontos, e o item
  # hoje vence mesmo com local_relevance -0.09 (9 pontos).
  test "A4: primary_score usa freshness*100 — frescor vence no desempate de title/url" do
    # Dois itens sobre a MESMA URL (mesma chave), cada um em um stream
    # diferente. O item de 29 dias tem local_relevance=0.85, freshness=0.03.
    # O item de hoje tem local_relevance=0.80 (menor), freshness=0.97.
    # primary(0.85, 0.03) = 85 + 3 + 6 = 94
    # primary(0.80, 0.97) = 80 + 97 + 6 = 183 -> item de hoje vence.
    hoje    = Time.now.utc
    atras29 = (Time.now.utc - (29 * 86400))

    antigo = hn_item(title: "Titulo antigo", url: "https://exemplo.com/post",
                     item_id: "1", local_relevance: 0.85, freshness: 0.03,
                     published_at: atras29.iso8601)
    novo   = hn_item(title: "Titulo novo", url: "https://exemplo.com/post",
                     item_id: "2", source: "reddit",
                     local_relevance: 0.80, freshness: 0.97,
                     published_at: hoje.iso8601, author: "bob")

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [antigo],
        "q1:reddit"     => [novo]
      },
      pool_limit: 10
    )

    assert_equal 1, pool.size
    cand = pool.first
    # O item com maior primary_score vence o title/url.
    assert_equal "Titulo novo", cand["title"],
                 "item de HOJE (freshness 0.97) deve vencer o de 29 dias atras apesar de local_relevance menor"
    # E o freshness do candidato e' max(0.03, 0.97) = 0.97.
    assert_in_delta 0.97, cand["freshness"], 1e-9
  end

  # A6: idempotencia do sort. Todos os candidatos com mesmo rrf_score
  # (1/61 cada) sao "rank 1 em seu stream" — o caso comum no regime
  # operacional. Sem tie-break por key, sort_by do Ruby nao garante
  # ordem estavel e o mesmo input pode sair em ordens diferentes.
  test "A6: empate de rrf_score => desempate por key, saida deterministica" do
    # 5 itens, cada um rank 1 em 1 stream diferente (rrf = 1/61 para todos).
    items = [
      hn_item(title: "T-zeta", url: "https://z.example.com/", item_id: "1", source: "z"),
      hn_item(title: "T-alpha", url: "https://a.example.com/", item_id: "2", source: "a"),
      hn_item(title: "T-mike", url: "https://m.example.com/", item_id: "3", source: "m"),
      hn_item(title: "T-bravo", url: "https://b.example.com/", item_id: "4", source: "b"),
      hn_item(title: "T-yankee", url: "https://y.example.com/", item_id: "5", source: "y")
    ]
    streams = items.each_with_index.each_with_object({}) do |(it, i), h|
      h["q#{i}:src"] = [it]
    end

    orders = Array.new(5) do
      pool = Research::Fusion.fuse(streams: streams, pool_limit: 10)
      pool.map { |c| c["key"] }
    end
    assert orders.all? { |o| o == orders.first },
           "ordem de keys nao e' estavel: #{orders.inspect}"
    # E a ordem canonica e' lex por key (tie-break explicito).
    assert_equal orders.first.sort, orders.first
  end

  # A8: extract_engagement so' aceita numerico. Se o campo `engagement`
  # vier como HASH (formato esperado pelo Signals.engagement_raw), o
  # Fusion deve devolver nil e o merge_into_existing NAO pode quebrar
  # com NoMethodError (`[hash, hash].max`).
  test "A8: item com engagement como Hash nao derruba a fusao quando aparece em 2 streams" do
    a = hn_item(title: "Mesmo A", url: "https://e.example.com/", item_id: "1",
                engagement: { "score" => 100, "num_comments" => 30 })
    b = hn_item(title: "Mesmo B", url: "https://e.example.com/", item_id: "2",
                source: "reddit", engagement: { "score" => 200, "num_comments" => 50 })

    pool = nil
    begin
      pool = Research::Fusion.fuse(
        streams: {
          "q1:hackernews" => [a],
          "q1:reddit"     => [b]
        },
        pool_limit: 10
      )
    rescue StandardError => e
      flunk "fuse nao deveria levantar com engagement Hash, mas levantou: #{e.class}: #{e.message}"
    end

    assert_equal 1, pool.size
    # Engagement: hash ignorado => nil (ou 0.0 se outro item trouxer numero).
    assert pool.first["engagement"].nil? || pool.first["engagement"] == 0.0,
           "engagement Hash vira nil/0.0 (NAO quebra)"
  end

  test "A8: item com engagement numerico faz merge por max" do
    a = hn_item(title: "Mesmo A", url: "https://e.example.com/", item_id: "1",
                engagement: 100.0)
    b = hn_item(title: "Mesmo B", url: "https://e.example.com/", item_id: "2",
                source: "reddit", engagement: 250.0)

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [a],
        "q1:reddit"     => [b]
      },
      pool_limit: 10
    )
    assert_equal 1, pool.size
    assert_in_delta 250.0, pool.first["engagement"], 1e-9,
                    "engagement numerico em 2 streams: max(100, 250) = 250"
  end

  # A9: o "source" escalar do candidato segue o item VENCEDOR (maior
  # primary_score), NAO o primeiro item visto. Aqui o item aparece em
  # q1:hackernews rank 5 e em q1:github rank 1 (com local_relevance maior)
  # — o source do candidato deve ser github.
  test "A9: source escalar do candidato segue o item vencedor (primary_score maior)" do
    # Mesmo URL, dois streams. O item de hackernews tem primary_score
    # menor que o de github (local_relevance mais alto). Sem a correcao,
    # o source era "hackernews" (frozen no build_candidate).
    a = hn_item(title: "Titulo HN", url: "https://gh.example.com/repo",
                item_id: "1", source: "hackernews", local_relevance: 0.3,
                freshness: 0.5, author: "a1")
    b = hn_item(title: "Titulo GH", url: "https://gh.example.com/repo",
                item_id: "2", source: "github", local_relevance: 0.9,
                freshness: 0.8, author: "a2")

    pool = Research::Fusion.fuse(
      streams: {
        "q1:hackernews" => [a, hn_item(title: "p1", url: "https://p.example.com/1", item_id: "p1", source: "reddit", author: "p1-a"), hn_item(title: "p2", url: "https://p.example.com/2", item_id: "p2", source: "reddit", author: "p2-a"), hn_item(title: "p3", url: "https://p.example.com/3", item_id: "p3", source: "reddit", author: "p3-a"), hn_item(title: "p4", url: "https://p.example.com/4", item_id: "p4", source: "reddit", author: "p4-a"), a],
        "q1:github"     => [b]
      },
      pool_limit: 10
    )
    cand = pool.find { |c| c["key"] == "https://gh.example.com/repo" }
    refute_nil cand
    assert_equal "github", cand["source"],
                 "source escalar deve seguir o vencedor (github, primary_score maior)"
    assert_equal "Titulo GH", cand["title"],
                 "title do vencedor: Titulo GH"
  end

  # S1: normalize_url percent-encode antes de parsear + rescue alargado.
  # Sem isso, URL com UTF-8 (acentos, CJK) cai no rescue antigo e sai
  # crua — sem strip de www/utm. A correcao codifica em percent-encoding
  # e re-parseia, devolvendo a forma normalizada.
  test "S1: URL com acento e www/utm e' normalizada para a chave canonica" do
    a = hn_item(title: "A", url: "https://WWW.g1.globo.com/eleição?utm_source=news&id=1", item_id: "1")
    b = hn_item(title: "B", url: "https://g1.globo.com/eleição?id=1", item_id: "2", source: "reddit")
    pool = Research::Fusion.fuse(
      streams: { "q1:hackernews" => [a], "q1:reddit" => [b] },
      pool_limit: 10
    )
    assert_equal 1, pool.size, "URLs com acento equivalentes viram 1 candidato"
    key = pool.first["key"]
    assert key.start_with?("https://g1.globo.com/"),
           "host e scheme normalizados: #{key.inspect}"
    refute_includes key, "utm_source", "utm removido"
    refute_includes key, "WWW.", "www. removido"
  end

  test "S1: URL com CJK (nao-ASCII multibyte) nao derruba a fusao" do
    a = hn_item(title: "A", url: "https://example.com/路径/文章", item_id: "1")
    pool = Research::Fusion.fuse(
      streams: { "q1:hackernews" => [a] },
      pool_limit: 10
    )
    assert_equal 1, pool.size
    # O resultado e' a forma percent-encoded (deterministica), NAO a string crua.
    assert_includes pool.first["key"], "%",
                    "CJK vira percent-encoded (sem o rescue silencioso devolver cru)"
  end

  # S2: parse_qs Python descarta keep_blank_values=False. O Ruby mantem
  # o param vazio; sem a correcao, "?flag=&id=1" e "?id=1" viravam
  # chaves diferentes e o dedup quebrava.
  test "S2: param com valor vazio e' descartado na normalizacao" do
    a = hn_item(title: "A", url: "https://example.com/path?flag=&id=1", item_id: "1")
    b = hn_item(title: "B", url: "https://example.com/path?id=1", item_id: "2", source: "reddit")
    pool = Research::Fusion.fuse(
      streams: { "q1:hackernews" => [a], "q1:reddit" => [b] },
      pool_limit: 10
    )
    assert_equal 1, pool.size, "?flag=&id=1 e ?id=1 normalizam para a mesma chave"
    assert_equal "https://example.com/path?id=1", pool.first["key"]
  end

  # S3: split_stream_key. Sem ":" a referencia trata a chave como source
  # inteira; a versao antiga gravava source "" no provenance.
  test "S3: stream_key sem ':' e' tratado como source pura" do
    a = hn_item(title: "A", url: "https://exemplo.com/x", item_id: "1", source: "hackernews")
    pool = Research::Fusion.fuse(
      streams: { "hackernews" => [a] },
      pool_limit: 10
    )
    assert_equal 1, pool.size
    assert_equal "hackernews", pool.first["provenance"].first["source"],
                 "stream_key sem ':' => source = chave inteira"
    assert_equal "", pool.first["provenance"].first["subquery_label"]
  end
end
