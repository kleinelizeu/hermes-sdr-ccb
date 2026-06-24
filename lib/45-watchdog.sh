#!/usr/bin/env bash
# 45-watchdog.sh — Vigia (watchdog) do webhook: detecta a queda e reconecta sozinho.
#
# CAUSA-RAIZ que isto resolve:
#   No modo NATIVO o webhook é exposto por um *quick tunnel* do Cloudflare
#   (`cloudflared tunnel --url ...`), que gera uma URL efêmera *.trycloudflare.com.
#   Depois de alguns dias a conexão de borda (edge) do túnel cai silenciosamente:
#     • o PROCESSO continua vivo, então o `Restart=always` do systemd NUNCA dispara
#       (systemd só reinicia se o processo morre) → o túnel fica morto e o serviço
#       paralisado até alguém reiniciar na mão;
#     • mesmo quando reinicia, o quick tunnel ganha uma URL NOVA e aleatória, então
#       o endereço cadastrado no Zernio passa a apontar para o nada.
#
#   Solução: um vigia que roda a cada minuto, faz um HEALTH-CHECK de verdade do túnel
#   (endpoint /ready das métricas do cloudflared, que só responde 200 quando há
#   conexão de borda saudável), e quando detecta a queda RECONECTA sozinho, recaptura
#   a URL nova e — no modo nativo — ATUALIZA O ZERNIO SOZINHO via API (sem humano).
#
#   100% SEM TOQUE: quando a URL muda, o vigia chama a API do Zernio
#   (PUT /v1/webhooks/settings) e troca a Endpoint URL automaticamente, inclusive
#   reativando o webhook caso o Zernio o tenha desativado (ele desativa após 10
#   falhas seguidas de entrega). Só cai no aviso por Telegram (colar na mão) se a
#   API falhar — então o comportamento nunca fica PIOR do que era antes.
#
# Projetado para ser TESTÁVEL: toda dependência externa (systemctl, curl, relógio,
# Telegram, API do Zernio) está isolada em funções "seam" wd__* que os testes
# sobrescrevem.

# ── Configuração (sobrescrevível por env, útil nos testes) ────────────────────
WD_LOG="${WD_LOG:-/var/log/hermes-sdr-webhook.log}"
WD_TUNNEL_SVC="${WD_TUNNEL_SVC:-cloudflared-sdr}"
WD_TUNNEL_LOG="${WD_TUNNEL_LOG:-/var/log/cloudflared-sdr.log}"
WD_METRICS_URL="${WD_METRICS_URL:-http://127.0.0.1:20241}"
WD_WAIT_TRIES="${WD_WAIT_TRIES:-15}"   # tentativas após reiniciar antes de desistir do ciclo
WD_WAIT_SLEEP="${WD_WAIT_SLEEP:-2}"    # segundos entre tentativas
WD_CONFIRM_SLEEP="${WD_CONFIRM_SLEEP:-3}"  # pausa antes de RECONFIRMAR a queda (debounce)
WD_ZERNIO_API="${WD_ZERNIO_API:-https://zernio.com/api/v1/webhooks/settings}"  # endpoint de webhooks

# ── Log com timestamp (observabilidade) ──────────────────────────────────────
wd__now() { date '+%Y-%m-%d %H:%M:%S'; }
wd_log() {
  local linha; linha="$(wd__now) [watchdog] $*"
  printf '%s\n' "$linha" >> "$WD_LOG" 2>/dev/null || true
  printf '%s\n' "$linha"
}

# ── Seams (dependências externas isoladas; testes redefinem estas funções) ────

# Túnel saudável? Verdadeiro só quando o serviço está ativo E a borda do
# cloudflared respondeu no /ready (200). Pega tanto "processo morreu" quanto
# "processo vivo mas conexão de borda caiu" (o caso que paralisa o serviço).
wd__ready_ok() {
  systemctl is-active --quiet "$WD_TUNNEL_SVC" 2>/dev/null || return 1
  curl -fsS --max-time 5 "$WD_METRICS_URL/ready" >/dev/null 2>&1
}

# Reinicia o túnel (reconexão).
wd__restart_tunnel() {
  # Zera o log do cloudflared ANTES de reiniciar: o log é append-only, então sem
  # isso a recaptura (grep | tail -1) poderia pegar uma URL antiga acumulada de
  # um boot anterior em vez da nova. Limpando, o tail -1 só vê a URL atual.
  { : > "$WD_TUNNEL_LOG"; } 2>/dev/null || true
  systemctl restart "$WD_TUNNEL_SVC" 2>/dev/null
}

# Lê a URL pública atual a partir do log do cloudflared.
wd__recapture_url() {
  local base
  base="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$WD_TUNNEL_LOG" 2>/dev/null | tail -1 || true)"
  [[ -n "$base" ]] && printf '%s/webhooks/zernio' "$base"
}

# Persiste uma variável no estado (salvar_var vem do 00-core.sh).
wd__persist() {
  if type salvar_var >/dev/null 2>&1; then
    salvar_var "$1" "$2"
  else
    printf -v "$1" '%s' "$2"
  fi
}

# Persiste a nova URL pública no estado.
wd__save_url() { wd__persist WEBHOOK_URL "$1"; }

# Espera (isolado para os testes não dormirem de verdade).
wd__sleep() { sleep "${1:-2}"; }

# Aviso amistoso (FALLBACK NÃO foi preciso): a URL mudou e o vigia já atualizou
# o Zernio sozinho — o usuário não precisa fazer nada. Apenas informativo.
wd__notify_ok() {
  local url="$1"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
  local texto="✅ O endereço do seu webhook mudou e eu JÁ ATUALIZEI no Zernio automaticamente. Você não precisa fazer nada.

Novo endereço:
${url}"
  curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${texto}" >/dev/null 2>&1 || true
}

# Aviso de FALLBACK: só usado quando o update automático no Zernio NÃO deu certo.
# Aí sim pede para o humano colar a URL nova no painel. Sem Telegram, só registra.
wd__notify() {
  local url="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    wd_log "Sem Telegram configurado — não consegui avisar do novo endereço."
    return 0
  fi
  local texto
  texto="⚠️ O endereço do seu webhook MUDOU e NÃO consegui atualizar no Zernio sozinho.

Novo endereço:
${url}

Atualize no painel do Zernio: Webhooks → seu webhook → Endpoint URL."
  curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${texto}" >/dev/null 2>&1 || true
}

# ── Integração com a API do Zernio (atualização automática da Endpoint URL) ───
# Doc: base https://zernio.com/api/v1 · Bearer sk_ · /v1/webhooks/settings
#   GET  lista os webhooks · PUT atualiza (body {_id,url,isActive}) · POST cria.

# GET da lista de webhooks (JSON cru no stdout). Seam: testes mockam.
wd__zernio_list() {
  curl -fsS --max-time 15 -H "Authorization: Bearer ${ZERNIO_API_KEY:-}" \
    "$WD_ZERNIO_API" 2>/dev/null
}

# PUT: troca a url do webhook _id e o reativa (isActive). Seam: testes mockam.
# Retorna 0 só com HTTP 2xx.
wd__zernio_put() {
  local id="$1" url="$2" body code
  body="$(WD_ID="$id" WD_URL="$url" python3 -c 'import json,os; print(json.dumps({"_id":os.environ["WD_ID"],"url":os.environ["WD_URL"],"isActive":True}))' 2>/dev/null)" || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X PUT "$WD_ZERNIO_API" \
    -H "Authorization: Bearer ${ZERNIO_API_KEY:-}" -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null || echo 000)"
  [[ "$code" == 2[0-9][0-9] ]]
}

# DELETE: remove o webhook _id (query param ?id=). Seam. Retorna 0 só com 2xx.
wd__zernio_delete() {
  local id="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X DELETE \
    "$WD_ZERNIO_API?id=${id}" \
    -H "Authorization: Bearer ${ZERNIO_API_KEY:-}" 2>/dev/null || echo 000)"
  [[ "$code" == 2[0-9][0-9] ]]
}

# POST: cria o webhook. Imprime o _id criado no stdout. Seam: testes mockam.
wd__zernio_create() {
  local url="$1" secret="$2" resp
  local body
  body="$(WD_URL="$url" WD_SECRET="$secret" python3 -c 'import json,os; print(json.dumps({"name":"Hermes SDR","url":os.environ["WD_URL"],"events":["message.received","comment.received"],"secret":os.environ.get("WD_SECRET") or "","isActive":True}))' 2>/dev/null)" || return 1
  resp="$(curl -fsS --max-time 15 -X POST "$WD_ZERNIO_API" \
    -H "Authorization: Bearer ${ZERNIO_API_KEY:-}" -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null)" || return 1
  printf '%s' "$resp" | wd__zernio_extract_id
}

# Extrai o _id de uma resposta JSON (objeto direto, {data:{...}} etc). Lê do
# stdin. Usa `python3 -c` (não heredoc) para o stdin continuar sendo o pipe.
wd__zernio_extract_id() {
  python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
def wid(w):
    return (w.get("_id") or w.get("id") or "") if isinstance(w,dict) else ""
print((wid(d) or wid(d.get("data")) or wid(d.get("webhook")) or wid(d.get("settings"))) if isinstance(d,dict) else "")' 2>/dev/null
}

# Acha o _id do NOSSO webhook na lista (o que bate com a URL antiga; senão o que
# termina em /webhooks/zernio). Função pura (sem rede) → fácil de testar.
wd__zernio_find_id() {
  local listjson="$1" old="$2"
  WD_LIST="$listjson" WD_OLD="$old" python3 - 2>/dev/null <<'PY'
import json, os, sys
raw = os.environ.get("WD_LIST") or ""
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)
items = data if isinstance(data, list) else (
    data.get("data") or data.get("webhooks") or data.get("settings") or data.get("results") or [])
if not isinstance(items, list):
    items = []
old = os.environ.get("WD_OLD", "")
def wid(w): return w.get("_id") or w.get("id") or ""
chosen = ""
for w in items:                       # 1) bate exatamente com a URL antiga
    if isinstance(w, dict) and old and w.get("url") == old:
        chosen = wid(w); break
if not chosen:                        # 2) termina em /webhooks/zernio (o nosso padrão)
    for w in items:
        if isinstance(w, dict) and str(w.get("url", "")).rstrip("/").endswith("/webhooks/zernio"):
            chosen = wid(w); break
print(chosen)
PY
}

# TODOS os _id dos NOSSOS webhooks (url termina em /webhooks/zernio), um por linha.
# Função pura (sem rede) → usada pela consolidação para achar os duplicados.
wd__zernio_find_all_ids() {
  WD_LIST="$1" python3 - 2>/dev/null <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ.get("WD_LIST") or "")
except Exception:
    sys.exit(1)
items = data if isinstance(data, list) else (
    data.get("data") or data.get("webhooks") or data.get("settings") or data.get("results") or [])
if not isinstance(items, list):
    items = []
for w in items:
    if isinstance(w, dict) and str(w.get("url", "")).rstrip("/").endswith("/webhooks/zernio"):
        wid = w.get("_id") or w.get("id") or ""
        if wid:
            print(wid)
PY
}

# CONSOLIDA o Zernio: garante UM ÚNICO webhook apontando para $url (atualiza o
# existente ou cria) e APAGA os duplicados (os outros que terminam em
# /webhooks/zernio). É o coração do "sem toque": mesmo que a URL tenha trocado
# várias vezes e acumulado webhooks mortos, o resultado é sempre 1 webhook vivo.
# Retorna 0 se conseguiu deixar o Zernio apontando para $url.
zernio_consolidar() {
  local url="$1"
  [[ -n "${ZERNIO_API_KEY:-}" ]] || return 1
  local listjson ids keep="" id
  listjson="$(wd__zernio_list)" || return 1
  ids="$(wd__zernio_find_all_ids "$listjson")"
  # Qual manter: o já cacheado (se ainda existe na lista) ou o primeiro encontrado.
  if [[ -n "${ZERNIO_WEBHOOK_ID:-}" ]] && printf '%s\n' "$ids" | grep -qxF "$ZERNIO_WEBHOOK_ID"; then
    keep="$ZERNIO_WEBHOOK_ID"
  else
    keep="$(printf '%s\n' "$ids" | sed '/^$/d' | head -1)"
  fi
  if [[ -z "$keep" ]]; then
    keep="$(wd__zernio_create "$url" "${WEBHOOK_SECRET:-}")" || return 1
    [[ -n "$keep" ]] || return 1
  else
    wd__zernio_put "$keep" "$url" || return 1
  fi
  wd__persist ZERNIO_WEBHOOK_ID "$keep"
  # Apaga os duplicados (todo o resto que é nosso). Sem subshell (process subst.)
  # para o contador sobreviver.
  local apagados=0
  while IFS= read -r id; do
    [[ -n "$id" && "$id" != "$keep" ]] || continue
    if wd__zernio_delete "$id"; then
      apagados=$((apagados+1))
      wd_log "Webhook duplicado removido do Zernio: $id"
    fi
  done < <(printf '%s\n' "$ids")
  [[ "$apagados" -gt 0 ]] && wd_log "Consolidação do Zernio: $apagados webhook(s) duplicado(s) removido(s); mantido $keep."
  return 0
}

# Atualiza a URL do nosso webhook direto no Zernio, SEM humano (e consolida
# duplicados). Usada pelo vigia na troca de URL. Retorna 0 se OK.
wd__zernio_sync() { zernio_consolidar "$1"; }

# Garante o webhook no Zernio apontando para a URL atual (cria se não existe e
# consolida duplicados). Usada pelo wizard (setup sem toque) e pelo doctor.
zernio_garantir_webhook() {
  [[ -n "${ZERNIO_API_KEY:-}" && -n "${WEBHOOK_URL:-}" ]] || return 1
  zernio_consolidar "$WEBHOOK_URL"
}

# A URL mudou: salva, tenta atualizar o Zernio sozinho e só cai no aviso manual
# (Telegram) se a API falhar. WEBHOOK_URL (antigo) é lido por wd__zernio_sync
# para achar o _id ANTES de sobrescrevermos com a URL nova.
wd__on_url_change() {
  local new_url="$1"
  if wd__zernio_sync "$new_url"; then
    wd__save_url "$new_url"
    wd_log "Zernio ATUALIZADO automaticamente para a URL nova: $new_url (sem intervenção humana)."
    wd__notify_ok "$new_url"
  else
    wd__save_url "$new_url"
    wd_log "Não atualizei o Zernio sozinho (sem API key / webhook não encontrado / API fora) — avisando no Telegram para colar na mão."
    wd__notify "$new_url"
  fi
}

# ── Health-check do modo Docker (URL é estável via Traefik) ───────────────────
wd__ready_ok_docker() {
  [[ -n "${CONTAINER:-}" ]] || return 1
  docker exec "$CONTAINER" curl -sf --max-time 5 http://localhost:8644/health >/dev/null 2>&1
}
wd__restart_docker() {
  ( cd "${COMPOSE_DIR:-/tmp}" && docker compose up -d >/dev/null 2>&1 )
}

wd__tick_docker() {
  if wd__ready_ok_docker; then
    return 0
  fi
  wd_log "QUEDA detectada (Docker): o webhook não respondeu na porta 8644. Religando o container..."
  wd__restart_docker
  local i
  for ((i=1; i<=WD_WAIT_TRIES; i++)); do
    wd__ready_ok_docker && break
    wd__sleep "$WD_WAIT_SLEEP"
  done
  if wd__ready_ok_docker; then
    wd_log "RECONECTADO (Docker): webhook respondendo de novo. URL estável (Traefik), nada a atualizar no Zernio."
    return 0
  fi
  wd_log "FALHA (Docker): o webhook não voltou após religar o container. Tentando de novo no próximo ciclo."
  return 1
}

# Túnel saudável: confere só se a URL mudou por baixo dos panos (ex.: o systemd
# reiniciou o túnel sozinho após um crash → URL nova) e, se mudou, salva e avisa.
wd__handle_healthy() {
  local saved="$1" cur
  cur="$(wd__recapture_url)"
  if [[ -n "$cur" && -n "$saved" && "$cur" != "$saved" ]]; then
    wd_log "URL MUDOU (o túnel reiniciou fora do vigia): nova=$cur anterior=$saved"
    wd__on_url_change "$cur"
  fi
}

# ── Ciclo principal do vigia ──────────────────────────────────────────────────
# Retorna 0 quando o webhook está (ou voltou a ficar) saudável; 1 quando não
# conseguiu recuperar neste ciclo (o timer chama de novo no próximo minuto).
wd_tick() {
  if [[ "${MODO:-nativo}" == "docker" ]]; then
    wd__tick_docker
    return $?
  fi

  local saved="${WEBHOOK_URL:-}"

  if wd__ready_ok; then
    wd__handle_healthy "$saved"
    return 0
  fi

  # Debounce: antes de declarar queda (e reiniciar, o que troca a URL à toa),
  # espera um pouco e RECONFIRMA. Um soluço transitório do /ready — enquanto o
  # cloudflared reconecta a borda sozinho, logo após o boot, ou num pico de CPU —
  # não deve disparar um restart desnecessário (que geraria churn de URL e
  # spam no Telegram). Só agimos se a queda persistir na segunda checagem.
  wd__sleep "${WD_CONFIRM_SLEEP:-3}"
  if wd__ready_ok; then
    wd_log "Soluço transitório no health-check do túnel — recuperou sozinho (cloudflared reconectou a borda). Sem reinício."
    wd__handle_healthy "$saved"
    return 0
  fi

  # ── Queda confirmada (falhou duas checagens seguidas) ──
  wd_log "QUEDA confirmada: o túnel do webhook não está saudável (serviço parado ou conexão de borda caída). Iniciando reconexão automática..."
  wd__restart_tunnel

  local i
  for ((i=1; i<=WD_WAIT_TRIES; i++)); do
    wd__ready_ok && break
    wd__sleep "$WD_WAIT_SLEEP"
  done

  if ! wd__ready_ok; then
    wd_log "FALHA: o túnel não voltou a ficar saudável depois de reiniciar. Vou tentar de novo no próximo ciclo."
    return 1
  fi

  local cur; cur="$(wd__recapture_url)"
  if [[ -z "$cur" ]]; then
    wd_log "RECONECTADO: o túnel está saudável, mas ainda sem URL no log. O próximo ciclo confirma o endereço."
    return 0
  fi

  if [[ "$cur" != "$saved" ]]; then
    wd_log "RECONECTADO com URL NOVA: $cur (anterior: ${saved:-nenhuma}). Atualizando o Zernio..."
    wd__on_url_change "$cur"
  else
    wd_log "RECONECTADO com a MESMA URL: $cur. Nada a atualizar no Zernio."
  fi
  return 0
}

# ── Instalação dos serviços do vigia (chamado pelo wizard/doctor) ─────────────
_instalar_watchdog() {
  if ! command -v systemctl >/dev/null 2>&1; then
    nota "systemd ausente — vigia automático não instalado neste ambiente."
    return 0
  fi
  local svc="/etc/systemd/system/hermes-sdr-watchdog.service"
  local tmr="/etc/systemd/system/hermes-sdr-watchdog.timer"
  local bin="$BASE_DIR/watchdog.sh"
  chmod +x "$bin" 2>/dev/null || true
  sed "s#__WATCHDOG_BIN__#${bin}#" "$BASE_DIR/modelos/hermes-sdr-watchdog.service" > "$svc"
  cp "$BASE_DIR/modelos/hermes-sdr-watchdog.timer" "$tmr"
  systemctl daemon-reload
  systemctl enable --now hermes-sdr-watchdog.timer >/dev/null 2>&1 || systemctl restart hermes-sdr-watchdog.timer
  ok "Vigia automático do webhook ligado (verifica a cada minuto e religa sozinho)."
}
