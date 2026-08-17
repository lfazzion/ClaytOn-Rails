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

# ── Resultado ────────────────────────────────────────────────────────────────
puts "\n=== Search API Quota Fail-Open Check ==="
puts "Passed: #{passed}"
puts "Failed: #{failed}"
puts failed.zero? ? "ALL GREEN ✅" : "SOME FAILURES ❌"
exit(failed.zero? ? 0 : 1)
