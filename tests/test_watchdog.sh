#!/usr/bin/env bash
# test_watchdog.sh — Prova que o vigia detecta a queda do webhook e se recupera
# sozinho, SEM intervenção humana. Simula a queda derrubando o health-check de
# propósito e verifica a reconexão automática, a recaptura da URL, o aviso e os logs.
#
# Não toca em systemd/cloudflared de verdade: sobrescreve as funções "seam" wd__*
# do lib/45-watchdog.sh por dublês controlados pelo teste.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$HERE/.." && pwd)"

source "$HERE/helpers.sh"

# Dublê de salvar_var (do 00-core.sh): grava na variável de verdade, sem disco.
salvar_var() { printf -v "$1" '%s' "$2"; }

source "$BASE_DIR/lib/45-watchdog.sh"

MODO="nativo"
WD_WAIT_SLEEP=0
WD_LOG="$(mktemp "${TMPDIR:-/tmp}/hermes-wd.XXXXXX")"

# ── estado controlado pelo teste ──────────────────────────────────────────────
READY="up"          # "up" => túnel saudável; qualquer outra coisa => caído
RESTART_N=0         # quantas vezes o vigia reiniciou o túnel
NOTIFY_N=0          # quantas vezes avisou no Telegram
NOTIFY_URL=""       # qual URL foi avisada
NEXT_URL=""         # URL que o log do túnel "mostra" ao recapturar

# Reseta tudo e redefine os seams para o padrão controlado.
reset_cenario() {
  READY="up"; RESTART_N=0; NOTIFY_N=0; NOTIFY_URL=""; NEXT_URL=""
  : > "$WD_LOG"
  WD_WAIT_TRIES=5

  wd__ready_ok()       { [[ "$READY" == "up" ]]; }
  wd__restart_tunnel() { RESTART_N=$((RESTART_N+1)); }   # por padrão NÃO cura
  wd__recapture_url()  { [[ -n "$NEXT_URL" ]] && printf '%s' "$NEXT_URL"; }
  wd__notify()         { NOTIFY_N=$((NOTIFY_N+1)); NOTIFY_URL="$1"; }
  wd__sleep()          { :; }
}

# Roda um ciclo do vigia no shell atual (sem subshell, para os contadores valerem).
run_tick() {
  wd_tick >"${WD_LOG}.out" 2>&1
  TICK_RC=$?
  OUT="$(cat "${WD_LOG}.out")"
}

# ──────────────────────────────────────────────────────────────────────────────
t_section "Cenário 1: queda silenciosa do túnel → reconecta sozinho com URL NOVA"
reset_cenario
WEBHOOK_URL="https://antigo-abc.trycloudflare.com/webhooks/zernio"
READY="down"                                   # simula a QUEDA (edge caiu)
wd__restart_tunnel() { RESTART_N=$((RESTART_N+1)); READY="up"; }   # reiniciar cura
NEXT_URL="https://novo-xyz.trycloudflare.com/webhooks/zernio"      # URL muda no restart
run_tick
assert_eq        "ciclo termina com sucesso (rc=0)"          "0" "$TICK_RC"
assert_eq        "reiniciou o túnel exatamente 1x"           "1" "$RESTART_N"
assert_eq        "URL salva foi atualizada para a nova"      "$NEXT_URL" "$WEBHOOK_URL"
assert_eq        "túnel está saudável de novo"               "up" "$READY"
assert_eq        "avisou no Telegram exatamente 1x"          "1" "$NOTIFY_N"
assert_eq        "aviso levou a URL nova"                    "$NEXT_URL" "$NOTIFY_URL"
assert_contains  "log registrou a QUEDA detectada"          "$OUT" "QUEDA detectada"
assert_contains  "log registrou a RECONEXÃO com URL nova"   "$OUT" "RECONECTADO com URL NOVA"

t_section "Cenário 2: túnel saudável, mas a URL mudou por fora → atualiza e avisa"
reset_cenario
WEBHOOK_URL="https://antigo-abc.trycloudflare.com/webhooks/zernio"
READY="up"                                     # nunca caiu
NEXT_URL="https://outra-999.trycloudflare.com/webhooks/zernio"     # mas a URL é outra
run_tick
assert_eq        "não precisou reiniciar (rc=0)"             "0" "$TICK_RC"
assert_eq        "não reiniciou o túnel"                     "0" "$RESTART_N"
assert_eq        "URL salva foi atualizada"                  "$NEXT_URL" "$WEBHOOK_URL"
assert_eq        "avisou no Telegram"                        "1" "$NOTIFY_N"
assert_contains  "log registrou a mudança de URL"           "$OUT" "URL MUDOU"

t_section "Cenário 3: tudo saudável e URL igual → não faz nada (sem ruído/sem churn)"
reset_cenario
WEBHOOK_URL="https://estavel-123.trycloudflare.com/webhooks/zernio"
READY="up"
NEXT_URL="https://estavel-123.trycloudflare.com/webhooks/zernio"   # mesma URL
run_tick
assert_eq        "ciclo ok (rc=0)"                           "0" "$TICK_RC"
assert_eq        "não reiniciou o túnel"                     "0" "$RESTART_N"
assert_eq        "não avisou no Telegram"                    "0" "$NOTIFY_N"
assert_eq        "URL salva permaneceu a mesma"              "https://estavel-123.trycloudflare.com/webhooks/zernio" "$WEBHOOK_URL"
assert_not_contains "log não registrou QUEDA"               "$OUT" "QUEDA"

t_section "Cenário 4: túnel NÃO volta após reiniciar → reporta falha (não mente)"
reset_cenario
WEBHOOK_URL="https://antigo-abc.trycloudflare.com/webhooks/zernio"
READY="down"
WD_WAIT_TRIES=3
wd__restart_tunnel() { RESTART_N=$((RESTART_N+1)); }   # continua caído
NEXT_URL=""
run_tick
assert_eq        "ciclo reporta falha (rc=1)"               "1" "$TICK_RC"
assert_eq        "tentou reiniciar"                          "1" "$RESTART_N"
assert_contains  "log registrou a FALHA"                    "$OUT" "FALHA"
assert_eq        "não avisou URL nova falsa"                 "0" "$NOTIFY_N"

t_section "Cenário 5: caiu e voltou com a MESMA URL → reconecta sem reavisar Zernio"
reset_cenario
WEBHOOK_URL="https://mesma-777.trycloudflare.com/webhooks/zernio"
READY="down"
wd__restart_tunnel() { RESTART_N=$((RESTART_N+1)); READY="up"; }
NEXT_URL="https://mesma-777.trycloudflare.com/webhooks/zernio"     # voltou igual
run_tick
assert_eq        "ciclo ok (rc=0)"                           "0" "$TICK_RC"
assert_eq        "reiniciou 1x"                              "1" "$RESTART_N"
assert_eq        "não precisou avisar (URL igual)"          "0" "$NOTIFY_N"
assert_contains  "log registrou reconexão com a MESMA URL"  "$OUT" "MESMA URL"

# ── limpeza ───────────────────────────────────────────────────────────────────
rm -f "$WD_LOG" "${WD_LOG}.out" 2>/dev/null || true

t_summary
