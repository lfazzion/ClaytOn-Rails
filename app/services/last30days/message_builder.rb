# frozen_string_literal: true

module Last30Days
  class MessageBuilder
    MAX_CLUSTERS = 8
    MAX_ITEMS_PER_CLUSTER = 3

    # Retorna { text: String, url_keys: Array<String> }
    # url_keys contém APENAS as keys dos itens que aparecem na mensagem gerada
    # (limitados por MAX_CLUSTERS × MAX_ITEMS_PER_CLUSTER), para que o job grave
    # só o que foi realmente exibido ao usuário (Achado 4).
    class << self
      def build(clusters:, topic_name:)
        c_list = Array(clusters)
        if c_list.empty?
          return { text: "nada encontrado nas fontes para #{topic_name}", url_keys: [] }
        end

        lines = ["**📌 Digest Last 30 Days — Tópico: #{topic_name}**", ""]
        rendered_url_keys = []

        # Achado 7: score recalculado dos itens EXIBIDOS — o "score" do cluster
        # original é o max pré-dedupe (lib/research/cluster.rb:255) e pode ter
        # contado com itens que o job removeu (dedupe). O sort usa esse score
        # recalculado; desempate pela ordem de entrada (já score-original desc,
        # vinda do Cluster).
        view = c_list.each_with_index.map do |cluster, ord|
          items = Array(cluster["items"]).first(MAX_ITEMS_PER_CLUSTER)
          { cluster: cluster, items: items, score: score_of_items(items), ord: ord }
        end
        sorted_clusters = view.sort_by { |v| [-v[:score], v[:ord]] }.first(MAX_CLUSTERS)

        sorted_clusters.each_with_index do |entry, idx|
          cluster = entry[:cluster]
          items = entry[:items]
          title = cluster["title"].to_s
          score = entry[:score].round(2)

          # Achado 7: sources e uncertainty recalculados a partir dos itens EXIBIDOS
          # (não do cluster original, que pode ter tido itens removidos pelo dedupe)
          effective_sources = sources_of_items(items)
          effective_uncertainty = uncertainty_for(items, entry[:score])

          sources_str = effective_sources.join(", ")
          uncertainty_tag = case effective_uncertainty.to_s
                            when "single-source" then " (⚠️ fonte única)"
                            when "thin-evidence" then " (⚠️ evidência fraca)"
                            else ""
                            end

          lines << "### #{idx + 1}. #{title} (score: #{score}, fontes: #{sources_str})#{uncertainty_tag}"

          items.each do |item|
            item_title = item["title"].to_s
            item_url = item["url"].to_s
            item_source = item["source"].to_s
            item_key = item["url"].presence || item["key"].to_s

            lines << "- [#{item_title}](#{item_url}) (fonte: #{item_source})"

            # Coleta a url_key normalizada do item renderizado (Achado 4)
            normalized = normalize_url_key(item_key)
            rendered_url_keys << normalized unless rendered_url_keys.include?(normalized)
          end

          lines << ""
        end

        { text: lines.join("\n").strip, url_keys: rendered_url_keys }
      end

      private

      def normalize_url_key(raw)
        Research::Fusion.normalize_url(raw)
      end

      # Achado 7: fontes de um item. Candidato fundido por N streams carrega
      # "sources" => [a, b]; o escalar "source" é só o vencedor do merge
      # (lib/research/fusion.rb:313-318). Preferir o array; fallback para o
      # escalar quando o item não passou por merge.
      def item_sources(item)
        srcs = Array(item["sources"]).map(&:to_s).reject(&:empty?)
        return srcs if srcs.any?

        scalar = item["source"].to_s
        scalar.empty? ? [] : [scalar]
      end

      def sources_of_items(items)
        items.flat_map { |i| item_sources(i) }.uniq
      end

      # Mesmo critério de trabalho do Cluster (lib/research/cluster.rb score_of):
      # "local_relevance" 0-1 (score real de trabalho); fallback "rrf_score".
      def score_of_item(item)
        v = item["local_relevance"]
        return v.to_f unless v.nil?

        v = item["rrf_score"]
        return 0.0 if v.nil?

        v.to_f
      end

      def score_of_items(items)
        items.map { |i| score_of_item(i) }.max || 0.0
      end

      # Mesma re-avaliação do Cluster.uncertainty_for (lib/research/cluster.rb:316-323):
      # 1 fonte => single-source; senão, se o score RECALCULADO ficou abaixo do
      # limiar usado pelo Cluster, vira thin-evidence (não apenas preservar o
      # uncertainty original — o dedupe pode ter removido o item de score alto).
      def uncertainty_for(items, score)
        return "single-source" if sources_of_items(items).size <= 1
        return "thin-evidence" if score < Research::Cluster::THIN_EVIDENCE_FLOOR

        nil
      end
    end
  end
end
