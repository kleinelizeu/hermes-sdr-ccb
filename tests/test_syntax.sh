#!/usr/bin/env bash
# test_syntax.sh — Garante que todos os scripts do projeto têm sintaxe válida
# (bash -n) e que o vigia carrega sem erro. Barato e pega quebras de copy/paste.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"

t_section "Sintaxe (bash -n) de todos os scripts"
while IFS= read -r f; do
  rel="${f#$BASE_DIR/}"
  if bash -n "$f" 2>/dev/null; then
    assert_eq "bash -n $rel" "ok" "ok"
  else
    msg="$(bash -n "$f" 2>&1)"
    assert_eq "bash -n $rel" "ok" "ERRO: $msg"
  fi
done < <(find "$BASE_DIR" -name '*.sh' -not -path '*/.git/*' | sort)

t_summary
