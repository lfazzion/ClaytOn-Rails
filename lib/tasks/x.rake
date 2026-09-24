# frozen_string_literal: true

# Leitura do X por linha de comando (usada pelo agente Hermes; lógica em Fetcher::XLeitura).
#   bin/rails x:buscar CONSULTAS=arquivo|- [LIMITE=20]     -> uma linha JSON por consulta
#   bin/rails x:conversa ID=<id ou link> [LIMITE=40] [FORMATO=texto|json]
namespace :x do
  desc "Busca no X: CONSULTAS=arquivo (uma por linha; - = stdin) [LIMITE=20]. Saida: uma linha JSON por consulta"
  task buscar: :environment do
    origem = ENV.fetch("CONSULTAS") { abort "uso: bin/rails x:buscar CONSULTAS=arquivo|- [LIMITE=20]" }
    texto = origem == "-" ? $stdin.read : File.read(origem)
    consultas = texto.lines.map(&:strip).reject(&:empty?)
    abort "x:buscar: nenhuma consulta em #{origem}" if consultas.empty?

    resultados = Fetcher::XLeitura.buscar(consultas, limite: Integer(ENV.fetch("LIMITE", "20")))
    resultados.each { |r| puts JSON.generate(r) }
    falhas = resultados.count { |r| r["erro"] }
    abort "x:buscar: #{falhas} de #{resultados.size} consulta(s) falharam (campo erro)" if falhas.positive?
  end

  desc "Post + comentarios do X: ID=<id ou link> [LIMITE=40] [FORMATO=texto|json]"
  task conversa: :environment do
    entrada = ENV.fetch("ID") { abort "uso: bin/rails x:conversa ID=<id ou link> [LIMITE=40] [FORMATO=texto|json]" }
    limite = Integer(ENV.fetch("LIMITE", Fetcher::Channels::XConversation::DEFAULT_LIMIT.to_s))
    conversa = Fetcher::XLeitura.conversa(entrada, limite: limite)
    puts(ENV["FORMATO"] == "json" ? JSON.generate(conversa) : Fetcher::XLeitura.conversa_texto(conversa))
  rescue Fetcher::Channels::Error, ArgumentError => e
    abort "x:conversa: #{e.class}: #{e.message}"
  end
end
