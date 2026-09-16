# frozen_string_literal: true
#
# UMBRÁCULO ÚNICO do classificador de causa de falha do YouTube (B10).
#
# Este arquivo é a FONTE ÚNICA dos padrões: `YoutubeScraperService` (Ruby)
# importa daqui; o canário bin/canario-youtube.sh executa `classify_failure_cause`
# via `ruby -r` neste arquivo (o canário roda na MESMA VM do serviço — o
# Dockerfile instala Ruby em ambas as camadas).
#
# Por que não é um .rb de constante lido pelo shell? Porque shell não lê Ruby.
# A única forma de UMA implementação ser realmente consumida pelos DOIS lados é
# que o shell invoque Ruby apontando para ESTE arquivo. Isso elimina a duplicação
# — e a divergência que o canário antigo tinha ("sign in to confirm"||"bot" sem
# fronteiras; `members-only` plural hifenizado não reconhecido).
#
# Carga segura: sem require, sem Rails, sem IO. Só define constantes e um
# módulo puro — carrega sob `ruby -r` do canário sem dependências (o json
# acima NÃO é necessário: o módulo não faz parse).

# Classificador de causa de falha do yt-dlp (YouTube). Sem dependências de
# framework — consumido pelo serviço (via require relativo) e pelo canário
# (via `ruby -r <este arquivo>`).
module FailureCauseClassify
  # B5: anti-bot reconhecido APENAS por frases específicas de verificação —
  # a sub-string genérica `bot` e o prefixo `sign in to confirm` (que batia em
  # "confirm your age") eram os furos. Cada regex casa uma frase completa de
  # anti-bot; `bot` solto, "robot", "hobbit" etc. NÃO batem em nenhum, e
  # "sign in to confirm your age" NÃO completa nenhuma frase → `unknown`.
  BOT_CHECK_PATTERNS = [
    # O anti-bot canônico do YouTube (frase dos fixtures); casa por sub-string,
    # então também cobre "please sign in to confirm you're not a bot". Aceita
    # apostrofo reto (') ou curvo (\u2019).
    /sign in to confirm (you['\u2019]?re|you are)\s*(a )?(not a )?(bot|human|robot)/i,
    /verify (you['\u2019]?re|you are)\s*(a )?(not a )?(robot|bot|human)/i,
    /i['\u2019]?m not a robot/i,
    /are you (a )?(bot|robot)/i,
    # IP sob bloqueio anti-bot (sem exigir sign-in).
    /unusual traffic/i,
    /access to this page has been (temporarily )?limited/i,
    /suspicious (activity|traffic)/i
  ].freeze

  # Cobre `member-only`, `members-only` (plural hifenizado — que o canário
  # antigo perdia) e `members only`. O `\s*-?\s*` casa o hífen OU o espaço.
  MEMBERS_ONLY_PATTERN = /members?\s*-?\s*only/i.freeze

  # Padrões de TRANSPORTE e SESSÃO, na ORDEM de prioridade (o semântico ganha
  # do transport: um bot-check com "timed out" continua bot_check).
  # Cada entrada: [chamada, regex]. `String#include?` em mensagem downcase é
  # equivalentemente expresso por /.../i sem captura.
  TRANSPORT_AND_SESSION_PATTERNS = [
    ["timeout",  /timed out|timeout/i],
    ["network",  /connection reset|network|unreachable|resolve host/i],
    ["session_rejected", /cookies are no longer valid|session rejected|auth_token/i]
  ].freeze

  # Classifica a mensagem (stderr + stdout, já em minúsculas pelo chamador) em
  # uma causa nomeada: bot_check / members_only / timeout / network /
  # session_rejected / unknown. Devolve [causa, detalhes] no MESMO formato do
  # serviço — o 2º elemento é { no_cookie_fallback_allowed?: bool }, e o
  # fallback sem-cookie é permitido APENAS para session_rejected.
  #
  # A mesma função é o corpo do `classify_failure_cause` do serviço e a
  # delegação do canário — UMA implementação testável, consumida pelos dois.
  def self.classify_failure_cause(message)
    cause = if BOT_CHECK_PATTERNS.any? { |re| message =~ re }
              'bot_check'
            elsif MEMBERS_ONLY_PATTERN.match?(message)
              'members_only'
            else
              transport = TRANSPORT_AND_SESSION_PATTERNS.find { |(_, re)| re.match?(message) }
              transport ? transport[0] : 'unknown'
            end

    [cause, { no_cookie_fallback_allowed?: cause == 'session_rejected' }]
  end
end
