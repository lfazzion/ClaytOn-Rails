# frozen_string_literal: true

# PROVA (parte 2) — o 403 do FATO 2 do card existe MESMO no caminho que o bot
# usa? Roda dentro do container de PRODUCAO (app), que e quem fala com o Chrome.
#
#   docker cp scripts/proofs/reddit_403_gap_p2.rb docker-app-1:/tmp/p2.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p2.rb

require "net/http"
require "uri"

def linha(t)
  puts "\n=== #{t} ==="
end

linha "A) De onde o Chrome de PRODUCAO sai? (o proxy esta no caminho dele?)"
cmd = File.read(Rails.root.join("docker/docker-compose.yml"))
comando_chrome = cmd[/^\s+command: \[.*chrome/m] || cmd[/(?<=command: )\[.*\]\n\s+volumes:\n\s+- chrome-profile/]
puts "  compose, comando do container chrome:"
comando_chrome.to_s.lines.grep(/command|proxy/).each { |l| puts "    #{l.strip}" }
puts "  --proxy-server aparece no comando do chrome? #{cmd[/(?<=command: )\[.*\]/].to_s.include?("--proxy-server")}"
puts "  ferrum.rb:89 aplica --proxy-server so no browser que o FERRUM CRIA"
puts "  (chromium local). A producao fala com o Chrome do CONTAINER por CDP:"
ferrum = File.read(Rails.root.join("config/initializers/ferrum.rb"))
ws_url = ferrum[/(def discover_stealth_ws_url.*?\n  end)/m].to_s
puts "    a via de producao usa ws_url/stealth_opts? #{ws_url[0, 300].to_s.empty? ? 'n/a' : 'sim (CDP)'}"
puts "  -> o Chrome de producao NAO tem --proxy-server: ele sai pelo IP da VM."

linha "B) O IP de saida REAL do container app (o que o Chrome herda)"
require "open-uri"
saida = begin
  URI.open("https://api.ipify.org?format=json", read_timeout: 15).read
rescue StandardError => e
  "ERRO: #{e.class}: #{e.message}"
end
puts "  app -> #{saida}"
ipres = begin
  URI.open("https://ipinfo.io/json", read_timeout: 15).read.to_s
rescue StandardError => e
  "ERRO: #{e.class}: #{e.message}"
end
require "json"
j = (JSON.parse(ipres) rescue {})
puts "  org=#{j['org'].inspect} cidade=#{j['city'].inspect} pais=#{j['country'].inspect} hostname=#{j['hostname'].inspect}"

linha "C) old.reddit.com por esse mesmo caminho: qual o status REAL?"
url = "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/"
2.times do |i|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    http = Net::HTTP.new("old.reddit.com", 443)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15
    req = Net::HTTP::Get.new("/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/")
    req["User-Agent"] = Fetcher::BrowserSession::REDDIT_USER_AGENT if defined?(Fetcher::BrowserSession)
    req["Accept-Language"] = "pt-BR,pt;q=0.9"
    res = http.request(req)
    dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
    puts "  tentativa #{i + 1}: HTTP #{res.code} em #{dt}s  server=#{res['server'].inspect} " \
         "x-reddit-ct=#{res['x-reddit-ct'].inspect} len=#{res.body.to_s.length}"
    if res.code.to_i >= 400
      puts "    corpo(200 chars)=#{res.body.to_s[0, 200].gsub(/\s+/, ' ')}"
    end
  rescue StandardError => e
    dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
    puts "  tentativa #{i + 1}: #{e.class}: #{e.message} (#{dt}s)"
  end
end

linha "D) O mesmo alvo, agora pelo PROXY que o .env aponta (FATO 2 do card)"
proxy = ENV["SCRAPING_PROXY"].to_s
puts "  SCRAPING_PROXY presente? #{!proxy.empty?} (valor nao impresso)"
if proxy.empty?
  puts "  SEM PROXY no env deste container -> nada a comparar"
else
  require "uri"
  puri = URI.parse(proxy)
  puts "  esquema=#{puri.scheme} host=#{puri.host} porta=#{puri.port}"
  begin
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    proxy_class = Net::HTTP::Proxy(puri.host, puri.port)
    http = proxy_class.new("old.reddit.com", 443)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15
    req = Net::HTTP::Get.new("/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/")
    req["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    res = http.request(req)
    dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
    puts "  VIA PROXY: HTTP #{res.code} em #{dt}s server=#{res['server'].inspect} x-reddit-ct=#{res['x-reddit-ct'].inspect}"
  rescue StandardError => e
    puts "  VIA PROXY: #{e.class}: #{e.message}"
  end
end
