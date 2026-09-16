# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/discord_api_client"
require_relative "../../app/services/discord_message_chunker"
require_relative "../../app/jobs/last30days_topic_job"
require_relative "../../app/models/topic"
require_relative "../../app/models/topic_delivery"

class Last30DaysTopicJobTest < ActiveSupport::TestCase
  setup do
    ENV["DISCORD_DIGEST_CHANNEL_ID"] = "123456"
    @topic = Topic.create!(name: "Ruby on Rails", active: true)
  end

  teardown do
    ENV.delete("DISCORD_DIGEST_CHANNEL_ID")
  end

  test "perform com resultados monta mensagem com dedupe" do
    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]
    gh_results = [{ "title" => "Rails Repo Updates", "url" => "https://github.com/rails/rails", "source" => "github" }]
    pm_results = []

    Fetcher::Channels::Hackernews.stubs(:search).with(query: @topic.name, limit: 10).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).with(query: @topic.name, limit: 10).returns(gh_results)
    Fetcher::Channels::Polymarket.stubs(:search).with(query: @topic.name, limit: 10).returns(pm_results)

    DiscordApiClient.expects(:send_message).with("123456", regexp_matches(/Rails 8.1 Released/)).returns(true)

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    assert res[:sent]
    assert_equal @topic.id, res[:topic_id]

    assert_equal 2, TopicDelivery.where(topic_id: @topic.id).count

    # 2a execucao: tudo dedupe -> sent: false, nao envia mensagem
    res2 = job.perform(@topic.id, "123456")
    refute res2[:sent]
  end

  test "perform fonte que falha segue com as outras" do
    hn_results = [{ "title" => "Rails Post", "url" => "https://news.ycombinator.com/item?id=99", "source" => "hackernews" }]

    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).raises(StandardError.new("GitHub API error"))
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.stubs(:send_message).returns(true)

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    assert res[:sent]
    assert_equal 1, TopicDelivery.where(topic_id: @topic.id).count
  end

  test "perform quando tudo ja entregue nao envia" do
    url_key = Research::Fusion.normalize_url("https://rubyonrails.org/8.1")
    TopicDelivery.create!(topic_id: @topic.id, url_key: url_key, sent_at: 1.day.ago)

    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]

    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.expects(:send_message).never

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    refute res[:sent]
  end

  test "perform com topico removido loga sem erro" do
    non_existent_id = 999_999
    job = Last30DaysTopicJob.new

    res = job.perform(non_existent_id, "123456")
    refute res[:sent]
  end

  # Achado 5: sent_at deve ser ATUALIZADO em re-execuções (não apenas no create)
  test "perform atualiza sent_at em re-execucao para item ja existente" do
    url_key = Research::Fusion.normalize_url("https://rubyonrails.org/8.1")
    # Simula entrega antiga (> 7 dias) — já saiu da janela de dedupe
    old_time = 8.days.ago
    TopicDelivery.create!(topic_id: @topic.id, url_key: url_key, sent_at: old_time)

    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]
    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])
    DiscordApiClient.stubs(:send_message).returns(true)

    freeze_time = Time.current
    Time.stubs(:current).returns(freeze_time)

    job = Last30DaysTopicJob.new
    job.perform(@topic.id, "123456")

    td = TopicDelivery.find_by!(topic_id: @topic.id, url_key: url_key)
    # sent_at deve ter sido atualizado para agora (não manter old_time)
    assert_in_delta freeze_time.to_i, td.sent_at.to_i, 2,
                    "sent_at deve ser atualizado na re-entrega, mas manteve o valor antigo"
  end

  # Achado 6: sem channel_id (nil), nao grava TopicDelivery e retorna sent: false
  test "perform sem channel_id nao grava entregas e retorna sent false" do
    ENV.delete("DISCORD_DIGEST_CHANNEL_ID")

    hn_results = [{ "title" => "Rails 8.1 Released", "url" => "https://rubyonrails.org/8.1", "source" => "hackernews" }]
    Fetcher::Channels::Hackernews.stubs(:search).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.expects(:send_message).never
    # channel_id nil passado diretamente (Achado 8: DigestJob passa o id resolvido)
    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, nil)

    refute res[:sent], "Esperado sent: false quando channel_id é nil"
    assert_equal 0, TopicDelivery.where(topic_id: @topic.id).count,
                 "Nenhuma entrega deve ser gravada quando channel_id é nil"
  end

  # Achado 4: job grava SOMENTE as url_keys que aparecem na mensagem (limitadas pelo builder)
  test "perform grava apenas url_keys que aparecem na mensagem apos truncamento" do
    # Montar clusters sintéticos: 10 clusters × 4 itens cada (40 itens total)
    # MessageBuilder mostra MAX_CLUSTERS=8 × MAX_ITEMS_PER_CLUSTER=3 = 24 itens
    # Portanto só 24 url_keys devem ser gravadas, não 40

    all_items = []
    clusters = (1..10).map do |i|
      items = (1..4).map do |j|
        item = { "title" => "Item #{i}-#{j}", "url" => "https://example.com/#{i}/#{j}", "source" => "github",
                 "key" => "key-#{i}-#{j}" }
        all_items << item
        item
      end
      {
        "cluster_id" => "cluster-#{i}",
        "title" => "Cluster #{i}",
        "sources" => ["github"],
        "score" => (1.0 - (i * 0.05)),
        "uncertainty" => nil,
        "items" => items
      }
    end

    # Stub do Fusion e Cluster para retornar clusters sintéticos diretamente
    Research::Fusion.stubs(:fuse).returns([{ "key" => "k", "title" => "t", "score" => 0.5 }])
    Research::Cluster.stubs(:cluster).returns(clusters)
    Fetcher::Channels::Hackernews.stubs(:search).returns([])
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordApiClient.stubs(:send_message).returns(true)

    job = Last30DaysTopicJob.new
    job.perform(@topic.id, "123456")

    count = TopicDelivery.where(topic_id: @topic.id).count
    # 8 clusters × 3 itens = 24, NÃO 10×4=40
    assert_equal 24, count,
                 "Esperado exatamente 24 entregas (MAX_CLUSTERS 8 × MAX_ITEMS 3), mas gravou #{count}"

    # C2c: a marca na tabela própria (DigestItemDelivery) respeita o MESMO
    # truncamento — só os itens realmente exibidos entram, não os 40.
    assert_equal 24, DigestItemDelivery.where(
      digest_type: "last30days_topic", channel_id: "123456",
      item_type: "last30days_topic_item"
    ).size, "DigestItemDelivery deve gravar exatamente as 24 keys exibidas"
  end

  # Achado 5 (PR #36): o job DELEGA o chunking ao DiscordMessageChunker (helper
  # único). O algoritmo migrou para o unit test do chunker
  # (test/services/discord_message_chunker_test.rb); aqui verifica-se o
  # contrato de integração: 1 chamada ao helper + 1 send_message por chunk.
  test "perform delega chunking ao DiscordMessageChunker e envia 1 mensagem por chunk" do
    clusters = [
      {
        "cluster_id" => "cluster-1",
        "title" => "Cluster 1",
        "sources" => ["github"],
        "score" => 1.0,
        "uncertainty" => nil,
        "items" => [{ "title" => "Item 1", "url" => "https://example.com/1", "source" => "github", "key" => "key-1" }]
      }
    ]

    Research::Fusion.stubs(:fuse).returns([{ "key" => "k", "title" => "t", "score" => 0.5 }])
    Research::Cluster.stubs(:cluster).returns(clusters)
    Fetcher::Channels::Hackernews.stubs(:search).returns([])
    Fetcher::Channels::Github.stubs(:search).returns([])
    Fetcher::Channels::Polymarket.stubs(:search).returns([])

    DiscordMessageChunker.expects(:chunk).returns(["chunk_um", "chunk_dois"])
    DiscordApiClient.expects(:send_message).with("123456", "chunk_um").returns(true)
    DiscordApiClient.expects(:send_message).with("123456", "chunk_dois").returns(true)

    job = Last30DaysTopicJob.new
    res = job.perform(@topic.id, "123456")

    assert res[:sent]
  end

  # ============================================================ C2c ==========
  # O job passa a usar o mecanismo C2a (DigestItemDelivery) para supressão de
  # repetição: (1) exclui da seleção as keys já entregues para este
  # digest_type + canal, via sent_item_keys; (2) registra a entrega DEPOIS de
  # todos os chunks saírem bem, como o FridayIdeationJob.
  #
  # DECISÕES DE ESCOPO (C2c):
  #  - digest_type PRÓPRIO "last30days_topic" (não reusa o "friday_ideation"
  #    do friday — dois silêncios independentes: o mesmo item pode ser
  #    entregue pelos dois digests sem que um suprima o outro);
  #  - item_type PRÓPRIO "last30days_topic_item";
  #  - item_key ESCOPADA POR TÓPICO: "topic_<id>:<url_key>". O mesmo link
  #    pode aparecer em tópicos distintos e é relevante para cada um; o
  #    escopo por tópico impede que a entrega de um tópico silencie o outro.
  #  - JANELA: as fontes só retornam itens dos últimos 30 dias (HN filter
  #    created_at_i>now-30d; GitHub created:>=now-30d — Polymarket SEM
  #    filtro temporal). Um item já enviado que sai da janela (ex.: lançado
  #    há 40 dias) NUNCA volta pela própria fonte; a supressão permanente da
  #    DigestItemDelivery (sem filtro por sent_at) é inofensiva nesse caso —
  #    provada no teste "item de 40d..." abaixo.

  DIGEST_TYPE = "last30days_topic".freeze
  ITEM_TYPE = "last30days_topic_item".freeze

  # Item de HN como o canal devolve (url fixa, title livre).
  def hn_item(title, url)
    { "title" => title, "url" => url, "source" => "hackernews" }
  end

  def digest_keys(channel_id = "123456")
    DigestItemDelivery.where(digest_type: DIGEST_TYPE, channel_id: channel_id,
                             item_type: ITEM_TYPE).pluck(:item_key)
  end

  # Chave estável de entrega de um item HN, como o job a monta (tópico +
  # url_key normalizada pela mesma regra do job: Fusion.normalize_url).
  def delivery_key(url, topic)
    "topic_#{topic.id}:#{Research::Fusion.normalize_url(url)}"
  end

  # Executa o job com fetchers determinísticos (sem stub) e captura as
  # mensagens enviadas via send_message (chunker pass-through) — padrão do
  # repo (friday_ideation_job_c2a_test.rb, run_job).
  def perform_capturing(channel_id, hn_results, gh_results: [], pm_results: [])
    sent = []
    original_chunk = DiscordMessageChunker.method(:chunk)
    original_send = DiscordApiClient.method(:send_message)

    DiscordMessageChunker.define_singleton_method(:chunk) { |message, **_kwargs| [message] }
    DiscordApiClient.define_singleton_method(:send_message) { |_channel, msg| sent << msg }
    Fetcher::Channels::Hackernews.stubs(:search).with(query: @topic.name, limit: 10).returns(hn_results)
    Fetcher::Channels::Github.stubs(:search).with(query: @topic.name, limit: 10).returns(gh_results)
    Fetcher::Channels::Polymarket.stubs(:search).with(query: @topic.name, limit: 10).returns(pm_results)

    res = Last30DaysTopicJob.new.perform(@topic.id, channel_id)
    [res, sent]
  ensure
    if original_chunk
      DiscordMessageChunker.singleton_class.send(:remove_method, :chunk)
      DiscordMessageChunker.define_singleton_method(:chunk, original_chunk)
    end
    if original_send
      DiscordApiClient.singleton_class.send(:remove_method, :send_message)
      DiscordApiClient.define_singleton_method(:send_message, original_send)
    end
  end

  # 1. RED: a mesma URL nas duas rodadas NÃO repete na 2a; a nova entra.
  test "C2c-1: o mesmo item nao repete em duas rodadas para o mesmo canal" do
    url_a = "https://news.ycombinator.com/item?id=101"
    url_b = "https://news.ycombinator.com/item?id=102"
    url_c = "https://news.ycombinator.com/item?id=103"

    # Rodada 1: fontes trazem A e B. Rodada 2: A e B voltam (a API do HN
    # continua dentro de 30 dias) e a nova C entra. Sem C2c a rodada 2
    # repetiria A e B no Discord.
    res1, sent1 = perform_capturing("123456",
                                    [hn_item("Lançamento A", url_a), hn_item("Lançamento B", url_b)])
    res2, sent2 = perform_capturing("123456",
                                    [hn_item("Lançamento A", url_a),
                                     hn_item("Lançamento B", url_b),
                                     hn_item("Novo C", url_c)])
    mensagem2 = sent2.last.to_s

    assert res1[:sent]
    assert res2[:sent]
    assert sent1.last.to_s.include?("Lançamento A"), "1a rodada envia A e B"
    refute mensagem2.include?("Lançamento A"),
           "item já enviado na 1a rodada repetiu na 2a (repetição da C2c)"
    assert mensagem2.include?("Novo C")

    # Ambas as marcas ficam na tabela própria C2a — nunca na tabela de
    # catálogo. Rodada 1: A e B; rodada 2: só C entra.
    assert_equal [delivery_key(url_a, @topic), delivery_key(url_b, @topic)].sort,
                 digest_keys("123456").first(2).sort
    assert_equal 3, digest_keys("123456").size
    assert_equal [delivery_key(url_c, @topic)], digest_keys("123456")[2..].sort
  end

  # 2. Registro DEPOIS do envio bem-sucedido, com sent_at atual (mesmo
  # contrato do friday record_catalog_delivery).
  test "C2c-2: entrega registrada em DigestItemDelivery apos o envio" do
    url = "https://news.ycombinator.com/item?id=201"
    res, _ = perform_capturing("123456", [hn_item("Item 201", url)])

    assert res[:sent]
    assert_equal [delivery_key(url, @topic)], digest_keys("123456")
    entrega = DigestItemDelivery.find_by!(item_key: delivery_key(url, @topic))
    assert_in_delta Time.current.to_i, entrega.sent_at.to_i, 120,
                    "sent_at deve registrar o momento da entrega"
    assert_equal 1, TopicDelivery.where(topic_id: @topic.id).count,
                   "TopicDelivery continua gravado (compatibilidade da janela de 7 dias)"
  end

  # 3. Supressão NÃO vaza entre canais: a marca permanente de canal_a
  # não silencia canal_b (o isolamento entre canais é papel do
  # DigestItemDelivery, não da janela de 7 dias do TopicDelivery — a
  # antiga expira; a permanente, não).
  test "C2c-3: item entregue em outro canal nao e suprimido indevidamente" do
    url = "https://news.ycombinator.com/item?id=301"
    url_key = Research::Fusion.normalize_url(url)
    # 8 dias atrás: já saiu da janela de 7 dias do TopicDelivery, mas a
    # marca permanente por canal vive na DigestItemDelivery (C2a).
    TopicDelivery.create!(topic_id: @topic.id, url_key: url_key, sent_at: 8.days.ago)
    DigestItemDelivery.create!(digest_type: DIGEST_TYPE, channel_id: "canal_a",
                               item_type: ITEM_TYPE,
                               item_key: delivery_key(url, @topic), sent_at: 8.days.ago)

    # canal_b: sem marca ali → item entra (isolamento entre canais).
    res_b, sent_b = perform_capturing("canal_b", [hn_item("Item 301", url)])
    assert res_b[:sent], "entrega em canal_a não pode silenciar canal_b"
    assert sent_b.last.to_s.include?("Item 301")
    assert_equal [delivery_key(url, @topic)], digest_keys("canal_b")

    # canal_a: item NÃO repete ali (supressão efetiva — pela marca
    # permanente da DigestItemDelivery ou pela janela de 7 dias do
    # TopicDelivery; em ambos os casos a política "não repete" segura).
    res_a, _ = perform_capturing("canal_a", [hn_item("Item 301", url)])
    refute res_a[:sent], "canal_a já recebeu este item: repetição não é permitida"
  end

  # 4. Supressão NÃO vaza entre digest_types: a marca do friday_ideation
  # (C2a) não silencia o last30days_topic, e vice-versa.
  test "C2c-4: digest_type proprio nao e silenciado pelo friday_ideation" do
    url = "https://news.ycombinator.com/item?id=401"
    key = delivery_key(url, @topic)
    DigestItemDelivery.create!(digest_type: "friday_ideation", channel_id: "123456",
                               item_type: DigestItemDelivery::ITEM_TYPE_CATALOG,
                               item_key: key, sent_at: Time.current)

    res, sent_msgs = perform_capturing("123456", [hn_item("Item 401", url)])

    assert res[:sent]
    assert sent_msgs.last.to_s.include?("Item 401"),
           "marca do friday_ideation não pode suprimir o last30days_topic"
    assert_equal [key], digest_keys("123456")
  end

  # 5. Janela temporal: item lançado há 40 dias que JÁ foi enviado não volta.
  # A janela das fontes (30d) controla a reaparição — item fora da janela
  # simplesmente não é mais retornado; a supressão permanente fica
  # inofensiva. Prova: um item de 40d que RESURGE nos resultados (ex.:
  # fonte sem filtro temporal) continua sendo suprimido, e um item novo
  # entra normalmente.
  test "C2c-5: item de 40d ja enviado nao repete; itens novos entram" do
    url_antigo = "https://news.ycombinator.com/item?id=501"
    url_novo = "https://news.ycombinator.com/item?id=502"
    key_antigo = delivery_key(url_antigo, @topic)
    key_novo = delivery_key(url_novo, @topic)

    # Entregas feitas há 40 dias (fora da janela de 30d das fontes).
    DigestItemDelivery.create!(digest_type: DIGEST_TYPE, channel_id: "123456",
                               item_type: ITEM_TYPE, item_key: key_antigo,
                               sent_at: 40.days.ago)

    res, sent_msgs = perform_capturing("123456",
                                       [hn_item("Antigo 40d", url_antigo), hn_item("Novo 4d", url_novo)])

    mensagem = sent_msgs.last.to_s
    assert res[:sent]
    assert mensagem.include?("Novo 4d")
    refute mensagem.include?("Antigo 40d"),
           "item de 40d já enviado não deve voltar (supressão permanente da C2a)"
    assert_equal [key_antigo, key_novo].sort, digest_keys("123456").sort
  end

  # 6. limits_concurrency: uma execução por TÓPICO no worker do Solid Queue
  # — a causa da corrida (select+envio em paralelo duplicando itens no
  # Discord antes da marca), mesmo remédio do friday (C2a-r5).
  test "C2c-6: limits_concurrency serializa por topico" do
    job_a = Last30DaysTopicJob.new(@topic.id, "123456")
    job_b = Last30DaysTopicJob.new(@topic.id, "123456")

    assert_equal "Last30DaysTopicJob/last30days_topic/#{@topic.id}", job_a.concurrency_key
    assert_equal job_a.concurrency_key, job_b.concurrency_key
    assert_equal 1, Last30DaysTopicJob.concurrency_limit
    assert_equal :block, Last30DaysTopicJob.concurrency_on_conflict
    assert job_a.concurrency_limited?, "expected concurrency limiting to be enabled"

    outro_topico = Topic.create!(name: "Kubernetes", active: true)
    assert_not_equal job_a.concurrency_key,
                     Last30DaysTopicJob.new(outro_topico.id, "123456").concurrency_key,
                     "tópicos distintos não disputam a mesma chave"
  end

  # 7. Padrão do friday (C2a): registro DEPOIS do envio; erro no envio NÃO
  # grava a entrega — a próxima execução reenvia. DiscordApiClient levanta
  # RuntimeError ("Discord API error: ...") no caminho de envio.
  test "C2c-7: falha no envio nao registra entrega" do
    url = "https://news.ycombinator.com/item?id=701"
    original_chunk = DiscordMessageChunker.method(:chunk)
    original_send = DiscordApiClient.method(:send_message)
    DiscordMessageChunker.define_singleton_method(:chunk) { |message, **_kwargs| [message] }
    DiscordApiClient.define_singleton_method(:send_message) do |_c, _m|
      raise RuntimeError, "Discord API error: 500 boom"
    end

    err = assert_raises(RuntimeError) do
      Fetcher::Channels::Hackernews.stubs(:search).with(query: @topic.name, limit: 10)
            .returns([hn_item("Item 701", url)])
      Fetcher::Channels::Github.stubs(:search).with(query: @topic.name, limit: 10).returns([])
      Fetcher::Channels::Polymarket.stubs(:search).with(query: @topic.name, limit: 10).returns([])
      Last30DaysTopicJob.new.perform(@topic.id, "123456")
    end
    assert_match(/boom/, err.message)

    assert_equal 0, digest_keys.size,
                 "entrega não deve ser registrada quando o envio falhou"
  ensure
    if original_chunk
      DiscordMessageChunker.singleton_class.send(:remove_method, :chunk)
      DiscordMessageChunker.define_singleton_method(:chunk, original_chunk)
    end
    if original_send
      DiscordApiClient.singleton_class.send(:remove_method, :send_message)
      DiscordApiClient.define_singleton_method(:send_message, original_send)
    end
  end
end
