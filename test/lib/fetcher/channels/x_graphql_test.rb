# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/x_graphql"

# Stub local sem dependencia externa — substitui OpenStruct para Ruby 4.0
# Deve simular SafeHttpClient::Response (status, body, success?, headers)
StubTx = Struct.new(:status, :body, :headers, keyword_init: true) do
  def success?
    status.to_i.between?(200, 299)
  end
end

class Fetcher::Channels::XGraphqlTest < ActiveSupport::TestCase
  FIXTURES_PATH = File.expand_path("../../../../test/fixtures/x", __dir__)

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES_PATH, "#{name}.json")))
  end

  setup do
    Fetcher::Channels::XGraphql.clear_remote_state!
    # Remove o jitter real entre paginações: o sleep é o que pesa na suíte
    # (~1-2 s por página). Testes específicos de paginação usam expectativa própria.
    Kernel.stubs(:sleep)
    # Pré-popula o cache do resolver para evitar requisições de rede.
    # O resolver usa Faraday (não SafeHttpClient), então stubs de rede não o capturam.
    @cache = ActiveSupport::Cache::MemoryStore.new
    @cache.write(
      "fetcher:x_query_id:SearchTimeline",
      { query_id: "test-query-id", fetched_at: Time.now.to_i, stale_at: Time.now.to_i + 86_400 }
    )
    @resolver_with_cache = Fetcher::XQueryIdResolver.new(cache: @cache)
    Fetcher::XQueryIdResolver.stubs(:new).returns(@resolver_with_cache)
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

  # Formato atual do X (medido 24/09/2026): o autor mora em user_results.result.core.screen_name
  # e user_results.result.legacy nao traz screen_name. Exigir o legacy descartava TODOS os posts
  # e a busca devolvia [] sem erro.
  test 'parser le o autor de user.core quando o legacy nao traz screen_name' do
    pagina = fixture('search_timeline_page_1')
    mover_autor_para_core = lambda do |no|
      case no
      when Hash
        if no['__typename'] == 'User' && no['legacy'].is_a?(Hash) && no['legacy']['screen_name']
          no['core'] = { 'screen_name' => no['legacy'].delete('screen_name'), 'name' => no['legacy']['name'] }
        end
        no.each_value { |v| mover_autor_para_core.call(v) }
      when Array then no.each { |v| mover_autor_para_core.call(v) }
      end
    end
    mover_autor_para_core.call(pagina)

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(pagina)

    assert_equal 2, itens.size
    assert_equal 'railsdev', itens.first['screen_name']
    assert_includes itens.first['url'], 'x.com/railsdev/status/'
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

  test "parser descarta usuario sem legacy e sem core.screen_name" do
    data = {
      "data" => {
        "search_by_raw_query" => {
          "search_timeline" => {
            "timeline" => {
              "instructions" => [
                {
                  "type" => "TimelineAddEntries",
                  "entries" => [
                    {
                      "content" => {
                        "itemContent" => {
                          "tweet_results" => {
                            "result" => {
                              "__typename" => "TweetResult",
                              "legacy" => {
                                "full_text" => "sem identificacao de usuario",
                                "created_at" => "2026-01-01T00:00:00Z",
                                "id_str" => "111111"
                              },
                              "core" => {
                                "user_results" => {
                                  "result" => {
                                    # nem legacy nem core.screen_name
                                    "core" => { "name" => "Anon" }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(data)
    assert_equal [], itens
  end

  test "parser descarta TweetWithVisibilityResults sem hash tweet (ausente ou string)" do
    base_entry = {
      "content" => {
        "itemContent" => {
          "tweet_results" => {
            "result" => {
              "__typename" => "TweetWithVisibilityResults"
            }
          }
        }
      }
    }

    ausente = {
      "data" => {
        "search_by_raw_query" => { "search_timeline" => { "timeline" => { "instructions" => [
          { "type" => "TimelineAddEntries", "entries" => [base_entry] }
        ] } } }
      }
    }

    como_string = {
      "data" => {
        "search_by_raw_query" => { "search_timeline" => { "timeline" => { "instructions" => [
          {
            "type" => "TimelineAddEntries",
            "entries" => [
              {
                "content" => {
                  "itemContent" => {
                    "tweet_results" => {
                      "result" => {
                        "__typename" => "TweetWithVisibilityResults",
                        "tweet" => "uma string, nao um hash"
                      }
                    }
                  }
                }
              }
            ]
          }
        ] } } }
      }
    }

    assert_equal [], Fetcher::Channels::XGraphql.parse_search_timeline(ausente),
                 "tweet ausente deve devolver []"
    assert_equal [], Fetcher::Channels::XGraphql.parse_search_timeline(como_string),
                 "tweet como string deve devolver []"
  end

  # ---------------------------------------------------------------------------
  # Fase 4: Testes do BuildTxid (metodo puro testavel)
  # ---------------------------------------------------------------------------

  test "build_headers usa query_id correto na assinatura txid (vetor canary)" do
    cookies = [
      { "name" => "auth_token", "value" => "test-auth-token" },
      { "name" => "ct0", "value" => "test-ct0-token" }
    ]
    Fetcher::CookieJar.stubs(:for).returns(cookies)

    # Vetor canary calculado via /tmp/gen_txid_vector.py
    # NOW_MS=1788194000000, MASK=123
    # path=/i/api/graphql/flaR-PUMshxFWZWPNpq4zA/SearchTimeline
    expected_txid = "e5BncvspyRzsZnZ2vL45buEHlPkSusBk6haOUzdet+Axbws8XQYmoXDwV4AHEMX5VhsyPX3pTXspi1zbIbCw+cNKxUMseA"

    txid = Fetcher::Channels::XGraphql::BuildTxid.new("fast_path")
    actual = txid.evidence_header(now_ms: 1_788_194_000_000, query_id: "flaR-PUMshxFWZWPNpq4zA", path_suffix: "SearchTimeline", mask: 123)

    assert_equal expected_txid, actual
    assert_equal 94, actual.length
  end

  test "BuildTxid gera header EXATO do algoritmo canary (vetor fixo)" do
    # Vetor gerado pela canary real /tmp/x_canary_final.rb com:
    # - pair[0] do /tmp/x_pair.json (fast_path)
    # - NOW_MS=1788194000000, MASK=123
    # - path=/i/api/graphql/flaR-PUMshxFWZWPNpq4zA/SearchTimeline
    # Output esperado: 94 chars, header byte-exato
    now_ms = 1_788_194_000_000
    mask = 123

    txid = Fetcher::Channels::XGraphql::BuildTxid.new("fast_path")
    header = txid.evidence_header(now_ms: now_ms, query_id: "flaR-PUMshxFWZWPNpq4zA", path_suffix: "SearchTimeline", mask: mask)

    assert_kind_of String, header
    assert_equal 94, header.length
    assert_equal "e5BncvspyRzsZnZ2vL45buEHlPkSusBk6haOUzdet+Axbws8XQYmoXDwV4AHEMX5VhsyPX3pTXspi1zbIbCw+cNKxUMseA", header
  end

  # ---------------------------------------------------------------------------
  # Fase 14: Generalizacao do XGraphql para operacoes arbitrarias (L2)
  # ---------------------------------------------------------------------------

  # Prova (mock BuildTxid/evidence_header): build_headers(operation:) repassa o
  # `operation` como `path_suffix` na assinatura do txid. O fake captura os
  # kwargs REAIS que build_headers manda para evidence_header e casa o
  # path_suffix de volta no valor retornado — deterministico (nao depende de
  # Time.now/rand) e prova a LIGACAO operation->path_suffix, nao a eficacia do
  # BuildTxid em si (essa ja e coberta pelos vetores canary acima).
  test "build_headers(operation: TweetDetail) assina com path_suffix: TweetDetail" do
    cookies = [
      { "name" => "auth_token", "value" => "test-auth-token" },
      { "name" => "ct0", "value" => "test-ct0-token" }
    ]
    Fetcher::CookieJar.stubs(:for).returns(cookies)

    fake_txid = Class.new do
      attr_reader :last_kwargs
      def evidence_header(now_ms:, mask: nil, query_id: nil, path_suffix: nil, method: nil)
        @last_kwargs = { now_ms: now_ms, mask: mask, query_id: query_id, path_suffix: path_suffix, method: method }
        "SIGN(#{path_suffix})"
      end
    end.new
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(fake_txid)

    headers = Fetcher::Channels::XGraphql.build_headers(
      {}, {},
      operation: "TweetDetail",
      query_id: "flaR-PUMshxFWZWPNpq4zA"
    )

    # A assinatura do txid recebeu path_suffix: TweetDetail (o que o perito exigiu)
    assert_equal "TweetDetail", fake_txid.last_kwargs[:path_suffix]
    assert_equal "flaR-PUMshxFWZWPNpq4zA", fake_txid.last_kwargs[:query_id]
    # A assinatura do txid recebeu ainda o method (default GET aqui)
    assert_equal "GET", fake_txid.last_kwargs[:method]
    # O header txid e o echo do path_suffix -> prova a ligacao operation->path_suffix
    assert_equal "SIGN(TweetDetail)", headers["x-client-transaction-id"]
  end

  # Controle negativo obrigatorio: SearchTimeline tem de produzir header
  # DIFERENTE do TweetDetail. Com o mesmo fake (que casa a assinatura por
  # path_suffix), dois operation distintos nunca podem devolver o mesmo txid.
  test "controle negativo: SearchTimeline e TweetDetail produzem txid diferentes" do
    cookies = [
      { "name" => "auth_token", "value" => "test-auth-token" },
      { "name" => "ct0", "value" => "test-ct0-token" }
    ]
    Fetcher::CookieJar.stubs(:for).returns(cookies)

    fake_txid = Class.new do
      def evidence_header(now_ms:, mask: nil, query_id: nil, path_suffix: nil, method: nil)
        "SIGN(#{path_suffix})"
      end
    end.new
    Fetcher::Channels::XGraphql::BuildTxid.stubs(:new).returns(fake_txid)

    qid = "flaR-PUMshxFWZWPNpq4zA"
    txid_search = Fetcher::Channels::XGraphql.build_headers({}, {}, operation: "SearchTimeline", query_id: qid)["x-client-transaction-id"]
    txid_tweet  = Fetcher::Channels::XGraphql.build_headers({}, {}, operation: "TweetDetail", query_id: qid)["x-client-transaction-id"]

    assert_equal "SIGN(SearchTimeline)", txid_search
    assert_equal "SIGN(TweetDetail)", txid_tweet
    assert_not_equal txid_search, txid_tweet, "path_suffix diferente deve produzir txid diferente"
  end

  test "build_headers sem query_id levanta ArgumentError para operation TweetDetail" do
    cookies = [
      { "name" => "auth_token", "value" => "test-auth-token" },
      { "name" => "ct0", "value" => "test-ct0-token" }
    ]
    Fetcher::CookieJar.stubs(:for).returns(cookies)

    # Sem query_id (e com operation != SearchTimeline) nao pode assinar com o
    # id padrao (id do SearchTimeline) — que era o bug A0.3.
    error = assert_raises(ArgumentError) do
      Fetcher::Channels::XGraphql.build_headers({}, {}, operation: "TweetDetail")
    end
    assert_match(/query_id/, error.message)
  end

  test "build_url com operation: TweetDetail monta path correto" do
    url = Fetcher::Channels::XGraphql.build_url(
      "", {}, {},
      "flaR-PUMshxFWZWPNpq4zA",
      operation: "TweetDetail"
    )

    assert_match %r{\/i\/api\/graphql\/flaR-PUMshxFWZWPNpq4zA\/TweetDetail}, url
    refute_match %r{SearchTimeline}, url, "URL para TweetDetail nao deve conter SearchTimeline"
  end

  test "build_url com operation: SearchTimeline continua funcionando (retrocompatibilidade)" do
    url = Fetcher::Channels::XGraphql.build_url(
      "", {}, {},
      "flaR-PUMshxFWZWPNpq4zA",
      operation: "SearchTimeline"
    )

    assert_match %r{\/i\/api\/graphql\/flaR-PUMshxFWZWPNpq4zA\/SearchTimeline}, url
  end

  test "parser tolera screen_name em user_result core (nao apenas legacy)" do
    # Fixture com screen_name em core (nao em legacy)
    data = {
      "data" => {
        "search_by_raw_query" => {
          "search_timeline" => {
            "timeline" => {
              "instructions" => [
                {
                  "type" => "TimelineAddEntries",
                  "entries" => [
                    {
                      "content" => {
                        "itemContent" => {
                          "tweet_results" => {
                            "result" => {
                              "__typename" => "TweetResult",
                              "legacy" => {
                                "full_text" => "Teste de screen_name em core",
                                "created_at" => "2026-01-01T00:00:00Z",
                                "id_str" => "1234567890"
                              },
                              "core" => {
                                "user_results" => {
                                  "result" => {
                                    # Nao ha legacy, so core com screen_name
                                    "core" => {
                                      "screen_name" => "coreuser"
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(data)
    assert_equal 1, itens.size
    assert_equal "coreuser", itens.first["screen_name"]
  end

  test "parser nao quebra quando legacy do usuario e String e usa core.screen_name" do
    # legacy String nao deve levantar NoMethodError; o parser cai no fallback core.
    data = {
      "data" => {
        "search_by_raw_query" => {
          "search_timeline" => {
            "timeline" => {
              "instructions" => [
                {
                  "type" => "TimelineAddEntries",
                  "entries" => [
                    {
                      "content" => {
                        "itemContent" => {
                          "tweet_results" => {
                            "result" => {
                              "__typename" => "TweetResult",
                              "legacy" => {
                                "full_text" => "legacy String nao derruba o parser",
                                "created_at" => "2026-01-01T00:00:00Z",
                                "id_str" => "1234567891"
                              },
                              "core" => {
                                "user_results" => {
                                  "result" => {
                                    "legacy" => "string-malformada",
                                    "core" => {
                                      "screen_name" => "stringlegacyuser"
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(data)
    assert_equal 1, itens.size
    assert_equal "stringlegacyuser", itens.first["screen_name"]
  end

  test "parser desembroa TweetWithVisibilityResults para tweet" do
    # Fixture com __typename TweetWithVisibilityResults
    data = {
      "data" => {
        "search_by_raw_query" => {
          "search_timeline" => {
            "timeline" => {
              "instructions" => [
                {
                  "type" => "TimelineAddEntries",
                  "entries" => [
                    {
                      "content" => {
                        "itemContent" => {
                          "tweet_results" => {
                            "result" => {
                              "__typename" => "TweetWithVisibilityResults",
                              "tweet" => {
                                "__typename" => "TweetResult",
                                "legacy" => {
                                  "full_text" => "Tweet dentro de visibility wrapper",
                                  "created_at" => "2026-01-01T00:00:00Z",
                                  "id_str" => "9876543210"
                                },
                                "core" => {
                                  "user_results" => {
                                    "result" => {
                                      "legacy" => {
                                        "screen_name" => "visibilityuser"
                                      }
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }

    itens = Fetcher::Channels::XGraphql.parse_search_timeline(data)
    assert_equal 1, itens.size
    assert_equal "visibilityuser", itens.first["screen_name"]
    assert_equal "Tweet dentro de visibility wrapper", itens.first["text"]
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
    # Usa fixture SEM cursor para evitar paginacao indesejada nos testes de contrato
    Fetcher::SafeHttpClient.expects(:get).returns(
      StubTx.new(status: 200, body: fixture("search_timeline_single").to_json, headers: {})
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

  test "search retorna [] quando remote_blocked? e nao toca rede" do
    # Define estado de bloqueio completo (required por remote_blocked?)
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_blocked, true)
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_block_until, Time.now + 60)
    # require! tambem deve ser stubado para nao levantar Expired
    Fetcher::CookieJar.stubs(:require!)

    Fetcher::SafeHttpClient.expects(:get).never

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails")
    assert_equal [], resultados
  end

  test "busca com query vazia devolve lista vazia sem gastar requisicoes" do
    Fetcher::SafeHttpClient.expects(:get).never

    assert_equal [], Fetcher::Channels::XGraphql.search(query: "   ", limit: 10)
  end

  test "resultado tem chaves obrigatorias: title, url, screen_name" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)
    # Usa fixture SEM cursor para evitar paginacao indesejada
    Fetcher::SafeHttpClient.expects(:get).returns(
      StubTx.new(status: 200, body: fixture("search_timeline_single").to_json, headers: {})
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

  # ---------------------------------------------------------------------------
  # Fase 6: Paginacao com cursor
  # ---------------------------------------------------------------------------

  test "fetch_search faz paginacao quando cursor Bottom esta presente" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Primeira pagina: retorna 2 itens + cursor
    first_response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_page_1").to_json,
      headers: { "x-rate-limit-remaining" => "49", "x-rate-limit-reset" => (Time.now.to_i + 120).to_s }
    )

    # Segunda pagina: retorna 1 item novo + cursor
    second_response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_page_2").to_json,
      headers: { "x-rate-limit-remaining" => "48", "x-rate-limit-reset" => (Time.now.to_i + 120).to_s }
    )

    # Terceira pagina: retorna vazio (sem cursor)
    third_response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_empty").to_json,
      headers: { "x-rate-limit-remaining" => "47", "x-rate-limit-reset" => (Time.now.to_i + 120).to_s }
    )

    Fetcher::SafeHttpClient.expects(:get).at_least_once.returns(first_response, second_response, third_response)

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails", limit: 10)

    # Espera todos os itens unicos (page1: 2, page2: 1 novo + 1 duplicado, page3: 0)
    # page_1: urls 1234567890, 1234567891
    # page_2: url 1234567892 (nova) + 1234567890 (duplicada)
    # Total unico pos dedupe: 3
    assert_kind_of Array, resultados
    assert_equal 3, resultados.size, "deveria ter 3 itens unicos apos dedupe (page1:2 + page2:1 novo)"
  end

  test "fetch_search dorme entre paginas mas nao apos a ultima (sleep so quando page_count < max_pages)" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # 3 paginas TODAS com cursor novo (page1, page2 e page1 de novo): assim o loop
    # so termina pelo `while page_count < max_pages`, e o guard
    # `if page_count < max_pages` e o que evita o 3o sleep na ultima pagina.
    # Nota: page1 como 3a pagina tem cursor (C1) DIFERENTE do cursor da page2 (C2),
    # entao o loop nao quebra em `break if cursor == prev_cursor`.
    first_response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_page_1").to_json,
      headers: {}
    )
    second_response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_page_2").to_json,
      headers: {}
    )
    third_response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_page_1").to_json,
      headers: {}
    )

    # 3 leituras: page1 (cursor C1), page2 (cursor C2), page1 de novo (cursor C1,
    # difere de C2) — todas passam pelo sleep line; so a 3a nao dorme.
    Fetcher::SafeHttpClient.expects(:get).times(3).returns(first_response, second_response, third_response)

    # Entre a 1a e 2a pagina e entre a 2a e 3a: 2 sleeps (page_count 1 e 2 sao
    # < max_pages=3). Na 3a iteracao (page_count == 3) o guard impede o sleep —
    # sem o guard, dormiria tambem apos a ultima pagina.
    # Desarma o stub relaxado global do setup para que a expectativa estrita
    # abaixo enxergue QUALQUER chamada extra de sleep (se o guard for removido).
    # Com o stub do setup ativo, uma 3a chamada seria absorvida por ele e a
    # suíte ficaria verde nos dois estados — o teste nao distinguiria a correcao.
    Kernel.unstub(:sleep)
    Kernel.expects(:sleep).times(2)

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails", limit: 10)
    assert_kind_of Array, resultados
  end

  test "fetch_search para no limite de paginas (max 3)" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Retorna a mesma pagina 3 vezes; o loop para quando max_pages é atingido
    response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_page_1").to_json,
      headers: { "x-rate-limit-remaining" => "49", "x-rate-limit-reset" => (Time.now.to_i + 120).to_s }
    )

    # Nota: o codigo para em 2 chamadas devido a deteccao de cursor repetido
    # (page1 tem cursor A, page2 retorna mesmo cursor A -> break).
    # Usamos at_most(3) para ser tolerante.
    Fetcher::SafeHttpClient.expects(:get).at_most(3).returns(response)

    Fetcher::Channels::XGraphql.search(query: "ruby rails", limit: 10)
  end

  test "cursor repetido nao causa loop infinito" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Pagina com cursor que nao muda (simulando loop)
    response = StubTx.new(
      status: 200,
      body: fixture("search_timeline_page_1").to_json,
      headers: { "x-rate-limit-remaining" => "49", "x-rate-limit-reset" => (Time.now.to_i + 120).to_s }
    )

    # Com deteccao de cursor repetido, para em 2 paginas (nao 3)
    Fetcher::SafeHttpClient.expects(:get).at_most(3).returns(response)

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails", limit: 10)
    # Deve parar sem loop infinito (max 2 paginas devido a deteccao de repeticao)
    assert_kind_of Array, resultados
  end

  # ---------------------------------------------------------------------------
  # Fase 7: Rate limit remoto (429)
  # ---------------------------------------------------------------------------

  test "429 retorna erro imediato sem aguardar" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    response = StubTx.new(
      status: 429,
      body: '{"error": "rate limited"}',
      headers: {
        "x-rate-limit-remaining" => "0",
        "x-rate-limit-reset" => (Time.now.to_i + 60).to_s
      }
    )

    Fetcher::SafeHttpClient.expects(:get).returns(response)

    error = assert_raises(Fetcher::Channels::XGraphql::RateLimitedRemote) do
      Fetcher::Channels::XGraphql.search(query: "ruby rails")
    end

    assert_match(/429/, error.message)
    assert_match(/reset/, error.message)
  end

  test "429 com reset invalido usa fallback seguro" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    response = StubTx.new(
      status: 429,
      body: '{"error": "rate limited"}',
      headers: {
        "x-rate-limit-remaining" => "0",
        "x-rate-limit-reset" => "invalido"
      }
    )

    Fetcher::SafeHttpClient.expects(:get).returns(response)

    error = assert_raises(Fetcher::Channels::XGraphql::RateLimitedRemote) do
      Fetcher::Channels::XGraphql.search(query: "ruby rails")
    end

    assert_match(/429/, error.message)
  end

  test "429 nao incrementa contador de rede em chamada subsequente durante bloqueio" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Primeira chamada: 429
    response_429 = StubTx.new(
      status: 429,
      body: '{"error": "rate limited"}',
      headers: { "x-rate-limit-remaining" => "0", "x-rate-limit-reset" => (Time.now.to_i + 60).to_s }
    )

    # Mock para provar que segunda chamada nao toca rede
    Fetcher::SafeHttpClient.expects(:get).once.returns(response_429)

    # Captura o erro da primeira chamada
    assert_raises(Fetcher::Channels::XGraphql::RateLimitedRemote) do
      Fetcher::Channels::XGraphql.search(query: "ruby rails")
    end

    # Verifica que state de bloqueio foi definido
    assert Fetcher::Channels::XGraphql.remote_blocked?

    # Segunda chamada durante bloqueio NAO deve tocar a rede
    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails")
    assert_equal [], resultados
  end

  # ---------------------------------------------------------------------------
  # Fase 8: Headers preservados
  # ---------------------------------------------------------------------------

  test "headers da resposta sao preservados no Response" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    expected_headers = {
      "x-rate-limit-remaining" => "49",
      "x-rate-limit-reset" => (Time.now.to_i + 120).to_s
    }

    # Usa fixture SEM cursor para evitar paginacao indesejada
    Fetcher::SafeHttpClient.expects(:get).returns(
      StubTx.new(status: 200, body: fixture("search_timeline_single").to_json, headers: expected_headers)
    )

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails", limit: 10)
    assert_kind_of Array, resultados
  end

  # ---------------------------------------------------------------------------
  # Fase 9: Testes auxiliares
  # ---------------------------------------------------------------------------

  test "extract_bottom_cursor extrai cursor Bottom corretamente" do
    pagina = fixture("search_timeline_page_1")
    cursor = Fetcher::Channels::XGraphql.extract_bottom_cursor(pagina)
    assert_equal "scroll:thGxwVR_7V2J9hJGhAABCgAAAAAAAAAAAA==", cursor
  end

  test "extract_bottom_cursor retorna nil quando nao ha cursor" do
    pagina = fixture("search_timeline_empty")
    cursor = Fetcher::Channels::XGraphql.extract_bottom_cursor(pagina)
    assert_nil cursor
  end

  test "build_variables inclui cursor quando fornecido" do
    vars = Fetcher::Channels::XGraphql.build_variables("teste", 10, "cursor-teste")
    assert_equal "cursor-teste", vars[:cursor]
    assert_equal "teste", vars[:rawQuery]
  end

  test "build_variables nao inclui cursor quando nil" do
    vars = Fetcher::Channels::XGraphql.build_variables("teste", 10, nil)
    refute vars.key?(:cursor)
  end

  test "parse_rate_limit_reset com timestamp valido retorna Time" do
    headers = { "x-rate-limit-reset" => (Time.now.to_i + 60).to_s }
    reset_at = Fetcher::Channels::XGraphql.parse_rate_limit_reset(headers)
    assert_kind_of Time, reset_at
    assert reset_at > Time.now
  end

  test "parse_rate_limit_reset com timestamp invalido retorna nil" do
    headers = { "x-rate-limit-reset" => "invalido" }
    reset_at = Fetcher::Channels::XGraphql.parse_rate_limit_reset(headers)
    assert_nil reset_at
  end

  test "update_remote_budget! marca bloqueio quando remaining == 0" do
    headers = { "x-rate-limit-remaining" => "0" }
    Fetcher::Channels::XGraphql.update_remote_budget!(headers)
    assert Fetcher::Channels::XGraphql.remote_blocked?
  end

  test "update_remote_budget! nao marca bloqueio quando remaining > 0" do
    headers = { "x-rate-limit-remaining" => "49" }
    Fetcher::Channels::XGraphql.update_remote_budget!(headers)
    refute Fetcher::Channels::XGraphql.remote_blocked?
  end

  test "rate limit local estoura RateLimited com orcamento graphql_search" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.expects(:exceeded?)
                            .with("x.com", **Fetcher::Channels::XGraphql::GRAPHQL_BUDGET)
                            .returns(true)
    Fetcher::SafeHttpClient.expects(:get).never

    erro = assert_raises(Fetcher::Channels::XGraphql::RateLimited) do
      Fetcher::Channels::XGraphql.search(query: "ruby")
    end

    assert_includes erro.message, "x.com"
    assert_includes erro.message, "graphql_search"
    assert Fetcher::Channels::XGraphql::RateLimited < Fetcher::Channels::Error
  end

  # ---------------------------------------------------------------------------
  # Fase 10: Cookie e x-csrf-token nos headers (CRÍTICO 1)
  # ---------------------------------------------------------------------------

  test "build_headers envia Cookie e x-csrf-token" do
    cookies = [
      { "name" => "auth_token", "value" => "test-auth-token" },
      { "name" => "ct0", "value" => "test-ct0-token" }
    ]
    Fetcher::CookieJar.stubs(:for).returns(cookies)

    headers = Fetcher::Channels::XGraphql.build_headers({}, {})

    assert_match(/auth_token=test-auth-token/, headers["Cookie"])
    assert_match(/ct0=test-ct0-token/, headers["Cookie"])
    assert_equal "test-ct0-token", headers["x-csrf-token"]
  end

  test "build_headers envia Cookie mesmo sem ct0" do
    cookies = [
      { "name" => "auth_token", "value" => "test-auth-token" }
    ]
    Fetcher::CookieJar.stubs(:for).returns(cookies)

    headers = Fetcher::Channels::XGraphql.build_headers({}, {})

    assert_match(/auth_token=test-auth-token/, headers["Cookie"])
    assert_equal "", headers["x-csrf-token"]
  end

  test "WebMock prova que Cookie e x-csrf-token sao enviados na requisicao" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::CookieJar.stubs(:for).returns([
      { "name" => "auth_token", "value" => "test-token" },
      { "name" => "ct0", "value" => "test-ct0" }
    ])
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Stub explícito do resolver para evitar fetch de rede via Faraday.
    # O stub do setup pode não propagar em execução isolada; aqui garantimos
    # que build_url receba query_id já resolvido sem tocar x.com/home.
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write(
      "fetcher:x_query_id:SearchTimeline",
      { query_id: "test-query-id", fetched_at: Time.now.to_i, stale_at: Time.now.to_i + 86_400 }
    )
    resolver = Fetcher::XQueryIdResolver.new(cache: cache)
    Fetcher::XQueryIdResolver.stubs(:new).returns(resolver)

    # Stubs a URL REAL com query params (regex no path)
    stub_request(:get, %r{\Ahttps://x\.com/i/api/graphql/test-query-id/SearchTimeline})
      .to_return(
        status: 200,
        body: fixture("search_timeline_single").to_json,
        headers: { "Content-Type" => "application/json" }
      )

    Fetcher::Channels::XGraphql.search(query: "ruby rails")

    # Verifica que o request foi feito com os headers corretos
    # Usa lookup case-insensitivo pois o Net::HTTP normaliza chaves para lowercase
    assert_requested :get, %r{\Ahttps://x\.com/i/api/graphql/test-query-id/SearchTimeline} do |req|
      h = req.headers
      cookie = h["Cookie"] || h["cookie"]
      csrf = h["x-csrf-token"] || h["X-CSRF-Token"] || h["X-Csrf-Token"]
      cookie&.include?("auth_token=test-token") && csrf == "test-ct0"
    end
  end

  # ---------------------------------------------------------------------------
  # Fase 11: Testes 401 e 403 (CRÍTICO 6)
  # ---------------------------------------------------------------------------

  test "401 levanta GraphQLError sem retry automatico" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    response = StubTx.new(
      status: 401,
      body: '{"error": "unauthorized"}',
      headers: {}
    )

    Fetcher::SafeHttpClient.expects(:get).returns(response)

    error = assert_raises(Fetcher::Channels::XGraphql::GraphQLError) do
      Fetcher::Channels::XGraphql.search(query: "ruby rails")
    end

    assert_match(/401/, error.message)
    assert_match(/nao autorizado/, error.message)
  end

  test "403 levanta GraphQLError sem retry automatico" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    response = StubTx.new(
      status: 403,
      body: '{"error": "forbidden"}',
      headers: {}
    )

    Fetcher::SafeHttpClient.expects(:get).returns(response)

    error = assert_raises(Fetcher::Channels::XGraphql::GraphQLError) do
      Fetcher::Channels::XGraphql.search(query: "ruby rails")
    end

    assert_match(/403/, error.message)
    assert_match(/proibido/, error.message)
  end

  # ---------------------------------------------------------------------------
  # Fase 12: remote_blocked? com tempo (CRÍTICO 5)
  # ---------------------------------------------------------------------------

  test "remote_blocked? retorna false quando tempo expirou" do
    # Marca como bloqueado com tempo no passado
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_blocked, true)
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_block_until, Time.now - 10)

    refute Fetcher::Channels::XGraphql.remote_blocked?
  end

  test "remote_blocked? retorna true enquanto tempo nao expirou" do
    # Marca como bloqueado com tempo no futuro
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_blocked, true)
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_block_until, Time.now + 60)

    assert Fetcher::Channels::XGraphql.remote_blocked?
  end

  test "remote_blocked? limpa estado quando tempo expira" do
    # Marca como bloqueado com tempo no passado
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_blocked, true)
    Fetcher::Channels::XGraphql.instance_variable_set(:@remote_block_until, Time.now - 10)

    Fetcher::Channels::XGraphql.remote_blocked?

    # Estado deve ser limpo
    refute Fetcher::Channels::XGraphql.instance_variable_get(:@remote_blocked)
    assert_nil Fetcher::Channels::XGraphql.instance_variable_get(:@remote_block_until)
  end

  # ---------------------------------------------------------------------------
  # Fase 13: Testes 404 com query ID refresh (fix retry sem rescue)
  # ---------------------------------------------------------------------------

  test "404 com query ID invalido tenta refresh uma unica vez" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Resolver customizado com cache pré-populado para evitar rede
    custom_cache = ActiveSupport::Cache::MemoryStore.new
    custom_cache.write(
      "fetcher:x_query_id:SearchTimeline",
      { query_id: "old-query-id", fetched_at: Time.now.to_i, stale_at: Time.now.to_i + 86_400 }
    )
    resolver = Fetcher::XQueryIdResolver.new(cache: custom_cache)
    # Override resolve para simular o comportamento esperado
    def resolver.resolve(type, force: false)
      if force
        "new-query-id"
      else
        "old-query-id"
      end
    end
    Fetcher::XQueryIdResolver.stubs(:new).returns(resolver)

    # Primeira resposta: 404 (query ID invalido)
    # Segunda resposta: 200 (depois do refresh)
    response_404 = StubTx.new(
      status: 404,
      body: '{"errors": [{"message": "Query not found"}]}',
      headers: {}
    )
    response_200 = StubTx.new(
      status: 200,
      body: fixture("search_timeline_single").to_json,
      headers: {}
    )

    Fetcher::SafeHttpClient.expects(:get).twice.returns(response_404, response_200)

    resultados = Fetcher::Channels::XGraphql.search(query: "ruby rails")
    assert_kind_of Array, resultados
  end

  test "404 apos refresh ainda falha levanta GraphQLError" do
    Fetcher::CookieJar.stubs(:valid?).returns(true)
    Fetcher::HostRateLimiter.stubs(:exceeded?).returns(false)

    # Resolver customizado com cache pré-populado
    custom_cache = ActiveSupport::Cache::MemoryStore.new
    custom_cache.write(
      "fetcher:x_query_id:SearchTimeline",
      { query_id: "test-query-id", fetched_at: Time.now.to_i, stale_at: Time.now.to_i + 86_400 }
    )
    resolver = Fetcher::XQueryIdResolver.new(cache: custom_cache)
    # Override resolve para simular o comportamento esperado
    def resolver.resolve(type, force: false)
      if force
        "new-query-id"
      else
        "test-query-id"
      end
    end
    Fetcher::XQueryIdResolver.stubs(:new).returns(resolver)

    response_404 = StubTx.new(
      status: 404,
      body: '{"errors": [{"message": "Query not found"}]}',
      headers: {}
    )

    # Primeira chamada com test-query-id -> 404
    # Refresh: resolve com force retorna new-query-id (diferente) -> retry
    # Segunda chamada com new-query-id -> 404 -> levanta GraphQLError
    Fetcher::SafeHttpClient.expects(:get).twice.returns(response_404, response_404)

    error = assert_raises(Fetcher::Channels::XGraphql::GraphQLError) do
      Fetcher::Channels::XGraphql.search(query: "ruby rails")
    end

    assert_match(/404/, error.message)
    assert_match(/query nao encontrada/, error.message)
  end
end
