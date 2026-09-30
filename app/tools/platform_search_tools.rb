# frozen_string_literal: true

require_relative "../../lib/fetcher/channels/youtube"
require_relative "../../lib/fetcher/channels/reddit"
require_relative "../../lib/fetcher/channels/x"
require_relative "../../lib/fetcher/channels/hackernews"
require_relative "../../lib/fetcher/channels/github"
require_relative "../../lib/fetcher/channels/polymarket"

# Leitura DENTRO da plataforma, pelo caminho nativo dela.
#
# Existe porque buscador web não indexa permalink de plataforma. Medido em
# 05/08/2026 no SearXNG já consertado: `site:reddit.com` devolveu ZERO, e
# nenhum dos engines (duckduckgo, google cse, seznam, brave) trouxe link de
# thread ou de vídeo em consulta nenhuma. Sem esta tool, "acha uma thread sobre
# X" só produz artigo de blog falando sobre a thread.
#
# O X entra por uma porta diferente das outras duas, e isso é do domínio, não
# escolha de desenho: no YouTube e no Reddit existe busca nativa por assunto; no
# X não existe caminho para busca de timeline (medido em 05/08: espelhos só
# servem post único, `syndication.twitter.com` dá 429 global, as 5 instâncias
# Nitter testadas dão 403/400). O que dá para ler com a sessão do dono é a
# timeline de UM PERFIL ou a busca por ASSUNTO (f=live).
class PlatformSearchTool < ToolBase
  description "Lê conteúdo DENTRO do YouTube, do Reddit, do Hacker News, do GitHub, do Polymarket " \
              "e do X (Twitter) pelo caminho nativo da própria plataforma, e devolve os permalinks. " \
              "No youtube, no reddit, no hackernews, no github, no polymarket e no x, `query` é o " \
              "ASSUNTO procurado — 'acha um vídeo sobre X', 'o que o pessoal do Reddit diz sobre X', " \
              "'discussões do Hacker News sobre X', 'issues do GitHub sobre X', 'mercados do Polymarket " \
              "sobre X', 'tuítes sobre X'. No X, se `query` for um PERFIL com @ explícito (ex: '@jack'), " \
              "a busca traz os posts MAIS RECENTES desse perfil ('o que fulano postou no X'). Se `query` " \
              "for um assunto no X (frase sem @, ex: 'ruby rails' ou 'bitcoin'), faz a busca nativa por assunto. Para o resto da internet " \
              "(notícia, preço, documentação, site), use web_search: ela NÃO acha permalink de " \
              "YouTube, Reddit, Hacker News, GitHub, Polymarket nem X, os buscadores web não indexam isso. " \
              "Depois de escolher um resultado, passe a `url` para page_fetch para ler a transcrição " \
              "do vídeo, a thread inteira ou o post."

  param :query,    type: :string,
                   desc: "No youtube, reddit, hackernews, github e polymarket: o assunto procurado " \
                         "(1-200 chars). No x: o perfil com @ explícito (ex: '@jack') para posts do perfil ou o assunto sem @ (ex: 'ruby rails')",
                   required: true
  param :platform, type: :string,
                   desc: "Onde ler: youtube | reddit | hackernews | github | polymarket | x",
                   required: true
  param :limit,    type: :integer, desc: "Número máximo de resultados (1-25, padrão 10)", required: false

  # O modelo não escolhe classe: o nome vem dele, o canal vem daqui.
  #
  # Guardar a CLASSE aqui era o que quebrava x e reddit em produção (27/09,
  # `NameError: uninitialized constant #<Class:Fetcher::Channels::X>::XGraphql`):
  # esta tool mora em `app/tools/`, que o Zeitwerk não gerencia e que o
  # initializer carrega com `require` UMA vez só, então ela não é recarregada
  # junto com o resto. Já `lib/fetcher/` é watchable: o reloader troca
  # `Fetcher::Channels::X` por um módulo NOVO em runtime e esta constante
  # continuaria apontando para o módulo DESCARREGADO — cujos corpos de método
  # (`class << self`) guardam o cref de um namespace que o reloader já trocou,
  # e qualquer constante do corpo (XGraphql, HostRateLimiter, CookieJar) deixa
  # de resolver.
  #
  # Guardar o NOME resolve na hora da chamada, e é o mesmo desenho em todos os
  # canais: um caso por canal seria o mesmo conserto repetido seis vezes.
  PLATFORMS = {
    "youtube"     => "Youtube",
    "reddit"      => "Reddit",
    "x"           => "X",
    "hackernews"  => "Hackernews",
    "github"      => "Github",
    "polymarket"  => "Polymarket"
  }.freeze

  # `PLATFORMS` guarda nomes, não classes, então o que esta lista mede é o
  # conjunto de NOMES — e ela é a única lista de canais de que `query` pode ser
  # perfil. O nome da plataforma já é string nos dois lugares, então as duas
  # estruturas comparam pela mesma chave.
  POR_PERFIL = %w[x].freeze

  DEFAULT_LIMIT = 10
  MIN_LIMIT     = 1
  # Teto igual ao dos canais de busca (`MAX_RESULTADOS`): pedir mais exigiria
  # paginar, e cada página é outra requisição contra uma plataforma logada. O
  # canal do X clampa mais fundo ainda, no teto dele.
  MAX_LIMIT     = 25
  MAX_QUERY     = 200

  def run(query:, platform:, limit: nil)
    q = query.to_s.strip
    return error("query vazia") if q.empty?
    return error("query muito longa (máx #{MAX_QUERY} chars)") if q.length > MAX_QUERY

    nome = platform.to_s.strip.downcase
    # Não adivinha: chutar a plataforma devolveria resultado de outro lugar com
    # cara de resposta ao que foi pedido.
    if !PLATFORMS.key?(nome)
      return error("plataforma desconhecida: #{platform.inspect} — válidas: #{PLATFORMS.keys.join(', ')}")
    end
    canal = canal_para(nome)

    handle = por_perfil?(nome) ? perfil(q) : nil
    alvo   = handle || q

    n = limit ? clamp(limit, MIN_LIMIT, MAX_LIMIT) : DEFAULT_LIMIT
    resultados = Array(ler(nome, canal, alvo, n, is_profile: handle.present?))

    reordenados = handle.present? ? resultados : sort_resultados(resultados, alvo)

    success({ platform: nome, query: alvo, count: reordenados.size, results: reordenados })
  rescue Fetcher::CookieJar::Expired => e
    # NUNCA lista vazia aqui: o modelo leria "não existe nada sobre isso" e
    # responderia isso ao usuário. O erro precisa dizer qual domínio renovar.
    Rails.logger.warn "[PlatformSearchTool] sessão de #{e.domain} expirada"
    error("sessão de #{e.domain} ausente ou expirada — o dono precisa renovar o cookie desse domínio " \
          "antes de ler dentro dessa plataforma")
  rescue Fetcher::BrowserSession::RenderTimeout, Fetcher::PageFetcher::RenderTimeout => e
    Rails.logger.warn "[PlatformSearchTool] timeout de render em #{nome}: #{e.message}"
    error("leitura em #{nome} estourou o tempo de render (#{Fetcher::BrowserSession::OVERALL_TIMEOUT}s) — tente de novo")
  rescue Fetcher::Channels::Error => e
    # Falha prevista de canal (rate limit, busca sem resposta, timeline
    # ilegível): mensagem limpa, já escrita pelo canal.
    error("leitura em #{nome} falhou: #{e.message}")
  rescue StandardError => e
    Rails.logger.error "[PlatformSearchTool] #{e.class}: #{e.message}"
    error("falha inesperada ao ler dentro da plataforma")
  end

  private

  # Resolve o canal na HORA da chamada, e não na carga do arquivo — é o que
  # sobrevive ao reloader. Ver a nota longa em `PLATFORMS`.
  def canal_para(nome)
    Fetcher::Channels.const_get(PLATFORMS.fetch(nome), false)
  end

  def por_perfil?(nome)
    POR_PERFIL.include?(nome)
  end

  # No X o parâmetro pode ser perfil (navegação até `x.com/<handle>`).
  def perfil(bruto)
    str = bruto.to_s.strip
    return unless str.start_with?("@")

    limpo = str.delete_prefix("@").strip
    limpo if limpo.match?(Fetcher::Channels::X::HANDLE)
  end

  # Cada canal tem o verbo do que ele sabe fazer: busca por perfil chama `timeline`,
  # busca por assunto chama `search`.
  def ler(nome, canal, alvo, limite, is_profile: false)
    return canal.timeline(user: alvo, limit: limite) if is_profile

    canal.search(query: alvo, limit: limite)
  end

  def sort_resultados(resultados, query)
    Research::Scorer.sort(resultados, query: query)
  rescue StandardError => e
    Rails.logger.error "[PlatformSearchTool] erro ao ordenar resultados com Scorer: #{e.class}: #{e.message}"
    # Fallback NUNCA sobrescreve chaves nativas (o "score" do Reddit são
    # upvotes): devolve intactos — sem scoring, mas sem perda de informação.
    resultados
  end
end
