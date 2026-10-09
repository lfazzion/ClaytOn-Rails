# frozen_string_literal: true

# PROVA (parte 8, CORRIGIDA) — a janela do balde desliza? e ele estoura no ritmo
# REAL de producao?
#
# A p8 anterior rotulava "t=35s" sem DORMIR: as 5 chamadas de `exceeded?` rodaram
# em milissegundos e foram lidas como espacadas. O "t=35s" era etiqueta, nao
# medicao. Aqui o relogio e de parede e o ritmo simula o custo real de 35s.
#
#   docker cp scripts/proofs/reddit_403_gap_p8.rb docker-app-1:/tmp/p8.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p8.rb

Fetcher::BrowserSession
Fetcher::Channels::Reddit
Fetcher::ExtractService
Fetcher::HostRateLimiter

def linha(t)
  puts "\n=== #{t} ==="
end

PREFIX = Fetcher::HostRateLimiter::KEY_PREFIX
JANELA = Fetcher::HostRateLimiter::WINDOW_SECONDS
TETO   = Fetcher::Channels::Reddit::MAX_PER_WINDOW
T0     = Time.current

def marca
  (Time.current - T0).round(2)
end

linha "1) A janela DESLIZA com a atividade? (increment renova o TTL?)"
chave = "#{PREFIX}:prova-janela"
Rails.cache.delete(chave)
Rails.cache.increment(chave, 1, expires_in: 12) # janela curta de proposito
[0, 4, 8, 12, 16, 20, 24].each do |alvo|
  sleep(alvo - marca) if alvo > marca
  Rails.cache.increment(chave, 1, expires_in: 12)
  v = Rails.cache.read(chave)
  puts "  t=#{'%5.1f' % marca}s  read=#{v.inspect}  #{v.nil? ? 'EXPIROU' : 'viva'}"
end
v = Rails.cache.read(chave)
puts "  >>> #{v.nil? ? 'TTL FIXO: a janela NAO desliza com a atividade' : 'TTL RENOVADO: desliza'}"
puts "  (janela=12s, incremento a cada 4s durante 24s — atividade continua)"
Rails.cache.delete(chave)

linha "2) O balde no ritmo REAL: 35s por navegacao, teto #{TETO}/min, janela #{JANELA}s"
chave2 = "#{PREFIX}:www.reddit.com"
Rails.cache.delete(chave2)
puts "  custo por chamada = #{Fetcher::BrowserSession::OVERALL_TIMEOUT}s (browser_session.rb:37)"
4.times do |i|
  alvo = i * 35
  sleep(alvo - marca) if alvo > marca
  estourou = Fetcher::HostRateLimiter.exceeded?("www.reddit.com", max: TETO)
  puts "  ##{i + 1} t=#{'%6.1f' % marca}s  excedeu=#{estourou}  contador=#{Rails.cache.read(chave2).inspect}"
end
Rails.cache.delete(chave2)

linha "3) O balde sob RAJADA (concorrencia, como o MCP atende)"
Rails.cache.delete(chave2)
barreira = Queue.new
n = 12
threads = n.times.map do
  Thread.new do
    barreira.pop
    Fetcher::HostRateLimiter.exceeded?("www.reddit.com", max: TETO)
  end
end
n.times { barreira << :vai }
estouros = threads.map(&:value).count(true)
printf("  %d threads simultaneas, teto %d -> %d estouraram, contador=%s\n",
       n, TETO, estouros, Rails.cache.read(chave2).inspect)
Rails.cache.delete(chave2)

linha "4) O ritmo REAL de producao (medido no log do app, 6h)"
puts "  65 navegacoes old.reddit.com em ~55 min -> media 1,2/min"
puts "  pior minuto medido: 4 navegacoes (T18:47, T19:17)"
puts "  grep por 'fetches/min' no log de 12h: 0 ocorrencias (o balde nunca reclamou)"
puts "  Nao houve rajada de 3+ no mesmo minuto, logo o balde nunca foi testado."

linha "5) Fecha: o balde explica as 28 navegacoes?"
puts "  NAO. Media de 1,2/min fica DENTRO do teto de 2/min mesmo sequencialmente."
puts "  O balde e' por alvo e por janela, e nao e' o gargalo."
puts "  O gargalo e' outro, medido nas p1/p6:"
puts "    - 0 call sites de RateLimitHandler em lib/fetcher (p1)"
puts "    - 6/6 chamadas reais do canal -> RenderTimeout, 0 PageFailed (p6)"
puts "    - cooldown(old.reddit.com) = nil depois das 6 chamadas (p6)"
puts "  Um 403 que chega ao codigo como TIMEOUT nao aciona backoff nenhum."
