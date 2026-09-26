# frozen_string_literal: true

# PROVA (parte 4) — QUAL RenderTimeout levanta, e o corpo da pagina de bloqueio
# chega a ser lido pelo caminho do canal?
#
#   docker cp scripts/proofs/reddit_403_gap_p4.rb docker-app-1:/tmp/p4.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p4.rb

Fetcher::BrowserSession
Fetcher::Channels::Reddit

ALVO = "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/"

def linha(t)
  puts "\n=== #{t} ==="
end

linha "1) go_to com o MESMO goto_limit do canal: levanta ou completa?"
browser = Fetcher::PageFetcher.browser
context = browser.contexts.create(disposeOnDetach: true)
page = context.create_page
begin
  page.timeout = 15 # browser_session.rb:117-118 (goto_limit para host reddit)
  page.command("Network.setUserAgentOverride",
               userAgent: Fetcher::BrowserSession::REDDIT_USER_AGENT,
               acceptLanguage: "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
               platform: Fetcher::BrowserSession::REDDIT_PLATFORM)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  levantou = nil
  begin
    page.go_to(ALVO)
    puts "  go_to COMPLETOU em #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s"
  rescue StandardError => e
    levantou = e
    puts "  go_to LEVANTOU #{e.class} em #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s"
  end
  puts "  -> o rescue de browser_session.rb:132 so cobre " \
       "#{levantou.is_a?(Ferrum::TimeoutError) ? 'Ferrum::TimeoutError' : 'Ferrum::PendingConnectionsError'}"
  puts "     (capturado: #{levantou&.class})"

  # Exatamente o body_check do browser_session.rb:133
  body = (page.evaluate("document.body ? document.body.innerText : ''") rescue "").to_s.strip
  puts "\n  body_check (browser_session.rb:133) -> #{body.length} chars: #{body[0, 200].inspect}"
  puts "  body_check vazio? #{body.empty?}  => raise RenderTimeout se VAZIO (linha 134)"

  st = (page.network.response&.status rescue nil)
  puts "\n  page.network.response&.status = #{st.inspect}"
  puts "  page.title = #{(page.title rescue nil).inspect}"
  puts "  page.current_url = #{(page.current_url rescue nil).inspect}"

  linha "2) Se o corpo NAO fosse vazio, o canal veria a pagina de bloqueio?"
  if body.empty?
    puts "  body VAZIO: o RenderTimeout levanta em browser_session.rb:134 e o"
    puts "  `yield page` (linha 156) NUNCA roda -> from_page/EXTRACT_JS nao leem"
    puts "  nada -> os marcadores do canal ficam INALCANCAVEIS."
  else
    puts "  body presente: o yield roda e o canal teria chance de ler os marcadores."
  end

  linha "3) O HTML bruto que o Chrome carregou tem a pagina de bloqueio?"
  html = (page.evaluate("document.documentElement.outerHTML") rescue "").to_s
  puts "  outerHTML = #{html.length} chars"
  marcadores = Fetcher::Channels::Reddit::BLOCKED_PAGE_MARKERS
  marcadores.each do |m|
    puts "    #{m.source.inspect} casa? #{!!html.match?(m)}"
  end
  puts "  title no HTML: #{html[/<title>(.*?)<\/title>/i, 1].inspect}"
  puts "  BotDetection.blocked?(status=#{st.inspect}) = " \
       "#{Fetcher::BotDetection.blocked?(Struct.new(:status, :title, :body, :current_url).new(st, 'Blocked', html, ALVO))}"
ensure
  begin
    page&.close
    context&.dispose
  rescue StandardError
    nil
  end
end

linha "4) Quantas vezes o Chrome SERIA acionado se o RenderTimeout nao existisse?"
puts "  O corpo do 403 tem os marcadores do canal (medido na p3), logo o"
puts "  caminho so precisa ALCANCA-los. Hoje ele levanta antes (linha 134)."
puts "  Cada tentativa custa o goto_limit inteiro de 15s: 53 de 65 navegacoes"
puts "  medidas gastaram 15,0s exatos e nao produziram decisao nenhuma."
