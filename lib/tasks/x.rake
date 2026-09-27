# frozen_string_literal: true

# Leitura e escrita no X por linha de comando (usada pelo agente Hermes e pelo porteiro do
# experimento-x; lógica em Fetcher::XLeitura, Fetcher::Channels::XEscrita/XConta e Fetcher::XComando).
#   bin/rails x:buscar CONSULTAS=arquivo|- [LIMITE=20]     -> uma linha JSON por consulta
#   bin/rails x:conversa ID=<id ou link> [LIMITE=40] [FORMATO=texto|json]
#   bin/rails x:postar TEXTO=-|arquivo [RESPOSTA_A=<id|link>]  -> {"id","url"}
#   bin/rails x:curtir ID=<id|link>                             -> {"id"}
#   bin/rails x:repostar ID=<id|link>                           -> {"id"}
#   bin/rails x:apagar ID=<id|link>                             -> {"id"}
#   bin/rails x:seguir USUARIO=<screen_name>                    -> {"usuario_id"}
#   bin/rails x:perfil USUARIO=<screen_name>                    -> {"id","usuario","seguidores","seguindo","posts"}
#   bin/rails x:posts USUARIO=<screen_name> [LIMITE=20]         -> {"posts": [...]}
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

  # Escrita e conta (porteiro do experimento-x). Saída: uma linha JSON; erro -> {"erro","tipo"} e exit 1.
  desc "Posta (ou responde): TEXTO=-|arquivo [RESPOSTA_A=<id|link>]"
  task postar: :environment do
    exit Fetcher::XComando.executa {
      texto = Fetcher::XComando.le_texto(ENV.fetch("TEXTO") { raise ArgumentError, "uso: x:postar TEXTO=-|arquivo" })
      alvo = ENV["RESPOSTA_A"].to_s.empty? ? nil : Fetcher::XLeitura.tweet_id(ENV["RESPOSTA_A"])
      Fetcher::Channels::XEscrita.postar(texto: texto, em_resposta_a: alvo)
    }
  end

  { curtir: :curtir, repostar: :repostar, apagar: :apagar }.each do |nome, metodo|
    desc "#{nome.capitalize} um post: ID=<id|link>"
    task nome => :environment do
      exit Fetcher::XComando.executa {
        id = Fetcher::XLeitura.tweet_id(ENV.fetch("ID") { raise ArgumentError, "uso: x:#{nome} ID=<id|link>" })
        Fetcher::Channels::XEscrita.public_send(metodo, id: id)
      }
    end
  end

  desc "Segue uma conta: USUARIO=<screen_name>"
  task seguir: :environment do
    exit Fetcher::XComando.executa {
      usuario = ENV.fetch("USUARIO") { raise ArgumentError, "uso: x:seguir USUARIO=<screen_name>" }
      Fetcher::Channels::XEscrita.seguir(usuario_id: Fetcher::Channels::XConta.perfil(usuario: usuario)["id"])
    }
  end

  desc "Perfil da conta: USUARIO=<screen_name>"
  task perfil: :environment do
    exit Fetcher::XComando.executa {
      Fetcher::Channels::XConta.perfil(usuario: ENV.fetch("USUARIO") { raise ArgumentError, "uso: x:perfil USUARIO=" })
    }
  end

  desc "Posts da conta com métricas: USUARIO=<screen_name> [LIMITE=20]"
  task posts: :environment do
    exit Fetcher::XComando.executa {
      perfil = Fetcher::Channels::XConta.perfil(usuario: ENV.fetch("USUARIO") { raise ArgumentError, "uso: x:posts USUARIO=" })
      { "posts" => Fetcher::Channels::XConta.posts(usuario_id: perfil["id"], limite: Integer(ENV.fetch("LIMITE", "20"))) }
    }
  end
end
