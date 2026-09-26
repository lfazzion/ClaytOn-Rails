#!/usr/bin/env bash
# Gera docker/searxng-runtime/settings.yml a partir do settings do repo,
# injetando a BRAVE_API_KEY da env (o !env da factory nao interpola; a key
# nunca vai pro git). Rode APOS alterar settings.yml, antes do up do searxng.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC="docker/searxng/settings.yml"
DST="docker/searxng-runtime/settings.yml"
ENV_FILE="docker/.env.searxng"
# A chave vive em docker/.env.searxng (nunca no git). Se nao veio pelo ambiente,
# carrega daqui — senao o braveapi sai sem API e o sintoma e SILENCIOSO: o motor
# fica ligado devolvendo nada, e ninguem ve. (medido 26/09/2026)
if [ -z "${BRAVE_API_KEY:-}" ] && [ -f "$ENV_FILE" ]; then
  BRAVE_API_KEY="$(sed -n 's/^BRAVE_API_KEY=//p' "$ENV_FILE" | head -n1 | tr -d '\r' | sed 's/^"//; s/"$//')"
  export BRAVE_API_KEY
fi
sed "s/__BRAVE_API_KEY__/${BRAVE_API_KEY:-}/g" "$SRC" > "$DST"
chmod 644 "$DST"
if [ -n "${BRAVE_API_KEY:-}" ]; then
  echo "OK: $DST gerado com key presente"
else
  echo "AVISO: $DST gerado SEM key — braveapi vai devolver NADA. Ponha BRAVE_API_KEY em $ENV_FILE"
fi