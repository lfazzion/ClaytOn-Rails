# frozen_string_literal: true

require "json"
require "time"
require "logger"

# F8 (plano-fase2 D7, 30/08/2026): log estruturado `[WebSearchMetric]` para
# cada busca EXECUTADA (não cache hit). Saída = arquivo dedicado para o rake
# `search:report` parsear sem grep manual no log da app.
#
# Contrato do brief (D5-F8):
#   - Cada busca real escreve 1 linha:
#       "[WebSearchMetric] {<json canônico>}"
#   - JSON tem os campos: ts (ISO8601), origin, provider, type, query_len,
#     results_count, latency_ms, from_cache=false, source (searxng/router),
#     engine, trust_primary, trust_ugc, trust_unknown, unresponsive_count,
#     cost_usd, error.
#   - Cache hit NÃO escreve linha (brief literal: "em cada busca executada
#     (nao cache hit)").
#
# Logger dedicado (não `Rails.logger` da app): para o rake `search:report`
# ler UM arquivo só, sem grep. Quando o logger não está atachado
# (ex.: rake ou contexto sem `attach_logger`), `record` é silencioso
# (fail-open — métrica não derruba a busca).
#
# Decisão de design: o método público é `SearchMetric.record(...)`. A
# assinatura aceita kwargs para forçar chamadas explícitas e evitar
# parâmetros posicionais ambíguos. `from_cache` é SEMPRE `false` na entrada
# (o brief diz: cache hit não emite) — o helper rejeita `from_cache: true`
# como salvaguarda.
class SearchMetric
  # Versão do contrato JSON. Se algum dia o formato precisar mudar,
  # bump para 2 e atualizar o parser do rake com co-existência.
  SCHEMA_VERSION = 1

  class << self
    # Atacha um logger que escreve no IO (StringIO em teste, File em prod).
    # Substitui o logger default da classe.
    def attach_logger(io)
      @logger = build_logger(io)
    end

    # Desatacha (teste). Restaura logger que escreve em /dev/null.
    def detach_logger
      @logger = build_logger(File.open(File::NULL, "w"))
    end

    # Emite 1 linha `[WebSearchMetric]`. Fail-open: erros do logger são
    # engolidos (a busca não pode morrer por causa da métrica).
    #
    # @param origin [Symbol, nil] :discord / :mcp / nil.
    # @param provider [Symbol, nil] provider efetivo (:tavily / :exa /
    #   :linkup / :searxng / nil para type=auto sem fallback).
    # @param type [String] "news"/"entity"/"academic"/"factual"/"code"/"auto".
    # @param query_len [Integer] tamanho da query (após strip).
    # @param results_count [Integer] nº de resultados devolvidos.
    # @param latency_ms [Integer] tempo total do run em ms.
    # @param source [String] "searxng" ou "router" — quem efetivamente serviu.
    # @param engine [String, nil] engine do 1º resultado (SearXNG) ou provider pago.
    # @param cost_usd [Numeric, nil] créditos/centavos da API paga (nil SearXNG).
    # @param trust_primary [Integer] qtd de itens com trust :primary.
    # @param trust_ugc [Integer] qtd de itens com trust :ugc.
    # @param trust_unknown [Integer] qtd de itens com trust :unknown.
    # @param unresponsive_count [Integer] qtd de engines caídas.
    # @param error [String, nil] código de erro (nil = sucesso).
    # @param from_cache [Boolean] SEMPRE false. `true` é rejeitado (defesa).
    def record(
      origin:,
      provider:,
      type:,
      query_len:,
      results_count:,
      latency_ms:,
      source:,
      engine: "",
      cost_usd: nil,
      trust_primary: 0,
      trust_ugc: 0,
      trust_unknown: 0,
      unresponsive_count: 0,
      error: nil,
      from_cache: false
    )
      # Defesa em profundidade: cache hit nunca pode emitir.
      return if from_cache

      payload = build_payload(
        origin: origin,
        provider: provider,
        type: type,
        query_len: query_len,
        results_count: results_count,
        latency_ms: latency_ms,
        source: source,
        engine: engine,
        cost_usd: cost_usd,
        trust_primary: trust_primary,
        trust_ugc: trust_ugc,
        trust_unknown: trust_unknown,
        unresponsive_count: unresponsive_count,
        error: error
      )

      emit(payload)
    rescue StandardError
      # Fail-open: métrica nunca derruba a busca.
    end

    # Caminho de leitura do rake: retorna IO onde as linhas são emitidas.
    # Default: `log/search_metrics.log` no root do app. Em teste/dev, pode
    # ser sobrescrito por `attach_logger(io)`.
    def default_log_path
      defined?(Rails) && Rails.respond_to?(:root) && Rails.root ?
        Rails.root.join("log", "search_metrics.log") :
        File.expand_path("../../log/search_metrics.log", __dir__)
    end

    private

    def build_logger(io)
      logger = ::Logger.new(io)
      logger.level = ::Logger::INFO
      logger.formatter = proc { |_sev, _ts, _prog, msg| "#{msg}\n" }
      logger
    end

    def build_payload(
      origin:, provider:, type:, query_len:, results_count:,
      latency_ms:, source:, engine:, cost_usd:,
      trust_primary:, trust_ugc:, trust_unknown:,
      unresponsive_count:, error:
    )
      {
        v: SCHEMA_VERSION,
        ts: Time.now.utc.iso8601(3),
        origin: stringify_origin(origin),
        provider: stringify_provider(provider),
        type: type.to_s,
        query_len: query_len.to_i,
        results_count: results_count.to_i,
        latency_ms: latency_ms.to_i,
        source: source.to_s,
        engine: engine.to_s,
        cost_usd: cost_usd,
        trust_primary: trust_primary.to_i,
        trust_ugc: trust_ugc.to_i,
        trust_unknown: trust_unknown.to_i,
        unresponsive_count: unresponsive_count.to_i,
        from_cache: false,
        error: error
      }.compact
    end

    # `compact` remove chaves com valor `nil` para manter o JSON magro
    # (cost_usd nil SearXNG → fora do JSON). ATENÇÃO: `from_cache: false`
    # NUNCA é removido — está sempre presente (sentinela do contrato).
    def emit(payload)
      payload[:from_cache] = false
      json = JSON.generate(payload)
      logger.info("[WebSearchMetric] #{json}")
    end

    def logger
      @logger ||= build_logger(File.open(default_log_path, "a"))
    end

    def stringify_origin(origin)
      case origin
      when :discord then "discord"
      when :mcp then "mcp"
      else nil
      end
    end

    # nil (type=auto sem fallback) → "searxng" porque o caminho é o SearXNG
    # em produção. Marcamos com rótulo explícito para a tabela do report.
    def stringify_provider(provider)
      return "searxng" if provider.nil?

      provider.to_s
    end
  end
end