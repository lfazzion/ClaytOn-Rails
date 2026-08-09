# frozen_string_literal: true

require_relative "../../lib/fetcher/channels/youtube"
require_relative "../../lib/fetcher/channels/reddit"
require_relative "../../lib/fetcher/channels/x"

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
# timeline de UM PERFIL.
class PlatformSearchTool < ToolBase
  description "Lê conteúdo DENTRO do YouTube, do Reddit e do X (Twitter) pelo caminho nativo da " \
              "própria plataforma, e devolve os permalinks. No youtube e no reddit, `query` é o " \
              "ASSUNTO procurado — 'acha um vídeo sobre X', 'o que o pessoal do Reddit diz sobre " \
              "X'. No X é DIFERENTE e não há ambiguidade: NÃO existe busca por assunto no X, " \
              "então `query` é o PERFIL (o @handle, com ou sem arroba) e o retorno são os posts " \
              "MAIS RECENTES desse perfil — use para 'o que fulano postou no X', 'últimos tuítes " \
              "do fulano'. Se o usuário pedir um ASSUNTO no X, não chute um perfil: diga que aqui " \
              "só dá para listar os posts de um perfil informado. Para o resto da internet " \
              "(notícia, preço, documentação, site), use web_search: ela NÃO acha permalink de " \
              "YouTube, Reddit nem X, os buscadores web não indexam isso. Depois de escolher um " \
              "resultado, passe a `url` para page_fetch para ler a transcrição do vídeo, a thread " \
              "inteira ou o post."

  param :query,    type: :string,
                   desc: "No youtube e no reddit: o assunto procurado (1-200 chars). No x: o " \
                         "perfil/handle a listar, com ou sem @ (1-15 chars [A-Za-z0-9_])",
                   required: true
  param :platform, type: :string,  desc: "Onde ler: youtube | reddit | x", required: true
  param :limit,    type: :integer, desc: "Número máximo de resultados (1-25, padrão 10)", required: false

  # O modelo não escolhe classe: o nome vem dele, o canal vem daqui.
  PLATFORMS = {
    "youtube" => Fetcher::Channels::Youtube,
    "reddit"  => Fetcher::Channels::Reddit,
    "x"       => Fetcher::Channels::X
  }.freeze

  # Plataformas em que `query` é perfil, não assunto. Uma lista em vez de um `if
  # nome == "x"` porque a pergunta ("este canal lê perfil?") vai ser feita em
  # três pontos, e espalhar o nome literal é como se esquece um deles.
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

    nome  = platform.to_s.strip.downcase
    canal = PLATFORMS[nome]
    # Não adivinha: chutar a plataforma devolveria resultado de outro lugar com
    # cara de resposta ao que foi pedido.
    if canal.nil?
      return error("plataforma desconhecida: #{platform.inspect} — válidas: #{PLATFORMS.keys.join(', ')}")
    end

    alvo = por_perfil?(nome) ? perfil(q) : q
    # Handle inválido é frase de busca no lugar do perfil: erro que ENSINA a
    # fronteira, e antes de gastar Chrome com `x.com/<frase>`.
    return error(erro_de_perfil(nome, q)) if alvo.nil?

    n = limit ? clamp(limit, MIN_LIMIT, MAX_LIMIT) : DEFAULT_LIMIT
    resultados = Array(ler(nome, canal, alvo, n))
    reordenados = sort_resultados(resultados, alvo)

    success({ platform: nome, query: alvo, count: reordenados.size, results: reordenados })
  rescue Fetcher::CookieJar::Expired => e
    # NUNCA lista vazia aqui: o modelo leria "não existe nada sobre isso" e
    # responderia isso ao usuário. O erro precisa dizer qual domínio renovar.
    Rails.logger.warn "[PlatformSearchTool] sessão de #{e.domain} expirada"
    error("sessão de #{e.domain} ausente ou expirada — o dono precisa renovar o cookie desse domínio " \
          "antes de ler dentro dessa plataforma")
  rescue Fetcher::Channels::Error => e
    # Falha prevista de canal (rate limit, busca sem resposta, timeline
    # ilegível): mensagem limpa, já escrita pelo canal.
    error("leitura em #{nome} falhou: #{e.message}")
  rescue StandardError => e
    Rails.logger.error "[PlatformSearchTool] #{e.class}: #{e.message}"
    error("falha inesperada ao ler dentro da plataforma")
  end

  private

  def por_perfil?(nome)
    POR_PERFIL.include?(nome)
  end

  # No X o parâmetro não é busca: é navegação até `x.com/<handle>`. O canal
  # valida de novo (é o portão de verdade), mas validar aqui é o que impede a
  # chamada de custar um Chrome e uma requisição na conta pessoal do dono.
  def perfil(bruto)
    limpo = bruto.delete_prefix("@").strip
    limpo if limpo.match?(Fetcher::Channels::X::HANDLE)
  end

  def erro_de_perfil(nome, bruto)
    "no #{nome} o parâmetro `query` é um PERFIL, não um assunto — #{bruto.inspect} não é um handle " \
      "válido (1-15 caracteres [A-Za-z0-9_], com ou sem @). Busca por assunto no #{nome} não existe " \
      "nesta ferramenta: informe o @perfil de quem se quer ler os posts recentes"
  end

  # Cada canal tem o verbo do que ele sabe fazer: os dois com busca nativa
  # expõem `search(query:)`, e o X expõe `timeline(user:)`. Uniformizar o nome
  # esconderia justamente a diferença que o modelo precisa enxergar.
  def ler(nome, canal, alvo, limite)
    return canal.timeline(user: alvo, limit: limite) if por_perfil?(nome)

    canal.search(query: alvo, limit: limite)
  end

  def sort_resultados(resultados, query)
    Research::Scorer.sort(resultados, query: query)
  rescue StandardError => e
    Rails.logger.error "[PlatformSearchTool] erro ao ordenar resultados com Scorer: #{e.class}: #{e.message}"
    resultados.map do |r|
      next r unless r.is_a?(Hash)

      r.merge("score" => 0.0)
    end
  end
end
