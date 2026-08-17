# frozen_string_literal: true

# Teste PURO de representação da migration no db/schema.rb (Defeito 4).
# Não depende de Rails/banco: lê o arquivo de schema e valida que a tabela
# search_api_quotas (com índice único) e a versão da migration estão presentes.

require "minitest/autorun"
require "pathname"

class SearchApiSchemaTest < Minitest::Test
  SCHEMA_PATH = File.expand_path("../../db/schema.rb", __dir__)
  SCHEMA = File.read(SCHEMA_PATH)

  def test_schema_representa_tabela_search_api_quotas_com_indice_unico_defeito_4
    assert_includes SCHEMA, 'create_table "search_api_quotas"'
    assert_match(
      /t\.index\s+\["api_name",\s*"month"\],\s*name:\s*"index_search_api_quotas_on_api_name_and_month",\s*unique:\s*true/,
      SCHEMA,
      "o índice único específico em [api_name, month] deve estar presente na tabela search_api_quotas"
    )
  end

  def test_schema_version_presente_e_valida
    version_match = SCHEMA.match(/define\(version:\s*(\d{4}_\d{2}_\d{2}_\d{6})\)/)
    refute_nil version_match, "o schema.rb deve definir uma versão no formato YYYY_MM_DD_HHMMSS"
    assert_operator version_match[1].delete("_").to_i, :>=, 20260817000001
  end
end
