# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

class NodriverFetchScriptTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts/python/nodriver_fetch.py").to_s

  # Fake do módulo `nodriver` usado pelo script em ambiente de teste.
  #
  # Contratos do fake (exigidos pelo merge laguna-fix):
  #   1. FakePage.send() registra quando Network.enable é chamado e, só então,
  #      habilita a emissão de eventos ResponseReceived pelo FakePage.get.
  #   2. FakePage.get SÓ emite eventos ResponseReceived se Network.enable tiver
  #      sido chamado (efetivamente) ANTES do get.
  #
  # O script em GREEN chama `await page.send(uc.cdp.network.enable())` antes do
  # `browser.get`. O fake reconhece esse comando e marca `network_enabled`.
  #
  # Variáveis de ambiente (apenas no fake, NUNCA no código de produção):
  #   DOC_IP_SEQUENCE : "public_first" (default) -> 1.2.3.4, 10.0.0.1
  #                     "private_first"          -> 10.0.0.1, 1.2.3.4
  #   DOC_NO_ENABLE   : "1" -> send() NÃO habilita a rede (simula "sem
  #                     Network.enable efetivo" / send sem efeito antes do get)
  #                     para validar o fail-open honesto.
  FAKE_NODRIVER = <<~PYTHON
    import asyncio
    import os

    class ResourceType:
        DOCUMENT = "Document"

    class NetworkEnableCommand:
        pass

    class ResponseReceived:
        pass

    def _network_enable():
        return NetworkEnableCommand()

    class Network:
        ResourceType = ResourceType
        ResponseReceived = ResponseReceived
        enable = staticmethod(_network_enable)

    class cdp:
        network = Network

    class FakeResponse:
        def __init__(self, ip):
            self.remote_ip_address = ip

    class FakeParams:
        def __init__(self, ip):
            self.type_ = ResourceType.DOCUMENT
            self.response = FakeResponse(ip)

    class FakePage:
        def __init__(self):
            self.handlers = []
            self.network_enabled = False
            self.enable_called = False

        def add_handler(self, event, handler):
            self.handlers.append(handler)

        def remove_handler(self, event, handler):
            if handler in self.handlers:
                self.handlers.remove(handler)

        async def send(self, command):
            # Requisito 1: registra quando Network.enable é chamado.
            if isinstance(command, NetworkEnableCommand):
                self.enable_called = True
                # Requisito (cenário 4): sem enable efetivo, não habilita eventos.
                if os.environ.get("DOC_NO_ENABLE") != "1":
                    self.network_enabled = True

        async def get(self, url):
            # Requisito 2: emite eventos ResponseReceived SÓ se enable foi chamado.
            if self.network_enabled:
                seq = os.environ.get("DOC_IP_SEQUENCE", "public_first")
                if seq == "private_first":
                    ips = ["10.0.0.1", "1.2.3.4"]
                else:
                    ips = ["1.2.3.4", "10.0.0.1"]
                for ip in ips:
                    for handler in list(self.handlers):
                        handler(FakeParams(ip))
            return self

        async def get_content(self):
            return "<html>body</html>"

        async def evaluate(self, expr):
            if "document.readyState" in expr:
                return "complete"
            if "innerText.length" in expr:
                return 100
            if "document.title" in expr:
                return "Test Title"
            if "window.location.href" in expr:
                return "https://example.com/final"
            return "body text"

    class FakeBrowser:
        def __init__(self):
            self.main_tab = FakePage()

        async def get(self, url):
            # Delega à aba principal (onde o listener foi registrado) para que
            # os eventos ResponseReceived sejam emitidos no handler correto.
            return await self.main_tab.get(url)

        def stop(self):
            pass

    async def start(**kwargs):
        return FakeBrowser()
  PYTHON

  FAKE_BROWSER_BINARY = <<~PYTHON
    def start_kwargs(args=None):
        return {}
  PYTHON

  def build_fake_env(extra_env = {})
    dir = Dir.mktmpdir
    package_nodriver = File.join(dir, "nodriver")
    FileUtils.mkdir_p(package_nodriver)
    File.write(File.join(package_nodriver, "__init__.py"), FAKE_NODRIVER)

    binary_file = File.join(dir, "browser_binary.py")
    File.write(binary_file, FAKE_BROWSER_BINARY)

    env = { "PYTHONPATH" => dir }.merge(extra_env)
    [dir, env]
  end

  test "com Network.enable, listener captura o IP do ultimo documento (publico -> privado)" do
    dir, env = build_fake_env("DOC_IP_SEQUENCE" => "public_first")
    stdout, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    assert status.success?, "script falhou com status #{status.exitstatus}: #{stderr}"
    json = JSON.parse(stdout)
    assert_equal "10.0.0.1", json["document_ip"],
      "publico(1.2.3.4) -> privado(10.0.0.1): deve retornar o IP do ultimo documento (10.0.0.1)"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "preserva o IP bloqueado (privado) contra documento publico posterior (privado -> publico)" do
    dir, env = build_fake_env("DOC_IP_SEQUENCE" => "private_first")
    stdout, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    assert status.success?, "script falhou com status #{status.exitstatus}: #{stderr}"
    json = JSON.parse(stdout)
    # Contrato: "IP bloqueado observado nao pode ser perdido". Um IP privado
    # (10.0.0.1) detectado primeiro nao pode ser sobrescrito por um documento
    # publico posterior (1.2.3.4) — senao o IP bloqueado deixa de ser detectado.
    assert_equal "10.0.0.1", json["document_ip"],
      "privado(10.0.0.1) -> publico(1.2.3.4): deve PRESERVAR o bloqueado 10.0.0.1"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "sem Network.enable efetivo -> document_ip vazio (fail-open honesto) e script sucesso" do
    dir, env = build_fake_env("DOC_NO_ENABLE" => "1")
    stdout, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    assert status.success?, "script falhou com status #{status.exitstatus}: #{stderr}"
    json = JSON.parse(stdout)
    # Sem enable efetivo, o CDP nao garante eventos; document_ip fica vazio e a
    # validacao Ruby opera em fail-open — mas o script TERMINA com sucesso.
    assert_equal "", json["document_ip"],
      "sem Network.enable: document_ip deve ser vazio (fail-open honesto)"
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
