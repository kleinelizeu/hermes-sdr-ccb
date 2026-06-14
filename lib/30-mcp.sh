#!/usr/bin/env bash
# 30-mcp.sh — Conecta o agente ao Zernio via MCP.
# Tenta pela CLI; se não der, entrega uma mensagem pronta para o aluno colar no bot.

MCP_URL="https://mcp.zernio.com/mcp"

passo_mcp() {
  passo "CONECTANDO AO ZERNIO"

  if _mcp_ja_registrado; then
    ok "O Zernio já está conectado ao seu agente."
    return 0
  fi

  # A CLI tem 'mcp add'? (varia entre versões)
  if hermes_cli mcp --help 2>/dev/null | grep -q ' add'; then
    info "Registrando o Zernio automaticamente..."
    if hermes_cli mcp add zernio -- npx -y mcp-remote@latest "$MCP_URL" \
         --header "Authorization: Bearer $ZERNIO_API_KEY" >/dev/null 2>&1; then
      _reiniciar_gateway
      if _mcp_ja_registrado; then
        ok "Zernio conectado!"
        return 0
      fi
    fi
    dica "A conexão automática não confirmou — vamos pelo jeito manual (rápido)."
  fi

  _mcp_manual
}

_mcp_ja_registrado() {
  hermes_cli mcp list 2>/dev/null | grep -qi zernio
}

_mcp_manual() {
  local msg
  msg="$(sed "s|__API_KEY__|$ZERNIO_API_KEY|" "$BASE_DIR/modelos/mensagem-mcp-telegram.txt")"
  titulo "Conecte o Zernio pelo Telegram (1 minuto):"
  info "1. Abra a conversa com o seu bot @${BOT_USERNAME:-seu_bot}"
  info "2. Copie e mande a mensagem abaixo (ela já contém a sua chave):"
  copiavel "$msg"
  info "3. Espere o agente responder confirmando as ferramentas do Zernio."
  confirmar "Já mandou e o agente confirmou a conexão?" s || \
    dica "Tudo bem, você pode conferir depois com 'hermes-sdr doctor'."
}

_reiniciar_gateway() {
  if [[ "${MODO:-}" == "docker" ]]; then
    ( cd "$COMPOSE_DIR" && docker compose restart >/dev/null 2>&1 ) || true
  else
    systemctl restart "$GATEWAY_SVC" 2>/dev/null || true
  fi
  sleep 5
}
