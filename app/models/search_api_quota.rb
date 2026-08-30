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

  # ── F3a: reserva atômica de quota ──────────────────────────────────────────
  # Funde `exceeded?` + `increment` numa única transação atômica para fechar
  # a janela TOCTOU do E10: dois `with_lock` separados davam espaço para uma
  # thread passar no check e a outra também passar antes do increment gravar.
  #
  # Semântica:
  #   - Abre transação + `with_lock` na linha (api_name, month) (cria se não
  #     existir, com count=0).
  #   - Lê count, compara com ceiling. Se count >= ceiling → retorna false
  #     SEM incrementar. O caller decide o que fazer (pular provedor).
  #   - Senão → increment!(:count), retorna true.
  #
  # Em caso de corrida na criação concorrente (RecordNotUnique entre o
  # find_or_create_by de uma transação e a outra), recupera o registro já
  # criado pela thread rival e re-tenta o lock — análogo ao `increment`
  # legado.
  #
  # @return [Boolean] true se reservou, false se teto atingido.
  def self.reserve_quota!(api_name, ceiling:, month: current_month)
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
          false
        else
          rec.increment!(:count)
          true
        end
      end
    end
  end

  # Reverte UM incremento feito por `reserve_quota!`. Noop silencioso se a
  # contagem já está em 0 (não baixa para negativo — protege contra
  # rollback duplicado em caso de retry/HTTP error duplo).
  #
  # @return [Integer] count resultante após o rollback (ou o valor atual se noop).
  def self.rollback_quota!(api_name, month: current_month)
    return 0 unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    rec = find_by(api_name: api_name, month: month)
    return 0 unless rec

    rec.with_lock do
      if rec.count.positive?
        rec.decrement!(:count)
        rec.count
      else
        rec.count
      end
    end
  end
end
