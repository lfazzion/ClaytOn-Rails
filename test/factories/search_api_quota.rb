# frozen_string_literal: true

FactoryBot.define do
  factory :search_api_quota do
    api_name { "linkup" }
    month { Time.current.in_time_zone("America/Sao_Paulo").strftime("%Y-%m") }
    count { 0 }
  end
end
