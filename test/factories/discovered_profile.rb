FactoryBot.define do
  factory :discovered_profile do
    platform { %w[twitter instagram youtube].sample }
    # Username ÚNICO garantido (SecureRandom): a validação do modelo é
    # `platform, uniqueness: { scope: :username }` — Faker gera duplicatas em
    # create_list grande (ex.: 55 perfis, CI 13/08 — RecordInvalid flaky).
    username { SecureRandom.hex(4)[0, 8] }
    bio { Faker::Lorem.sentence }
    profile_url { "https://#{platform}.com/#{username}" }

    trait :classified do
      classification { DiscoveredProfile::CLASSIFICATIONS.sample }
      classification_reason { Faker::Lorem.sentence }
      classified_at { Time.current }
    end

    trait :concorrente do
      classification { 'CONCORRENTE' }
      classification_reason { 'Influenciador do mesmo nicho' }
      classified_at { Time.current }
    end

    trait :prospecto do
      classification { 'PATROCINADOR_PROSPECTO' }
      classification_reason { 'Marca relevante para parceria' }
      classified_at { Time.current }
    end

    trait :ignorado do
      classification { 'IGNORAR' }
      classification_reason { 'Bot ou spam' }
      classified_at { Time.current }
    end

    trait :stale do
      classification { 'IGNORAR' }
      classified_at { 10.days.ago }
    end
  end
end
