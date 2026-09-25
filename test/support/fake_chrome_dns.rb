# frozen_string_literal: true

require "socket"

# DNS falso e hermético para os testes do cliente do Chrome.
#
# Intercepta `Addrinfo.getaddrinfo` E `Socket.getaddrinfo` SÓ para os nomes
# registrados, e imita o resolvedor real no ponto que importa: sem família
# pedida (nil/AF_UNSPEC), a lista volta com o IPv6 PRIMEIRO — o caso que a
# revisão do t_a7a8cad2 apontou (`getaddrinfo` pode devolver v6 antes do v4, e
# esse não é o caminho medido). Pedindo AF_INET, só v4. Os dois pontos de
# entrada são interceptados para que uma implementação ingênua
# (`Socket.getaddrinfo(host, ...).first`) não escape do teste.
# Nomes não registrados caem no resolvedor original.
#
# Uso: `FakeChromeDns.install("chrome" => ["fd00::c", "172.26.0.9"])` no setup e
# `FakeChromeDns.uninstall` no teardown.
module FakeChromeDns
  module_function

  def install(table)
    uninstall
    @originals = { Addrinfo => Addrinfo.method(:getaddrinfo), Socket => Socket.method(:getaddrinfo) }
    orig_addrinfo = @originals[Addrinfo]
    orig_socket = @originals[Socket]

    Addrinfo.define_singleton_method(:getaddrinfo) do |node, service = nil, family = nil, socktype = nil, *rest|
      ips = table[node]
      next orig_addrinfo.call(node, service, family, socktype, *rest) unless ips

      FakeChromeDns.pick(ips, family, node).map { |ip| Addrinfo.tcp(ip, service.to_i) }
    end

    Socket.define_singleton_method(:getaddrinfo) do |node, service = nil, family = nil, socktype = nil, *rest|
      ips = table[node]
      next orig_socket.call(node, service, family, socktype, *rest) unless ips

      FakeChromeDns.pick(ips, family, node).map do |ip|
        v6 = ip.include?(":")
        [v6 ? "AF_INET6" : "AF_INET", service.to_i, ip, ip,
         v6 ? Socket::AF_INET6 : Socket::AF_INET, Socket::SOCK_STREAM, Socket::IPPROTO_TCP]
      end
    end
  end

  def pick(ips, family, node)
    wanted = case family
             when nil, 0, :UNSPEC, :AF_UNSPEC, "AF_UNSPEC" then nil
             when Integer then family
             else Socket.const_get(:"AF_#{family.to_s.delete_prefix('AF_')}")
             end
    list = ips.sort_by { |ip| ip.include?(":") ? 0 : 1 } # v6 primeiro
    list = list.select { |ip| (ip.include?(":") ? Socket::AF_INET6 : Socket::AF_INET) == wanted } if wanted
    raise SocketError, "getaddrinfo: Address family for hostname not supported (#{node})" if list.empty?

    list
  end

  def uninstall
    return unless @originals

    @originals.each { |klass, original| klass.define_singleton_method(:getaddrinfo, original) }
    @originals = nil
  end
end
