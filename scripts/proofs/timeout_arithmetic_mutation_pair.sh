#!/usr/bin/env bash
# Prova do par por MUTAÇÃO da aritmética dos tetos (ressalva do #204, card
# t_35bcd11f, item 1). Os DOIS lados, com a MESMA mutação:
#
#   PASSO 1 — VERDE com mutação: a aritmética ANTIGA (soma só o open timeout)
#             ignora o read timeout, então a regressão passa.
#   PASSO 2 — VERMELHO com a MESMA mutação: a aritmética NOVA (soma open + read)
#             pega a regressão.
#   PASSO 3 — VERMELHO com a mutação de REMOÇÃO: o read timeout some do cliente.
#
# A mutação dos passos 1 e 2 é a MESMA: `HTTP_READ_TIMEOUT` de 3s para 8s, sem
# tocar em mais nada. O pior caso real passa de 3 x (3+3) = 18s para
# 3 x (3+8) = 33s, contra um join de 25,0s.
#
# POR QUE O FILTRO `/pior_caso/`: os testes de CONFIGURAÇÃO do cliente
# comparam `conn.options.timeout` com a constante e pegam QUALQUER mudança no
# read, inclusive o aumento. O que o card quer provado é o par sobre a
# ARITMÉTICA — a que prometia o pior caso. Sem o filtro, o passo 1 acusaria uma
# falha de configuração e o par seria falso.
#
# Uso:  bash scripts/proofs/timeout_arithmetic_mutation_pair.sh
# Requer: docker + o repo com `docker/docker-compose.yml`.
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$RAIZ"

ARQ_TESTE=test/lib/fetcher/x_query_id_resolver_timeout_test.rb
ARQ_RESOLVER=lib/fetcher/x_query_id_resolver.rb
TMP="$(mktemp -d)"
trap 'cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER" 2>/dev/null; rm -rf "$TMP"' EXIT

rodar_aritmetica() {
  docker compose -f docker/docker-compose.yml run --rm test test "$ARQ_TESTE" -n "/pior_caso/" 2>&1
}

# A mutação do read: 3s -> 8s. Separador `|` (o endereço da regex não tem `|`).
aplicar_mutacao_read() {
  sed -i 's|^    HTTP_READ_TIMEOUT = 3$|    HTTP_READ_TIMEOUT = 8|' "$ARQ_RESOLVER"
  grep -qP '^    HTTP_READ_TIMEOUT = 8$' "$ARQ_RESOLVER" \
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

cp "$ARQ_RESOLVER" "$TMP/resolver.bom.rb"
cp "$ARQ_TESTE" "$TMP/teste-novo.rb"
git show "HEAD:$ARQ_TESTE" > "$TMP/teste-antigo.rb" 2>/dev/null \
  || { echo "ERRO: o teste anterior nao esta no HEAD (rode depois do 1o commit)"; exit 1; }

echo "################################################################"
echo "# PASSO 1 — VERDE COM MUTACAO: a aritmetica ANTIGA (soma so o open)"
echo "################################################################"
cp "$TMP/teste-antigo.rb" "$ARQ_TESTE"
# Join no valor antigo (10.0), para casar com a aritmetica antiga.
sed -i 's|^    BACKGROUND_JOIN_TIMEOUT = 25\.0$|    BACKGROUND_JOIN_TIMEOUT = 10.0|' "$ARQ_RESOLVER"
aplicar_mutacao_read
echo "-- mutacao: HTTP_READ_TIMEOUT = $(read_atual)s  (pior caso real = 3 x (3+$(read_atual)) = $((3 * (3 + $(read_atual))))s)"
rodar_aritmetica > "$TMP/passo1.log"
grep -E "MEDIDO" "$TMP/passo1.log"
echo "RESULTADO PASSO 1: $(resultado "$TMP/passo1.log")  <- ESPERADO: 0 failures"

echo
echo "################################################################"
echo "# PASSO 2 — VERMELHO COM A MESMA MUTACAO: a aritmetica NOVA (open+read)"
echo "################################################################"
cp "$TMP/teste-novo.rb" "$ARQ_TESTE"
cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER"
aplicar_mutacao_read
echo "-- mutacao: HTTP_READ_TIMEOUT = $(read_atual)s  (pior caso real = 3 x (3+$(read_atual)) = $((3 * (3 + $(read_atual))))s)"
rodar_aritmetica > "$TMP/passo2.log"
grep -E "MEDIDO|Expected .* to be <=" "$TMP/passo2.log"
echo "RESULTADO PASSO 2: $(resultado "$TMP/passo2.log")  <- ESPERADO: >= 1 failure"

echo
echo "################################################################"
echo "# PASSO 3 — VERMELHO COM A MUTACAO DE REMOCAO (o read some do cliente)"
echo "################################################################"
cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER"
aplicar_mutacao_remocao
echo "-- mutacao: a linha 'conn.options.timeout = HTTP_READ_TIMEOUT' foi removida"
rodar_aritmetica > "$TMP/passo3.log"
echo "RESULTADO PASSO 3: $(resultado "$TMP/passo3.log")  <- ESPERADO: >= 1 failure"

cp "$TMP/resolver.bom.rb" "$ARQ_RESOLVER"
echo
echo "restaurado: BACKGROUND_JOIN_TIMEOUT = $(join_atual), HTTP_READ_TIMEOUT = $(read_atual)"
