# frozen_string_literal: true

require 'test_helper'

class DigestItemDeliveryTest < ActiveSupport::TestCase
  setup do
    @attrs = {
      digest_type: 'friday_ideation',
      channel_id: 'canal_teste',
      item_type: DigestItemDelivery::ITEM_TYPE_CATALOG,
      item_key: 'anilist:12345',
      sent_at: Time.current
    }
  end

  test 'unicidade composta (digest_type, channel_id, item_type, item_key) é recusada pelo índice único no banco' do
    DigestItemDelivery.create!(@attrs)

    duplicado = DigestItemDelivery.new(@attrs)

    # Prova pelo BANCO: o índice único existe no schema; `validate: false`
    # contorna qualquer validação de model e deixa o constraint do SQLite
    # recusar a linha duplicada (padrão da casa — post_snapshot_test.rb:42).
    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicado.save(validate: false)
    end
  end

  test 'mesma item_key em outro channel_id é permitida' do
    DigestItemDelivery.create!(@attrs)
    outro = DigestItemDelivery.new(@attrs.merge(channel_id: 'canal_outro'))
    assert outro.save
  end

  test 'mesma item_key em outro digest_type é permitida' do
    DigestItemDelivery.create!(@attrs)
    outro = DigestItemDelivery.new(@attrs.merge(digest_type: 'weekly_digest'))
    assert outro.save
  end

  test 'sent_item_keys devolve exatamente as chaves do par digest_type+channel_id e não vaza de outro canal/digest' do
    DigestItemDelivery.create!(@attrs.merge(item_key: 'anilist:AAA'))
    DigestItemDelivery.create!(@attrs.merge(item_key: 'anilist:BBB'))
    # Outro canal com a mesma item_key.
    DigestItemDelivery.create!(@attrs.merge(channel_id: 'canal_outro', item_key: 'anilist:CCC'))
    # Outro digest_type com a mesma item_key.
    DigestItemDelivery.create!(@attrs.merge(digest_type: 'weekly_digest', item_key: 'anilist:DDD'))

    chaves = DigestItemDelivery.sent_item_keys(
      digest_type: 'friday_ideation', channel_id: 'canal_teste'
    )

    assert_equal %w[anilist:AAA anilist:BBB].sort, chaves.sort
    refute_includes chaves, 'anilist:CCC' # outro canal não vaza
    refute_includes chaves, 'anilist:DDD' # outro digest_type não vaza
  end

  test 'sent_at persiste o valor informado' do
    momento = 5.days.ago.change(usec: 0)
    entrega = DigestItemDelivery.create!(@attrs.merge(sent_at: momento))
    entrega.reload
    assert_in_delta momento.to_f, entrega.sent_at.to_f, 1.0
  end
end