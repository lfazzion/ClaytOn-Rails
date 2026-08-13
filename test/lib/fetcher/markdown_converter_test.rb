# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/fetcher/markdown_converter"

class Fetcher::MarkdownConverterTest < ActiveSupport::TestCase
  def convert(html)
    Fetcher::MarkdownConverter.call(html)
  end

  test "títulos viram atx" do
    assert_equal "# Um", convert("<h1>Um</h1>")
    assert_equal "### Três", convert("<h3>Três</h3>")
  end

  test "parágrafos ficam separados por linha em branco" do
    assert_equal "Primeiro\n\nSegundo", convert("<p>Primeiro</p><p>Segundo</p>")
  end

  test "lista não ordenada usa hífen" do
    markdown = convert("<ul><li>a</li><li>b</li></ul>")
    assert_equal "- a\n- b", markdown
  end

  test "lista ordenada numera" do
    markdown = convert("<ol><li>um</li><li>dois</li></ol>")
    assert_equal "1. um\n2. dois", markdown
  end

  test "lista aninhada indenta" do
    markdown = convert("<ul><li>pai<ul><li>filho</li></ul></li></ul>")
    assert_includes markdown, "- pai"
    assert_includes markdown, "  - filho"
  end

  test "links preservam href" do
    assert_equal "[Rails](https://rubyonrails.org)", convert('<a href="https://rubyonrails.org">Rails</a>')
  end

  test "link javascript vira só o texto" do
    assert_equal "clique", convert('<a href="javascript:alert(1)">clique</a>')
  end

  test "ênfase e código inline" do
    assert_equal "**forte** e *ênfase* e `codigo`",
                 convert("<p><strong>forte</strong> e <em>ênfase</em> e <code>codigo</code></p>")
  end

  test "bloco de código vira fence" do
    assert_equal "```\nputs :oi\n```", convert("<pre>puts :oi</pre>")
  end

  test "citação usa prefixo" do
    assert_equal "> citado", convert("<blockquote><p>citado</p></blockquote>")
  end

  test "tabela vira pipe table com separador" do
    html = "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>"
    markdown = convert(html)

    assert_includes markdown, "| A | B |"
    assert_includes markdown, "| 1 | 2 |"
    assert_match(/\|\s*---\s*\|/, markdown)
  end

  test "script, style e nav somem" do
    html = "<div><script>roubar()</script><style>a{}</style><nav>menu</nav><p>fica</p></div>"
    markdown = convert(html)

    assert_equal "fica", markdown
    assert_not_includes markdown, "roubar"
    assert_not_includes markdown, "menu"
  end

  test "imagem sem alt é descartada; com alt e src vira imagem markdown válida" do
    assert_equal "", convert('<img src="x.png">')
    assert_equal "![diagrama](x.png)", convert('<img src="x.png" alt="diagrama">')
  end

  test "imagem com src ausente é descartada" do
    assert_equal "", convert('<img alt="diagrama">')
    assert_equal "", convert('<img>')
  end

  test "imagem com esquema perigoso (javascript, data) é descartada" do
    assert_equal "", convert('<img src="javascript:alert(1)" alt="x">')
    assert_equal "", convert('<img src="data:text/html,foo" alt="x">')
  end

  test "imagem com esquema perigoso bypassa case-sensitive (JavaScript:, Data:, VBScript:)" do
    assert_equal "", convert('<img src="JavaScript:alert(1)" alt="x">')
    assert_equal "", convert('<img src="DATA:text/html,foo" alt="x">')
    assert_equal "", convert('<img src="vbscript:msgbox(1)" alt="x">')
    assert_equal "", convert('<img src="VBScript:msgbox(1)" alt="x">')
  end

  test "imagem com scheme perigoso e whitespace obfuscado é descartada" do
    assert_equal "", convert('<img src="java	script:alert(1)" alt="x">')
    assert_equal "", convert('<img src="java script:alert(1)" alt="x">')
  end

  test "imagem com scheme http(s) normal é preservada" do
    assert_equal "![ok](https://exemplo.com/img.png)", convert('<img src="https://exemplo.com/img.png" alt="ok">')
    assert_equal "![ok](http://exemplo.com/img.png)", convert('<img src="http://exemplo.com/img.png" alt="ok">')
  end

  test "html vazio ou nil devolve string vazia" do
    assert_equal "", convert(nil)
    assert_equal "", convert("")
    assert_equal "", convert("   ")
  end

  test "tabela vazia no início calcula separador com colunas da primeira linha útil" do
    html = "<table><tr></tr><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>"
    markdown = convert(html)

    assert_includes markdown, "| A | B |"
    assert_includes markdown, "| 1 | 2 |"
    assert_match(/^\| --- \| --- \|$/, markdown)
  end

  test "tabela externa não incorpora linhas de tabela aninhada" do
    html = "<table><tr><th>A</th><th>B</th></tr><tr><td><table><tr><td>inner</td></tr></table></td></tr></table>"
    markdown = convert(html)

    assert_includes markdown, "| A | B |"
    # A linha da tabela interna não deve aparecer como linha independente
    # (standalone) da tabela externa — ela deve estar apenas dentro da célula.
    assert_not_includes markdown.lines.map(&:strip), "| inner |"
  end

  test "markdown é menor que o HTML de origem" do
    html = <<~HTML
      <div class="wrapper" id="main" data-track="123">
        <section class="content"><h2 class="title heading-lg">Título</h2>
        <p class="body text-base leading-7">#{'palavra ' * 30}</p>
        <ul class="list"><li class="item">um</li><li class="item">dois</li></ul></section>
      </div>
    HTML

    markdown = convert(html)

    assert_operator markdown.length, :<, html.length
    assert_includes markdown, "## Título"
    assert_includes markdown, "- um"
  end
end
