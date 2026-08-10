# frozen_string_literal: true

require "set"
require_relative "relevance"

module Research
  # Cluster (Fase 3)
  #
  # Recebe candidatos já ordenados por rrf_score desc (entregues pelo
  # Research::Fusion) e os agrupa por similaridade de texto (título + snippet).
  # Para cada grupo, escolhe representantes diversos via MMR (Maximal Marginal
  # Relevance) e classifica incerteza (single-source / thin-evidence).
  #
  # Contrato de entrada (cada candidato é um Hash com chaves String):
  #   "key"              => String única
  #   "title"            => String (pode ser nil/"" -> vira "")
  #   "url"              => String
  #   "snippet"          => String
  #   "source"           => String escalar (atualizado pelo Fusion quando o
  #                                   item vence o desempate; ver A9)
  #   "sources"          => Array<String>
  #   "local_relevance"  => Float 0-1  (score de TRABALHO do Cluster: líder,
  #                                       sort do grupo, MMR, thin-evidence)
  #   "freshness"        => Float 0-1
  #   "source_quality"   => Float
  #   "engagement"       => Float ou nil
  #   "rrf_score"        => Float (≈0.016 a 0.05; usado APENAS para ordenação
  #                                 do pool pelo Fusion; NÃO é o score do
  #                                 Cluster — ver score_of)
  #   "author"           => String ou nil
  #   "provenance"       => Array
  #
  # Contrato de saída (Array<Hash>, ordenado por "score" desc):
  #   "cluster_id"         => "cluster-N" (N = ordem 1-indexada, APÓS o sort por score)
  #   "title"              => título do líder
  #   "keys"               => Array<String> de keys do grupo (ordem por local_relevance desc)
  #   "representative_ids" => Array<String> (até 3, seleção MMR)
  #   "sources"            => Array<String> únicas e ordenadas (união)
  #   "score"              => Float = max(local_relevance) do grupo
  #   "uncertainty"        => "single-source" | "thin-evidence" | nil
  #   "items"              => Array<Hash> com os candidatos do grupo, ordenados por local_relevance desc
  #
  # NOTAS / SUPOSIÇÕES:
  #   - Merge cross-source por entidade (Fase 4) NÃO está incluído: ele depende
  #     de entity_extract, que ainda não existe no mapa. O comentário
  #     "merge cross-source por entidade fica para a Fase 4 (entity_extract)"
  #     marca o ponto onde o segundo pass do cluster.py seria plugado. Decidido
  #     com o delegado para a Fase 4 — ver docs/MEMORY.md (Fase 3).
  #   - ESCALA (A1): no Python o `final_score` é 0-100 e o Cluster usa esse
  #     valor para líder, MMR e thin-evidence. Aqui o Fusion emite
  #     `rrf_score = 1/(60+rank)` que dá no máximo ~0,0164 por stream — usar
  #     isso como score do Cluster degenera (uncertainty vira "thin-evidence"
  #     sempre; diversidade no MMR pesa ~10x mais que o score). Por isso o
  #     Cluster usa `local_relevance` (0-1, emitido pelo Scorer via
  #     relevance_score) como score de TRABALHO, e mantém rrf_score só para
  #     ordenação do pool (feita no Fusion) e como desempate. Ver score_of.
  #   - A entrada é tratada como JÁ ordenada por rrf_score desc (contrato do
  #     Fusion). Quem chama de fora com candidatos desordenados vai ter ordem
  #     de grupo indefinida. Documentado aqui, não validado em runtime para
  #     não adicionar custo.
  module Cluster
    CLUSTERABLE_INTENTS = %w[breaking_news opinion comparison prediction].freeze

    # Threshold do greedy. breaking_news recebe 0.42: artigos sobre o mesmo
    # evento costumam compartilhar menos palavras exatas (headlines sintetizam,
    # fontes diferentes usam angulação). Outros intents usam 0.48 para evitar
    # colapsar histórias que tangenciam o tema.
    THRESHOLD_BREAKING = 0.42
    THRESHOLD_DEFAULT = 0.48

    # MMR: balanceia score do candidato contra redundância com já-selecionados.
    MMR_LIMIT = 3
    MMR_DIVERSITY_LAMBDA = 0.75

    # Threshold de "thin-evidence" no cleitin (score 0-1). No Python é 55
    # porque final_score é 0-100; aqui a referência equivalente é 0.55.
    THIN_EVIDENCE_FLOOR = 0.55

    # Similaridade híbrida (ngrams + tokens). Implementada como submódulo
    # privado — não é exposta pela API pública. Outras camadas não devem
    # usá-la diretamente; se precisarem, copiem a chamada aqui. O Fusion
    # não a expõe (verificar lib/research/fusion.rb quando ele for escrito).
    module Similarity
      NGRAM_SIZE = 3

      class << self
        # API de conveniência: recebe strings brutas e devolve a
        # similaridade híbrida (max de ngram-jaccard e token-jaccard).
        # Internamente prepara o texto nas duas pontas. O caching entre
        # chamadas é responsabilidade do caller via prep_text (Cluster):
        # o cache local foi removido por ser código morto — ninguém chamava
        # de fora e o prep_text interno já implementa o mesmo padrão com
        # cache por grupo.
        def hybrid(text_a, text_b, stopwords = Research::Relevance::STOPWORDS)
          a = PreparedText.from_raw(text_a.to_s, stopwords)
          b = PreparedText.from_raw(text_b.to_s, stopwords)
          similarity(a, b)
        end

        def similarity(a, b)
          [
            jaccard(a.ngrams, b.ngrams),
            jaccard(a.tokens, b.tokens)
          ].max
        end

        def jaccard(left, right)
          return 0.0 if left.empty? || right.empty?

          inter = (left & right).size
          union = (left | right).size
          return 0.0 if union.zero?

          inter.to_f / union
        end

        # Tokenização estilo dedupe.py: split em palavras com len>1, sem
        # stopwords. Diferenças intencionais:
        #   - A5: usa POSIX [:word:] (Unicode-aware) em vez de [a-z0-9] ASCII
        #     para preservar acentos e CJK. O dedupe.py usa \w Unicode, então
        #     o fallback ASCII destruía "informação" -> "informa o" e
        #     histórias do mesmo evento (com e sem acento) não agrupavam.
        def tokenize(normalized, stopwords)
          normalized.split.reject { |tok| tok.length <= 1 || stopwords.include?(tok) }
        end

        # N-grams do texto normalizado. Se o texto for menor que n, devolve
        # o próprio texto como set unitário (espelha dedupe.py).
        def ngrams_of(normalized, n = NGRAM_SIZE)
          return Set.new if normalized.empty?
          return Set[normalized] if normalized.length < n

          (0..(normalized.length - n)).each_with_object(Set.new) do |i, acc|
            acc << normalized[i, n]
          end
        end

        def normalize(text)
          # A5: POSIX word (`\w` é [[:word:]] em Ruby) preserva letras
          # acentuadas e CJK; o regex ASCII antigo virava espaço em cada
          # caractere não-ASCII e quebrava tokens como "proteção" e
          # "informação". Mantém o split/double-space/strip.
          text.to_s.downcase.gsub(/[^[:word:]\s]/, " ").gsub(/\s+/, " ").strip
        end
      end

      # Pré-computado: ngrams (set) e tokens (set) do texto normalizado.
      # Imutável por contrato de uso: quem precisar de um novo prepara via
      # prep_text (Cluster), que faz o cache por grupo.
      PreparedText = Struct.new(:ngrams, :tokens) do
        def self.from_raw(raw, stopwords)
          norm = Similarity.normalize(raw)
          new(
            Similarity.ngrams_of(norm),
            Set.new(Similarity.tokenize(norm, stopwords))
          )
        end
      end
    end

    class << self
      # API pública. Ver doc do módulo.
      # @param candidates [Array<Hash>] formato contrato acima, ordenados por
      #   rrf_score desc.
      # @param intent [String] "breaking_news" | "opinion" | "comparison" |
      #   "prediction" | outro. Outros intents => 1 cluster por candidato.
      # @param cluster_mode [String, nil] "none" desliga o agrupamento
      #   (útil quando o caller já sabe que o intent não é clusterable).
      # @return [Array<Hash>] clusters (ver contrato de saída).
      def cluster(candidates, intent: "breaking_news", cluster_mode: nil)
        list = Array(candidates)
        return [] if list.empty?

        if !clusterable?(intent) || cluster_mode == "none"
          return identity_clusters(list)
        end

        groups = greedy_group(list, intent: intent)
        build_clusters(groups)
      end

      def clusterable?(intent)
        CLUSTERABLE_INTENTS.include?(intent.to_s)
      end

      private

      # Um cluster por candidato. Mesmo do cluster.py linhas 50-66.
      def identity_clusters(list)
        list.each_with_index.map do |cand, idx|
          {
            "cluster_id" => "cluster-#{idx + 1}",
            # A3: o caminho normal (build_clusters) usa só cand["title"] e a
            # referência (cluster.py:58) também. title_for (title+snippet)
            # colava o snippet no título e tornava "tutorial" e "tutorial
            # de hooks" visivelmente o mesmo — burro quando o caller optou
            # por não agrupar. Espelhamos o caminho não-clusterable aqui.
            "title" => cand["title"].to_s,
            "keys" => [cand["key"].to_s],
            "representative_ids" => [cand["key"].to_s],
            "sources" => sorted_sources(cand),
            "score" => score_of(cand),
            "uncertainty" => single_source_uncertainty(cand),
            "items" => [cand]
          }
        end
      end

      def greedy_group(list, intent:)
        threshold = threshold_for(intent)
        prep_cache = {}
        groups = []

        list.each do |cand|
          cand_prep = prep_text(cand, prep_cache)
          assigned = false
          groups.each do |group|
            leader = group.first
            leader_prep = prep_text(leader, prep_cache)
            sim = Similarity.similarity(cand_prep, leader_prep)
            if sim >= threshold
              group << cand
              assigned = true
              break
            end
          end
          groups << [cand] unless assigned
        end
        groups
      end

      def build_clusters(groups)
        # TODO Fase 4 (entity_extract): merge cross-source por entidade fica
        # para a Fase 4 (entity_extract). Aqui entra um segundo pass
        # equivalente a cluster.py::_merge_entity_clusters: pega clusters
        # com <= 3 itens e mesmo evento, funde os que compartilham
        # entidades (>= 1 ou >= 2 conforme "discover-mode" no plano)
        # e re-calcula representatives via MMR no pool combinado.
        # Mantido fora ate entity_extract existir no mapa.
        clusters = groups.each_with_index.map do |group, idx|
          # A6 + A1: ordena por local_relevance desc (A1) com tie-break por
          # key (A6) para idempotência. sort_by do Ruby não é estável; sem
          # a chave final, candidatos com mesmo local_relevance poderiam
          # alternar entre runs.
          sorted = group.sort_by { |c| [-score_of(c), c["key"].to_s] }
          rep_ids = mmr_representatives(sorted, group_prep_cache_for(sorted))
          all_sources = sorted.flat_map { |c| sources_of(c) }.uniq.sort
          max_score = sorted.map { |c| score_of(c) }.max || 0.0
          {
            "cluster_id" => "cluster-#{idx + 1}",
            "title" => sorted.first["title"].to_s,
            "keys" => sorted.map { |c| c["key"].to_s },
            "representative_ids" => rep_ids,
            "sources" => all_sources,
            "score" => max_score,
            "uncertainty" => uncertainty_for(sorted),
            "items" => sorted
          }
        end
        # A6: idem para o sort final dos clusters por score (não-idempotente
        # em caso de empate de score). Mantém o líder global como cluster-1.
        clusters.sort_by { |cl| [-cl["score"], cl["keys"].first.to_s] }.each_with_index.map do |cl, idx|
          # Reatribui cluster_id pelo ranking final (líder global = cluster-1),
          # espelhando o sort final do cluster.py.
          cl.merge("cluster_id" => "cluster-#{idx + 1}")
        end
      end

      # MMR: primeiro o melhor score, depois maximiza
      #   lambda * score - (1 - lambda) * max_sim(selected).
      # ESCALA: `score` aqui é local_relevance 0-1 (ver score_of) e o
      # diversity_penalty é a similarity crua (0-1) — duas grandezas na
      # mesma escala. A fórmula com score 0-100 e penalty 0-1 daria peso
      # efetivo 100× maior para a penalidade; por isso a porta usa score
      # 0-1 e o diversity_lambda 0.75. Ver doc do módulo.
      def mmr_representatives(sorted_group, prep_cache = {})
        return [] if sorted_group.empty?

        selected = []
        remaining = sorted_group.dup

        while remaining.any? && selected.size < MMR_LIMIT
          if selected.empty?
            # R1 (revisão R2): primeiro representante = MESMO critério do
            # líder que dá o título (sort do grupo: score desc, key asc).
            best = remaining.sort_by { |c| [-score_of(c), c["key"].to_s] }.first
            selected << best
            remaining.delete(best)
            next
          end

          # A10: usa o cache passado (group_prep_cache_for do build_clusters)
          # em vez de {{}} novo a cada laço. selected_preps são fixos dentro
          # do laço externo; cand_preps são cacheados entre laços.
          selected_preps = selected.map { |c| prep_text(c, prep_cache) }
          best = nil
          best_val = -Float::INFINITY
          remaining.each do |cand|
            cand_prep = prep_text(cand, prep_cache)
            max_sim = selected_preps.map { |sp| Similarity.similarity(cand_prep, sp) }.max || 0.0
            mmr_val = (MMR_DIVERSITY_LAMBDA * score_of(cand)) - ((1.0 - MMR_DIVERSITY_LAMBDA) * max_sim)
            if mmr_val > best_val || (mmr_val == best_val && best && cand["key"].to_s < best["key"].to_s)
              best_val = mmr_val
              best = cand
            end
          end
          break unless best

          selected << best
          remaining.delete(best)
        end

        selected.map { |c| c["key"].to_s }
      end

      def uncertainty_for(group)
        return "single-source" if group.flat_map { |c| sources_of(c) }.uniq.size <= 1

        max_score = group.map { |c| score_of(c) }.max || 0.0
        return "thin-evidence" if max_score < THIN_EVIDENCE_FLOOR

        nil
      end

      def single_source_uncertainty(cand)
        sources_of(cand).size <= 1 ? "single-source" : nil
      end

      def threshold_for(intent)
        intent.to_s == "breaking_news" ? THRESHOLD_BREAKING : THRESHOLD_DEFAULT
      end

      # Texto usado para similaridade: title + (snippet | text | content).
      # Espelha _candidate_text do cluster.py + item_text do dedupe.py
      # (a referência usa title + snippet; "text"/"content" são extensões
      # defensivas para o formato do cleitin, onde algumas fontes entregam
      # o campo com nome diferente).
      def text_for(cand)
        parts = [cand["title"], cand["snippet"] || cand["text"] || cand["content"]]
        parts.compact_blank.join(" ").to_s.strip
      end

      def prep_text(cand, cache)
        # A10: usa o cache (passado por greedy_group e por
        # mmr_representatives). Antes o cache era ignorado — cada chamada
        # recomputava o PreparedText e o cache morto do `prep_cache = {}`
        # virava lixo. A chave é o texto normalizado de text_for.
        key = text_for(cand)
        cache[key] ||= Similarity::PreparedText.from_raw(key, Relevance::STOPWORDS)
      end

      # A10: cache compartilhado entre o sort/MMR e o group. Mantido como
      # helper para deixar o build_clusters legível; mutuável (cache
      # local ao group).
      def group_prep_cache_for(group)
        cache = {}
        group.each { |c| prep_text(c, cache) }
        cache
      end

      def score_of(cand)
        # A1: o "score de trabalho" do Cluster é `local_relevance` 0-1
        # (vindo do Scorer.relevance_score). O `rrf_score` do Fusion é
        # ~0.016-0.05 e torna este método inútil para o regime operacional.
        # Fallback: rrf_score (NUNCA o inverso — manter invariante "se o
        # Scorer rodou, score_of = local_relevance").
        v = cand["local_relevance"]
        return v.to_f unless v.nil?

        v = cand["rrf_score"]
        return 0.0 if v.nil?

        v.to_f
      end

      def sources_of(cand)
        Array(cand["sources"]).map(&:to_s).reject(&:empty?).uniq
      end

      def sorted_sources(cand)
        sources_of(cand).sort
      end
    end
  end
end
