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
end
