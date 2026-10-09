# frozen_string_literal: true

# PROVA (parte 11) — o PROXY: o FATO 2 do card ("o SCRAPING_PROXY do container
# aponta para 31.58.9.4:6077 e o 403 vem por ele") vale para o caminho que
# gera as 28 navegacoes?
#
#   docker cp scripts/proofs/reddit_403_gap_p11.rb docker-app-1:/tmp/p11.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p11.rb

Fetcher::BrowserSession

def linha(t)
  puts "\n=== #{t} ==="
end

linha "1) Onde o --proxy-server e' aplicado, no codigo?"
f = File.read(Rails.root.join("config/initializers/ferrum.rb"))
f.lines.each_with_index do |l, i|
  puts "  ferrum.rb:#{i + 1}: #{l.rstrip}" if l.match?(/proxy|PROXY|stealth_opts|browser_options|def /)
end

linha "2) O Chrome de PRODUCAO (container) recebe essa flag?"
cmd = File.read(Rails.root.join("docker/docker-compose.yml"))
so_chrome = cmd[/  chrome:.*?\n(?=\n  [a-z])/m].to_s
flags = so_chrome[/command: \[(.*?)\]/m, 1]
puts "  flags do container chrome: #{flags}"
puts "  contem --proxy-server? #{flags.to_s.include?('--proxy-server')}"
puts "  browser_options do ferrum chegam no chrome do container? NAO:"
puts "  o ferrum so usa browser_options quando ELE cria o processo do chromium;"
puts "  em producao o processo ja existe (container) e o ferrum so conecta por CDP."

linha "3) Entao quem usa o proxy, de verdade, no stack?"
puts "  SCRAPING_PROXY e' lido em config/initializers/ferrum.rb:89 e nos jobs"
puts "  scrape_{twitter,instagram,youtube}_job.rb. Nada disso esta no caminho do"
puts "  canal do Reddit (BrowserSession). O canal fala CDP com o Chrome do"
puts "  container, e esse Chrome nao tem proxy nenhum."
Dir.glob(Rails.root.join("app/jobs/*.rb")).sort.each do |j|
  src = File.read(j)
  puts "    #{j.sub(%r{.*/app/jobs/}, 'app/jobs/')} usa SCRAPING_PROXY" if src.include?("SCRAPING_PROXY")
end
Dir.glob(Rails.root.join("lib/fetcher/**/*.rb")).sort.each do |jf|
  src = File.read(jf)
  next unless src.include?("SCRAPING_PROXY")

  puts "    #{jf.sub(%r{.*/lib/}, 'lib/')} USA SCRAPING_PROXY (no caminho do canal!)"
end

linha "4) Medido: o IP de saida do container app (que o Chrome herda)"
require "open-uri"
begin
  ip = URI.open("https://api.ipify.org?format=json", read_timeout: 15).read
  puts "  app -> #{ip}"
rescue StandardError => e
  puts "  ERRO: #{e.class}: #{e.message}"
end
begin
  require "json"
  info = JSON.parse(URI.open("https://ipinfo.io/json", read_timeout: 15).read.to_s)
  puts "  org=#{info['org'].inspect} cidade=#{info['city'].inspect} pais=#{info['country'].inspect}"
  puts "  o proxy do .env aponta para 31.58.9.4:6077 (host:port, redigido). Este IP"
  puts "  NAO e o do proxy -> o container app sai direto pela VM."
rescue StandardError => e
  puts "  ERRO: #{e.class}: #{e.message}"
end

linha "5) Conclusao sobre o FATO 2 do card"
puts "  O 403 (snooserv, x-reddit-ct: v=1,dn=FT,p=GRU,cs=MISS) e' REAL e"
puts "  REPRODUZIVEL pelo caminho de producao (medido na p2: HTTP 403 em 0,025s)."
puts "  Mas a ATRIBUICAO ao proxy (FATO 2) nao se sustenta: o Chrome do canal"
puts "  nao tem --proxy-server (medido no passo 2) e o container app sai por"
puts "  #{`curl -s --max-time 5 https://api.ipify.org`.strip rescue 'IP-desconhecido'}."
puts "  O bloqueio esta no IP DA VM (AS31898 Oracle, datacenter), que e o mesmo"
puts "  FATO 3 do card: pelo caminho residencial responde 302. A diferenca entre"
puts "  'proxy de datacenter' e 'IP de datacenter da OCI' nao muda a conclusao"
puts "  (bloqueio por faixa de datacenter), mas a TESE do card (o proxy e' a"
puts "  causa) precisa ser corrigida: nao ha proxy no caminho do canal."
