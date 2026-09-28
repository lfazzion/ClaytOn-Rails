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
#   bin/rails x:posts USUARIO=<screen_name> [LIMITE=20]         -> {"posts": [...]} (posts e respostas; sem reposts)
#   bin/rails x:feed [TIPO=para_voce|seguindo] [CURSOR=] [LIMITE=20] -> {"posts": [...], "proximo_cursor"}
#   bin/rails x:artigo TITULO=arquivo|- CORPO=arquivo|- [VISIBILIDADE=Public] [CONVERSA=ByInvitation] [RASCUNHO=<id>]
#                                                               -> {"id","tweet_id","url"}
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
  # tipo "Incerto": a escrita pode ter acontecido no X (falha de rede depois do envio).
  desc "Posta (ou responde): TEXTO=-|arquivo [RESPOSTA_A=<id|link>]"
  task postar: :environment do
    exit Fetcher::XComando.executa {
      texto = Fetcher::XComando.le_texto(ENV.fetch("TEXTO") { raise ArgumentError, "uso: x:postar TEXTO=-|arquivo" })
      alvo = ENV["RESPOSTA_A"].to_s.empty? ? nil : Fetcher::XLeitura.tweet_id(ENV["RESPOSTA_A"])
      Fetcher::Channels::XEscrita.postar(texto: texto, em_resposta_a: alvo)
    }
  end

  %i[curtir repostar apagar].each do |nome|
    desc "#{nome.capitalize} um post: ID=<id|link>"
    task nome => :environment do
      exit Fetcher::XComando.executa {
        id = Fetcher::XLeitura.tweet_id(ENV.fetch("ID") { raise ArgumentError, "uso: x:#{nome} ID=<id|link>" })
        Fetcher::Channels::XEscrita.public_send(nome, id: id)
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

  desc "Posts e respostas da conta com métricas (sem reposts): USUARIO=<screen_name> [LIMITE=20]"
  task posts: :environment do
    exit Fetcher::XComando.executa {
      perfil = Fetcher::Channels::XConta.perfil(usuario: ENV.fetch("USUARIO") { raise ArgumentError, "uso: x:posts USUARIO=" })
      { "posts" => Fetcher::Channels::XConta.posts(usuario_id: perfil["id"], limite: Integer(ENV.fetch("LIMITE", "20"))) }
    }
  end

  desc "Uma pagina do feed da conta (sem promovidos): [TIPO=para_voce|seguindo] [CURSOR=] [LIMITE=20]"
  task feed: :environment do
    exit Fetcher::XComando.executa {
      Fetcher::Channels::XFeed.ler(tipo: ENV.fetch("TIPO", "para_voce"), cursor: ENV["CURSOR"].presence,
                                   limite: ENV.fetch("LIMITE", "20"))
    }
  end

  # Artigo longo (X Article). Título e corpo vêm de `-` (stdin) ou de arquivo, como nas outras
  # escritas; o corpo é markdown de um subconjunto (parágrafo, #/##, - , > , link, **negrito**,
  # *itálico*, ~~riscado~~) e o que não é suportado (código, tabela, imagem) é recusado com erro
  # tipado, sem chegar ao X. Salvar o artigo com o comando é decisão de quem roda: é escrita
  # pública na conta.
  #
  # SÓ UM dos dois pode ser `-`: o stdin é um único fluxo, e `le_texto` o consome inteiro. Com os
  # dois em `-` o título viria com o corpo dentro e o corpo sairia vazio — um artigo publicado com o
  # texto trocado. Por isso a recusa é explícita, e não um combinado calado.
  #
  # RASCUNHO=<id> RETOMA um rascunho que já existe no X (é o id que a falha anterior devolveu na
  # linha de erro). TITULO e CORPO continuam obrigatórios: o rascunho é reescrito com eles, e sem
  # eles a retomada publicaria o rascunho antigo com título vazio.
  desc "Publica artigo: TITULO=-|arquivo CORPO=-|arquivo [VISIBILIDADE=Public] [CONVERSA=ByInvitation] " \
       "[RASCUNHO=<id>]"
  task artigo: :environment do
    exit Fetcher::XComando.executa {
      uso = "uso: x:artigo TITULO=-|arquivo CORPO=-|arquivo [VISIBILIDADE=] [CONVERSA=] [RASCUNHO=<id>]"
      # A retomada NÃO abre exceção de uso: quem re-executa depois de uma falha tem TITULO e CORPO
      # na mão de novo, e a mensagem de erro mandou colar os dois com o RASCUNHO=<id>.
      #
      # `RASCUNHO=` VAZIO é recusado, e não apagado com `presence`: ausente é o caminho normal
      # (cria rascunho novo), mas presente-e-vazio é o sinal de que a pessoa colou o comando de
      # retomada sem o id. Deixar passar criava OUTRO rascunho — a duplicação que a retomada
      # existe para impedir, agora silenciosa. Ausente segue ausente; só o vazio é erro.
      raise ArgumentError, "#{uso} (RASCUNHO= vazio: use um id de artigo ou omita para criar rascunho novo)" if
        ENV.key?("RASCUNHO") && ENV["RASCUNHO"].to_s.strip.empty?
      retomada = ENV["RASCUNHO"].presence
      origem_titulo = ENV.fetch("TITULO") { raise ArgumentError, "#{uso} (com RASCUNHO= informe TITULO e CORPO)" }
      origem_corpo = ENV.fetch("CORPO") { raise ArgumentError, "#{uso} (com RASCUNHO= informe TITULO e CORPO)" }
      raise ArgumentError, "#{uso} (so um dos dois pode ser '-': o stdin e um fluxo so)" if
        origem_titulo == "-" && origem_corpo == "-"

      argumentos = {
        titulo: Fetcher::XComando.le_texto(origem_titulo),
        corpo: Fetcher::XComando.le_texto(origem_corpo),
        visibilidade: ENV.fetch("VISIBILIDADE", Fetcher::Channels::XArtigo::VISIBILIDADE_PADRAO),
        conversa: ENV.fetch("CONVERSA", Fetcher::Channels::XArtigo::CONVERSA_PADRAO)
      }
      # `:rascunho` só entra quando existe: sem RASCUNHO= a chamada é a de sempre, e quem chama o
      # canal por fora não precisa conhecer a palavra nova.
      argumentos[:rascunho] = retomada if retomada
      Fetcher::Channels::XArtigo.publicar(**argumentos)
    }
  end
end
