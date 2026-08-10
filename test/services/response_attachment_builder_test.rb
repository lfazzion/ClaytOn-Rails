# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/response_attachment_builder"

class ResponseAttachmentBuilderTest < ActiveSupport::TestCase
  # m5 (revisão Opus): os testes não podem depender do ENV ambiente — se o
  # operador puser DISCORD_OUTPUT_* na .env, os testes quebrariam em silêncio.
  setup do
    @output_env = {
      "DISCORD_OUTPUT_CODE_LINES" => ENV["DISCORD_OUTPUT_CODE_LINES"],
      "DISCORD_OUTPUT_PROSE_CHARS" => ENV["DISCORD_OUTPUT_PROSE_CHARS"]
    }
    ENV.delete("DISCORD_OUTPUT_CODE_LINES")
    ENV.delete("DISCORD_OUTPUT_PROSE_CHARS")
  end

  teardown do
    @output_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "codigo python grande (>25 linhas) gera Result com filename codigo.py, content sem backticks e caption restante" do
    lines = (1..30).map { |i| "  print('linha #{i}')" }
    code_block = "```python\n#{lines.join("\n")}\n```"
    texto = "Aqui esta o script:\n\n#{code_block}\n\nEspero que ajude!"

    result = ResponseAttachmentBuilder.build(texto)

    assert_not_nil result
    assert_equal "codigo.py", result.filename
    assert_equal lines.join("\n"), result.content
    refute_includes result.content, "```"
    assert_equal "Aqui esta o script:\n\nEspero que ajude!", result.caption
  end

  test "fence com title='solver.rb' usa filename sanitizado solver.rb" do
    lines = (1..30).map { |i| "  puts 'linha #{i}'" }
    code_block = "```ruby title=\"solver.rb\"\n#{lines.join("\n")}\n```"
    texto = code_block

    result = ResponseAttachmentBuilder.build(texto)

    assert_not_nil result
    assert_equal "solver.rb", result.filename
    assert_equal lines.join("\n"), result.content
    assert_equal "Aqui esta o arquivo.", result.caption
  end

  test "title malicioso com path traversal, colons e aspas e sanitizado" do
    lines = (1..30).map { |i| "  puts #{i}" }
    code_block = "```ruby title=\"../../dir/a:b.rb\"\n#{lines.join("\n")}\n```"
    texto = code_block

    result = ResponseAttachmentBuilder.build(texto)

    assert_not_nil result
    assert_equal "dirab.rb", result.filename
    refute_includes result.filename, ".."
    refute_includes result.filename, "/"
    refute_includes result.filename, ":"
  end

  test "snippet pequeno (<=25 linhas) devolve nil" do
    lines = (1..20).map { |i| "  puts #{i}" }
    code_block = "```ruby\n#{lines.join("\n")}\n```"
    texto = "Veja este trecho:\n\n#{code_block}"

    result = ResponseAttachmentBuilder.build(texto)

    assert_nil result
  end

  test "prosa <= 2000 e 2500 devolvem nil; prosa > 4000 gera resposta.md" do
    prosa_curta = "A" * 1500
    prosa_media = "B" * 2500
    prosa_longa = "Esta e uma resposta muito longa sobre a analise. " + ("palavra " * 600)

    assert_nil ResponseAttachmentBuilder.build(prosa_curta)
    assert_nil ResponseAttachmentBuilder.build(prosa_media)

    result = ResponseAttachmentBuilder.build(prosa_longa)
    assert_not_nil result
    assert_equal "resposta.md", result.filename
    assert_equal prosa_longa, result.content
    assert_match(/^📄 Esta e uma resposta muito longa/, result.caption)
    assert_match(/\.\.\.$/, result.caption)
  end

  test "JSON grande em fence sem linguagem gera codigo.json quando parseia e codigo.txt quando nao parseia" do
    json_lines = (1..30).map { |i| "  \"key_#{i}\": #{i}" }
    json_valid_body = "{\n#{json_lines.join(",\n")}\n}"
    code_block_valid = "```\n#{json_valid_body}\n```"

    result_valid = ResponseAttachmentBuilder.build(code_block_valid)
    assert_not_nil result_valid
    assert_equal "codigo.json", result_valid.filename

    invalid_body = (1..30).map { |i| "linha nao json #{i}" }.join("\n")
    code_block_invalid = "```\n#{invalid_body}\n```"

    result_invalid = ResponseAttachmentBuilder.build(code_block_invalid)
    assert_not_nil result_invalid
    assert_equal "codigo.txt", result_invalid.filename
  end

  test "caption acima de 2000 preserva o excedente em caption_resto (B2)" do
    intro = "A" * 2500
    lines = (1..30).map { |i| "  puts #{i}" }
    code_block = "```ruby\n#{lines.join("\n")}\n```"
    texto = "#{intro}\n\n#{code_block}"

    result = ResponseAttachmentBuilder.build(texto)

    assert_not_nil result
    assert_operator result.caption.length, :<=, 2000
    # Marcador explícito de corte + excedente preservado — NADA se perde
    # (regressão que o split_message de hoje nunca teve).
    assert_includes result.caption, "…"
    assert_equal intro[1999..], result.caption_resto
  end

  test "fence com espaco apos as crases e detectado (B1)" do
    lines = (1..30).map { |i| "  print('linha #{i}')" }
    code_block = "``` python\n#{lines.join("\n")}\n```"
    texto = code_block

    result = ResponseAttachmentBuilder.build(texto)

    assert_not_nil result
    assert_equal "codigo.py", result.filename
  end

  test "title com espaco entre aspas e aceito (B1)" do
    lines = (1..30).map { |i| "  puts 'linha #{i}'" }
    code_block = "```ruby title=\"meu arquivo.rb\"\n#{lines.join("\n")}\n```"

    result = ResponseAttachmentBuilder.build(code_block)

    assert_not_nil result
    assert_equal "meu arquivo.rb", result.filename
  end

  test "info-string com atributos extras nao quebram a abertura (B1)" do
    lines = (1..30).map { |i| "  x = #{i}" }
    code_block = "```python filename=solver.py {1,3}\n#{lines.join("\n")}\n```"

    result = ResponseAttachmentBuilder.build(code_block)

    assert_not_nil result
    assert_equal "codigo.py", result.filename
    assert_equal lines.join("\n"), result.content
  end

  test "fence de 4 crases com markdown aninhado: a linha interna nao fecha o bloco (ressalva 1)" do
    # ````markdown ... ```bash ... ```` — o ``` interno (3 crases) é MENOR que
    # a abertura (4) e NÃO fecha; só o fechamento de 4 crases fecha.
    interno = (1..26).map { |i| "```bash\n  echo #{i}\n```" }.join("\n")
    corpo = "# HEADER\n\n#{interno}"
    code_block = "````markdown\n#{corpo}\n````"

    result = ResponseAttachmentBuilder.build(code_block)

    assert_not_nil result
    assert_equal "codigo.md", result.filename
    assert_equal corpo, result.content
    refute_includes result.content, "````markdown"
  end

  test "dois blocos grandes: AMBOS vao para o arquivo e o caption fica so com o texto de fora (B2)" do
    py = (1..30).map { |i| "  print(#{i})" }
    sql = (1..30).map { |i| "SELECT #{i};" }
    texto = "Explicacao.\n\n```python\n#{py.join("\n")}\n```\n\n```sql\n#{sql.join("\n")}\n```\n\nFim."

    result = ResponseAttachmentBuilder.build(texto)

    assert_not_nil result
    assert_equal "codigo.txt", result.filename
    assert_includes result.content, py.join("\n")
    assert_includes result.content, sql.join("\n")
    refute_includes result.content, "```"
    assert_includes result.content, "--- sql ---"
    assert_equal "Explicacao.\n\nFim.", result.caption
  end

  test "fence nao fechado (resposta cortada no meio do bloco) ainda conta como bloco (M2)" do
    lines = (1..30).map { |i| "  print('linha #{i}')" }
    texto = "```python\n#{lines.join("\n")}" # sem fechamento

    result = ResponseAttachmentBuilder.build(texto)

    assert_not_nil result
    assert_equal "codigo.py", result.filename
    assert_equal lines.join("\n"), result.content
  end

  test "title sem extensao ganha a extensao real (m6)" do
    lines = (1..30).map { |i| "  puts #{i}" }
    code_block = "```ruby title=\"notas\"\n#{lines.join("\n")}\n```"

    result = ResponseAttachmentBuilder.build(code_block)

    assert_not_nil result
    assert_equal "notas.rb", result.filename
  end

  test "ENV vazia (chave presente) nao desliga a feature nem vira tudo arquivo (M1)" do
    ENV["DISCORD_OUTPUT_CODE_LINES"] = ""
    lines = (1..30).map { |i| "  puts #{i}" }
    code_block = "```ruby\n#{lines.join("\n")}\n```"

    result = ResponseAttachmentBuilder.build(code_block)

    # clamp [..,1].max: linha vazia vira 0 -> clamp 1 -> bloco de 30 linhas
    # ainda vira arquivo (0 faria até 1 linha virar; o clamp impede o absurdo).
    assert_not_nil result
    assert_equal "codigo.rb", result.filename
  end

  test "linguagem desconhecida cai para txt" do
    lines = (1..30).map { |i| "linha #{i}" }
    code_block = "```linguagem_desconhecida\n#{lines.join("\n")}\n```"

    result = ResponseAttachmentBuilder.build(code_block)

    assert_not_nil result
    assert_equal "codigo.txt", result.filename
  end
end
