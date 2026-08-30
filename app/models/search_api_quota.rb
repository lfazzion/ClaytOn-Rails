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
  # Em caso de corrida no find_or_create_by (RecordNotUnique), recupera o
  # registro criado concorrentemente sem perder sucesso.
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
    rescue ActiveRecord::RecordNotUnique
      find_by(api_name: api_name, month: month) || retry
    end
    rec.with_lock do
      rec.increment!(:count)
    end
  end

  # ── F3b D1: piso 5% pro bot + métricas por origem ────────────────────────────
  # Constantes da regra do plano-fase2 D1/F3-quota (linha 31). O piso é uma
  # EXCEÇÃO do teto único, não um segundo teto: o `count` continua sendo o
  # teto; `count_discord` é um CONTADOR de observabilidade que sustenta a
  # exceção. Discorda do brief? Ver `plano-fase2.md` seção D1 — esse é o
  # contrato canônico. O brief reconhece que o plano é a fonte de verdade.
  FLOOR_RATIO = 0.05
  private_constant :FLOOR_RATIO

  # Coluna que recebe o incremento do contador de origem (nenhuma se nil).
  # Símbolo (não string) para casar com o `increment!` do AR — strings não
  # funcionam como argumento de `increment!`.
  ORIGIN_COUNTER_COLUMN = {
    discord: :count_discord,
    mcp:     :count_mcp,
    nil:     nil
  }.freeze
  private_constant :ORIGIN_COUNTER_COLUMN

  # Tamanho do piso: `max(1, floor(ceiling * 0.05))`. Pelo menos 1 para
  # não zerar o piso com tetos muito pequenos. `ceiling=100 → 5`,
  # `ceiling=5 → 1`, `ceiling=1 → 0 → max(1, 0) = 1`.
  def self.bot_floor_size(ceiling)
    [1, (ceiling.to_i * FLOOR_RATIO).floor].max
  end
  private_class_method :bot_floor_size

  # ── F3a: reserva atômica de quota ──────────────────────────────────────────
  # Funde `exceeded?` + `increment` numa única transação atômica para fechar
  # a janela TOCTOU do E10: dois `with_lock` separados davam espaço para uma
  # thread passar no check e a outra também passar antes do increment gravar.
  #
  # Semântica:
  #   - Abre transação + `with_lock` na linha (api_name, month) (cria se não
  #     existir, com count=0).
  #   - Lê count, compara com ceiling. Se count >= ceiling → verifica a
  #     EXCEÇÃO DO PISO (F3b): só `origin == :discord` com
  #     `count_discord < bot_floor_size(ceiling)` ainda reserva. Senão
  #     retorna false SEM incrementar.
  #   - Caso normal (count < ceiling) → increment!(:count), e se origin
  #     não for nil, increment!(ORIGIN_COUNTER_COLUMN[origin]).
  #   - Retorna true.
  #
  # Em caso de corrida na criação concorrente (RecordNotUnique entre o
  # find_or_create_by de uma transação e a outra), recupera o registro já
  # criado pela thread rival e re-tenta o lock — análogo ao `increment`
  # legado.
  #
  # @param origin [:discord, :mcp, nil] nil = chamada "sem origem" (legado)
  # @return [Boolean] true se reservou, false se teto/piso atingido.
  def self.reserve_quota!(api_name, ceiling:, month: current_month, origin: nil)
    transaction do
      rec = nil
      begin
        rec = find_or_create_by(api_name: api_name, month: month) do |r|
          r.count = 0
        end
      rescue ActiveRecord::RecordNotUnique
        # Concorrente acabou de criar a linha entre o nosso find e o create.
        # `retry` re-executa o bloco begin..rescue; o find_or_create_by vai
        # agora encontrar a row já criada.
        rec = find_by(api_name: api_name, month: month) || retry
      end

      rec.with_lock do
        if rec.count >= ceiling
          # Teto principal fechado. Tenta a EXCEÇÃO DO PISO (F3b):
          # só `origin == :discord` com count_discord abaixo do piso.
          if origin == :discord && rec.count_discord < bot_floor_size(ceiling)
            # Reservou do piso. `count` sobe junto (o teto principal
            # também reflete o gasto — é o "count" que o orçamento vê);
            # `count_discord` é a métrica que conta quantas dessas
            # reservas vieram do bot. Sem o count, dashboards leriam
            # só 95 e achariam que o bot não usou a API.
            rec.increment!(:count)
            rec.increment!(:count_discord)
            true
          else
            false
          end
        else
          rec.increment!(:count)
          column = ORIGIN_COUNTER_COLUMN[origin]
          rec.increment!(column) if column
          true
        end
      end
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
