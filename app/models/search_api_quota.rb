# frozen_string_literal: true

# Cota mensal por API de busca externa (Linkup/Exa/Tavily).
class SearchApiQuota < ApplicationRecord
  self.table_name = "search_api_quotas"

  validates :api_name, presence: true
  validates :month, presence: true, format: { with: /\A\d{4}-\d{2}\z/ }

  def self.current_month
    if defined?(Time.current) && Time.current
      Time.current.in_time_zone("America/Sao_Paulo").strftime("%Y-%m")
    else
      Time.now.strftime("%Y-%m")
    end
  end

  # Cota esgotada se a contagem do mês >= teto.
  # Teto zero (ou negativo) bloqueia mesmo sem registro existente.
  # Executa com lock para serializar verificação e evitar TOCTOU sob concorrência.
  def self.exceeded?(api_name, ceiling, month: current_month)
    return true if ceiling <= 0

    rec = find_by(api_name: api_name, month: month)
    return false unless rec

    rec.with_lock do
      rec.count >= ceiling
    end
  end

  # Incrementa a contagem do mês DENTRO de with_lock (transação serializa
  # leitura + gravação, evitando corrida de incremento concorrente).
  # Em caso de corrida no find_or_create_by (RecordNotUnique ou BusyException),
  # recupera o registro criado concorrentemente sem perder sucesso.
  # BusyException em find_or_create_by concorrente = corrida de CREATE,
  # recuperável; retry após a outra thread commitar.
  #
  # NOTA F3a: `increment` foi mantido por compatibilidade com
  # test/services/search_api_quota_test.rb (minitest puro sem Rails) e com
  # `SearchApiRouter.increment_quota` (helper público fail-open). O caminho
  # NOVO do router usa `reserve_quota!` para fundir check+increment numa
  # única transação atômica (corrige o TOCTOU do E10).
  def self.increment(api_name, month: current_month)
    rec = begin
      find_or_create_by(api_name: api_name, month: month) do |r|
        r.count = 0
      end
    rescue ActiveRecord::RecordNotUnique, SQLite3::BusyException
      # Concorrente acabou de criar a linha. `retry` re-executa o bloco;
      # o find_or_create_by vai agora encontrar a row já criada.
      rec = find_by(api_name: api_name, month: month) || retry
    end
    rec.with_lock do
      rec.increment!(:count)
    end
  end

  # ── F3b D1: piso 5% pro bot + métricas por origem ────────────────────────────
  # Regra canônica (plano-fase2 D1, linha 31 / aceite F3b, linha 109):
  #
  #   "Piso dos últimos 5%" — RESERVA, não overage. O teto único é `count`
  #   e NUNCA passa de `ceiling`. Discord (o bot) tem acesso aos últimos 5%
  #   da cota; MCP e demais origens param aos 95%.
  #
  # Concretamente (uma fórmula única: mcp_limit = ceiling - bot_floor_size(ceiling)):
  #   ceiling <= 0                              → kill-switch; ninguém reserva
  #                                              (nem Discord). Early-return.
  #   origin != :discord (inclui nil e mcp)
  #     count >= mcp_limit                      → recusa (MCP/legado param).
  #     count <  mcp_limit                      → reserva normal.
  #   origin == :discord
  #     count <  ceiling                        → reserva normal (count_discord+1).
  #     count >= ceiling                        → recusa (teto único puro; sem
  #                                              overage — `count` NUNCA
  #                                              ultrapassa `ceiling`).
  #
  # Tabela rápida de `mcp_limit = ceiling - bot_floor_size(ceiling)`:
  #   ceiling=100 → bot_floor_size=5  → mcp_limit=95
  #   ceiling=10  → bot_floor_size=0  → mcp_limit=10 (teto pequeno, sem fatia extra)
  #   ceiling=5   → bot_floor_size=0  → mcp_limit=5  (teto 1-19: piso=0 → mcp usa tudo)
  #   ceiling=1   → bot_floor_size=0  → mcp_limit=1
  #   ceiling=0   → kill-switch (early-return antes do cálculo)
  #
  # A coluna `count_discord` é CONTADOR DE OBSERVABILIDADE da reserva: sobe
  # junto com `count` e serve ao dashboard F8 (rake search:report). NÃO é um
  # segundo teto — o teto é único, e a trava do Discord é só `count >= ceiling`.
  FLOOR_RATIO = 0.05
  private_constant :FLOOR_RATIO

  # Tamanho da RESERVA de piso para o bot: `max(0, floor(ceiling * 0.05))`.
  # `ceiling=100 → 5`, `ceiling=5 → 0`, `ceiling=1 → 0`, `ceiling=0 → 0`.
  # `max(0, ...)` evita piso negativo com tetos pequenos (1-2) e zera o
  # piso com `ceiling=0` (kill-switch — visto no early-return abaixo).
  def self.bot_floor_size(ceiling)
    [0, (ceiling.to_i * FLOOR_RATIO).floor].max
  end
  private_class_method :bot_floor_size

  # Coluna que recebe o incremento do contador de origem (nenhuma se nil).
  # Símbolo (não string) para casar com o `increment!` do AR — strings não
  # funcionam como argumento de `increment!`. Chave `nil => nil` explícita
  # para legibilidade (a forma `nil:` em literal de hash vira símbolo `:nil`,
  # o que confunde leitora — esse desenho evita a armadilha).
  ORIGIN_COUNTER_COLUMN = {
    discord: :count_discord,
    mcp:     :count_mcp,
    nil     => nil
  }.freeze
  private_constant :ORIGIN_COUNTER_COLUMN

  # ── F3a: reserva atômica de quota — REGRA CANÔNICA F3b D1 (revisada) ───────
  # Funde `exceeded?` + `increment` numa única transação atômica para fechar
  # a janela TOCTOU do E10: dois `with_lock` separados davam espaço para uma
  # thread passar no check e a outra também passar antes do increment gravar.
  #
  # Regra (F3b D1 — "RESERVA dos últimos 5%"):
  #   1. ceiling <= 0 → false SEMPRE. Teto 0 é kill-switch (Discord não
  #      escapa — o bot fica sem API). Early-return SEM incrementar.
  #   2. origin != :discord (inclui nil ≡ mcp) e count >= mcp_limit
  #      (onde `mcp_limit = ceiling - bot_floor_size(ceiling)`)
  #      → false SEM incrementar. MCP/legado param; a fatia 96–100 é
  #      exclusiva do bot. Com `ceiling=5`/`ceiling=1` (piso=0),
  #      `mcp_limit = ceiling`, e MCP reserva até o teto — não há
  #      "reserva de piso" extra: teto pequeno demais para partilha.
  #   3. origin == :discord recusa SÓ com count >= ceiling (sem sobreposição):
  #      a trava é única no teto. Sem overage (`count` nunca ultrapassa
  #      `ceiling`); a coluna `count_discord` é só métrica, não um segundo
  #      teto paralelo.
  #   4. Caso normal (count < ceiling para qualquer origem; ou
  #      origin == :discord com count < ceiling) → increment!(:count),
  #      e se origin não for nil, increment!(ORIGIN_COUNTER_COLUMN[origin]).
  #   5. Em corrida na criação concorrente (RecordNotUnique), recupera o
  #      registro já criado pela thread rival e re-tenta o lock — análogo
  #      ao `increment` legado.
  #
  # `max(0, ...)` em `bot_floor_size` evita piso negativo com tetos 1-2
  # (e.g. ceiling=2 → floor(0.10)=0 → max(0,0)=0 → `bot_floor_size=0`).
  # Isso é o que faz `mcp_limit(2)=2` e `mcp_limit(1)=1` — MCP reserva
  # até o teto inteiro, sem "fatia zero" artificial.
  #
  # @param origin [:discord, :mcp, nil] nil = "sem origem" (legado).
  # @return [Boolean] true se reservou, false se teto/piso atingido.
  def self.reserve_quota!(api_name, ceiling:, month: current_month, origin: nil)
    return false if ceiling <= 0

    transaction do
      rec = nil
      begin
        rec = find_or_create_by(api_name: api_name, month: month) do |r|
          r.count = 0
        end
      rescue ActiveRecord::RecordNotUnique, SQLite3::BusyException
        # Concorrente acabou de criar a linha entre o nosso find e o create.
        # `retry` re-executa o bloco begin..rescue; o find_or_create_by vai
        # agora encontrar a row já criada.
        rec = find_by(api_name: api_name, month: month) || retry
      end

      rec.with_lock do
        if origin != :discord
          # MCP/legado param no `mcp_limit = ceiling - bot_floor_size(ceiling)`.
          # Concretamente: ceiling=100 → 95; ceiling=10 → 10; ceiling=1 → 1.
          # `bot_floor_size(ceiling)=0` para tetos 1-19 (floor(0.05..0.95)=0),
          # então `mcp_limit = ceiling` nesses casos — MCP usa o teto inteiro,
          # não há "reserva de piso" porque o piso é zero. Discord, por sua
          # vez, sempre olha `count < ceiling` (teto único puro) — trava
          # única, sem overage.
          mcp_limit = ceiling - bot_floor_size(ceiling)
          if rec.count >= mcp_limit
            # MCP/legado atingiu o limite (95% com teto grande, ou o teto
            # inteiro com teto pequeno). Reserva do piso é exclusiva do bot.
            return false
          end
          # Cabe no teto geral E no limite MCP — reserva normal.
          rec.increment!(:count)
          column = ORIGIN_COUNTER_COLUMN[origin]
          rec.increment!(column) if column
          return true
        end

        # origin == :discord: teto único puro. count NUNCA passa de ceiling
        # — sem overage. O "piso" do bot é a ÚLTIMA fatia antes do teto
        # (96–100 quando ceiling=100, ou 1 quando ceiling=1-2 com piso=0
        # e teto único já fechado).
        if rec.count >= ceiling
          # Teto fechado — sem reserva possível. Discord não escapa do
          # kill-switch nem da contagem `count` (que é o teto).
          return false
        end

        rec.increment!(:count)
        rec.increment!(:count_discord)
        true
      end
    end
  end

  # `exceeded_with_origin?` — MESMA regra do `reserve_quota!`, sem
  # incrementar. Usado pelo fast-path do router (cascata padrão e
  # specialty_enabled?) para evitar entrar em `attempt` quando a cota já
  # está fechada. Kill-switch (ceiling<=0) bloqueia para TODOS.
  #
  # Diferença importante vs `exceeded?` legado: este método conhece a
  # exceção do piso. `exceeded?` (legado, F3a) só olha count >= ceiling
  # e foi mantido para compatibilidade com testes existentes; o fast-path
  # F3b usa este.
  #
  # @return [Boolean] true se NÃO pode reservar (cota/piso esgotado).
  def self.exceeded_with_origin?(api_name, ceiling:, month: current_month, origin: nil)
    return true if ceiling <= 0

    rec = find_by(api_name: api_name, month: month)
    return false unless rec

    rec.with_lock do
      if origin != :discord
        # MCP/legado: `mcp_limit = ceiling - bot_floor_size(ceiling)`.
        # `bot_floor_size == 0` para tetos 1-19 → `mcp_limit = ceiling`
        # nesses casos. O único cenário em que `mcp_limit == 0` é
        # `ceiling == 0`, e esse já foi bloqueado pelo kill-switch no
        # early-return acima — então `mcp_limit > 0` quando chegamos aqui.
        # Discord, por outro lado, usa o teto único (count < ceiling) —
        # tetos pequenos (1-2) ainda permitem ao bot uma reserva normal
        # dentro do teto.
        mcp_limit = ceiling - bot_floor_size(ceiling)
        return rec.count >= mcp_limit
      end

      # origin == :discord: teto único puro, sem overage.
      rec.count >= ceiling
    end
  end

  # Reverte UM incremento feito por `reserve_quota!`. Noop silencioso se a
  # contagem já está em 0 (não baixa para negativo — protege contra
  # rollback duplicado em caso de retry/HTTP error duplo).
  #
  # F3b: com `origin:`, decrementa também a coluna do contador de origem
  # correspondente (count_discord ou count_mcp). O noop em 0 protege o
  # contador de origem idem. O rollback ESPELHA o reserve: se origin foi
  # passado mas a coluna de origem já está em 0, NÃO decrementa `count`
  # (não havia nada dessa origem para reverter — rollback duplicado).
  #
  # @return [Integer] count resultante após o rollback (ou o valor atual se noop).
  def self.rollback_quota!(api_name, month: current_month, origin: nil)
    return 0 unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    rec = find_by(api_name: api_name, month: month)
    return 0 unless rec

    rec.with_lock do
      column = ORIGIN_COUNTER_COLUMN[origin]
      origin_has_to_revert = column.nil? || rec.public_send(column).positive?

      if origin_has_to_revert
        rec.decrement!(:count) if rec.count.positive?
        rec.decrement!(column) if column && rec.public_send(column).positive?
      end
      rec.count
    end
  end
end
