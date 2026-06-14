#!/usr/bin/env bash
# 20-perfil.sh — Cria o perfil dedicado 'sdr' e configura o Telegram dele.
#
# NOTA: nomes exatos de comandos/variáveis do Hermes podem variar entre versões.
# O passo é defensivo: tenta editar direto; se não reconhecer o formato, cai no
# assistente interativo do próprio Hermes (que guia o aluno).

PERFIL_PADRAO="sdr"

# Define PERFIL e caminhos derivados; salva no estado.
_definir_perfil() {
  local nome="${PERFIL:-$PERFIL_PADRAO}"
  if [[ "${MODO:-}" == "nativo" ]] && _perfil_existe "$nome" && ! passo_concluido perfil; then
    titulo "Já existe um agente chamado '$nome' nesta VPS."
    info "1) Usar/atualizar esse mesmo"
    info "2) Criar outro com um nome novo"
    local op; MENU_MAX=2
    perguntar op "O que prefere? (1 ou 2)" valida_opcao_menu "Digite 1 ou 2."
    if [[ "$op" == "2" ]]; then
      perguntar nome "Nome do novo agente (só letras minúsculas, ex.: sdrloja):" \
        valida_nome_perfil "Use só letras minúsculas e números, começando por letra."
    fi
  fi
  salvar_var PERFIL "$nome"
  if [[ "${MODO:-}" == "nativo" ]]; then
    salvar_var PERFIL_DIR "/root/.hermes/profiles/$nome"
    salvar_var CONFIG_FILE "/root/.hermes/profiles/$nome/config.yaml"
    salvar_var ENV_FILE "/root/.hermes/profiles/$nome/.env"
    salvar_var PERFIL_BIN "/root/.local/bin/$nome"
    salvar_var GATEWAY_SVC "hermes-gateway-$nome"
  fi
}

_perfil_existe() {
  local nome="$1"
  if [[ "${MODO:-}" == "nativo" ]]; then
    [[ -d "/root/.hermes/profiles/$nome" ]] && return 0
    hermes profile list 2>/dev/null | grep -qw "$nome"
  else
    return 1   # Docker: o agente é o do container (sem perfis múltiplos por padrão)
  fi
}

passo_perfil() {
  passo "CRIANDO O SEU AGENTE"
  _definir_perfil

  if [[ "${MODO:-}" == "docker" ]]; then
    nota "No Docker usamos o agente do próprio container."
    salvar_var PERFIL "default"
    _configurar_telegram_docker
    return 0
  fi

  # ── Nativo ──
  if _perfil_existe "$PERFIL"; then
    ok "Agente '$PERFIL' já existe — vou só conferir a configuração."
  else
    info "Criando o agente '$PERFIL' (copiando o que já funciona do seu Hermes)..."
    if hermes profile create "$PERFIL" --clone >/dev/null 2>&1; then
      ok "Agente '$PERFIL' criado."
    else
      erro "Não consegui criar o agente automaticamente."
      dica "Rode manualmente:  hermes profile create $PERFIL --clone   e depois rode este assistente de novo."
      return 1
    fi
  fi

  _reconfigurar_telegram_nativo
  _instalar_servico_nativo
}

# Sobrescreve o token/chat-id do Telegram no perfil (corrige o vazamento do --clone).
_reconfigurar_telegram_nativo() {
  local env="$ENV_FILE"
  if [[ ! -f "$env" ]]; then
    dica "Não achei o arquivo de configuração do perfil; vou usar o assistente do Hermes."
    _setup_gateway_interativo
    return
  fi
  backup_arquivo "$env"

  # Detecta a chave do token (varia: TELEGRAM_BOT_TOKEN / TELEGRAM_TOKEN / ...).
  local chave_token chave_chat
  chave_token="$(grep -oiE '^[A-Z_]*TELEGRAM[A-Z_]*TOKEN' "$env" | head -1 || true)"
  chave_chat="$(grep -oiE '^[A-Z_]*TELEGRAM[A-Z_]*(CHAT_?ID|USER_?ID|OWNER)' "$env" | head -1 || true)"

  if [[ -n "$chave_token" ]]; then
    _set_env_var "$env" "$chave_token" "$TELEGRAM_BOT_TOKEN"
    [[ -n "$chave_chat" ]] && _set_env_var "$env" "$chave_chat" "$TELEGRAM_CHAT_ID"
    ok "Token do Telegram do agente atualizado para o seu bot novo."
    _avisar_outros_tokens "$env"
  else
    dica "Não reconheci o formato do arquivo — vou abrir o assistente do Hermes (é só seguir as perguntas)."
    _setup_gateway_interativo
  fi
}

# _set_env_var arquivo CHAVE valor — substitui ou adiciona CHAVE=valor.
_set_env_var() {
  local arq="$1" chave="$2" valor="$3" tmp
  tmp="$(mktemp)"
  grep -viE "^${chave}=" "$arq" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$chave" "$valor" >> "$tmp"
  mv "$tmp" "$arq"
  chmod 600 "$arq" 2>/dev/null || true
}

# O --clone pode ter trazido outros tokens (Discord etc.). Alerta para rotacionar.
_avisar_outros_tokens() {
  local env="$1"
  if grep -qiE '(DISCORD|SLACK|WHATSAPP).*TOKEN' "$env"; then
    dica "Atenção: este perfil herdou tokens de outros serviços (Discord/Slack) do seu Hermes."
    dica "Por segurança, considere remover/rotacionar o que você não vai usar."
  fi
}

_setup_gateway_interativo() {
  caixa "ATENÇÃO: o assistente do Hermes vai abrir." \
        "Quando ele perguntar do Telegram, use:" \
        "  Token:   o do seu bot novo (@${BOT_USERNAME:-seu_bot})" \
        "  Seu ID:  ${TELEGRAM_CHAT_ID:-seu numero}"
  confirmar "Pronto pra abrir o assistente?" s || return 0
  "$PERFIL_BIN" setup gateway </dev/tty || hermes setup gateway </dev/tty || true
}

_instalar_servico_nativo() {
  if systemctl list-unit-files 2>/dev/null | grep -q "^${GATEWAY_SVC}"; then
    systemctl restart "$GATEWAY_SVC" 2>/dev/null || true
    ok "Serviço do agente reiniciado."
  else
    dica "O serviço que mantém o agente ligado ainda não existe."
    dica "No assistente do Hermes, escolha 'System service (starts on boot)' rodando como root."
    _setup_gateway_interativo
  fi
}

# Docker: garante que o token do Telegram do container é o do aluno.
_configurar_telegram_docker() {
  local env="$ENV_FILE"
  [[ -f "$env" ]] || { dica "Configure o Telegram pelo painel do seu Hermes."; return 0; }
  backup_arquivo "$env"
  local chave_token chave_chat
  chave_token="$(grep -oiE '^[A-Z_]*TELEGRAM[A-Z_]*TOKEN' "$env" | head -1 || true)"
  chave_chat="$(grep -oiE '^[A-Z_]*TELEGRAM[A-Z_]*(CHAT_?ID|USER_?ID|OWNER)' "$env" | head -1 || true)"
  if [[ -n "$chave_token" ]]; then
    _set_env_var "$env" "$chave_token" "$TELEGRAM_BOT_TOKEN"
    [[ -n "$chave_chat" ]] && _set_env_var "$env" "$chave_chat" "$TELEGRAM_CHAT_ID"
    ok "Token do Telegram atualizado no container (vai valer após o restart)."
  else
    dica "Configure o token do Telegram no .env do seu compose, se ainda não estiver."
  fi
}
