# frozen_string_literal: true
#
# Estado de envio de itens de digest (C2a — veredito perito seção C2,
# S2-01/S2-04). Marca QUEM recebeu QUE, quando: um item de catálogo
# entregue pelo digest X para o canal Y.
#
# Vive aqui (não em ExternalCatalog) porque:
#  - a supressão é por (digest_type, channel_id): o mesmo item pode voltar
#    para OUTRO canal ou para OUTRO digest;
#  - ExternalCatalog é domínio de catálogo (dados da fonte); entrega é
#    estado operacional do digest — misturar os dois contamina a fonte.
#
# Política de fallback declarada (C2a, documentada no job FridayIdeationJob):
# item entregue NUNCA repete no mesmo digest_type + channel_id (supressão
# indeterminada); a novidade entra por itens novos dentro da janela de
# recência (base 30d; se esgotada, 60d; se esgotada, 90d — teto).
# sent_at fica registrada para auditoria.
#
# Unicidade (digest_type, channel_id, item_type, item_key): envio
# idempotente — duas execuções concorrentes do mesmo digest+canal não
# duplicam a marca (a segunda criação é recusada pelo índice único).

class DigestItemDelivery < ApplicationRecord
  ITEM_TYPE_CATALOG = 'external_catalog'.freeze

  validates :digest_type, presence: true
  validates :channel_id, presence: true
  validates :item_type, presence: true
  validates :item_key, presence: true
  validates :sent_at, presence: true

  validates :item_key,
            uniqueness: {
              scope: %i[digest_type channel_id item_type],
              message: 'já foi enviado para este digest/canal (supressão indeterminada)'
            }

  # Registra o envio de um item. `item_key` é a chave estável do item
  # (ex.: "anilist:123" para ExternalCatalog — ver ExternalCatalog#key).
  def self.mark_sent!(digest_type:, channel_id:, item_type:, item_key:, sent_at: Time.current)
    create!(digest_type: digest_type,
            channel_id: channel_id.to_s,
            item_type: item_type,
            item_key: item_key.to_s,
            sent_at: sent_at)
  end

  # Chaves de itens JÁ enviados para este digest+canal (supressão da seleção).
  def self.sent_item_keys(digest_type:, channel_id:, item_type: ITEM_TYPE_CATALOG)
    where(digest_type: digest_type, channel_id: channel_id.to_s, item_type: item_type)
      .pluck(:item_key)
  end
end
