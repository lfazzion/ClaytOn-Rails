# frozen_string_literal: true

require "test_helper"
require "llm/model_chain"

# Fecha a porta do achado de revisao do PR de LLM: o caminho que o chat
# realmente usa (ModelChain, consumido pelo ChatSessionManager) nao pode
# apontar para modelo fora do registry da gem — senao toda mensagem cai em
# ModelNotFoundError -> "Erro ao processar". A versao antiga do bug vivia em
# PRIMARY_MODEL/FALLBACK_MODEL (constantes do ChatSessionManager antigo).
class ChatModelsRegistryTest < ActiveSupport::TestCase
  test "cada elo da ModelChain resolve no registry da gem" do
    links = Llm::ModelChain.links
    refute_empty links, "sem elos, o chat nao tem rota nenhuma"
    links.each do |link|
      assert RubyLLM.models.find(link.model, link.provider),
             "elo #{link.label} aponta para #{link.model} (#{link.provider}), fora do registry"
    end
  end
end
