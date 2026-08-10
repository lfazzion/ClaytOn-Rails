# frozen_string_literal: true

require "test_helper"
require "json"
require "net/http"
require "uri"
require "socket"
require "tmpdir"
require "fileutils"

# Exercita a rota POST /extract-pdf do `scripts/python/server.py` DE VERDADE em subprocesso.
class ServerExtractPdfTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts/python/server.py").to_s
  TEST_TOKEN = "pdf_test_token_999"

  FAKE_PYPDF = <<~PYTHON
    class Page:
        def __init__(self, text):
            self._text = text
        def extract_text(self):
            return self._text

    class PdfReader:
        def __init__(self, path):
            with open(path, 'rb') as f:
                content = f.read()

            if b"CORRUPT" in content:
                raise ValueError("PDF corrupto de teste")

            text = "Texto extraido do PDF de teste"
            if b"PAGES=" in content:
                num = int(content.split(b"PAGES=")[1].split()[0])
                self.pages = [Page(f"Pagina {i+1}") for i in range(num)]
            else:
                self.pages = [Page(text)]
  PYTHON

  def find_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def with_server
    port = find_free_port
    Dir.mktmpdir do |dir|
      package = File.join(dir, "pypdf")
      FileUtils.mkdir_p(package)
      File.write(File.join(package, "__init__.py"), FAKE_PYPDF)

      env = {
        "PYTHONPATH" => dir,
        "PYTHON_SCRAPER_TOKEN" => TEST_TOKEN,
        "SCRAPER_PORT" => port.to_s,
        "SCRAPER_BIND" => "127.0.0.1"
      }

      # out:/err: :close FECHA os fds do filho: o server.py escreve o banner de
      # boot ("[scraper-api] escutando...") no stderr logo ao subir e, com fd
      # fechado, o sys.stderr.write levanta EBADF e o processo morre antes do
      # serve_forever — "servidor não subiu na porta X" em todos os testes.
      # File::NULL mantém os fds abertos apontando para /dev/null (descarta sem
      # matar o boot).
      pid = Process.spawn(env, "python3", "-u", SCRIPT_PATH, out: File::NULL, err: File::NULL)

      # Aguarda o servidor subir (healthcheck)
      uri = URI("http://127.0.0.1:#{port}/health")
      up = false
      10.times do
        sleep 0.1
        res = Net::HTTP.get_response(uri) rescue nil
        if res&.is_a?(Net::HTTPSuccess)
          up = true
          break
        end
      end

      flunk("Servidor server.py não subiu na porta #{port}") unless up

      begin
        yield "http://127.0.0.1:#{port}"
      ensure
        Process.kill("KILL", pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end

  test "POST /extract-pdf extrai texto com sucesso de um PDF valido" do
    with_server do |base_url|
      uri = URI("#{base_url}/extract-pdf")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{TEST_TOKEN}"
      req["Content-Type"] = "application/pdf"
      req.body = "%PDF-1.4\nConteudo do arquivo PDF"

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }

      assert_equal "200", res.code
      json = JSON.parse(res.body)
      assert_equal "Texto extraido do PDF de teste", json["text"]
      assert_equal 1, json["pages"]
      assert_equal false, json["truncated"]
    end
  end

  test "POST /extract-pdf sem token devolve 401 token invalido" do
    with_server do |base_url|
      uri = URI("#{base_url}/extract-pdf")
      req = Net::HTTP::Post.new(uri)
      req.body = "%PDF-1.4\nConteudo"

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }

      assert_equal "401", res.code
      json = JSON.parse(res.body)
      assert_equal "token inválido", json["error"]
    end
  end

  test "POST /extract-pdf com corpo acima de 10MB devolve 413" do
    with_server do |base_url|
      uri = URI("#{base_url}/extract-pdf")
      req = Net::HTTP::Post.new(uri)
      # Raw socket de propósito: com Net::HTTP o Content-Length manual é
      # recalculado (com body → vira o tamanho real; sem body → some), então o
      # servidor nunca veria o length inflado. Aqui a request é escrita na mão:
      # o servidor lê o Content-Length > MAX_PDF_BYTES na read_pdf_body e
      # responde 413 antes de ler o corpo — sem race nem 10MB transferidos.
      socket = TCPSocket.new(URI(base_url).hostname, URI(base_url).port)
      request = "POST /extract-pdf HTTP/1.1\r\n" \
                "Host: 127.0.0.1\r\n" \
                "Authorization: Bearer #{TEST_TOKEN}\r\n" \
                "Content-Type: application/pdf\r\n" \
                "Content-Length: #{10_485_760 + 100}\r\n" \
                "Connection: close\r\n" \
                "\r\n%PDF-1.4\nconteudo"
      socket.write(request)
      socket.close_write
      response = socket.read
      socket.close

      assert_includes response, "413"
      assert_match(/corpo excede/i, response)
    end
  end

  test "POST /extract-pdf com PDF corrupto devolve 200 com mensagem de erro" do
    with_server do |base_url|
      uri = URI("#{base_url}/extract-pdf")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{TEST_TOKEN}"
      req.body = "%PDF-1.4 CORRUPT"

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }

      assert_equal "200", res.code
      json = JSON.parse(res.body)
      assert_match(/erro ao ler PDF/i, json["error"])
    end
  end

  test "POST /extract-pdf com bytes que nao iniciam com %PDF- devolve 200 com erro de validacao" do
    with_server do |base_url|
      uri = URI("#{base_url}/extract-pdf")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{TEST_TOKEN}"
      req.body = "Este nao e um PDF"

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }

      assert_equal "200", res.code
      json = JSON.parse(res.body)
      assert_equal "arquivo não é um PDF válido", json["error"]
    end
  end

  # C1 (revisão Opus, B3): o corte por PÁGINAS (acima de MAX_PDF_PAGES) tem que
  # marcar truncated:true — antes o campo só acendia por estouro de CHARACTERES,
  # e o consumidor respondia com confiança sobre um documento lido pela metade.
  test "POST /extract-pdf com mais paginas que o teto marca truncated (B3/C1)" do
    with_server do |base_url|
      uri = URI("#{base_url}/extract-pdf")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{TEST_TOKEN}"
      req["Content-Type"] = "application/pdf"
      # FAKE_PYPDF (dublê) interpreta "PAGES=<N>" no corpo e gera N páginas.
      req.body = "%PDF-1.4\nPAGES=400\nConteudo"

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }

      assert_equal "200", res.code
      json = JSON.parse(res.body)
      assert_equal 400, json["pages"]
      assert_equal true, json["truncated"]
    end
  end
end
