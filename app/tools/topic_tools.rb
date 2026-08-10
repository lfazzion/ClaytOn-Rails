# frozen_string_literal: true

require_relative "profile_management_tools"

class TopicToolBase < ManagementToolBase
  private

  def format_topic(topic)
    {
      id: topic.id,
      name: topic.name,
      active: topic.active,
      created_at: topic.created_at
    }
  end
end

class TopicAddTool < TopicToolBase
  description "Adiciona um novo tópico à watchlist de digests."

  param :name, type: :string, desc: "Nome do tópico (2 a 100 caracteres)", required: true

  def run(name:)
    return owner_error unless owner?

    norm = name.to_s.squish.downcase
    if norm.length < 2 || norm.length > 100
      return error("Nome do tópico deve ter entre 2 e 100 caracteres")
    end

    existing = Topic.find_by(name: norm)
    if existing
      if existing.active?
        return { status: :already_exists, data: format_topic(existing) }
      else
        existing.update!(active: true)
        return { status: :reactivated, data: format_topic(existing) }
      end
    end

    topic = Topic.create!(name: norm, active: true)
    success(format_topic(topic))
  rescue ActiveRecord::RecordInvalid => e
    error("Erro ao salvar: #{e.record.errors.full_messages.join(', ')}")
  end
end

class TopicListTool < TopicToolBase
  description "Lista tópicos da watchlist de digests."

  param :limit, type: :integer, desc: "Limite de tópicos (padrão 50, máx 50)", required: false

  def run(limit: 50)
    return owner_error unless owner?

    lim = clamp(limit || 50, 1, 50)
    topics = Topic.order(created_at: :desc).limit(lim)
    success(topics.map { |t| format_topic(t) })
  end
end

class TopicRemoveTool < TopicToolBase
  description "Desativa (soft-delete) um tópico da watchlist de digests."

  param :name, type: :string, desc: "Nome do tópico a desativar", required: true

  def run(name:)
    return owner_error unless owner?

    norm = name.to_s.squish.downcase
    topic = Topic.find_by(name: norm)
    return error("Tópico não encontrado: #{name}") unless topic

    topic.update!(active: false)
    success(format_topic(topic))
  rescue ActiveRecord::RecordInvalid => e
    error("Erro ao salvar: #{e.record.errors.full_messages.join(', ')}")
  end
end
