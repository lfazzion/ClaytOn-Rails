# frozen_string_literal: true

require "test_helper"

# O camoufox ficou meses sem subir neste projeto por DUAS linhas ausentes nesta
# imagem, e nenhum teste podia reprovar: a única verificação era construir a
# imagem e rodar o browser à mão. Estas asserções são o guarda-baixo — não
# substituem a prova ao vivo, mas fazem a remoção das linhas voltar como
# falha em vez de voltar como "engine morto de novo".
class DockerfilePythonTest < ActiveSupport::TestCase
  # Override para reprovar esta suíte contra a versão ANTIGA do arquivo
  # (`git show HEAD:docker/Dockerfile.python > tmp/old.Dockerfile`).
  DOCKERFILE_PATH = ENV.fetch("DOCKERFILE_PYTHON_PATH", Rails.root.join("docker/Dockerfile.python").to_s)

  def content
    @content ||= File.read(DOCKERFILE_PATH)
  end
  test "usa base Python 3.13 (3.14 quebra o nodriver)" do
    # O Python 3.14 rejeita nodriver >= 0.48.0: byte nao-UTF-8 em
    # cdp/network.py:1345 causa SyntaxError no import (medido 12/08/2026).
    # O nodriver nao e pinado na imagem (piso >= 0.0.35) — uma versao futura
    # que quebre no 3.14 falharia em runtime; a base 3.13 mantem qualquer
    # versao importavel. A proxima troca de base deve ser decisao consciente,
    # nao efeito colateral do dependabot.
    assert_match(/^FROM python:3\.13-slim\b/, content,
                 "3.14 quebra o nodriver (>= 0.48 SyntaxError em cdp/network.py:1345)")
  end


  test "instala o runtime GTK que o Firefox do camoufox linka" do
    # `libmozgtk.so` linka libgtk-3.so.0 e libgdk-3.so.0. `playwright install
    # --with-deps` NÃO as traz (chromium headless não usa GTK), e sem elas todo
    # launch morre em "Couldn't load XPCOM". Medido com `ldd` em 05/08/2026:
    # são as únicas bibliotecas externas que faltavam na imagem.
    apt_block = content[/RUN apt-get update.*?rm -rf \/var\/lib\/apt\/lists\/\*/m]

    assert apt_block, "bloco de apt-get não encontrado em #{DOCKERFILE_PATH}"
    assert_match(/\blibgtk-3-0\b/, apt_block,
                 "sem libgtk-3-0 o camoufox não sobe: XPCOMGlueLoad error")
  end

  test "baixa o binário do camoufox no build, não na primeira execução" do
    # `pip install camoufox` traz só a biblioteca. Sem o fetch no build, o
    # primeiro `POST /run` de cada container novo baixa o Firefox e escreve o
    # progresso em STDOUT — que é exatamente onde o `CamoufoxService` faz
    # `JSON.parse(stdout.strip)`. O sintoma no Ruby é `data: null`, sem erro.
    assert_match(/^RUN\s+python3\s+-m\s+camoufox\s+fetch\b/, content,
                 "faltou `RUN python3 -m camoufox fetch`: o download vaza para o stdout em runtime")
  end

  test "o fetch do camoufox vem depois do pip que o instala" do
    pip_index = content.index(/pip install[^\n]*(\n[^\n]*)*?camoufox/m)
    fetch_index = content.index(/RUN\s+python3\s+-m\s+camoufox\s+fetch/)

    assert pip_index, "o pip install do camoufox sumiu"
    assert fetch_index, "o fetch do camoufox sumiu"
    assert_operator pip_index, :<, fetch_index,
                    "`camoufox fetch` antes do pip quebra o build (módulo ainda não existe)"
  end

  test "os requisitos de versão do pip chegam ao pip, não ao shell" do
    # `camoufox>=2.0.0` SEM aspas não é requisito: `>` é redirecionamento. O pip
    # recebe só `camoufox` e o shell cria um arquivo vazio chamado `=2.0.0`.
    # Medido em 05/08/2026 na imagem: `ls /` traz `=0.0.35`, `=0.27.0`, `=2.0.0`,
    # `=3.10.0` e `=0.7.0` (este com 14 KB — é o stdout do pip inteiro engolido),
    # e `pip show camoufox` responde 0.5.4, versão que o requisito declarado
    # proibiria. Nenhum piso de versão desta imagem estava valendo.
    pip_block = content[/RUN pip install .*?(?=\n\n)/m]
    assert pip_block, "bloco de `pip install` não encontrado em #{DOCKERFILE_PATH}"

    pip_block.scan(/(?<![\w"'=])([A-Za-z][\w.\-]*(?:[<>=!~]=|>|<)[\w.*]+)/) do |(spec)|
      flunk "requisito `#{spec}` sem aspas: o shell o transforma em redirecionamento e o pip nunca o vê"
    end
  end

  test "a versão do camoufox é pinada, não deixada ao acaso do dia do build" do
    # A lib decide qual build do Firefox o `camoufox fetch` baixa (medido: 0.5.4
    # → browsers/official/152.0.4-beta.28). Sem pin, dois builds da mesma árvore
    # produzem fingerprints diferentes — o mesmo modo de falha que fez a searxng
    # ser pinada por digest em 05/08/2026.
    assert_match(/["']camoufox==\d+\.\d+(\.\d+)?["']/, content,
                 "camoufox precisa de versão exata e entre aspas")
  end

  test "o CMD sobe a API do sidecar, não um servidor de diretório" do
    # O `http.server` de diretório vazio foi o motivo de o sidecar existir por
    # 30 dias sem ninguém falar com ele.
    assert_match(/^CMD\s+\[.*server\.py.*\]/, content,
                 "o CMD do sidecar precisa subir scripts/python/server.py")
    assert_no_match(/http\.server/, content,
                    "o `http.server` de diretório vazio voltou como CMD")
  end
end
