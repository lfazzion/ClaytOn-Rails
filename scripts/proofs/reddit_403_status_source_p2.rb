# frozen_string_literal: true

# PROVA (fix t_324ad4fd, parte 2) — POR QUE o evento do documento não chega?
#
# A prova anterior mediu ZERO `Network.responseReceived` no old.reddit.com, e
# `page.network.response&.status` = nil (a fonte que o código já usa). Duas
# explicações possiveis, e elas levam a consertos opostos:
#
#   (A) `Network.enable` nao esta ligado na pagina -> o CDP nao emite nada, e
#       nenhum conserto no Ruby sobre o 403 tem como ler o status;
#   (B) o evento chega normalmente e o que não volta é o status do documento
#       (o 403 é de outra natureza).
#
# A distinguishing test é um host que responde RÁPIDO: se o evento chega em
# example.com e não no old.reddit.com, é (B); se não chega em nenhum, é (A).
# Também mede o que muda com `Network.enable` explícito.
#
#   docker cp scripts/proofs/reddit_403_status_source_p2.rb docker-app-1:/tmp/st2.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/st2.rb

Fetcher::BrowserSession

ALVO_LENTO = "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/"
ALVO_RAPIDO = "https://example.com/"

def navega(alvo, timeout:, enable: false, collect: false)
  browser = Fetcher::PageFetcher.browser
  context = browser.contexts.create(disposeOnDetach: true)
  page = context.create_page
  eventos = []
  begin
    page.timeout = timeout
    page.command("Network.setUserAgentOverride",
                 userAgent: Fetcher::BrowserSession::REDDIT_USER_AGENT,
                 acceptLanguage: "pt-BR,pt;q=0.9",
                 platform: Fetcher::BrowserSession::REDDIT_PLATFORM) if alvo.include?("reddit")
    # HABILITACAO EXPLICITA — a unica diferenca entre os dois braços.
    page.command("Network.enable", {}) if enable

    id = nil
    if collect
      id = page.on("Network.responseReceived") do |params|
        eventos << { type: params["type"], status: params.dig("response", "status"),
                     url: params.dig("response", "url"), ip: params.dig("response", "remoteIPAddress") }
      end
    end

    erro = nil
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      page.go_to(alvo)
    rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError => e
      erro = e.class.name
    end
    dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
    page.off("Network.responseReceived", id) if id

    body = (page.evaluate("document.body ? document.body.innerText : ''") rescue "").to_s
    net = (page.network.response&.status rescue nil)
    {
      alvo: alvo, enable: enable, duracao: dt, erro: erro,
      eventos: eventos.size, docs: eventos.select { |e| e[:type] == "Document" },
      network_status: net, body: body.strip[0, 90],
      traffic: (page.network.traffic&.size rescue nil)
    }
  ensure
    begin
      page&.close
      context&.dispose
    rescue StandardError
      nil
    end
  end
end

def mostra(tag, r)
  puts "\n--- #{tag} ---"
  puts "  alvo=#{r[:alvo]} enable=#{r[:enable]} duracao=#{r[:duracao]}s erro=#{r[:erro].inspect}"
  puts "  eventos responseReceived=#{r[:eventos]}  documentos=#{r[:docs].size}"
  r[:docs].first(3).each { |d| puts "    type=#{d[:type]} status=#{d[:status].inspect} ip=#{d[:ip].inspect}" }
  puts "  page.network.response&.status=#{r[:network_status].inspect}  traffic=#{r[:traffic].inspect}"
  puts "  innerText=#{r[:body].inspect}"
end

mostra("CONTROLE: host rapido, SEM Network.enable explicito",
       navega(ALVO_RAPIDO, timeout: 20, enable: false, collect: true))
mostra("CONTROLE: host rapido, COM Network.enable explicito",
       navega(ALVO_RAPIDO, timeout: 20, enable: true, collect: true))
mostra("ALVO DO CARD: old.reddit, COM Network.enable explicito",
       navega(ALVO_LENTO, timeout: 15, enable: true, collect: true))
mostra("ALVO DO CARD: old.reddit, sem coletar evento (so network.response)",
       navega(ALVO_LENTO, timeout: 15, enable: false, collect: false))

puts "\n=== VEREDITO ==="
puts "  (A) se o host rapido NAO emite evento em nenhum dos bracos -> Network.enable"
puts "      ausente: nenhum conserto em Ruby sobre o status pode funcionar."
puts "  (B) se o host rapido emite e o old.reddit nao -> o evento existe e falta o"
puts "      documento; o status do 403 teria de vir de outro lugar."
