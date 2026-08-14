FactoryBot.define do
  factory :social_profile do
    platform { %w[twitter instagram youtube tiktok].sample }
    # Username SEMPRE válido para a validação de Twitter ([A-Za-z0-9_]{1,15}):
    # Faker::Internet.username gera pontos/hífens e até 20 chars, quebrando
    # a validação adicionada na campanha laguna-fix (13/08).
    platform_username { SecureRandom.hex(4)[0, 8] }
    platform_user_id { Faker::Number.number(digits: 10) }
    display_name { Faker::Name.name }
    bio { Faker::Lorem.sentence }
    followers_count { Faker::Number.between(from: 100, to: 1_000_000) }
    following_count { Faker::Number.between(from: 50, to: 10_000) }
    verified { [true, false].sample }
    profile_url { "https://#{platform}.com/#{platform_username}" }
    avatar_url { nil }
    is_private { false }
    posts_count { 0 }

    trait :twitter do
      platform { "twitter" }
    end

    trait :instagram do
      platform { "instagram" }
    end

    trait :youtube do
      platform { "youtube" }
    end

    trait :tiktok do
      platform { "tiktok" }
    end

    trait :verified do
      verified { true }
    end

    trait :with_nil_metrics do
      followers_count { nil }
      following_count { nil }
    end
  end
end
