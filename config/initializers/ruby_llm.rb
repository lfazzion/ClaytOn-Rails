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
# sem a gem. Produção roda com `eager_load = true` — sem a gem, o boot morre
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
  require Rails.root.join('lib/llm/model_registry')

  RubyLLM::Provider.register(:poolside, Llm::Providers::Poolside)
  RubyLLM::Provider.register(:nous, Llm::Providers::Nous)

  # Os modelos custom do projeto (Poolside, Nous, OpenRouter e os dois Gemini)
  # vivem em `Llm::ModelRegistry.custom_models` e são registrados por
  # `Llm::ModelRegistry.register_custom_models!` — o mesmo método que a rake
  # `llm:models:refresh` usa para re-registrar os custom_models depois do
  # `refresh!` (que substitui a lista viva em memória).
  Llm::ModelRegistry.register_custom_models!

  RubyLLM.configure do |config|
    config.gemini_api_key = ENV.fetch('GOOGLE_AI_API_KEY', nil)
    config.openrouter_api_key = ENV.fetch('OPENROUTER_API_KEY', nil)
    config.poolside_api_key = ENV.fetch('POOLSIDE_API_KEY', nil)
    config.nous_api_key = ENV.fetch('NOUS_API_KEY', nil)
    # Só vale para chamada sem `model:`. O chat do Discord sempre passa o modelo
    # e o provedor explicitamente, pela cadeia. `openrouter/free` exige
    # `OPENROUTER_API_KEY` — sem ela, não há rota para chamada sem `model:`.
    config.default_model = 'openrouter/free'
    # Poolside, Nous e OpenRouter herdam `format_role` de RubyLLM::Providers::OpenAI
    # (chat.rb:99), que sem isto manda toda mensagem :system como papel
    # "developer". Medido em 2026-08-07, 3/3 rodadas: a rota direta da Poolside
    # (elo primário) IGNORA "developer" — responde genérico, em inglês, sem
    # seguir a instrução — e OBEDECE a "system". Nous e OpenRouter obedecem os
    # dois papéis, então ligar isto não regride nada neles. Sem esta linha o bot
    # perde persona, timestamp e as regras das 17 tools (`with_instructions`) e o
    # resumo da compactação (`ConversationRehydrator#apply!` — de outro PR) no elo primário.
    config.openai_use_system_role = true
    config.logger = Rails.logger
    config.log_level = Rails.env.production? ? :info : :debug
    # 40s/link — cadeia de 3 links = máx ~2min; antes 120s/link = 6min de silêncio
    config.request_timeout = 40
  end

  # Sem isto ninguém sabe em qual rota o bot está rodando — mesma lição do
  # limiar inerte registrada em docs/MEMORY.md.
  Llm::ModelChain.log_links!
end
