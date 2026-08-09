# frozen_string_literal: true

require "ipaddr"
require "resolv"
require "uri"

module Fetcher
  module SsrfGuard
    MAX_URL_LENGTH = 2048
    ALLOWED_SCHEMES = %w[http https].freeze
    DNS_TIMEOUT = 3

    IPV4_BLOCKED = [
      "0.0.0.0/8",
      "10.0.0.0/8",
      "100.64.0.0/10",
      "127.0.0.0/8",
      "169.254.0.0/16",
      "172.16.0.0/12",
      "192.0.2.0/24",
      "192.168.0.0/16",
      "198.51.100.0/24",
      "203.0.113.0/24",
      "224.0.0.0/4",
      "240.0.0.0/4",
      "255.255.255.255/32"
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    IPV6_BLOCKED = [
      "::1/128",
      "::/128",
      "::ffff:0:0/96",
      "fc00::/7",
      "fe80::/10",
      "ff00::/8"
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    class Blocked < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("fetch bloqueado: #{reason}")
      end
    end

    # Resultado de uma validação: a URI aprovada, o IP EXATO que foi validado e
    # o hostname validado. Quem for conectar deve usar `ip` — re-resolver o
    # hostname na hora de conectar reabre a janela de DNS rebinding que esta
    # validação fecha.
    #
    # O caminho estático honra isto (o SafeHttpClient pinou o IP no socket). O
    # caminho Chrome NÃO consegue pinar o socket: quem navega (PageFetcher,
    # BrowserSession) tem de conferir depois o `remoteIPAddress` que o navegador
    # usou de fato contra `ip` — ver `Fetcher::RebindingGuard`.
    Resolution = Struct.new(:uri, :ip, :host, keyword_init: true)

    class << self
      # Valida e devolve o IP fixado. Uma única resolução DNS: o IP validado é o
      # mesmo que será usado no connect.
      def resolve!(url_string)
        uri  = validated_uri(url_string)
        host = uri.host.to_s

        literal_ip = extract_ip_literal(host)
        ip = if literal_ip
               ensure_ip_allowed!(literal_ip)
               literal_ip.to_s
             else
               first_public_ip!(host)
             end

        Resolution.new(uri: uri, ip: ip, host: host.downcase)
      end

      def validate!(url_string)
        resolve!(url_string).uri
      end

      # Exposto para stubbing em testes.
      def resolve_all(host)
        Resolv::DNS.open do |dns|
          dns.timeouts = DNS_TIMEOUT
          a = dns.getresources(host, Resolv::DNS::Resource::IN::A).map { |r| r.address.to_s }
          aaaa = dns.getresources(host, Resolv::DNS::Resource::IN::AAAA).map { |r| r.address.to_s }
          (a + aaaa).uniq
        end
      rescue Resolv::ResolvError, Resolv::ResolvTimeout
        []
      end

      def ip_blocked?(ip_string)
        ip = IPAddr.new(ip_string)
        if ip.ipv4?
          IPV4_BLOCKED.any? { |range| range.include?(ip) }
        else
          # IPv4-mapped IPv6: unwrap e checa contra IPv4 blocklist também
          if ipv4_mapped?(ip)
            return true if IPV4_BLOCKED.any? { |range| range.include?(unwrap_ipv4_mapped(ip)) }
          end
          IPV6_BLOCKED.any? { |range| range.include?(ip) }
        end
      rescue IPAddr::InvalidAddressError
        true
      end

      private

      def validated_uri(url_string)
        raise Blocked.new("URL vazia") if url_string.to_s.strip.empty?
        raise Blocked.new("URL muito longa (>#{MAX_URL_LENGTH} chars)") if url_string.to_s.length > MAX_URL_LENGTH

        uri = parse_uri(url_string)

        unless ALLOWED_SCHEMES.include?(uri.scheme)
          raise Blocked.new("scheme não permitido: #{uri.scheme.inspect}")
        end

        raise Blocked.new("host vazio") if uri.host.to_s.empty?
        raise Blocked.new("credenciais na URL não são aceitas") if uri.userinfo.present?

        uri
      end

      def first_public_ip!(host)
        ips = resolve_all(host)
        raise Blocked.new("hostname não resolve (#{host})") if ips.empty?

        blocked = ips.select { |ip| ip_blocked?(ip) }
        unless blocked.empty?
          raise Blocked.new("host resolve para IP privado/interno (#{blocked.join(', ')})")
        end

        ips.first
      end

      def parse_uri(url_string)
        URI.parse(url_string.to_s)
      rescue URI::InvalidURIError => e
        raise Blocked.new("URL inválida: #{e.message}")
      end

      def extract_ip_literal(host)
        # URI.parse entrega IPv6 com colchetes; strip
        candidate = host.start_with?("[") && host.end_with?("]") ? host[1..-2] : host
        IPAddr.new(candidate)
      rescue IPAddr::InvalidAddressError
        nil
      end

      def ensure_ip_allowed!(ip)
        return unless ip_blocked?(ip.to_s)

        raise Blocked.new("host privado/interno (#{ip})")
      end

      def ipv4_mapped?(ip)
        ip.ipv6? && IPAddr.new("::ffff:0:0/96").include?(ip)
      end

      def unwrap_ipv4_mapped(ip)
        # IPAddr IPv6 → extrai os últimos 32 bits como IPv4
        IPAddr.new(ip.to_i & 0xFFFFFFFF, Socket::AF_INET)
      end
    end
  end
end
