#!/usr/bin/env bash
# helpers.sh — micro-framework de testes (puro bash, sem dependências).
# Funciona em bash 3.2+ (macOS) e 4+/5+ (Linux). Sem bats, sem instalar nada.

TESTS_PASS=0
TESTS_FAIL=0

_t_green() { printf '\033[32m%s\033[0m' "$*"; }
_t_red()   { printf '\033[31m%s\033[0m' "$*"; }

# assert_eq "descrição" "esperado" "obtido"
assert_eq() {
  local desc="$1" esperado="$2" obtido="$3"
  if [[ "$esperado" == "$obtido" ]]; then
    printf '  %s %s\n' "$(_t_green ok)" "$desc"
    TESTS_PASS=$((TESTS_PASS+1))
  else
    printf '  %s %s\n' "$(_t_red 'NÃO OK')" "$desc"
    printf '      esperado: [%s]\n' "$esperado"
    printf '      obtido:   [%s]\n' "$obtido"
    TESTS_FAIL=$((TESTS_FAIL+1))
  fi
}

# assert_contains "descrição" "texto" "substring esperada"
assert_contains() {
  local desc="$1" texto="$2" sub="$3"
  if [[ "$texto" == *"$sub"* ]]; then
    printf '  %s %s\n' "$(_t_green ok)" "$desc"
    TESTS_PASS=$((TESTS_PASS+1))
  else
    printf '  %s %s\n' "$(_t_red 'NÃO OK')" "$desc"
    printf '      não encontrei [%s] em:\n      %s\n' "$sub" "$texto"
    TESTS_FAIL=$((TESTS_FAIL+1))
  fi
}

# assert_not_contains "descrição" "texto" "substring que NÃO deve aparecer"
assert_not_contains() {
  local desc="$1" texto="$2" sub="$3"
  if [[ "$texto" != *"$sub"* ]]; then
    printf '  %s %s\n' "$(_t_green ok)" "$desc"
    TESTS_PASS=$((TESTS_PASS+1))
  else
    printf '  %s %s\n' "$(_t_red 'NÃO OK')" "$desc"
    printf '      NÃO deveria conter [%s], mas continha.\n' "$sub"
    TESTS_FAIL=$((TESTS_FAIL+1))
  fi
}

t_section() { printf '\n• %s\n' "$*"; }

t_summary() {
  printf '\n──────────────────────────────────────────\n'
  printf 'Resultado: %d passou, %d falhou\n' "$TESTS_PASS" "$TESTS_FAIL"
  [[ "$TESTS_FAIL" -eq 0 ]]
}
