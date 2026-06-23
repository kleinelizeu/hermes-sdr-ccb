#!/usr/bin/env bash
# run.sh — Roda toda a suíte de testes do Hermes SDR by CCB.
# Uso:  bash tests/run.sh
# Sai com código != 0 se qualquer teste falhar (bom para CI).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FALHOU=0
for t in "$HERE"/test_*.sh; do
  printf '\n══════════════════════════════════════════\n'
  printf '▶ %s\n' "$(basename "$t")"
  printf '══════════════════════════════════════════\n'
  if bash "$t"; then :; else FALHOU=1; fi
done

printf '\n'
if [[ "$FALHOU" -eq 0 ]]; then
  printf '\033[32m✔ Todos os testes passaram.\033[0m\n'
else
  printf '\033[31m✘ Há testes falhando.\033[0m\n'
fi
exit "$FALHOU"
