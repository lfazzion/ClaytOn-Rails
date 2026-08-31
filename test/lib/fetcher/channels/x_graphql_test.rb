# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_graphql"

# Stub local sem dependencia externa — substitui OpenStruct para Ruby 4.0
# Deve simular SafeHttpClient::Response (status, body, success?)
StubTx = Struct.new(:status, :body, keyword_init: true) do
  def success?
    status.to_i.between?(200, 299)
  end
end

class Fetcher::Channels::XGraphqlTest < ActiveSupport::TestCase
  FIXTURES_PATH = File.expand_path("../../../../test/fixtures/x", __dir__)

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES_PATH, "#{name}.json")))
  end

  # ---------------------------------------------------------------------------
  # Fase 1: Testes de contrato (RED inicial — module ainda não existe)
  # ---------------------------------------------------------------------------

  test "module Fetcher::Channels::XGraphql existe" do
    assert defined?(Fetcher::Channels::XGraphql)
  end

  test "XGraphql.expire_token! existe como metodo de classe" do
    assert_respond_to Fetcher::Channels::XGraphql, :expire_token!
  end

  test "XGraphql.fetch_search existe como metodo de classe" do
    assert_respond_to Fetcher::Channels::XGraphql, :fetch_search
  end

  test "XGraphql.search existe como metodo de classe" do
    assert_respond_to Fetcher::Channels::XGraphql, :search
  end

  # ---------------------------------------------------------------------------
  # Fase 2: Testes de validacao de sessao e configuracao
  # ---------------------------------------------------------------------------

  test "search sem sessao no jar levanta Expired nomeando x.com" do
    Fetcher::CookieJar.stubs(:valid?).returns(false)

    erro = assert_raises(Fetcher::CookieJar::Expired) do
      Fetcher::Channels::XGraphql.search(query: "ruby rails")
    end

    assert_equal "x.com", erro.domain
  end

  test 'search com sessao valida so passa se txid foi criado' do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Se o modulo existe e está implementado corretamente, deve chamar
    # BuildTxid antes de fazer qualquer requisicao HTTP
    mock_txid = Object.new
    def mock_txid.evidence_header(_now_ms)
      'mock-txid-header'
    end
    Fetcher::Channels::XGraphql::BuildTxid.expects(:new).returns(mock_txid)

    # SafeHttpClient sera chamado (ou falhara se WebMock bloquear)
    # A excecao deve conter 'request' para indicar que o fluxo avancou
    Fetcher::SafeHttpClient.expects(:get).raises(StandardError, 'request failed')

    error = assert_raises(StandardError) do
      Fetcher::Channels::XGraphql.search(query: 'ruby rails')
    end
    assert_match(/request/, error.message)
  end

  # ---------------------------------------------------------------------------
  # Fase 3: Testes do parser de pagina
  # ---------------------------------------------------------------------------

  test 'parser de pagina com resultados devolve array de hashes com chaves string' do
    pagina = fixture('search_timeline_page_1')

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(pagina)

    assert_kind_of Array, itens
    assert_equal 2, itens.size

    primeiro = itens.first
    assert_kind_of Hash, primeiro
    assert_equal %w[title url screen_name text created_at].sort, primeiro.keys.sort

    assert_includes primeiro['url'], 'x.com'
    assert_equal 'railsdev', primeiro['screen_name']
    assert_match /Ruby on Rails/, primeiro['text']
  end

  test "parser de pagina vazia legitima devolve array vazio sem erro" do
    pagina = fixture("search_timeline_empty")

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(pagina)

    assert_equal [], itens
  end

  test "parser descarta entries com TweetUnavailable (visibilidade)" do
    pagina = fixture("search_timeline_visibility_wrapper")

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(pagina)

    assert_kind_of Array, itens
    assert_equal 1, itens.size
    assert_equal "publicuser", itens.first["screen_name"]
  end

  test "parser com GraphQL error devolve array vazio (sem erro)" do
    pagina = fixture("search_timeline_graphql_error")

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(pagina)

    assert_equal [], itens
  end

  test "parser com schema desconhecido nao quebra" do
    unknown_schema = { "data" => { "algo_diferente" => {} } }

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(unknown_schema)

    assert_equal [], itens
  end

  # ---------------------------------------------------------------------------
  # Fase 4: Testes do BuildTxid (metodo puro testavel)
  # ---------------------------------------------------------------------------

  test "BuildTxid.evidence_header com tempo fixo retorna string base64 com tamanho esperado" do
    payload = {
      animation_key: "WebKit",
      verification: "V0lwcklQY2dFQUFCQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE="
    }
    now_ms = 1_725_145_200_000

    header = Fetcher::Channels::XGraphql::BuildTxid.evidence_header(payload, now_ms)

    assert_kind_of String, header
    # O header evidencia é base64 de ~99 chars (53 bytes verification + 4 seconds + 16 digest + 1 byte)
    assert_equal 99, header.length
  end

  test "evidence_header nunca vaza segredo em string" do
    payload = {
      animation_key: "WebKit",
      verification: "V0lwcklQY2dFQUFCQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE="
    }
    now_ms = 1_725_145_200_000

    header = Fetcher::Channels::XGraphql::BuildTxid.evidence_header(payload, now_ms)

    # Header eh base64; NAO deve conter os tokens originais
    refute_match(/auth_token/, header)
    refute_match(/ct0/, header)
  end

  # ---------------------------------------------------------------------------
  # Fase 5: Contrato de saida do PlatformSearchTool
  # ---------------------------------------------------------------------------

  test "search devolve Array de Hash com chaves STRING (contrato PlatformSearchTool)" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::SafeHttpClient.expects(:get).returns(
      StubTx.new(status: 200, body: fixture("search_timeline_page_1").to_json)
    )

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails", limit: 10)

    assert_kind_of Array, resultados
    resultados.each do |item|
      assert_kind_of Hash, item
      item.keys.each do |chave|
        assert_kind_of String, chave
      end
    end
  end

  test "busca com query vazia devolve lista vazia sem gastar requisicoes" do
    Fetcher::SafeHttpClient.expects(:get).never

    assert_equal [], Fetcher::Channels::XGraphql.search(query: "   ", limit: 10)
  end

  test "resultado tem chaves obrigatorias: title, url, screen_name" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    Fetcher::SafeHttpClient.expects(:get).returns(
      StubTx.new(status: 200, body: fixture("search_timeline_page_1").to_json)
    )

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails", limit: 10)

    assert_operator resultados.size, :>, 0
    resultados.each do |item|
      assert item.key?("title"), "item falta chave 'title'"
      assert item.key?("url"), "item falta chave 'url'"
      assert item.key?("screen_name"), "item falta chave 'screen_name'"
    end
  end

  test "deduplicacao de entradas repetidas baseada na URL" do
    # Simulacao: dois tweets com a mesma URL devem ser dedupados
    pagina = fixture("search_timeline_page_1")
    pagina.dig("data", "search_by_raw_query", "search_timeline", "timeline", "instructions", 0, "entries").append(
      pagina["data"]["search_by_raw_query"]["search_timeline"]["timeline"]["instructions"][0]["entries"][0].deep_dup
    )

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(pagina)
    urls = itens.map { |i| i["url"] }

    # Se houver duplicacao, deve haver apenas um item por URL unica
    assert_equal urls.uniq.size, itens.size, "ha duplicatas na lista de resultados"
  end
end
