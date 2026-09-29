# frozen_string_literal: true

# YouTube por linha de comando para o porteiro do experimento-x (só leitura + curtir; nada de comentar/postar).
#   bin/rails yt:feed [LIMITE=20]                -> {"videos": [{"id","titulo","canal","duracao","url"}]}
#   bin/rails yt:buscar CONSULTA=<texto> [LIMITE=10] -> {"videos": [...]}
#   bin/rails yt:assistir ID=<id|link>           -> {"id","titulo","canal","idioma","automatica","texto"}
namespace :yt do
  desc "Página inicial de recomendações da conta: [LIMITE=20]"
  task feed: :environment do
    exit Fetcher::XComando.executa {
      { "videos" => Fetcher::Channels::Youtube.feed(limit: Integer(ENV.fetch("LIMITE", "20"))) }
    }
  end

  desc "Busca no YouTube: CONSULTA=<texto> [LIMITE=10]"
  task buscar: :environment do
    exit Fetcher::XComando.executa {
      consulta = ENV.fetch("CONSULTA") { raise ArgumentError, "uso: yt:buscar CONSULTA=<texto>" }
      itens = Fetcher::Channels::Youtube.search(query: consulta, limit: Integer(ENV.fetch("LIMITE", "10")))
      { "videos" => itens.map { |i| Fetcher::Channels::Youtube.para_agente(i) } }
    }
  end

  desc "Transcrição + marca como assistido: ID=<id|link>"
  task assistir: :environment do
    exit Fetcher::XComando.executa {
      entrada = ENV.fetch("ID") { raise ArgumentError, "uso: yt:assistir ID=<id|link>" }
      Fetcher::Channels::Youtube.video_id!(entrada)
      Fetcher::Channels::Youtube.assistir(url: entrada)
    }
  end
end
