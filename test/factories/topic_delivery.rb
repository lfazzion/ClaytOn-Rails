# frozen_string_literal: true

FactoryBot.define do
  factory :topic_delivery do
    association :topic
    sequence(:url_key) { |n| "https://example.com/item-#{n}" }
    sent_at { Time.current }
  end
end
