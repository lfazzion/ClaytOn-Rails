# frozen_string_literal: true

# F3b — Origem (discord/mcp/nil) + piso 5% pro bot.
#
# Decisão de design (D-F3b, 30/08/2026):
#
#   - UMA linha canônica por (api_name, month). Mantemos o índice único
#     existente — é o que serializa o `with_lock` do F3a (E10). Sem ele o
#     race do F3a volta.
#
#   - Colunas INTEIRAS na linha canônica para a métrica de origem
#     (count_discord, count_mcp) — não tabela nova. São CONTADORES, não
#     tetos: o teto é único (count >= ceiling) e o piso é só uma exceção
#     do teto para `origin = :discord`.
#
#   - Coluna `origin` string nullable na linha canônica: quando o caller
#     pede `find_or_create_by(api_name:, month:, origin: ...)` com origin
#     setada, ele cai no índice único [api_name, month] e o `with_lock`
#     funciona igual. Mantemos `origin` apenas para F8-readiness — o log
#     JSON do F8 e o rake `search:report` precisam dela como observabilidade.
#     O `reserve_quota!` NUNCA usa `origin` no find_or_create_by (a linha
#     é sempre a canônica sem origin), só nas colunas count_discord /
#     count_mcp que são incrementadas juntas.
#
#   - Piso: `max(1, floor(ceiling * 0.05))`. Ativado exclusivamente quando
#     `origin == :discord` e `count_discord < piso`. Quando o teto principal
#     (count) está estourado (count >= ceiling), discord AINDA pode gastar
#     até encher o piso (essa é a concessionária: o bot não fica sem API
#     porque a campanha gastou tudo).
#
# Plano-fase2 §D1 (linha 31) é canônico para a regra do piso. O brief
# desta fatia confirma "teto único intacto", alinhado com D1 ("um teto só").
class AddOriginMetricsToSearchApiQuotas < ActiveRecord::Migration[8.1]
  def up
    # Coluna de observabilidade da origem (qual caller fez esta reserva).
    # `origin` é só metadado — o `find_or_create_by` do F3a continua
    # ignorando essa coluna e usando o índice único [api_name, month].
    # NULL = "sem origem" (legado / outros); não-default, nullable.
    add_column :search_api_quotas, :origin, :string, null: true

    # Contadores por origem — métricas, não tetos. Default 0 na linha
    # canônica: garante que `count_discord` e `count_mcp` sempre lêem
    # inteiros quando `reserve_quota!` decide o piso. Sem default, um
    # `find_or_create_by` retornaria nil e a comparação com o piso
    # quebraria (NilClass < Integer).
    add_column :search_api_quotas, :count_discord, :integer, null: false, default: 0
    add_column :search_api_quotas, :count_mcp,     :integer, null: false, default: 0

    # NÃO criamos índice novo em [api_name, month, origin]:
    #   1. O índice único [api_name, month] já cobre a busca canônica
    #      usada pelo F3a (find_or_create_by(api_name:, month:)).
    #   2. A coluna `origin` é só observabilidade da linha canônica —
    #      a consulta do F8 (relatório) é por (api_name, month) e cai no
    #      índice existente; a distribuição por origin é GROUP BY sobre
    #      o resultado, sem necessidade de índice composto.
    #   3. Criar índice não-unique [api_name, month, origin] faria o
    #      banco otimizar o caminho que NÃO usamos e custa espaço.
  end

  def down
    remove_column :search_api_quotas, :count_mcp
    remove_column :search_api_quotas, :count_discord
    remove_column :search_api_quotas, :origin
  end
end