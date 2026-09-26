#!/usr/bin/env bash
# Prova do par por MUTAÇÃO da aritmética dos tetos (ressalva do #204, card
# t_35bcd11f, item 1; guard e veredito corrigidos no card t_cbfa9f27, item 4).
# Os DOIS lados, com a MESMA mutação:
#
#   PASSO 1 — VERDE com mutação: a aritmética ANTIGA (soma só o open timeout)
#             ignora o read timeout, então a regressão passa.
#   PASSO 2 — VERMELHO com a MESMA mutação: a aritmética NOVA (teto total por
#             requisição) pega a regressão.
#   PASSO 3 — VERMELHO com a mutação de REMOÇÃO: o read timeout some do cliente.
#
# A mutação dos passos 1 e 2 é a MESMA: `HTTP_READ_TIMEOUT` de 3s para 20s, sem
# tocar em mais nada. O teto total é de 8s, então 20s de read passa a ser o
# relógio dominante do `max` — que é o que a aritmética NOVA mede. (Com o valor
# antigo desta mutação, 8s, o `max` não mudava e o par viraria falso.)
#
# O COMMIT-BASE é OBRIGATORIO: tem de ser o commit em que a aritmética ANTIGA
# ainda era a do HEAD. O script SAI com código 1 se algum passo sair fora do
# esperado — um par que não confirma é par nenhum, e antes ele saía com 0.
#
# POR QUE O FILTRO `/pior_caso/`: os testes de CONFIGURAÇÃO do cliente
# comparam `conn.options.timeout` com a constante e pegam QUALQUER mudança no
# read, inclusive o aumento. O que o card quer provado é o par sobre a
# ARITMÉTICA — a que prometia o pior caso. Sem o filtro, o passo 1 acusaria uma
# falha de configuração e o par seria falso.
#
# Uso:  bash scripts/proofs/timeout_arithmetic_mutation_pair.sh 971308d
# Requer: docker + o repo com `docker/docker-compose.yml`.
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$RAIZ"

ARQ_TESTE=test/lib/fetcher/x_query_id_resolver_timeout_test.rb
ARQ_RESOLVER=lib/fetcher/x_query_id_resolver.rb

# O "teste antigo" (aritmetica que somava so o open) e' o arquivo no commit que
# ANTECEDE o item 1. Sem este parametro, o script pegaria o HEAD, que depois do
# commit ja e' a aritmetica NOVA — e o passo 1 seria o passo 2, sem par nenhum.
#   uso: bash scripts/proofs/timeout_arithmetic_mutation_pair.sh 971308d
#
# ── O COMMIT-BASE E' OBRIGATORIO (medido no card t_cbfa9f27) ───────────────
# O default anterior era `HEAD~1`, e ele e' DEGENERADO por construcao: depois
# de qualquer commit que mexa na aritmetica, `HEAD~1` ja e' a aritmetica NOVA.
# Medido: rodando com `HEAD~1` (o commit-base resolve para o item 3, que ja
# traz o `max` com o teto total) o PASSO 1 deu 2 failures — a aritmetica "antiga"
# que o script buscava JA ERA a nova, entao o par nao tinha um par. O script ainda
# imprimia "ESPERADO: 0 failures" ao lado do 2 failures e saia com 0: o par falso
# passava por prova. Por isso o parametro passou a ser OBRIGATORIO: quem nao
# disser qual e' a aritmetica antiga nao esta' rodando par nenhum.
COMMIT_ANTES="${1:-}"
[ -n "$COMMIT_ANTES" ] \
  || { echo "ERRO: informe o commit-base (a aritmetica ANTIGA que deve ficar verde)."; \
       echo "  uso: $0 <commit>   # ex.: $0 971308d"; \
       echo "  O default HEAD~1 e' degenerado: depois do commit da aritmetica nova, ele ja e' a nova."; exit 2; }
TMP="$(mktemp -d)"
trap 'cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER" 2>/dev/null; rm -rf "$TMP"' EXIT

# `git show` precisa rodar na raiz do repo, e o script pode ser chamado de fora.
( cd "$RAIZ" && git show "$COMMIT_ANTES:$ARQ_TESTE" ) > "$TMP/teste-antigo.rb" 2>/dev/null \
  || { echo "ERRO: nao achei o teste antigo em $COMMIT_ANTES (informe o commit: $0 <commit>)"; exit 1; }
# O GUARD (item 4 do #205) — o que ele PROTEGE, e o que ele JA protegeva
# ────────────────────────────────────────────────────────────────────────────
# O QUE ELE DEVE PROTEGER: "este arquivo afirma a aritmética dos tetos contra um
# teto". O QUE ELE FAZIA (e por isso o comentário mentia): um
# `grep -q 'pior_caso'` no ARQUIVO INTEIRO. Esse token aparece na VARIÁVEL
# local (`requisicoes, por_requisicao, pior_caso = ...`), no `puts` de
# diagnóstico e na própria mensagem de falha do arquivo anti-engano — então o
# guard passava num arquivo em que a asserção de teto não existe mais, que é
# exatamente o que ele deveria rejeitar.
#
# O guard agora casa com a ASSERÇÃO: uma linha `assert_operator` que compare uma
# variável de pior caso contra um teto. É isso que distingue "a aritmética dos
# tetos está aqui" de "a palavra aparece aqui".
#
# E o guard sozinho NÃO bastava: ele garante que o arquivo do commit-base tem
# a asserção, mas NÃO que o PASSO 1 saiu verde. Quem garante isso é o veredito
# do par, no fim do script (`registrar` + `exit 1`) — medido: com o commit-base
# degenerado o passo 1 deu 2 failures e o script antigo saía com 0.
tem_assert_de_pior_caso() {
  grep -qE 'assert_operator +[a-z_]*pior_caso[a-z_]*, *:<=' "$1"
}
tem_assert_de_pior_caso "$TMP/teste-antigo.rb" \
  || { echo "ERRO: o teste em $COMMIT_ANTES nao afirma pior caso contra teto"; exit 1; }

rodar_aritmetica() {
  docker compose -f docker/docker-compose.yml run --rm test test "$ARQ_TESTE" -n "/pior_caso/" 2>&1
}

# A MUTAÇÃO TAMBÉM PRECISA MUDAR (item 4 do #205)
#
# Com a aritmética corrigida, o pior caso de UMA requisição é o MAIOR entre
# `read`, `open` e o TETO TOTAL — não a soma. Subir só o read para 8s (o valor
# antigo desta mutação) NÃO muda o `max` enquanto o teto total for 8s: o par
# viraria falso, e um par falso é pior que par nenhum. A mutação sobe o read
# ACIMA do teto total, que é o que a aritmética real escolhe como relógio
# dominante.
#
# POR QUE O FILTRO `/pior_caso/`: os testes de CONFIGURAÇÃO do cliente
# comparam `conn.options.timeout` com a constante e pegam QUALQUER mudança no
# read, inclusive o aumento. O que o card quer provado é o par sobre a
# ARITMÉTICA — a que prometia o pior caso. Sem o filtro, o passo 1 acusaria uma
# falha de configuração e o par seria falso. O filtro casa pelo NOME
# UNDERSCORED do método (o minitest não casa com a prosa do título: medido,
# `-n "/teto do join/"` roda 0 testes e `-n "/pior_caso/"` roda os 2), e o
# token existe no nome dos testes de aritmética dos DOIS lados do par.
aplicar_mutacao_read() {
  sed -i 's|^    HTTP_READ_TIMEOUT = 3$|    HTTP_READ_TIMEOUT = 20|' "$ARQ_RESOLVER"
  grep -qP '^    HTTP_READ_TIMEOUT = 20$' "$ARQ_RESOLVER" \
    || { echo "ERRO: a mutacao do read timeout NAO foi aplicada"; exit 1; }
}

aplicar_mutacao_remocao() {
  sed -i '/conn\.options\.timeout = HTTP_READ_TIMEOUT/d' "$ARQ_RESOLVER"
  grep -q 'conn.options.timeout' "$ARQ_RESOLVER" \
    && { echo "ERRO: a remocao NAO foi aplicada"; exit 1; }
  return 0
}

resultado() { grep -oE '[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors' "$1" | head -1; }
read_atual() { grep -oP 'HTTP_READ_TIMEOUT = \K\d+' "$ARQ_RESOLVER"; }
join_atual() { grep -oP 'BACKGROUND_JOIN_TIMEOUT = \K[0-9.]+' "$ARQ_RESOLVER"; }
total_atual() { grep -oP 'HTTP_TOTAL_TIMEOUT = \K[0-9.]+' "$ARQ_RESOLVER"; }

# Quantas falhas/errors o passo N produziu. `resultado` acima é só o TEXTO que
# se imprime; quem julga é este numero — ler a palavra "ESPERADO" ao lado de
# um veredito vermelho e sair com 0 é como um par FALSO passa por prova.
#   MEDIDO (card t_cbfa9f27): com o commit-base errado o passo 1 deu 2 failures
#   e o script imprimiu "ESPERADO: 0 failures" ao lado, e saiu com exit 0.
falhas_do_passo() { grep -oE '[0-9]+ failures, [0-9]+ errors' "$1" | head -1 | grep -oE '^[0-9]+'; }

# Acumula o veredito dos tres passos. Um par so' prova alguma coisa se o
# VERDE vier do lado que tem de ser cego a mutacao e o VERMELHO do lado que
# tem de ve-la; qualquer outra combinacao e' par degenerado.
PAR_FALHAS=0
registrar() { # registrar <n> <log> <esperado: verde|vermelho> <rotulo>
  local n="$1" log="$2" esperado="$3" rotulo="$4"
  local f; f="$(falhas_do_passo "$log")"
  [ -n "$f" ] || f=0
  local obtido; case "$esperado" in
    verde)   obtido=$(( f == 0 ? 0 : 1 )) ;;
    vermelho) obtido=$(( f >= 1 ? 0 : 1 )) ;;
  esac
  if [ "$obtido" -eq 0 ]; then
    echo "PASSO $n VEREDITO: CONFIRMADO ($(resultado "$log"))"
  else
    echo "PASSO $n VEREDITO: NAO CONFIRMADO ($(resultado "$log")) <- esperava $rotulo"
    PAR_FALHAS=$((PAR_FALHAS + 1))
  fi
}

cp "$ARQ_RESOLVER" "$TMP/resolver.bom.rb"
cp "$ARQ_TESTE" "$TMP/teste-novo.rb"

echo "################################################################"
echo "# PASSO 1 — VERDE COM MUTACAO: a aritmetica ANTIGA (soma so o open)"
echo "################################################################"
cp "$TMP/teste-antigo.rb" "$ARQ_TESTE"
# Join no valor antigo (10.0), para casar com a aritmetica antiga.
sed -i 's|^    BACKGROUND_JOIN_TIMEOUT = 25\.0$|    BACKGROUND_JOIN_TIMEOUT = 10.0|' "$ARQ_RESOLVER"
aplicar_mutacao_read
# A aritmetica ANTIGA soma SO o open (3s): a mutacao do read e' invisivel para ela.
echo "-- mutacao: HTTP_READ_TIMEOUT = $(read_atual)s (teto total = $(total_atual)s)"
echo "-- aritmetica ANTIGA: soma so o open = 3s -> pior caso = 3 x 3s = 9s, contra join de 10.0s"
rodar_aritmetica > "$TMP/passo1.log"
grep -E "MEDIDO" "$TMP/passo1.log"
echo "RESULTADO PASSO 1: $(resultado "$TMP/passo1.log")  <- ESPERADO: 0 failures"
registrar 1 "$TMP/passo1.log" verde "0 failures (a aritmetica ANTIGA tem de ser CEGA a mutacao do read)"

echo
echo "################################################################"
echo "# PASSO 2 — VERMELHO COM A MESMA MUTACAO: a aritmetica NOVA (teto total)"
echo "################################################################"
cp "$TMP/teste-novo.rb" "$ARQ_TESTE"
cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER"
aplicar_mutacao_read
echo "-- mutacao: HTTP_READ_TIMEOUT = $(read_atual)s (ACIMA do teto total de $(total_atual)s: agora o read domina o max)"
echo "-- aritmetica NOVA: max(read, open, teto total) = $(read_atual)s -> pior caso = 3 x $(read_atual)s = $((3 * $(read_atual)))s, contra join de 25.0s"
rodar_aritmetica > "$TMP/passo2.log"
grep -E "MEDIDO|Expected .* to be <=" "$TMP/passo2.log"
echo "RESULTADO PASSO 2: $(resultado "$TMP/passo2.log")  <- ESPERADO: >= 1 failure"
registrar 2 "$TMP/passo2.log" vermelho ">= 1 failure (a aritmetica NOVA tem de VER a mesma mutacao)"

echo
echo "################################################################"
echo "# PASSO 3 — VERMELHO COM A MUTACAO DE REMOCAO (o read some do cliente)"
echo "################################################################"
cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER"
aplicar_mutacao_remocao
echo "-- mutacao: a linha 'conn.options.timeout = HTTP_READ_TIMEOUT' foi removida"
rodar_aritmetica > "$TMP/passo3.log"
echo "RESULTADO PASSO 3: $(resultado "$TMP/passo3.log")  <- ESPERADO: >= 1 failure"
registrar 3 "$TMP/passo3.log" vermelho ">= 1 failure (sem o read no cliente a aritmetica tem de estourar)"

cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER"
echo
echo "restaurado: BACKGROUND_JOIN_TIMEOUT = $(join_atual), HTTP_READ_TIMEOUT = $(read_atual), HTTP_TOTAL_TIMEOUT = $(total_atual)"

# ── VEREDITO DO PAR (item 4 do #205) ───────────────────────────────────────
# O script precisa SAIR com codigo diferente de zero quando o par nao
# confirma. Antes ele imprimia a palavra "ESPERADO" ao lado do numero e saia
# com 0 sempre: um par falso (o passo 1 vermelho, que e' justamente o sinal de
# que o commit-base escolhido NAO e' a aritmetica antiga) saiaverde no CI.
echo "=============================================================================="
if [ "$PAR_FALHAS" -eq 0 ]; then
  echo "VEREDITO DO PAR: CONFIRMADO (verde com a aritmetica ANTIGA, vermelho com a NOVA)"
  exit 0
fi
echo "VEREDITO DO PAR: NAO CONFIRMADO ($PAR_FALHAS de 3 passos fora do esperado)"
echo "  O par so' prova alguma coisa com o commit-base CERTO: tem de ser o commit"
echo "  em que a aritmetica ANTIGA (a que ignora o read) ainda era a do HEAD."
echo "  $0 <commit>"
exit 1
