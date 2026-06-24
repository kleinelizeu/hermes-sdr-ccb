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
# PUT (atualização do Zernio) → imprime o http_code (curl usa -w '%{http_code}')
for a in "$@"; do [[ "$a" == "PUT" ]] && { printf '%s' "${FAKE_PUT_CODE:-200}"; exit 0; }; done
# DELETE (remoção de duplicado) → imprime o http_code
for a in "$@"; do [[ "$a" == "DELETE" ]] && { printf '%s' "${FAKE_DELETE_CODE:-200}"; exit 0; }; done
is_post=0; for a in "$@"; do [[ "$a" == "POST" ]] && is_post=1; done
for a in "$@"; do
  case "$a" in
    */ready)      [[ "${FAKE_READY_OK:-1}" == "1" ]] && exit 0 || exit 22 ;;
    *sendMessage) exit 0 ;;                       # Telegram
  esac
done
if [[ "$is_post" == "1" ]]; then printf '%s' "${FAKE_POST_RESP:-}"; exit 0; fi
printf '%s' "${FAKE_GET_RESP:-}"                  # GET (lista de webhooks do Zernio)
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
t_section "wd__zernio_find_id REAL: acha o _id do nosso webhook na lista"
lista='[{"_id":"a1","url":"https://old-abc.trycloudflare.com/webhooks/zernio"},{"_id":"b2","url":"https://outro.com/hook"}]'
assert_eq "bate pela URL antiga exata" "a1" \
  "$(wd__zernio_find_id "$lista" "https://old-abc.trycloudflare.com/webhooks/zernio")"
assert_eq "URL antiga não está na lista → cai no sufixo /webhooks/zernio" "a1" \
  "$(wd__zernio_find_id "$lista" "https://sumiu.trycloudflare.com/webhooks/zernio")"
wrap='{"data":[{"id":"x9","url":"https://z.trycloudflare.com/webhooks/zernio"}]}'
assert_eq "entende resposta embrulhada em {data:[...]} e campo id" "x9" \
  "$(wd__zernio_find_id "$wrap" "")"
none='[{"_id":"c3","url":"https://nada.com/outro"}]'
assert_eq "nenhum webhook nosso → vazio" "" "$(wd__zernio_find_id "$none" "")"

t_section "wd__zernio_extract_id REAL: pega o _id da resposta de criação"
assert_eq "objeto direto" "new123" "$(printf '{\"_id\":\"new123\",\"url\":\"x\"}' | wd__zernio_extract_id)"
assert_eq "embrulhado em data" "d7" "$(printf '{\"data\":{\"_id\":\"d7\"}}' | wd__zernio_extract_id)"
assert_eq "resposta inválida → vazio" "" "$(printf 'nao-e-json' | wd__zernio_extract_id)"

t_section "wd__zernio_sync REAL: descobre o _id (GET), atualiza (PUT) e cacheia"
export PATH="$FAKEBIN:$ORIG_PATH"
: > "$FAKE_CURL_LOG"
unset ZERNIO_WEBHOOK_ID
ZERNIO_API_KEY="sk_teste"
WEBHOOK_URL="https://old-abc.trycloudflare.com/webhooks/zernio"
export FAKE_GET_RESP='[{"_id":"wh_42","url":"https://old-abc.trycloudflare.com/webhooks/zernio"}]'
export FAKE_PUT_CODE="200"
wd__zernio_sync "https://novo-xyz.trycloudflare.com/webhooks/zernio" && r=0 || r=1
log="$(cat "$FAKE_CURL_LOG")"
assert_eq      "sync retornou sucesso" "0" "$r"
assert_eq      "cacheou o _id descoberto em ZERNIO_WEBHOOK_ID" "wh_42" "${ZERNIO_WEBHOOK_ID:-}"
assert_contains "fez PUT no endpoint de webhooks do Zernio" "$log" "PUT"
assert_contains "PUT levou a URL NOVA" "$log" "novo-xyz.trycloudflare.com"
assert_contains "usou o Authorization Bearer com a chave" "$log" "Bearer sk_teste"

t_section "wd__zernio_sync REAL: sem API key → falha de cara (fallback p/ Telegram)"
unset ZERNIO_API_KEY ZERNIO_WEBHOOK_ID
: > "$FAKE_CURL_LOG"
wd__zernio_sync "https://qualquer.trycloudflare.com/webhooks/zernio" && r=0 || r=1
assert_eq "sem chave → retorna falha" "1" "$r"
assert_eq "sem chave → nem chamou a API (curl não foi usado)" "" "$(cat "$FAKE_CURL_LOG")"

t_section "zernio_garantir_webhook REAL: cria quando não existe"
: > "$FAKE_CURL_LOG"
unset ZERNIO_WEBHOOK_ID
ZERNIO_API_KEY="sk_teste"; WEBHOOK_URL="https://novo.trycloudflare.com/webhooks/zernio"; WEBHOOK_SECRET="segredo123"
export FAKE_GET_RESP='[]'                       # nenhum webhook ainda
export FAKE_POST_RESP='{"_id":"wh_novo"}'
zernio_garantir_webhook && r=0 || r=1
log="$(cat "$FAKE_CURL_LOG")"
assert_eq      "garantir retornou sucesso" "0" "$r"
assert_eq      "guardou o _id do webhook criado" "wh_novo" "${ZERNIO_WEBHOOK_ID:-}"
assert_contains "fez POST para criar o webhook" "$log" "POST"
export PATH="$ORIG_PATH"
unset ZERNIO_API_KEY ZERNIO_WEBHOOK_ID FAKE_GET_RESP FAKE_POST_RESP FAKE_PUT_CODE

t_section "wd__zernio_find_all_ids REAL: lista só os NOSSOS webhooks (sufixo /webhooks/zernio)"
lista3='[{"_id":"keep1","url":"https://a.trycloudflare.com/webhooks/zernio"},{"_id":"dup2","url":"https://b.trycloudflare.com/webhooks/zernio"},{"_id":"other","url":"https://x.com/naonosso"}]'
assert_eq "achou exatamente 2 webhooks nossos" "2" "$(wd__zernio_find_all_ids "$lista3" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_contains "inclui keep1" "$(wd__zernio_find_all_ids "$lista3")" "keep1"
assert_contains "inclui dup2"  "$(wd__zernio_find_all_ids "$lista3")" "dup2"
assert_not_contains "NÃO inclui o de outro domínio" "$(wd__zernio_find_all_ids "$lista3")" "other"

t_section "zernio_consolidar REAL: atualiza 1, APAGA os duplicados, ignora os de fora"
export PATH="$FAKEBIN:$ORIG_PATH"
: > "$FAKE_CURL_LOG"
unset ZERNIO_WEBHOOK_ID
ZERNIO_API_KEY="sk_teste"; WEBHOOK_SECRET="seg"
export FAKE_GET_RESP="$lista3"
export FAKE_PUT_CODE="200"; export FAKE_DELETE_CODE="200"
zernio_consolidar "https://novo.trycloudflare.com/webhooks/zernio" && r=0 || r=1
log="$(cat "$FAKE_CURL_LOG")"
assert_eq      "consolidar retornou sucesso" "0" "$r"
assert_eq      "manteve o 1º (keep1) como o webhook oficial" "keep1" "${ZERNIO_WEBHOOK_ID:-}"
assert_contains "atualizou (PUT) para a URL nova" "$log" "novo.trycloudflare.com"
assert_contains "APAGOU o duplicado dup2 (DELETE ?id=dup2)" "$log" "id=dup2"
assert_not_contains "NÃO apagou o webhook de outro domínio (other)" "$log" "id=other"
assert_not_contains "NÃO apagou o que manteve (keep1)" "$log" "id=keep1"
export PATH="$ORIG_PATH"
unset ZERNIO_API_KEY ZERNIO_WEBHOOK_ID FAKE_GET_RESP FAKE_PUT_CODE FAKE_DELETE_CODE

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
