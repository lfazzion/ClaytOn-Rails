# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'shellwords'
require 'tmpdir'

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

  # B4 — prova TÍPADA da transição sem cookie. Os DOIS caminhos de sessão
  # rejeitada passam por UM único ponto de transição por lado — serviço:
  # SessionRejected (texto-inferido no stderr) deságua em
  # transition_without_cookie; job: Fetcher::CookieJar::Expired é resgatada no
  # helper (lado job, medido em test/jobs/scrape_youtube_job_test.rb "B4 (job)").
  # É pelo TIPO da prova que a transição é auditável — nunca por string solta
  # em dois lugares. O negativo (outra causa NUNCA abre coleta sem cookie) é
  # medido pelo teste "bot_check não cai no fallback sem-cookie" acima.
  test 'B4: SessionRejected abre o ÚNICO ponto de transição (folha flat recebe cookies_path: nil, uma vez)' do
    svc = ScrapingServices::YoutubeScraperService
    falha = stub(success?: false, exitstatus: 1)
    flat_item = {
      platform_post_id: 'fv1', title: 'FV1', post_type: 'video', posted_at: nil,
      views_count: nil, likes_count: nil, comments_count: nil,
      thumbnail_url: nil, video_url: 'https://youtube.com/watch?v=fv1'
    }

    # O caminho detalhado /videos falha com a sessão rejeitada (a causa
    # inferida do stderr; o resgate do serviço levanta a prova TÍPADA).
    svc.stubs(:execute_yt_dlp)
      .with { |cmd| !cmd.include?("--flat-playlist") }
      .returns(["", "ERROR: [youtube] cookies are no longer valid", falha])

    # A FOLHA da transição: é ela quem recebe cookies_path: nil — e só a
    # transition_without_cookie a chama assim. O .with fixa a assinatura
    # exata (limit/proxy/cookies_path: nil); se qualquer outro ponto abrir
    # coleta sem cookie, a expectativa de 1 chamada com esses args falha.
    svc.expects(:extract_videos_flat)
      .with('https://www.youtube.com/channel/UCtest', limit: 1, proxy: nil, cookies_path: nil)
      .returns([flat_item])

    result = svc.extract_videos_detailed('https://www.youtube.com/channel/UCtest', limit: 1)

    assert_equal [[flat_item], true, 'session_rejected'], result,
                 'a transição devolve o parcial flat com a causa nomeada'
  end

  # B6 — casos adversariais do classificador: as entradas que o padrão antigo
  # (`include?("bot")` + prefixo `sign in to confirm`) capturava por engano.
  test 'B6: "sign in to confirm your age" NÃO é bot_check (cai em unknown)' do
    cause, = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      "ERROR: please sign in to confirm your age"
    )

    refute_equal 'bot_check', cause, '"confirm your age" não é frase de anti-bot'
    assert_equal 'unknown', cause
  end

  test 'B6: palavras com "bot" que não são anti-bot (robot/hobbit) NÃO são bot_check' do
    casos = [
      'ERROR: [youtube] robot detection unavailable',
      'ERROR: [youtube] hobbit quest interrupted'
    ]
    casos.each do |msg|
      cause, = ScrapingServices::YoutubeScraperService.send(:classify_failure_cause, '', msg)
      refute_equal 'bot_check', cause, "#{msg.inspect} não é frase de anti-bot"
      assert_equal 'unknown', cause
    end
  end

  test 'B6: "members-only" (plural hifenizado) vira members_only' do
    cause, = ScrapingServices::YoutubeScraperService.send(
      :classify_failure_cause,
      '',
      'ERROR: [youtube] This channel has members-only content'
    )

    assert_equal 'members_only', cause
  end

  # B7 — Timeout::Error e erros de REDE que escalam do execute_yt_dlp (o
  # subprocess expõe Errno/Socket) viram causa NOMEADA — o rescue genérico
  # de StandardError os converteria em 'unknown'.
  test 'B7: Timeout::Error do execute_yt_dlp vira causa "timeout" (não "unknown")' do
    svc = ScrapingServices::YoutubeScraperService
    svc.stubs(:execute_yt_dlp).raises(Timeout::Error.new('execution expired'))

    result = svc.extract_videos_detailed('https://www.youtube.com/channel/UCtest', limit: 1)

    assert_equal [[], false, 'timeout'], result
  end

  test 'B7: erro de rede (ECONNRESET) do execute_yt_dlp vira causa "network" (não "unknown")' do
    svc = ScrapingServices::YoutubeScraperService
    svc.stubs(:execute_yt_dlp).raises(Errno::ECONNRESET.new('connection reset by peer'))

    result = svc.extract_videos_detailed('https://www.youtube.com/channel/UCtest', limit: 1)

    assert_equal [[], false, 'network'], result
  end

  test 'B7: SocketError do execute_yt_dlp vira causa "network" (não "unknown")' do
    svc = ScrapingServices::YoutubeScraperService
    svc.stubs(:execute_yt_dlp).raises(SocketError.new('getaddrinfo: Name or service not known'))

    result = svc.extract_videos_detailed('https://www.youtube.com/channel/UCtest', limit: 1)

    assert_equal [[], false, 'network'], result
  end

  # B8b/B8 — /shorts é ENRIQUECIMENTO. As DUAS fixtures foram separadas (a
  # antiga mesclava e CRISTALIZAVA o falso sucesso que B8 eliminava):
  #   * FIXTURE A — aba ausente/vazia BEM-SUCEDIDA: exit 0 e saída vazia.
  #     Ausência comprovada (canal sem a aba /shorts) → segue sucesso, causa
  #     nil. É a ÚNICA situação que devolve causa nil.
  #   * FIXTURE B — falha operacional DESCONHECIDA: exit 1 com stderr que não
  #     casa nenhum padrão ('unable to extract data'). Vira PARCIAL nomeado
  #     'unknown' — nunca mais "success" silencioso.
  # Justificativa da correção (B9): o teste antigo usava exit 1 + 'ERROR:
  # [youtube] unable to extract data' rotulado "aba ausente/vazia" e exigia
  # causa nil — codificava exatamente o falso sucesso que o bloqueador 8
  # existia para eliminar; agora a fixture de falha espera 'unknown'.
  test 'B8b: /shorts ausente/vazia BEM-SUCEDIDA (exit 0, saída vazia) segue sucesso com causa nil' do
    svc = ScrapingServices::YoutubeScraperService
    fake_ok = stub(success?: true, exitstatus: 0)
    videos_json = "{\"id\":\"v1\",\"title\":\"V1\",\"webpage_url\":\"https://youtube.com/watch?v=v1\"}\n" \
                  "{\"id\":\"v2\",\"title\":\"V2\",\"webpage_url\":\"https://youtube.com/watch?v=v2\"}\n"

    svc.stubs(:build_videos_command).returns(['yt-dlp', 'vdetail'])
    svc.stubs(:build_shorts_command).returns(['yt-dlp', 'sdetail'])
    svc.stubs(:execute_yt_dlp).with(['yt-dlp', 'vdetail']).returns([videos_json, '', fake_ok])
    svc.stubs(:execute_yt_dlp).with(['yt-dlp', 'sdetail']).returns(['', '', fake_ok])

    videos, fallback, cause = svc.extract_videos_detailed('https://www.youtube.com/@TeGeCe', limit: 3)

    assert_equal 2, videos.size, '/videos segue valendo quando /shorts é ausente (sucesso com saída vazia)'
    refute fallback
    assert_nil cause, 'ausência inocente de /shorts comprovada pelo exit 0 NÃO degrada o run (sucesso, causa nil)'
  end

  test 'B8b: falha OPERACIONAL em /shorts com stderr não reconhecido vira parcial com causa unknown' do
    svc = ScrapingServices::YoutubeScraperService
    fake_ok = stub(success?: true, exitstatus: 0)
    fake_fail = stub(success?: false, exitstatus: 1)
    videos_json = "{\"id\":\"v1\",\"title\":\"V1\",\"webpage_url\":\"https://youtube.com/watch?v=v1\"}\n" \
                  "{\"id\":\"v2\",\"title\":\"V2\",\"webpage_url\":\"https://youtube.com/watch?v=v2\"}\n"

    svc.stubs(:build_videos_command).returns(['yt-dlp', 'vdetail'])
    svc.stubs(:build_shorts_command).returns(['yt-dlp', 'sdetail'])
    svc.stubs(:execute_yt_dlp).with(['yt-dlp', 'vdetail']).returns([videos_json, '', fake_ok])
    svc.stubs(:execute_yt_dlp).with(['yt-dlp', 'sdetail']).returns(['', 'ERROR: [youtube] unable to extract data', fake_fail])

    videos, fallback, cause = svc.extract_videos_detailed('https://www.youtube.com/@TeGeCe', limit: 3)

    assert_equal 2, videos.size, '/videos segue valendo na falha operacional do /shorts'
    refute fallback, 'o run NÃO cai em fallback flat: é um PARCIAL nomeado'
    assert_equal 'unknown', cause,
                 'falha (exit 1) com stderr não reconhecido é parcial NOMEADO unknown — nunca "success" com causa nil'
  end

  # B10 — o canário (bin/canario-youtube.sh) tem de classificar com a MESMA
  # fonte única do serviço (lib/scraping/failure_cause_classify.rb). O
  # classificador em bash do canário antigo reimplementava os padrões e
  # divergiu ("sign in to confirm"||"bot" sem fronteiras batia em
  # "confirm your age"/"robot"; "members-only" hifenizado não era
  # reconhecido) — o artefato de diagnóstico reportava falsos bot_check e
  # perdia members_only. Este teste extrai a função classify_cause do
  # canário e a roda na MESMA bateria do classify_failure_cause do serviço;
  # qualquer divergência volta a travar aqui.
  test 'B10: canário classifica idêntico ao serviço (bateria da fonte única)' do
    # Este teste vive em test/lib/scraping/services/ → a raiz do repo está
    # 4 níveis acima (__dir__ = .../test/lib/scraping/services).
    root = File.expand_path('../../../..', __dir__)
    canario_sh = File.join(root, 'bin/canario-youtube.sh')
    module_rb = File.join(root, 'lib/scraping/failure_cause_classify.rb')
    assert File.exist?(canario_sh), "canário ausente: #{canario_sh}"
    assert File.exist?(module_rb), "fonte única ausente: #{module_rb}"

    fn = File.read(canario_sh)[/^classify_cause\(\) \{.*?^\}/m]
    refute_nil fn, 'não consegui extrair classify_cause() do canário (a função deve permanecer autocontida)'

    # As 5 entradas que o revisor assinalou + timeout/rede/sessão para
    # pinar o classificador inteiro. Cada caso: [entrada, causa esperada].
    bateria = [
      ['sign in to confirm your age', 'unknown'],
      ['robot', 'unknown'],
      ['hobbit', 'unknown'],
      ['members-only', 'members_only'],
      ["Sign in to confirm you're not a bot", 'bot_check'],
      ['Read timed out while connecting', 'timeout'],
      ['connection reset by peer', 'network'],
      ['cookies are no longer valid', 'session_rejected']
    ]

    Dir.mktmpdir do |dir|
      battery_file = File.join(dir, 'battery.txt')
      script_file = File.join(dir, 'driver.sh')
      File.write(battery_file, bateria.map { |m, _| m }.join("\n") + "\n")

      # Driver: injeta a função extraída do canário + laço que alimenta
      # stderr/stdout por entrada e imprime "entrada => causa".
      # Nota: `fn` termina em "}" SEM quebra de linha — separo com "\n" explícito,
      # senão cola em "}battery_file=" (syntax error medido no 1º run).
      driver = +"#!/usr/bin/env bash\nset -euo pipefail\n"
      driver << fn
      driver << "\n"
      driver << <<~'EOS'
        battery_file="$1"
        dir_err="$(mktemp)"
        dir_out="$(mktemp)"
        trap 'rm -f "$dir_err" "$dir_out"' EXIT
        while IFS= read -r input; do
          [ -z "$input" ] && continue
          printf '%s' "$input" > "$dir_err"
          : > "$dir_out"
          cause="$(classify_cause "$dir_err" "$dir_out")"
          printf '%s => %s\n' "$input" "$cause"
        done < "$battery_file"
      EOS
      File.write(script_file, driver)

      out, err, status = Open3.capture3(
        "CANARY_CLASSIFIER=#{Shellwords.escape(module_rb)} bash #{Shellwords.escape(script_file)} #{Shellwords.escape(battery_file)}"
      )
      assert status.success?, "driver do canário (fonte única) falhou:\n#{err}\n#{out}"

      # O canário escreve '-' para causa inexistente; o serviço escreve
      # 'unknown'. Normaliza para comparar (o contrato da tabela é '-').
      canario = out.each_line.map { |l| l.chomp.split(' => ', 2) }.to_h

      # B10-guarda: força o CAMINHO EMBUTIDO do canário (CANARY_CLASSIFIER
      # apontando para módulo inexistente) e mede a MESMA bateria — a cópia
      # embutida no bash tem de se sincronizar com a fonte única.
      out2, err2, status2 = Open3.capture3(
        "CANARY_CLASSIFIER=/nonexistent-module.rb bash #{Shellwords.escape(script_file)} #{Shellwords.escape(battery_file)}"
      )
      assert status2.success?, "driver do canário (cópia embutida) falhou:\n#{err2}\n#{out2}"
      canario_embutido = out2.each_line.map { |l| l.chomp.split(' => ', 2) }.to_h

      divergencias = []
      bateria.each do |input, esp|
        servico, = ScrapingServices::YoutubeScraperService.send(:classify_failure_cause, input, '')
        divergencias << "serviço: #{input.inspect} → espere #{esp}, obteve #{servico.inspect}" unless servico == esp

        esperada_canario = esp == 'unknown' ? '-' : esp
        obteve = canario[input]
        divergencias << "canário (fonte única): #{input.inspect} → espere #{esperada_canario.inspect}, obteve #{obteve.inspect}" unless obteve == esperada_canario

        obteve_emb = canario_embutido[input]
        divergencias << "canário (cópia embutida): #{input.inspect} → espere #{esperada_canario.inspect}, obteve #{obteve_emb.inspect}" unless obteve_emb == esperada_canario
      end
      assert_equal [], divergencias,
                   "bateria diverge entre canário e serviço:\n#{divergencias.join("\n")}"
    end
  end

  test 'B8b: falha operacional em /shorts vira parcial nomeado com a causa do /shorts' do
    svc = ScrapingServices::YoutubeScraperService
    fake_ok = stub(success?: true, exitstatus: 0)
    fake_fail = stub(success?: false, exitstatus: 1)
    videos_json = "{\"id\":\"v1\",\"title\":\"V1\",\"webpage_url\":\"https://youtube.com/watch?v=v1\"}\n" \
                  "{\"id\":\"v2\",\"title\":\"V2\",\"webpage_url\":\"https://youtube.com/watch?v=v2\"}\n"

    svc.stubs(:build_videos_command).returns(['yt-dlp', 'vdetail'])
    svc.stubs(:build_shorts_command).returns(['yt-dlp', 'sdetail'])
    svc.stubs(:execute_yt_dlp).with(['yt-dlp', 'vdetail']).returns([videos_json, '', fake_ok])
    svc.stubs(:execute_yt_dlp).with(['yt-dlp', 'sdetail']).returns(['', "ERROR: [youtube] Sign in to confirm you're not a bot", fake_fail])

    videos, fallback, cause = svc.extract_videos_detailed('https://www.youtube.com/@TeGeCe', limit: 3)

    assert_equal 2, videos.size, '/videos segue valendo na falha operacional do /shorts'
    refute fallback, 'o run NÃO cai em fallback flat: é um PARCIAL nomeado'
    assert_equal 'bot_check', cause, 'falha OPERACIONAL do /shorts NUNCA vira "success" silencioso'
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

  test 'B2/ressalva: fallback sem-cookie só é permitido p/ session_rejected (stderr realista)' do
    # Ressalva: o teste antigo constrói strings genéricas ("stderr genérico
    # para X") e só checa o booleano. Aqui cada caso usa um stderr REALISTA
    # e afirma a causa esperada E a permissão de fallback (as duas faces da
    # invariante: só sessão rejeitada libera coleta sem-cookie).
    casos = [
      ["ERROR: [youtube] Sign in to confirm you're not a bot", "bot_check", false],
      ["This channel has members-only content", "members_only", false],
      ["Read timed out while connecting", "timeout", false],
      ["connection reset by peer", "network", false],
      ["unexpected token in JSON", "unknown", false],
      ["ERROR: [youtube] cookies are no longer valid", "session_rejected", true]
    ]
    casos.each do |stderr, causa_esperada, fallback_ok|
      causa, details = ScrapingServices::YoutubeScraperService.send(:classify_failure_cause, stderr, '')
      assert_equal causa_esperada, causa,
                   "stderr #{stderr.inspect} deve classificar #{causa_esperada} (obteve #{causa.inspect})"
      assert_equal fallback_ok, details[:no_cookie_fallback_allowed?],
                   "causa #{causa} → fallback permitido? #{fallback_ok} (obteve #{details[:no_cookie_fallback_allowed?]})"
    end
  end

  # Ressalva-3 (consolida as antigas L156-175 x L264-277): UMA única
  # cobertura de cookies_path — a que captura o comando REALMENTE ENTREGUE
  # a execute_yt_dlp (espionado no método). Os testes antigos só
  # reconstruíam o comando (falso-green: passavam até se o build mudasse,
  # sem medir o que execute_yt_dlp recebeu de fato).
  test 'extract_channel_metadata entrega --cookies ao execute_yt_dlp quando cookies_path é informado' do
    svc = ScrapingServices::YoutubeScraperService
    fake_status = Struct.new(:success?).new(true)
    json_output = '{"channel_id":"UC123","channel":"Canal","channel_follower_count":10,"description":"x","thumbnails":[]}'
    captured = []

    svc.stubs(:execute_yt_dlp).with { |cmd, **opts| captured << cmd; true }.returns([json_output, '', fake_status])

    svc.extract_channel_metadata(
      'https://www.youtube.com/channel/UC123',
      proxy: nil,
      cookies_path: '/tmp/cookies.txt'
    )

    assert_equal 1, captured.size, 'execute_yt_dlp deve ser chamado exatamente uma vez'
    cmd = captured.first
    cookies_idx = cmd.index('--cookies')
    assert_not_nil cookies_idx, 'o comando entregue a execute_yt_dlp deve incluir --cookies'
    assert_equal '/tmp/cookies.txt', cmd[cookies_idx + 1], 'o valor do jar é o cookies_path informado'
  end
end

