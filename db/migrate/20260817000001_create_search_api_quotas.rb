# frozen_string_literal: true

# Cota mensal por API de busca externa (Tavily/Exa/Linkup).
#
# Decisão de escopo: o repo NÃO tem um `sentiment_daily_quota` nem outro padrão
# de quota de tabela para copiar (a quota diária dos LLMs vive em Rails.cache,
# ver lib/llm/base_client.rb). A spec prevê esse fallback explícito: criar a
# tabela `search_api_quotas` (api_name, month 'YYYY-MM', count) com
# find_or_create + increment DENTRO de with_lock e índice único.
#
# Índice único (api_name, month) serializa a contagem por API/mês e impede
# duplicatas concorrentes. O padrão de transação segue a migration irmã
# 20260813000001 (em SQLite o DDL é transacional e admite um escritor por vez).
class CreateSearchApiQuotas < ActiveRecord::Migration[8.1]
  def up
    create_table :search_api_quotas do |t|
      t.string :api_name, null: false
      t.string :month, null: false # 'YYYY-MM'
      t.integer :count, null: false, default: 0
      t.timestamps
    end

    transaction do
      remove_index :search_api_quotas, name: "index_search_api_quotas_on_api_name_and_month", if_exists: true
      add_index :search_api_quotas, [:api_name, :month], unique: true,
                name: "index_search_api_quotas_on_api_name_and_month"
    end
  end

  def down
    drop_table :search_api_quotas
  end
end
