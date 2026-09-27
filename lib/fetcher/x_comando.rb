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
      saida.puts JSON.generate("erro" => e.message, "tipo" => e.class.name.split("::").last)
      1
    end

    # `-` lê o stdin inteiro; senão é caminho de arquivo. Tira só a quebra de linha final.
    def le_texto(origem, entrada = $stdin)
      (origem == "-" ? entrada.read : File.read(origem)).chomp
    end
  end
end
