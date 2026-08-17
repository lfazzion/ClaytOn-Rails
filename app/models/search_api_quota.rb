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
end
