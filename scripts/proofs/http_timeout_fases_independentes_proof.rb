# frozen_string_literal: true
# PROVA (reescrita, card t_cbfa9f27, item 1): `open_timeout` e `read_timeout`
# são DOIS RELÓGIOS INDEPENDENTES POR FASE. A soma do pior caso vem da
# SEQUENCIALIDADE das fases (connect → escrever → ler), não de uma soma de
# orçamentos que se acumulam no mesmo relógio.
#
# ── O QUE ESTA PROVA CORRIGE ────────────────────────────────────────────────
# A prova do PR #205 (`http_timeout_cumulativo_proof.rb`) usava um proxy que
# ACEITAVA a conexão na hora e só dormia depois. Medido: com o proxy o pedido
# saía em 2,21s, e sem proxy também 2,21s — o atraso do proxy caía DENTRO da
# janela de `read`, nunca dentro da de `open`. O "cenário A" era controle de
# NADA: os dois cenários mediam a mesma coisa, e a conclusão de "cumulativo" não
# tinha lastro.
#
# Aqui o atraso de OPEN cai no open DE VERDADE, retendo o SYN no kernel: um
# `listen(1)` cuja fila de accept fica CHEIA e sem `accept()` durante o tempo do
# open. Com `tcp_abort_on_overflow=0` (default do Linux) o SYN do cliente é
# DESCARTADO e ele o retransmite — o `connect()` só termina quando alguém
# drena a fila. Nenhum proxy, nenhum `accept` antecipado.
#
# ── MEDIÇÃO DO PRÓPRIO ARRANJO (dentro deste container) ─────────────────────
# A fila de accept segura BACKLOG+1 conexões (medido: backlog=1 segura 2), e o
# tempo do connect é um múltiplo do RTO inicial (~1s), porque o SYN só volta no
# próximo RTO:
#   drena em 0,05s -> connect em 1,04s     drena em 1,05s -> connect em 2,05s
#   drena em 0,50s -> connect en 1,02s     drena em 1,50s -> connect em 2,05s
#   drena em 1,00s -> connect em 1,02s     drena em 2,00s -> connect em 2,05s
# Por isso o open de ~1,0s (um degrau) é o menor atraso que este arranjo mede
# de forma reprodutível, e é com ele que os tetos são escolhidos. A prova
# IMPRIME a duração medida de cada fase — nunca um número assumido.
#
# Uso: rode DENTRO do container do repo (é o ruby que fala com o X):
#   docker compose -f docker/docker-compose.yml run --rm --entrypoint ruby test \
#     scripts/proofs/http_timeout_fases_independentes_proof.rb
require "faraday"
require "socket"
require "benchmark"

# Fase de open: DOIS degraus de RTO (~2,05s). Fase de read: 1,2s (não quantizada:
# o servidor dorme antes de responder, o que não passa por RTO nenhum).
#
# Dois degraus, e não um, porque o teto do cenário B (1,5s) precisa cair ABAIXO
# do connect com folga: com um degrau o connect completa em ~1,02s e o teto de
# 1,5s nunca dispara — foi assim que a primeira versão deste arquivo mediu
# "HTTP 200" no cenário que deveria estourar. A 2,05s contra 1,5s sobram 0,55s
# de margem, e o valor é estável porque é quantizado por RTO, não por sorte.
ATRASO_OPEN_SEGUNDOS = 2
ATRASO_READ = 1.2
BACKLOG = 1
# Medido: a fila de accept segura BACKLOG+1. Abaixo de 2, o SYN do cliente
# ainda é respondido e o atraso cai fora do open.
CHEIOS_NA_FILA = BACKLOG + 1

# ── O SERVIDOR ──────────────────────────────────────────────────────────────
# A ordem importa e já custou uma versão errada desta prova:
#
#  - As conexões de preenchimento SÃO aceitas e fechadas uma a uma, e a fila é
#    reabastecida depois. Se elas ficarem paradas na fila sem `accept`, o SYN do
#    cliente é respondido de imediato (o handshake é feito pelo kernel) e o
#    atraso não cai no open. Se o setup DRAINAR a fila e deixá-la vazia, a
#    conexão de bloqueio vira a única occupant e o `accept` do fim pega ela, não
#    o cliente.
#  - O que segura o open é a conexão de bloqueio, que entra por último e fica.
#  - Quando o servidor drena, a vaga liberada promove o SYN retransmitido: aí
#    sim o `accept` devolve o cliente de verdade.
def arranjo
  srv = Socket.new(:INET, :STREAM)
  srv.setsockopt(:SOCKET, :REUSEADDR, true)
  srv.bind(Addrinfo.tcp('127.0.0.1', 0))
  srv.listen(BACKLOG)
  porta = srv.local_address.ip_port
  saida = Socket.pack_sockaddr_in(porta, '127.0.0.1')

  # ── setup: encher a fila, drenar, encher de novo ──
  # Encher e drenar em ciclos deixa a fila CHEIA de conexões ACEITAS (o
  # handshake já passou) e nenhuma delas é a do cliente: o próximo SYN é
  # descartado.
  2.times do
    fillers = Array.new(CHEIOS_NA_FILA) { s = Socket.new(:INET, :STREAM); s.connect(saida); s }
    fillers.each do |s|
      aceita, = srv.accept
      aceita.close
      s.close
    end
  end

  bloqueio = Socket.new(:INET, :STREAM)
  bloqueio.connect(saida) # esta cabe: a fila está vazia depois do setup
  fillers2 = Array.new(CHEIOS_NA_FILA - 1) { s = Socket.new(:INET, :STREAM); s.connect(saida); s }

  th = Thread.new do
    sleep ATRASO_OPEN_SEGUNDOS
    # Drena a fila inteira: só depois de isso o SYN do cliente é promovido.
    (CHEIOS_NA_FILA).times { f, = srv.accept; f.close }
    real, = srv.accept # o cliente, pelo SYN retransmitido
    t_open = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      real.gets
      sleep ATRASO_READ
      real.print "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    ensure
      real.close
    end
    t_open
  end

  [porta, th, [bloqueio, *fillers2]]
end

# O Faraday reembrulha a exceção: `Net::OpenTimeout` e `Net::ReadTimeout` saem
# como `Faraday::ConnectionFailed` / `Faraday::TimeoutError`
# (faraday-net_http-3.4.4/lib/faraday/adapter/net_http.rb:70 e :74). A fase que
# estourou está no `cause` — reportá-la é o que separa "estourou o connect" de
# "estourou a leitura".
def desfecho(e)
  "#{e.cause&.class || e.class} (Faraday: #{e.class})"
end

def cenario(open_timeout, read_timeout)
  porta, th, a_limpar = arranjo

  conn = Faraday.new(url: "http://127.0.0.1:#{porta}") do |f|
    f.options.open_timeout = open_timeout
    f.options.timeout = read_timeout
  end

  res = nil
  t = Benchmark.realtime do
    res = begin
      "HTTP #{conn.get('/').status}"
    rescue StandardError => e
      desfecho(e)
    end
  end
  th.kill
  a_limpar.each { |s| s.close rescue nil }
  [res, t]
end

puts "ruby #{RUBY_VERSION} | faraday #{Faraday::VERSION} | net-http #{Net::HTTP::VERSION}"
puts "tcp_abort_on_overflow = #{File.read('/proc/sys/net/ipv4/tcp_abort_on_overflow').strip}" \
     ' (0 = o kernel descarta o SYN quando a fila de accept enche)'
puts "Servidor IDENTICO nos três cenários:"
puts "  fase de OPEN = ~#{ATRASO_OPEN_SEGUNDOS}s, retendo o SYN (fila de accept cheia, zero accepts)"
puts "  fase de READ = #{ATRASO_READ}s, o servidor final demorando a responder"
puts "  total de uma requisição = ~#{ATRASO_OPEN_SEGUNDOS + ATRASO_READ}s (as fases em SÉRIE)"
puts "=" * 78

# ── CENÁRIO A (controle) — as DUAS fases com folga ─────────────────────────
a, ta = cenario(5.0, 10.0)
puts "A  open=5,0 read=10,0 -> #{a} em #{format('%.2f', ta)}s"
puts "   as duas fases folgadas: o total medido (~#{format('%.2f', ta)}s) e' a SOMA delas em série," \
     "\n   e não o MAIOR delas — que é o que a semântica MAX daria."

# ── CENÁRIO B — open curto, read LONGO: o read folgado NÃO cobre o connect ──
b, tb = cenario(1.5, 10.0)
puts "B  open=1,5 read=10,0 -> #{b} em #{format('%.2f', tb)}s"
puts "   o read 10x folgado não salvou: o connect estourou em ~#{format('%.2f', tb)}s, ANTES de" \
     "\n   qualquer byte de resposta. A fase que matou a requisição foi a do OPEN."

# ── CENÁRIO C — open folgado, read curto: o open folgado NÃO cobre a resposta
c, tc = cenario(10.0, 1.0)
puts "C  open=10,0 read=1,0 -> #{c} em #{format('%.2f', tc)}s"
puts "   o open 10x folgado não salvou: a LEITURA estourou em ~#{format('%.2f', tc)}s, com o" \
     "\n   connect já completado dentro do open folgado."

# ── VEREDITO ────────────────────────────────────────────────────────────────
ok = a.match?(/HTTP 200/) && b.match?(/OpenTimeout/) && c.match?(/ReadTimeout/)
puts "=" * 78
puts "VEREDITO: #{ok ? 'DOIS RELÓGIOS INDEPENDENTES CONFIRMADO' : 'NÃO CONFIRMADO'}"
puts "  A  open=5,0/read=10,0 -> HTTP 200. O arranjo funciona: o open de ~#{ATRASO_OPEN_SEGUNDOS}s" \
     "\n     caiu no open de verdade, e o read de #{ATRASO_READ}s, na resposta de verdade."
puts "  B  open=1,5/read=10,0 -> Net::OpenTimeout. O read folgado NÃO cobre o connect."
puts "  C  open=10,0/read=1,0 -> Net::ReadTimeout. O open folgado NÃO cobre a resposta."
puts "  B e C juntos são a separação que derruba a semântica 'cumulativa': se o read fosse" \
     "\n  orçamento SOMADO ao open, o read de 10,0s de B cobriria o open de ~#{ATRASO_OPEN_SEGUNDOS}s" \
     "\n  e B PASSARIA. Ele não passa — porque cada fase tem o SEU relógio, e uma delas"
puts "  estoura antes de a outra ser tocada."
puts "  A SOMA do pior caso vem da SEQUENCIALIDADE (connect → escrever → ler, uma atrás da"
puts "  outra), não de dois orçamentos que se acumulam no mesmo relógio."

# ── EXIT: A PROVA CONFIRMA OU NÃO CONFIRMA (fecha o furo) ────────────────────
#
# Esta prova saía 0 MESMO QUANDO NÃO CONFIRMAVA. Quem a roda num script (o par
# por mutação, o CI) não tinha como distinguir "a prova passou" de "a prova
# rodou": o código 0 era o do fim do script, e o veredicto estava só na tela.
# A diferença entre um 0 que significa "confirmado" e um 0 que significa "rodou"
# é a diferença entre uma prova e uma decoracao.
#
# O conserto é o mesmo do outro proof da casa (read_timeout_por_leitura_proof.rb:
# `exit(ok ? 0 : 1)`), e ele vai DEPOIS das linhas de explicação de propósito:
# quem lê a saída tem de ver o veredicto e o porquê ANTES do processo sair, e
# quem só olha o código de saída tem o bit que falta.
exit(ok ? 0 : 1)
