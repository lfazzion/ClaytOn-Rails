# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/llm/model_chain"

class Llm::ModelChainTest < ActiveSupport::TestCase
  TODAS = %w[POOLSIDE_API_KEY NOUS_API_KEY OPENROUTER_API_KEY
             DISCORD_EFFORT_NOUS DISCORD_POOLSIDE_THINKING].freeze

  # Troca ENV e devolve ao que era, inclusive quando o bloco estoura. Sem isto
  # um caso vaza a configuração no seguinte e a suíte fica dependente de ordem.
  def com_env(valores)
    anteriores = TODAS.index_with { |chave| ENV[chave] }
    TODAS.each { |chave| ENV.delete(chave) }
    valores.each { |chave, valor| valor.nil? ? ENV.delete(chave.to_s) : ENV[chave.to_s] = valor }
    yield
  ensure
    TODAS.each { |chave| anteriores[chave].nil? ? ENV.delete(chave) : ENV[chave] = anteriores[chave] }
  end

  def com_as_duas_chaves(&)
    com_env({ "POOLSIDE_API_KEY" => "sk-p", "NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o" }, &)
  end

  test "com as três chaves, a cadeia tem três elos na ordem da spec" do
    com_as_duas_chaves do
      assert_equal %w[nous poolside-direta openrouter], Llm::ModelChain.links.map(&:label)
    end
  end

  test "cada elo aponta para o par provedor/modelo certo" do
    com_as_duas_chaves do
      nous, poolside, openrouter = Llm::ModelChain.links

      assert_equal :poolside, poolside.provider
      assert_equal "poolside/laguna-s-2.1", poolside.model
      assert_equal :nous, nous.provider
      assert_equal "tencent/hy3:free", nous.model
      assert_equal :openrouter, openrouter.provider
      assert_equal "openrouter/free", openrouter.model
    end
  end

  # O CORAÇÃO DESTA TAREFA, e a correção que a spec não tem.
  #
  # As duas rotas desligam o raciocínio por mecanismos DIFERENTES, e trocar um
  # pelo outro não degrada — quebra. Medido em 2026-08-07:
  #   * Poolside direta: `reasoning_effort: "none"` -> HTTP 400, e "minimal" não
  #     muda nada (12.033 ms / 1.168 tokens contra 9.749 ms / 1.100 do controle).
  #     O que funciona é chat_template_kwargs.enable_thinking = false:
  #     254 ms e ZERO tokens de raciocínio.
  #   * Nous: `reasoning_effort: "none"` chato zera o raciocínio (0 tokens em
  #     6 de 6) e derruba a mediana para 3.097 ms.
  test "o elo da Poolside NUNCA manda reasoning_effort — manda enable_thinking" do
    com_as_duas_chaves do
      poolside = Llm::ModelChain.links.find { |elo| elo.label == "poolside-direta" }

      assert_nil poolside.effort, "reasoning_effort na rota direta é ignorado ou dá HTTP 400"
      assert_equal({ chat_template_kwargs: { enable_thinking: false } }, poolside.params)
    end
  end

  test "o elo do Nous manda reasoning_effort e NUNCA params de chat_template" do
    com_as_duas_chaves do
      nous = Llm::ModelChain.links.find { |elo| elo.label == "nous" }

      assert_equal "none", nous.effort
      assert_nil nous.params
    end
  end

  test "o elo da OpenRouter não manda esforço nem params" do
    com_as_duas_chaves do
      openrouter = Llm::ModelChain.links.find { |elo| elo.label == "openrouter" }

      assert_nil openrouter.effort
      assert_nil openrouter.params
    end
  end

  test "nenhum elo carrega um esforço fora do vocabulário do provedor dele" do
    com_as_duas_chaves do
      Llm::ModelChain.links.each do |elo|
        next if elo.effort.nil?

        assert_includes Llm::ModelChain::NOUS_EFFORTS, elo.effort,
                        "#{elo.label} carrega um esforço que a rota dele recusa com HTTP 400"
      end
    end
  end

  test "sem POOLSIDE_API_KEY o elo da Poolside some e o resto continua" do
    com_env("NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      assert_equal %w[nous openrouter], Llm::ModelChain.links.map(&:label)
    end
  end

  test "sem NOUS_API_KEY o elo do Nous some e o resto continua" do
    com_env("POOLSIDE_API_KEY" => "sk-p", "OPENROUTER_API_KEY" => "sk-o") do
      assert_equal %w[poolside-direta openrouter], Llm::ModelChain.links.map(&:label)
    end
  end

  test "sem as duas chaves novas sobra o comportamento de antes desta spec" do
    com_env("OPENROUTER_API_KEY" => "sk-o") do
      assert_equal %w[openrouter], Llm::ModelChain.links.map(&:label)
    end
  end

  test "chave em branco conta como ausente" do
    com_env("POOLSIDE_API_KEY" => "   ", "NOUS_API_KEY" => "", "OPENROUTER_API_KEY" => "sk-o") do
      assert_equal %w[openrouter], Llm::ModelChain.links.map(&:label)
    end
  end

  test "sem chave nenhuma a cadeia fica vazia em vez de mentir" do
    com_env({}) do
      assert_empty Llm::ModelChain.links
      assert_nil Llm::ModelChain.primary
    end
  end

  test "primary é o primeiro elo disponível, não o primeiro elo possível" do
    com_env("NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      assert_equal "nous", Llm::ModelChain.primary.label
    end
  end

  test "aggregator é o hy3 no Nous e só existe com a chave do Nous" do
    com_env("NOUS_API_KEY" => "sk-n") do
      agregador = Llm::ModelChain.aggregator

      assert_equal "tencent/hy3:free", agregador.model
      assert_equal :nous, agregador.provider
      assert_equal "none", agregador.effort
    end

    com_env("OPENROUTER_API_KEY" => "sk-o") { assert_nil Llm::ModelChain.aggregator }
  end

  # Desde a troca de 2026-08-07 o hy3 é, por escolha, o MESMO modelo do elo 2
  # do chat (nous_link) — então "modelo não aparece em links" deixou de ser a
  # garantia certa para testar (aparece, e é esperado). O que continua valendo
  # é que `aggregator` é um método à parte com rótulo próprio: `links` nunca
  # devolve o elo "nous-agregador", mesmo que o modelo dele coincida com o do
  # elo 2.
  test "o agregador tem rótulo próprio e não aparece dentro de links" do
    com_as_duas_chaves do
      assert_not_includes Llm::ModelChain.links.map(&:label), "nous-agregador"
    end
  end

  test "DISCORD_EFFORT_NOUS válido é respeitado" do
    com_env("NOUS_API_KEY" => "sk-n", "DISCORD_EFFORT_NOUS" => "low") do
      assert_equal "low", Llm::ModelChain.links.first.effort
    end
  end

  # Um valor inválido não degrada: dá HTTP 400 em TODA chamada daquele elo. Cair
  # no padrão conhecido-bom é a única saída segura — e tem de LOGAR, senão vira
  # a mesma dívida do limiar inerte já registrada no MEMORY.md.
  test "DISCORD_EFFORT_NOUS inválido cai no padrão e reclama no log" do
    com_env("NOUS_API_KEY" => "sk-n", "DISCORD_EFFORT_NOUS" => "turbinado") do
      Rails.logger.expects(:warn).with(regexp_matches(/turbinado/)).at_least_once

      assert_equal Llm::ModelChain::DEFAULT_NOUS_EFFORT, Llm::ModelChain.links.first.effort
    end
  end

  test "DISCORD_POOLSIDE_THINKING=true devolve o raciocínio da rota direta" do
    com_env("POOLSIDE_API_KEY" => "sk-p", "DISCORD_POOLSIDE_THINKING" => "true") do
      assert_nil Llm::ModelChain.links.first.params
    end
  end

  test "describe nomeia todos os elos, para o log de boot não mentir" do
    com_as_duas_chaves do
      texto = Llm::ModelChain.describe

      assert_includes texto, "poolside-direta"
      assert_includes texto, "nous"
      assert_includes texto, "openrouter"
    end
  end

  test "describe diz que não há elo nenhum em vez de devolver vazio" do
    com_env({}) { assert_match(/nenhum/i, Llm::ModelChain.describe) }
  end

  test "links não memoiza — trocar a chave entre chamadas muda a cadeia" do
    com_env("OPENROUTER_API_KEY" => "sk-o") do
      assert_equal %w[openrouter], Llm::ModelChain.links.map(&:label)
      ENV["NOUS_API_KEY"] = "sk-n"

      assert_equal %w[nous openrouter], Llm::ModelChain.links.map(&:label)
    end
  end
  # O resumidor NÃO é o elo 1, e essa separação tem de ser guardada: quando ela
  # não existia, trocar o modelo do chat mudou o resumo em silêncio, de 3.180 ms
  # para 9.849 ms. Medido em 2026-08-07, mesmos 6/6 fatos preservados nos três
  # candidatos — só a latência separou.
  test "summarizer é escolhido por latência e NÃO é o elo primário" do
    com_as_duas_chaves do
      resumidor = Llm::ModelChain.summarizer

      assert_equal "poolside/laguna-xs-2.1", resumidor.model
      assert_equal :poolside, resumidor.provider
      assert_not_equal Llm::ModelChain.primary.model, resumidor.model,
                       "resumidor amarrado ao elo 1 muda sozinho quando o chat troca de modelo"
    end
  end

  test "summarizer desliga o raciocínio pelo mecanismo da rota dele" do
    com_as_duas_chaves do
      resumidor = Llm::ModelChain.summarizer

      assert_nil resumidor.effort, "a rota direta da Poolside ignora reasoning_effort"
      assert_equal({ chat_template_kwargs: { enable_thinking: false } }, resumidor.params)
    end
  end

  test "sem a chave da Poolside não há resumidor próprio, e quem chama cai na cadeia" do
    com_env("NOUS_API_KEY" => "sk-n", "OPENROUTER_API_KEY" => "sk-o") do
      assert_nil Llm::ModelChain.summarizer
    end
  end

end
