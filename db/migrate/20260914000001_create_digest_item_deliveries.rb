# frozen_string_literal: true
#
# C2a (campanha 1409, veredito perito seção C2 — S2-01/S2-04): estado de
# envio de itens de digest em tabela PRÓPRIA, não em ExternalCatalog.
#
# Chave de supressão: (digest_type, channel_id, item_type, item_key) — um
# item enviado num canal/outro digest_type NÃO inibe o envio em outro.
# sent_at fecha a janela de recência (item só pode ser reenviado após X dias
# de recência, nunca enquanto está "novo" para o canal).

class CreateDigestItemDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :digest_item_deliveries do |t|
      t.string :digest_type, null: false
      t.string :channel_id, null: false
      t.string :item_type, null: false
      t.string :item_key, null: false
      t.datetime :sent_at, null: false
    end

    # Idempotência de envio: o mesmo item não é reenviado para o mesmo
    # digest_type + canal enquanto a janela de recência está em curso.
    add_index :digest_item_deliveries,
              [:digest_type, :channel_id, :item_type, :item_key],
              unique: true,
              name: 'index_digest_item_deliveries_unique_key'
    # Janela de recência / varredura de "últimos N dias enviados para este canal".
    add_index :digest_item_deliveries, [:digest_type, :channel_id, :sent_at],
              name: 'index_digest_item_deliveries_on_sent_at'
  end
end
