# frozen_string_literal: true

# Uma fala persistida. `content` é literal e nunca é reescrito — a compactação
# só produz resumo em outro campo, jamais altera o que a pessoa escreveu.
# Tool calls não são persistidos: reidratá-los sem os resultados originais quebra
# o protocolo do provedor.
class ChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze

  # Rótulos que o próprio sistema usa para se referir a papéis dentro do prompt
  # (ver config/prompts/partials/_multi_user.yml, que promete ao modelo que
  # `<autor>:` é metadado confiável). Um discord_username que colida com um
  # destes — em qualquer caixa, com espaço nas bordas — se passaria pelo papel.
  RESERVED_DISPLAY_NAMES = %w[assistente assistant usuario usuário system sistema].freeze
  DISPLAY_NAME_FALLBACK = "convidado"
  DISPLAY_NAME_LIMIT = 40

  belongs_to :conversation

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :content, presence: true
  validates :discord_user_id, presence: true, if: :user?

  scope :for_llm, -> { order(:id) }

  def user?
    role == "user"
  end

  def assistant?
    role == "assistant"
  end

  # Sobrescreve o reader gerado pelo ActiveRecord para saneá-lo NA LEITURA, não
  # na escrita: o dado bruto continua persistido (é o que o Discord de fato
  # mandou), mas todo consumidor do atributo — este model e também
  # ConversationCompactor#transcript/#fallback_summary, que leem
  # `message.discord_username` diretamente — passa a enxergar só a versão sem
  # personificação, inclusive para linhas já gravadas antes deste conserto.
  #
  # Isto é defesa contra PERSONIFICAÇÃO/INJEÇÃO pelo carimbo `<autor>:` (nome de
  # exibição do Discord é escolhido livremente por quem fala e chega sem
  # sanitização nenhuma), não formatação estética: remove `:` (evita um segundo
  # carimbo forjado na mesma linha), remove controle/quebra de linha (evita
  # forjar um turno inteiro), colapsa espaço, limita tamanho e neutraliza nomes
  # que colidem com os rótulos que o próprio sistema usa para os papéis.
  def discord_username
    sanitize_display_name(super)
  end

  # Carimbo mecânico de autor. Em sala compartilhada o modelo precisa saber quem
  # falou, e pedir que ele deduza não funciona: a acurácia medida de atribuição
  # em conversa multi-pessoa fica perto de 26%.
  def llm_content
    return content unless user? && conversation.shared && discord_username.present?

    "#{discord_username}: #{content}"
  end

  private

  def sanitize_display_name(raw_name)
    return raw_name if raw_name.blank?

    cleaned = raw_name.gsub(/[[:cntrl:]]/, "").delete(":").gsub(/\s+/, " ").strip
    return DISPLAY_NAME_FALLBACK if cleaned.blank?

    cleaned = cleaned[0, DISPLAY_NAME_LIMIT]
    RESERVED_DISPLAY_NAMES.include?(cleaned.downcase) ? DISPLAY_NAME_FALLBACK : cleaned
  end
end
