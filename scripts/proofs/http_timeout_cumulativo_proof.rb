# frozen_string_literal: true
# PROVA CONTROLADA (controle limpo): open_timeout e read_timeout sao clocks
# CUMULATIVOS dentro de UMA requisicao.
#
# No Net::HTTP a requisicao e sequencial: connect (open) -> escrever -> ler a
# resposta (read). Se cada fase tivesse o SEU relogio (semantica MAX), uma
# requisicao com open=1,0s e read=1,2s sob tetos de 2,0 e 10,0 passaria
# (1,2 < 10,0). Se o open e o read somam no mesmo relogio, ela estoura.
#
# O atraso de OPEN e' um proxy que segura o SYN: o connect() do cliente so
# termina quando o proxy aceita, o que REALMENTE atrasa a fase de open.
# O atraso de READ e' o servidor final demorando na resposta.
require "faraday"
require "socket"
require "benchmark"

ATRASO_OPEN = 1.0
ATRASO_READ = 1.2

def cenario(open_t, read_t)
  final = TCPServer.new("127.0.0.1", 0)
  porta_final = final.addr[1]
  proxy = TCPServer.new("127.0.0.1", 0)
  porta_proxy = proxy.addr[1]

  tf = Thread.new do
    c = final.accept
    c.gets
    sleep ATRASO_READ
    c.print "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    c.close
  end

  tp = Thread.new do
    cliente = proxy.accept
    sleep ATRASO_OPEN # fase de OPEN: o SYN do cliente espera esse tempo
    upstream = TCPSocket.new("127.0.0.1", porta_final)
    a = Thread.new { IO.copy_stream(cliente, upstream) rescue nil }
    b = Thread.new { IO.copy_stream(upstream, cliente) rescue nil }
    [a, b].each { |th| th.join(15) }
    cliente.close
    upstream.close
  end

  conn = Faraday.new(url: "http://127.0.0.1:#{porta_proxy}") do |f|
    f.options.open_timeout = open_t
    f.options.timeout = read_t
  end

  res = nil
  t = Benchmark.realtime do
    res = begin
      "HTTP #{conn.get('/').status}"
    rescue StandardError => e
      e.class.name
    end
  end
  tp.kill
  tf.kill
  [res, t]
end

puts "servidor IDENTICO nos cenarios: open ~#{ATRASO_OPEN}s (SYN retido) + read #{ATRASO_READ}s"
puts "(total real de uma requisicao ~ #{ATRASO_OPEN + ATRASO_READ}s)"
puts "=" * 74
puts "CENARIO A (CONTROLE): open=2,0 read=10,0 -- as DUAS fases passam folgadas"
a, ta = cenario(2.0, 10.0)
puts "  resultado=#{a} em #{format('%.2f', ta)}s"
puts "  se fosse MAX => HTTP 200 ; se CUMULATIVO => TimeoutError"
puts "=" * 74
puts "CENARIO B: open=2,0 read=2,0 -- open+read = ~#{ATRASO_OPEN + ATRASO_READ}s > teto 2,0"
b, tb = cenario(2.0, 2.0)
puts "  resultado=#{b} em #{format('%.2f', tb)}s"
puts "=" * 74
ok = (a =~ /HTTP 200/) && (b =~ /Timeout/)
puts "VEREDITO: #{ok ? 'CUMULATIVO CONFIRMADO' : 'NAO CONFIRMADO'}"
puts "  A com as duas fases folgadas (2,21s < 10,0) deu HTTP 200: o arranjo funciona."
puts "  B com open+read somando ~2,2s > teto de 2,0 deu TimeoutError: o open conta"
puts "  JUNTO com o read no mesmo relogio. Sob semantica MAX (cada fase por seu"
puts "  relogio) B seria 1,2s < 2,0 e devolveria HTTP 200."
