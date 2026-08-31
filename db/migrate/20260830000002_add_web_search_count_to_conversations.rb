# frozen_string_literal: true

# F5a (30/08/2026) — Teto de 5 buscas web por conversa ativa do Discord.
#
# Decisão de design (D-F5a, plano-fase2.md §D4):
#
#   - Coluna `web_search_count` na linha canônica de `conversations` (a linha
#     ATIVA do escopo, índice parcial único [scope] where active=1).
#
#   - O teto mora NA CONVERSA, não no escopo global nem no usuário: a fronteira
#     entre tetos é o comando `/new`, que abre uma NOVA row (default 0) — o que
#     elimina a necessidade de zerar manualmente em `reset!`. Por construção,
#     `/new` zera porque é outra linha. Decisão D4 verbatim.
#
#   - `default: 0`, `null: false`: toda conversa NOVA começa com contador zero,
#     inclusive antes da migration rodar em produção (linhas pré-existentes
#     ganham 0 no `up` da migration via default retroativo).
#
#   - NÃO criamos índice novo: o gate do F5a lê `Conversation.active_for(scope)`
#     que usa o índice parcial único existente (`index_conversations_on_active_scope`).
#     Incremento usa `ActiveRecord::Base#increment_counter` (UPDATE atômico
#     por id) que bate no PK — não precisa de índice composto.
#
#   - Origem (Discord vs MCP) NÃO mora em coluna: D4 explicita que o teto é
#     "só do caminho Discord in-process". MCP e outras origens não incrementam
#     este contador — a checagem fica no `WebSearchTool` lendo
#     `Thread.current[:cleitin_origin]`.
class AddWebSearchCountToConversations < ActiveRecord::Migration[8.1]
  def up
    add_column :conversations, :web_search_count, :integer, null: false, default: 0
  end

  def down
    remove_column :conversations, :web_search_count
  end
end
