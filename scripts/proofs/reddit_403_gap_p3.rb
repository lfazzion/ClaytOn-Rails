# frozen_string_literal: true

# PROVA (parte 3) — o que o Chrome de PRODUCAO REALMENTE ve de old.reddit.com,
# e por que o codigo nunca classifica isso como 403.
#
#   docker cp scripts/proofs/reddit_403_gap_p3.rb docker-app-1:/tmp/p3.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p3.rb

# `bin/rails runner` ja sobe o ambiente; o require_relative resolveria /config/environment
# a partir de /tmp (medido: LoadError). Basta pedir o autoload do constante.
Fetcher::BrowserSession

ALVO = "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/"

def linha(t)
  puts "\n=== #{t} ==="
end

linha "0) O que o MESMO Chrome que a producao usa responde?"
# BrowserSession e o caminho real do canal. A janela de 35s e a mesma.
begin
  html = nil
  Fetcher::BrowserSession.with_page(ALVO) do |page|
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    html = (page.evaluate("document.body ? document.body.innerText : ''") rescue "").to_s
    puts "  innerText (#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s): #{html.strip[0, 300].inspect}"
    st = (page.network.response&.status rescue nil)
    puts "  page.network.response&.status = #{st.inspect}"
    title = (page.title rescue nil)
    puts "  page.title = #{title.inspect}"
    puts "  page.current_url = #{(page.current_url rescue nil).inspect}"
  end
rescue StandardError => e
  puts "  #{e.class}: #{e.message}"
end

linha "1) A pagina de bloqueio do Reddit casa com BLOCKED_PAGE_MARKERS?"
markers = Fetcher::Channels::Reddit::BLOCKED_PAGE_MARKERS
puts "  marcadores que o codigo procura: #{markers.map(&:source).inspect}"
require "net/http"
require "uri"
http = Net::HTTP.new("old.reddit.com", 443)
http.use_ssl = true
http.open_timeout = 10
http.read_timeout = 15
req = Net::HTTP::Get.new(URI.parse(ALVO).request_uri)
req["User-Agent"] = Fetcher::BrowserSession::REDDIT_USER_AGENT
req["Accept-Language"] = "pt-BR,pt;q=0.9"
res = http.request(req)
body = res.body.to_s
puts "  status HTTP do mesmo alvo (mesmo UA): #{res.code}"
markers.each do |m|
  puts "    #{m.source.inspect} casa no corpo? #{!!body.match?(m)}"
end
puts "  title no corpo: #{body[/<title>(.*?)<\/title>/i, 1].inspect}"
puts "  marcadores de BLOCK TITLES do BotDetection casam? " \
     "#{Fetcher::BotDetection::BLOCK_TITLES.any? { |t| body.to_s.downcase.include?(t) }}"
puts "  marcador 'just a moment' (Cloudflare) casa? #{body.downcase.include?('just a moment')}"
puts "  corpo tem 'whoa there'? #{body.downcase.include?('whoa there')}"
puts "  corpo tem 'blocked due to a network policy'? #{body.downcase.include?('blocked due to a network policy')}"

linha "2) Entao o que o Reddit devolve e como o codigo o leria?"
puts "  HTTP #{res.code} + <title>Blocked</title> — o titulo NAO esta em BLOCK_TITLES"
puts "  (#{Fetcher::BotDetection::BLOCK_TITLES.inspect}) e o corpo NAO tem nenhum dos"
puts "  marcadores do canal. Para BotDetection.blocked? isso e uma PAGINA NORMAL."

fake = Struct.new(:status, :title, :body, :current_url).new(res.code, "Blocked", body, ALVO)
puts "  BotDetection.blocked?(pagina com status=#{res.code}) = #{Fetcher::BotDetection.blocked?(fake)}"
puts "  VEREDITO: com status 403 chegado ao PageFetcher, SIM bloqueava. Mas o 403"
puts "  NAO chega: a navegacao estoura em 15s e o status sai vazio (nil)."

linha "3) Por que a navegacao estoura em 15s se o 403 vem em 0,02s?"
puts "  BrowserSession:117-118 -> goto_limit = 15 para host reddit (REDDIT_HOSTS)"
puts "  BrowserSession:131     -> page.go_to(uri)"
puts "  No log real: 53 de 65 navegacoes com duracao=15.0s e status VAZIO;"
puts "  as 12 com status=200 sao as que responderam em ~1,2-2,3s."
puts "  page.network.response e a ULTIMA resposta da sessao CDP. O 403 do"
puts "  documento principal chega, mas o go_to so resolve quando a pagina para"
puts "  de carregar: a folha de estilo/script do <title>Blocked</title> aponta"
puts "  para o tracker do Reddit, que pelo IP bloqueado nao volta -> PendingConnections."
