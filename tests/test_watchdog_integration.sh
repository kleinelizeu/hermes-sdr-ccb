#!/usr/bin/env bash
# test_watchdog_integration.sh — Exercita as funções REAIS de I/O do vigia
# (sem stub): a recaptura de URL do log do cloudflared, o health-check /ready
# (com systemctl/curl falsos no PATH) e o aviso no Telegram. Pega bugs que os
# testes de orquestração (com dublês) não pegam: regex errado, porta errada,
# nome de serviço errado, payload do Telegram malformado.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"

# Carrega as funções REAIS (não sobrescreve nenhum seam wd__*).
source "$BASE_DIR/lib/45-watchdog.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermes-wd-int.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
ORIG_PATH="$PATH"

# ── Falsos systemctl e curl que registram chamadas e obedecem variáveis de env ──
cat > "$FAKEBIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
if [[ "$1" == "is-active" ]]; then
  [[ "${FAKE_SYSTEMCTL_ACTIVE:-1}" == "1" ]] && exit 0 || exit 3
fi
exit 0
FAKE
cat > "$FAKEBIN/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
for a in "$@"; do
  case "$a" in
    */ready) [[ "${FAKE_READY_OK:-1}" == "1" ]] && exit 0 || exit 22 ;;
  esac
done
exit 0
FAKE
chmod +x "$FAKEBIN/systemctl" "$FAKEBIN/curl"

export FAKE_SYSTEMCTL_LOG="$WORK/systemctl.log"
export FAKE_CURL_LOG="$WORK/curl.log"

# ──────────────────────────────────────────────────────────────────────────────
t_section "wd__recapture_url REAL: extrai a URL de um log de cloudflared de verdade"
fixture="$WORK/cloudflared.log"
cat > "$fixture" <<'LOG'
2026-06-23T15:00:00Z INF Thank you for trying Cloudflare Tunnel.
2026-06-23T15:00:01Z INF +-----------------------------------------------------+
2026-06-23T15:00:01Z INF |  Your quick Tunnel has been created! Visit it at:    |
2026-06-23T15:00:01Z INF |  https://teste-abc-123.trycloudflare.com             |
2026-06-23T15:00:01Z INF +-----------------------------------------------------+
2026-06-23T15:00:02Z INF Registered tunnel connection connIndex=0
LOG
WD_TUNNEL_LOG="$fixture"
assert_eq "recaptura monta URL + sufixo /webhooks/zernio" \
  "https://teste-abc-123.trycloudflare.com/webhooks/zernio" "$(wd__recapture_url)"

t_section "wd__recapture_url REAL: com várias URLs (restarts), pega a ÚLTIMA"
cat >> "$fixture" <<'LOG'
2026-06-23T16:00:01Z INF |  https://nova-xyz-999.trycloudflare.com              |
LOG
WD_TUNNEL_LOG="$fixture"
assert_eq "recaptura pega a URL mais recente" \
  "https://nova-xyz-999.trycloudflare.com/webhooks/zernio" "$(wd__recapture_url)"

t_section "wd__recapture_url REAL: log sem URL → vazio (cai no branch seguro)"
empty="$WORK/sem-url.log"; printf 'INF nada aqui\n' > "$empty"
WD_TUNNEL_LOG="$empty"
assert_eq "recaptura retorna vazio quando não há URL" "" "$(wd__recapture_url)"

# ──────────────────────────────────────────────────────────────────────────────
t_section "wd__ready_ok REAL: usa systemctl+curl falsos no PATH"
export PATH="$FAKEBIN:$ORIG_PATH"
WD_TUNNEL_SVC="cloudflared-sdr"
WD_METRICS_URL="http://127.0.0.1:20241"

: > "$FAKE_SYSTEMCTL_LOG"; : > "$FAKE_CURL_LOG"
FAKE_SYSTEMCTL_ACTIVE=1 FAKE_READY_OK=1 wd__ready_ok && r=0 || r=1
assert_eq "saudável (serviço ativo + /ready 200) → ok" "0" "$r"
assert_contains "consultou o /ready do endpoint de métricas" "$(cat "$FAKE_CURL_LOG")" "127.0.0.1:20241/ready"
assert_contains "checou is-active do serviço certo" "$(cat "$FAKE_SYSTEMCTL_LOG")" "is-active --quiet cloudflared-sdr"

: > "$FAKE_CURL_LOG"
FAKE_SYSTEMCTL_ACTIVE=1 FAKE_READY_OK=0 wd__ready_ok && r=0 || r=1
assert_eq "borda caída (/ready 503) → falha" "1" "$r"

: > "$FAKE_CURL_LOG"
FAKE_SYSTEMCTL_ACTIVE=0 FAKE_READY_OK=1 wd__ready_ok && r=0 || r=1
assert_eq "serviço parado → falha" "1" "$r"
assert_eq "curto-circuito: nem chamou o curl quando o serviço está parado" "" "$(cat "$FAKE_CURL_LOG")"
export PATH="$ORIG_PATH"

# ──────────────────────────────────────────────────────────────────────────────
t_section "wd__notify REAL: sem Telegram configurado → não quebra, registra"
WD_LOG="$WORK/wd.log"; : > "$WD_LOG"
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
wd__notify "https://x.trycloudflare.com/webhooks/zernio" >/dev/null 2>&1 && r=0 || r=1
assert_eq "retorna 0 mesmo sem Telegram" "0" "$r"
assert_contains "registrou que não havia Telegram" "$(cat "$WD_LOG")" "Sem Telegram"

t_section "wd__notify REAL: com Telegram → monta sendMessage com chat_id e URL"
export PATH="$FAKEBIN:$ORIG_PATH"
: > "$FAKE_CURL_LOG"
TELEGRAM_BOT_TOKEN="123456:ABCDEF" TELEGRAM_CHAT_ID="987654" \
  wd__notify "https://novo-xyz-999.trycloudflare.com/webhooks/zernio" >/dev/null 2>&1
curlargs="$(cat "$FAKE_CURL_LOG")"
assert_contains "chamou a API sendMessage do bot certo" "$curlargs" "api.telegram.org/bot123456:ABCDEF/sendMessage"
assert_contains "passou o chat_id" "$curlargs" "chat_id=987654"
assert_contains "incluiu a URL nova na mensagem" "$curlargs" "novo-xyz-999.trycloudflare.com/webhooks/zernio"
export PATH="$ORIG_PATH"

# ──────────────────────────────────────────────────────────────────────────────
t_section "Invariantes de configuração (porta/serviço batem entre lib e units)"
unit_tunel="$(cat "$BASE_DIR/modelos/cloudflared-sdr.service")"
lib_src="$(cat "$BASE_DIR/lib/45-watchdog.sh")"
# A porta de métricas que o vigia consulta (default da lib) tem que ser a mesma
# do --metrics do unit do cloudflared, senão o /ready nunca responde.
assert_contains "unit do túnel expõe --metrics na porta 20241" "$unit_tunel" "--metrics 127.0.0.1:20241"
assert_contains "default WD_METRICS_URL da lib usa a porta 20241" "$lib_src" "127.0.0.1:20241"
# O nome do serviço que o vigia reinicia tem que ser o do arquivo de unit.
assert_contains "default WD_TUNNEL_SVC da lib é cloudflared-sdr" "$lib_src" 'WD_TUNNEL_SVC:-cloudflared-sdr'

t_summary
