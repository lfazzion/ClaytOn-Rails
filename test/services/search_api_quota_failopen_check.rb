# frozen_string_literal: true

# Testes de fail-open da cota (SearchApiQuota) em caso de falha de banco/erro.
#
# Ruby puro — sem Rails, sem test_helper. Fora do glob do Rails test runner.
# Roda com:
#   ruby test/services/search_api_quota_failopen_check.rb
#
# Cobertura do contrato fail-open:
# - SearchApiRouter.quota_exceeded? retorna false se SearchApiQuota.exceeded? levantar erro.
# - SearchApiRouter.increment_quota não levanta exceção e retorna nil se SearchApiQuota.increment levantar erro.
# - SearchApiRouter.reserve_quota_or_skip retorna true (fail-open) se SearchApiQuota.reserve_quota!
#   levantar erro (busca segue mesmo com DB fora).
# - SearchApiRouter.rollback_quota_silently NÃO levanta exceção se SearchApiQuota.rollback_quota!
#   levantar erro (busca não derruba por falha de rollback).

require "json"
require "date"

unless defined?(Rails)
  module Rails
  end
end

unless Rails.respond_to?(:logger) && Rails.logger
  def Rails.logger
    @logger ||= Object.new.tap do |l|
      l.define_singleton_method(:info)  { |*| }
      l.define_singleton_method(:warn)  { |*| }
      l.define_singleton_method(:error) { |*| }
    end
  end
end

# Simula ActiveRecord conectado
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      def self.connected?
        true
      end
    end
  end
end

# Simula SearchApiQuota com falhas/erros de banco
unless defined?(SearchApiQuota)
  class SearchApiQuota
    def self.exceeded?(*, **)
      raise StandardError, "DB connection lost"
    end

    def self.increment(*, **)
      raise StandardError, "DB write lock failed"
    end

    # F3a: o caminho vivo do `attempt` usa `reserve_quota!` / `rollback_quota!`,
    # não `exceeded?` / `increment`. Para o check ser fiel ao contrato novo,
    # os envelopes também precisam ser fail-open.
    def self.reserve_quota!(*, **)
      raise StandardError, "DB connection lost (reserve)"
    end

    def self.rollback_quota!(*, **)
      raise StandardError, "DB connection lost (rollback)"
    end
  end
end

require_relative "../../app/services/search_api_router"

passed = 0
failed = 0

# ── 1. quota_exceeded? fail-open retorna false se ocorrer erro ───────────────
begin
  result = SearchApiRouter.quota_exceeded?(:linkup)
  if result == false
    passed += 1
  else
    puts "FAIL: quota_exceeded? esperado false, recebeu #{result.inspect}"
    failed += 1
  end
rescue StandardError => e
  puts "FAIL: quota_exceeded? levantou exceção inesperada: #{e.message}"
  failed += 1
end

# ── 2. increment_quota fail-open não levanta exceção se ocorrer erro ──────────
begin
  result = SearchApiRouter.increment_quota(:linkup)
  if result.nil?
    passed += 1
  else
    puts "FAIL: increment_quota esperado nil, recebeu #{result.inspect}"
    failed += 1
  end
rescue StandardError => e
  puts "FAIL: increment_quota levantou exceção inesperada: #{e.message}"
  failed += 1
end

# ── 3. reserve_quota_or_skip fail-open retorna true se SearchApiQuota.reserve_quota! levantar erro ─
# O envelope do `attempt` (SearchApiRouter.reserve_quota_or_skip) DEVE propagar
# `true` quando o `reserve_quota!` falha — a busca do usuário NÃO pode ser
# bloqueada por erro de banco. Esse é o caminho vivo (F3a) que substituiu
# `exceeded? + increment` legado.
begin
  result = SearchApiRouter.reserve_quota_or_skip(:linkup)
  if result == true
    passed += 1
  else
    puts "FAIL: reserve_quota_or_skip esperado true (fail-open), recebeu #{result.inspect}"
    failed += 1
  end
rescue StandardError => e
  puts "FAIL: reserve_quota_or_skip levantou exceção inesperada: #{e.message}"
  failed += 1
end

# ── 4. rollback_quota_silently fail-open NÃO levanta exceção se SearchApiQuota.rollback_quota! levantar erro ─
# O envelope do rollback (SearchApiRouter.rollback_quota_silently) deve engolir
# erros do `rollback_quota!` — uma busca que JÁ falhou HTTP não pode virar
# exceção por causa do rollback. Esse é o caminho vivo (F3a) que substituiu
# o legado `increment_quota`.
begin
  result = SearchApiRouter.rollback_quota_silently(:linkup)
  # Sem raise e retorno é o que o envelope fizer (nil nesse stub). O importante:
  # não levantou exceção.
  passed += 1
rescue StandardError => e
  puts "FAIL: rollback_quota_silently levantou exceção inesperada: #{e.message}"
  failed += 1
end

# ── 5. Kill-switch do envelope: ceiling=0 + DB explode → quota_exceeded? = true ─
# Defesa em profundidade do `quota_exceeded?` (router, search_api_router.rb:
# linhas do early-return do kill-switch): quando `ceiling <= 0` o envelope
# retorna `true` ANTES de tocar em AR/`SearchApiQuota.exceeded_with_origin?`.
# Isso trava a regressão do contrato no envelope: alguém NÃO pode mover a
# checagem de `ceiling <= 0` para dentro do `rescue` (fail-open) — o kill-switch
# é do plano, não da infra.
#
# Para o teste ser honesto, simulamos AMBOS os cenários adversos:
#   - ENV `SEARCH_API_QUOTA_LINKUP=0`  → `quota_ceiling(:linkup)` retorna 0.
#   - stub `exceeded_with_origin?` levanta erro (DB fora).
# Se a checagem do kill-switch for removida, o `rescue` engoliria o erro e
# retornaria `false` (fail-open) — o teste falharia. Com a checagem intacta,
# o early-return no envelope devolve `true` sem alcançar o `rescue`.
begin
  # Garante a configuração adversária sem contaminar ENV do processo após o teste.
  original_quota = ENV["SEARCH_API_QUOTA_LINKUP"]
  ENV["SEARCH_API_QUOTA_LINKUP"] = "0"

  result = SearchApiRouter.quota_exceeded?(:linkup)
  if result == true
    passed += 1
  else
    puts "FAIL: quota_exceeded? esperado true (kill-switch), recebeu #{result.inspect}"
    failed += 1
  end
rescue StandardError => e
  puts "FAIL: quota_exceeded? com kill-switch levantou exceção inesperada: #{e.message}"
  failed += 1
ensure
  if original_quota.nil?
    ENV.delete("SEARCH_API_QUOTA_LINKUP")
  else
    ENV["SEARCH_API_QUOTA_LINKUP"] = original_quota
  end
end

# ── Resultado ────────────────────────────────────────────────────────────────
puts "\n=== Search API Quota Fail-Open Check ==="
puts "Passed: #{passed}"
puts "Failed: #{failed}"
puts failed.zero? ? "ALL GREEN ✅" : "SOME FAILURES ❌"
exit(failed.zero? ? 0 : 1)
