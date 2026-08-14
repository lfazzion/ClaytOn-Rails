# frozen_string_literal: true

require_relative "tool_base"
require_relative "profile_management_tools"

class CreateSentimentTargetTool < ManagementToolBase
  description "Cria ou atualiza um alvo para a análise de sentimento (owner-only)."

  param :name, type: :string, desc: "Nome único do alvo (ex: 'Cleitin', 'Bitcoin')", required: true
  param :query, type: :string, desc: "Termo ou frase de busca (ex: 'cleitin bot', 'bitcoin')", required: true
  param :sources, type: :string, desc: "Fontes separadas por vírgula (ex: 'reddit,x')", required: false
  param :window_days, type: :integer, desc: "Janela histórica de busca em dias (1-365, padrão 30)", required: false
  param :bucket, type: :string, desc: "Granularidade da curva: day ou week (padrão week)", required: false
  param :max_phrases, type: :integer, desc: "Teto de frases coletadas por rodada (10-2000, padrão 600)", required: false

  def run(name:, query:, sources: nil, window_days: nil, bucket: nil, max_phrases: nil)
    return owner_error unless owner?

    target_name = name.to_s.strip
    return error("Nome não pode ser vazio") if target_name.blank?

    target_query = query.to_s.strip
    return error("Query não pode ser vazia") if target_query.blank?

    srcs = (sources.presence || "reddit,x").to_s.split(",").map(&:strip).map(&:downcase).uniq
    invalid_srcs = srcs - %w[reddit x]
    if invalid_srcs.any?
      return error("Fontes inválidas: #{invalid_srcs.join(', ')}. Fontes aceitas: reddit, x")
    end

    bkt = (bucket.presence || "week").to_s.strip.downcase
    unless %w[day week].include?(bkt)
      return error("Bucket inválido: #{bucket}. Aceitos: day, week")
    end

    w_days = clamp(window_days || 30, 1, 365)
    m_phrases = clamp(max_phrases || 600, 10, 2000)

    target = SentimentTarget.find_or_initialize_by(name: target_name)
    target.assign_attributes(
      query: target_query,
      sources: srcs.join(","),
      window_days: w_days,
      bucket: bkt,
      max_phrases: m_phrases,
      active: true
    )
    target.save!

    success({
              id: target.id,
              name: target.name,
              query: target.query,
              sources: target.sources,
              window_days: target.window_days,
              bucket: target.bucket,
              max_phrases: target.max_phrases,
              active: target.active
            })
  rescue ActiveRecord::RecordInvalid => e
    error("Erro ao salvar alvo: #{e.record.errors.full_messages.join(', ')}")
  end
end

class RunSentimentAnalysisTool < ManagementToolBase
  description "Dispara a execução do pipeline de análise de sentimento para um alvo (owner-only)."

  param :target_identifier, type: :string, desc: "ID numérico ou nome do alvo", required: true
  param :run_id, type: :integer, desc: "ID opcional de uma rodada anterior para retry/retomada", required: false
  param :async, type: :boolean, desc: "Se true, enfileira o job em background; se false, roda síncrono (padrão true)", required: false

  def run(target_identifier:, run_id: nil, async: true)
    return owner_error unless owner?

    target = find_target(target_identifier)
    return error("Alvo não encontrado: #{target_identifier}") if target.nil?

    r_id = run_id.presence&.to_i
    if r_id
      found_run = SentimentRun.find_by(id: r_id)
      return error("Run não encontrado: #{r_id}") if found_run.nil?
      if found_run.target_id != target.id
        return error("Run ##{r_id} pertence ao alvo ##{found_run.target_id}, não ao alvo ##{target.id} (#{target.name})")
      end
    end

    if async
      if r_id
        SentimentAnalysisJob.perform_later(target.id, r_id)
        success({ target_id: target.id, name: target.name, run_id: r_id, status: "enqueued" })
      else
        SentimentAnalysisJob.perform_later(target.id)
        success({ target_id: target.id, name: target.name, status: "enqueued" })
      end
    else
      job = SentimentAnalysisJob.new
      run_record = r_id ? job.perform(target.id, r_id) : job.perform(target.id)
      success({ target_id: target.id, name: target.name, run_id: run_record&.id, status: run_record&.status })
    end
  rescue StandardError => e
    error("Falha ao disparar análise de sentimento: #{e.message}")
  end

  private

  def find_target(id_or_name)
    str = id_or_name.to_s.strip
    if str =~ /\A\d+\z/
      t = SentimentTarget.find_by(id: str.to_i)
      return t if t
    end

    SentimentTarget.find_by("LOWER(name) = ?", str.downcase)
  end
end

class SentimentStatusTool < ManagementToolBase
  description "Consulta o status e histórico de execuções de um alvo de sentimento (owner-only)."

  param :target_identifier, type: :string, desc: "ID numérico ou nome do alvo", required: true

  def run(target_identifier:)
    return owner_error unless owner?

    target = find_target(target_identifier)
    return error("Alvo não encontrado: #{target_identifier}") if target.nil?

    runs = target.sentiment_runs.order(created_at: :desc).limit(5).map do |r|
      {
        id: r.id,
        status: r.status,
        collected_count: r.collected_count,
        classified_count: r.classified_count,
        unparsed_count: r.unparsed_count,
        model_id: r.model_id,
        started_at: r.started_at,
        finished_at: r.finished_at,
        error: r.error
      }
    end

    success({
              target_id: target.id,
              name: target.name,
              query: target.query,
              sources: target.sources,
              bucket: target.bucket,
              runs: runs
            })
  end

  private

  def find_target(id_or_name)
    str = id_or_name.to_s.strip
    if str =~ /\A\d+\z/
      t = SentimentTarget.find_by(id: str.to_i)
      return t if t
    end

    SentimentTarget.find_by("LOWER(name) = ?", str.downcase)
  end
end
