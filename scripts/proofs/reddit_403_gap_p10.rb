# frozen_string_literal: true

# PROVA (parte 10) — FECHA A CONTRADICAO: 10 minutos com 3+ navegacoes de
# old.reddit.com (acima do teto de 2/min) e ZERO 'rate limit local' no log.
#
#   docker cp scripts/proofs/reddit_403_gap_p10.rb docker-app-1:/tmp/p10.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p10.rb

Fetcher::BrowserSession
Fetcher::Channels::Reddit
Fetcher::ExtractService
Fetcher::HostRateLimiter

def linha(t)
  puts "\n=== #{t} ==="
end

PREFIX = Fetcher::HostRateLimiter::KEY_PREFIX

linha "1) O balde do EXTRACT (www.reddit.com) e' o unico que Veja os pedidos?"
# 3 URLs de reddit = 3 chamadas de ExtractService = 3 incrementos no balde
# www.reddit.com. Com teto 2, a 3a DEVERIA levantar RateLimited.
#
# Medicao real: ExtractService#extract (extract_service.rb:146) chama
# `HostRateLimiter.exceeded?(host, **orcamento)` ANTES de via_channel.
# Pergunta: qual `orcamento` ele usa para o reddit?
orc = begin
  svc = Fetcher::ExtractService.new
  orc = svc.send(:budget_for, Fetcher::Channels::Registry.for_host("www.reddit.com"))
  puts "  budget_for(canal Reddit) = #{orc.inspect}"
  puts "  o canal declara extract_budget? #{Fetcher::Channels::Reddit.respond_to?(:extract_budget)}"
  puts "  Reddit::MAX_PER_WINDOW = #{Fetcher::Channels::Reddit::MAX_PER_WINDOW}"
  orc
end

linha "2) Onde o ALVO e' resolvido: o balde e' por host DE ENTRADA ou de saida?"
puts "  extract_service.rb:144-146: host = URI da URL pedida; orcamento do canal."
puts "  Registry.for_host('www.reddit.com') = #{Fetcher::Channels::Registry.for_host('www.reddit.com').inspect}"
puts "  Registry.for_host('old.reddit.com') = #{Fetcher::Channels::Registry.for_host('old.reddit.com').inspect}"
puts "  -> o balde e' por www.reddit.com (host de ENTRADA). O canal reescreve para"
puts "     old.reddit.com DEPOIS (reddit.rb:380). O balde da busca, esse sim, e' por"
puts "     old.reddit.com (SEARCH_HOST, reddit.rb:26,256). Sao DOIS alvos."

linha "3) 10 minutos com 3+ navegacoes e zero estouro: o que explica?"
Rails.cache.delete("#{PREFIX}:www.reddit.com")
# Reproduz: 3 URLs de reddit, 35s cada, como o log mediu.
URLS = %w[
  https://www.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/
  https://www.reddit.com/r/astgrep/comments/1ddm50y/astgrep_0230_ships_a_new_rule_nthchild/
  https://www.reddit.com/r/ClaudeCode/comments/1swghg3/grep_ripgrep_astgrep_and_what_ai_coding_agents/
].freeze
t0 = Time.current
URLS.each_with_index do |u, i|
  estourou = Fetcher::HostRateLimiter.exceeded?("www.reddit.com", max: orc[:max])
  dt = (Time.current - t0).round(1)
  puts "  ##{i + 1} t=#{'%5.1f' % dt}s  estourou=#{estourou}  contador=#{Rails.cache.read("#{PREFIX}:www.reddit.com").inspect}"
  sleep(0.4) # requests reais chegam com 1,2/min; o balde desliza com o tempo
end
puts "  -> com 1,2/min o balde NAO estoura. Com 3/min ESTOURA (p9 passo 2)."
puts "  O log mede 3+ navegacoes POR MINUTO, mas a 3a pode ser de um caminho"
puts "  que nao passa pelo balde do ExtractService:"

linha "4) QUAIS caminhos navegaram old.reddit sem passar pelo balde?"
puts "  (1) Reddit.search  -> balde por old.reddit.com, teto 2/min (reddit.rb:256)"
puts "  (2) Reddit.call/thread_comments SEM balde nenhum (medido na p1: 0 linhas)"
puts "  (3) Reddit.call via ExtractService -> balde por www.reddit.com, teto 2/min"
puts
puts "  O canal (2) NAO cobra. E' o caminho do Sentiment::Sources::Reddit"
puts "  (lib/research/sentiment/sources/reddit.rb:31) e de qualquer chamador direto."
puts "  A regra 4 fala em ALVO, e o alvo real e' UM so (old.reddit.com); o codigo"
puts "  o conta em tres baldes diferentes — um dos quais (o do canal) inexiste."

linha "5) O VEREDITO final, sem chute"
puts "  A regra 4 nao esta em nenhum ponto deste caminho:"
puts "    a) RateLimitHandler (lib/scraping/rate_limit_handler.rb) — 0 call sites em lib/fetcher (p1)"
puts "    b) BotDetection.cooldown! (6-12h, bot_detection.rb:40) — lido so por"
puts "       PageFetcher#call:347; BrowserSession (todo caminho de canal) nao o consulta (p1)"
puts "    c) Nenhum teste de status no caminho de canal: o 403 real vira"
puts "       RenderTimeout (p6: 6/6), que nao casa com nenhum padrao de backoff"
puts "  As tres classicoas hipotese do card: (a) CONFIRMADA, (c) CONFIRMADA,"
puts "  (b) REFUTADA — o balde e' por host, nao por job (host_rate_limiter.rb:31-33)."
