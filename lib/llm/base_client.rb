# frozen_string_literal: true

module Llm
  class BaseClient
    class QuotaExceededError < StandardError; end

    def model_id
      raise NotImplementedError, "#{self.class}#model_id não implementado"
    end

    def daily_quota_key
      raise NotImplementedError, "#{self.class}#daily_quota_key não implementado"
    end

    def max_daily_requests
      raise NotImplementedError, "#{self.class}#max_daily_requests não implementado"
    end

    def complete(prompt, system: nil, tools: [])
      reserve_quota!

      begin
        chat = RubyLLM.chat(model: model_id)
        chat.with_instructions(system) if system
        tools.each { |t| chat.with_tool(t) }
      rescue QuotaExceededError
        # levantada dentro de reserve_quota! antes de qualquer chat — nada a reverter
        raise
      rescue StandardError
        # Falha na PREPARAÇÃO (antes do envio ao provedor): a quota externa não
        # foi tocada, reverte a reserva local (P1 do sol, 13/08).
        rollback_quota!
        raise
      end

      # A partir daqui a requisição SAI para o provedor: timeout, parse error e
      # qualquer falha do chat.ask NÃO revertem a quota — o provedor já contou
      # a chamada mesmo sem resposta útil.
      Rails.logger.info "[#{self.class.name}] Requisição enviada (model: #{model_id})"
      chat.ask(prompt)
    rescue QuotaExceededError
      raise
    end

    private

    # Atômico: usa Rails.cache.increment como única operação de reserva.
    # Nenhum read-modify-write — o incremento é uma operação CAS do backend.
    def reserve_quota!
      cache_key = daily_cache_key
      max = max_daily_requests

      # Primeira tentativa: criação atômica da chave (unless_exist) + incremento.
      # Se a chave já existia, increment retorna nil e fazemos uma nova tentativa
      # sem unless_exist — ainda assim atômica.
      count = Rails.cache.increment(cache_key, 1, expires_in: 26.hours, unless_exist: true)
      count = Rails.cache.increment(cache_key, 1, expires_in: 26.hours) if count.nil?

      if count && count > max
        rollback_quota!
        Rails.logger.warn "[#{self.class.name}] Quota diária atingida: #{count}/#{max}"
        raise QuotaExceededError, "#{self.class.name} excedeu #{max} requests/dia"
      end

      count
    end

    # Reverte atomicamente o incremento feito por reserve_quota! quando a
    # requisição falha antes de completar. Garante que a quota só seja
    # consumida por requisições que realmente atingiram o provedor.
    def rollback_quota!
      cache_key = daily_cache_key
      Rails.cache.decrement(cache_key, 1, expires_in: 26.hours)
    end

    def daily_cache_key
      "#{daily_quota_key}:#{Date.current.iso8601}"
    end
  end
end
