# frozen_string_literal: true

module Llm
  # Consulta e atualização do registry de modelos do RubyLLM.
  #
  # O gem embarca um models.json congelado no release, então a lista envelhece
  # sozinha: um slug aposentado pelo provedor continua nela, e um modelo novo
  # nunca aparece. refresh! busca a lista viva de cada provedor configurado.
  class ModelRegistry
    PROVIDER = 'openrouter'

    FreeModel = Struct.new(:id, :context_window, keyword_init: true)

    class << self
      # Retorna o total de modelos após a atualização.
      def refresh!
        RubyLLM.models.refresh!.all.size
      end

      # Re-registra os custom_models do projeto no registry em memória.
      #
      # `Models#refresh!` SUBSTITUI a lista viva e perde o que o initializer
      # registrou no boot, então quem chamar `refresh!` tem de rodar isto depois
      # (a rake `llm:models:refresh` faz os dois). Idempotente: pula ids/
      # provedores já presentes.
      def register_custom_models!
        # `Models.instance.all` devolve a referência do array interno, não uma
        # cópia — verificado em `models.rb:410-424` —, então o `<<` muta o
        # registry de verdade.
        registry = RubyLLM::Models.instance.all
        custom_models.each do |model|
          next if registry.any? { |m| m.id == model.id && m.provider == model.provider }

          registry << model
        end
      end

      # Registro DINÂMICO (desde 29/08): um slug vindo do config/llm_chain.yml que
      # não está na lista hardcoded é resolvido assim que a cadeia é montada.
      #
      # Antes disto, um modelo novo no YAML levantava ModelNotFoundError no
      # primeiro uso do chat, porque a gem só conhece o models.json congelado.
      # Idempotente: pula se já existe (id + provider). `effort`/`params` do YAML
      # NÃO são campos do Model::Info — só guardamos metadados de janela/limite que
      # o spec do provider não sabe; o `effort`/`params` vivem no Link, não aqui.
      def register_from_spec!(provider:, model:, effort: nil, params: nil)
        registry = RubyLLM::Models.instance.all
        return if registry.any? { |m| m.id == model.to_s && m.provider == provider.to_s }

        # Sem medir janela/limite do modelo novo, usa tetos conservadores que a
        # gem aceita (inteiros). Quem quiser afinar pode registrar no initializer.
        registry << RubyLLM::Model::Info.new(
          id: model.to_s,
          name: "#{provider.to_s}/#{model} (via llm_chain.yml)",
          provider: provider.to_s,
          capabilities: %w[function_calling streaming],
          max_output_tokens: 32_768,
          context_window: 200_000
        )
      end

      # A lista de modelos custom do projeto, registrada no boot pelo
      # initializer (config/initializers/ruby_llm.rb) e re-registrada pela rake
      # depois do `refresh!`.
      #
      # O campo `provider` tem de ser String e tem de casar com o `slug` da
      # classe do provedor (derivado do nome da classe). Symbol aqui não casa em
      # `Models#find`, que compara contra `provider.to_s`, e o sintoma é
      # `ModelNotFoundError` em produção, não erro de boot.
      #
      # Janelas e tetos de saída medidos em `GET /v1/models` das duas APIs em
      # 2026-08-07 — não são estimativa.
      def custom_models
        [
          # --- NVIDIA NIM, rota direta ------------------------------------------------
          RubyLLM::Model::Info.new(
            id: 'moonshotai/kimi-k3',
            name: 'Kimi K3 (via NVIDIA NIM)',
            provider: 'nvidia',
            capabilities: %w[function_calling streaming],
            max_output_tokens: 32_768,
            context_window: 131_072
          ),
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
          # Roteador que sorteia entre os modelos gratuitos disponíveis. O valor
          # substituído era o par de modelos gratuitos fixos google/gemma-4-31b-it:free
          # e openai/gpt-oss-120b:free — não o `openrouter/auto`. Ressalva: o
          # google/gemma-4-31b-it:free (rota OpenRouter) e o gemma-4-31b-it (rota
          # direta do Gemini, seção abaixo) são ids diferentes. O gemma-4-31b-it,
          # FALLBACK_MODEL do ChatSessionManager, voltou a ser registrado; o par
          # :free substituído, não.
          RubyLLM::Model::Info.new(
            id: 'openrouter/free',
            name: 'OpenRouter Free Router',
            provider: 'openrouter',
            capabilities: %w[function_calling streaming],
            max_output_tokens: 32_768,
            context_window: 200_000
          ),
          # --- Gemini ----------------------------------------------------------------
          # Os três existem na API do Google mas não no registry embutido na gem.
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
          ),
          # O gemma-4-31b-it é o FALLBACK_MODEL do ChatSessionManager. O origin o
          # registrava no initializer antigo; este PR o perdeu junto com a remoção
          # do arquivo, e o fallback do chat passou a levantar ModelNotFoundError.
          # Restaurado aqui no formato do origin: provider 'gemini' (String, casa
          # com o slug da classe), max_output_tokens 32_768, context_window 262_144.
          RubyLLM::Model::Info.new(
            id: 'gemma-4-31b-it',
            name: 'Gemma 4 31B',
            provider: 'gemini',
            max_output_tokens: 32_768,
            context_window: 262_144
          )
        ]
      end

      def free(tools_only: true)
        live_rows.filter_map do |row|
          next if tools_only && !supports_tools?(row)
          next unless free?(row)

          FreeModel.new(id: row['id'], context_window: row['context_length'])
        end
      end

      # Resposta crua da OpenRouter, reaproveitando a conexão configurada do gem.
      #
      # Duas informações se perdem no Model::Info: o parser do gem só guarda preço
      # positivo, então tanto "0" (gratuito) quanto "-1" (tarifa variável do
      # openrouter/auto) viram nil; e refresh! ainda funde a resposta com o
      # catálogo models.dev, que traz modelos sem pricing e fora de serviço.
      def live_rows
        provider = RubyLLM::Provider.providers[PROVIDER.to_sym].new(RubyLLM.config)
        Array(provider.connection.get('models').body['data'])
      end

      def free?(row)
        pricing = row['pricing'] || {}
        %w[prompt completion].all? do |key|
          value = pricing[key]
          !value.nil? && value.to_f.zero?
        end
      end

      def supports_tools?(row)
        Array(row['supported_parameters']).include?('tools')
      end
    end
  end
end
