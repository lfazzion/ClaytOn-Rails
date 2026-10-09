# frozen_string_literal: true

# PROVA (parte 5) — QUAL ponto levanta o RenderTimeout que o log mostra como
# "tempo de render excedeu 35s", quando o goto_limit e de 15s.
#
#   docker cp scripts/proofs/reddit_403_gap_p5.rb docker-app-1:/tmp/p5.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/p5.rb

Fetcher::BrowserSession
Fetcher::Channels::Reddit

ALVO = "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/"

def linha(t)
  puts "\n=== #{t} ==="
end

linha "1) O RenderTimeout que o log real mostra: de onde vem?"
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  Fetcher::BrowserSession.with_page(ALVO) { |_p| raise "NAO DEVERIA CHEGAR" }
  puts "  NAO LEVANTOU (inesperado)"
rescue Fetcher::BrowserSession::RenderTimeout => e
  dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
  puts "  #{e.class}: #{e.message}  em #{dt}s"
  puts "  backtrace do ponto de origem (arquivo:linha):"
  e.backtrace.select { |l| l.include?("lib/fetcher/") || l.include?("timers") || l.include?("rails") }.first(8).each do |l|
    puts "    #{l.sub(%r{^/rails/}, '')}"
  end
  origem = e.backtrace.find { |l| l.include?("lib/fetcher/browser_session.rb") }
  puts "  VEREDITO: origem em #{origem.to_s.sub(%r{^/rails/}, '')}"
end

linha "2) A pagina fica viva depois do go_to? (o evaluate e onde trava)"
browser = Fetcher::PageFetcher.browser
context = browser.contexts.create(disposeOnDetach: true)
page = context.create_page
begin
  page.timeout = 15
  page.command("Network.setUserAgentOverride",
               userAgent: Fetcher::BrowserSession::REDDIT_USER_AGENT,
               acceptLanguage: "pt-BR,pt;q=0.9",
               platform: Fetcher::BrowserSession::REDDIT_PLATFORM)
  ta = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  page.go_to(ALVO)
  puts "  go_to: #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - ta)).round(3)}s (levantou? nao)"

  # evaluate com o MESMO teto que o yield usa: se travar, e o gargalo.
  te = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  resultado = begin
    Timeout.timeout(20) do
      v = page.evaluate("(function(){ return document.body ? document.body.innerText : ''; })()")
      "OK: #{v.to_s[0, 80].inspect}"
    end
  rescue Timeout::Error
    "TRAVOU: Timeout.timeout(20s) disparou"
  rescue StandardError => e
    "ERRO: #{e.class}: #{e.message}"
  end
  puts "  evaluate(innerText) apos go_to: #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - te)).round(3)}s -> #{resultado}"

  # O canal de verdade: EXTRACT_JS.
  te2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r2 = begin
    Timeout.timeout(20) do
      page.evaluate(Fetcher::Channels::Reddit::EXTRACT_JS).to_s[0, 80]
    end
  rescue Timeout::Error
    "TRAVOU (Timeout 20s)"
  rescue StandardError => e
    "ERRO: #{e.class}: #{e.message}"
  end
  puts "  evaluate(EXTRACT_JS) apos go_to: #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - te2)).round(3)}s -> #{r2}"
  puts "  15s (goto) + ate 20s (evaluate pendente) = 35s = OVERALL_TIMEOUT."
  puts "  E o rescue de browser_session.rb:169 pega Timeout::Error e levanta o"
  puts "  RenderTimeout de 35s — NAO o de 15s. Logo o goto_limit e o que trava"
  puts "  primeiro, e o evaluate consome o resto do orcamento."
ensure
  begin
    page&.close
    context&.dispose
  rescue StandardError
    nil
  end
end

linha "3) E o efeito colateral: PageFetcher.reset_browser! derruba o Chrome?"
puts "  browser_session.rb:173 -> PageFetcher.reset_browser! em CADA RenderTimeout."
puts "  O proximo pedido reconstrói o browser do zero. Isso explica o"
puts "  '[BrowserCookies] sessao do Chrome indisponivel' e o reuso de contexto."
