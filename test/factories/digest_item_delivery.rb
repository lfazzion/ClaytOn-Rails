# frozen_string_literal: true

FactoryBot.define do
  factory :digest_item_delivery do
    digest_type { 'friday_ideation' }
    channel_id { 'canal_teste' }
    item_type { DigestItemDelivery::ITEM_TYPE_CATALOG }
    sequence(:item_key) { |n| "anilist:10000#{n}" }
    sent_at { Time.current }
  end
end
