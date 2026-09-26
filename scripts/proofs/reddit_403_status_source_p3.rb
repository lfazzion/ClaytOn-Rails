# frozen_string_literal: true

# PROVA (fix t_324ad4fd, parte 3) — a sessão do Chrome responde AO VIVO?
#
# A p2 mediu ZERO eventos até em example.com, com 20s de goto e innerText
# vazio. Duas leituras possíveis, e elas não podem ser confundidas:
#
#   (V) a sessão CDP está envenenada AGORA (o Chrome responde ao /json/version
#       mas nenhuma requisição completa — o episodio documentado no compose);
#   (R) a sessão está viva e quem falha é o caminho do script (page criada em
#       contexto isolado + `on` sem o `subscribe` do Ferrum).
#
# O par de controle é o mesmo host pelo MESMO browser, um pelo caminho cru do
# Ferrum (`browser.go_to`, que é o que o Ferrum prepara e assina) e um pelo
# caminho isolado que o BrowserSession usa. Se o cru funciona e o isolado não,
# é (R) e o conserto é no Ruby. Se NENHUM funciona, é (V) e a p2 mediu a
# sessão morta, não o código.
#
#   docker cp scripts/proofs/reddit_403_status_source_p3.rb docker-app-1:/tmp/st3.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/st3.rb

def linha(t)
  puts "\n=== #{t} ==="
end

linha "1) A sessao CDP responde?"
require "net/http"
http = Net::HTTP.new("chrome", 9222)
http.open_timeout = 3
http.read_timeout = 5
begin
  req = Net::HTTP::Get.new("/json/version", "Host" => "localhost")
  res = http.request(req)
  puts "  /json/version -> #{res.code}"
  puts "  body: #{res.body.to_s[0, 200]}"
rescue StandardError => e
  puts "  ERRO: #{e.class}: #{e.message}"
end

linha "2) Criando o browser pelo MESMO caminho de producao (PageFetcher)"
browser = Fetcher::PageFetcher.browser
puts "  browser=#{browser.class} contexts=#{browser.contexts.size}"
begin
  puts "  alive?= #{Fetcher::PageFetcher.send(:alive?, browser)}"
rescue StandardError => e
  puts "  alive? ERRO: #{e.class}: #{e.message}"
end

linha "3) CAMINHO CRU: browser.go_to (o Ferrum assina os eventos sozinho)"
eventos = []
id = browser.on("Network.responseReceived") do |params|
  eventos << { type: params["type"], status: params.dig("response", "status"),
               url: params.dig("response", "url") }
end
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
erro = nil
begin
  browser.go_to("https://example.com/", timeout: 20)
rescue StandardError => e
  erro = "#{e.class}: #{e.message}"
end
dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
body_cru = (browser.body rescue "").to_s
puts "  go_to: #{dt}s erro=#{erro.inspect}"
puts "  browser.body: #{body_cru[0, 120].inspect}"
puts "  browser.network.status: #{(browser.network.status rescue nil).inspect}"
puts "  browser.network.traffic: #{(browser.network.traffic.size rescue nil)}"
puts "  eventos responseReceived: #{eventos.size}"
eventos.first(4).each { |e| puts "    type=#{e[:type]} status=#{e[:status].inspect} url=#{e[:url].to_s[0, 60]}" }
browser.off("Network.responseReceived", id) rescue nil

linha "4) CAMINHO ISOLADO: contexts.create + create_page (o do BrowserSession)"
ctx = browser.contexts.create(disposeOnDetach: true)
page = ctx.create_page
ev2 = []
id2 = page.on("Network.responseReceived") do |params|
  ev2 << { type: params["type"], status: params.dig("response", "status"), url: params.dig("response", "url") }
end
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
erro2 = nil
begin
  page.timeout = 20
  page.go_to("https://example.com/")
rescue StandardError => e
  erro2 = "#{e.class}: #{e.message}"
end
dt2 = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
body_iso = (page.body rescue "").to_s
puts "  go_to: #{dt2}s erro=#{erro2.inspect}"
puts "  page.body: #{body_iso[0, 120].inspect}"
puts "  page.network.status: #{(page.network.status rescue nil).inspect}"
puts "  page.network.traffic: #{(page.network.traffic.size rescue nil)}"
puts "  eventos responseReceived: #{ev2.size}"
ev2.first(4).each { |e| puts "    type=#{e[:type]} status=#{e[:status].inspect} url=#{e[:url].to_s[0, 60]}" }
page.off("Network.responseReceived", id2) rescue nil

linha "5) VEREDITO"
puts "  cru:      body=#{body_cru.empty? ? 'VAZIO' : 'preenchido'} status=#{(browser.network.status rescue nil).inspect} eventos=#{eventos.size}"
puts "  isolado:  body=#{body_iso.empty? ? 'VAZIO' : 'preenchido'} status=#{(page.network.status rescue nil).inspect} eventos=#{ev2.size}"
puts "  (V) sessao envenenada: os DOIS vazios."
puts "  (R) problema no caminho isolado: so o isolado vazio."
puts "  (S) evento nao chega em nenhum dos dois, mas o body volta: a fonte do"
puts "      status tem de ser outra (ver p4)."
begin
  page&.close
  ctx&.dispose
rescue StandardError
  nil
end
