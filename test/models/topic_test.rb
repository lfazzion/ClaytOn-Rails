# frozen_string_literal: true

require "test_helper"

class TopicTest < ActiveSupport::TestCase
  test "valida presença e tamanho do nome" do
    invalid_short = Topic.new(name: "a")
    assert_not invalid_short.valid?
    assert_includes invalid_short.errors[:name], "is too short (minimum is 2 characters)"

    invalid_long = Topic.new(name: "a" * 101)
    assert_not invalid_long.valid?

    invalid_blank = Topic.new(name: "   ")
    assert_not invalid_blank.valid?
  end

  test "normaliza o nome antes da validação (strip, downcase, compacta espaços)" do
    topic = Topic.create!(name: "  AI   Agents  ")
    assert_equal "ai agents", topic.name
  end

  test "valida unicidade do nome normalizado" do
    Topic.create!(name: "ai agents")
    duplicate = Topic.new(name: "  AI   Agents  ")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "valida teto de 15 tópicos ativos" do
    15.times do |i|
      Topic.create!(name: "topico #{i}", active: true)
    end

    sixteenth = Topic.new(name: "topico 16", active: true)
    assert_not sixteenth.valid?
    assert_includes sixteenth.errors[:base], "Limite máximo de 15 tópicos ativos atingido"

    # Criar um inativo quando já existem 15 ativos DEVE ser permitido
    inactive = Topic.create!(name: "topico inativo", active: false)
    assert inactive.persisted?

    # Tentar reativar o inativo quando já existem 15 ativos DEVE falhar
    inactive.active = true
    assert_not inactive.valid?
    assert_includes inactive.errors[:base], "Limite máximo de 15 tópicos ativos atingido"
  end

  test "permite atualizar nome de tópico ativo existente mesmo se houver 15 ativos" do
    topics = 15.times.map do |i|
      Topic.create!(name: "topico #{i}", active: true)
    end

    first_topic = topics.first
    first_topic.name = "topico 0 renomeado"
    assert first_topic.valid?
    assert first_topic.save
  end

  test "destrói topic_deliveries ao destruir topic" do
    topic = Topic.create!(name: "inteligência artificial")
    delivery = topic.topic_deliveries.create!(url_key: "news-123", sent_at: Time.current)

    assert_difference "TopicDelivery.count", -1 do
      topic.destroy!
    end
  end

  test "scope recent em topic_delivery filtra entregas da janela" do
    topic = Topic.create!(name: "tecnologia")
    old_delivery = topic.topic_deliveries.create!(url_key: "old-key", sent_at: 35.days.ago)
    recent_delivery = topic.topic_deliveries.create!(url_key: "recent-key", sent_at: 2.days.ago)

    recent_deliveries = TopicDelivery.recent
    assert_includes recent_deliveries, recent_delivery
    assert_not_includes recent_deliveries, old_delivery
  end
end
