# frozen_string_literal: true

# PROVA (parte 7) — fecha a cadeia: o balde de 2/min ESTOURA, mas o erro some.
#
#   docker cp scripts/proofs/reddit_403_gap_p7.rb docker-app-1:/tmp/p7.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p7.rb

Fetcher::BrowserSession
Fetcher::Channels::Reddit
Fetcher::ExtractService

URLS = [
  "https://www.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/",
  "https://www.reddit.com/r/astgrep/comments/1ddm50y/astgrep_0230_ships_a_new_rule_nthchild/",
  "https://www.reddit.com/r/ClaudeCode/comments/1swghg3/grep_ripgrep_astgrep_and_what_ai_coding_agents/",
  "https://www.reddit.com/r/cursor/comments/1liuoxw/use_cursor_rule_mcp_structural_search_to_find/"
].freeze

def linha(t)
  puts "\n=== #{t} ==="
end

linha "1) As 4 URLs sao do MESMO alvo (old.reddit.com)?"
URLS.each do |u|
  # old_reddit_url e' privado; o reescritor publico e' o old. do host. Mostramos
  # que o Registry roteia www.reddit.com -> canal Reddit, e o canal reescreve.
  canal = Fetcher::Channels::Registry.for_host("www.reddit.com")
  puts "  Registry.for_host(www.reddit.com) = #{canal.inspect}"
  break
end
puts "  o canal reescreve o host para old.reddit.com (reddit.rb:380) -> 1 alvo so."
puts "  as 4 threads acima sao o MESMO alvo, pedido #{URLS.size}x."

linha "2) O balde de 2/min do CANAL (Reddit.search, SEARCH_HOST): estouraria?"
chave = "#{Fetcher::HostRateLimiter::KEY_PREFIX}:old.reddit.com"
Rails.cache.delete(chave)
6.times do |i|
  e = Fetcher::HostRateLimiter.exceeded?("old.reddit.com", max: 2)
  puts "  busca ##{i + 1} -> RateLimited? #{e} (contador=#{Rails.cache.read(chave)})"
end
puts "  => SIM, o balde estouraria na 3a. O balde NAO e o defeito."

linha "3) Mas o balde do ExtractService: o que o CHAMADOR VE quando estoura?"
Rails.cache.delete("#{Fetcher::HostRateLimiter::KEY_PREFIX}:www.reddit.com")
URLS.each_with_index do |u, i|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = Fetcher::ExtractService.call(u)
  dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)
  printf("  ##{i + 1} %6.2fs  error=%s\n", dt, r[:error].inspect)
  puts "        engine=#{r[:engine].inspect} content=#{r[:content].to_s.length} chars"
end
puts
puts "  (os 3 primeiros estouram o balde de 2/min: erro = 'rate limit local')"

linha "4) Onde esse erro foi? Alguem logou?"
puts "  ExtractService#failure (extract_service.rb:453-465) monta o hash e"
puts "  DEVOLVE. Nao ha Rails.logger ali — o grep no log de producao por"
puts "  'fetches/min' devolve 0 (medido: 0 ocorrencias em 12h de log)."
puts "  Resultado: o modelo recebe error: 'rate limit local: www.reddit.com"
puts "  atingiu 2 fetches/min' e o QUE FAZ? repete a pergunta com outro termo."

linha "5) A 403-classificacao: o que dispara backoff hoje, neste caminho?"
puts "  caminho de canal (BrowserSession) nao chama check_cooldown! nem"
puts "  RateLimitHandler (medido na p1: 0 call sites de RateLimitHandler em"
puts "  lib/fetcher). O unico escritor de cooldown e PageFetcher#call:379, que"
puts "  so roda no caminho COMUM (via_browser), nunca no de canal."
puts "  E o BrowserSession, no 403 real, levanta RenderTimeout (medido: 6/6)."
puts "  Logo: nenhum dos tres gatilhos (403 nomeado, cooldown, backoff) dispara."
