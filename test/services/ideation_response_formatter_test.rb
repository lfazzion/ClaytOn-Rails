# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/ideation_response_formatter"

class IdeationResponseFormatterTest < ActiveSupport::TestCase
  test "formata JSON com bloco markdown e sugestoes_de_conteudo" do
    json_block = <<~JSON
      ```json
      {
        "sugestoes_de_conteudo": [
          {
            "titulo": "Top 5 Filmes da Semana",
            "descricao": "Resumo dos lançamentos mais aguardados no cinema.",
            "formatos_sugeridos": ["Reels", "TikTok"]
          },
          {
            "titulo": "Cobertura BGS",
            "descricao": "Dicas e bastidores do evento.",
            "formatos_sugeridos": ["Shorts", "Stories"]
          }
        ]
      }
      ```
    JSON

    expected = <<~TEXT.strip
      1. **Top 5 Filmes da Semana** — Resumo dos lançamentos mais aguardados no cinema. Formatos: Reels, TikTok
      2. **Cobertura BGS** — Dicas e bastidores do evento. Formatos: Shorts, Stories
    TEXT

    assert_equal expected, IdeationResponseFormatter.format(json_block)
  end

  test "formata JSON puro sem markdown com chave sugestoes" do
    raw_json = '{"sugestoes": [{"titulo": "Setup Tour", "descricao": "Mostre os bastidores.", "formatos_sugeridos": ["Reels"]}]}'
    expected = "1. **Setup Tour** — Mostre os bastidores. Formatos: Reels"

    assert_equal expected, IdeationResponseFormatter.format(raw_json)
  end

  test "formata JSON com formatos_sugeridos como string simples" do
    raw_json = '{"sugestoes_de_conteudo": [{"titulo": "Review de Games", "descricao": "Analise o novo patch.", "formatos_sugeridos": "YouTube Video"}]}'
    expected = "1. **Review de Games** — Analise o novo patch. Formatos: YouTube Video"

    assert_equal expected, IdeationResponseFormatter.format(raw_json)
  end

  test "formata JSON array na raiz" do
    raw_json = '[{"titulo": "Ideia Direta", "descricao": "Explicacao rapida.", "formatos_sugeridos": ["TikTok"]}]'
    expected = "1. **Ideia Direta** — Explicacao rapida. Formatos: TikTok"

    assert_equal expected, IdeationResponseFormatter.format(raw_json)
  end

  test "formata JSON com chaves em ingles (title, description, formats)" do
    raw_json = '{"content_suggestions": [{"title": "Tech Review", "description": "Analyzing new gadgets.", "formats": ["Reels"]}]}'
    expected = "1. **Tech Review** — Analyzing new gadgets. Formatos: Reels"

    assert_equal expected, IdeationResponseFormatter.format(raw_json)
  end

  test "mantem texto puro inalterado sem regressao" do
    plain_text = "1. **Ideia 1**: Descrição da ideia 1\n2. **Ideia 2**: Descrição da ideia 2"

    assert_equal plain_text, IdeationResponseFormatter.format(plain_text)
  end

  test "trata entrada nil ou vazia retornando string vazia" do
    assert_equal "", IdeationResponseFormatter.format(nil)
    assert_equal "", IdeationResponseFormatter.format("")
    assert_equal "", IdeationResponseFormatter.format("   \n\t  ")
  end

  test "formata item sem formatos_sugeridos" do
    raw_json = '{"sugestoes": [{"titulo": "Apenas Titulo", "descricao": "Apenas descricao."}]}'
    expected = "1. **Apenas Titulo** — Apenas descricao."

    assert_equal expected, IdeationResponseFormatter.format(raw_json)
  end

  test "formata item sem descricao" do
    raw_json = '{"sugestoes": [{"titulo": "Apenas Titulo", "formatos_sugeridos": ["Reels"]}]}'
    expected = "1. **Apenas Titulo**. Formatos: Reels"

    assert_equal expected, IdeationResponseFormatter.format(raw_json)
  end

  test "formata JSON invalido ou truncado caindo para texto puro" do
    malformed = "```json\n{\"sugestoes\": [invalido...\n```"

    assert_equal malformed.strip, IdeationResponseFormatter.format(malformed)
  end

  # Regressão do defeito do dono (BLOCKER 1): JSON válido com array de
  # sugestões VAZIO NUNCA deve vazar o JSON cru. O caminho é:
  # format -> try_parse_json (JSON válido) -> format_json -> extract_items
  # devolve [] -> hoje retorna fallback_text (o JSON cru). Corrigido para
  # distinguir "não é JSON" (devolve texto original) de "é JSON válido mas
  # sem itens" (devolve string vazia, sem vazar o JSON).
  test "JSON válido com array de sugestoes vazio não vaza o JSON cru" do
    raw_json = '{"sugestoes_de_conteudo": []}'

    assert_equal "", IdeationResponseFormatter.format(raw_json)
  end
end
