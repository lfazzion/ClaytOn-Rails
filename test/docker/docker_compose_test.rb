require "test_helper"
require "yaml"

class DockerComposeTest < ActiveSupport::TestCase
  DOCKER_COMPOSE_PATH = Rails.root.join("docker", "docker-compose.yml")

  test "docker-compose.yml should exist" do
    assert File.exist?(DOCKER_COMPOSE_PATH), "docker-compose.yml not found"
  end

  test "docker-compose.yml should be valid YAML" do
    assert_nothing_raised do
      YAML.load_file(DOCKER_COMPOSE_PATH)
    end
  end

  test "should have required services" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    services = config["services"]

    assert services.key?("app"), "app service not found"
    assert services.key?("jobs"), "jobs service not found"
    assert services.key?("chrome"), "chrome service not found"
  end

  test "app service should have correct configuration" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    app = config["services"]["app"]

    assert_includes app["command"], "rails server"
    assert_includes app["networks"], "internal"
    # Loopback: /internal/extract não pode ficar exposto em 0.0.0.0 com o
    # firewall do host como única camada.
    assert_equal "127.0.0.1:3000:3000", app["ports"].first
  end

  test "no service should publish a port outside the loopback" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    config["services"].each do |name, service|
      Array(service["ports"]).each do |mapping|
        assert_match(/\A127\.0\.0\.1:/, mapping.to_s,
                     "#{name} publica #{mapping} fora do loopback")
      end
    end
  end

  test "python-scraper healthcheck validates full readiness (HTTP status)" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    sidecar = config["services"]["python-scraper"]

    assert sidecar, "python-scraper service not found"
    assert sidecar["healthcheck"], "sidecar precisa de healthcheck do /health"

    # O healthcheck deve não apenas tocar /health, mas validar o STATUS HTTP.
    # urllib.request.urlopen levanta HTTPError em 4xx/5xx — um 503 (dependência
    # ausente) faz o healthcheck falhar, garantindo que o container não fique
    # "healthy" com scraping engine quebrado.
    healthcheck_cmd = sidecar["healthcheck"]["test"].join(" ")
    assert_includes healthcheck_cmd, "/health"
    assert_match(/urllib/, healthcheck_cmd,
                 "healthcheck deve usar urllib (levanta HTTPError em 503)")
  end

  test "python-scraper healthcheck covers dependency-absent scenario" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    sidecar = config["services"]["python-scraper"]

    assert sidecar, "python-scraper service not found"
    healthcheck = sidecar["healthcheck"]
    assert healthcheck, "sidecar precisa de healthcheck do /health"

    # O server.py valida scripts e imports na inicialização; o /health responde
    # 503 quando algo falta. O healthcheck do docker-compose deve propagar essa
    # falha (não a mascarar). Opcionalmente, pode usar --fail-with-body ou
    # equivalente para assertar 200; aqui garantimos que o teste não usa
    # `--fail` sem validação de status, que aceitaria 503.
    cmd_str = healthcheck["test"].join(" ")
    # Não deve usar `|| exit 0` ou equivalente que mascare 503.
    refute_includes cmd_str, "|| exit 0",
                    "healthcheck não deve mascara 503 com '|| exit 0'"
    refute_includes cmd_str, "|| true",
                    "healthcheck não deve mascara 503 com '|| true'"
    # A URL /health deve aparecer integralmente.
    assert_match(%r{/health}, cmd_str)
  end

  test "python-scraper should serve the HTTP API and stay off the host network" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    sidecar = config["services"]["python-scraper"]

    assert sidecar, "python-scraper service not found"
    assert_nil sidecar["ports"], "sidecar não deve publicar porta no host"
    assert sidecar["healthcheck"], "sidecar precisa de healthcheck do /health"
    assert_includes sidecar["healthcheck"]["test"].join(" "), "/health"
    assert_includes sidecar["networks"], "internal"
    assert_not_includes Array(sidecar["networks"]), "browser",
                        "o container de maior exposição do stack não pode alcançar o CDP"
  end

  test "python-scraper must not load the shared .env" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    # env_file pode ser string ou hash com path/required — o path e o que importa.
    env_files = Array(config["services"]["python-scraper"]["env_file"]).map do |e|
      e.is_a?(Hash) ? e["path"].to_s : e.to_s
    end

    # O sidecar roda engines de evasão contra sites hostis. Carregar ../.env
    # daria a ele SECRET_KEY_BASE, DISCORD_BOT_TOKEN e as chaves de LLM.
    assert_not_includes env_files, "../.env",
                        "sidecar não pode carregar o .env compartilhado"
    assert_includes env_files, "./.env.sidecar",
                    "sidecar precisa do env_file dedicado"
    env_files.each do |path|
      assert_match(/\.env\.[^.]+/, File.basename(path),
                   "#{path} não casa com o padrão `.env.*` do .gitignore e seria commitado")
    end
  end

  test "only the sidecar env file feeds the sidecar" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    env = config["services"]["python-scraper"]["environment"] || []

    # `environment:` inline não pode virar rota alternativa para segredo.
    forbidden = /SECRET_KEY_BASE|DISCORD|OPENROUTER|GOOGLE_AI|GEMINI|INTERNAL_EXTRACT/
    Array(env).each do |entry|
      assert_no_match forbidden, entry.to_s, "segredo em environment: do sidecar (#{entry})"
    end
  end

  test "searxng must not load the shared .env" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    # env_file pode ser string (`- ./.env.searxng`) ou hash com path/required
    # (`- path: ./.env.searxng, required: false`); o path e o que importa aqui.
    env_files = Array(config["services"]["searxng"]["env_file"]).map do |e|
      e.is_a?(Hash) ? e["path"].to_s : e.to_s
    end

    # Mesma classe de exposição do sidecar: o searxng busca e parseia HTML de
    # sites arbitrários da internet. Ele precisa de UMA variável
    # (SEARXNG_SECRET_KEY); `../.env` entrega 26, incluindo SECRET_KEY_BASE,
    # DISCORD_BOT_TOKEN, as chaves de LLM e o INTERNAL_EXTRACT_TOKEN.
    assert_not_includes env_files, "../.env",
                        "searxng não pode carregar o .env compartilhado"
    assert_includes env_files, "./.env.searxng",
                    "searxng precisa do env_file dedicado"
    env_files.each do |path|
      assert_match(/\.env\.[^.]+/, File.basename(path),
                   "#{path} não casa com o padrão `.env.*` do .gitignore e seria commitado")
    end
  end

  test "only the searxng env file feeds searxng" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    env = config["services"]["searxng"]["environment"] || []

    # `environment:` inline não pode virar rota alternativa para segredo.
    forbidden = /SECRET_KEY_BASE|DISCORD|OPENROUTER|GOOGLE_AI|GEMINI|INTERNAL_EXTRACT/
    entries = env.is_a?(Hash) ? env.map { |k, v| "#{k}=#{v}" } : Array(env).map(&:to_s)
    entries.each do |entry|
      assert_no_match forbidden, entry, "segredo em environment: do searxng (#{entry})"
    end
  end

  test "searxng image should be pinned by digest" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    image = config["services"]["searxng"]["image"].to_s

    # `:latest` não é repuxada por `docker compose up`: a VM ficou 3 meses numa
    # versão com o duckduckgo quebrado sem nenhum sinal. Pinar por digest faz o
    # upgrade voltar a ser decisão explícita.
    assert_match(/\Asearxng\/searxng@sha256:[0-9a-f]{64}\z/, image,
                 "searxng deve ser pinada por digest, não por tag mutável (atual: #{image})")
  end

  test "rails services should know where the sidecar lives" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    %w[app jobs discord-bot].each do |service_name|
      env = config["services"][service_name]["environment"] || {}
      assert_equal "http://python-scraper:8080", env["PYTHON_SCRAPER_URL"],
                   "#{service_name} precisa de PYTHON_SCRAPER_URL"
    end
  end

  test "app, jobs e discord-bot montam o storage por bind mount" do
    # Regressão do achado 1 da rodada 1: o volume nomeado storage-data perdia o
    # banco a cada container recriado. O banco de produção vive em storage/ no
    # host — o mount tem que ser relativo ao compose (../storage), nunca nomeado.
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    %w[app jobs discord-bot].each do |service_name|
      volumes = Array(config["services"][service_name]["volumes"])
      assert_includes volumes, "../storage:/rails/storage",
                      "#{service_name} precisa do bind mount ../storage:/rails/storage"
      assert_not_includes volumes, "storage-data:/rails/storage",
                          "#{service_name} não pode usar o volume nomeado storage-data"
    end
  end

  test "jobs service should run solid queue via bin/jobs" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    jobs = config["services"]["jobs"]

    assert_includes jobs["command"], "jobs start"
    assert_includes jobs["networks"], "internal"
  end

  test "chrome service should use chromedp/headless-shell" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    chrome = config["services"]["chrome"]

    assert_includes chrome["image"], "chromedp/headless-shell"
    assert_equal "2gb", chrome["shm_size"]

    # O CDP não tem autenticação e o Chromium marcou como WontFix: quem alcança a
    # porta dirige o navegador e rouba os cookies da sessão. Publicar no host dava
    # esse poder a qualquer processo local. O Rails fala por `chrome:9222` na rede.
    assert_nil chrome["ports"], "o CDP não pode ser publicado no host"

    # Rede dedicada: o chrome sai do barramento comum para ficar fora do alcance
    # do python-scraper, que roda engines de evasão contra sites hostis.
    assert_equal ["browser"], chrome["networks"]

    # Perfil persistente: sem ele a sessão logada morre a cada restart.
    assert_includes chrome["command"].join(" "), "--user-data-dir"
    assert_includes chrome["volumes"].join(" "), "chrome-profile"
  end

  test "app and jobs should depend on chrome service" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    app_deps = config["services"]["app"]["depends_on"] || {}
    jobs_deps = config["services"]["jobs"]["depends_on"] || {}

    assert app_deps.key?("chrome"), "app should depend on chrome"
    assert jobs_deps.key?("chrome"), "jobs should depend on chrome"
  end

  test "jobs deve subir só após o app estar healthy (db:prepare da fila antes do worker)" do
    # Regressão do achado r9 (rodada 9 do sol): a fila usa SQLite dedicado
    # (storage/production_queue.sqlite3) e o `bin/jobs start` NÃO roda
    # `db:prepare`. Sem ordenação, no primeiro deploy o worker abre o arquivo
    # vazio e reinicia com erro de tabela inexistente. O `app` roda `db:prepare`
    # no entrypoint e expõe healthcheck de `/up`; exigir que `jobs` dependa da
    # saúde do `app` garante que o banco de fila foi criado/migrado antes.
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    jobs_deps = config["services"]["jobs"]["depends_on"] || {}

    assert jobs_deps.key?("app"), "jobs deve depender do app (db:prepare antes da fila)"
    app_dep = jobs_deps["app"]
    assert_equal "service_healthy", app_dep["condition"],
                 "jobs sobe só após app healthy (condition: service_healthy)"
  end

  test "services should sit on a declared network, and only chrome leaves the bus" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    config["services"].each do |name, service|
      redes = Array(service["networks"])
      assert_not_empty redes, "#{name} should declare a network"

      # O chrome é o único fora do barramento comum: ele é dirigível por quem
      # alcança o CDP, então fica numa rede só com quem precisa dirigi-lo.
      next if name == "chrome"

      assert_includes redes, "internal", "#{name} should use internal network"
    end

    assert config["networks"].key?("internal"), "internal network should be defined"
    assert config["networks"].key?("browser"), "browser network should be defined"
  end

  test "only the services that drive Chrome reach the CDP network" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    na_rede = config["services"].select { |_n, s| Array(s["networks"]).include?("browser") }.keys

    assert_equal %w[app chrome discord-bot jobs test], na_rede.sort,
                 "quem entra na rede do CDP ganha controle total do navegador — a lista é fechada"
  end

  test "services should have restart policy" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    config["services"].each do |name, service|
      next if service["profiles"]
      assert service["restart"], "#{name} should have restart policy"
    end
  end

  test "all services should have CHROME_HOST and CHROME_PORT environment" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)

    %w[app jobs].each do |service_name|
      env = config["services"][service_name]["environment"] || {}
      assert env["CHROME_HOST"], "#{service_name} should have CHROME_HOST env"
      assert env["CHROME_PORT"], "#{service_name} should have CHROME_PORT env"
    end
  end

  test "docker-compose should not have obsolete version key" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    assert_nil config["version"], "version key is obsolete and should be removed"
  end

  test "discord-bot declara as variáveis de sessão de conversa" do
    compose = YAML.load_file(Rails.root.join("docker/docker-compose.yml"), aliases: true)
    env = compose.dig("services", "discord-bot", "environment")
    texto = env.is_a?(Hash) ? env.keys.join(" ") : Array(env).join(" ")

    %w[DISCORD_OPEN_CHANNEL_IDS DISCORD_MUTE_PREFIX DISCORD_COMPACTION_THRESHOLD
       DISCORD_REHYDRATE_MESSAGES DISCORD_PROTECTED_TAIL DISCORD_SESSIONS_PAGE_SIZE
       DISCORD_COMMAND_GUILD_ID].each do |chave|
      assert_includes texto, chave
    end
  end

  test "discord-bot troca DISCORD_SESSIONS_LIMIT por page size e max" do
    compose = YAML.load_file(Rails.root.join("docker/docker-compose.yml"), aliases: true)
    env = compose.dig("services", "discord-bot", "environment")
    texto = env.is_a?(Hash) ? env.keys.join(" ") : Array(env).join(" ")

    assert_includes texto, "DISCORD_SESSIONS_PAGE_SIZE"
    assert_includes texto, "DISCORD_SESSIONS_MAX"
    assert_not_includes texto, "DISCORD_SESSIONS_LIMIT"
  end

  test "discord-bot declara as variáveis de raciocínio da cadeia de modelos" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    env = config["services"]["discord-bot"]["environment"]

    assert_equal "${DISCORD_EFFORT_NOUS:-none}", env["DISCORD_EFFORT_NOUS"]
    assert_equal "${DISCORD_POOLSIDE_THINKING:-}", env["DISCORD_POOLSIDE_THINKING"]
  end
  test "as chaves de API NÃO aparecem no bloco environment de nenhum serviço" do
    # `environment:` tem precedência sobre `env_file:`. Uma chave listada ali é
    # resolvida contra docker/.env, onde ela não existe, e chega VAZIA ao
    # container — sobrescrevendo, em silêncio, a que veio do .env da raiz.
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    proibidas = %w[POOLSIDE_API_KEY NOUS_API_KEY OPENROUTER_API_KEY GOOGLE_AI_API_KEY]

    config["services"].each do |nome, servico|
      env = servico["environment"] || {}
      # `environment:` pode ser um Hash (dict) ou um Array (list de strings)
      chaves = if env.is_a?(Hash)
                  env.keys
                else
                  # Array de "KEY=value" — extrai as chaves
                  Array(env).map { |entry| entry.to_s.split("=").first }
                end

      proibidas.each do |chave|
        assert_not_includes chaves, chave,
                            "#{nome} declara #{chave} em environment: — chegaria vazia"
      end
    end
  end

  test "chrome healthcheck envia GET /json/version com Host: localhost e valida webSocketDebuggerUrl" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    chrome = config["services"]["chrome"]

    healthcheck = chrome["healthcheck"]
    assert healthcheck, "chrome deve ter healthcheck"

    test_cmd = healthcheck["test"].join(" ")
    assert_match(/CMD-SHELL/, test_cmd)
    # Deve fazer GET /json/version — não mais TCP aberto
    assert_match(%r{/json/version}, test_cmd,
                 "healthcheck deve consultar /json/version, não apenas abrir a porta")
    # Deve enviar o header Host: localhost
    assert_match(/Host: localhost/, test_cmd,
                 "healthcheck deve enviar o header Host: localhost")
    # Deve validar a presença de webSocketDebuggerUrl na resposta
    assert_match(/webSocketDebuggerUrl/, test_cmd,
                 "healthcheck deve validar webSocketDebuggerUrl na resposta")
    # NÃO deve usar `echo -e` — é não-portátil no dash (Debian base images).
    # Deve usar `printf` (POSIX), que interpreta \r\n de forma confiável.
    assert_match(/printf/, test_cmd,
                 "healthcheck deve usar printf (portátil), não echo -e")
    assert_no_match(/echo\s+-e/, test_cmd,
                    "healthcheck NÃO deve usar `echo -e` — não é portátil no dash")
  end

  test "chrome deve ter limites explícitos de recursos compatíveis com a VM de 24GB/4OCPUs" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    chrome = config["services"]["chrome"]

    # mem_limit: 4g — numérico, superior ao shm_size (2gb), dentro do teto da VM
    assert chrome["mem_limit"], "chrome deve ter mem_limit explícito"
    assert_match(/\d+[gmb]/i, chrome["mem_limit"].to_s,
                 "mem_limit deve ser um valor numérico")
    assert_operator chrome["mem_limit"].to_i, :>, 0, "mem_limit deve ser positivo"

    # cpus: 2.0 — numérico, dentro dos 4 OCPUs disponíveis
    assert chrome["cpus"], "chrome deve ter cpus explícito"
    cpus = chrome["cpus"].to_s.to_f
    assert_operator cpus, :>, 0, "cpus deve ser positivo"
    assert_operator cpus, :<=, 4.0, "cpus não deve exceder os 4 OCPUs da VM"

    # pids_limit conservador — numérico positivo
    assert chrome["pids_limit"], "chrome deve ter pids_limit explícito"
    assert_operator chrome["pids_limit"].to_i, :>, 0, "pids_limit deve ser positivo"

    # shm_size mantido em 2gb
    assert_equal "2gb", chrome["shm_size"], "shm_size deve ser mantido em 2gb"

    # restart mantido
    assert_equal "unless-stopped", chrome["restart"],
                 "chrome deve manter restart: unless-stopped"
  end

  test "container de teste não roda como root e não compartilha o .env de produção" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    test_service = config["services"]["test"]

    assert test_service, "test service not found"

    # Usuário não-root
    assert_not_equal "root", test_service["user"],
                     "container de teste não deve rodar como root"
    assert test_service["user"], "container de teste deve declarar um usuário não-root"

    # Ausência do .env compartilhado
    env_files = Array(test_service["env_file"]).compact
    assert_empty env_files,
                 "container de teste não deve carregar env_file (nem ../.env)"

    # Checkout read-only
    volumes = Array(test_service["volumes"]) || []
    ro_volumes = volumes.select { |v| v.is_a?(String) && v.end_with?(":ro") }
    assert ro_volumes.any? { |v| v.match?(/\.\.\/:\/rails:ro/) },
           "checkout deve ser montado read-only (../:/rails:ro)"
  end

  test "container de teste expõe apenas diretórios temporários explicitamente graváveis" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    test_service = config["services"]["test"]

    volumes = Array(test_service["volumes"]) || []
    # O checkout read-only não deve aparecer sem :ro
    writable_non_ro = volumes.select { |v| v.is_a?(String) && v.end_with?(":/rails") && !v.end_with?(":ro") }
    assert_empty writable_non_ro,
                 "nenhum volume do checkout deve ser gravável sem :ro"

    # tmpfs gravável sobre tmp e log — o compose usa bind relativo
    # (../tmp:/rails/tmp), não absoluto; verificar o lado do container.
    writable_paths = volumes.select { |v| v.is_a?(String) && v =~ %r{:/rails/(tmp|log)$} }
    assert writable_paths.any? { |v| v.end_with?("/rails/tmp") },
           "tmp deve ser montado gravável"
    assert writable_paths.any? { |v| v.end_with?("/rails/log") },
           "log deve ser montado gravável"

    # O SQLite de teste deve viver em tmpfs, NÃO em bind-mount de arquivo no
    # host — um bind-mount cria um arquivo vazio (0 bytes) no host antes do
    # Rails subir, o que pode disparar SQLite3::CorruptException. O tmpfs vive
    # só na memória do container e é descartado a cada restart (correto para
    # testes).
    tmpfs_volume = volumes.find { |v| v.is_a?(Hash) && v["type"] == "tmpfs" && v["target"] == "/tmp" }
    assert tmpfs_volume, "test service deve montar tmpfs em /tmp (não bind-mount de sqlite)"
    refute volumes.any? { |v| v.to_s =~ %r{clayton_test\.sqlite3} },
           "não deve haver bind-mount de /tmp/clayton_test.sqlite3 (cria arquivo vazio no host)"
  end

  test "container de teste aponta o banco para SQLite em /tmp via ambiente inline" do
    config = YAML.load_file(DOCKER_COMPOSE_PATH)
    test_service = config["services"]["test"]

    env = test_service["environment"] || {}
    env_str = env.is_a?(Hash) ? env.map { |k, v| "#{k}=#{v}" }.join(" ") : Array(env).join(" ")

    # DATABASE_URL inline apontando para /tmp — não vem do .env
    assert_match(/DATABASE_URL/, env_str, "test deve declarar DATABASE_URL inline")
    assert_match(%r{/tmp/}, env_str, "banco de teste deve viver em /tmp")
    assert_match(/sqlite3/, env_str, "banco de teste deve ser SQLite")
  end
end
