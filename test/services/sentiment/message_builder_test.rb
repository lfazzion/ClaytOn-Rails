# frozen_string_literal: true

require "test_helper"

class SentimentMessageBuilderTest < ActiveSupport::TestCase
  setup do
    @target = SentimentTarget.create!(name: "Cleitin MessageBuilder", query: "cleitin")
    @run = @target.sentiment_runs.create!(
      status: "completed",
      frozen_spec: { "name" => "Cleitin MessageBuilder", "sources" => "reddit,x", "bucket" => "week" },
      started_at: Time.utc(2026, 8, 1, 10, 0, 0),
      model_id: "google/gemma-4-26b-a4b-it:free",
      snapshot_pinned: true,
      collected_count: 100,
      rejected_count: 10,
      unparsed_count: 2,
      tara: 0.96
    )
  end

  test "gera mensagem com os 5 números de honestidade e 1 exemplo por classe" do
    data = {
      spec: @run.frozen_spec,
      period_balance: { positive: 40, negative: 20, neutral: 38, total: 98, balance: 0.20 },
      sources_balance: {
        "reddit" => { positive: 25, negative: 10, neutral: 20, total: 55, balance: 0.27 },
        "x" => { positive: 15, negative: 10, neutral: 18, total: 43, balance: 0.12 }
      },
      curve: [
        { date: "2026-08-03", balance: 0.20, n: 50, sparkline: "▅" }
      ],
      max_delta_s: nil,
      insufficient_buckets: ["2026-08-10"],
      unparsed_count: 2,
      sem_data_count: 5,
      rejected_count: 10,
      collected_count: 100,
      tara: 0.96,
      examples: {
        "positive" => { text: "Excelente bot de teste", permalink: "https://reddit.com/r1" },
        "negative" => { text: "Muito ruim o serviço", permalink: "https://x.com/x1" },
        "neutral" => { text: "Lançamento confirmado", permalink: "https://x.com/x2" }
      }
    }

    msg = Sentiment::MessageBuilder.build(@run, data)

    # 5 números de honestidade
    assert_includes msg, "~75%"
    assert_includes msg, "96%"
    assert_includes msg, "2 frases sem classificação"
    assert_includes msg, "5 frases sem data"
    assert_includes msg, "1 buckets ignorados por volume"

    # 1 exemplo por classe com permalink
    assert_includes msg, "Excelente bot de teste"
    assert_includes msg, "<https://reddit.com/r1>"
    assert_includes msg, "Muito ruim o serviço"

    # Saldo por fonte
    assert_includes msg, "reddit"
    assert_includes msg, "x"

    # Sem anexo e chunks dentro do limite
    chunks = DiscordMessageChunker.chunk(msg)
    chunks.each do |c|
      assert c.length <= 1900
    end
  end
end
