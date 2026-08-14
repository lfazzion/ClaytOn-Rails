# frozen_string_literal: true

require "test_helper"
require "llm/model_chain"

# Fecha a porta do achado de revisao do PR de LLM: o caminho que o chat
# realmente usa (ModelChain, consumido pelo ChatSessionManager) nao pode
# apontar para modelo fora do registry da gem — senao toda mensagem cai em
# ModelNotFoundError -> "Erro ao processar". A versao antiga do bug vivia em
# PRIMARY_MODEL/FALLBACK_MODEL (constantes do ChatSessionManager antigo).
class ChatModelsRegistryTest < ActiveSupport::TestCase
  # `Llm::ModelChain.links` monta cada elo SÓ quando a chave daquela rota está no
  # ambiente (`lib/llm/model_chain.rb:146,153,160` via `chave?`) — chave ausente
  # ENCURTA a cadeia de propósito. No container de teste (e no CI) não existe
  # chave nenhuma, então `links` voltava [] e o teste morria no `refute_empty`
  # sem nunca exercitar o que ele existe para cobrir: o mapeamento
  # (modelo, provider) de cada elo contra o registry da gem.
  #
  # A correção NÃO é aceitar a cadeia vazia (isso desligaria a cobertura) nem ler
  # segredo: os nomes das chaves são presença, não valor. Setamos valores
  # obviamente falsos para que TODOS os elos sejam montados e verificados — a
  # asserção fica mais forte, não mais fraca. `links` não é memoizado de
  # propósito (model_chain.rb:68-71), então o ENV vale na hora da chamada.
  CHAVES_DE_ROTA = %w[NOUS_API_KEY POOLSIDE_API_KEY OPENROUTER_API_KEY].freeze
  VALOR_FALSO = "chave-teste-invalida"

  def com_todas_as_rotas_no_ambiente
    anteriores = CHAVES_DE_ROTA.to_h { |nome| [nome, ENV.key?(nome) ? ENV[nome] : :ausente] }
    CHAVES_DE_ROTA.each { |nome| ENV[nome] = VALOR_FALSO if ENV[nome].to_s.strip.empty? }
    yield
  ensure
    anteriores.each do |nome, valor|
      valor == :ausente ? ENV.delete(nome) : ENV[nome] = valor
    end
  end

  test "cada elo da ModelChain resolve no registry da gem" do
    com_todas_as_rotas_no_ambiente do
      links = Llm::ModelChain.links
      refute_empty links, "sem elos, o chat nao tem rota nenhuma"
      assert_equal CHAVES_DE_ROTA.size, links.size,
                   "com todas as chaves presentes a cadeia tem de montar os 3 elos"
      links.each do |link|
        assert RubyLLM.models.find(link.model, link.provider),
               "elo #{link.label} aponta para #{link.model} (#{link.provider}), fora do registry"
      end
    end
  end
end
