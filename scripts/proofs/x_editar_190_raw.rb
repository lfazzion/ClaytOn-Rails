# frozen_string_literal: true

# Prova CRUA da traducao da recusa 190 no caminho de edicao (card t_b4d83a56).
# Roda com: docker compose -f docker/docker-compose.yml run --rm test runner - < scripts/proofs/x_editar_190_raw.rb
# (o stdin do runner e lido depois de bootar o app, e o codigo vai no proprio arquivo).

require "json"
require "stringio"
require_relative "config/environment"

TEXTO_190 = "Authorization: Status *** failed: Tweet creation failed. (190)"
CORPO_190 = { "errors" => [{ "message" => TEXTO_190 }] }.to_json
ALVO = "2104670335882977677"
Resposta = Struct.new(:status, :body, :headers, keyword_init: true)

ALVO_COOKIE = [{ "name" => "auth_token", "value" => "segredo-auth-123" }, { "name" => "ct0", "value" => "csrf-ct0-456" }]

def instalar_gates!
  # Todas as tres recebem o DOMINIO (`for(domain)`, `valid?(domain)`, `require!(domain)` —
  # lib/fetcher/cookie_jar.rb:90,100,104). Duble de aridade zero estoura
  # `ArgumentError: given 1, expected 0` e MASCARA a traducao (foi a 1a tentativa desta prova).
  Fetcher::CookieJar.define_singleton_method(:valid?) { |_dominio| true }
  Fetcher::CookieJar.define_singleton_method(:require!) { |_dominio| nil }
  Fetcher::CookieJar.define_singleton_method(:for) { |_dominio| ALVO_COOKIE }
  # `exceeded?(host, max:, scope:, per_hour:)` — lib/fetcher/host_rate_limiter.rb:23. O splat
  # absorve o host posicional e os dois kwargs, para o duble não virar mais uma fonte de
  # `ArgumentError` (a 2a mascarou a tradução: "given 2, expected 0").
  Fetcher::HostRateLimiter.define_singleton_method(:exceeded?) { |_host, **_opts| false }
  Fetcher::XQueryIdResolver.define_singleton_method(:new) { Class.new { def resolve(_o, force: false) = "QID" }.new }
  txid = Class.new { def evidence_header(**) = "TXID" }.new
  Fetcher::Channels::XGraphql::BuildTxid.define_singleton_method(:new) { txid }
end

def stub_de(corpo)
  Fetcher::SafeHttpClient.define_singleton_method(:post) do |_url, json:, headers: nil|
    $stdout.puts "  (foi para o X) .../#{json['queryId']}/CreateTweet  edit_options=#{json['variables']['edit_options'].inspect}"
    Resposta.new(status: 200, body: corpo, headers: {})
  end
end

def envelope
  saida = StringIO.new
  Fetcher::XComando.executa(saida) { Fetcher::Channels::XEditar.editar(id: ALVO, texto: "texto novo") }
  saida.string
end

instalar_gates!

puts "ANTES (a mensagem crua que o smoke real mediu em 29/09/2026, imagem 0c76a60):"
puts %({"erro":"CreateTweet: erro do X: #{TEXTO_190}","tipo":"ResponseError"})

puts "\nDEPOIS (MESMO corpo, MESMO caminho de edicao, agora traduzido):"
stub_de(CORPO_190)
puts envelope

# O caminho feliz com o MESMO codigo: prova de que o gancho nao recusa tudo.
controle = { "initial_tweet_id" => ALVO, "edit_tweet_ids" => [ALVO, "2104299999999999999"],
             "editable_until_msecs" => "1790639000000", "is_edit_eligible" => true, "edits_remaining" => 2 }
feliz = { "data" => { "create_tweet" => { "tweet_results" => {
  "result" => { "rest_id" => "2104299999999999999", "edit_control" => controle }
} } } }.to_json
puts "\nCAMINHO FELIZ (mesmo codigo, id novo utilizavel):"
stub_de(feliz)
puts envelope
