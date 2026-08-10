# frozen_string_literal: true

require "uri"
require "cgi"
require "set"

require_relative "relevance"
require_relative "signals"

module Research
  # Weighted Reciprocal Rank Fusion (RRF) para streams de candidatos.
  #
  # Porta Ruby de lib/research/fusion (Fase 3 do last30days). Recebe vários
  # streams (chave "label:source" -> Array de Hash de itens já ordenados por
  # relevância) e devolve um pool fundido, deduplicado por URL normalizada,
  # com cap por autor e diversidade mínima por fonte.
  #
  # NOTA sobre pesos: como o Cleitin ainda não tem subqueries rotuladas
  # (a fase do QueryPlanner vem depois), `weight` é fixo em 1.0 aqui. Quando
  # o mapa de subqueries do last30days for portado, basta multiplicar
  # `subquery.weight * plan.source_weights[source]` no lugar do 1.0
  # atual. Mantemos `source_weights = 1.0` pelo mesmo motivo.
  module Fusion
    RRF_K = 60
    DIVERSITY_RELEVANCE_THRESHOLD = 0.25
    MAX_ITEMS_PER_AUTHOR = 3

    # Chave de stream: "label:source" — divide na ÚLTIMA ocorrência de ":" para
    # tolerar labels que contenham ":" (defensivo; hoje as labels do last30days
    # não têm, mas a forma é a que o orquestrador fixou).
    def self.fuse(streams:, pool_limit: 20)
      return [] if streams.nil? || streams.empty?

      candidates = {}
      seen_source_items = {}

      streams.each do |stream_key, items|
        next if items.nil? || items.empty?

        subquery_label, source_name = split_stream_key(stream_key.to_s)
        source_name = source_name.to_s
        subquery_label = subquery_label.to_s

        weight = 1.0 # gancho futuro: subquery.weight * source_weights[source]
        Array(items).each_with_index do |item, idx|
          next unless item.is_a?(Hash)

          rank = idx + 1
          key = candidate_key(item)

          item_local_relevance = extract_local_relevance(item)
          item_freshness = extract_freshness(item)
          item_source_quality = extract_source_quality(item)
          item_engagement = extract_engagement(item)
          item_source = item_source_value(item)

          rrf_contrib = weight / (RRF_K + rank).to_f

          if candidates.key?(key)
            merge_into_existing(
              candidates[key], seen_source_items[key], item,
              subquery_label: subquery_label, source_name: source_name,
              rank: rank, rrf_contrib: rrf_contrib,
              item_local_relevance: item_local_relevance,
              item_freshness: item_freshness,
              item_source_quality: item_source_quality,
              item_engagement: item_engagement,
              item_source: item_source
            )
          else
            candidates[key] = build_candidate(
              item, key: key, subquery_label: subquery_label,
              source_name: source_name, rank: rank, rrf_contrib: rrf_contrib,
              item_local_relevance: item_local_relevance,
              item_freshness: item_freshness,
              item_source_quality: item_source_quality,
              item_engagement: item_engagement,
              item_source: item_source
            )
            seen_source_items[key] = Set.new(
              ["#{item_source_value(item)}|#{item_id_value(item)}"]
            )
          end
        end
      end

      sorted = candidates.values.sort_by { |c| sort_key(c) }
      capped = apply_per_author_cap(sorted)
      diversify_pool(capped, pool_limit)
    end

    # ---- chaves e normalização ----

    def self.candidate_key(item)
      url = fetch_val(item, "url")
      return normalize_url(url) if url && !url.to_s.strip.empty?

      "#{item_source_value(item)}:#{item_id_value(item)}"
    end

    def self.normalize_url(url)
      s = url.to_s.strip.downcase
      return s if s.empty?

      # Percent-encode antes de parsear: URI.parse rejeita não-ASCII
      # (InvalidURIError) e o rescue devolvia a string crua SEM strip de
      # www/utm/chomp — o dedupe.py trata Unicode. Sem o encode, URLs com
      # acentos ou CJK escapa do método inteiro.
      encoded = URI::DEFAULT_PARSER.escape(s)
      parsed = URI.parse(encoded)
      netloc = parsed.host.to_s
      %w[www. old. m.].each do |prefix|
        netloc = netloc[prefix.length..] if netloc.start_with?(prefix)
      end

      raw_query = parsed.query.to_s
      params = raw_query.empty? ? [] : URI.decode_www_form(raw_query)
      # S2: parse_qs do Python descarta keep_blank_values=False. Manter
      # param com valor vazio aqui produziria dedup errado ("?flag=&id=1"
      # vs "?id=1" virariam chaves diferentes).
      clean_params = params.reject { |k, v| k.to_s.start_with?("utm_") || v.to_s.empty? }
      query = clean_params.empty? ? "" : URI.encode_www_form(clean_params)

      path = parsed.path.to_s.chomp("/")

      rebuild = +""
      rebuild << parsed.scheme << "://" if parsed.scheme
      rebuild << netloc
      rebuild << ":#{parsed.port}" if parsed.port && parsed.port != parsed.default_port
      rebuild << path unless path.empty?
      rebuild << "?" << query unless query.empty?
      rebuild
    rescue URI::Error, ArgumentError
      s
    end

    # ---- extração de campos por item ----

    def self.extract_local_relevance(item)
      # IMPORTANTE (A1): o Research::Scorer.sort grava o score do scorer em
      # `relevance_score` (ver lib/research/scorer.rb:80). Sem ler esse campo
      # aqui, candidatos pós-sort chegam com relevance_score preenchido mas
      # local_relevance = 0.0, e o Cluster (que usa local_relevance como
      # score de TRABALHO — líder, MMR, thin-evidence) degenera: uncertainty
      # vira "thin-evidence" para todo mundo e MMR pune a diversidade muito
      # mais que a relevância.
      #
      # Prioridade: local_relevance > relevance_score > metadata.local_relevance > relevance_hint.
      v = fetch_val(item, "local_relevance")
      return v.to_f if v
      v = fetch_val(item, "relevance_score")
      return v.to_f if v
      v = fetch_val_nested(item, %w[metadata local_relevance])
      return v.to_f if v
      v = fetch_val(item, "relevance_hint")
      return v.to_f if v

      0.0
    end

    def self.extract_freshness(item)
      v = fetch_val(item, "freshness")
      return v.to_f if v
      v = fetch_val_nested(item, %w[metadata freshness])
      return v.to_f if v

      published_at = fetch_val(item, "published_at") ||
                      fetch_val(item, "created_at") ||
                      fetch_val_nested(item, %w[metadata published_at]) ||
                      fetch_val_nested(item, %w[metadata created_at])
      Signals.freshness(published_at).to_f
    end

    def self.extract_source_quality(item)
      v = fetch_val(item, "source_quality")
      return v.to_f if v
      v = fetch_val_nested(item, %w[metadata source_quality])
      return v.to_f if v

      Signals.source_quality(item_source_value(item)).to_f
    end

    def self.extract_engagement(item)
      # A8: `engagement` é o campo HASH que o Signals.engagement_raw espera
      # (ver signals.rb:64-65). Se devolvêssemos cru, um item com
      # "engagement" => {"score"=>.., "num_comments"=>..} cairia duas vezes
      # em streams diferentes e o merge_into_existing tentaria
      # `[hash.to_f, hash.to_f].max` -> NoMethodError. Aceitar APENAS
      # numérico aqui; hash/array/outros viram nil e o merge cai no ramo
      # "primeiro que aparecer".
      v = fetch_val(item, "engagement")
      return v.to_f if v.is_a?(Numeric)
      v = fetch_val(item, "engagement_score")
      return v.to_f if v.is_a?(Numeric)
      v = fetch_val_nested(item, %w[metadata engagement])
      return v.to_f if v.is_a?(Numeric)
      fetch_val_nested(item, %w[metadata engagement_score]).then { |x| x.is_a?(Numeric) ? x.to_f : nil }
    end

    def self.extract_snippet(item)
      fetch_val(item, "snippet") || fetch_val(item, "text") || fetch_val(item, "content") || ""
    end

    def self.extract_title(item)
      fetch_val(item, "title").to_s
    end

    def self.extract_url(item)
      fetch_val(item, "url").to_s
    end

    def self.extract_author(item)
      a = fetch_val(item, "author")
      return nil if a.nil?

      a.to_s.empty? ? nil : a
    end

    def self.item_source_value(item)
      s = fetch_val(item, "source") || fetch_val_nested(item, %w[metadata source])
      s.to_s
    end

    def self.item_id_value(item)
      v = fetch_val(item, "item_id")
      return v.to_s if v

      fetch_val_nested(item, %w[metadata item_id]).to_s
    end

    # ---- construção / merge de candidato ----

    def self.build_candidate(item, key:, subquery_label:, source_name:, rank:,
                             rrf_contrib:, item_local_relevance:,
                             item_freshness:, item_source_quality:,
                             item_engagement:, item_source:)
      src = item_source
      {
        "key" => key,
        "title" => extract_title(item),
        "url" => extract_url(item),
        "snippet" => extract_snippet(item),
        "source" => src, # A9: escalar atualizado no merge para refletir a fonte do item "vencedor"
        "sources" => [src].reject { |s| s.empty? },
        "source_items" => [item],
        "local_relevance" => item_local_relevance.to_f,
        "freshness" => item_freshness.to_f,
        "source_quality" => item_source_quality.to_f,
        "engagement" => item_engagement,
        "rrf_score" => rrf_contrib.to_f,
        "author" => extract_author(item),
        "provenance" => [
          {
            "source" => source_name,
            "subquery_label" => subquery_label,
            "native_rank" => rank,
            "item_id" => item_id_value(item)
          }
        ]
      }
    end

    def self.merge_into_existing(candidate, seen_pairs, item, subquery_label:,
                                 source_name:, rank:, rrf_contrib:,
                                 item_local_relevance:, item_freshness:,
                                 item_source_quality:, item_engagement:,
                                 item_source:)
      candidate["rrf_score"] = (candidate["rrf_score"] || 0.0) + rrf_contrib.to_f

      prev_primary = primary_score(
        candidate["local_relevance"], candidate["freshness"],
        candidate["source_quality"]
      )
      inc_primary = primary_score(item_local_relevance, item_freshness, item_source_quality)

      candidate["local_relevance"] = [candidate["local_relevance"].to_f, item_local_relevance.to_f].max
      candidate["freshness"] = [candidate["freshness"].to_f, item_freshness.to_f].max
      candidate["source_quality"] = [candidate["source_quality"].to_f, item_source_quality.to_f].max

      # A8: engagement agora é garantidamente Float ou nil; merge por max
      # é seguro (no código antigo, hash aqui quebrava com NoMethodError).
      if candidate["engagement"].nil?
        candidate["engagement"] = item_engagement
      elsif !item_engagement.nil?
        candidate["engagement"] = [candidate["engagement"].to_f, item_engagement.to_f].max
      end

      provenance = candidate["provenance"] ||= []
      provenance << {
        "source" => source_name,
        "subquery_label" => subquery_label,
        "native_rank" => rank,
        "item_id" => item_id_value(item)
      }

      src = item_source
      sources = candidate["sources"] ||= []
      sources << src unless sources.include?(src) || src.empty?

      item_pair = "#{src}|#{item_id_value(item)}"
      unless seen_pairs.include?(item_pair)
        seen_pairs << item_pair
        (candidate["source_items"] ||= []) << item
      end

      # Author: pega o primeiro item que tiver author (espelha a referência).
      if candidate["author"].nil?
        candidate["author"] = extract_author(item)
      end

      # Melhor item (maior score primário) vence para title/url; empate mantém o
      # anterior (== não troca).
      if inc_primary > prev_primary
        candidate["title"] = extract_title(item)
        candidate["url"] = extract_url(item)
        # A9: o "source" escalar segue o vencedor (espelha a referência
        # que usa `c.source = src` quando `inc_primary > prev_primary`).
        candidate["source"] = src unless src.empty?
      end

      # Snippet: sempre o mais longo (mesmo se o item não "venceu" o score
      # primário — espelha as linhas 202-203 da referência).
      if snippet_word_count(item) > snippet_word_count_from(candidate["snippet"])
        candidate["snippet"] = extract_snippet(item)
      end
    end

    def self.primary_score(local_relevance, freshness, source_quality)
      # A4: freshness é 0-1 em Signals.freshness, mas o termo de frescor do
      # primary_score precisa estar na MESMA escala de local_relevance (0-100,
      # vindo de *100) para fazer diferença no desempate de "qual item vence
      # title/url". Sem o *100 o frescor era ~0,5 num cálculo que vai até ~100
      # e o desempate temporal sumia. (A referência soma freshness já em 0-100.)
      (local_relevance.to_f * 100.0) + (freshness.to_f * 100.0) + (source_quality.to_f * 10.0)
    end

    def self.snippet_word_count(item)
      snippet_word_count_from(extract_snippet(item))
    end

    def self.snippet_word_count_from(snippet)
      return 0 if snippet.nil?

      snippet.to_s.split.size
    end

    # ---- sort e cap por autor ----

    def self.sort_key(candidate)
      # A6: empate de rrf é comum (todo rank-1 de 1 stream dá 1/61). Sem a
      # chave de desempate por key, sort_by do Ruby repete ordem de inserção
      # e o mesmo input pode sair em ordens diferentes. Por simetria com a
      # correção no Cluster, `candidate["key"]` é a última chave.
      [
        -candidate["rrf_score"].to_f,
        -candidate["local_relevance"].to_f,
        -candidate["freshness"].to_f,
        source_label_for_sort(candidate),
        candidate["title"].to_s,
        candidate["key"].to_s
      ]
    end

    def self.source_label_for_sort(candidate)
      # A9: prioriza o source escalar (atualizado no merge quando o item
      # vence) sobre o primeiro item de "sources" (congelado no build).
      s = candidate["source"]
      return s.to_s if s && !s.to_s.empty?

      sources = candidate["sources"] || []
      sources.first.to_s
    end

    def self.extract_author_from_candidate(candidate)
      items = candidate["source_items"] || []
      items.each do |it|
        a = extract_author(it)
        return a if a
      end
      candidate["author"]
    end

    def self.normalize_author(author)
      return nil if author.nil?

      a = author.to_s.strip.downcase
      a.empty? ? nil : a
    end

    def self.apply_per_author_cap(candidates, max_per_author: MAX_ITEMS_PER_AUTHOR)
      author_counts = {}
      result = []
      candidates.each do |c|
        author = normalize_author(extract_author_from_candidate(c))
        if author.nil?
          result << c
          next
        end
        count = author_counts[author] || 0
        if count < max_per_author
          result << c
          author_counts[author] = count + 1
        end
      end
      result
    end

    # ---- diversidade por fonte ----

    def self.diversify_pool(fused, pool_limit, min_per_source: 2)
      return fused.first(pool_limit) if fused.size <= pool_limit

      max_relevance = {}
      fused.each do |c|
        src = source_label_for_sort(c)
        next if src.empty?

        rel = c["local_relevance"].to_f
        if rel > (max_relevance[src] || 0.0)
          max_relevance[src] = rel
        end
      end

      reserved = {}
      remainder = []
      fused.each do |c|
        src = source_label_for_sort(c)
        bucket = reserved[src] ||= []
        if !src.empty? &&
           max_relevance[src].to_f >= DIVERSITY_RELEVANCE_THRESHOLD &&
           bucket.size < min_per_source
          bucket << c
        else
          remainder << c
        end
      end

      pool = reserved.values.flatten
      seen = pool.map { |c| c["key"] }.to_set
      remainder.each do |c|
        break if pool.size >= pool_limit
        next if seen.include?(c["key"])

        pool << c
        seen << c["key"]
      end

      pool.sort_by { |c| sort_key(c) }.first(pool_limit)
    end

    # ---- helpers de leitura ----

    def self.fetch_val(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key.to_s] || hash[key.to_sym]
    end

    def self.fetch_val_nested(hash, keys)
      curr = hash
      keys.each do |k|
        return nil unless curr.is_a?(Hash)

        curr = fetch_val(curr, k)
      end
      curr
    end

    def self.split_stream_key(stream_key)
      idx = stream_key.rindex(":")
      # S3: sem ":" a referência trata a chave inteira como source. A
      # versão antiga devolvia [stream_key, ""], gravando source "" no
      # provenance. Invertido: ["", stream_key].
      return ["", stream_key] if idx.nil?

      [stream_key[0...idx], stream_key[(idx + 1)..]]
    end
  end
end
