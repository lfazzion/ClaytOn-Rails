# frozen_string_literal: true

require Rails.root.join("lib/fetcher/cookie_jar")
require Rails.root.join("lib/fetcher/channels/youtube")

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
  # opostas do dono, e o log é o único canal por onde ele fica sabendo.
  class SessaoRejeitada < StandardError; end

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
      log("ERRO: renovação derrubou a sessão de youtube.com — precisa de exportação nova")
    elsif antes == depois
      log("sessão de youtube.com viva, servidor não rotacionou desta vez")
    else
      log("sessão de youtube.com renovada")
    end
  rescue SessaoRejeitada
    log("ERRO: o YouTube rejeitou a sessão durante a renovação. O jar foi preservado " \
        "intacto — a sessão não morreu por exportação velha, morreu do lado do servidor. " \
        "Precisa de exportação nova, e o PROCEDIMENTO importa: #{PROCEDIMENTO}")
  rescue Fetcher::CookieJar::Expired
    log("ERRO: sessão de youtube.com já estava expirada — precisa de exportação nova")
  rescue StandardError => e
    log("falhou: #{e.class}: #{e.message}")
  end

  private

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
