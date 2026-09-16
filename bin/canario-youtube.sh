#!/usr/bin/env bash
#
# canario-youtube.sh — Canário C1 para coleta do YouTube.
#
# Mede, por canal, quatro braços de execução do yt-dlp e classifica cada
# um com a MESMA FONTE ÚNICA do classificador do serviço:
# lib/scraping/failure_cause_classify.rb (consumido pelo serviço via
# require e pelo canário via `ruby -r`; ver "Classificador de causa —
# fonte ÚNICA" mais abaixo e o teste B10):
#
#   bot_check / members_only / timeout / network / session_rejected / "-"
#
# Os quatro braços por canal são a interseção:
#   {sem cookie, com cookie}  x  {cliente default, cliente mweb}
#
# Onde:
#   - "com cookie" usa o jar Netscape em CANARY_COOKIE_JAR.
#   - "mweb" adiciona  --extractor-args "youtube:player_client=mweb".
#
# Forma do comando — alinhada ao build_videos_command do serviço
# (youtube_scraper_service.rb:163-179):
#   yt-dlp --dump-json --no-download --playlist-end <N> \
#          --sleep-interval 8 --max-sleep-interval 20 [extra] <url>
#   O modo NÃO-FLAT (sem --flat-playlist) é o que revela a bot-check:
#   o flat pode retornar rc=0 mascarando o "Sign in to confirm" que o
#   maestro mediu (8 braços, todos rc=1 + bot_check).
#   - "default" = cliente padrão do yt-dlp (sem --extractor-args).
#   - URL usa os params de locale do serviço (hl=pt-BR&gl=BR&persist_hl=1).
#
# Garantias deste canário:
#   * NUNCA inventa cookie sintético: se o jar não existir, falha e explica
#     como obtê-lo (ver mensagem de erro).
#   * SÓ LÊ o jar do usuário. IMPORTANTE: o yt-dlp REESCREVE o arquivo
#     passado em --cookies (persiste os cookies de sessão na saída). Por
#     isso, cada braço "com cookie" recebe uma CÓPIA temporária do jar e o
#     original nunca é tocado; o canário ainda confere o hash do jar ao
#     fim e grita se mudou (defesa em profundidade).
#   * Não altera banco, nem repositório, nem apaga cookies.
#   * O timeout por braço é CANARY_TIMEOUT (default 150s).
#
# Observação de ambiente: o serviço ancora o js-runtime em
# `--js-runtimes deno:/usr/local/bin/deno`. Se /usr/local/bin/deno não
# existir na máquina, repasse a flag via CANARY_EXTRA_ARGS:
#   CANARY_EXTRA_ARGS="--js-runtimes deno:/usr/local/bin/deno"
#
# Uso:
#   bin/canario-youtube.sh
#   CANARY_COOKIE_JAR=/tmp/meu-jar.txt bin/canario-youtube.sh
#   CANARY_TIMEOUT=60 bin/canario-youtube.sh
#
# A tabela final tem a forma:  canal | braço | rc | entradas | causa
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variáveis de ambiente (todas com default; o canário não escreve no disco
# além dos temporários de trabalho, que são derrubados no fim de cada braço)
# ---------------------------------------------------------------------------
CANARY_COOKIE_JAR="${CANARY_COOKIE_JAR:-/tmp/canary-cookies.txt}"

CANARY_TIMEOUT="${CANARY_TIMEOUT:-150}"
case "$CANARY_TIMEOUT" in
  ''|*[!0-9]*) CANARY_TIMEOUT=150 ;;
esac

# Canais de teste: um pequeno e um grande (mantém o comportamento original).
CHANNEL_SMALL="${CHANNEL_SMALL:-@YouTube}"
CHANNEL_LARGE="${CHANNEL_LARGE:-@TED}"

# Quantos vídeos por braço (mesma função de `limit` no build_videos_command).
CANARY_ITEMS="${CANARY_ITEMS:-3}"
case "$CANARY_ITEMS" in
  ''|*[!0-9]*) CANARY_ITEMS=3 ;;
esac

YT_DLP="${YT_DLP:-yt-dlp}"

# Locale idêntico ao serviço (localize, persist: true):
# LOCALE_BASE + "&persist_hl=1". O canal do canário original não tinha isso;
# mantém o padrão do serviço para que a medição seja comparável.
CANARY_LOCALE="${CANARY_LOCALE:-1}"

# Flags extra opcionais (ex.: --js-runtimes, quando deno existe na VM).
CANARY_EXTRA_ARGS="${CANARY_EXTRA_ARGS:-}"

# B10: fonte única de classificação — o MESMO módulo que o serviço consome,
# resolvido a partir deste script (canario-youtube.sh vive em bin/).
# Apontar CANARY_CLASSIFIER para um path inexistente força a cópia embutida
# (o teste B10 usa exatamente isso para provar a sincronia da cópia).
CANARY_CLASSIFIER="${CANARY_CLASSIFIER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/scraping/failure_cause_classify.rb}"

# ---------------------------------------------------------------------------
# Limpeza dos temporários por trap (6): a cópia do jar nasce com a permissão
# RESTRICTIVA do mktemp (0600) e NUNCA é relaxada (chmod aqui vazaria o
# conteúdo sensível). Se o canário cair de pé (Ctrl-C, timeout do braço,
# exit no pré-requisito, set -e), o trap em EXIT derruba o que restou —
# sem deixar um 0600 com cookies do usuário parado em /tmp.
# As variáveis guardam o caminho CRIADO no braço atual (globais pelo
# escopo do trap; run_arm atualiza a cada braço).
# ---------------------------------------------------------------------------
CANARY_TMP_OUT=""
CANARY_TMP_ERR=""
CANARY_TMP_COOKIE_COPY=""

cleanup_canary_tmp() {
  rm -f "${CANARY_TMP_OUT:-}" "${CANARY_TMP_ERR:-}" "${CANARY_TMP_COOKIE_COPY:-}" 2>/dev/null || true
}
trap cleanup_canary_tmp EXIT
trap 'cleanup_canary_tmp; trap - EXIT; exit 130' INT
trap 'cleanup_canary_tmp; trap - EXIT; exit 143' TERM

# ---------------------------------------------------------------------------
# Pré-requisito: jar de cookies real.
#
# Um jar sintético (SID canario123 etc.) ou inexistente não diz nada sobre
# uma sessão real — ele só mascara o resultado. Por isso, se o arquivo não
# existir, o canário PARA aqui e explica como obter um jar de verdade.
# ---------------------------------------------------------------------------
if [[ ! -e "$CANARY_COOKIE_JAR" ]]; then
  cat >&2 <<EOF
[CANÁRIO] ERRO: o jar de cookies não existe em: $CANARY_COOKIE_JAR
          Este canário NUNCA inventa um cookie sintético — um jar falso
          esconderia exatamente o que ele serve para medir.

          Como obter um jar de cookies REAL (formato Netscape):
            1. Faça login em https://www.youtube.com no navegador.
            2. Exporte os cookies do domínio youtube.com num arquivo
               "Get cookies.txt / Cookies.txt" (formato Netscape).
            3. Salve-o em: $CANARY_COOKIE_JAR
               (ou aponte para outro caminho já existente via
                CANARY_COOKIE_JAR=/caminho/jar.txt).
            4. Rode de novo: bin/canario-youtube.sh

          Para um teste rápido sem sessão, crie um jar VAZIO porém
          existente (só o cabeçalho Netscape):  touch $CANARY_COOKIE_JAR
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Contagem REAL de entradas do JSON (substitui o antigo grep -c '^{}').
# --dump-json devolve um JSON por linha (NDJSON) quando há vários vídeos;
# um único objeto quando há um. count_entries conta objetos JSON válidos;
# cai em 0 se a saída não existir ou não for JSON válido.
# ---------------------------------------------------------------------------
count_entries() {
  local file="$1"
  if [[ -s "$file" ]]; then
    jq -s 'length' "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Classificador de causa — fonte ÚNICA (B10).
#
# Caminho primário: o canário delega a classificação ao MESMO módulo que o
# serviço consome (lib/scraping/failure_cause_classify.rb, executado via
# `ruby -r`). É o MESMO CÓDIGO de produção — a divergência do canário antigo
# (que reimplementava "sign in to confirm"||"bot" sem fronteiras e perdia o
# "members-only" hifenizado) ficou impossível de reocorrer no caminho
# primário.
#
# Cópia embutida (fallback): replica os padrões específicos de produção e só é
# usada quando a fonte única está indisponível (sem Ruby no host ou módulo
# ausente). Ela é mantida em sincronia PELA BATERIA — o teste "B10: canário
# classifica idêntico ao serviço" (test/lib/scraping/services/youtube_scraper
# _service_test.rb) roda os DOIS caminhos (delegação e cópia embutida, via
# CANARY_CLASSIFIER) na mesma bateria de entradas; divergência trava o teste.
#
# Prioridade (idêntica ao serviço):
#   bot_check > members_only > timeout > network > session_rejected > "-"
# ---------------------------------------------------------------------------
classify_cause() {
  local stderr_file="$1" stdout_file="$2"
  local msg
  # Junta stderr+stdout e baixa para minúsculas, como o serviço.
  msg="$({ cat "$stderr_file"; cat "$stdout_file"; } 2>/dev/null | tr '[:upper:]' '[:lower:]')"

  # B10 (caminho primário): fonte única — o módulo que o serviço consome.
  local ruby_cause
  if [[ -f "${CANARY_CLASSIFIER:-}" ]] && command -v ruby >/dev/null 2>&1; then
    if ruby_cause="$(ruby -r"$CANARY_CLASSIFIER" -e '
      msg = (File.read(ARGV[0]) + File.read(ARGV[1])).downcase
      causa = FailureCauseClassify.classify_failure_cause(msg)[0]
      puts(causa == "unknown" ? "-" : causa)
    ' "$stderr_file" "$stdout_file" 2>/dev/null)"; then
      printf '%s\n' "$ruby_cause"
      return 0
    fi
    echo "[CANÁRIO] WARN: fonte única de classificação indisponível (${CANARY_CLASSIFIER}); usando cópia embutida" >&2
  fi

  # B10 (fallback): cópia embutida dos padrões específicos de produção,
  # sincronizada com lib/scraping/failure_cause_classify.rb pela bateria
  # (teste B10). Os padrões rodam sobre msg (já em minúsculas), em ERE:
  # as fronteiras ("sign in to confirm your age" NÃO completa a frase de
  # anti-bot; "robot"/"hobbit" NÃO casam em nenhuma) estão nos grupos
  # alternados — não em sub-string solta como o canário antigo.
  local re_bot re_members re_timeout re_network re_session
  re_bot='sign in to confirm (you.re|you are) *(a )?(not a )?(bot|human|robot)|verify (you.re|you are) *(a )?(not a )?(robot|bot|human)|i.m not a robot|are you (a )?(bot|robot)|unusual traffic|access to this page has been (temporarily )?limited|suspicious (activity|traffic)'
  re_members='members? *-? *only'
  re_timeout='timed out|timeout'
  re_network='connection reset|network|unreachable|resolve host'
  re_session='cookies are no longer valid|session rejected|auth_token'

  if [[ "$msg" =~ $re_bot ]]; then
    echo "bot_check"
  elif [[ "$msg" =~ $re_members ]]; then
    echo "members_only"
  elif [[ "$msg" =~ $re_timeout ]]; then
    echo "timeout"
  elif [[ "$msg" =~ $re_network ]]; then
    echo "network"
  elif [[ "$msg" =~ $re_session ]]; then
    echo "session_rejected"
  else
    echo "-"
  fi
}

# Hash do jar ANTES de rodar: se algo mudou no original ao final,
# o canário avisa (defesa em profundidade — cada braço usa cópia temporária).
JAR_HASH_ANTES="$(sha1sum "$CANARY_COOKIE_JAR" 2>/dev/null | cut -d' ' -f1 || echo na)"

# ---------------------------------------------------------------------------
# Executa UM braço e guarda a linha: canal | braço | rc | entradas | causa
# ---------------------------------------------------------------------------
ROWS=()

run_arm() {
  local channel="$1" arm_name="$2" use_cookie="$3" use_mweb="$4"

  # URL com locale do serviço (localize, persist: true):
  # https://www.youtube.com/<canal>/videos?hl=pt-BR&gl=BR&persist_hl=1
  local url="https://www.youtube.com/${channel}/videos"
  if [[ "$CANARY_LOCALE" == "1" ]]; then
    url="${url}?hl=pt-BR&gl=BR&persist_hl=1"
  fi

  # Mesma espinha do build_videos_command (modo não-flat).
  local -a cmd=("$YT_DLP" --dump-json --no-download \
                --playlist-end "$CANARY_ITEMS" \
                --sleep-interval 8 --max-sleep-interval 20)

  # Flags extra opcionais (ex.: --js-runtimes, quando deno existe na VM).
  if [[ -n "$CANARY_EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    local -a extra=($CANARY_EXTRA_ARGS)
    cmd+=("${extra[@]}")
  fi

  # Braço "com cookie": usa uma CÓPIA temporária do jar (em /tmp). O
  # yt-dlp reescreve o arquivo de --cookies; apontar direto para o jar do
  # usuário violaria a regra "não alterar cookies". A cópia nasce com a
  # permissão restrita do mktemp (0600) e é derrubada no fim do braço OU
  # pelo trap EXIT se o canário cair antes (item 6).
  local cookie_copy=""
  if [[ "$use_cookie" == "1" ]]; then
    cookie_copy="$(mktemp "${TMPDIR:-/tmp}/canary-jar.XXXXXX")"
    CANARY_TMP_COOKIE_COPY="$cookie_copy"
    if ! cp -f "$CANARY_COOKIE_JAR" "$cookie_copy"; then
      echo "[CANÁRIO] ERRO: não consegui copiar o jar $CANARY_COOKIE_JAR para a cópia temporária." >&2
      rm -f "$cookie_copy"
      exit 1
    fi
    cmd+=("--cookies" "$cookie_copy")
  fi
  if [[ "$use_mweb" == "1" ]]; then
    cmd+=("--extractor-args" "youtube:player_client=mweb")
  fi
  cmd+=("$url")

  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  CANARY_TMP_OUT="$out"
  CANARY_TMP_ERR="$err"

  set +e
  timeout "$CANARY_TIMEOUT" "${cmd[@]}" > "$out" 2> "$err"
  rc=$?
  set -e

  local entries cause
  entries="$(count_entries "$out")"

  # timeout(1) mata o processo com 124 => causa "timeout" (nem sempre o
  # texto "timeout" aparece no stderr).
  if [[ $rc -eq 124 ]]; then
    cause="timeout"
  else
    cause="$(classify_cause "$err" "$out")"
    # Se o braço teve sucesso e realmente listou vídeos, a causa é "-".
    if [[ $rc -eq 0 && "$entries" -gt 0 ]]; then
      cause="-"
    fi
  fi

  ROWS+=("${channel} | ${arm_name} | ${rc} | ${entries} | ${cause}")

  # Derruba os temporários no fim do braço (não deixa lixo, incluída a
  # cópia do jar — o original continua intocado em $CANARY_COOKIE_JAR).
  # O reset das globais evita que o trap EXIT repita a remoção.
  rm -f "$out" "$err"
  if [[ -n "$cookie_copy" ]]; then
    rm -f "$cookie_copy"
  fi
  CANARY_TMP_OUT=""
  CANARY_TMP_ERR=""
  CANARY_TMP_COOKIE_COPY=""
  return 0
}

# ---------------------------------------------------------------------------
# Roda os 4 braços por canal
# ---------------------------------------------------------------------------
echo "CANÁRIO C1 — YouTube (canal x braço)"
echo "  jar de cookies : $CANARY_COOKIE_JAR (usado via cópia temporária; original não é tocado)"
echo "  timeout/braço  : ${CANARY_TIMEOUT}s"
echo "  vídeos/braço   : ${CANARY_ITEMS} (playlist-end)"
echo "  locale         : $([[ "$CANARY_LOCALE" == "1" ]] && echo 'hl=pt-BR&gl=BR&persist_hl=1' || echo off)"
echo "  extra args     : ${CANARY_EXTRA_ARGS:-nenhum (o serviço usa --js-runtimes deno:/usr/local/bin/deno; repasse em CANARY_EXTRA_ARGS se deno existir)}"
echo "  data (UTC)     : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "Rodando 4 braços x 2 canais (8 execuções) ... (pode demorar; CANARY_TIMEOUT para encurtar)"
echo

for channel in "$CHANNEL_SMALL" "$CHANNEL_LARGE"; do
  run_arm "$channel" "sem-cookie  · default" 0 0
  run_arm "$channel" "sem-cookie  · mweb   " 0 1
  run_arm "$channel" "com-cookie  · default" 1 0
  run_arm "$channel" "com-cookie  · mweb   " 1 1
done

# ---------------------------------------------------------------------------
# Tabela final
# ---------------------------------------------------------------------------
echo
echo "=============================================================="
echo " TABELA: canal | braço | rc | entradas | causa"
echo "=============================================================="
printf '%s\n' "${ROWS[@]}"
echo "=============================================================="

# ---------------------------------------------------------------------------
# Conferência de integridade: o jar do usuário NÃO deveria ter mudado
# (cada braço usou cópia temporária). Se mudou, avisa antes do resumo.
# ---------------------------------------------------------------------------
JAR_HASH_DEPOIS="$(sha1sum "$CANARY_COOKIE_JAR" 2>/dev/null | cut -d' ' -f1 || echo na)"
if [[ "$JAR_HASH_ANTES" != "$JAR_HASH_DEPOIS" ]]; then
  {
    echo "AVISO: o jar $CANARY_COOKIE_JAR MUDOU durante a execução"
    echo "       (sha1 antes=$JAR_HASH_ANTES, depois=$JAR_HASH_DEPOIS)."
    echo "       O canário usa cópia temporária do jar; se isso aconteceu,"
    echo "       alguma coisa escreveu no jar — investigue antes de confiar nos números."
  } >&2
fi

# ---------------------------------------------------------------------------
# Resumo: o que cada padrão de resultado significa
# ---------------------------------------------------------------------------
echo
echo "RESUMO — como ler os padrões:"
echo "  rc=0 e entradas>0 ........ o braço LISTOU vídeos: coleta saudável (causa '-')."
echo "  causa=bot_check ........... o stderr casou com uma FRASE de anti-bot (a MESMA"
echo "                             lista de produção, via fonte única failure_cause_"
echo "                             classify.rb): o IP está sob anti-bot. Nem cookie real"
echo "                             nem mweb resolvem; o que falta é PO Token / IP"
echo "                             residencial (exatamente o achado do maestro: 8"
echo "                             braços, todos rc=1 + bot_check)."
echo "  causa=session_rejected .. cookie existe mas a sessão foi rejeitada ('cookies are"
echo "                             no longer valid' / 'session rejected' / 'auth_token')."
echo "  causa=members_only ...... o canal/aba requer membros pagos ('member-only',"
echo "                             'members-only' hifenizado, 'members only')."
echo "  causa=timeout ............ estourou CANARY_TIMEOUT (ou 'timed out' no stderr)."
echo "  causa=network ............ falha de rede ('connection reset' / 'unreachable' /"
echo "                             'resolve host')."
echo "  causa=- com rc!=0 ......... falha com stderr que NÃO casou nenhum padrão de"
echo "                             produção (causa 'unknown' no serviço): a leitura do"
echo "                             stderr está no artefato — não dá para afirmar a causa."
echo "  entradas=0 com rc!=0 ..... não listou nada; a causa acima diz por quê."
echo
echo "Leitura prática:"
echo "  - Se  SEM-cookie e  COM-cookie saem iguais (ex.: ambos bot_check),"
echo "    o cookie NÃO está mudando o resultado (IP bloqueado)."
echo "  - Se  COM-cookie  melhora (rc=0 / entradas>0), a sessão real foi"
echo "    aplicada e está funcionando."
echo "  - Se  mweb melhora vs. default, o cliente 'mweb' é a escolha certa"
echo "    para este IP — é o item 2 da C1 sendo medido aqui."
echo "  - Rode de novo quando houver PO Token / IP residencial e compare."
echo
