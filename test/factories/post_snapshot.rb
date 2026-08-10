# frozen_string_literal: true

FactoryBot.define do
  factory :post_snapshot do
    association :social_post
    views_count { Faker::Number.between(from: 100, to: 100_000) }
    likes_count { Faker::Number.between(from: 10, to: 10_000) }
    comments_count { Faker::Number.between(from: 1, to: 500) }
    recorded_at { Time.current }
  end
end
