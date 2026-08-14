# frozen_string_literal: true

require "test_helper"
require "open3"

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
    stderr_da_falha = "ERROR: [youtube] Could not extract data: Sign in to confirm you're not a bot"
    falha = stub(success?: false, exitstatus: 1)

    # Substitui o yt-dlp real (sem rede) por uma falha controlada com stderr.
    Open3.stubs(:capture3).returns(["", stderr_da_falha, falha])

    logged = +""
    Rails.logger.expects(:error).at_least_once.with do |msg|
      logged << msg.to_s
      true
    end

    # extract_videos_detailed chama o caminho detalhado (videos) que falha e
    # cai no flat (que também falha com o stub) — o ponto é que o stderr da
    # falha do yt-dlp tem que aparecer no log.
    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      "https://www.youtube.com/channel/UCtest", limit: 1
    )

    assert logged.include?(stderr_da_falha),
           "stderr do yt-dlp NÃO foi registrado no log (registrado: #{logged.inspect})"
    assert_equal [[], true], result
  end

  # Regressão do MENOR 3: o ramo de SUCESSO com stderr não-vazio também deve
  # ser registrado (via Rails.logger.warn). Hoje só o ramo de falha era
  # testado. Casos reais: "cookies are no longer valid" vem como WARNING mesmo
  # com exit 0.
  test 'execute_yt_dlp registra stderr via warn quando comando termina com sucesso (exit 0) e stderr não-vazio' do
    # stderr de 2500 chars exercita também o truncamento (~2000) no ramo warn.
    stderr_aviso = 'WARNING: [youtube] cookies are no longer valid ' + ('y' * 2443)
    sucesso = stub(success?: true, exitstatus: 0)

    Open3.stubs(:capture3).returns(["some output", stderr_aviso, sucesso])

    warned = +""
    Rails.logger.expects(:warn).at_least_once.with do |msg|
      warned << msg.to_s
      true
    end
    Rails.logger.expects(:error).never

    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      "https://www.youtube.com/channel/UCtest", limit: 1
    )

    assert warned.include?(stderr_aviso[0, 2000]),
           "stderr do yt-dlp (sucesso c/ aviso) NÃO foi registrado via warn (registrado: #{warned.inspect})"
    refute warned.include?('y' * 2001),
           "stderr no ramo warn NÃO foi truncado a ~2000 chars"
    assert_equal [[], false], result
  end

  # Regressão do MENOR 4: o stderr logado (warn OU error) deve ser truncado a
  # ~2000 chars — o yt-dlp despeja URLs/progresso que enchem o log. Aqui no
  # ramo de FALHA (Rails.logger.error), com stderr de 3000 chars.
  test 'execute_yt_dlp trunca stderr logado a ~2000 chars no ramo de falha' do
    long_stderr = 'x' * 3000
    falha = stub(success?: false, exitstatus: 1)

    Open3.stubs(:capture3).returns(["", long_stderr, falha])

    logged = +""
    Rails.logger.expects(:error).at_least_once.with do |msg|
      logged << msg.to_s
      true
    end

    result = ScrapingServices::YoutubeScraperService.extract_videos_detailed(
      "https://www.youtube.com/channel/UCtest", limit: 1
    )

    assert logged.include?('x' * 2000),
           "stderr truncado não preserva os primeiros 2000 chars (logado: #{logged[0, 80].inspect}...)"
    refute logged.include?('x' * 2001),
           "stderr NÃO foi truncado a 2000 chars (vazou o char 2001+)"

    assert_equal [[], true], result
  end
end
