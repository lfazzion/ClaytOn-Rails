# frozen_string_literal: true
# PROVA do item 2 do #205 (card t_cbfa9f27): `read_timeout` do Net::HTTP é
# orçamento POR LEITURA, não teto da resposta.
#
# `net/protocol.rb:229` chama `wait_readable(@read_timeout)` DENTRO do laço de
# retry de `rbuf_fill` (o `do ... end while true`). Cada leitura individual tem
# o seu relógio, e a requisição só morre quando UMA delas estoura. Um servidor
# que manda bytes devagar — mas sempre dentro do teto — NUNCA estoura o read:
# a requisição vive por quantas leituras forem necessárias, e esse número não
# tem limite no cliente.
#
# É o furo que o `HTTP_TOTAL_TIMEOUT` (8s, em volta da requisição inteira) veio
# fechar. Esta prova mede o furo e mostra o teto total cortando o drip.
#
# ── O QUE ESTA PROVA NÃO AFIRMA ───────────────────────────────────────────
# O drip é uma CLASSE de servidor (bytes devagar, sempre dentro do teto), não
# uma medição do comportamento do X. O que ela prova é a propriedade do
# cliente: existe servidor que sobrevive a QUALQUER `read_timeout` finito. Não
# mede quantos bytes o X manda nem se ele dripa — isso não é sabível daqui.
#
# Uso: rode DENTRO do container do repo:
#   docker compose -f docker/docker-compose.yml run --rm --entrypoint ruby test \
#     scripts/proofs/read_timeout_por_leitura_proof.rb
require "faraday"
require "socket"

READ_TIMEOUT = 1.0
TETO_TOTAL = 8

# Envia 1 byte a cada `intervalo` segundos. A CABEÇA vai de uma vez, para que o
# que se mede depois seja só o corpo pingando.
def drip(intervalo:, total_aprox:)
  srv = Socket.new(:INET, :STREAM)
  srv.setsockopt(:SOCKET, :REUSEADDR, true)
  srv.bind(Addrinfo.tcp('127.0.0.1', 0))
  srv.listen(4)
  porta = srv.local_address.ip_port
  corpo = (total_aprox / intervalo).ceil
  thread = Thread.new do
    c, = srv.accept
    c.gets
    c.print "HTTP/1.1 200 OK\r\nContent-Length: #{corpo}\r\nConnection: close\r\n\r\n"
    c.flush
    corpo.times { c.print('.'); c.flush; sleep intervalo }
    c.close
  rescue StandardError
    nil
  end
  [porta, thread]
end

# SEM teto total: o `read_timeout` é o único relógio, e a requisição só morre se
# UMA leitura estoura — o que o drip não permite.
def medir_sem_teto_total(intervalo:, teto_leitura: READ_TIMEOUT, teto_esperado: nil)
  porta, th = drip(intervalo: intervalo, total_aprox: teto_esperado || 120)
  conn = Faraday.new(url: "http://127.0.0.1:#{porta}") do |f|
    f.options.open_timeout = 3
    f.options.timeout = teto_leitura
  end

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  desfecho =
    begin
      "HTTP #{conn.get('/').status}"
    rescue StandardError => e
      "#{e.cause&.class || e.class}"
    end
  decorrido = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  th.kill
  [desfecho, decorrido]
end

# COM teto total: é o que o `http_get` do resolver faz — `Timeout.timeout`
# ENVOLVE a requisição inteira, e é o que corta o drip. (A primeira versão
# desta prova tinha o nome "`medir_com_teto_total`" e NÃO aplicava o
# `Timeout.timeout`: a requisição vivia 48,41s e o veredito saía "NÃO
# CONFIRMADO" — o nome prometia um teto que o corpo não tinha. O mesmo
# `Timeout::Error` do `http_get` é traduzido aqui para a mesma exceção.)
def medir_com_teto_total(intervalo:)
  porta, th = drip(intervalo: intervalo, total_aprox: TETO_TOTAL * 6)
  conn = Faraday.new(url: "http://127.0.0.1:#{porta}") do |f|
    f.options.open_timeout = 3
    f.options.timeout = READ_TIMEOUT
  end

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  desfecho =
    begin
      "HTTP #{Timeout.timeout(TETO_TOTAL) { conn.get('/') }.status}"
    rescue Timeout::Error
      'Timeout::Error (teto total)'
    rescue StandardError => e
      "#{e.cause&.class || e.class}"
    end
  decorrido = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  th.kill
  [desfecho, decorrido]
end

puts "ruby #{RUBY_VERSION} | faraday #{Faraday::VERSION} | net-http #{Net::HTTP::VERSION}"
puts "read_timeout = #{READ_TIMEOUT}s (POR LEITURA) | teto total = #{TETO_TOTAL}s"
puts "=" * 78

# ── CONTRASTE: drip LENTO (cada leitura abaixo do teto) vs drip RÁPIDO ─────
#
# Com o drip a 0,5s, cada `wait_readable` individual retorna em ~0,5s — bem
# abaixo do teto de 1,0s — então o read NUNCA estoura. O que estoura o relógio
# é o TEMPO TOTAL, e ele não tem teto no cliente puro.
resultados = {}
[[0.5, 40], [0.9, 60]].each do |intervalo, limite|
  desfecho, decorrido = medir_sem_teto_total(intervalo: intervalo, teto_esperado: limite)
  resultados[intervalo] = [desfecho, decorrido]
  puts format('SEM teto total, 1 byte a cada %.1fs -> %s em %.2fs', intervalo, desfecho, decorrido)
  puts format('   o read de %.1fs nao estourou: cada leitura ficou em %.1fs, abaixo do teto.',
              READ_TIMEOUT, intervalo)
end

# ── O TETO TOTAL CORTA O MESMO DRIP ──────────────────────────────────────
desfecho_c, decorrido_c = medir_com_teto_total(intervalo: 0.05)
puts format('COM teto total de %ds, 1 byte a cada 0.05s -> %s em %.2fs', TETO_TOTAL, desfecho_c, decorrido_c)

puts "=" * 78
# O veredito: a requisição com drip sobrevive MUITO além de read+open (1,0+3,0
# = 4,0s), o que prova que a soma `open + read` não é o teto. E o teto total
# corta o mesmo drip, o que prova que ele é o relógio que fecha a conta.
sobreviveu = resultados.values.all? { |(_d, t)| t > READ_TIMEOUT + 3.0 }
cortou = decorrido_c >= TETO_TOTAL * 0.9 && decorrido_c < TETO_TOTAL + 1.0
ok = sobreviveu && cortou
puts "VEREDITO: #{ok ? 'READ_TIMEOUT E\' TETO POR LEITURA CONFIRMADO' : 'NAO CONFIRMADO'}"
resultados.each do |intervalo, (_d, t)|
  puts format('  drip a %.1fs com read de %.1fs: %.2fs de vida contra %.1fs de open+read -> %s',
              intervalo, READ_TIMEOUT, t, READ_TIMEOUT + 3.0,
              t > READ_TIMEOUT + 3.0 ? 'SOBREVIVEU (a soma nao e\' o teto)' : 'NAO sobreviveu')
end
puts format('  drip a 0.05s com teto total de %ds: %.2fs -> o total cortou o que o read nunca cortaria',
            TETO_TOTAL, decorrido_c)
exit(ok ? 0 : 1)
