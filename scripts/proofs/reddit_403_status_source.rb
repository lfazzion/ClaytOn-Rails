# frozen_string_literal: true

# PROVA (fix t_324ad4fd) — o status do DOCUMENTO PRINCIPAL chega ao Ruby?
#
# O conserto (b) do card classifica o 403 como 403. A classified precisa de uma
# FONTE do status. A fonte que hoje existe no código (`page.network.response&
# .status`) é o ULTIMO exchange da sessão CDP e saiu VAZIA em 53 de 65 navegacoes
# reais (M11, e reconfirmado agora no log de producao: `status=` vazio em
# 15.0s). O assinante de `Network.responseReceived` — o mesmo que o
# RebindingGuard usa para o remoteIPAddress — carrega `response.status`. A
# pergunta desta prova: ele chega?
#
#   docker cp scripts/proofs/reddit_403_status_source.rb docker-app-1:/tmp/st.rb
#   docker exec -w /rails docker-app-1 bin/rails runner /tmp/st.rb

Fetcher::BrowserSession

ALVOS = [
  "https://old.reddit.com/r/rust/comments/13eg738/meet_astgrep_a_rustbased_tool_for_code_searching/",
  "https://old.reddit.com/search?q=ruby&sort=relevance"
].freeze

capturas = Hash.new { |h, k| h[k] = [] }

ALVOS.each_with_index do |alvo, i|
  browser = Fetcher::PageFetcher.browser
  context = browser.contexts.create(disposeOnDetach: true)
  page = context.create_page
  begin
    page.timeout = 15
    page.command("Network.setUserAgentOverride",
                 userAgent: Fetcher::BrowserSession::REDDIT_USER_AGENT,
                 acceptLanguage: "pt-BR,pt;q=0.9",
                 platform: Fetcher::BrowserSession::REDDIT_PLATFORM)

    id = page.on("Network.responseReceived") do |params|
      next unless params["type"] == "Document"

      r = params["response"] || {}
      capturas[i] << { url: r["url"], status: r["status"], ip: r["remoteIPAddress"] }
    end

    erro = nil
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      page.go_to(alvo)
    rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError => e
      erro = e.class.name
    end
    dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
    page.off("Network.responseReceived", id)

    network_status = (page.network.response&.status rescue nil)
    puts "\n=== [#{i}] #{alvo} ==="
    puts "  go_to: #{dt}s  erro=#{erro.inspect}"
    puts "  page.network.response&.status (fonte de hoje) = #{network_status.inspect}"
    puts "  Network.responseReceived tipo=Document: #{capturas[i].size} evento(s)"
    capturas[i].each do |c|
      puts "    status=#{c[:status].inspect} remoteIPAddress=#{c[:ip].inspect} url=#{c[:url].to_s[0, 70]}"
    end
    body = (page.evaluate("document.body ? document.body.innerText : ''") rescue "").to_s
    puts "  innerText: #{body.strip[0, 120].inspect}"
  ensure
    begin
      page&.close
      context&.dispose
    rescue StandardError
      nil
    end
  end
end

puts "\n=== VEREDITO ==="
todos = capturas.values.flatten
docs = todos.select { |c| c[:url].to_s.include?("reddit.com") }
com_status = docs.count { |c| c[:status].is_a?(Integer) }
puts "  documentos do Reddit: #{docs.size}; com status Inteiro: #{com_status}"
puts "  rede antiga (network.response): #{todos.size} evento(s), status #{todos.map { |c| c[:status] }.inspect}"
puts "  SEMPRE o mesmo host: #{docs.map { |c| URI.parse(c[:url]).host rescue nil }.uniq.inspect}"
puts "  VEREDITO: a fonte NOVA (responseReceived do documento) entrega o status = " \
     "#{com_status.positive? && docs.all? { |c| c[:status] == 403 }}"
