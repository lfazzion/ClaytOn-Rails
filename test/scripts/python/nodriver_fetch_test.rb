# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

class NodriverFetchScriptTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts/python/nodriver_fetch.py").to_s

  # Achado F: imports `time`/`os` e a constante STABILITY_POLL eram mortos.
  # Um teste estatico garante que nao voltam a poluir o topo do modulo.
  test "sem imports mortos (time/os) nem STABILITY_POLL no script" do
    src = File.read(SCRIPT_PATH)
    refute_match(/^\s*import\s+time\s*$/, src, "import time morto nao deve existir")
    refute_match(/^\s*import\s+os\s*$/, src, "import os morto nao deve existir")
    refute_match(/STABILITY_POLL\s*=/, src, "constante STABILITY_POLL morta nao deve existir")
    refute_match(/\bos\./, src, "sem uso de os.* no script")
    refute_match(/\btime\./, src, "sem uso de time.* no script")
  end

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

    class FakeFrameNavigated:
        # API real (nodriver 0.50.3, verificado 13/08): FrameNavigated.params
        # é um objeto Frame com `id_` e `parent_id` — não campos no params.
        def __init__(self, frame_id, parent_id=None):
            class Frame:
                pass
            self.frame = Frame()
            self.frame.id_ = frame_id
            self.frame.parent_id = parent_id

    def _network_enable():
        return NetworkEnableCommand()

    class Network:
        ResourceType = ResourceType
        ResponseReceived = ResponseReceived
        enable = staticmethod(_network_enable)

    class Page:
        FrameNavigated = FakeFrameNavigated

    class cdp:
        network = Network
        page = Page

    class FakeResponse:
        def __init__(self, ip):
            self.remote_ip_address = ip

    class FakeParams:
        def __init__(self, ip, frame_id="MAIN_FRAME"):
            self.type_ = ResourceType.DOCUMENT
            self.response = FakeResponse(ip)
            self.frame_id = frame_id

    class FakePage:
        def __init__(self):
            self.resp_handlers = []
            self.frame_handlers = []
            self.network_enabled = False
            self.enable_called = False

        def add_handler(self, event, handler):
            if event is ResponseReceived:
                self.resp_handlers.append(handler)
            else:
                self.frame_handlers.append(handler)

        def remove_handler(self, event, handler):
            if event is ResponseReceived:
                if handler in self.resp_handlers:
                    self.resp_handlers.remove(handler)
            else:
                if handler in self.frame_handlers:
                    self.frame_handlers.remove(handler)

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
                # Simula a navegacao do frame principal ANTES dos documentos,
                # para que o listener fixe main_frame_id (Achado B). Sem isso o
                # script desligaria o filtro de subframe.
                for handler in list(self.frame_handlers):
                    handler(FakeFrameNavigated(frame_id="MAIN_FRAME", parent_id=None))
                seq = os.environ.get("DOC_IP_SEQUENCE", "public_first")
                if seq == "private_first":
                    docs = [("MAIN_FRAME", "10.0.0.1"), ("MAIN_FRAME", "1.2.3.4")]
                elif seq == "cgnat_first":
                    # RFC6598 CGNAT (100.64.0.0/10): NAO e IP privado no
                    # sentido ipaddress.is_private, mas e nao-global. O script
                    # deve trata-lo como bloqueado e preserva-lo contra um
                    # documento publico posterior (senao o Ruby valida so o
                    # final e o IP bloqueado vaza -> bypass SSRF).
                    docs = [("MAIN_FRAME", "100.64.0.1"), ("MAIN_FRAME", "1.2.3.4")]
                elif seq == "main_public_sub_private":
                    # Achado B: documento do frame PRINCIPAL e publico, mas um
                    # iframe/subframe carrega de IP privado. Antes da correcao o
                    # script aceitava QUALQUER DOCUMENT e capturava o IP do
                    # subframe -> bloqueio falso no Ruby. Apos a correcao o
                    # subframe (frame_id diferente) deve ser ignorado.
                    docs = [("MAIN_FRAME", "1.2.3.4"), ("SUB_FRAME", "10.0.0.1")]
                else:
                    docs = [("MAIN_FRAME", "1.2.3.4"), ("MAIN_FRAME", "10.0.0.1")]
                for frame_id, ip in docs:
                    for handler in list(self.resp_handlers):
                        handler(FakeParams(ip, frame_id=frame_id))
            return self

        async def get_content(self):
            return "<html>body</html>"

        async def evaluate(self, expr):
            if os.environ.get("DOC_RAISE_CANCELLED") == "1" and "document.readyState" in expr:
                # Achado C: simula o cancelamento do chamador CHEGANDO durante o
                # polling de prontidao. Agendamos o cancelamento da tarefa atual
                # para que o CancelledError SURJA no `await asyncio.sleep` do
                # wait_for_content_ready (e seja engolido pelo `except
                # asyncio.CancelledError: break`), nao na propria chamada de
                # evaluate. Antes da correcao o script terminava como sucesso —
                # rompendo o cancelamento. Apos a correcao o CancelledError
                # deve propagar (exit != 0).
                asyncio.current_task().cancel()
                return "complete"
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
            self.stop_called = False
            self.stop_awaited = False

        async def get(self, url):
            # Delega à aba principal (onde o listener foi registrado) para que
            # os eventos ResponseReceived sejam emitidos no handler correto.
            return await self.main_tab.get(url)

        def stop(self):
            # API real (nodriver 0.50.3, verificado 13/08): Browser.stop é
            # SÍNCRONO (retorna None) — `await browser.stop()` levantaria
            # TypeError em produção. O fake modela a API real; o script chama
            # browser.stop() sem await.
            self.stop_called = True
            sentinel = os.environ.get("DOC_STOP_SENTINEL")
            if sentinel:
                with open(sentinel, "w") as fh:
                    fh.write("called")
            # Modo de injecao de erro: simula um erro de limpeza REAL que a
            # producao nao deve mascarar com `except Exception: pass` amplo.
            if os.environ.get("DOC_STOP_RAISE") == "1":
                raise RuntimeError("erro real de stop no fake")
            return None

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

  test "trata CGNAT (100.64.0.1, RFC6598 nao-global) como bloqueado e preserva contra publico posterior" do
    # Achado A: _is_private_ip soh cobria is_private/loopback/link-local/etc.
    # 100.64.0.1 (CGNAT) NAO bate nenhum desses, entao o IP bloqueado seria
    # sobrescrito por um documento publico e o Ruby (que valida so o final)
    # nao bloqueava -> bypass SSRF. O script deve tratar nao-global como
    # bloqueado e preservar o IP ja capturado.
    dir, env = build_fake_env("DOC_IP_SEQUENCE" => "cgnat_first")
    stdout, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    assert status.success?, "script falhou com status #{status.exitstatus}: #{stderr}"
    json = JSON.parse(stdout)
    assert_equal "100.64.0.1", json["document_ip"],
      "CGNAT 100.64.0.1 (nao-global) deve ser preservado como bloqueado; se vazar 1.2.3.4 o Ruby nao bloqueia (SSRF)"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "ignora documento de subframe/iframe (frame_id diferente) e mantem o IP do frame principal" do
    # Achado B: o listener aceitava QUALQUER ResponseReceived do tipo DOCUMENT,
    # inclusive de iframes/subframes. Se o iframe viesse de IP privado, o
    # document_ip ficaria com o IP do subframe -> bloqueio falso no Ruby (a
    # validacao posterior acha que o documento principal veio de IP privado).
    # O script deve ignorar documentos que nao sejam do frame principal.
    dir, env = build_fake_env("DOC_IP_SEQUENCE" => "main_public_sub_private")
    stdout, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    assert status.success?, "script falhou com status #{status.exitstatus}: #{stderr}"
    json = JSON.parse(stdout)
    assert_equal "1.2.3.4", json["document_ip"],
      "iframe privado (10.0.0.1) NAO deve sobrescrever o IP do frame principal (1.2.3.4): vazaria bloqueio falso"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "CancelledError nao e engolido: o script aborta (exit != 0) em vez de sair como sucesso" do
    # Achado C: o codigo consumia asyncio.CancelledError e convertia em saida
    # normal (sleep do wait_for_content_ready). Isso rompe o cancelamento do
    # chamador (asyncio.run propaga cancelamento). O script deve relancar o
    # CancelledError para que a cancellacao seja honrada.
    dir, env = build_fake_env("DOC_RAISE_CANCELLED" => "1")
    _, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    refute status.success?, "CancelledError nao deve ser engolido; o processo deve abortar, nao sair com sucesso (stderr: #{stderr})"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "browser.stop() sincrono e de fato chamado (API real nodriver 0.50.3)" do
    # API real (verificado 13/08 no nodriver 0.50.3): Browser.stop é SÍNCRONO
    # (retorna None) — `await browser.stop()` levantaria TypeError e todo fetch
    # falharia. O script chama browser.stop() sem await; o sentinela só é
    # escrito quando o stop roda de verdade.
    sentinel = File.join(Dir.tmpdir, "nodriver_stop_sentinel_#{Process.pid}.txt")
    FileUtils.rm_f(sentinel)
    dir, env = build_fake_env("DOC_STOP_SENTINEL" => sentinel)
    _, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    assert status.success?, "script falhou com status #{status.exitstatus}: #{stderr}"
    assert File.exist?(sentinel), "browser.stop() não foi chamado: sentinela ausente"
    assert_equal "called", File.read(sentinel).strip
  ensure
    FileUtils.rm_f(sentinel) if sentinel
    FileUtils.remove_entry(dir) if dir
  end

  test "erro real em browser.stop() NAO e mascarado pelo except amplo da producao" do
    # Achado G (parte 2): o `finally` da producao envolve `await browser.stop()`
    # num `try/except Exception: pass` que engole QUALQUER erro de limpeza. Um
    # erro de stop de verdade (ex.: recurso nao liberado, leak de browser) deve
    # propagar, nao ser silenciado. O teste injeta um erro no stop do fake e
    # exige que o script aborte (exit != 0) com a mensagem visivel.
    dir, env = build_fake_env("DOC_STOP_RAISE" => "1")
    _, stderr, status = Open3.capture3(env, "python3", "-u", SCRIPT_PATH, "https://example.com/initial")

    refute status.success?, "erro em browser.stop() nao deve ser mascarado pelo except amplo (stderr: #{stderr})"
    assert_match(/erro real de stop no fake/, stderr, "a causa real do erro de stop deve aparecer no stderr")
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
