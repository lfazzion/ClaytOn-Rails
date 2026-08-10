# frozen_string_literal: true

FactoryBot.define do
  factory :topic do
    sequence(:name) { |n| "Tópico #{n}" }
    active { true }
  end
end
