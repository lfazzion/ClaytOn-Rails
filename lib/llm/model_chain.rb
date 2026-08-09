# frozen_string_literal: true

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
  # em toda chamada daquele elo. Por isso o valor vindo do ambiente é validado
  # contra a lista medida, e valor inválido cai no padrão COM log.
  #
  # Chave ausente ENCURTA a cadeia em vez de quebrá-la, para o bot poder rodar
  # com uma chave de cada vez. Sem chave nenhuma, `links` volta vazia — e quem
  # chama trata isso, em vez de receber uma cadeia que mente.
  #
  # Escolha dos modelos dos elos 1 e 2, medida em 2026-08-07 com o prompt real
  # e as 17 tools reais do bot, 9 cenários x 3 amostras cada:
  #
  #   * Escolha de ferramenta (acertos/total, mediana de latência):
  #     laguna-s 27/27, 2.921 ms; hy3 26/27, 3.286 ms; laguna-xs (o que saiu do
  #     chat) 25/27, 639 ms — mais rápido, mas menos acerto. A ordem entre os
  #     dois primeiros foi decidida pelo dono em 08/08 (ver `links`), porque a
  #     medição os deixou perto demais para decidir sozinha.
  #   * Julgamento cego de prosa, 5 perguntas, 3 juízes independentes com
  #     lentes diferentes (utilidade / português / concisão): laguna-s venceu
  #     em português e concisão e ficou em 2º em utilidade; hy3 venceu
  #     utilidade; laguna-xs ficou em último em duas das três lentes.
  #   * O motivo mais duro de tirar o laguna-xs: em vez de CHAMAR a ferramenta,
  #     ele emitiu a chamada como TEXTO VISÍVEL — o usuário via na tela
  #     `<tool_call>web_search<arg_key>query</arg_key>...` — verificado no
  #     conteúdo bruto da resposta, não é boato.
  class ModelChain
    Link = Struct.new(:label, :provider, :model, :effort, :params, keyword_init: true)

    # Medidos como ACEITOS pelo gateway do Nous em 2026-08-07. `minimal` NÃO está
    # aqui: é vocabulário da Poolside, e mandá-lo para o Nous é justamente o tipo
    # de troca que este mapa existe para impedir.
    NOUS_EFFORTS = %w[none low medium high].freeze
    DEFAULT_NOUS_EFFORT = "none"

    # O corpo que desliga o raciocínio na rota direta da Poolside. Vai por
    # `Chat#with_params`, que a gem faz deep_merge no payload — não existe
    # método de alto nível para isto, porque não é vocabulário da OpenAI.
    POOLSIDE_SEM_RACIOCINIO = { chat_template_kwargs: { enable_thinking: false } }.freeze

    AGGREGATOR_MODEL = "tencent/hy3:free"

    # Ver `summarizer`: escolhido por latência, não por capacidade.
    SUMMARIZER_MODEL = "poolside/laguna-xs-2.1"

    class << self
      # Sem memoização de propósito: o valor viria de uma leitura de ENV feita
      # uma vez e ficaria para sempre, o que torna a configuração intestável e
      # esconde mudança de ambiente entre containers.
      def links
        # Ordem: hy3 (Nous) primeiro, laguna-s (Poolside) de reserva. Decisão do
        # dono em 08/08/2026, depois de usar os dois. A medição os deixou perto:
        # laguna-s 27/27 na escolha de ferramenta contra 26/27 do hy3, e 2.921 ms
        # contra 3.286 ms; mas o hy3 venceu a lente de UTILIDADE no julgamento
        # cego (18 contra 15) — foi o único a enunciar a pegadinha da conta de
        # engajamento. Com os dois tão próximos, quem usa decide.
        #
        # O resumidor NÃO acompanha esta ordem (ver `summarizer`): ele é fixado
        # por latência. Foi para isso que a separação existe — sem ela, esta
        # troca arrastaria o resumo de 3.180 ms para 7.963 ms sem ninguém pedir.
        [nous_link, poolside_link, openrouter_link].compact
      end

      def primary
        links.first
      end

      # Exposto para a spec 3 (MoA) consumir. NÃO entra diretamente na cadeia do
      # chat como método — quem chama a cadeia usa `links`, não `aggregator`.
      # Desde a troca de 2026-08-07 o hy3 também é o modelo do elo 2 do chat
      # (`nous_link`), e isso é esperado, não duplicação por engano: o mesmo
      # modelo serve dois papéis (agregador da MoA e elo 2 do chat) porque
      # ganhou nos dois critérios medidos para o papel dele.
      def aggregator
        return nil unless chave?("NOUS_API_KEY")

        Link.new(label: "nous-agregador", provider: :nous, model: AGGREGATOR_MODEL,
                 effort: DEFAULT_NOUS_EFFORT, params: nil)
      end

      # O modelo que resume a conversa na compactação. **Não é o elo 1**, e essa
      # separação é deliberada.
      #
      # O resumo roda DENTRO do turno do usuário, segurando o mutex do escopo —
      # quem cruza o gatilho espera por ele, e num canal compartilhado todos
      # esperam junto. Então o critério aqui é LATÊNCIA, não capacidade.
      #
      # E resumir é a tarefa fácil: medido em 2026-08-07, transcript de 17
      # mensagens, 3 amostras, contando quantos dos 6 fatos decididos pelo usuário
      # sobrevivem. Os três candidatos preservaram os MESMOS 6/6, e só a latência
      # separou:
      #
      #   poolside/laguna-xs-2.1   3.180 ms  <- escolhido
      #   tencent/hy3:free         7.963 ms  (hoje o elo 1)
      #   poolside/laguna-s-2.1    9.849 ms  (hoje o elo 2)
      #
      # O `laguna-xs` saiu do chat por dois defeitos medidos — escolhe a ferramenta
      # errada (25/27 contra 26-27/27 dos outros dois) e chegou a emitir a chamada de
      # ferramenta como TEXTO VISÍVEL na tela. Nenhum dos dois alcança este papel:
      # o resumidor não usa ferramenta, e o texto dele nunca vai para a tela — vai
      # para o próximo prompt.
      #
      # Sem a chave da Poolside devolve nil, e o chamador cai na cadeia.
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

      def poolside_link
        return nil unless chave?("POOLSIDE_API_KEY")

        Link.new(label: "poolside-direta", provider: :poolside, model: "poolside/laguna-s-2.1",
                 effort: nil, params: poolside_params)
      end

      def nous_link
        return nil unless chave?("NOUS_API_KEY")

        Link.new(label: "nous", provider: :nous, model: "tencent/hy3:free",
                 effort: nous_effort, params: nil)
      end

      def openrouter_link
        return nil unless chave?("OPENROUTER_API_KEY")

        Link.new(label: "openrouter", provider: :openrouter, model: "openrouter/free",
                 effort: nil, params: nil)
      end

      # Válvula de escape: se um dia o raciocínio da rota direta fizer falta, uma
      # variável devolve o comportamento padrão da API sem mexer em código.
      def poolside_params
        return nil if ENV["DISCORD_POOLSIDE_THINKING"].to_s.strip.downcase == "true"

        POOLSIDE_SEM_RACIOCINIO
      end

      def nous_effort
        configurado = ENV["DISCORD_EFFORT_NOUS"].to_s.strip
        return DEFAULT_NOUS_EFFORT if configurado.empty?
        return configurado if NOUS_EFFORTS.include?(configurado)

        Rails.logger.warn "[ModelChain] DISCORD_EFFORT_NOUS=#{configurado.inspect} não é aceito pelo Nous " \
                          "(aceitos: #{NOUS_EFFORTS.join(', ')}); usando #{DEFAULT_NOUS_EFFORT.inspect}. " \
                          "Valor inválido daria HTTP 400 em TODA chamada deste elo."
        DEFAULT_NOUS_EFFORT
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
