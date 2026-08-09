# frozen_string_literal: true

require "net/http"
require "json"
require "digest"
require "set"

class WebSearchTool < ToolBase
  description "Pesquisa web em tempo real via SearXNG. Use para fatos atuais, notícias, " \
              "preços, eventos, documentação externa — APENAS quando as tools internas não cobrirem. " \
              "NÃO indexa permalink de YouTube, Reddit nem X/Twitter (vídeo, thread, post, timeline) " \
              "— para ler dentro dessas plataformas use platform_search. " \
              "Passe time_range='day'|'week'|'month'|'year' para perguntas sobre 'último', 'agora', " \
              "'hoje', 'esta semana' (filtra por recência; senão buscador prioriza relevância e pode " \
              "devolver artigo antigo com bom SEO)."

  param :query, type: :string,  desc: "Consulta de busca (1-200 chars, não pode ser vazia)", required: true
  param :limit, type: :integer, desc: "Número máximo de resultados (1-10, padrão 5)", required: false
  param :time_range, type: :string,
        desc: "Filtro de recência: day|week|month|year. Use para último/agora/hoje/esta-semana.",
        required: false

  BASE_URL          = ENV.fetch("SEARXNG_URL", "http://searxng:8080/search")
  CONTENT_MAX_CHARS = 400
  CACHE_TTL         = 15.minutes
  # Um tropeço de um segundo não pode cegar o bot por 15 minutos: busca vazia pode ser
  # engine acordando, e o custo de repetir contra o SearXNG local é desprezível. O minuto
  # existe só para absorver rajada de tool calls do mesmo turno de conversa.
  EMPTY_CACHE_TTL   = 1.minute
  ALLOWED_TIME_RANGES = %w[day week month year].freeze

  # Sem este parametro o SearXNG busca so em `general`, e metade dos engines
  # registrados mora em `it` (stackoverflow, github, askubuntu, superuser,
  # hackernews, mdn, npm, crates.io, docker hub) ou `science` (arxiv, pubmed).
  # Eles estavam no catalogo e nunca disparavam — o mesmo tipo de buraco calado
  # que deixou `google` na lista por meses sem existir de fato.
  # Medido em 05/08/2026, query "ActiveRecord ConnectionNotEstablished":
  # `general` -> 13 resultados de 2 engines; `general,it` -> 24 de 5 engines.
  # A guarda de relevancia abaixo e o que torna essa largura segura: engine de
  # nicho respondendo fora de contexto e descartado por score, nao entregue.
  CATEGORIES = "general,it,science"

  # Operadores que só o engine general entende. Mandá-los para `it`/`science` faz
  # o engine de nicho responder à palavra solta: medido em 06/08, `site:x.com
  # EXM7777` trouxe 10 resultados do Docker Hub e 10 da MDN, aprovados pela guarda
  # porque o título deles contém "Site". UMA lista, usada nos dois lugares — duas
  # divergiriam.
  DOMAIN_OPERATORS  = %w[site inurl intitle filetype].freeze
  OPERATOR_PATTERN  = /(?:\A|\s)(?:#{DOMAIN_OPERATORS.join("|")}):/i
  NARROW_CATEGORIES = "general"

  def run(query:, limit: 5, time_range: nil)
    q = query.to_s.strip
    return error("query vazia") if q.empty?
    return error("query muito longa") if q.length > 200

    limit = clamp(limit, 1, 10)
    tr = ALLOWED_TIME_RANGES.include?(time_range.to_s) ? time_range.to_s : nil
    cache_key = "web_search:#{Digest::SHA256.hexdigest("#{q}|#{limit}|#{tr}")}"
    cached = Rails.cache.read(cache_key)
    # `nil`, não `[]`: acerto de cache não mediu engine nenhum, e um `[]` aqui
    # afirmaria "nenhum caiu". Métrica ausente é nil, nunca zero.
    return success(cached).merge(unresponsive: nil) if cached

    payload = fetch(q, limit, tr)
    return error("busca indisponível") if payload.nil?

    results     = payload[:results]
    unreachable = payload[:unresponsive]

    # Lista vazia COM engine caída não é "não achei nada" — é "a busca não aconteceu".
    # Sem essa distinção o modelo conclui que o fato não existe. Erro não é cacheado:
    # a próxima tentativa pode cair num engine vivo.
    if results.empty?
      if unreachable.any?
        Rails.logger.warn "[WebSearchTool] busca sem resultados com engines fora do ar: #{unreachable.join(', ')}"
        return error("busca não aconteceu: engines fora do ar (#{unreachable.join(', ')}) e nenhum " \
                     "resultado devolvido — tente de novo em alguns minutos")
      end

      Rails.cache.write(cache_key, [], expires_in: EMPTY_CACHE_TTL)
      return success([]).merge(unresponsive: unreachable)
    end

    verdict = RelevanceGuard.new(q).judge(results)
    if verdict.poisoned?
      Rails.logger.warn "[WebSearchTool] busca envenenada para #{q.inspect}: " \
                        "#{verdict.approved.size}/#{verdict.judged_count} aprovados"
      return error("resultados irrelevantes: só #{verdict.approved.size} de #{verdict.judged_count} " \
                   "resultados cobriram os termos de #{q.inspect} — o buscador respondeu outra pergunta, " \
                   "reformule a query")
    end

    data = verdict.approved.first(limit)
    Rails.cache.write(cache_key, data, expires_in: CACHE_TTL)
    success(data).merge(unresponsive: unreachable)
  end

  private

  def categories_for(query)
    query.to_s.match?(OPERATOR_PATTERN) ? NARROW_CATEGORIES : CATEGORIES
  end

  # A guarda julga uma janela maior que o `limit` porque o lixo costuma vir empilhado no
  # topo (era o caso do bing): olhar só os 5 primeiros faria a fração de aprovados medir
  # o próprio envenenamento em vez de detectá-lo. O piso de 10 vale para limit pequeno.
  def guard_window(limit)
    [limit * 2, 10].max
  end

  def fetch(query, limit, time_range)
    uri = URI(BASE_URL)
    params = { q: query, format: "json", safesearch: 1, language: "pt-BR", categories: categories_for(query) }
    params[:time_range] = time_range if time_range
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 20

    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/json"

    response = http.request(req)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "[WebSearchTool] HTTP #{response.code}"
      return nil
    end

    body = JSON.parse(response.body)
    results = body.fetch("results", []).first(guard_window(limit)).map do |r|
      {
        title:   r["title"],
        url:     r["url"],
        content: truncate(r["content"]),
        engine:  r["engine"]
      }
    end

    { results: results, unresponsive: unresponsive_names(body) }
  rescue StandardError => e
    Rails.logger.error "[WebSearchTool] #{e.class}: #{e.message}"
    nil
  end

  # O SearXNG serializa cada engine caída como par ["nome", "motivo"]; versões antigas
  # mandam só a string. Aceita as duas formas para não perder o sinal num upgrade.
  def unresponsive_names(body)
    Array(body["unresponsive_engines"]).filter_map do |entry|
      name = entry.is_a?(Array) ? entry.first : entry
      name.to_s.strip
    end.reject(&:empty?).uniq
  end

  def truncate(text)
    return nil if text.nil?

    text.length > CONTENT_MAX_CHARS ? "#{text[0, CONTENT_MAX_CHARS]}…" : text
  end

  # Guarda lexical de relevância — Ruby puro, sem rede e sem modelo (decisão do dono).
  #
  # Motivo: em 05/08/2026 a query "reddit ruby performance" voltou com páginas de login do
  # Roblox e cartas Pokémon (bug conhecido do bing, issue #4964 do SearXNG) e a tool as
  # devolveu com status de sucesso — o bot respondeu com confiança sobre a coisa errada.
  # O bing já saiu do conjunto de engines, mas nada no código sabia separar bom de lixo.
  class RelevanceGuard
    # Fração dos termos significativos da query que precisa aparecer em título+snippet.
    # 0.3 aceita 1 de 3 termos (0.33): numa query de 3 palavras, um resultado que cita
    # apenas "ruby" ainda pode ser a resposta certa. Derrubar resultado bom é pior que
    # deixar passar um mediano — o teto de qualidade quem dá é a fração agregada abaixo.
    RELEVANCE_FLOOR = 0.3

    # Abaixo desta fração de aprovados a busca INTEIRA é considerada envenenada. No caso
    # medido do Roblox a fração era 0 (nenhum dos 5 primeiros citava qualquer termo);
    # 0.25 fica bem acima disso e ainda deixa passar a busca em que só 1 de 4 casou.
    MIN_APPROVED_RATIO = 0.25

    # Com menos de 3 resultados não há amostra para julgar envenenamento — a fração vira
    # 0 ou 1 pelo acaso de um único item. Nesse caso a guarda se cala e devolve tudo:
    # derrubar o único resultado da busca custa mais do que o lixo que ela evitaria.
    MIN_RESULTS_TO_JUDGE = 3

    # Query de um termo só é tudo-ou-nada: 1 termo ausente = score 0 = busca reprovada.
    # "bitcoin" respondida por "Cotação do BTC hoje" seria descartada. Com menos de 2
    # termos significativos a guarda desliga.
    MIN_QUERY_TERMS = 2

    # Termo curto casa só por igualdade; de 4 caracteres em diante vale prefixo COMPARTILHADO.
    # Prefixo estrito (uma palavra começar com a outra) não cobre flexão portuguesa: "eleicao"
    # não é prefixo de "eleicoes" — o plural de -ção diverge no meio da palavra — e "ganhou"
    # não casa com "ganha". Medido ao vivo em 05/08/2026 contra o SearXNG desta máquina: na
    # query "quem ganhou a eleicao na Argentina" a manchete correta em 1º lugar (G1, "Partido
    # de Milei ... vence eleições legislativas na Argentina") ficava com 1 de 4 termos (0.25),
    # abaixo do piso, e era descartada; numa das coletas só 2 de 10 passaram e a busca INTEIRA
    # virou erro. O prefixo compartilhado casa "eleicao"/"eleicoes", "ganhou"/"ganha" e
    # "cache"/"caching", e continua não casando "reddit"/"roblox" nem "performance"/"platform"
    # (o caso Roblox segue reprovado).
    PREFIX_MATCH_MIN_CHARS = 4

    # O prefixo comum também precisa cobrir a maior parte da palavra mais curta, senão
    # "eleicao" casaria com "eleitoral" (4 de 7 é pouco: 4 < 0.6 * 7).
    SHARED_PREFIX_MIN_RATIO = 0.6

    # Termo de 1-2 letras não discrimina nada ("no", "os", "ia") e infla o denominador.
    # Exceção para quem tem dígito: "5g", "4k", "gpt5" são termos de busca de verdade.
    TERM_MIN_CHARS = 3

    STOPWORDS = %w[
      a o e as os um uma uns umas de do da dos das em no na nos nas ao aos por para com sem sob sobre
      entre que qual quais quando onde como porque pois mas ou se nao sim este esta esse essa isso isto
      aquele aquela seu sua meu minha nosso nossa ser sao foi era tem ter mais menos muito pouco tudo
      todo toda todos todas ja ainda depois antes pelo pela pelos pelas
      the an of in on at to for and or is are was were be by with from as it this that these those
      how what when where why which who i you your my our their there here about into over
    ].to_set.freeze

    Verdict = Struct.new(:approved, :judged_count, :poisoned, keyword_init: true) do
      def poisoned? = poisoned
    end

    def initialize(query)
      @terms = self.class.significant_terms(query)
    end

    def judge(items)
      unless judgeable?(items.size)
        # Métrica não medida é nil, nunca 0: um 0.0 aqui seria lido pelo modelo como
        # "resultado irrelevante", quando o que houve foi guarda desligada.
        return Verdict.new(approved: items.map { |i| i.merge(relevance: nil) },
                           judged_count: items.size, poisoned: false)
      end

      scored   = items.map { |i| i.merge(relevance: score(i)) }
      approved = scored.select { |i| i[:relevance] >= RELEVANCE_FLOOR }

      Verdict.new(approved: approved, judged_count: scored.size,
                  poisoned: approved.size.to_f / scored.size < MIN_APPROVED_RATIO)
    end

    # Acento é obrigatório aqui: as queries são em português e o título do resultado pode
    # vir sem acento (ou o contrário). NFD separa a marca diacrítica da letra base, e o
    # gsub de \p{Mn} a remove. O split por [^a-z0-9] também zera título em alfabeto não
    # latino — que foi exatamente um dos lixos medidos (resultado em chinês).
    def self.tokenize(text)
      text.to_s
          .unicode_normalize(:nfd)
          .gsub(/\p{Mn}/, "")
          .downcase
          .split(/[^a-z0-9]+/)
          .reject(&:empty?)
    end

    # Operador de domínio só conta como operador COM os dois-pontos — o mesmo
    # critério de `categories_for` (linhas 42-45 prometem uso simétrico da
    # lista). Palavra solta "site"/"inurl" numa query é termo de busca; derrubá-la
    # aqui sem estreitar a categoria faria a guarda julgar com um termo a menos.
    def self.significant_terms(query)
      operadores = query.to_s.match?(OPERATOR_PATTERN) ? DOMAIN_OPERATORS : []
      tokenize(query).uniq.reject do |term|
        STOPWORDS.include?(term) ||
          operadores.include?(term) ||
          (term.length < TERM_MIN_CHARS && !term.match?(/\d/))
      end
    end

    private

    def judgeable?(sample_size)
      @terms.size >= MIN_QUERY_TERMS && sample_size >= MIN_RESULTS_TO_JUDGE
    end

    # Pontua o snippet JÁ truncado em 400 chars, que é exatamente o texto que o modelo vai
    # ler. Julgar um texto maior que o entregue aprovaria resultado por evidência invisível.
    def score(item)
      doc = self.class.tokenize("#{item[:title]} #{item[:content]}")
      hits = @terms.count { |term| doc.any? { |word| match?(term, word) } }
      (hits.to_f / @terms.size).round(2)
    end

    def match?(term, word)
      return true if term == word
      return false if term.length < PREFIX_MATCH_MIN_CHARS || word.length < PREFIX_MATCH_MIN_CHARS

      shared = shared_prefix_length(term, word)
      shared >= PREFIX_MATCH_MIN_CHARS &&
        shared >= [term.length, word.length].min * SHARED_PREFIX_MIN_RATIO
    end

    def shared_prefix_length(one, other)
      limit = [one.length, other.length].min
      i = 0
      i += 1 while i < limit && one[i] == other[i]
      i
    end
  end
end
