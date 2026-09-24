# frozen_string_literal: true

require "time"

module Fetcher
  # Leitura do X pronta para quem lê de fora do bot (o agente Hermes, por `bin/rails x:*`):
  # busca várias consultas e devolve a conversa de um post (raiz + comentários) como texto.
  # Usa os mesmos canais do bot (XGraphql e XConversation) — uma implementação só.
  module XLeitura
    ID_REGEX = /(\d{15,25})/
    INTERVALO_BUSCA = 16 # segundos entre consultas: o limitador local da busca aceita 4/min

    module_function

    def tweet_id(entrada)
      id = entrada.to_s[%r{status(?:es)?/(\d{15,25})}, 1] || entrada.to_s[ID_REGEX, 1]
      raise ArgumentError, "não achei o id do post em #{entrada.inspect}" if id.nil?

      id
    end

    # Uma entrada por consulta: {"consulta", "posts", "erro"}. Falha de uma consulta não
    # interrompe as outras; o erro fica registrado nela.
    def buscar(consultas, limite: 20, intervalo: INTERVALO_BUSCA, dormir: ->(s) { sleep(s) })
      consultas.each_with_index.map do |consulta, i|
        dormir.call(intervalo) if i.positive?
        posts = Channels::XGraphql.search(query: consulta, limit: limite)
        { "consulta" => consulta, "posts" => posts, "erro" => nil }
      rescue StandardError => e
        Rails.logger.warn "[Fetcher::XLeitura] busca #{consulta.inspect} falhou: #{e.class}: #{e.message}"
        { "consulta" => consulta, "posts" => [], "erro" => "#{e.class}: #{e.message}" }
      end
    end

    def conversa(entrada, limite: Channels::XConversation::DEFAULT_LIMIT)
      Channels::XConversation.fetch(tweet_id: tweet_id(entrada), limit: limite)
    end

    def conversa_texto(conversa)
      raiz = conversa["root"] || {}
      comentarios = conversa["replies"] || []
      linhas = ["# Post #{raiz['id']} — https://x.com/i/status/#{raiz['id']}", "", tweet_texto(1, raiz), "",
                "## Comentários (#{comentarios.size})", ""]
      comentarios.each_with_index { |c, i| linhas.push(tweet_texto(i + 2, c), "") }
      linhas.join("\n")
    end

    # Métrica ausente aparece como "?" — nunca como 0 (zero é zero de verdade).
    def tweet_texto(numero, tweet)
      cabecalho = ["[#{numero}] @#{tweet['author'] || '?'}", "♥#{tweet['likes'] || '?'}", "↳#{tweet['replies'] || '?'}"]
      data = formata_data(tweet["created_at"])
      cabecalho << data if data
      "#{cabecalho.join(' · ')}\n#{tweet['text']}"
    end

    def formata_data(valor)
      return nil if valor.nil? || valor.to_s.empty?

      Time.parse(valor.to_s).utc.strftime("%Y-%m-%d %H:%M UTC")
    rescue ArgumentError
      nil
    end
  end
end
