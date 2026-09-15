# frozen_string_literal: true

require 'test_helper'

class ScrapeYoutubeJobTest < ActiveJob::TestCase
  setup do
    Scraping::FetchPacer.stubs(:wait)
    @profile = create(:social_profile, :youtube, platform_username: 'test_channel')
    @metadata = {
      channel_id: 'UC123',
      title: 'Test Channel',
      description: 'A channel',
      subscriber_count: 50_000,
      video_count: 100,
      thumbnail_url: 'https://example.com/thumb.jpg'
    }
    @videos = [
      {
        platform_post_id: 'vid1',
        title: 'Video 1',
        post_type: 'video',
        posted_at: 1.day.ago,
        views_count: 1000,
        thumbnail_url: 'https://example.com/t1.jpg',
        video_url: 'https://youtube.com/watch?v=vid1'
      },
      {
        platform_post_id: 'vid2',
        title: 'Video 2',
        post_type: 'video',
        posted_at: 2.days.ago,
        views_count: 2000,
        thumbnail_url: 'https://example.com/t2.jpg',
        video_url: 'https://youtube.com/watch?v=vid2'
      }
    ]
  end

  # ITEM 1/3 — stuba a sessão de cookies inteira para o caminho perform.
  # `perform` agora chama o jar de cookies DUAS vezes (extract_metadata_with_
  # cookies e extract_videos_with_cookies), então todo teste de perform precisa
  # de SessionCookies.for + with_netscape_file + refresh + extract_channel_
  # metadata stubados, senão o SessionCookies real abre CDP no Chrome
  # (chrome:9222) e o WebMock bloqueia a conexão. O `with_netscape_file`
  # devolve, via `.returns`, a 3-tupla [videos, fallback, causa] — que é o que
  # o helper de vídeos retorna em produção; a chamada interna de extract_
  # videos_detailed é stubada para satisfazer o bloco (o resultado do bloco é
  # descartado pelo `.returns`).
  def stub_youtube_session(metadata: @metadata, videos: @videos, fallback: false, cause: nil)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com')
                          .returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file)
                     .yields('/tmp/fake_cookies.txt')
                     .returns([videos, fallback, cause])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata)
      .with('https://www.youtube.com/@test_channel', proxy: nil, cookies_path: '/tmp/fake_cookies.txt')
      .returns(metadata)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed)
      .with('https://www.youtube.com/@test_channel', limit: 30, proxy: nil, cookies_path: '/tmp/fake_cookies.txt')
      .returns([videos, fallback, cause])
  end

  test 'should enqueue in scraping queue' do
    assert_equal 'scraping', ScrapeYoutubeJob.new.queue_name
  end

  test 'concurrency key should differ by profile' do
    other_profile = create(:social_profile, :youtube, platform_username: 'other_channel')
    key_profile_a = ScrapeYoutubeJob.new(@profile.id).concurrency_key
    key_profile_b = ScrapeYoutubeJob.new(other_profile.id).concurrency_key
    assert_not_equal key_profile_a, key_profile_b
  end

  test 'serializes two executions for the same profile' do
    job_a = ScrapeYoutubeJob.new(@profile.id)
    job_b = ScrapeYoutubeJob.new(@profile.id)
    assert_equal job_a.concurrency_key, job_b.concurrency_key
    assert job_a.concurrency_limited?, "expected concurrency limiting to be enabled"
  end

  test 'should raise ArgumentError for non-YouTube profile' do
    twitter_profile = create(:social_profile, :twitter, platform_username: 'twitter_user')

    assert_raises(ArgumentError) do
      ScrapeYoutubeJob.perform_now(twitter_profile.id)
    end
  end

  test 'should update profile, create posts and snapshot on success with cookies' do
    # expects(:refresh_from_netscape!) foi removido: o stub com a mesma
    # expectativa já existe no helper stub_youtube_session (stubs) — misturar
    # expects após stubs no mesmo método criava o conflito apontado no r7.
    # O contrato "jar atualizado após a coleta" segue medido nos testes de
    # unidade dos helpers (L121, L141, L155), cada um com expects de refresh.
    stub_youtube_session(fallback: false, cause: nil)
    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: '/tmp/fake_cookies.txt'
    ).returns([@videos, false, nil])

    assert_difference 'SocialPost.count', 2 do
      ScrapeYoutubeJob.perform_now(@profile.id)
    end

    @profile.reload
    assert_equal 'Test Channel', @profile.display_name
    assert_equal 50_000, @profile.followers_count
    assert_equal 'success', @profile.collection_status
    assert_not_nil @profile.last_collected_at
    assert_equal 1, ProfileSnapshot.where(social_profile: @profile).count
  end

  # ITEM 1 — cookie chega aos metadados: o job passou a coletar metadata pela
  # mesma sessão de cookies do vídeo (Fetcher::SessionCookies + CookieJar), com
  # fallback para coleta sem cookie em Fetcher::CookieJar::Expired (o alerta
  # diz que foi por sessão expirada).
  test 'extract_metadata_with_cookies usa a sessão de cookies e atualiza o jar após a coleta' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).with(
      "https://www.youtube.com/@test_channel", proxy: nil, cookies_path: "/tmp/fake_meta_cookies.txt"
    ).returns(@metadata)

    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([[{ "name" => "SID", "value" => "123" }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).with("youtube.com", cookies: [{ "name" => "SID", "value" => "123" }])
                                                   .yields("/tmp/fake_meta_cookies.txt")
    Fetcher::CookieJar.expects(:refresh_from_netscape!).with { |args|
      args[:domain] == "youtube.com" &&
        args[:path] == "/tmp/fake_meta_cookies.txt" &&
        args[:auth_cookies] == Fetcher::Channels::Youtube::AUTH_COOKIES &&
        args[:expires_at].present?
    }.returns(true)

    result = ScrapeYoutubeJob.new.send(:extract_metadata_with_cookies, "https://www.youtube.com/@test_channel", proxy: nil)

    assert_equal [@metadata, nil], result
  end

  test 'extract_metadata_with_cookies sem sessão válida cai na coleta sem cookie (Expired)' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).with(
      "https://www.youtube.com/@test_channel", proxy: nil, cookies_path: nil
    ).returns(@metadata)

    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([[{ "name" => "SID", "value" => "123" }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).with("youtube.com", cookies: [{ "name" => "SID", "value" => "123" }])
                                                   .raises(Fetcher::CookieJar::Expired.new("youtube.com"))

    result = ScrapeYoutubeJob.new.send(:extract_metadata_with_cookies, "https://www.youtube.com/@test_channel", proxy: nil)

    assert_equal [@metadata, "sessão expirada"], result
  end

  test 'extract_metadata_with_cookies propaga RateLimitError (não é fallback)' do
    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([[{ "name" => "SID", "value" => "123" }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields("/tmp/fake_meta_cookies.txt")
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).with(
      "https://www.youtube.com/@test_channel", proxy: nil, cookies_path: "/tmp/fake_meta_cookies.txt"
    ).raises(ScrapingServices::RateLimitError.new("429"))

    assert_raises(ScrapingServices::RateLimitError) do
      ScrapeYoutubeJob.new.send(:extract_metadata_with_cookies, "https://www.youtube.com/@test_channel", proxy: nil)
    end
  end

  test 'metadata nil após sessão expirada: perfil degraded e alerta cita a sessão expirada' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).with(
      "https://www.youtube.com/@test_channel", proxy: nil, cookies_path: "/tmp/fake_meta_cookies.txt"
    ).raises(Fetcher::CookieJar::Expired.new("youtube.com"))
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).with(
      "https://www.youtube.com/@test_channel", proxy: nil, cookies_path: nil
    ).returns(nil)

    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([[{ "name" => "SID", "value" => "123" }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).with("youtube.com", cookies: [{ "name" => "SID", "value" => "123" }])
                                                   .yields("/tmp/fake_meta_cookies.txt")

    # Asserção atualizada do r7: a asserção antiga esperava a mensagem
    # "extract_channel_metadata returned nil" porque o contrato era metadata
    # anônima; agora o contrato item 1 é metadata via sessão de cookies e a
    # nota da coleta sem-cookie acompanha o alerta ("sem cookies: sessão expirada").
    # .with(string literal): a asserção antiga usava o regex /sessão expirada/
    # porque era o único trecho conhecido da mensagem; agora a mensagem inteira
    # é canônica e Mocha não faz matching de Regexp em argumentos.
    ScrapingFailureAlertJob.expects(:perform_later).with(
      "youtube",
      @profile.id,
      "extract_channel_metadata returned nil (sem cookies: sessão expirada)",
      "metadata_failure"
    )

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    assert @profile.collection_status.start_with?("degraded"),
           "status deve ser degraded (obtido: #{@profile.collection_status.inspect})"
    assert_nil @profile.last_collected_at
  end

  test 'should set partial status and enqueue alert when fallback is used' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt').returns([@videos, true, nil])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    # Contrato r7: extract_videos_detailed devolve a 3-tupla [itens, fallback, causa];
    # fallback=true com causa=nil (o motivo genérico "sem causa identificada").
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([@videos, true, nil])
    # Asserção atualizada do r7: a asserção antiga esperava a mensagem
    # 'fallback: sem dados detalhados (likes/comments nil)' porque o contrato
    # era status opaco "partial"; agora o contrato item 3 inclui a causa no
    # alerta e no status — com causa nil, o motivo é "sem causa identificada".
    ScrapingFailureAlertJob.expects(:perform_later).with(
      'youtube',
      @profile.id,
      'fallback: sem causa identificada — sem dados detalhados (likes/comments nil)',
      'partial_collection'
    )

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    # Asserção atualizada do r7: a asserção antiga esperava "partial" porque
    # o contrato era status opaco; agora o contrato é "partial (#{motivo})".
    assert_equal 'partial (sem causa identificada)', @profile.collection_status
    assert_not_nil @profile.last_collected_at
  end

  # ITEM 3 — cada causa nomeada produz status e alerta próprios; a causa
  # `session_rejected` vem com o fallback flat (o único que o serviço permite
  # sem cookie), `bot_check` VEM SEM fallback (fallback=false) mas ainda marca
  # o run parcial com o motivo; causa nil + fallback mantém a mensagem legível.
  test 'cada causa nomeada gera status parcial com o motivo e alerta com a causa (item 3)' do
    causes = ["bot_check", "members_only", "timeout", "network", "session_rejected", "unknown"]
    causes.each do |cause|
      # Limpa o estado de incidente entre execuções (AlertThrottler).
      AlertThrottler.resolve_incident("youtube", @profile.id)
      @profile.update!(collection_status: "success", last_collected_at: nil)

      ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
      Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([[{ "name" => "SID", "value" => "123" }], :jar])
      fallback = cause == "session_rejected"
      # with_netscape_file devolve, via .returns, a 3-tupla do contrato r7
      # (sem .returns o stub devolve nil → cause vira nil → 'success' falso).
      Fetcher::CookieJar.stubs(:with_netscape_file).yields("/tmp/fake_cookies.txt").returns([@videos, fallback, cause])
      Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
      ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([@videos, fallback, cause])
      ScrapingFailureAlertJob.expects(:perform_later).with(
        "youtube",
        @profile.id,
        "fallback: #{cause} — sem dados detalhados (likes/comments nil)",
        "partial_collection"
      ).once

      ScrapeYoutubeJob.perform_now(@profile.id)

      @profile.reload
      assert_equal "partial (#{cause})", @profile.collection_status,
                   "causa #{cause} deve marcar status partial com o motivo"
      assert_not_nil @profile.last_collected_at
    end
  end

  test 'fallback sem causa nomeada mantém status e alerta legíveis (motivo genérico)' do
    AlertThrottler.resolve_incident("youtube", @profile.id)
    @profile.update!(collection_status: "success", last_collected_at: nil)

    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([[{ "name" => "SID", "value" => "123" }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields("/tmp/fake_cookies.txt").returns([@videos, true])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([@videos, true, nil])
    ScrapingFailureAlertJob.expects(:perform_later).with(
      "youtube",
      @profile.id,
      "fallback: sem causa identificada — sem dados detalhados (likes/comments nil)",
      "partial_collection"
    ).once

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    assert_equal "partial (sem causa identificada)", @profile.collection_status
    assert_not_nil @profile.last_collected_at
  end

  # Caminho feliz segue 'success' (item 3): fallback=false, causa=nil.
  test 'caminho feliz segue success com causa nil' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with("youtube.com").returns([[{ "name" => "SID", "value" => "123" }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields("/tmp/fake_cookies.txt").returns([@videos, false])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([@videos, false, nil])
    ScrapingFailureAlertJob.expects(:perform_later).never

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    assert_equal "success", @profile.collection_status
  end

  test 'should fallback to no cookies when session expired' do
    # Item 1: os metadados agora passam pela MESMA sessão de cookies dos vídeos
    # (extract_metadata_with_cookies). SessionCookies.for raising Expired faz o
    # helper de metadata cair na coleta sem-cookie (assim como o de vídeos).
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').raises(Fetcher::CookieJar::Expired.new('youtube.com'))
    # O fallback sem-cookie devolve a 3-tupla (contrato r7); causa nil →
    # motivo genérico "sem causa identificada".
    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: nil
    ).returns([@videos, true, nil])
    # Asserção atualizada do r7: a mensagem antiga 'fallback: sem dados
    # detalhados' era do contrato opaco; agora item 3 inclui a causa (aqui
    # genérica, pois causa=nil) no alerta.
    ScrapingFailureAlertJob.expects(:perform_later).with(
      'youtube',
      @profile.id,
      'fallback: sem causa identificada — sem dados detalhados (likes/comments nil)',
      'partial_collection'
    )

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    # Asserção atualizada do r7: 'partial' (opaco) → 'partial (sem causa
    # identificada)' — o motivo agora acompanha o status.
    assert_equal 'partial (sem causa identificada)', @profile.collection_status
  end

  test 'should fallback to no cookies when extract_videos_detailed raises non-CookieJar error' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt')
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    # Erro de parser/rede RECUPERÁVEL (entra em RECOVERABLE_SCRAPER_ERRORS) ainda
    # justifica o fallback sem cookies (achado D: só estes, não qualquer
    # StandardError genérico).
    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: '/tmp/fake_cookies.txt'
    ).raises(Errno::ECONNRESET.new('connection reset by peer'))
    # Fallback call must use cookies_path: nil (achado R3-6)
    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: nil
    ).returns([@videos, false])

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'success', @profile.collection_status
  end

  # DECISÃO 5 do sol — metadata nil NÃO é return silencioso: marca o perfil como
  # "degraded" e enfileira ScrapingFailureAlertJob("youtube", id, msg, "metadata_failure"),
  # preservando last_collected_at nil (não houve coleta). Atualizado da expectativa
  # antiga (return silencioso) para o comportamento canônico da fusão.
  test 'should mark profile degraded, enqueue metadata_failure alert and preserve last_collected_at when metadata is nil' do
    # Item 1: perform passa pela sessão de cookies (extract_metadata_with_cookies).
    # Sem stub de SessionCookies.for o real abre CDP no chrome:9222 (WebMock
    # bloqueia) antes de chegar no extract_channel_metadata stubado.
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt')
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(nil)
    # metadata nil SEM nota de fallback (o bloco com-cookie devolveu nil, não
    # Expired) → detail vira '' e a mensagem permanece 'returned nil'.
    ScrapingFailureAlertJob.expects(:perform_later).with(
      'youtube',
      @profile.id,
      'extract_channel_metadata returned nil',
      'metadata_failure'
    )

    assert_no_difference 'ProfileSnapshot.count' do
      assert_no_difference 'SocialPost.count' do
        ScrapeYoutubeJob.perform_now(@profile.id)
      end
    end

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
    assert_nil @profile.last_collected_at
  end

  test 'should handle empty videos array' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt').returns([[], false])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([[], false])

    assert_no_difference 'SocialPost.count' do
      ScrapeYoutubeJob.perform_now(@profile.id)
    end

    @profile.reload
    assert_equal 'success', @profile.collection_status
    assert_equal 1, ProfileSnapshot.where(social_profile: @profile).count
  end

  test 'should skip when profile was recently collected' do
    @profile.update!(last_collected_at: 3.hours.ago)
    ScrapingServices::YoutubeScraperService.expects(:extract_channel_metadata).never

    ScrapeYoutubeJob.perform_now(@profile.id)
  end

  test 'should be idempotent for snapshots within same hour' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt').returns([@videos, false])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([@videos, false])

    ScrapeYoutubeJob.perform_now(@profile.id)
    first_snapshot = ProfileSnapshot.where(social_profile: @profile).last
    assert_equal 50_000, first_snapshot.followers_count
    assert_equal 100, first_snapshot.posts_count

    # Reset last_collected_at so the second run is not blocked by rate-limit,
    # but keep within the same hour so create_snapshot reuses the same record.
    # update_all (não update!) é obrigatório: o objeto @profile em memória já
    # tem last_collected_at nil (do factory), então update! seria no-op e o
    # banco manteria o valor setado pela primeira execução do job.
    SocialProfile.where(id: @profile.id).update_all(last_collected_at: nil)

    # Second run with DIFFERENT metadata to prove snapshot is actually updated
    updated_metadata = @metadata.merge(subscriber_count: 75_000, video_count: 200)
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(updated_metadata)

    ScrapeYoutubeJob.perform_now(@profile.id)

    assert_equal 1, ProfileSnapshot.where(social_profile: @profile).count
    second_snapshot = ProfileSnapshot.where(social_profile: @profile).last
    assert_equal first_snapshot.id, second_snapshot.id
    assert_equal 75_000, second_snapshot.followers_count
    assert_equal 200, second_snapshot.posts_count
  end

  # ACHADO D: o rescue interno de extract_videos_with_cookies engolia QUALQUER
  # StandardError — inclusive NoMethodError/contrato (bug de programação) — e
  # caía num fallback "sucesso" silencioso sem cookies. Erros de programação
  # DEVEM propagar. Aqui injetamos um NoMethodError DENTRO do bloco de cookies
  # e exigimos que suba (e que o fallback sem cookies NÃO seja chamado).
  test 'extract_videos_with_cookies propaga erro de programacao em vez de fallback silencioso' do
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).with('youtube.com', cookies: [{ 'name' => 'SID', 'value' => '123' }]).yields('/tmp/fake_cookies.txt')
    # Erro de programação (contrato quebrado), não de rede/parser/timeout:
    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: '/tmp/fake_cookies.txt'
    ).raises(NoMethodError.new('undefined method `parse\' for nil'))
    # O fallback sem cookies NÃO deve ocorrer:
    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: nil
    ).never

    assert_raises(NoMethodError) do
      ScrapeYoutubeJob.new.send(
        :extract_videos_with_cookies,
        'https://www.youtube.com/@test_channel',
        limit: 30,
        proxy: nil
      )
    end
  end

  test 'should set degraded status and enqueue ScrapingFailureAlertJob on StandardError' do
    # Item 1: perform abre a sessão de cookies ANTES do extract_channel_metadata.
    # Sem o stub de SessionCookies.for o real tenta CDP no chrome:9222 (o
    # WebMock bloqueia) e o StandardError real nunca chega no teste.
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt')
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    # O StandardError (yt-dlp não encontrado) é BUG/ambiente, NÃO é
    # recoverable-scraper: o helper extract_metadata_with_cookies NÃO rescató
    # StandardError (só Expired + RateLimitError), então sobe até o
    # rescue StandardError de perform, que marca 'degraded' + alerta scrape_error.
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).raises(StandardError.new('yt-dlp not found'))
    ScrapingFailureAlertJob.expects(:perform_later).with('youtube', @profile.id, 'yt-dlp not found', 'scrape_error')

    assert_nothing_raised do
      ScrapeYoutubeJob.perform_now(@profile.id)
    end

    @profile.reload
    assert_equal 'degraded', @profile.collection_status
  end

  test 'should set rate_limited status and blocked_until on RateLimitError' do
    # Item 1: mesmo pré-requisito — abrir a sessão antes do metadata.
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt')
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    # O helper de metadata PROPAGA o RateLimitError (rescue...raise), e o
    # perform rescatá-lo em rate_limited + blocked_until (retry com backoff).
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).raises(ScrapingServices::RateLimitError.new('429'))

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'rate_limited', @profile.collection_status
    assert_not_nil @profile.blocked_until
  end

  # Achado 13 — fallback de post_type morto e perigoso
  test 'post existente short nao e rebaixado para video quando deteccao e positiva para video (sem /shorts/ na URL)' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])

    existing_short = create(:social_post, social_profile: @profile, platform_post_id: 'short_vid', post_type: 'short')

    # parse_video_list sem /shorts/ na URL retorna post_type: 'video' (deteccao flaky)
    misdetected_video = {
      platform_post_id: 'short_vid',
      title: 'Short que perdeu deteccao',
      post_type: 'video',
      posted_at: 1.day.ago,
      views_count: 500,
      thumbnail_url: 'https://example.com/t.jpg',
      video_url: 'https://youtube.com/watch?v=short_vid'
    }

    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt').returns([[misdetected_video], false])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([[misdetected_video], false])

    ScrapeYoutubeJob.perform_now(@profile.id)

    existing_short.reload
    assert_equal 'short', existing_short.post_type,
      'post_type do short existente NAO deve ser sobrescrito por deteccao incorreta de video'
  end

  test 'should create post_snapshots with fixed TZ and prune snapshots older than 180 days' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt').returns([@videos, false])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([@videos, false])

    old_post = create(:social_post, social_profile: @profile)
    old_snapshot = create(:post_snapshot, social_post: old_post, recorded_at: 181.days.ago)

    assert_difference 'PostSnapshot.count', 1 do # 2 new post snapshots minus 1 deleted old snapshot = +1 net
      ScrapeYoutubeJob.perform_now(@profile.id)
    end

    refute PostSnapshot.exists?(old_snapshot.id)

    today = Time.current.in_time_zone("America/Sao_Paulo").beginning_of_day
    snapshot = PostSnapshot.where(recorded_at: today).first
    assert_not_nil snapshot
    assert_equal 1000, snapshot.views_count
  end

  # Achado 1+3 — build_channel_url deve priorizar channel ID canônico (case preservado)
  test 'build_channel_url usa /channel/ com case preservado quando platform_user_id é channel ID' do
    channel_id = 'UCn8SzhX6Z1qW9_123456789'
    profile = create(:social_profile, :youtube,
                     platform_username: channel_id,
                     platform_user_id: channel_id)

    assert_equal "https://www.youtube.com/channel/#{channel_id}",
                 ScrapeYoutubeJob.new.send(:build_channel_url, profile)
  end

  test 'build_channel_url usa /@handle/ quando platform_user_id não é channel ID' do
    profile = create(:social_profile, :youtube, platform_username: 'handle_nao_id', platform_user_id: 'UC123')

    assert_equal 'https://www.youtube.com/@handle_nao_id',
                 ScrapeYoutubeJob.new.send(:build_channel_url, profile)
  end

  # R2 — build_channel_url must check username FIRST when user_id is not
  # canonical, otherwise the real channel ID held in username is missed and
  # the scraper dies with a nil-metadata silent failure.
  test 'build_channel_url usa /channel/<username> quando platform_user_id nao e channel ID mas username e' do
    channel_id = 'UCn8SzhX6Z1qW9_123456789'
    profile = create(:social_profile, :youtube,
                     platform_username: channel_id,
                     platform_user_id: 'pending:youtube:abc123')

    assert_equal "https://www.youtube.com/channel/#{channel_id}",
                 ScrapeYoutubeJob.new.send(:build_channel_url, profile)
  end

  test 'build_channel_url cai em /channel/<user_id> quando user_id e channel ID e username e downcased (legado)' do
    channel_id = 'UCn8SzhX6Z1qW9_123456789'
    profile = create(:social_profile, :youtube,
                     platform_username: channel_id.downcase,
                     platform_user_id: channel_id)

    assert_equal "https://www.youtube.com/channel/#{channel_id}",
                 ScrapeYoutubeJob.new.send(:build_channel_url, profile)
  end

  test 'build_channel_url cai em /channel/ por platform_user_id quando username em branco' do
    profile = create(:social_profile, :youtube, platform_username: 'some_channel', platform_user_id: 'abc123')
    profile.update_columns(platform_username: '')

    assert_equal 'https://www.youtube.com/channel/abc123',
                 ScrapeYoutubeJob.new.send(:build_channel_url, profile)
  end

  test 'should raise RateLimitError and not fallback to no cookies when extract_videos_with_cookies raises RateLimitError' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt')
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)

    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: '/tmp/fake_cookies.txt'
    ).raises(ScrapingServices::RateLimitError.new('429 Too Many Requests'))

    ScrapingServices::YoutubeScraperService.expects(:extract_videos_detailed).with(
      'https://www.youtube.com/@test_channel',
      limit: 30,
      proxy: nil,
      cookies_path: nil
    ).never

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'rate_limited', @profile.collection_status
    assert_not_nil @profile.blocked_until
  end

  # ACHADO G: o teste antigo pré-criava o snapshot e chamava create_snapshot
  # com update normal — sem disparar RecordNotUnique nem concorrência. Aqui
  # forçamos o RecordNotUnique REAL: induzimos um INSERT que colide com o
  # registro já existente (simulando a corrida de upsert/concorrência). A
  # rotina deve resgatar o RecordNotUnique, reler o registro e atualizá-lo —
  # resultado final = 1 linha com os valores novos, sem duplicar nem perder.
  test 'create_snapshot trata RecordNotUnique real e atualiza o registro existente' do
    recorded_at = Time.current.beginning_of_hour

    s1 = ProfileSnapshot.create!(
      social_profile: @profile,
      recorded_at: recorded_at,
      followers_count: 50_000,
      posts_count: 100
    )

    # Fazemos o find_or_initialize_by retornar um objeto NOVO (não salvo) para
    # forçar o INSERT. Como s1 já ocupa a unique (social_profile_id,
    # recorded_at), esse INSERT colide de verdade e levanta
    # ActiveRecord::RecordNotUnique — exatamente a condição de corrida.
    ProfileSnapshot.stubs(:find_or_initialize_by).returns(
      ProfileSnapshot.new(social_profile: @profile, recorded_at: recorded_at)
    )

    ScrapeYoutubeJob.new.send(:create_snapshot, @profile, { subscriber_count: 60_000, video_count: 110 })

    snapshots = ProfileSnapshot.where(social_profile: @profile, recorded_at: recorded_at)
    assert_equal 1, snapshots.count, 'não deve duplicar o snapshot sob RecordNotUnique'
    assert_equal s1.id, snapshots.first.id, 'deve manter o mesmo registro'
    assert_equal 60_000, snapshots.first.followers_count
    assert_equal 110, snapshots.first.posts_count
  end

  # ACHADO C (P2, sol 13/08): o rescue StandardError é muito amplo —
  # NoMethodError/ArgumentError viravam fallback degradado "com sucesso".
  # Testamos pelo caminho PÚBLICO (extract_videos_with_cookies) — o contrato
  # real — em vez da unidade interna collect_with_cookies (estrutura unificada
  # com a PR #140).
  test 'extract_videos_with_cookies propaga NoMethodError em vez de fallback' do
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).with('youtube.com', cookies: [{ 'name' => 'SID', 'value' => '123' }]).yields('/tmp/fake_cookies.txt')
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed)
      .with('https://x', limit: 30, proxy: nil, cookies_path: '/tmp/fake_cookies.txt')
      .raises(NoMethodError.new('undefined method for nil'))

    assert_raises(NoMethodError) do
      ScrapeYoutubeJob.new.send(:extract_videos_with_cookies, 'https://x', limit: 30, proxy: nil)
    end
  end

  test 'extract_videos_with_cookies propaga ArgumentError em vez de fallback' do
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).with('youtube.com', cookies: [{ 'name' => 'SID', 'value' => '123' }]).yields('/tmp/fake_cookies.txt')
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed)
      .with('https://x', limit: 30, proxy: nil, cookies_path: '/tmp/fake_cookies.txt')
      .raises(ArgumentError.new('nil cipher'))

    assert_raises(ArgumentError) do
      ScrapeYoutubeJob.new.send(:extract_videos_with_cookies, 'https://x', limit: 30, proxy: nil)
    end
  end

  test 'extract_videos_with_cookies ainda cai no fallback sem cookies em erro conhecido de rede/parse' do
    # JSON::ParserError é erro de extração conhecido → continua elegível ao fallback.
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).with('youtube.com', cookies: [{ 'name' => 'SID', 'value' => '123' }]).yields('/tmp/fake_cookies.txt')
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed)
      .with('https://x', limit: 30, proxy: nil, cookies_path: '/tmp/fake_cookies.txt')
      .raises(JSON::ParserError.new('unexpected token'))
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed)
      .with('https://x', limit: 30, proxy: nil, cookies_path: nil)
      .returns([@videos, true])

    result = ScrapeYoutubeJob.new.send(:extract_videos_with_cookies, 'https://x', limit: 30, proxy: nil)

    assert_equal [@videos, true], result
  end

  test 'should resolve incident on full success' do
    AlertThrottler.consolidate_incident('youtube', @profile.id, 'partial_collection', 'fallback: sem dados')
    assert_not_nil AlertThrottler.incident_state('youtube', @profile.id)

    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(@metadata)
    Fetcher::SessionCookies.stubs(:for).with('youtube.com').returns([[{ 'name' => 'SID', 'value' => '123' }], :jar])
    Fetcher::CookieJar.stubs(:with_netscape_file).yields('/tmp/fake_cookies.txt').returns([@videos, false])
    Fetcher::CookieJar.stubs(:refresh_from_netscape!).returns(true)
    ScrapingServices::YoutubeScraperService.stubs(:extract_videos_detailed).returns([@videos, false])

    ScrapeYoutubeJob.perform_now(@profile.id)

    @profile.reload
    assert_equal 'success', @profile.collection_status
    assert_nil AlertThrottler.incident_state('youtube', @profile.id), 'sucesso na coleta deve limpar o estado do incidente'
  end
end

