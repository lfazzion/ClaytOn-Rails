# frozen_string_literal: true

require "json"

module Fetcher
  # Envelope dos comandos `bin/rails x:*` de escrita/conta: UMA linha JSON no stdout, erro tipado
  # como {"erro","tipo"} e status 1. O porteiro do experimento-x lê só isso.
  module XComando
    module_function

    def executa(saida = $stdout)
      saida.puts JSON.generate(yield)
      0
    rescue Channels::Error, CookieJar::Expired, ArgumentError, SystemCallError => e
      erro!(saida, e)
    rescue StandardError => e
      # Última rede: qualquer outra exceção também sai como uma linha JSON, nunca como backtrace.
      erro!(saida, e)
    end

    # `XLer::Bloqueado` responde se o bloqueio veio depois de a rede ter sido usada
    # (`apos_rede`). A pergunta "a requisição saiu?" decide se o porteiro devolve a
    # vaga da cota, então o nome precisa atravessar o envelope — ver `ServicoX.ler`.
    #
    # Qualquer OUTRA recusa da SsrfGuard segue igual, sem o campo: a resposta honesta
    # para as outras rotas (que contam erro como erro) continua sendo a mesma.
    def erro!(saida, erro)
      corpo = { "erro" => erro.message, "tipo" => erro.class.name.to_s.split("::").last }
      if erro.respond_to?(:bloqueado_apos_rede)
        corpo["bloqueado_apos_rede"] = erro.bloqueado_apos_rede ? true : false
      end
      saida.puts JSON.generate(corpo)
      1
    end

    # `-` lê o stdin inteiro; senão é caminho de arquivo. Tira só a quebra de linha final.
    def le_texto(origem, entrada = $stdin)
      (origem == "-" ? entrada.read : File.read(origem)).chomp
    end
  end
end
