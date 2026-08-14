# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

# Exercita `scripts/python/extract_pdf.py` em substituição direta (subprocesso),
# garantindo o contrato de saída:
#   - stdout: JSON sanitizado (uma linha, parseável)
#   - stderr: traceback com o tipo da exceção (via logger.exception)
#   - exit code 0 para erro de documento (não é falha de execução do script)
class ExtractPdfTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts/python/extract_pdf.py").to_s

  # Doubles do pypdf: o módulo `pypdf` embutido levanta uma exceção qualquer
  # durante o parse, simulando um PDF hostil ou defeito de regressão do pypdf.
  FAKE_PYPDF = <<~PYTHON
    class FakePdfError(Exception):
        pass

    class Page:
        def extract_text(self):
            return "texto"

    class PdfReader:
        def __init__(self, path):
            raise FakePdfError("simulação de defeito interno do pypdf")

        @property
        def pages(self):
            return [Page()]

    import sys
    sys.modules["pypdf"] = sys.modules[__name__]
  PYTHON

  def write_fake_pypdf(tmpdir)
    package = File.join(tmpdir, "pypdf")
    FileUtils.mkdir_p(package)
    File.write(File.join(package, "__init__.py"), FAKE_PYPDF)
  end

  def write_pdf(tmpdir, name, content)
    path = File.join(tmpdir, name)
    File.write(path, content)
    path
  end

  test "erro inesperado do parser emite JSON sanitizado no stdout, traceback no stderr e exit code zero" do
    Dir.mktmpdir do |dir|
      write_fake_pypdf(dir)
      pdf_path = write_pdf(dir, "corrupt.pdf", "%PDF-1.4 conteudo")

      stdout, stderr, status = Open3.capture3(
        {"PYTHONPATH" => dir},
        "python3", "-u", SCRIPT_PATH, pdf_path, "10", "1000"
      )

      # stdout: JSON válido e sanitizado (contrato com server.py)
      json = JSON.parse(stdout.strip)
      assert_equal "parse", json["error_kind"]
      assert_match(/erro ao ler PDF/i, json["error"])

      # stderr: traceback com o tipo da exceção — info necessária para
      # diagnosticar defeitos e regressões do pypdf
      assert_match(/FakePdfError/, stderr,
        "traceback no stderr deve conter o tipo da exceção ("\
        "logger.exception)")
      assert_match(/Traceback/, stderr,
        "stderr deve conter um traceback completo")

      # exit code zero: erro de documento não é falha de execução do script
      assert_equal 0, status.exitstatus,
        "erro de documento deve ter status contratual zero"
    end
  end
end
