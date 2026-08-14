# frozen_string_literal: true

require "test_helper"

class SentimentAnalysisJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear rescue nil
    @target = SentimentTarget.create!(name: "Cleitin Job Test", query: "cleitin")
  end

  test "perform executa o pipeline completo de análise de sentimento e monta frozen_spec com janelas" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
                                                                  spec: { name: "Cleitin Job Test" },
                                                                  period_balance: { balance: 0.1 },
                                                                  collected_count: 10,
                                                                  rejected_count: 0,
                                                                  unparsed_count: 0,
                                                                  sem_data_count: 0
                                                                })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem de teste de sentimento").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem de teste de sentimento").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_not_nil run.finished_at
    assert_not_nil run.frozen_spec["window_start"]
    assert_not_nil run.frozen_spec["window_end"]
  end

  test "canal digest nulo define status delivery_failed e erro no run sem perder o relatório silenciosamente" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
                                                                  spec: { name: "Cleitin Job Test" },
                                                                  period_balance: { balance: 0.1 },
                                                                  collected_count: 10,
                                                                  rejected_count: 0,
                                                                  unparsed_count: 0,
                                                                  sem_data_count: 0
                                                                })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem de teste").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns(nil)

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "delivery_failed", run.status
    assert_equal "canal digest indisponível", run.error
    assert_not_nil run.finished_at
  end

  test "job integrado roda com Collector real e fontes stubadas provando amostragem com frozen_spec completo" do
    now = Time.current.utc
    x_items = [
      { source: "x", external_id: "job_x1", permalink: "p1", author: "user1", text: "Post integrado sobre cleitin bot", posted_at: now - 1.hour }
    ]

    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns(x_items)

    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
                                                                  spec: { name: "Cleitin Job Test" },
                                                                  period_balance: { balance: 0.1 },
                                                                  collected_count: 1,
                                                                  rejected_count: 0,
                                                                  unparsed_count: 0,
                                                                  sem_data_count: 0
                                                                })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem integrada").once
    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem integrada").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_equal 1, run.sentiment_phrases.count
    assert_equal "job_x1", run.sentiment_phrases.first.external_id
    assert_not_nil run.frozen_spec["window_start"]
    assert_not_nil run.frozen_spec["window_end"]
  end

  test "AllModelsFailed no classifier faz job falhar com status failed mesmo se SENTIMENT_ALLOW_PAID=true" do
    ENV["SENTIMENT_ALLOW_PAID"] = "true"
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).raises(Research::Sentiment::AllModelsFailed.new("LLM offline"))

    job = SentimentAnalysisJob.new
    assert_raises(Research::Sentiment::AllModelsFailed) do
      job.perform(@target.id)
    end

    run = @target.sentiment_runs.last
    assert_equal "failed", run.status
    assert_includes run.error, "LLM offline"
  ensure
    ENV.delete("SENTIMENT_ALLOW_PAID")
  end

  test "quando todas as fontes falham na coleta, não publica relatório de zeros no canal digest e marca status de dados insuficientes" do
    Research::Sentiment::Sources::Reddit.stubs(:fetch).raises(Fetcher::Channels::Error.new("Reddit indisponível"))
    Research::Sentiment::Sources::X.stubs(:fetch).raises(Fetcher::Channels::Error.new("X indisponível"))

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).never

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_includes %w[insufficient_data empty failed], run.status
    assert_not_equal "completed", run.status
  end

  test "quando a coleta é legitimamente vazia (zero frases encontradas), não envia relatório de zeros no digest" do
    Research::Sentiment::Sources::Reddit.stubs(:fetch).returns([])
    Research::Sentiment::Sources::X.stubs(:fetch).returns([])

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).never

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_includes %w[insufficient_data empty completed_empty], run.status
    assert_not_equal "completed", run.status
  end

  test "quando uma fonte falha e outra coleta com sucesso, completa o run com dados da fonte funcional" do
    now = Time.current.utc
    x_items = [
      { source: "x", external_id: "job_x_partial", permalink: "p1", author: "user1", text: "Post válido no X sobre cleitin bot", posted_at: now - 1.hour }
    ]

    Research::Sentiment::Sources::Reddit.stubs(:fetch).raises(Fetcher::Channels::Error.new("Reddit offline"))
    Research::Sentiment::Sources::X.stubs(:fetch).returns(x_items)

    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 1,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem com dados parciais").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem com dados parciais").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_equal 1, run.sentiment_phrases.count
  end

  # --- ACHADO N1: Recuperação de canal obsoleto não integrada ---

  test "quando canal em cache está obsoleto (404 no envio), recupera canal via recover_digest_channel e conclui envio no canal recuperado" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem recuperada").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("stale_channel_123")
    DiscordApiClient.expects(:send_message).with("stale_channel_123", "Mensagem recuperada")
      .raises(RuntimeError.new("Discord API error: 404 Not Found"))
    SentimentAnalysisJob.any_instance.expects(:recover_digest_channel).with("stale_channel_123")
      .returns("recovered_channel_456")
    DiscordApiClient.expects(:send_message).with("recovered_channel_456", "Mensagem recuperada").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_not_nil run.finished_at
  end

  test "quando canal digest está obsoleto e recover_digest_channel retorna nil, marca status delivery_failed" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem com canal obsoleto").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("stale_channel_123")
    DiscordApiClient.expects(:send_message).with("stale_channel_123", "Mensagem com canal obsoleto")
      .raises(RuntimeError.new("Discord API error: 404 Not Found"))
    SentimentAnalysisJob.any_instance.expects(:recover_digest_channel).with("stale_channel_123").returns(nil)

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "delivery_failed", run.status
    assert_includes run.error, "canal digest indisponível"
    assert_not_nil run.finished_at
  end

  # --- ACHADO N2: Entrega parcial sem idempotência ---

  test "fluxo normal de entrega marca o run como entregue (delivered_at preenchido)" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem de teste de sentimento").once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "Mensagem de teste de sentimento").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert run.respond_to?(:delivered_at) && run.delivered_at.present?, "run deve possuir e preencher delivered_at após entrega com sucesso"
  end

  test "re-execução de run já marcado como entregue não re-envia mensagens no Discord (idempotência de entrega)" do
    run = @target.sentiment_runs.create!(
      status: "completed",
      started_at: Time.current,
      frozen_spec: { "target_id" => @target.id }
    )
    if run.respond_to?(:delivered_at=)
      run.update!(delivered_at: Time.current)
    else
      run.define_singleton_method(:delivered_at) { Time.current }
    end

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).never

    job = SentimentAnalysisJob.new
    result_run = job.perform(@target.id, run.id)

    assert_equal "completed", result_run.status
    assert_not_nil result_run.delivered_at
  end

  test "entrega registra progresso por chunk com indice unico para o run" do
    Research::Sentiment::Collector.expects(:collect).once
    Research::Sentiment::Classifier.expects(:classify).once
    Research::Sentiment::Aggregator.expects(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.expects(:build).returns("Mensagem longa").once
    DiscordMessageChunker.expects(:chunk).with("Mensagem longa").returns(["chunk_0", "chunk_1", "chunk_2"]).once

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_0").once
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_1").once
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_2").once

    job = SentimentAnalysisJob.new
    run = job.perform(@target.id)

    assert_equal "completed", run.status
    assert_not_nil run.delivered_at

    # Verifica o registro de progresso por chunk
    if defined?(SentimentChunkDelivery)
      chunk_indices = SentimentChunkDelivery.where(run_id: run.id).pluck(:chunk_index).sort
      assert_equal [0, 1, 2], chunk_indices
    end
  end

  test "falha no meio da entrega (chunk 2 de 3) permite retomada sem reenviar chunks ja entregues" do
    Research::Sentiment::Collector.stubs(:collect)
    Research::Sentiment::Classifier.stubs(:classify)
    Research::Sentiment::Aggregator.stubs(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.stubs(:build).returns("Mensagem com 3 chunks")
    DiscordMessageChunker.stubs(:chunk).returns(["chunk_0", "chunk_1", "chunk_2"])

    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")

    # Primeira tentativa: chunk 0 envia com sucesso, chunk 1 falha com erro de rede
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_0").once
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_1").raises(RuntimeError.new("Discord API 500 error")).once

    job = SentimentAnalysisJob.new
    assert_raises(RuntimeError) do
      job.perform(@target.id)
    end

    run = @target.sentiment_runs.last
    assert_nil run.delivered_at, "delivered_at global nao pode ser preenchido apos falha parcial"

    # Segunda tentativa (retomada passando run_id):
    # chunk 0 NÃO deve ser reenviado; chunk 1 e chunk 2 devem ser enviados
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_0").never
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_1").once
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_2").once

    resumed_run = job.perform(@target.id, run.id)
    assert_equal "completed", resumed_run.status
    assert_not_nil resumed_run.delivered_at
  end

  test "executores concorrentes nao entregam o mesmo chunk duas vezes (lock/idempotencia por chunk)" do
    run = @target.sentiment_runs.create!(
      status: "aggregating",
      started_at: Time.current,
      frozen_spec: { "target_id" => @target.id }
    )

    Research::Sentiment::Collector.stubs(:collect)
    Research::Sentiment::Classifier.stubs(:classify)
    Research::Sentiment::Aggregator.stubs(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.stubs(:build).returns("Mensagem concorrente")
    DiscordMessageChunker.stubs(:chunk).returns(["chunk_0", "chunk_1"])
    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")

    # Chunk 0 e 1 devem ser entregues exatamente uma vez
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_0").once
    DiscordApiClient.expects(:send_message).with("channel_123", "chunk_1").once

    # Simula o primeiro executor completando a entrega
    job1 = SentimentAnalysisJob.new
    job1.perform(@target.id, run.id)

    # Segundo executor rodando o mesmo run não deve enviar nenhum chunk novamente
    job2 = SentimentAnalysisJob.new
    job2.perform(@target.id, run.id)
  end

  test "executores concorrentes sobrepostos nao marcam run entregue durante envio em andamento e enviam chunk uma unica vez" do
    run = @target.sentiment_runs.create!(
      status: "aggregating",
      started_at: Time.current,
      frozen_spec: { "target_id" => @target.id }
    )

    Research::Sentiment::Collector.stubs(:collect)
    Research::Sentiment::Classifier.stubs(:classify)
    Research::Sentiment::Aggregator.stubs(:aggregate).returns({
      spec: { name: "Cleitin Job Test" },
      period_balance: { balance: 0.1 },
      collected_count: 10,
      rejected_count: 0,
      unparsed_count: 0,
      sem_data_count: 0
    })
    Sentiment::MessageBuilder.stubs(:build).returns("Mensagem concorrente sobreposta")
    DiscordMessageChunker.stubs(:chunk).returns(["chunk_0"])
    SentimentAnalysisJob.any_instance.stubs(:ensure_digest_channel).returns("channel_123")

    q_t1_entered = Queue.new
    q_t1_unblock = Queue.new
    send_mutex = Mutex.new
    send_calls = []

    DiscordApiClient.stubs(:send_message).with do |channel_id, chunk|
      send_mutex.synchronize { send_calls << [channel_id, chunk] }
      q_t1_entered.push(true)
      q_t1_unblock.pop # Bloqueia thread1 simulando I/O lento
      true
    end

    t1 = nil
    t2 = nil
    Timeout.timeout(5) do
      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          SentimentAnalysisJob.new.perform(@target.id, run.id)
        end
      end

      # Aguarda Thread 1 entrar no send_message (reservou chunk, mas ainda não concluiu envio)
      q_t1_entered.pop

      # Enquanto Thread 1 está bloqueada no envio, Thread 2 executa concorrentemente
      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          SentimentAnalysisJob.new.perform(@target.id, run.id)
        end
      end

      # Breve pausa para dar oportunidade de avanço a Thread 2
      sleep 0.1

      # Asserção crítica: enquanto Thread 1 não confirmou envio, nenhum executor pode marcar o run entregue
      assert_nil run.reload.delivered_at, "run nao pode ser marcado entregue enquanto o envio do chunk esta em andamento"

      # Desbloqueia Thread 1 para concluir
      q_t1_unblock.push(true)

      t1.join
      t2.join

      assert_equal 1, send_calls.size, "chunk deve ser enviado exatamente uma vez no total"
      assert_equal "completed", run.reload.status
      assert_not_nil run.delivered_at
    end
  ensure
    q_t1_unblock.push(true) rescue nil
    t1&.kill
    t2&.kill
  end

  test "acquire_delivery_lock e release_delivery_lock gerenciam posse do lock via token" do
    job = SentimentAnalysisJob.new
    token1 = "token_owner"
    token2 = "token_competitor"

    assert job.send(:acquire_delivery_lock, 9999, token1)
    refute job.send(:acquire_delivery_lock, 9999, token2)

    # Release com token divergente não libera
    job.send(:release_delivery_lock, 9999, "token_wrong")
    refute job.send(:acquire_delivery_lock, 9999, token2)

    # Release com token legítimo libera
    job.send(:release_delivery_lock, 9999, token1)
    assert job.send(:acquire_delivery_lock, 9999, token2)

    job.send(:release_delivery_lock, 9999, token2)
  end

  # --- Validações de target e run_id ---

  test "perform com run_id inexistente lanca erro e nao cria novo run" do
    assert_no_difference "SentimentRun.count" do
      assert_raises(ArgumentError) do
        SentimentAnalysisJob.new.perform(@target.id, 999_999)
      end
    end
  end

  test "perform com run_id pertencente a outro alvo lanca erro e nao processa o run alheio" do
    other_target = SentimentTarget.create!(name: "Outro Alvo Job", query: "outro")
    other_run = other_target.sentiment_runs.create!(
      status: "pending",
      started_at: Time.current,
      frozen_spec: { "target_id" => other_target.id }
    )

    Research::Sentiment::Collector.expects(:collect).never

    assert_raises(ArgumentError) do
      SentimentAnalysisJob.new.perform(@target.id, other_run.id)
    end
  end
end
