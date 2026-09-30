# frozen_string_literal: true

# PROVA (parte 6) — O QUE O CANAL REAL VE, repetido. Sem chutar: cada tentativa
# e uma chamada de producao (mesma classe, mesmo Chrome, mesmo teto) e o
# desfecho e o que o codigo de fato Classificou.
#
#   docker cp scripts/proofs/reddit_403_gap_p6.rb docker-app-1:/tmp/p6.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p6.rb

Fetcher::BrowserSession
Fetcher::Channels::Reddit

BUSCA  = "ast-grep"
THREAD = "https://www.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/"

def linha(t)
  puts "\n=== #{t} ==="
end

def classifica(e)
  case e
  when nil then "SEM ERRO (deu certo)"
  when Fetcher::Channels::Reddit::RateLimited then "RateLimited (balde local)"
  when Fetcher::Channels::Reddit::PageFailed  then "PageFailed: #{e.message}"
  when Fetcher::Channels::Reddit::SearchFailed then "SearchFailed: #{e.message}"
  when Fetcher::BrowserSession::RenderTimeout  then "RenderTimeout(35s): #{e.message}"
  else "#{e.class}: #{e.message[0, 90]}"
  end
end

def registra(agora, tipo, url, err, dt, extra = nil)
  agora << { tipo: tipo, url: url, desfecho: classifica(err), dt: dt, extra: extra }
end

N_BUSCA  = 3
N_THREAD = 3

linha "1) Reddit.search — o caminho que o PlatformSearchTool chama"
buscas = []
N_BUSCA.times do |i|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  err = nil
  res = nil
  begin
    res = Fetcher::Channels::Reddit.search(query: BUSCA, limit: 5)
  rescue StandardError => e
    err = e
  end
  dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)
  registra(buscas, "search", BUSCA, err, dt, res.is_a?(Array) ? "#{res.size} itens" : res.class.to_s)
  puts "  ##{i + 1} #{dt}s -> #{classifica(err)}  #{res.is_a?(Array) ? "(#{res.size} itens)" : ""}"
end

linha "2) Reddit.call(THREAD) — o caminho que o page_fetch/ExtractService chama"
threads = []
N_THREAD.times do |i|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  err = nil
  res = nil
  begin
    res = Fetcher::Channels::Reddit.call(url: THREAD)
  rescue StandardError => e
    err = e
  end
  dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)
  registra(threads, "thread", THREAD, err, dt, res.is_a?(Hash) ? "title=#{res[:title].to_s[0, 40].inspect}" : res.inspect)
  puts "  ##{i + 1} #{dt}s -> #{classifica(err)}"
end

linha "3) O cooldown de 6-12h foi gravado em ALGUMA dessas tentativas?"
%w[old.reddit.com www.reddit.com].each do |h|
  e = Fetcher::BotDetection.cooldown_for(h)
  puts "  cooldown(#{h}) = #{e ? "PRESENTE (regra 4 disparou)" : 'nil (regra 4 NAO disparou)'}"
end

linha "4) Tabuao: o codigo viu '403' alguma vez?"
todas = buscas + threads
puts "  #{'tipo'.ljust(8)} #{'duracao'.rjust(8)}  desfecho"
todas.each do |t|
  puts "  #{t[:tipo].ljust(8)} #{("#{t[:dt]}s").rjust(8)}  #{t[:desfecho]}"
end
tem403 = todas.count { |t| t[:desfecho].match?(/403|blocked|bloqueou/i) }
puts "\n  desfechos que NOMEIAM bloqueio/403: #{tem403}/#{todas.length}"
puts "  desfechos genericos (timeout):      #{todas.count { |t| t[:desfecho].include?('RenderTimeout') }}/#{todas.length}"
puts
puts "  REGRA GERAL QUE ESTA PROVANDO:"
puts "  Um 403 que chega ao codigo como TIMEOUT nao aciona backoff: o backoff e"
puts "  por SINTOMA nomeado (403/429/captcha), e o caminho de canal so produz"
puts "  'tempo de render excedeu 35s' — que nao esta em nenhum padrao de backoff."
