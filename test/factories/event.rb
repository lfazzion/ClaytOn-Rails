FactoryBot.define do
  factory :event do
    title { Faker::Lorem.words(number: 3).join(" ").titleize }
    description { Faker::Lorem.paragraph }
    source { "rss" }
    source_url { Faker::Internet.url }
    location { %w[São-Paulo São-Bernardo Rio-de-Janeiro].sample }
    start_date { Faker::Date.forward(days: 90) }
    end_date { start_date + Faker::Number.between(from: 1, to: 10).days }
    event_type { %w[bgs ccxp anime_friends other].sample }
    image_url { Faker::Internet.url(path: "/event.jpg") }
    organizer { Faker::Company.name }

    trait :bgs do
      event_type { "bgs" }
      title { "Brasil Game Show #{Date.current.year}" }
    end

    trait :ccxp do
      event_type { "ccxp" }
      title { "CCXP #{Date.current.year}" }
    end

    trait :upcoming do
      start_date { Faker::Date.forward(days: 60) }
      end_date { start_date + Faker::Number.between(from: 1, to: 10).days }
    end

    trait :past do
      end_date { Faker::Date.backward(days: 5) }
      start_date { end_date - Faker::Number.between(from: 1, to: 10).days }
    end
  end
end
