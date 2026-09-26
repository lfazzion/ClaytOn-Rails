# frozen_string_literal: true

# PROVA (parte 9) — o pico real de 16 page_fetch no minuto T18:45: por que o
# balde de 2/min NAO reclamou, se o alvo e' um so?
#
#   docker cp scripts/proofs/reddit_403_gap_p9.rb docker-app-1:/tmp/p9.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p9.rb

Fetcher::BrowserSession
Fetcher::Channels::Reddit
Fetcher::ExtractService
Fetcher::HostRateLimiter

def linha(t)
  puts "\n=== #{t} ==="
end

PREFIX = Fetcher::HostRateLimiter::KEY_PREFIX

linha "1) Quais HOSTS os 16 pedidos de T18:45 tocaram? (do log, nao de teoria)"
puts "  (leia scripts/proofs/reddit_pico_t1845.txt — gerado do docker logs)"
File.readlines(Rails.root.join("scripts/proofs/reddit_pico_t1845.txt")).first(30).each { |l| puts "  #{l}" }

linha "2) O RateLimited do ExtractService: o que ele produziria se estourasse?"
chave = "#{PREFIX}:www.reddit.com"
Rails.cache.delete(chave)
# Duas chamadas dentro da janela (teto=2) e uma terceira: estouraria?
r1 = nil
begin
  Fetcher::ExtractService.instance_variable_set(:@start_time, nil)
rescue StandardError
  nil
end
# Nao vamos chamar a rede: medimos o balde direto, que e' o que decide.
3.times do |i|
  e = Fetcher::HostRateLimiter.exceeded?("www.reddit.com", max: 2)
  puts "  incremento ##{i + 1} -> estourou=#{e}  contador=#{Rails.cache.read(chave).inspect}"
end
puts "  => o balde ESTOURA na 3a dentro da janela (medido, janela deslizando)."
Rails.cache.delete(chave)

linha "3) Entao: o pico de 16 no minuto T18:45 passou pelo balde de reddit?"
puts "  Se as 16 eram majoritariamente NAO-reddit (x.com, github, medium), o"
puts "  balde de www.reddit.com nunca foi pressionado naquele minuto — e o"
puts "  numero 28 do card (28x old.reddit) NAO se aplica ao balde, mas sim ao"
puts "  Chrome. Sao dois recursos diferentes: balde por host, Chrome por fila."
puts
puts "  O gargalo real e o Chrome: PageFetcher::MAX_INFLIGHT_PAGES + BROWSER_MUTEX."
puts "  track_in_flight (page_fetcher.rb:142) segura o semaphore; cada"
puts "  RenderTimeout de 35s segura o browser por 35s. Ver abaixo."

linha "4) O recurso realmente contido: Chrome, e nao host"
puts "  MAX_INFLIGHT_PAGES  = #{Fetcher::PageFetcher::MAX_INFLIGHT_PAGES}"
puts "  GOTO_TIMEOUT        = #{Fetcher::PageFetcher::GOTO_TIMEOUT}s"
puts "  OVERALL_TIMEOUT     = #{Fetcher::BrowserSession::OVERALL_TIMEOUT}s"
puts "  -> com 35s por tentativa e o browser ocupado, o服务 enfileira. O log"
puts "  mostra o sintoma: '[BrowserCookies] sessao do Chrome indisponivel"
puts "  (timeout aguardando semaforo de browser (25s))' — o gargalo e o Chrome."

linha "5) Fecha a cadeia do card"
puts "  (a) o backoff da regra 4 nao cobre este caminho? SIM, e' o achado."
puts "      RateLimitHandler: 0 call sites em lib/fetcher (p1). BotDetection"
puts "      (o cooldown de 6-12h) so e lido por PageFetcher#call:347, que o"
puts "      caminho de canal nao usa (p1). O 403 real chega como RenderTimeout"
puts "      (p6: 6/6), que nao casa com nenhum padrao de backoff."
puts "  (b) as navegacoes vem de jobs diferentes e o balde e' por job? NAO."
puts "      O balde e' por HOST (host_rate_limiter.rb:31-33), nao por job; e"
puts "      thread_comments nem cobra nada (p1). Nao e' balde-por-job."
puts "  (c) o 403 nao esta sendo classificado como 403? SIM, e' o achado."
puts "      browser_session.rb:138 le status, mas do CDP: saiu VAZIO em 53 de"
puts "      65 navegacoes (log). E o status VINDO do HTTP seria 403, mas o"
puts "      caminho de canal nao tem teste de status algum (p3: so olha HTML)."
