# frozen_string_literal: true

# Uma conversa do Discord. O escopo decide se ela é individual
# ("u:<user_id>:c:<channel_id>") ou compartilhada pela sala inteira ("c:<channel_id>").
# O índice parcial único garante no máximo uma ativa por escopo — a fronteira entre
# conversas é o comando /new, e não mais o TTL de 30 minutos.
class Conversation < ApplicationRecord
  TITLE_LIMIT = 80
  # F5a (30/08/2026) — teto de buscas web por conversa ativa do Discord
  # (plano-fase2 §D4). 5 buscas, 6ª = erro curto sugerindo `/new`. A fronteira
  # entre tetos é a própria row: `/new` cria outra row (default 0), não há
  # zerar manual. `MAX_WEB_SEARCH_PER_CONVERSATION` é a constante canônica
  # consultada tanto pelo `WebSearchTool` (gate) quanto pelos testes.
  MAX_WEB_SEARCH_PER_CONVERSATION = 5

  has_many :chat_messages, dependent: :destroy

  validates :scope, presence: true
  validates :discord_channel_id, presence: true

  # Desempate por id: dois registros podem cair no mesmo last_active_at (ex.:
  # /new fecha uma conversa e abre outra quase no mesmo instante), e sem
  # segundo critério a ordem de empate é indefinida no SQLite — /resume por
  # índice podia acertar conversas diferentes em chamadas consecutivas.
  scope :recent, -> { order(last_active_at: :desc, id: :desc) }

  class << self
    def active_for(scope)
      find_by(scope: scope, active: true)
    end

    # Idempotente. Duas mensagens simultâneas no canal compartilhado podem correr
    # aqui ao mesmo tempo; o índice parcial único converte a corrida em
    # RecordNotUnique, e a releitura devolve a conversa que venceu.
    def open_for(scope:, channel_id:, user_id: nil, shared: false)
      active_for(scope) || create!(
        scope: scope,
        discord_channel_id: channel_id,
        discord_user_id: user_id,
        shared: shared,
        active: true,
        last_active_at: Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      active_for(scope) || raise
    end
  end

  def assign_title_from(content)
    return if title.present?

    update!(title: content.to_s.strip[0, TITLE_LIMIT])
  end

  def touch_activity!
    update!(last_active_at: Time.current)
  end

  def close!
    update!(active: false)
  end
end
