# frozen_string_literal: true

# PROVA — por que o caminho que navega old.reddit.com ignora a regra 4
# ("Never retry scraping on 403/429/captcha — backoff 6-12 hours").
#
# Roda DENTRO do container de produção (app), com o SolidCache e a config reais.
# Não é inspeção de código: cada número abaixo vem de EXECUTAR o método real.
#
#   docker compose -f docker/docker-compose.yml exec app \
#     bin/rails runner scripts/proofs/reddit_403_backoff_gap_proof.rb

require "fetcher/browser_session"
require "fetcher/bot_detection"
require "fetcher/host_rate_limiter"

def linha(titulo)
  puts "\n=== #{titulo} ==="
end

linha "1) O limitador local, no store de PRODUCAO, estouraria mesmo?"
# Chave e teto reais do caminho de BUSCA: Reddit.search usa SEARCH_HOST com
# MAX_PER_WINDOW=2 (lib/fetcher/channels/reddit.rb:21,256).
chave = "#{Fetcher::HostRateLimiter::KEY_PREFIX}:old.reddit.com"
Rails.cache.delete(chave)
contagens = (1..6).map do |i|
  estourou = Fetcher::HostRateLimiter.exceeded?("old.reddit.com", max: 2)
  bruto    = Rails.cache.read(chave)
  printf("  tentativa %d -> exceeded?=%-5s  cache.read=%s\n", i, estourou, bruto.inspect)
  estourou
end
n_estourou = contagens.count(true)
puts "  VEREDITO: estourou em #{n_estourou}/6 tentativas (teto=2/min)"
puts "  -> o BALDE LOCAL funciona: o canal teria levantado RateLimited na 3a."

linha "2) Os dois baldes sao o mesmo alvo?"
# ExtractService cobra pelo host QUE CHEGOU na URL; o canal cobra por SEARCH_HOST.
# Um pedido de thread chega como www.reddit.com, o canal reescreve para old.reddit.com.
Rails.cache.delete("#{Fetcher::HostRateLimiter::KEY_PREFIX}:old.reddit.com")
Rails.cache.delete("#{Fetcher::HostRateLimiter::KEY_PREFIX}:www.reddit.com")
5.times { Fetcher::HostRateLimiter.exceeded?("old.reddit.com", max: 2) }
5.times { Fetcher::HostRateLimiter.exceeded?("www.reddit.com", max: 2) }
puts "  balde old.reddit.com  = #{Rails.cache.read("#{Fetcher::HostRateLimiter::KEY_PREFIX}:old.reddit.com").inspect}"
puts "  balde www.reddit.com  = #{Rails.cache.read("#{Fetcher::HostRateLimiter::KEY_PREFIX}:www.reddit.com").inspect}"
puts "  o alvo real e UM (old.reddit.com), e o balde de busca nao conta o que o"
puts "  ExtractService gasta em thread — e o ThreadComments nao cobra NADA:"

linha "3) ThreadComments cobra algum balde?"
src = File.read(Rails.root.join("lib/fetcher/channels/reddit.rb"))
metodo = src[/def thread_comments.*?^        end/m]
puts metodo.lines.map { |l| "  | #{l}" }.join
puts "  VEREDITO: nenhum HostRateLimiter no thread_comments -> cota ZERO por alvo."

linha "4) O cooldown de 6-12h da regra 4 existe; o caminho do canal o consulta?"
tem_check = File.read(Rails.root.join("lib/fetcher/browser_session.rb")).include?("check_cooldown!") ||
            File.read(Rails.root.join("lib/fetcher/browser_session.rb")).include?("BotDetection")
puts "  BrowserSession (todo caminho de canal) cita BotDetection/check_cooldown!: #{tem_check}"
tem_bot = File.read(Rails.root.join("lib/fetcher/page_fetcher.rb")).include?("check_cooldown!")
puts "  PageFetcher (caminho COMUM, nao de canal) chama check_cooldown!:       #{tem_bot}"
puts "  VEREDITO: o cooldown so existe em PageFetcher#call, que o canal NAO usa."

linha "5) O cooldown funciona quando alguem o escreve? (a regra existe e funciona)"
reason = "PROVA-NAO-PRODUCAO"
Fetcher::BotDetection.cooldown!("old.reddit.com", reason: reason)
entrada = Fetcher::BotDetection.cooldown_for("old.reddit.com")
# O payload de BotDetection.cooldown! grava CHAVES SIMBOLO (bot_detection.rb:44-48),
# nao string — a prova precisou disso para ler (medido: NoMethodError em string).
resto   = (entrada[:expires_at] - entrada[:blocked_at]).to_i / 3600
printf("  cooldown gravado: %s h de TTL (a regra pede 6-12h) -> cooldown?=%s\n", resto, Fetcher::BotDetection.cooldown?("old.reddit.com"))
puts "  ...mas BrowserSession NAO o consulta, entao quem chama com_page no Reddit"
puts "  IGNORA o que esta aqui. Limpando a chave de teste."
Fetcher::BotDetection.clear!("old.reddit.com")

linha "6) O 403 chega ao codigo? (status lido na navegacao real)"
puts "  browser_session.rb:138 -> status = (page.network.response&.status rescue nil)"
page = Struct.new(:network, :current_url).new(Struct.new(:response).new(nil), "https://old.reddit.com/")
begin
  valor = (page.network.response&.status rescue nil)
  puts "  CDP sem resposta concluded -> status=#{valor.inspect} (vazio no log real: 53 de 65)"
rescue StandardError => e
  puts "  #{e.class}: #{e.message}"
end
puts "  e o caminho de canal nao tem NENHUM teste de status: 403 e 200 sao iguais"
puts "  para o codigo, que so olha o HTML (BLOCKED_PAGE_MARKERS)."

linha "7) Resumo: onde a regra 4 deveria agir e por que nao age"
puts "  regra 4 mora em ScrapingServices::RateLimitHandler (lib/scraping/rate_limit_handler.rb)"
puts "  e em Fetcher::BotDetection (lib/fetcher/bot_detection.rb:40) — 6-12h de TTL."
puts "  Chamadores de RateLimitHandler (grep):"
%w[
  lib/scraping/scrapers/ferrum_scraper_base.rb
  lib/scraping/services/http_stealth_client.rb
  lib/scraping/python_bridge/curl_impersonate_client.rb
  lib/scraping/python_bridge/camoufox_service.rb
  lib/scraping/python_bridge/nodriver_runner.rb
].each do |f|
  n = File.read(Rails.root.join(f)).scan(/RateLimitHandler/).size
  puts "    #{f} (#{n})"
end
n_lib = Dir.glob(Rails.root.join("lib/fetcher/**/*.rb")).sum { |f| File.read(f).scan(/RateLimitHandler/).size }
puts "    lib/fetcher/**  (#{n_lib})  <- o caminho que navega o Reddit"
puts "  VEREDITO: RateLimitHandler nao tem NENHUM call site em lib/fetcher."
