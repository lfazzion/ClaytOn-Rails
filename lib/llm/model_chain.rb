# frozen_string_literal: true

require "llm/llm_chain_loader"

module Llm
  # A cadeia de rotas que o chat percorre, em ordem, até alguma responder.
  #
  # Um ELO é a quíntupla (rótulo, provedor, modelo, esforço, params). O ajuste de
  # raciocínio vive AQUI, no elo, e não numa configuração global, porque as rotas
  # desligam o raciocínio por mecanismos incompatíveis entre si — medido em
  # 2026-08-07 contra as APIs reais:
  #
  #   * Poolside direta: ignora `reasoning_effort` ("minimal" deu 12.033 ms e
  #     1.168 tokens de raciocínio, contra 9.749 ms e 1.100 do controle SEM
  #     campo nenhum) e RECUSA "none" com HTTP 400. A doc oficial confirma que
  #     reasoning_effort não é suportado nos modelos Poolside. O que funciona é
  #     `chat_template_kwargs: { enable_thinking: false }`, que entra pelo
  #     `with_params` da gem: 254 ms e ZERO tokens de raciocínio. O aninhamento
  #     importa — a mesma chave no nível de cima não faz efeito.
  #   * Nous: `reasoning_effort: "none"` chato zera o raciocínio (0 tokens em 6
  #     de 6 rodadas) e derruba a mediana de 13.240 ms para 3.097 ms.
  #   * OpenRouter `openrouter/free`: roteador que sorteia entre gratuitos. Não
  #     dá para garantir o vocabulário do modelo sorteado, então não se manda
  #     nada.
  #
  # Um valor de esforço fora do vocabulário do provedor NÃO degrada: dá HTTP 400
  # em toda chamada daquele elo. Por isso o valor vindo do arquivo é validado
  # contra a lista medida, e valor inválido cai no padrão COM log.
  #
  # CONFIGURAÇÃO DINÂMICA (desde 29/08): os elos primário e fallback vêm de
  # config/llm_chain.yml (NÃO commitado), lido a cada chamada de `links` — trocar
  # o arquivo reconfigura o bot SEM restart. O arquivo só nomeia provedor/modelo/
  # effort/params; as chaves de API continuam no ENV como antes. Chave ausente
  # ENCURTA a cadeia (remove o elo cujo provider não tem credencial) em vez de
  # quebrá-la.
  #
  # O comentário antigo deste arquivo (ago/2026) culpava o DNS de um domínio
  # que nunca foi usado pelo provider (ver providers/nous.rb — o endpoint real é
  # inference-api.nousresearch.com). A causa real, medida em 28/08, foi MUDANÇA
  # DE CONTRATO do gateway Nous: chamadores com API key crua passaram a precisar
  # do header/campo `tags` ("user=cleitin-bot"). É resolvido no YAML via
  # `params: { tags: [...] }`, que a gem faz deep_merge no corpo HTTP
  # (ver providers/nous.rb).
  #
  # Chave ausente ENCURTA a cadeia em vez de quebrá-la, para o bot poder rodar
  # com uma chave de cada vez. Sem chave nenhuma (e sem fallback válido), `links`
  # volta vazia — e quem chama trata isso, em vez de receber uma cadeia que mente.
  #
  # Escolha dos modelos, medida em 2026-08-07, continua válida e está documentada
  # em docs/MEMORY.md.
  class ModelChain
    Link = Struct.new(:label, :provider, :model, :effort, :params, keyword_init: true)

    # Medidos como ACEITOS pelo gateway do Nous em 2026-08-07. `minimal` NÃO está
    # aqui: é vocabulário da Poolside, e mandá-lo para o Nous é justamente o tipo
    # de troca que este mapa existe para impedir.
    NOUS_EFFORTS = %w[none low medium high].freeze
    DEFAULT_NOUS_EFFORT = "none"

    # Variável de credencial POR PROVEDOR (Sol R1-A, achado 4). O initializer
    # `config.gemini_api_key = ENV.fetch('GOOGLE_AI_API_KEY', nil)` — NÃO
    # `GEMINI_API_KEY`. Se um dia um provider novo entrar no YAML sem chave
    # correspondente aqui, ele simplesmente fica sem credencial e é cortado da
    # cadeia (em vez de mandar requisição sem auth).
    PROVIDER_CRED_KEY = {
      nous: "NOUS_API_KEY",
      poolside: "POOLSIDE_API_KEY",
      openrouter: "OPENROUTER_API_KEY",
      nvidia: "NVIDIA_API_KEY",
      gemini: "GOOGLE_AI_API_KEY"
    }.freeze

    # Vocabulário de `effort` ACEITO por provider, medido/contratado. Array
    # vazio = provider NÃO suporta effort (vira nil). O Nous é o único com
    # vocabulário próprio; Poolside RECUSA `effort: none` com HTTP 400; OpenRouter
    # e NVIDIA não aceitam o campo; Gemini não tem contrato de effort neste bot
    # (mantido nil até confirmar o vocabulário da gem — ver RISK no relatório).
    PROVIDER_EFFORTS = {
      nous: %w[none low medium high],
      poolside: [],
      openrouter: [],
      nvidia: [],
      gemini: []
    }.freeze

    # O corpo que desliga o raciocínio na rota direta da Poolside. Vai por
    # `Chat#with_params`, que a gem faz deep_merge no payload — não existe
    # método de alto nível para isto, porque não é vocabulário da OpenAI.
    POOLSIDE_SEM_RACIOCINIO = { chat_template_kwargs: { enable_thinking: false } }.freeze

    AGGREGATOR_MODEL = "tencent/hy3:free"

    # Ver `summarizer`: escolhido por latência, não por capacidade.
    SUMMARIZER_MODEL = "poolside/laguna-xs-2.1"

    # Caminho do YAML de configuração (fora do git). Lido a cada `links`.
    CHAIN_CONFIG_PATH = Rails.root.join("config/llm_chain.yml") rescue Pathname.new("config/llm_chain.yml")

    class << self
      # Sem memoização de propósito: o valor viria de uma leitura de arquivo/ENV
      # feita uma vez e ficaria para sempre, o que torna a configuração
      # intestável e esconde mudança de arquivo entre containers. Cada chamada
      # relê o YAML (last-known-good interno cobre leitura ruim momentânea).
      #
      # Ordem da cadeia: [primary] + ([fallback] se presente e com chave).
      # NÃO altera `summarizer` nem `aggregator` — continuam como estão.
      #
      # CORREÇÃO Sol R1-A (achado 3): primary e fallback são construídos
      # INDEPENDENTEMENTE. Antes, se o primary não pudesse ser construído (chave
      # ausente) a cadeia inteira voltava `[]` — matando um fallback válido. Agora
      # cada elo é tentado isoladamente e os indisponíveis são compactados; o
      # fallback válido assume a ponta quando o primary cai. Cadeia vazia SÓ
      # quando nenhum elo configurado puder ser usado.
      def links
        cfg = Llm::LlmChainLoader.new(path: CHAIN_CONFIG_PATH, logger: Rails.logger).load
        return [] if cfg.nil?

        elos = []
        if (primary = build_link(cfg[:primary]))
          elos << primary
        end

        if cfg[:fallback] && (fb = build_link(cfg[:fallback]))
          elos << fb
        end

        elos
      end

      def primary
        links.first
      end

      # Exposto para a spec 3 (MoA) consumir. NÃO entra diretamente na cadeia do
      # chat como método — quem chama a cadeia usa `links`, não `aggregator`.
      # Também precisa das tags do Nous (mesma causa do hy3:free ter parado em
      # 28/08). Se o YAML declarar params para o primary Nous, reusamos para o
      # agregador; caso contrário usamos o padrão medido (user=cleitin-bot).
      def aggregator
        return nil unless chave?("NOUS_API_KEY")

        Link.new(label: "nous-agregador", provider: :nous, model: AGGREGATOR_MODEL,
                 effort: DEFAULT_NOUS_EFFORT, params: nous_tags_params)
      end

      # O modelo que resume a conversa na compactação. **Não é o elo 1**, e essa
      # separação é deliberada. Continua fixo (poolside/laguna-xs-2.1) por latência
      # — ver MEMORY.md. Sem a chave da Poolside devolve nil, e o chamador cai na
      # cadeia.
      def summarizer
        return nil unless chave?("POOLSIDE_API_KEY")

        Link.new(label: "resumidor", provider: :poolside, model: SUMMARIZER_MODEL,
                 effort: nil, params: POOLSIDE_SEM_RACIOCINIO)
      end

      def describe
        disponiveis = links
        return "nenhum elo disponível (nenhuma chave de LLM configurada)" if disponiveis.empty?

        disponiveis.map { |elo| "#{elo.label}(#{elo.model}#{descreve_raciocinio(elo)})" }.join(" > ")
      end

      def log_links!
        Rails.logger.info "[ModelChain] Cadeia ativa: #{describe}"
      end

      private

      # Monta um Link a partir do mapa do YAML, validando a chave do provider e
      # registrando o modelo dinamicamente (idempotente). Devolve nil se o
      # provider não tem credencial (encurta a cadeia) ou se o YAML for inválido.
      def build_link(spec)
        return nil if spec.nil?

        provider = spec[:provider].to_sym
        model = spec[:model].to_s
        effort = spec[:effort]
        params = spec[:params]
        label = spec[:label] || "#{provider}:#{model}"

        # Chave ausente encurta a cadeia (mesmo comportamento de antes). O mapa
        # PROVIDER_CRED_KEY garante a variável correta por provider (Gemini é
        # GOOGLE_AI_API_KEY, não GEMINI_API_KEY — ver achado 4). Provider fora do
        # mapa => sem credencial => cortado (não manda sem auth).
        cred_key = PROVIDER_CRED_KEY[provider]
        return nil if cred_key.nil? || !chave?(cred_key)

        # Effort validado contra o vocabulário MEDIDO do provider (achado 4).
        # Inválido/ausente para provider sem suporte vira nil COM log quando
        # aplicável (valor inválido daria HTTP 400 em TODA chamada daquele elo).
        effort = normalize_effort(provider, effort)

        # Registra o modelo (idempotente) ANTES de devolver o Link — slug vindo
        # do YAML que não está na lista hardcoded passa a ser resolvido.
        Llm::ModelRegistry.register_from_spec!(provider: provider, model: model, effort: effort, params: params)

        Link.new(label: label, provider: provider, model: model, effort: effort, params: params)
      rescue StandardError => e
        Rails.logger.error "[ModelChain] elo inválido (#{label}: #{e.message}) — removido da cadeia"
        nil
      end

      # Valida o effort contra o vocabulário ACEITO do provider (Sol R1-A,
      # achado 4). nil/empty passa (sem reasoning_effort). Provider cujo
      # vocabulário é vazio (Poolside, OpenRouter, NVIDIA, Gemini) NÃO suporta o
      # campo: qualquer valor (inclusive o `none` que a Poolside RECUSA com HTTP
      # 400) é rejeitado e vira nil, COM log de alerta.
      def normalize_effort(provider, effort)
        return nil if effort.nil? || effort.to_s.strip.empty?

        vocabulario = PROVIDER_EFFORTS[provider] || []
        esforco = effort.to_s.strip
        return esforco if vocabulario.include?(esforco)

        # Fora do vocabulário: rejeita para nil e LOGA. Para o Nous, cai no
        # padrão documentado; para os demais, avisa que o provider não suporta.
        if provider == :nous
          Rails.logger.warn "[ModelChain] effort=#{esforco.inspect} não é aceito pelo Nous " \
                            "(aceitos: #{NOUS_EFFORTS.join(', ')}); usando #{DEFAULT_NOUS_EFFORT.inspect}. " \
                            "Valor inválido daria HTTP 400 em TODA chamada deste elo."
          DEFAULT_NOUS_EFFORT
        else
          Rails.logger.warn "[ModelChain] effort=#{esforco.inspect} não é suportado pelo provider " \
                            "#{provider.inspect} (HTTP 400 em TODA chamada); desligando effort (nil)."
          nil
        end
      end

      # Tags que o gateway Nous passou a exigir (28/08): chamador com API key crua
      # precisa se identificar. Se o YAML do primary Nous trouxer params[:tags],
      # reusamos; senão, o padrão medido em produção.
      def nous_tags_params
        cfg = Llm::LlmChainLoader.new(path: CHAIN_CONFIG_PATH, logger: Rails.logger).load
        primary = cfg && cfg[:primary]
        if primary && primary[:provider].to_sym == :nous && primary[:params].is_a?(Hash) && primary[:params][:tags]
          return { tags: primary[:params][:tags] }
        end

        { tags: ["user=cleitin-bot"] }
      end

      def chave?(nome)
        ENV[nome].to_s.strip.present?
      end

      def descreve_raciocinio(elo)
        return ", effort=#{elo.effort}" if elo.effort.present?
        return ", raciocínio desligado" if elo.params.present?

        ""
      end
    end
  end
end
