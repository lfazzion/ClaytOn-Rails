
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
      assert_match(/\.env\.[^/]+\z/, File.basename(path),
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
      assert_match(/\.env\.[^/]+\z/, File.basename(path),
                   "#{path} não casa com o padrão `.env.*` do .gitignore e seria commitado")
    end
