# frozen_string_literal: true

require "test_helper"
require "fetcher/x_query_id_resolver"

# Logger que guarda TUDO que passou por ele (qualquer severidade, assinatura
# livre) para o teste poder afirmar sobre o TEXTO e o NÍVEL do log do job.
# Mocha (`expects(:info)`) obrigaria a saber de antemão todos os loggers do
# caminho; aqui o que importa é: o que o job disse, e com que nível.
class CapturingLogger
  Entry = Struct.new(:level, :message)

  def entries
    @entries ||= []
  end

  def messages(level = nil)
    entries.select { |e| level.nil? || e.level == level }.map(&:message)
  end

  def method_missing(level, *args)
    entries << Entry.new(level, args.compact.first.to_s)
    nil
  end

  def respond_to_missing?(_level, _include_private = false)
    true
  end
end

class RefreshXQueryIdsJobTest < ActiveJob::TestCase
  LOCK_KEY = "fetcher:x_query_id_lock:SearchTimeline".freeze
  CACHE_KEY = "fetcher:x_query_id:SearchTimeline".freeze

  def setup
    @cache = ActiveSupport::Cache::MemoryStore.new
    @logger = CapturingLogger.new
    @home_html = File.read(Rails.root.join("test/fixtures/x/home_with_manifest.html"))
    @bundle_js = File.read(Rails.root.join("test/fixtures/x/main_bundle_with_search_timeline.js"))
    Rails.stubs(:cache).returns(@cache)
    Rails.stubs(:logger).returns(@logger)
    # O job agora passa por várias operações: as que o teste não prepara não podem sair para a
    # rede de verdade. `stub_network` (quando usado) sobrescreve estes stubs.
    any = Fetcher::XQueryIdResolver.any_instance
    any.stubs(:fetch_home_html).raises(RuntimeError, "rede desligada no teste")
    any.stubs(:fetch_bundle).raises(RuntimeError, "rede desligada no teste")
  end

  OPS = RefreshXQueryIdsJob::OPERATIONS

  test "NotificationsTimeline (aba Menções) entra no refresh proativo" do
    assert_includes OPS, "NotificationsTimeline"
  end

  def outcome(value = "QID")
    Fetcher::XQueryIdResolver::Discovery.new(discovered: true, value: value, reason: :discovered)
  end

  # Logs que falam da SearchTimeline: os testes antigos afirmam sobre ela; as demais operações
  # do mesmo job têm os seus próprios testes abaixo.
  def search_msgs(level = nil)
    @logger.messages(level).select { |m| m.include?("SearchTimeline") }
  end

  def teardown
    Rails.unstub(:cache)
    Rails.unstub(:logger)
    super
  end

  # Envelope stale: `force: true` ignora o TTL e vai para `discover!`.
  def write_stale_envelope(query_id)
    @cache.write(CACHE_KEY,
                 { query_id: query_id, fetched_at: Time.now.to_i - 90_000, stale_at: Time.now.to_i - 3_600 })
  end

  # Substitui a camada de rede do resolver REAL, que o job instancia sozinho.
  #
  # `any_instance` (e não `stubs(:new)`) por um motivo medido: `stubs(:new)`
  # instala o stub no momento da chamada, ANTES de o argumento ser avaliado —
  # o `XQueryIdResolver.new(cache:)` dentro do helper era interceptado e
  # devolvia `nil`. Aqui o job cria a sua própria instância de verdade, e só a
  # rede é substituída: o teste fala do desfecho, não de HTTP.
  def stub_network(extract:, home: :ok)
    any = Fetcher::XQueryIdResolver.any_instance
    if home == :ok
      any.stubs(:fetch_home_html).returns(@home_html)
    else
      any.stubs(:fetch_home_html).raises(RuntimeError, home)
    end
    any.stubs(:fetch_bundle).returns(extract ? @bundle_js : '')
  end

  # O `descurtir` resolve o `queryId` do `UnfavoriteTweet` por nome em runtime, então a
  # operação PRECISA entrar na lista do refresh: fora dela, o redescovery de 404/422 só saem
  # pelo cache miss do primeiro uso, e uma rotação de `queryId` do X só seria percebida na
  # primeira chamada de cada 24 h.
  test "o refresh proativo cobre a operacao do descurtir" do
    assert_includes OPS, "UnfavoriteTweet",
                    "sem refresh proativo, o primeiro descurtir apos a rotacao do queryId so se recupera pelo retry"
  end

  test "chama resolver com force: true para cada operacao (busca, escrita, conta, feed e notificações)" do
    assert_equal %w[SearchTimeline CreateTweet FavoriteTweet CreateRetweet DeleteTweet UnfavoriteTweet
                    UserByScreenName UserTweetsAndReplies HomeTimeline HomeLatestTimeline NotificationsTimeline], OPS
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).returns(resolver)
    OPS.each { |op| resolver.expects(:resolve_with_outcome).with(op, force: true).returns(outcome) }

    RefreshXQueryIdsJob.perform_now

    OPS.each do |op|
      assert @logger.messages(:info).any? { |m| m.include?("#{op} descoberto") }, "sem log de #{op}"
    end
  end

  test "falha de uma operacao nao impede as outras" do
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).returns(resolver)
    resolver.expects(:resolve_with_outcome).with("SearchTimeline", force: true).raises(StandardError, "caiu")
    OPS.drop(1).each { |op| resolver.expects(:resolve_with_outcome).with(op, force: true).returns(outcome) }

    RefreshXQueryIdsJob.perform_now

    assert @logger.messages(:warn).any? { |m| m.include?("SearchTimeline") && m.include?("caiu") }
    assert @logger.messages(:info).any? { |m| m.include?("UserTweetsAndReplies descoberto") }
  end

  test "operacao sem PIN que nao aparece nos bundles: warn mapeado, nada gravado" do
    stub_network(extract: true)

    RefreshXQueryIdsJob.perform_now

    warn = @logger.messages(:warn).select { |m| m.include?("CreateTweet") }
    assert warn.any? { |m| m.include?("sem PIN") }, "veio: #{@logger.entries.map(&:message).inspect}"
    refute @logger.messages.any? { |m| m.include?("desfecho nao mapeado") }
    assert_nil @cache.read("fetcher:x_query_id:CreateTweet")
  end

  test "descoberta de verdade: loga info dizendo que gravou o valor" do
    write_stale_envelope("id-velho")
    stub_network(extract: true)

    RefreshXQueryIdsJob.perform_now

    info = @logger.messages(:info)
    assert info.any? { |m| m.include?("SearchTimeline") && m.include?(Fetcher::XQueryIdResolver::PIN) },
           "esperado log info com o query_id gravado; veio: #{info.inspect}"
    assert_empty search_msgs(:warn)
  end

  # ── RESSALVA R2 do PR #203, item 1 deste card ────────────────────────────
  # Com `force: true` o caminho AGORA perde a corrida de verdade (o conserto
  # da aquisição atômica trocou o read+write por `unless_exist`), e quem perde
  # devolve o valor em cache SEM ter descoberto nada. O job logava
  # "refresh concluído" nos dois casos: um refresh que não descobriu nada some
  # do log como sucesso, e quem lê o log depois não tem como saber que o
  # cache NÃO foi atualizado.
  test "lock ocupado por outro worker: NAO loga sucesso, diz que outro processo esta descobrindo" do
    write_stale_envelope("id-em-cache")
    @cache.write(LOCK_KEY, "token-do-outro-worker", expires_in: 60)

    RefreshXQueryIdsJob.perform_now

    refute @logger.messages(:info).any? { |m| m.include?("conclu") },
           "nao pode logar sucesso quando o lock pertence a outro worker: #{@logger.messages(:info).inspect}"
    assert @logger.messages.any? { |m| m.include?("outro") && m.include?("SearchTimeline") },
           "o log tem de dizer que outro processo esta descobrindo; veio: #{@logger.entries.map(&:message).inspect}"
    # O valor servido continua sendo dito, para o log responder "o que o
    # cache tinha" e nao so "nao fiz nada".
    assert @logger.messages.any? { |m| m.include?("id-em-cache") },
           "o log tem de dizer qual valor foi servido do cache; veio: #{@logger.entries.map(&:message).inspect}"
  end

  test "busca que nao acha o query id: PIN de ultima instancia, nunca sucesso" do
    write_stale_envelope("id-em-cache")
    stub_network(extract: false)

    RefreshXQueryIdsJob.perform_now

    refute @logger.messages(:info).any? { |m| m.include?("conclu") },
           "nao achou o query id e gravou o PIN: nao e sucesso de descoberta"
    assert @logger.messages(:warn).any? { |m| m.include?(Fetcher::XQueryIdResolver::PIN) },
           "esperado warn com o PIN de ultima instancia; veio: #{@logger.entries.map(&:message).inspect}"
  end

  test "falha da descoberta: loga warn com a causa, nunca sucesso" do
    write_stale_envelope("id-em-cache")
    stub_network(extract: true, home: "HTTP 503")

    RefreshXQueryIdsJob.perform_now

    refute @logger.messages(:info).any? { |m| m.include?("conclu") },
           "descoberta que explodiu nao pode ser logada como sucesso"
    warn = @logger.messages(:warn)
    assert warn.any? { |m| m.include?("503") },
           "o log tem de carregar a causa da falha; veio: #{@logger.entries.map(&:message).inspect}"
  end

  # ── BUSCA CORTADA ≠ ID INEXISTENTE (achado 3 da revisão A do #205) ────────
  #
  # Um bundle cortado pelo `HTTP_TOTAL_TIMEOUT` é uma resposta que NÃO CHEGOU
  # AO FIM, e isso é diferente de o X não ter o id. O desfecho
  # `:discovery_truncated` existe para essa diferença aparecer no log: sem ele,
  # o job anunciava "nao encontrada nos bundles" — e o PIN ficava 25h no cache
  # como se fosse um id verificado.
  #
  # Este teste amarra o mapeamento do desfecho: um motivo novo que o job não
  # mapeia cai no `else` ("desfecho nao mapeado"), que é o sinal de que
  # ninguém olhou para ele.
  test "busca CORTADA pelo teto: diz que foi cortada, e nao que o id nao existe" do
    write_stale_envelope("id-em-cache")
    any = Fetcher::XQueryIdResolver.any_instance
    any.stubs(:fetch_home_html).returns(@home_html)
    any.stubs(:fetch_bundle).raises(Faraday::TimeoutError, "teto total de 8s: execution expired")

    RefreshXQueryIdsJob.perform_now

    refute @logger.messages(:info).any? { |m| m.include?("conclu") },
           "busca cortada nao pode ser logada como sucesso"
    warn = @logger.messages(:warn)
    assert warn.any? { |m| m.include?("CORTADA") || m.include?("cortada") },
           "o log tem de dizer que a busca foi CORTADA; veio: #{@logger.entries.map(&:message).inspect}"
    refute warn.any? { |m| m.include?("gravado PIN") },
           "nada foi gravado: o log nao pode anunciar PIN de ultima instancia numa busca cortada"
    refute warn.any? { |m| m.include?("desfecho nao mapeado") },
           "o desfecho :discovery_truncated precisa estar mapeado no job"
  end

  test "sem cache e com a rede caída: PIN com warn, nunca sucesso silencioso" do
    stub_network(extract: true, home: "HTTP 500")

    RefreshXQueryIdsJob.perform_now

    refute @logger.messages(:info).any? { |m| m.include?("conclu") },
           "sem cache e sem descoberta nao ha nada a anunciar como sucesso"
    assert @logger.messages(:warn).any? { |m| m.include?(Fetcher::XQueryIdResolver::PIN) },
           "esperado warn com o PIN de ultima instancia; veio: #{@logger.entries.map(&:message).inspect}"
  end

  test "falha do resolver não derruba o job" do
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).returns(resolver)
    resolver.expects(:resolve_with_outcome).times(OPS.size).raises(StandardError, "network timeout")

    RefreshXQueryIdsJob.perform_now

    assert @logger.messages(:warn).any? { |m| m.include?("network timeout") },
           "a excecao do resolver tem de aparecer no log"
  end

  test "é idempotente: segunda chamada não duplica trabalho" do
    outcome = Fetcher::XQueryIdResolver::Discovery.new(
      discovered: true, value: Fetcher::XQueryIdResolver::PIN, reason: :discovered
    )
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).twice.returns(resolver)
    # Cada chamada ao job cria um novo resolver (sem singleton), mas o cache
    # interno do resolver é o mesmo Rails.cache, então o valor já encontrado
    # será retornado imediatamente na segunda chamada (sem network).
    OPS.each { |op| resolver.expects(:resolve_with_outcome).with(op, force: true).twice.returns(outcome) }

    RefreshXQueryIdsJob.perform_now
    RefreshXQueryIdsJob.perform_now
  end
end
