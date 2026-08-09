# frozen_string_literal: true

require "test_helper"
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/page_fetch_tools"

class PageFetchToolTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    ENV["ENABLE_PAGE_FETCH"] = "true"
  end

  teardown do
    ENV["ENABLE_PAGE_FETCH"] = nil
  end

  # A tool fala com o `ExtractService`, o orquestrador, e não com o `PageFetcher`
  # por baixo dele. Era essa camada furada que deixava o chatbot sem os canais:
  # vídeo do YouTube, thread do Reddit, post do X e feed voltavam como casca da
  # página, enquanto o reader do Hermes — que passa pelo endpoint — recebia o
  # conteúdo de verdade.
  def stub_extract(overrides = {})
    payload = {
      requested_url: "https://example.com/doc", url: "https://example.com/doc",
      title: "Ferramentas Cleitin", content: "Conteúdo extraído da página",
      raw_content: nil, engine: "static", rendered: false, metadata: {}, error: nil
    }.merge(overrides)
    Fetcher::ExtractService.stubs(:call).returns(payload)
    payload
  end

  test "retorna success quando a extracao da certo" do
    stub_extract
    result = PageFetchTool.new.execute(url: "https://example.com/doc")

    assert_equal :success, result[:status]
    assert_includes result[:data][:content], "extraído"
    assert_equal "https://example.com/doc", result[:data][:url]
  end

  test "url vazia retorna error" do
    result = PageFetchTool.new.execute(url: "  ")
    assert_equal :error, result[:status]
    assert_match(/vazia/i, result[:reason])
  end

  test "feature flag desligada retorna error" do
    ENV["ENABLE_PAGE_FETCH"] = "false"
    result = PageFetchTool.new.execute(url: "https://example.com/")
    assert_equal :error, result[:status]
    assert_match(/desabilit/i, result[:reason])
  end

  test "ENABLE_PAGE_FETCH ausente é tratado como desligada" do
    ENV.delete("ENABLE_PAGE_FETCH")
    result = PageFetchTool.new.execute(url: "https://example.com/")
    assert_equal :error, result[:status]
  end

  # O teto acompanha o MAX_MAX_CHARS do ExtractService. Os 8k anteriores eram
  # teto de pagina web e cortavam transcricao de video pela metade.
  test "limit_chars é clampado no teto do ExtractService e repassado como max_chars" do
    Fetcher::ExtractService.expects(:call).with("https://example.com/", max_chars: 50_000).returns(
      { url: "https://example.com/", title: "t", content: "x", engine: "static", rendered: false,
        metadata: {}, error: nil }
    )

    assert_equal :success, PageFetchTool.new.execute(url: "https://example.com/", limit_chars: 99_999)[:status]
  end

  test "o teto da tool nao pode passar do que o ExtractService aceita" do
    assert_operator PageFetchTool::MAX_LIMIT, :<=, Fetcher::ExtractService::MAX_MAX_CHARS
    assert_equal Fetcher::ExtractService::DEFAULT_MAX_CHARS, PageFetchTool::DEFAULT_LIMIT
  end

  # Truncado sem saber o tamanho original nao deixa o modelo decidir se vale
  # repedir: perder 2% e 80% chegavam iguais.
  test "data informa quanto havia no total, nao so quanto voltou" do
    stub_extract(content: "x" * 500, metadata: { "content_chars_total" => 34_000 })

    data = PageFetchTool.new.execute(url: "https://example.com/", limit_chars: 500)[:data]

    assert_equal 500, data[:char_count]
    assert_equal 34_000, data[:char_count_total], "corte do ExtractService tambem conta"
    assert_equal true, data[:truncated]
  end

  test "piso do clamp vale no corte, nao no pedido ao servico" do
    stub_extract(content: "x" * 5_000)

    data = PageFetchTool.new.execute(url: "https://example.com/", limit_chars: 1)[:data]

    assert_equal PageFetchTool::MIN_LIMIT, data[:char_count], "limite abaixo do piso e elevado ao piso"
  end

  # Conteudo de canal e linear e feito para ser lido inteiro: 15k cortava uma
  # transcricao de 25k pela metade e o modelo pedia desculpa ao usuario.
  test "transcricao e thread ganham limite maior que pagina comum" do
    longo = "y" * 40_000

    { "youtube" => 40_000, "reddit" => 40_000, "static" => PageFetchTool::DEFAULT_LIMIT }.each do |engine, esperado|
      stub_extract(content: longo, engine: engine)
      data = PageFetchTool.new.execute(url: "https://example.com/")[:data]

      assert_equal esperado, data[:char_count], "engine #{engine}"
    end
  end

  test "limite explicito do modelo vence o padrao por tipo" do
    stub_extract(content: "y" * 40_000, engine: "youtube")

    data = PageFetchTool.new.execute(url: "https://example.com/", limit_chars: 1_000)[:data]

    assert_equal 1_000, data[:char_count]
  end

  # O `ExtractService` converte exceção em campo `error` — inclusive SSRF, rate
  # limit, cooldown, bot-block, PDF e timeout. A tool repassa a mensagem: quem lê
  # precisa saber POR QUE falhou, não só que falhou.
  test "erro do ExtractService vira error da tool, com a mensagem preservada" do
    {
      "host privado (10.0.0.1) — bloqueado"               => /privado/i,
      "rate limit local: host example.com atingiu 5/min"  => /rate limit/i,
      "host em cooldown por 5h (403)"                     => /cooldown/i,
      "conteúdo é PDF — não suportado"                    => /PDF/i,
      "render timeout"                                    => /timeout/i,
      "sessão de youtube.com ausente ou expirada — renovar o cookie do domínio" => /renovar/i
    }.each do |mensagem, padrao|
      stub_extract(error: mensagem, content: nil, engine: nil)
      result = PageFetchTool.new.execute(url: "https://example.com/")

      assert_equal :error, result[:status], mensagem
      assert_match(padrao, result[:reason], mensagem)
    end
  end

  test "excecao generica nao vaza stacktrace — retorna error generico" do
    Fetcher::ExtractService.stubs(:call).raises(StandardError.new("boom"))
    result = PageFetchTool.new.execute(url: "https://example.com/")

    assert_equal :error, result[:status]
    assert_match(/falha|erro/i, result[:reason])
    refute_match(/boom/, result[:reason].to_s)
  end

  test "data mantem os campos que a tool ja publicava" do
    stub_extract
    result = PageFetchTool.new.execute(url: "https://example.com/")

    %i[title url content truncated char_count fetched_at cache_age_seconds].each do |key|
      assert result[:data].key?(key), "esperava #{key} no data"
    end
  end

  # Sem `engine` o modelo não distingue transcrição de casca de página.
  test "data leva engine, rendered e metadata para o modelo" do
    stub_extract(engine: "youtube", rendered: false,
                 metadata: { "source" => "youtube", "kind" => "transcript", "lang" => "pt-BR" })

    data = PageFetchTool.new.execute(url: "https://www.youtube.com/watch?v=X")[:data]

    assert_equal "youtube", data[:engine]
    assert_equal false, data[:rendered]
    assert_equal "transcript", data[:metadata]["kind"]
  end

  test "cache_age_seconds vem do metadata quando o caminho foi o browser" do
    stub_extract(engine: "chrome", rendered: true, metadata: { "cache_age_seconds" => 42 })

    assert_equal 42, PageFetchTool.new.execute(url: "https://example.com/")[:data][:cache_age_seconds]
  end

  test "conteudo cortado e declarado truncado; conteudo que coube nao e" do
    stub_extract(content: "x" * 9_000)
    cortado = PageFetchTool.new.execute(url: "https://example.com/", limit_chars: 6_000)[:data]

    assert_equal 6_000, cortado[:char_count]
    assert_equal 9_000, cortado[:char_count_total]
    assert_equal true, cortado[:truncated]

    stub_extract(content: "x" * 6_000)
    coube = PageFetchTool.new.execute(url: "https://example.com/", limit_chars: 6_000)[:data]

    assert_equal false, coube[:truncated], "texto que coube exato nao foi truncado"
  end
end
