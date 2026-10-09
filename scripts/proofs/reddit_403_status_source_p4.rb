# frozen_string_literal: true

# PROVA (fix t_324ad4fd, parte 4) — CONTROLE COM CHROME NOVO, o do par de
# mutação da p3.
#
# A p3 mediu, no Chrome de PRODUÇÃO (24h de uptime): caminho isolado
# (contexts.create + create_page, o do BrowserSession) com body VAZIO após 20s
# e ZERO `Network.responseReceived`. Isso é consistente com a sessão
# envenenada documentada no compose ("CDP respondia e NENHUMA requisição
# completava") e é INCOMPATÍVEL com a leitura "o código está errado".
#
# (Correção de método: o "caminho cru com body preenchido" da p3 era
# artefato do script — `browser.go_to(url, timeout:)` não aceita `timeout:` e
# levantou ArgumentError, então o body lido era o da navegação ANTERIOR. Este
# arquivo repete os dois caminhos no MESMO Chrome, na MESMA ordem, com o
# `go_to` correto.)
#
# O Chrome de controle é NOVO (container chrome-p4, mesma imagem, mesma rede,
# mesmo IP de saída) — o par é o que fecha a questão:
#
#   Chrome novo, isolado com body  -> (R) o defeito é do caminho isolado.
#   Chrome novo, isolado VAZIO      -> a p3 mediu a sessão envenenada, não o
#                                     código; e o 403 do old.reddit precisa de
#                                     uma fonte de status que não depende do
#                                     CDP.
#
#   docker cp scripts/proofs/reddit_403_status_source_p4.rb docker-app-1:/tmp/st4.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/st4.rb

CHROME_NOVO = ENV.fetch("CHROME_P4_HOST", "chrome-p4")

def linha(t)
  puts "\n=== #{t} ==="
end

def medir(page, alvo, timeout:)
  eventos = []
  erro = nil
  id = nil
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    page.timeout = timeout
    id = page.on("Network.responseReceived") do |params|
      eventos << { type: params["type"], status: params.dig("response", "status"),
                   url: params.dig("response", "url"), ip: params.dig("response", "remoteIPAddress") }
    end
    page.go_to(alvo)
  rescue StandardError => e
    erro = "#{e.class}: #{e.message[0, 60]}"
  end
  dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
  body = (page.body rescue "").to_s
  begin
    page&.off("Network.responseReceived", id) if id
  rescue StandardError
    nil
  end
  { duracao: dt, erro: erro, body: body.strip[0, 90], eventos: eventos,
    docs: eventos.select { |e| e[:type] == "Document" },
    net_status: (page.network.status rescue nil) }
end

def mostrar(tag, r)
  puts "\n--- #{tag} ---"
  puts "  dur=#{r[:duracao]}s erro=#{r[:erro].inspect}"
  puts "  body=#{r[:body].empty? ? '(VAZIO)' : r[:body].inspect}"
  puts "  network.status=#{r[:net_status].inspect}  eventos=#{r[:eventos].size} docs=#{r[:docs].size}"
  r[:docs].first(3).each { |d| puts "    doc status=#{d[:status].inspect} ip=#{d[:ip].inspect} url=#{d[:url].to_s[0, 60]}" }
end

linha "1) Chrome de CONTROLE (novo): #{CHROME_NOVO}"
require "socket"
ws_url = begin
  uri = URI("http://#{CHROME_NOVO}:9222/json/version")
  resposta = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 5) do |h|
    req = Net::HTTP::Get.new(uri)
    req["Host"] = "localhost"
    h.request(req)
  end
  JSON.parse(resposta.body)["webSocketDebuggerUrl"]
rescue StandardError => e
  puts "  ERRO ao ler /json/version: #{e.class}: #{e.message}"
  nil
end
puts "  ws_url=#{ws_url.inspect}"
abort("sem Chrome de controle") if ws_url.nil?

ws = URI(ws_url)
# Mesmo caminho que o FerumConfig usa em produção (config/initializers/ferrum.rb:62):
# `Addrinfo#getaddrinfo` devolve o OBJETO e `#ip_address` dá o IPv4. O
# `Socket.getaddrinfo` devolvia a sockaddr crua, cuja forma muda entre versões —
# usar a mesma API do INITializer tira a fonte de erro do script da medição.
ip = Addrinfo.getaddrinfo(CHROME_NOVO, nil, Socket::AF_INET, :STREAM).first.ip_address
ws.host = ip
ws.port = 9222
puts "  ws resolvido: #{ws}"

browser = Ferrum::Browser.new(ws_url: ws.to_s, timeout: 15, process_timeout: 60)
puts "  browser=#{browser.class} versao=#{(browser.version rescue nil)}"

linha "2) CHROME NOVO — caminho CRU (mesma sessao, primeiro)"
mostrar("cru / example.com", medir(browser, "https://example.com/", timeout: 20))

linha "3) CHROME NOVO — caminho ISOLADO (o do BrowserSession)"
ctx = browser.contexts.create(disposeOnDetach: true)
page = ctx.create_page
mostrar("isolado / example.com", medir(page, "https://example.com/", timeout: 20))

linha "4) CHROME NOVO — caminho ISOLADO no ALVO do card"
mostrar("isolado / old.reddit",
        medir(page, "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/",
              timeout: 15))

linha "5) VEREDITO"
begin
  page&.close
  ctx&.dispose
rescue StandardError
  nil
end
begin
  browser.quit
rescue StandardError
  nil
end
