# frozen_string_literal: true

require "test_helper"

class Fetcher::XComandoTest < ActiveSupport::TestCase
  test "sucesso imprime uma linha json e devolve 0" do
    saida = StringIO.new
    status = Fetcher::XComando.executa(saida) { { "id" => "1" } }
    assert_equal 0, status
    assert_equal "{\"id\":\"1\"}\n", saida.string
  end

  test "erro tipado imprime erro e tipo curto e devolve 1" do
    saida = StringIO.new
    status = Fetcher::XComando.executa(saida) { raise Fetcher::Channels::XEscrita::Restrito, "226" }
    assert_equal 1, status
    assert_equal({ "erro" => "226", "tipo" => "Restrito" }, JSON.parse(saida.string))
  end

  test "sessao expirada vira tipo Expired" do
    saida = StringIO.new
    Fetcher::XComando.executa(saida) { raise Fetcher::CookieJar::Expired, "x.com" }
    assert_equal "Expired", JSON.parse(saida.string)["tipo"]
  end

  test "texto do stdin chega intacto (aspas, quebra de linha, emoji)" do
    texto = "linha \"um\"\nlinha 2 🚀"
    assert_equal texto, Fetcher::XComando.le_texto("-", StringIO.new(texto + "\n"))
  end

  test "arquivo inexistente em le_texto vira tipo ENOENT" do
    saida = StringIO.new
    status = Fetcher::XComando.executa(saida) { Fetcher::XComando.le_texto("/nao/existe.txt") }
    assert_equal 1, status
    assert_equal "ENOENT", JSON.parse(saida.string)["tipo"]
  end
end
