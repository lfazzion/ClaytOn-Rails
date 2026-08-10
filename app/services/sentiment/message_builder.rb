# frozen_string_literal: true

module Sentiment
  class MessageBuilder
    class << self
      def build(run, data)
        new(run, data).build
      end
    end

    def initialize(run, data)
      @run = run
      @data = data
      @spec = (data[:spec] || {}).with_indifferent_access
    end

    def build
      target_name = @spec[:name] || @run.sentiment_target&.name || "Alvo"
      bucket_type = @spec[:bucket] || "week"

      w_start = format_date(@run.window_start || @spec[:window_start])
      w_end = format_date(@run.window_end || @spec[:window_end])

      sources_str = Array(@spec[:sources].to_s.split(",")).map(&:strip).join(", ")
      model_info = if @run.snapshot_pinned
                     @run.model_id || "desconhecido"
                   else
                     distinct_models = @run.sentiment_labels.pluck(:model_id).compact.uniq
                     distinct_models = @run.model_id.to_s.split(",").map(&:strip).reject(&:empty?) if distinct_models.empty?
                     model_names = distinct_models.map { |m| short_model_name(m) }.join(", ").presence || "desconhecido"
                     "modelos usados: #{model_names}"
                   end

      lines = [
        "**Sentimento — #{target_name}** (#{w_start} a #{w_end}, bucket #{bucket_type})",
        "fontes: #{sources_str} · #{@data[:collected_count]} frases (#{@data[:rejected_count]} descartadas) · #{model_info} · temp 0",
        ""
      ]

      if @data[:sources_balance].present?
        lines << "**Saldo por fonte:**"
        @data[:sources_balance].each do |src, s_data|
          lines << "- **#{src}**: #{format_num(s_data[:balance])} (pos #{s_data[:positive]} · neu #{s_data[:neutral]} · neg #{s_data[:negative]})"
        end
        lines << ""
      end

      pb = @data[:period_balance] || {}
      lines << "**Saldo do período (agregado):** #{format_num(pb[:balance])} (pos #{pb[:positive] || 0} · neu #{pb[:neutral] || 0} · neg #{pb[:negative] || 0})"
      lines << ""

      curve = @data[:curve] || []
      if curve.any?
        lines << "**Curva (saldo por #{bucket_type}):**"
        lines << "```"
        curve.each do |c|
          lines << "  #{c[:date]} #{c[:sparkline]} #{format_num(c[:balance]).rjust(5)}  n=#{c[:n]}"
        end
        lines << "```"

        if @data[:max_delta_s].present?
          md = @data[:max_delta_s]
          lines << "maior variação: #{md[:from_date]} → #{md[:to_date]}, ΔS = #{format_num(md[:delta])}"
        end
        lines << ""
      end

      if @data[:insufficient_buckets].present?
        lines << "sem sinal (n<30): #{@data[:insufficient_buckets].join(', ')}"
        lines << ""
      end

      examples = @data[:examples] || {}
      if examples.values.any?(&:present?)
        lines << "**Exemplos por classe:**"
        if examples["positive"]
          ex = examples["positive"]
          link_str = ex[:permalink].present? ? " (<#{ex[:permalink]}>)" : ""
          lines << "- **Positivo**: \"#{ex[:text].to_s.truncate(120)}\"#{link_str}"
        end
        if examples["negative"]
          ex = examples["negative"]
          link_str = ex[:permalink].present? ? " (<#{ex[:permalink]}>)" : ""
          lines << "- **Negativo**: \"#{ex[:text].to_s.truncate(120)}\"#{link_str}"
        end
        if examples["neutral"]
          ex = examples["neutral"]
          link_str = ex[:permalink].present? ? " (<#{ex[:permalink]}>)" : ""
          lines << "- **Neutro**: \"#{ex[:text].to_s.truncate(120)}\"#{link_str}"
        end
        lines << ""
      end

      tara_str = @data[:tara].present? ? "#{(@data[:tara] * 100).round}%" : "não executado nesta rodada"
      insufficient_count = Array(@data[:insufficient_buckets]).size

      lines << "**Confiança & Diagnóstico:**"
      lines << "1. 3-way sentiment tem teto medido de ~75% em frases curtas (benchmark en — otimista para pt-BR); isto é estimativa, não oráculo."
      lines << "2. Estabilidade nesta rodada (TARa): #{tara_str}."
      lines << "3. #{@data[:unparsed_count]} frases sem classificação (JSON inválido após retry)."
      lines << "4. #{@data[:sem_data_count]} frases sem data (fora da curva, no saldo do período)."
      lines << "5. #{insufficient_count} buckets ignorados por volume (n<30)."

      lines.join("\n")
    end

    private

    def short_model_name(m_id)
      case m_id.to_s
      when /gemma/i then "gemma"
      when /nemotron/i then "nemotron"
      when /openrouter/i then "openrouter"
      when /hy3|nous/i then "nous"
      else m_id.to_s.split("/").last
      end
    end

    def format_date(dt)
      return "—" if dt.blank?

      Time.parse(dt.to_s).strftime("%d/%m/%Y")
    rescue StandardError
      dt.to_s
    end

    def format_num(val)
      return "0.00" if val.nil?

      v = val.to_f
      sprintf("%+.2f", v)
    end
  end
end
