# frozen_string_literal: true

# config/initializers/ruby_llm.rb
#
# Configuração global do RubyLLM.
#
# Três coisas acontecem aqui, nesta ordem, e a ordem importa:
#
#   1. Os provedores customizados são carregados e registrados. `Provider.register`
#      cria, por dentro, os acessores de configuração de cada um
#      (`poolside_api_key`, `nous_api_key`) — por isso ele vem ANTES do
#      `RubyLLM.configure`, que só pode atribuir o que já existe.
#   2. Os modelos são registrados à mão. O `models.json` embarcado na gem é
#      congelado no release: modelo não registrado faz `RubyLLM.chat` levantar
#      `ModelNotFoundError` antes mesmo de tentar a requisição.
#   3. As chaves entram na configuração e a cadeia se anuncia no log.
#
# `lib/llm` está fora do autoloader (`config/application.rb:18`), então tudo ali
# precisa de `require` explícito — e este é o ponto certo de carregamento, porque
# os provedores têm de existir antes do `configure`.
#
# O `require 'ruby_llm'` é o ÚNICO ponto coberto pelo rescue de LoadError deste
# arquivo. Ressalva honesta: esse rescue **não** entrega mais um bot funcional
# sem a gem. `ChatSessionManager::CHAIN_ERRORS` avalia `RubyLLM::Error` no corpo
# da classe, e produção roda com `eager_load = true` — sem a gem, o boot morre
# com `NameError` logo depois deste arquivo, em vez de subir com a
# funcionalidade LLM desligada. Como `ruby_llm` está no `Gemfile` sem condição e
# travado no `Gemfile.lock`, isso é teórico; o rescue fica como rede para o
# ambiente de build, não como promessa de degradação. Os `require` dos arquivos locais em `lib/llm/`
# ficam FORA desse rescue: um caminho digitado errado ali é bug nosso, não
# ausência de dependência, e tem de estourar o boot — se caísse no mesmo rescue,
# a aplicação subiria de pé, logando um "Gem não disponível" enganoso, sem
# nenhum provedor nem modelo novo registrado. Essa falha silenciosa é
# exatamente o que a regra 3/CLAUDE.md e a lição do limiar inerte (MEMORY.md)
# proíbem.
gem_available = true
begin
  require 'ruby_llm'
rescue LoadError => e
  Rails.logger.warn "[RubyLLM] Gem não disponível: #{e.message}. Funcionalidade LLM desabilitada."
  gem_available = false
end

if gem_available
  require Rails.root.join('lib/llm/providers/poolside')
  require Rails.root.join('lib/llm/providers/nous')
  require Rails.root.join('lib/llm/model_chain')

  RubyLLM::Provider.register(:poolside, Llm::Providers::Poolside)
  RubyLLM::Provider.register(:nous, Llm::Providers::Nous)

  # O campo `provider` tem de ser String e tem de casar com o `slug` da classe do
  # provedor (derivado do nome da classe). Symbol aqui não casa em `Models#find`,
  # que compara contra `provider.to_s`, e o sintoma é `ModelNotFoundError` em
  # produção, não erro de boot.
  #
  # Janelas e tetos de saída medidos em `GET /v1/models` das duas APIs em
  # 2026-08-07 — não são estimativa.
  custom_models = [
    # --- Poolside, rota direta -------------------------------------------------
    RubyLLM::Model::Info.new(
      id: 'poolside/laguna-xs-2.1',
      name: 'Poolside Laguna XS 2.1 (rota direta)',
      provider: 'poolside',
      capabilities: %w[function_calling streaming reasoning],
      max_output_tokens: 32_768,
      context_window: 262_144
    ),
    # Não está na cadeia. Fica registrado porque é o caminho de volta de uma
    # linha se o laguna-xs se mostrar raso demais: basta o elo 1 apontar para cá.
    RubyLLM::Model::Info.new(
      id: 'poolside/laguna-s-2.1',
      name: 'Poolside Laguna S 2.1 (rota direta)',
      provider: 'poolside',
      capabilities: %w[function_calling streaming reasoning],
      max_output_tokens: 32_768,
      context_window: 262_144
    ),
    # --- Nous Portal -----------------------------------------------------------
    RubyLLM::Model::Info.new(
      id: 'poolside/laguna-xs-2.1:free',
      name: 'Poolside Laguna XS 2.1 (via Nous)',
      provider: 'nous',
      capabilities: %w[function_calling streaming reasoning],
      max_output_tokens: 32_768,
      context_window: 262_144
    ),
    # Reservado para o agregador do MoA (spec 3). Registrado aqui para a
    # `ModelChain.aggregator` não devolver um id que levantaria ModelNotFoundError
    # no primeiro uso.
    RubyLLM::Model::Info.new(
      id: 'tencent/hy3:free',
      name: 'Tencent HY3 (via Nous)',
      provider: 'nous',
      capabilities: %w[function_calling streaming reasoning],
      max_output_tokens: 128_000,
      context_window: 262_144
    ),
    # --- OpenRouter ------------------------------------------------------------
    # Roteador que sorteia entre os modelos gratuitos disponíveis. Substituiu o
    # `openrouter/auto`, que roteava para modelos pagos e era cobrado.
    RubyLLM::Model::Info.new(
      id: 'openrouter/free',
      name: 'OpenRouter Free Router',
      provider: 'openrouter',
      capabilities: %w[function_calling streaming],
      max_output_tokens: 32_768,
      context_window: 200_000
    ),
    # --- Gemini ----------------------------------------------------------------
    # Os dois existem na API do Google mas não no registry embutido na gem.
    RubyLLM::Model::Info.new(
      id: 'gemini-3.1-flash-lite',
      name: 'Gemini 3.1 Flash Lite',
      provider: 'gemini',
      max_output_tokens: 65_536,
      context_window: 1_048_576
    ),
    RubyLLM::Model::Info.new(
      id: 'gemini-3.5-flash-lite',
      name: 'Gemini 3.5 Flash Lite',
      provider: 'gemini',
      max_output_tokens: 65_536,
      context_window: 1_048_576
    )
  ]

  # `Models.instance.all` devolve a referência do array interno, não uma cópia —
  # verificado em `models.rb:410-424` —, então o `<<` muta o registry de verdade.
  registry = RubyLLM::Models.instance.all
  custom_models.each do |model|
    next if registry.any? { |m| m.id == model.id && m.provider == model.provider }

    registry << model
  end

  RubyLLM.configure do |config|
    config.gemini_api_key = ENV.fetch('GOOGLE_AI_API_KEY', nil)
    config.openrouter_api_key = ENV.fetch('OPENROUTER_API_KEY', nil)
    config.poolside_api_key = ENV.fetch('POOLSIDE_API_KEY', nil)
    config.nous_api_key = ENV.fetch('NOUS_API_KEY', nil)
    # Só vale para chamada sem `model:`. O chat do Discord sempre passa o modelo
    # e o provedor explicitamente, pela cadeia. Aponta para o elo que existe
    # sempre que houver qualquer chave de LLM configurada.
    config.default_model = 'openrouter/free'
    # Poolside, Nous e OpenRouter herdam `format_role` de RubyLLM::Providers::OpenAI
    # (chat.rb:99), que sem isto manda toda mensagem :system como papel
    # "developer". Medido em 2026-08-07, 3/3 rodadas: a rota direta da Poolside
    # (elo primário) IGNORA "developer" — responde genérico, em inglês, sem
    # seguir a instrução — e OBEDECE a "system". Nous e OpenRouter obedecem os
    # dois papéis, então ligar isto não regride nada neles. Sem esta linha o bot
    # perde persona, timestamp e as regras das 19 tools (`with_instructions`) e o
    # resumo da compactação (`ConversationRehydrator#apply!`) no elo primário.
    config.openai_use_system_role = true
    config.logger = Rails.logger
    config.log_level = Rails.env.production? ? :info : :debug
    config.request_timeout = 120
  end

  # Sem isto ninguém sabe em qual rota o bot está rodando — mesma lição do
  # limiar inerte registrada em docs/MEMORY.md.
  Llm::ModelChain.log_links!
end
