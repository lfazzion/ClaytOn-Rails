# frozen_string_literal: true

require 'test_helper'

class YoutubeScraperServiceTest < ActiveSupport::TestCase
  # TDD — garante que o stderr do yt-dlp NÃO seja descartado.
  #
  # Incidente 14/08: ScrapeYoutubeJob caiu no fallback flat-playlist para os
  # perfis 5/3/8 e disparou ScrapingFailureAlertJob("partial_collection"),
  # mas execute_yt_dlp fazia `output, _, status = Open3.capture3(*cmd)` e jogava
  # o stderr fora — então não havia NENHUMA pista do motivo (extrator
  # JS/deno, bot-check, rate-limit, DOM mudou) no log. O diagnóstico depende
  # exatamente desse stderr.
  #
  # Contrato: em falha do yt-dlp, o stderr deve ser registrado via
  # Rails.logger.error para que o próximo fallback seja diagnosticável.
  test 'execute_yt_dlp registra o stderr do yt-dlp quando o comando falha' do
    stderr_da_falha = 'ERROR: [youtube] Could not extract data: Sign in to confirm you\'re not a bot'
    falha = stub(success?: false, exitstatus: 1)

    # Substitui o yt-dlp real (sem rede) por uma falha controlada com stderr.
    Open3.stubs(:capture3).returns(['', stderr_da_falha, falha])

    logged = +''
    Rails.logger.expects(:error).at_least_once.with do |msg|
      logged << msg.to_s
      true
    end

    # extract_videos_detailed chama o caminho detalhado (videos) que falha e
    # cai no flat (que também falha com o stub) — o ponto é que o stderr da
    # falha do yt-dlp tem que aparecer no log.
    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      'https://www.youtube.com/channel/UCtest', limit: 1
    )

    assert logged.include?(stderr_da_falha),
           "stderr do yt-dlp NÃO foi registrado no log (registrado: #{logged.inspect})"
    assert_equal [[], false, "bot_check"], result
  end

  # Regressão do MENOR 3: o ramo de SUCESSO com stderr não-vazio também deve
  # ser registrado (via Rails.logger.warn). Hoje só o ramo de falha era
  # testado. Casos reais: 'cookies are no longer valid' vem como WARNING mesmo
  # com exit 0.
  test 'execute_yt_dlp registra stderr via warn quando comando termina com sucesso (exit 0) e stderr não-vazio' do
    # stderr de 2500 chars exercita também o truncamento (~2000) no ramo warn.
    stderr_aviso = 'WARNING: [youtube] cookies are no longer valid ' + ('y' * 2443)
    sucesso = stub(success?: true, exitstatus: 0)

    Open3.stubs(:capture3).returns(['some output', stderr_aviso, sucesso])

    warned = +''
    Rails.logger.expects(:warn).at_least_once.with do |msg|
      warned << msg.to_s
      true
    end
    Rails.logger.expects(:error).never

    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      'https://www.youtube.com/channel/UCtest', limit: 1
    )

    assert warned.include?(stderr_aviso[0, 2000]),
           'stderr do yt-dlp (sucesso c/ aviso) NÃO foi registrado via warn (registrado: #{warned.inspect})'
    refute warned.include?('y' * 2001),
           'stderr no ramo warn NÃO foi truncado a ~2000 chars'
    assert_equal [[], false, nil], result
  end

  # Regressão do MENOR 4: o stderr logado (warn OU error) deve ser truncado a
  # ~2000 chars — o yt-dlp despeja URLs/progresso que enchem o log. Aqui no
  # ramo de FALHA (Rails.logger.error), com stderr de 3000 chars.
  test 'execute_yt_dlp trunca stderr logado a ~2000 chars no ramo de falha' do
    long_stderr = 'x' * 3000
    falha = stub(success?: false, exitstatus: 1)

    Open3.stubs(:capture3).returns(['', long_stderr, falha])

    logged = +''
    Rails.logger.expects(:error).at_least_once.with do |msg|
      logged << msg.to_s
      true
    end

    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      'https://www.youtube.com/channel/UCtest', limit: 1
    )

    assert logged.include?('x' * 2000),
           'stderr truncado não preserva os primeiros 2000 chars (logado: #{logged[0, 80].inspect}...)'
    refute logged.include?('x' * 2001),
           'stderr NÃO foi truncado a 2000 chars (vazou o char 2001+)'
    assert_equal [[], false, 'unknown'], result
  end

  # ITEM 4 (regra de fallback) — prova END-TO-END em extract_videos_detailed,
  # não só na classificação: bot_check DEVOLVE run vazio nomeado e NÃO chama
  # o flat-playlist (o bloqueio de bot piora sem cookie); session_rejected
  # PODE cair no fallback sem-cookie.
  test 'bot_check não cai no fallback sem-cookie (run parcial nomeado, flat não é chamado)' do
    falha_bot = stub(success?: false, exitstatus: 1)
    # Detalhado /videos falha com bot-check; o flat (que exigiria cookie bom)
    # NUNCA é chamado — ele devolve o run vazio já nomeado.
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp)
      .with { |cmd| !cmd.include?("--flat-playlist") }
      .returns(["", "ERROR: [youtube] Sign in to confirm you're not a bot", falha_bot])
    ScrapingServices::YoutubeScraperService.expects(:extract_videos_flat).never

    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      "https://www.youtube.com/channel/UCtest", limit: 1
    )

    assert_equal [[], false, "bot_check"], result,
                 "bot_check deve devolver run vazio, sem fallback, com a causa nomeada"
  end

  test 'session_rejected cai no fallback sem-cookie (run flat com a causa nomeada)' do
    ok = stub(success?: true, exitstatus: 0)
    falha_sessao = stub(success?: false, exitstatus: 1)
    flat_json = "{\"id\":\"fv1\",\"title\":\"FV1\",\"webpage_url\":\"https://youtube.com/watch?v=fv1\"}\n"

    # Detalhado /videos falha com cookie inválido → fallback flat-playlist SEM
    # cookie devolve os itens e propaga a causa session_rejected.
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp)
      .with { |cmd| !cmd.include?("--flat-playlist") }
      .returns(["", "ERROR: [youtube] cookies are no longer valid", falha_sessao])
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp)
      .with { |cmd| cmd.include?("--flat-playlist") }
      .returns([flat_json, "", ok])

    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      "https://www.youtube.com/channel/UCtest", limit: 1
    )

    videos, fallback, cause = result
    assert fallback, "session_rejected deve ter caído no fallback flat-playlist"
    assert_equal "session_rejected", cause, "a causa deve ser propagada mesmo no fallback"
    assert_equal 1, videos.size, "o fallback flat deve ter devolvido os itens"
  end

  # TDD — build_metadata_command deve aceitar cookies_path e propagá-lo ao
  # comando de metadata.
  test 'build_metadata_command inclui --cookies quando cookies_path é informado' do
    cmd = ScrapingServices::YoutubeScraperService.send(
      :build_metadata_command,
      'https://www.youtube.com/channel/UC123',
      nil,
      cookies_path: '/tmp/cookies.txt'
    )

    assert_includes cmd, '--cookies'
    assert_includes cmd, '/tmp/cookies.txt'
  end

  test 'extract_channel_metadata repassa cookies_path para build_metadata_command' do
    fake_status = Struct.new(:success?).new(true)
    json_output = '{"channel_id":"UC123","channel":"Canal","channel_follower_count":10,"description":"x","thumbnails":[]}'
    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp).returns([json_output, '', fake_status])

    ScrapingServices::YoutubeScraperService.extract_channel_metadata(
      'https://www.youtube.com/channel/UC123',
      proxy: nil,
      cookies_path: '/tmp/cookies.txt'
    )

    cmd = ScrapingServices::YoutubeScraperService.send(
      :build_metadata_command,
      'https://www.youtube.com/channel/UC123',
      nil,
      cookies_path: '/tmp/cookies.txt'
    )
    assert_includes cmd, '--cookies'
    assert_includes cmd, '/tmp/cookies.txt'
  end

  # TDD — sem cookies_path, o comando de metadata não deve inventar cookie.
  test 'build_metadata_command não inclui --cookies quando cookies_path é nil' do
    cmd = ScrapingServices::YoutubeScraperService.send(
      :build_metadata_command,
      'https://www.youtube.com/channel/UC123',
      nil,
      cookies_path: nil
    )

    refute_includes cmd, '--cookies'
  end

  # Causa estruturada: mapeia stderr conhecido para causa nomeada.
  test 'classifica causa bot_check a partir do stderr do yt-dlp' do
    cause, = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      'Sign in to confirm you\'re not a bot'
    )

    assert_equal 'bot_check', cause
  end

  test 'classifica causa members_only a partir do stderr do yt-dlp' do
    cause, = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      'This channel has member-only content'
    )

    assert_equal 'members_only', cause
  end

  test 'classifica causa timeout a partir do stderr do yt-dlp' do
    cause, = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      'Read timed out'
    )

    assert_equal 'timeout', cause
  end

  test 'classifica causa network a partir do stderr do yt-dlp' do
    cause, = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      'Connection reset by peer'
    )

    assert_equal 'network', cause
  end

  test 'classifica causa session_rejected para cookie inválido explícito' do
    cause, = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      'cookies are no longer valid'
    )

    assert_equal 'session_rejected', cause
  end

  test 'fallback sem cookie é permitido quando a causa é session_rejected' do
    cause, details = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      'cookies are no longer valid'
    )

    assert_equal 'session_rejected', cause
    assert_equal true, details[:no_cookie_fallback_allowed?]
  end

  test 'fallback sem cookie NÃO é permitido para causas não-session_rejected' do
    %w[bot_check members_only timeout network unknown].each do |cause|
      _, details = ScrapingServices::YoutubeScraperService.send(
        :classify_failure_cause,
        '',
        "stderr genérico para #{cause}"
      )

      assert_equal false, details[:no_cookie_fallback_allowed?],
                   "causa #{cause} não deveria permitir fallback sem cookie"
    end
  end

  test 'extract_channel_metadata passa cookies_path para build_metadata_command' do
    fake_status = Struct.new(:success?).new(true)
    json_output = '{"channel_id":"UC123","channel":"Canal","channel_follower_count":10,"description":"x","thumbnails":[]}'

    ScrapingServices::YoutubeScraperService.stubs(:execute_yt_dlp).returns([json_output, '', fake_status])

    ScrapingServices::YoutubeScraperService.extract_channel_metadata(
      'https://www.youtube.com/channel/UC123',
      proxy: nil,
      cookies_path: '/tmp/cookies.txt'
    )

    assert ScrapingServices::YoutubeScraperService.send(:build_metadata_command, 'https://www.youtube.com/channel/UC123', nil, cookies_path: '/tmp/cookies.txt').include?('--cookies')
  end
end
