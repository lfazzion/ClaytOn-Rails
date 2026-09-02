#!/usr/bin/env bash
# Gera docker/searxng-runtime/settings.yml a partir do settings do repo,
# injetando a BRAVE_API_KEY da env (o !env da factory nao interpola; a key
# nunca vai pro git). Rode APOS alterar settings.yml, antes do up do searxng.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC="docker/searxng/settings.yml"
DST="docker/searxng-runtime/settings.yml"
sed "s/__BRAVE_API_KEY__/${BRAVE_API_KEY:-}/g" "$SRC" > "$DST"
chmod 644 "$DST"
if [ -n "${BRAVE_API_KEY:-}" ]; then
  echo "OK: $DST gerado com key presente"
else
  echo "OK: $DST gerado SEM key — braveapi fica sem API (verifique docker/.env.searxng)"
fi