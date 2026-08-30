# frozen_string_literal: true

require "digest"

# Cache unificado da busca web (F3c do plano-fase2).
#
# Fonte canônica dos números: plano-fase2 D2 (linhas 37-47 de
# `.hermes-lane/plano-fase2.md`). Replicada verbatim — não inventar.
#
# Por que este serviço existe (e não cache inline em `WebSearchTool`):
#   1. Tabela TTL precisa ser TESTÁVEL direto, sem stub de WebSearchTool.
#   2. Key precisa ser PURA: provider+type+query+limit+time_range. Embutir
#      isso em `web_search_tools.rb` misturaria a regra com 7 caminhos
#      diferentes (SearXNG ok, fallback ok, fallback miss, SearXNG erro,
#      SearXNG vazio, fallback vazio, type=code, type=auto).
#   3. Fan-in: tudo que escreve cache passa por aqui — fácil de auditar
#      e fácil de testar que "cache vazio" e "cache erro" NÃO gravam.
#
# Decisões F3c documentadas (consultadas com o brief e o plano):
#
# (a) TTL por tipo (ver `ttl_for`). Plano-fase2 D2 tabela exata:
#       news=600 factual=10800 entity/academic=86400 code/auto=900 vazio=60.
#     `time_range` aperta nunca alarga:
#       day=600 week=3600 month=10800 year=86400.
#     TTL = min(tipo, time_range). Piso 60s (a entrada "vazio" do plano é
#     o limite mínimo — sem tipo e sem time_range, TTL nunca pode ser 0).
#
# (b) Cache vazio NÃO grava (decisão do brief, item 5). O código antigo
#     em `web_search_tools.rb` gravava `[]` com `EMPTY_CACHE_TTL=1.minute`
#     para absorver rajada do mesmo turno — o serviço `write` rejeita
#     `payload=[]` ou `payload=nil` para não servir "não achei nada"
#     congelado. A WEBSEARCH_TOOL ainda pode absorver rajada via Rails.cache
#     de forma separada (chave de debounce, não do `SearchApiCache`); se
#     F4 ou F5 precisar reintroduzir isso, é em outra camada.
#
# (c) Cache de erro NÃO grava (mantido do código atual). O brief pediu
#     "NUNCA cachear erro/falha; cachear só sucesso". `write` rejeita
#     `payload` Hash cujo campo `ok` seja ausente, `nil` ou `false` —
#     i.e., "sem ok: true explícito" = erro conservador. A tool hoje
#     manda lista de hashes (cache de conteúdo); o envelope `{ok: false,
#     results: []}` é a forma que o router sinaliza falha, e o
#     `{ok: true, results: [...]}` que ele sinaliza sucesso também cai
#     na malha conservadora por não ser uma lista. Esse é o tradeoff
#     do fail-closed conservador: qualquer formato não-lista que não
#     traga `ok: true` explícito é descartado.
#
# (f) Fail-open do STORE: `read`/`write` engolem `StandardError` do
#     `Rails.cache` (Solid Cache lock/corrupt, FileStore IO, Memcached
#     down). `read` devolve `nil`, `write` devolve `false` — cache NUNCA
#     bloqueia a busca. Padrão de referência: `search_api_router.rb:405-411`.
#     Importante porque `WebSearchTool#run` chama esses métodos no caminho
#     quente — um erro de store propagado derruba a busca inteira e viola
#     o contrato "cache NUNCA bloqueia a busca" (decisão F3c).
#
# (d) Key inclui `provider` para NÃO cruzar hit SearXNG vs pago (decisão
#     do plano D2: "Key inclui `provider` **e** `type`"). Provider nil
#     (type=auto, fluxo legado) rotula como "searxng" — nesse modo o
#     caminho é sempre SearXNG primeiro, o risco de cruzamento é nulo.
#
# (e) type=auto: `provider` real é decidido pelo `SearchApiRouter.call`
#     DENTRO do attempt (a tool não sabe qual serviu). Decisão F3c:
#     cache fica na tool por (query|tr|type=auto) com TTL=900s
#     (code/auto=15min do plano), mesmo que o provider efetivo varie
#     entre chamadas (Tavily hoje, Exa amanhã). O risco aceito é servir
#     um hit "pago" para uma query que o próximo caller pagaria na API
#     diferente — vale o TTL de 15min pelo tradeoff. Se F4 quiser
#     refinar (key inclui provider efetivo após o fallback), é outra
#     fatia.
class SearchApiCache
  # ── Tabela TTL do plano-fase2 D2 ──────────────────────────────────────────
  # Verbatim. Não trocar sem ler o plano.
  TYPE_TTL = {
    "news"     => 10 * 60,         # 600s
    "factual"  => 3 * 60 * 60,     # 10_800s
    "entity"   => 24 * 60 * 60,    # 86_400s
    "academic" => 24 * 60 * 60,    # 86_400s
    "code"     => 15 * 60,         # 900s
    "auto"     => 15 * 60          # 900s
  }.freeze

  TIME_RANGE_TTL = {
    "day"   => 10 * 60,         # 600s
    "week"  => 60 * 60,         # 3_600s
    "month" => 3 * 60 * 60,     # 10_800s
    "year"  => 24 * 60 * 60     # 86_400s
  }.freeze

  # Piso da tabela plano-fase2 D2: "vazio 1 min (caso limiar)". É o TTL
  # de quando o tipo é nil/fora do enum. Como piso, nunca pode ser 0.
  FLOOR_TTL = 60

  # ── API pública ────────────────────────────────────────────────────────────

  # TTL final para uma query, considerando tipo e time_range.
  # Replicação VERBATIM da tabela do plano-fase2 D2.
  #
  # @param type [String, nil] tipo da query (news/factual/entity/academic/code/auto)
  # @param time_range [String, nil] recorte de tempo (day/week/month/year)
  # @return [Integer] TTL em segundos (sempre > 0)
  def self.ttl_for(type: nil, time_range: nil)
    # "vazio 1 min" da tabela é uma entrada válida da TABELA DE TIPOS
    # (não ausência), equivalente ao TTL de uma chave sem classificação.
    # Tratar como nil faria min(nil, time_range) => time_range, crescendo
    # de 60s para 600s quando time_range=day — violaria a tabela.
    type_ttl = TYPE_TTL.fetch(type.to_s, FLOOR_TTL)
    tr_ttl   = TIME_RANGE_TTL[time_range.to_s] # nil quando ausente (não aperta)

    [type_ttl, tr_ttl].compact.min
  end

  # Key de cache. Inclui provider+type para não cruzar hit SearXNG vs pago.
  #
  # provider nil (type=auto) rotula como "searxng" — o caminho é o mesmo
  # nesse modo (ver comentário da classe).
  #
  # @return [String] "search:<provider_label>:<sha1_hex>"
  def self.key_for(query:, limit:, time_range:, type:, provider:)
    label = provider_label(provider)
    payload = [query.to_s, limit.to_i, time_range.to_s, type.to_s].join("|")
    digest = Digest::SHA1.hexdigest(payload)
    "search:#{label}:#{digest}"
  end

  # Lê do cache. Retorna o payload ou nil se ausente/expirado.
  # Fail-open: erro de `Rails.cache` (Solid Cache lock, FileStore IO,
  # Memcached down) é logado e retorna nil — cache NUNCA bloqueia a busca.
  def self.read(query:, limit:, time_range:, type:, provider:)
    key = key_for(query: query, limit: limit, time_range: time_range, type: type, provider: provider)
    Rails.cache.read(key)
  rescue StandardError => e
    Rails.logger.warn("[SearchApiCache] read falhou para key=#{key}: #{e.class}: #{e.message}")
    nil
  end

  # Grava no cache SOMENTE sucesso (lista não vazia; hash com `ok: true`
  # explícito). Retorna true se gravou, false se rejeitado (vazio / nil /
  # erro / falha do store).
  #
  # Fail-open do STORE: `Rails.cache.write` pode levantar (Solid Cache lock,
  # corrupt file, Memcached down). O envelope engole e devolve `false` —
  # a busca segue sem cache, nunca propaga exceção de infraestrutura para
  # `WebSearchTool#run`.
  #
  # A WEBSEARCH_TOOL chama isso com o array normalizado (lista de hashes
  # {title:, url:, content:, engine:}). O router, se chamado em algum ponto
  # futuro, mandaria {results:, engine:} — mas como o cache mora na tool
  # (e não no router), esse caso não acontece hoje.
  def self.write(query:, limit:, time_range:, type:, provider:, payload:)
    return false if blank_payload?(payload)
    return false if error_envelope?(payload)

    ttl = ttl_for(type: type, time_range: time_range)
    key = key_for(query: query, limit: limit, time_range: time_range, type: type, provider: provider)
    Rails.cache.write(key, payload, expires_in: ttl)
    true
  rescue StandardError => e
    Rails.logger.warn("[SearchApiCache] write falhou para key=#{key}: #{e.class}: #{e.message}")
    false
  end

  # ── Helpers internos ───────────────────────────────────────────────────────
  # @return [String] rótulo do provider para a key. nil → "searxng".
  def self.provider_label(provider)
    return "searxng" if provider.nil?

    provider.to_s
  end

  # payload vazio ou nil → não grava (decisão F3c item 5 do brief).
  def self.blank_payload?(payload)
    payload.nil? || (payload.respond_to?(:empty?) && payload.empty?)
  end

  # envelope de erro (Hash sem `ok: true` explícito) → não grava
  # (decisão F3c item 1; alinhar com o comentário (c) da classe).
  # Cobre `{ok: false}`, `{ok: nil}` e `{ok: ausente}` — tudo que não
  # traga `ok: true` explícito é tratado como erro conservador.
  # Lista de hashes (cache de conteúdo da tool) não é Hash e passa.
  def self.error_envelope?(payload)
    return false unless payload.is_a?(Hash)

    payload[:ok] != true
  end
end
