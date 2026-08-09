# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/ssrf_guard"

class Fetcher::SsrfGuardTest < ActiveSupport::TestCase
  def stub_resolve(host, ips)
    Fetcher::SsrfGuard.stubs(:resolve_all).with(host).returns(ips)
  end

  test "http scheme é permitido" do
    stub_resolve("example.com", ["8.8.8.8"])
    uri = Fetcher::SsrfGuard.validate!("http://example.com/page")
    assert_equal "http", uri.scheme
  end

  test "https scheme é permitido" do
    stub_resolve("example.com", ["8.8.8.8"])
    uri = Fetcher::SsrfGuard.validate!("https://example.com/page")
    assert_equal "https", uri.scheme
  end

  test "ftp scheme é bloqueado" do
    error = assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("ftp://example.com/")
    end
    assert_match(/scheme/i, error.reason)
  end

  test "URL malformada é bloqueada" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("nao-e-uma-url")
    end
  end

  test "URL vazia é bloqueada" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("")
    end
  end

  test "URL > 2048 chars é bloqueada" do
    long = "https://example.com/#{'a' * 2048}"
    error = assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!(long)
    end
    assert_match(/longa/i, error.reason)
  end

  test "host vazio é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http:///caminho")
    end
  end

  test "IP literal 127.0.0.1 é bloqueado" do
    error = assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://127.0.0.1/")
    end
    assert_match(/privado|loopback|interno/i, error.reason)
  end

  test "IP literal 10.0.0.5 (RFC1918) é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://10.0.0.5/")
    end
  end

  test "IP literal 172.16.0.1 (RFC1918) é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://172.16.0.1/")
    end
  end

  test "IP literal 192.168.1.1 (RFC1918) é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://192.168.1.1/")
    end
  end

  test "IP literal 169.254.169.254 (AWS IMDS / link-local) é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://169.254.169.254/")
    end
  end

  test "IP literal 100.64.0.1 (CGNAT) é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://100.64.0.1/")
    end
  end

  test "IP literal 0.0.0.0 é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://0.0.0.0/")
    end
  end

  test "IPv6 literal ::1 é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://[::1]/")
    end
  end

  test "IPv6 literal fc00::1 (ULA) é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://[fc00::1]/")
    end
  end

  test "IPv6 literal fe80::1 (link-local) é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://[fe80::1]/")
    end
  end

  test "IPv4-mapped IPv6 ::ffff:10.0.0.1 é bloqueado" do
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://[::ffff:10.0.0.1]/")
    end
  end

  test "hostname que resolve para IP privado é bloqueado" do
    stub_resolve("interno.empresa.local", ["10.0.0.1"])
    error = assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://interno.empresa.local/")
    end
    assert_match(/privado|interno/i, error.reason)
  end

  test "hostname que resolve apenas para IP público é permitido" do
    stub_resolve("example.com", ["93.184.216.34"])
    uri = Fetcher::SsrfGuard.validate!("http://example.com/")
    assert_equal "example.com", uri.host
  end

  test "DNS rebinding: hostname com IP público E privado é bloqueado" do
    stub_resolve("rebind.attacker.com", ["8.8.8.8", "10.0.0.1"])
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://rebind.attacker.com/")
    end
  end

  test "hostname que não resolve é bloqueado" do
    stub_resolve("nxdomain.invalid", [])
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://nxdomain.invalid/")
    end
  end

  test "searxng (Docker service name) resolve pra rede privada e é bloqueado" do
    stub_resolve("searxng", ["172.18.0.5"])
    assert_raises(Fetcher::SsrfGuard::Blocked) do
      Fetcher::SsrfGuard.validate!("http://searxng:8080/")
    end
  end
end
