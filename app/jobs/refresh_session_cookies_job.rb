# frozen_string_literal: true

require "timeout"
require Rails.root.join("lib/fetcher/cookie_jar")
require Rails.root.join("lib/fetcher/channels/youtube")
require_relative "../services/alert_throttler"

# Mantém viva a sessão do YouTube renovando o cookie antes que ele vença.
#
# MEDIDO EM 05/08, quatro vezes: a sessão morre ~20 minutos depois de carregada,
# mesmo SEM nenhuma chamada no intervalo e mesmo com a exportação feita à risca
# (janela anônima, `robots.txt` como única aba, janela fechada em seguida). Não é
# erro de procedimento e não é uso em rajada — é o `__Secure-1PSIDTS`, que tem
# validade de cerca de 20 minutos no servidor.
#
# Num navegador de verdade quem renova é o próprio Google, em segundo plano. O
# nosso só apresentava cookie quando alguém pedia, então bastava ninguém pedir
# por 20 minutos para a sessão ser rejeitada — e rejeição é definitiva.
#
# Este job faz o que o navegador faria. Uma chamada barata (`--simulate`, sem
# baixar legenda nem gravar arquivo) é suficiente para o servidor rotacionar, e o
# `yt-dlp` reescreve o jar que recebeu — que é o que persistimos.
#
# NÃO renova o Reddit: o `reddit_session` é um JWT de meses, sem esta rotação.
# Medido no mesmo dia: sobreviveu horas enquanto o do YouTube morria.
class RefreshSessionCookiesJob < ApplicationJob
  queue_as :default

  # A sonda roda com `--simulate` (não baixa mídia nem grava arquivo), então
  # qualquer vídeo público serve; TIMEOUT cobre o round-trip do yt-dlp.
  VIDEO_SONDA = "https://www.youtube.com/watch?v=aircAruvnKk"
  TIMEOUT     = 30

  # Distinta de `CookieJar::Expired` de propósito: "o jar já estava vazio quando
  # começamos" e "o servidor rejeitou no meio da renovação" pedem investigações
  # opostas do dono. (COOKIE-1: e agora o dono fica sabendo pelo ALERTA, não só
  # pelo log — ver `alertar_rejeicao!`.)
  class SessaoRejeitada < StandardError; end

  # Identidade sintética do incidente de rejeição do JAR no dedupe por estado
  # (`AlertThrottler`), separada dos incidentes POR PERFIL do `ScrapeYoutubeJob`
  # (que usa `profile.id` numérico). "jar" não colide com ID de perfil.
  ALERT_SCRAPER = "youtube"
  ALERT_PERFIL  = "jar"
  ALERT_TIPO    = "session_rejected"

  # O procedimento viaja NA MENSAGEM, e não só no `docs/MEMORY.md`, porque em
  # 05-06/08/2026 a sessão foi perdida QUATRO vezes pela mesma causa: o export
  # saiu de uma janela com o app do YouTube aberto, e aí duas cópias passam a
  # rotacionar o `__Secure-1PSIDTS` em paralelo — a do navegador do dono e a
  # nossa — e o YouTube invalida as duas. Quem lê este log está exatamente no
  # momento de refazer a exportação; mandá-lo caçar a regra noutro arquivo é o
  # que fez a causa se repetir.
  #
  # O sinal de export sujo é objetivo: cookies `ST-*` carregando `itct=`,
  # `search_query=` ou `endpoint=` só existem se houve navegação no app.
  PROCEDIMENTO = "janela ANÔNIMA, login, `youtube.com/robots.txt` como ÚNICA aba, " \
                 "exportar, e FECHAR a janela em seguida. Se o export trouxer cookies " \
                 "`ST-*` com `itct=` ou `search_query=`, ele saiu de uma janela navegando " \
                 "e vai morrer em ~20 min"

  def perform
    return log("sem sessão de youtube.com no jar — nada a renovar") unless Fetcher::CookieJar.valid?("youtube.com")

    antes = assinatura
    renovar!
    depois = assinatura

    if depois.nil?
      # Revisão 199 (item 4): a rotação passou no `verify_session!` mas sem
      # `SID` (o portão aceita qualquer um dos AUTH_COOKIES) — a sessão NÃO foi
      # provada viva. O incidente fica ABERTO de propósito: fechá-lo aqui
      # tornaria "continua ruim" indistinguível de "foi consertado", e a
      # próxima rejeição — que tem que alertar de novo — seria dedupada em
      # silêncio. É o item 4 do veredito: resolução indevida no ramo de ERRO.
      log("ERRO: renovação derrubou a sessão de youtube.com — precisa de exportação nova")
    elsif antes == depois
      log("sessão de youtube.com viva, servidor não rotacionou desta vez")
    else
      log("sessão de youtube.com renovada")
    end
    # Rotação com a sessão provada viva (assinatura != nil): o dono resolveu a
    # rejeição (refez a exportação) ou o servidor seguiu devolvendo a sessão —
    # limpa o incidente para que a PRÓXIMA rejeição — não a repetição desta —
    # dispare o alerta. No ramo `depois.nil?` a condição segue existindo; o
    # incidente não resolve (guard `unless` acima, item 4 da revisão 199).
    AlertThrottler.resolve_incident(ALERT_SCRAPER, ALERT_PERFIL) unless depois.nil?
  rescue SessaoRejeitada
    # Revisão 199 (3b): a assinatura é captada ANTES da invalidação — depois
    # dela o portão do jar devolve [] e o payload rejeitado perde a
    # identidade. É essa identidade (cada exportação nova rotaciona o
    # `__Secure-1PSIDTS`) que separa "a exportação NOVA foi rejeitada"
    # (transição de fingerprint → re-alerta) de "a MESMA sessão continua
    # rejeitada" (dedupe → sem spam). Sem ela, a 2ª rejeição após
    # recuperação falha era silenciada pelo throttle para sempre.
    rejeitada_em = assinatura
    invalidar_sessao!
    log("ERRO: o YouTube rejeitou a sessão durante a renovação. O jar foi INVALIDADO " \
        "(o payload continua preservado para diagnóstico) — a sessão não morreu por " \
        "exportação velha, morreu do lado do servidor. Precisa de exportação nova, " \
        "e o PROCEDIMENTO importa: #{PROCEDIMENTO}")
    alertar_rejeicao!(rejeitada_em)
  rescue Fetcher::CookieJar::Expired
    log("ERRO: sessão de youtube.com já estava expirada — precisa de exportação nova")
  rescue Timeout::Error
    log("ERRO: renovação de cookie excedeu o timeout (#{TIMEOUT}s)")
  rescue StandardError => e
    Rails.logger.error "[RefreshSessionCookiesJob] Erro inesperado ao renovar cookie de youtube.com: #{e.class}: #{e.message}"
    raise
  end

  private

  # COOKIE-1 (defeito 1): rejeição do servidor tem que matar o jar no lado do
  # LEITOR, senão o `expires_at` local — que o YouTube NÃO sabe que morreu —
  # mantém o registro "vivo" e os jobs de coleta seguem gastando chamada num
  # cookie morto. É o que ficou 5,7 dias em produção: `valid?` devolvia true
  # e o job só logava, sem reagir.
  #
  # O mecanismo é empurrar `expires_at` para o passado no `BrowserSessionCookie`
  # do domínio: o único portão de leitura do jar é
  # `expires_at > Time.current` (`CookieJar#live_record`), então `valid?` vira
  # false, `for` devolve `[]`, `require!` levanta `Expired` — o caminho já
  # existia no código. O payload CIFRADO fica no banco de propósito: é o
  # diagnóstico do dono (o que a exportação trouxe, por que o servidor
  # rejeitou) — apagar era perder a cena do crime.
  #
  # Toco SÓ no registro de `youtube.com`; os outros domínios do jar
  # (reddit/x) continuam imunes, e o `CookieJar` em si não muda de contrato
  # (invalidar não é rotação nem reescrita de payload — é marcar a sessão
  # morta).
  def invalidar_sessao!
    BrowserSessionCookie.where(domain: "youtube.com")
                        .update_all(expires_at: 1.minute.ago)
  end

  # COOKIE-1 (defeito 2): rejeição precisa de ALERTA, não de linha de log.
  # Reuse o caminho de alerta do repo — `ScrapingFailureAlertJob` (que entrega
  # via `DiscordApiClient`) — e a deduplicação por transição de estado do
  # `AlertThrottler`: emite na PRIMEIRA rejeição e NÃO repete a cada 10 min.
  # O job roda em loop; sem o dedupe, o dono seria bombardeado a cada rodada
  # até refazer a exportação. É exatamente o padrão que o
  # `ScrapeYoutubeJob` já usa para o próprio incidente de perfil.
  def alertar_rejeicao!(assinatura_rejeitada = nil)
    ScrapingFailureAlertJob.perform_later(
      ALERT_SCRAPER,
      ALERT_PERFIL,
      "o YouTube rejeitou a sessão durante a renovação — o jar foi invalidado " \
      "(fingerprint da exportação rejeitada: #{fingerprint_rejeicao(assinatura_rejeitada)})",
      ALERT_TIPO
    )
  end

  # Identidade da exportação rejeitada, estável por exportação: o job não sabe
  # se a rejeição é a primeira da sessão atual ou a repetição dela — quem sabe
  # é o fingerprint do `AlertThrottler`. Mesma exportação re-rejeitada → mesmo
  # fingerprint → dedupe (sem spam no loop de 10 min / 144x dia). Exportação
  # nova (o dono refaz o `store!`) rotaciona o `__Secure-1PSIDTS` → fingerprint
  # novo → transição → re-alerta. Não carrega o valor do cookie, só 8 chars de
  # SHA1 — o mesmo padrão que `assinatura` já emite no log.
  def fingerprint_rejeicao(assinatura_rejeitada)
    return "sem-identificacao" if assinatura_rejeitada.nil?

    "sha1:#{assinatura_rejeitada}"
  end

  # Só o par que rotaciona, e só se mudou. Nunca o valor — isto vai para o log.
  def assinatura
    cookies = Fetcher::CookieJar.for("youtube.com")
    token = cookies.find { |c| c["name"] == "__Secure-1PSIDTS" }
    return nil if cookies.none? { |c| c["name"] == "SID" }

    Digest::SHA1.hexdigest(token.to_h["value"].to_s)[0, 8]
  end

  # `--simulate` de propósito: não queremos legenda nem arquivo, só o
  # round-trip que faz o servidor emitir os cookies novos.
  def renovar!
    Fetcher::CookieJar.with_netscape_file("youtube.com") do |caminho|
      comando = [
        "yt-dlp", "--no-update", "--simulate", "--quiet", "--no-warnings",
        "--ignore-no-formats-error", "--skip-download",
        "--print", "%(id)s", "--cookies", caminho,
        "--socket-timeout", "15", VIDEO_SONDA
      ]
      Timeout.timeout(TIMEOUT) { Open3.capture3(*comando) }
      # PORTÃO, e a ordem aqui é o conserto: o yt-dlp acabou de REESCREVER este
      # arquivo com o que o servidor devolveu. Se a sessão foi rejeitada, o que
      # está no arquivo agora é o conjunto anônimo — e persistir isso apaga a
      # sessão boa, que só volta com exportação manual do dono. Aconteceu em
      # produção: 21 cookies viraram 12, sem autenticação. Verificar DEPOIS de
      # gravar, como era antes, só rendia um log de necrotério.
      begin
        Fetcher::Channels::Youtube.verify_session!(caminho)
      rescue Fetcher::CookieJar::Expired
        raise SessaoRejeitada
      end
      # `expires_at:` é o conserto do auto-sabotagem: o `verify_session!` acima
      # acabou de provar a sessão viva, e o portão de leitura é
      # `expires_at > Time.current` — sem estender o prazo junto da rotação, o
      # job renovava o payload por 7 dias e então parava para sempre com uma
      # sessão recém-rotacionada no banco.
      persistiu = Fetcher::CookieJar.refresh_from_netscape!(
        domain: "youtube.com", path: caminho,
        auth_cookies: Fetcher::Channels::Youtube::AUTH_COOKIES,
        expires_at: 7.days.from_now
      )
      log("ERRO: rotação não foi persistida — arquivo veio vazio ou o registro sumiu") unless persistiu
    end
  end

  def log(mensagem)
    Rails.logger.info "[RefreshSessionCookiesJob] #{mensagem}"
  end
end
