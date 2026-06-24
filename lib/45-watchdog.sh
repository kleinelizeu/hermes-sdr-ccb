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
#   a URL nova, registra tudo em log e avisa no Telegram se a URL mudou.
#
# Projetado para ser TESTÁVEL: toda dependência externa (systemctl, curl, relógio,
# Telegram) está isolada em funções "seam" wd__* que os testes sobrescrevem.

# ── Configuração (sobrescrevível por env, útil nos testes) ────────────────────
WD_LOG="${WD_LOG:-/var/log/hermes-sdr-webhook.log}"
WD_TUNNEL_SVC="${WD_TUNNEL_SVC:-cloudflared-sdr}"
WD_TUNNEL_LOG="${WD_TUNNEL_LOG:-/var/log/cloudflared-sdr.log}"
WD_METRICS_URL="${WD_METRICS_URL:-http://127.0.0.1:20241}"
WD_WAIT_TRIES="${WD_WAIT_TRIES:-15}"   # tentativas após reiniciar antes de desistir do ciclo
WD_WAIT_SLEEP="${WD_WAIT_SLEEP:-2}"    # segundos entre tentativas
WD_CONFIRM_SLEEP="${WD_CONFIRM_SLEEP:-3}"  # pausa antes de RECONFIRMAR a queda (debounce)

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

# Persiste a nova URL no estado (salvar_var vem do 00-core.sh).
wd__save_url() {
  if type salvar_var >/dev/null 2>&1; then
    salvar_var WEBHOOK_URL "$1"
  else
    printf -v WEBHOOK_URL '%s' "$1"
  fi
}

# Espera (isolado para os testes não dormirem de verdade).
wd__sleep() { sleep "${1:-2}"; }

# Avisa no Telegram que a URL mudou (a única parte que precisa de um humano:
# colar a URL nova no painel do Zernio). Sem token/chat configurados, só registra.
wd__notify() {
  local url="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    wd_log "Sem Telegram configurado — não consegui avisar do novo endereço."
    return 0
  fi
  local texto
  texto="⚠️ O endereço do seu webhook MUDOU (o túnel reconectou sozinho).

Novo endereço:
${url}

Atualize no painel do Zernio: Webhooks → seu webhook → Endpoint URL."
  curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${texto}" >/dev/null 2>&1 || true
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
    wd__save_url "$cur"
    wd__notify "$cur"
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
    wd__save_url "$cur"
    wd_log "RECONECTADO com URL NOVA: $cur (anterior: ${saved:-nenhuma}). Avisando no Telegram para atualizar no Zernio."
    wd__notify "$cur"
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
