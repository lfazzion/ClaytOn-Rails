# frozen_string_literal: true

# PROVA DO CONSERTO (card t_324ad4fd) — a regra 4 no caminho que NAVEGA.
#
# Roda dentro do container de PRODUÇÃO, com o Chrome de CONTROLE (novo) e o
# código novo. O Chrome de produção estava com a sessão envenenada de 24h
# (medido: zero `Network.responseReceived`, corpo vazio até em example.com), e
# nele nenhuma requisição completa — o que tornaria impossível medir o status do
# documento. Mesmo container, mesmo IP de saída, mesmo jar: só o Chrome muda.
#
# TRÊS CENÁRIOS, porque o primeiro ensaio MEDIU que eles são coisas diferentes:
#
#   A) SEM SESSÃO (anônimo): é o cenário do card t_f63b3613 e o que reproduz o
#      403. O p4 mediu 403 em 0,117s contra este mesmo alvo sem cookie.
#   B) COM a sessão do jar: o mesmo alvo responde 200 e a thread é lida
#      (medido: 14.900 chars). O 403 do card, portanto, NÃO é do IP da VM — é
#      do caminho anônimo. Este é o achado que corrige o FATO 1 do card.
#   C) O backoff: a 2a tentativa no alvo do cenário A, por OUTRO chamador.
#
#   docker cp scripts/proofs/reddit_403_fix_proof.rb docker-app-1:/tmp/fix.rb
#   docker exec -w /rails -e CHROME_P4_HOST=chrome-p4 docker-app-1 bin/rails runner /tmp/fix.rb

CHROME_NOVO = ENV.fetch("CHROME_P4_HOST", "chrome-p4")
ALVO = "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/"

def linha(t)
  puts "\n=== #{t} ==="
end

def relogio = Process.clock_gettime(Process::CLOCK_MONOTONIC)

Fetcher::BrowserSession
Fetcher::Channels::Reddit
Fetcher::ExtractService

# ── Aponta o BrowserSession para o Chrome de CONTROLE ───────────────────────
require "net/http"
require "socket"
require "uri"
require "json"
linha "0) Chrome de CONTROLE (novo) + medidor de navegacoes"
uri = URI("http://#{CHROME_NOVO}:9222/json/version")
resposta = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 5) do |h|
  req = Net::HTTP::Get.new(uri)
  req["Host"] = "localhost"
  h.request(req)
end
ws = URI(JSON.parse(resposta.body)["webSocketDebuggerUrl"])
ws.host = Addrinfo.getaddrinfo(CHROME_NOVO, nil, Socket::AF_INET, :STREAM).first.ip_address
ws.port = 9222
controle = Ferrum::Browser.new(ws_url: ws.to_s, timeout: 15, process_timeout: 60)
%i[@browser @browser_started_at @pages_since_start @browser_dirty @in_flight
   @browser_received @pending_discard].each { |v| Fetcher::PageFetcher.instance_variable_set(v, nil) }
Fetcher::PageFetcher.instance_variable_set(:@browser, controle)
Fetcher::PageFetcher.instance_variable_set(:@browser_started_at, Time.current)
Fetcher::PageFetcher.instance_variable_set(:@pages_since_start, 0)
Fetcher::PageFetcher.instance_variable_set(:@in_flight, 0)
Fetcher::PageFetcher.instance_variable_set(:@browser_received, 0)
puts "  ws=#{ws}"

# Instrumentacao sem monkey-patch de classe: contam-se as paginas criadas pelo
# semaforo do PageFetcher (`@pages_since_start` sobe uma vez por `track_in_flight`
# que segura browser). E o que a prova do backoff mede — nao a excecao levantada.
def contagem_real
  antes = Fetcher::PageFetcher.instance_variable_get(:@pages_since_start).to_i
  resultado = yield
  depois = Fetcher::PageFetcher.instance_variable_get(:@pages_since_start).to_i
  [resultado, depois - antes]
end

# ── CENÁRIO A: sem sessão (o que reproduz o 403 do card) ────────────────────
linha "A) SEM SESSAO — o cenario do 403 (t_f63b3613)"
Fetcher::BotDetection.clear!("old.reddit.com")
sessao_real = Fetcher::SessionCookies.method(:for)
Fetcher::SessionCookies.define_singleton_method(:for) { |_domain| [[], :jar] }

t0 = relogio
erro_a = nil
res_a, nav_a = contagem_real do
  begin
    Fetcher::BrowserSession.with_page(ALVO) { |_p| :YIELD_ALCANCADO }
  rescue StandardError => e
    erro_a = e
    nil
  end
end
dt_a = (relogio - t0).round(3)
puts "  duracao=#{dt_a}s  paginas criadas=#{nav_a}"
puts "  erro=#{erro_a.class}: #{erro_a.message}" if erro_a
puts "  resultado=#{res_a.inspect}" if res_a
veredito_a = case erro_a
              when nil then "SEM ERRO — o 403 nao foi classificado"
              else erro_a.class.name
              end
puts "  VEREDITO A: #{veredito_a}"

entrada_a = Fetcher::BotDetection.cooldown_for("old.reddit.com")
puts "  cooldown(old.reddit.com)=#{entrada_a.inspect}"
if entrada_a
  ttl = entrada_a[:expires_at] - Time.current
  puts "  reason=#{entrada_a[:reason].inspect} TTL=#{(ttl / 3600.0).round(2)}h " \
       "dentro de 6-12h=#{(ttl >= 6 * 3600 - 60) && (ttl <= 12 * 3600 + 60)}"
end

linha "C) 2a TENTATIVA no mesmo alvo, por OUTRO CHAMADOR (Reddit.search)"
t0 = relogio
erro_c = nil
res_c, nav_c = contagem_real do
  begin
    Fetcher::Channels::Reddit.search(query: "reddit 403 datacenter")
  rescue StandardError => e
    erro_c = e
    nil
  end
end
dt_c = (relogio - t0).round(3)
puts "  duracao=#{dt_c}s  paginas criadas=#{nav_c}  (0 = barreira ANTES do go_to)"
puts "  erro=#{erro_c.class}: #{erro_c.message}" if erro_c
veredito_c = if erro_c.is_a?(Fetcher::BrowserSession::TargetInCooldown)
               "TargetInCooldown com 0 navegacoes — a 2a tentativa RESPETA o backoff"
             else
               "NAO barrada (nav=#{nav_c}, erro=#{erro_c.class})"
             end
puts "  VEREDITO C: #{veredito_c}"

linha "C2) E pelo ExtractService (o /internal/extract que o MCP chama)?"
# O cache do ExtractService tem de ser limpo: uma execução anterior pode ter
# gravado a thread, e acertar o cache NÃO navega (o próprio código comenta isso
# em page_fetcher.rb: "acerto de cache nao toca o site"). Sem limpar, a prova
# mediria um acerto de cache e não o backoff.
Rails.cache.clear
Fetcher::BotDetection.clear!("old.reddit.com") # regra 4 de novo: so o cache de pagina
Fetcher::BotDetection.cooldown!("old.reddit.com", reason: "HTTP 403")
puts "  cooldown armado de novo (cache de pagina limpo): #{!Fetcher::BotDetection.cooldown_for('old.reddit.com').nil?}"
r = Fetcher::ExtractService.call("https://www.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/")
puts "  error=#{r[:error].inspect}"
puts "  content=#{r[:content].to_s.length} chars engine=#{r[:engine].inspect}"
veredito_c2 = if r[:error].to_s.include?("cooldown")
                "o MCP recebe o cooldown como erro limpo, sem os 35s de RenderTimeout"
              else
                "NAO: #{r[:error].inspect}"
              end
puts "  VEREDITO C2: #{veredito_c2}"

# ── CENÁRIO B: com a sessão do jar (o caminho saudável) ──────────────────────
linha "B) COM A SESSAO DO JAR — o mesmo alvo"
Fetcher::BotDetection.clear!("old.reddit.com")
Fetcher::SessionCookies.define_singleton_method(:for, &sessao_real)
cookies, origem = Fetcher::SessionCookies.for("old.reddit.com")
puts "  sessao restaurada: #{cookies.size} cookie(s), origem=#{origem}"

t0 = relogio
erro_b = nil
res_b, nav_b = contagem_real do
  begin
    Fetcher::Channels::Reddit.call(url: "https://www.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/")
  rescue StandardError => e
    erro_b = e
    nil
  end
end
dt_b = (relogio - t0).round(3)
puts "  duracao=#{dt_b}s paginas=#{nav_b}"
if erro_b
  puts "  erro=#{erro_b.class}: #{erro_b.message}"
else
  puts "  title=#{res_b[:title].inspect} comments=#{res_b.dig(:metadata, 'num_comments')} " \
       "chars=#{res_b[:content].to_s.length}"
end
puts "  cooldown(old.reddit.com) apos o caminho COM sessao = #{Fetcher::BotDetection.cooldown_for('old.reddit.com').inspect}"
veredito_b = if erro_b
               "REGRESSAO: #{erro_b.class}: #{erro_b.message}"
             elsif Fetcher::BotDetection.cooldown?("old.reddit.com")
               "REGRESSAO: o caminho saudavel armou cooldown"
             else
               "intacto — thread lida, sem cooldown"
             end
puts "  VEREDITO B: #{veredito_b}"

# ── CENÁRIO D: 403 em host que responde 403 sempre, com sessão ──────────────
linha "D) CONTROLE do bloqueio com sessao presente: o host que 403 sempre"
# Não depende de rede externa nem do Reddit: um 403 garantido mostra que a
# classificacao nao depende de a sessao estar presente.
begin
  html = "https://httpbin.org/status/403"
  erro_d = nil
  Fetcher::BotDetection.clear!("httpbin.org")
  Fetcher::SessionCookies.define_singleton_method(:for) { |_d| [[], :jar] }
  begin
    Fetcher::BrowserSession.with_page(html) { |_p| :YIELD }
  rescue StandardError => e
    erro_d = e
  end
  puts "  erro=#{erro_d.class}: #{erro_d.message}" if erro_d
  puts "  cooldown(httpbin.org)=#{Fetcher::BotDetection.cooldown_for('httpbin.org').inspect}"
rescue StandardError => e
  puts "  prova D nao executavel aqui: #{e.class}: #{e.message}"
end
Fetcher::SessionCookies.define_singleton_method(:for, &sessao_real)

begin
  controle.quit
rescue StandardError
  nil
end

linha "RESUMO"
puts "  A) 403 sem sessao: #{veredito_a} (cooldown #{entrada_a ? 'GRAVADO' : 'AUSENTE'})"
puts "  C) 2a tentativa:   #{veredito_c}"
puts "  C2) pelo MCP:     #{veredito_c2}"
puts "  B) com sessao:    #{veredito_b}"
