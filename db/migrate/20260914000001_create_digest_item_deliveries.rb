# frozen_string_literal: true
#
# C2a (campanha 1409, veredito perito seção C2 — S2-01/S2-04): estado de
# envio de itens de digest em tabela PRÓPRIA, não em ExternalCatalog.
#
# Chave de supressão: (digest_type, channel_id, item_type, item_key) — um
# item enviado num canal/outro digest_type/outro item_type NÃO inibe o envio
# em outro.
#
# A supressão é PERMANENTE por (digest_type, channel_id, item_type,
# item_key): nenhum lugar do código filtra por data
# (DigestItemDelivery.sent_item_keys não usa sent_at), então o item não é
# reenviado para o mesmo par. sent_at existe para auditoria/janela de
# recência futura — NÃO para liberar reenvio.

class CreateDigestItemDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :digest_item_deliveries do |t|
      t.string :digest_type, null: false
      t.string :channel_id, null: false
      t.string :item_type, null: false
      t.string :item_key, null: false
      t.datetime :sent_at, null: false

      t.timestamps
    end

    # Idempotência de envio: o mesmo item não é reenviado para o mesmo
    # digest_type + canal (a chave inclui item_type). A supressão é
    # permanente — não há filtro por data liberando reenvio.
    add_index :digest_item_deliveries,
              [:digest_type, :channel_id, :item_type, :item_key],
              unique: true,
              name: 'index_digest_item_deliveries_unique_key'
    # Varredura futura de "últimos N dias enviados para este canal"
    # (auditoria/janela de recência). Não libera reenvio — a supressão é
    # permanente pela chave acima.
    add_index :digest_item_deliveries, [:digest_type, :channel_id, :sent_at],
              name: 'index_digest_item_deliveries_on_sent_at'
  end
end
