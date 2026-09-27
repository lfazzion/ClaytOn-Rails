# frozen_string_literal: true

require "test_helper"
# `app/tools/` NÃO é gerenciado pelo Zeitwerk (múltiplas classes por arquivo,
# require explícito em config/initializers/load_tools.rb) — o teste precisa dos
# mesmos requires que a tool tem.
require_relative "../../app/tools/tool_base"
require_relative "../../app/tools/platform_search_tools"

# `platform_search` para x e reddit quebrou em produção em 27/09/2026 com
# `NameError: uninitialized constant #<Class:Fetcher::Channels::X>::XGraphql` e
# `...::Reddit>::HostRateLimiter` (log do container docker-app-1: 38 ocorrências
# em 3h, 100% das leituras dos dois canais).
#
# A CAUSA não é arquivo faltando: os dois arquivos existem, e as duas constantes
# resolvem de boa quando olhadas de fresco — foi o que a sonda isolada do card
# mediu. É referência CAPTURADA antes de um reloader. `app/tools/` fica de fora
# do Zeitwerk e o initializer a carrega com `require` UMA vez, então ela não
# recarrega junto; `lib/` é watchable e recarrega. A tool ficava com os módulos
# DESCARCADOS, cujos corpos (`class << self`) guardam o cref de um namespace que
# o reloader já trocou.
#
# ── POR QUE TUDO RODA EM `fork` ────────────────────────────────────────────
# O sintoma só existe DEPOIS de um reload, e reload é o que não se desfaz:
# `Rails.application.reloader.reload!` descarrega as classes gerenciadas da
# Processo inteiro. Feito no processo do teste, ele envenena a suíte inteira —
# medido: 2787 runs, 24 failures, 172 errors, todos `NameError` de constante
# recém-descartada, em arquivos que não têm nada a ver com esta tool. Com o
# mesmo conserto e SEM este arquivo, a suíte fecha 2783 runs, 0 failures,
# 0 errors. O `fork` dá ao teste um processo próprio para descarregar, e o pai
# fica intacto — o `exit!` evita `at_exit`, que fecharia a conexão de banco
# herdada.
class PlatformSearchToolsReloadTest < ActiveSupport::TestCase
  # Executa o bloco em um processo FILHO que tem sua própria cópia do estado, e
  # devolve o que o filho escreveu. O pai não é tocado: nem autoload, nem
  # constante, nem conexão.
  #
  # O filho escreve por pipe em vez de usar `assert` porque asserção em processo
  # morto não reporta nada de útil — o pai recebe a falha por `flaky`/saída
  # vazia, e o sintoma (NameError) viraria "nenhuma asserção" em vez de RED.
  def em_proprio_processo
    leitura, escrita = IO.pipe
    antes = Fetcher::Channels::X.object_id

    pid = fork do
      leitura.close
      begin
        escrita.write("RESULTADO #{yield}\n")
      rescue Exception => e # rubocop:disable Lint/RescueException -- o filho RELATA qualquer erro
        escrita.write("RESULTADO #{e.class}: #{e.message}\n")
      end
      escrita.close
      exit!(0)
    end

    escrita.close
    linha = leitura.read.to_s
    leitura.close
    _, status = Process.waitpid2(pid)
    # Guarda o pai inteiro: se o `fork` tivesse vazado algo, isto acusa na hora.
    assert_equal antes, Fetcher::Channels::X.object_id, "o reload do filho não pode vazar para o pai"
    assert status.success?, "o processo do teste morreu (status #{status.inspect})"
    assert_match(/RESULTADO/, linha, "o processo do teste não devolveu nada")

    linha[/RESULTADO (.*)/m, 1].to_s.strip
  end

  # Resposta da tool achatada em `status|count|url|reason`. String e não
  # asserção porque quem afirma é o FILHO (processo separado) e quem reporta é o
  # pai — ver `em_proprio_processo`.
  def achata(result)
    dados = result[:data] || {}
    [result[:status], dados[:count], dados[:results].to_a.first&.dig("url"), result[:reason]].join("|")
  end

  POSTS_X = [
    { "url" => "https://x.com/jack/status/1001", "text" => "post", "author" => "Jack",
      "screen_name" => "jack", "created_at" => "2026-08-05T12:00:00Z",
      "likes" => 1234, "retweets" => nil, "replies" => nil }
  ].freeze

  THREADS = [
    { "url" => "https://www.reddit.com/r/ruby/comments/aaa/t/", "title" => "Titulo",
      "subreddit" => "ruby", "score" => 54, "comments" => 15 }
  ].freeze

  # ── O SINTOMA DO LOG, PROVADO QUE É REPRODUZÍVEL AQUI ────────────────────
  # Sem stub nenhum: chamar o verbo no módulo que o reloader deixou para trás
  # levanta NameError na PRIMEIRA linha do corpo, antes de qualquer rede,
  # cookie ou Chrome. É esta exceção que a tool converte em "falha inesperada ao
  # ler dentro da plataforma".
  #
  # Este teste não é o RED do conserto (ele descreve o Ruby, não a tool): é a
  # prova de que a falha do log de produção se reproduz no ambiente de teste.
  # Sem ele, o diagnóstico do card restsaria no log.
  test "o modulo descarregado reproduz o NameError exato do log de producao" do
    saida = em_proprio_processo do
      obsoleto_x     = Fetcher::Channels::X
      obsoleto_reddit = Fetcher::Channels::Reddit
      Rails.application.reloader.reload!
      refute Fetcher::Channels::X.equal?(obsoleto_x), "o reload não trocou o módulo — o teste não provaria nada"

      erros = [["X", obsoleto_x], ["Reddit", obsoleto_reddit]].map do |nome, obsoleto|
        obsoleto.search(query: "ruby rails", limit: 5)
        "#{nome}=SEMERRO"
      rescue NameError => e
        "#{nome}=#{e.class}(#{e.message})"
      end
      erros.join(" ")
    end

    assert_match(/X=NameError\(uninitialized constant #<Class:Fetcher::Channels::X>::XGraphql\)/, saida,
                 "o corpo de `X.search` tem de resolver XGraphql — é o NameError do log de produção")
    assert_match(/Reddit=NameError\(uninitialized constant #<Class:Fetcher::Channels::Reddit>::HostRateLimiter\)/, saida,
                 "o corpo de `Reddit.search` tem de resolver HostRateLimiter — idem no log")
  end

  # ── RED: O CANAL TEM DE SER RESOLVIDO NA HORA DA CHAMADA ─────────────────
  # O código anterior resolvia o canal uma vez e guardava o módulo; depois do
  # reload ele chamava o módulo morto, e a tool respondia a string que o
  # usuário viu. Assertar pelo CONTEÚDO (e não por "chamou o certo") é o que
  # separa as duas rotas: o obsoleto responde vazio, o vivo responde os itens.
  test "no x, apos um reload, a tool despacha para o modulo vivo e nao para o obsoleto" do
    saida = em_proprio_processo do
      obsoleto = Fetcher::Channels::X
      Rails.application.reloader.reload!
      vivo = Fetcher::Channels::X
      refute obsoleto.equal?(vivo), "o reload não trocou o módulo — o teste não provaria nada"

      obsoleto.stubs(:search).returns([])
      vivo.stubs(:search).with(query: "ruby rails", limit: 10).returns(POSTS_X)

      result = PlatformSearchTool.new.execute(query: "ruby rails", platform: "x")
      achata(result)
    end

    assert_equal "success|1|https://x.com/jack/status/1001|", saida,
                 "a tool precisa despachar para o módulo VIVO depois de um reload " \
                 "(formato: status|count|url|reason)"
  end

  # Mesmo contrato no Reddit e pelo MESMO desenho: um reload, um canal, uma
  # resolução na hora da chamada. O conserto é comum aos dois — se fosse por
  # canal, este passaria e o do X não.
  test "no reddit, apos um reload, a tool despacha para o modulo vivo e nao para o obsoleto" do
    saida = em_proprio_processo do
      obsoleto = Fetcher::Channels::Reddit
      Rails.application.reloader.reload!
      vivo = Fetcher::Channels::Reddit
      refute obsoleto.equal?(vivo), "o reload não trocou o módulo — o teste não provaria nada"

      obsoleto.stubs(:search).returns([])
      vivo.stubs(:search).with(query: "ruby 4", limit: 10).returns(THREADS)

      result = PlatformSearchTool.new.execute(query: "ruby 4", platform: "reddit")
      achata(result)
    end

    assert_equal "success|1|https://www.reddit.com/r/ruby/comments/aaa/t/|", saida,
                 "a tool precisa despachar para o módulo VIVO depois de um reload " \
                 "(formato: status|count|url|reason)"
  end

  # O caminho de PERFIL do X (`@handle` → `timeline`) passa pelo mesmo
  # `canal_para`/`ler` e estava no log com a mesma falha (04:39:51,
  # `uninitialized constant #<Class:Fetcher::Channels::X>::CookieJar` — a MESMA
  # causa: outra constante do corpo do mesmo módulo obsoleto).
  test "no x por perfil, apos um reload, a tool despacha para o modulo vivo" do
    saida = em_proprio_processo do
      obsoleto = Fetcher::Channels::X
      Rails.application.reloader.reload!
      vivo = Fetcher::Channels::X
      refute obsoleto.equal?(vivo), "o reload não trocou o módulo — o teste não provaria nada"

      obsoleto.stubs(:timeline).returns([])
      vivo.stubs(:timeline).with(user: "jack", limit: 10).returns(POSTS_X)

      result = PlatformSearchTool.new.execute(query: "@jack", platform: "x")
      achata(result)
    end

    assert_equal "success|1|https://x.com/jack/status/1001|", saida,
                 "a timeline do X precisa despachar para o módulo VIVO depois de um reload " \
                 "(formato: status|count|url|reason)"
  end

  # A GUARDA DO DESENHO, e não do sintoma: o conserto é "resolver pelo nome na
  # hora da chamada". Sem isso, um conserto por canal (uma linha no X, outra no
  # Reddit) passaria nestes testes e continuaria quebrando o próximo canal.
  test "a tool guarda o NOME do canal, e nao a classe" do
    assert_kind_of String, PlatformSearchTool::PLATFORMS["x"],
                   "guardar a classe é a causa raiz: o módulo capturado fica obsoleto no reload"
    assert_kind_of String, PlatformSearchTool::PLATFORMS["reddit"]
    PlatformSearchTool::PLATFORMS.each_value do |nome|
      assert_kind_of String, nome
      assert Fetcher::Channels.const_defined?(nome, false), "#{nome} não existe em Fetcher::Channels"
    end
  end
end
