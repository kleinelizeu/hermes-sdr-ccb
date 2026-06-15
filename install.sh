#!/usr/bin/env bash
# install.sh — Bootstrap do "Hermes SDR by CCB".
# Uso (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/kleinelizeu/hermes-sdr-ccb/main/install.sh | bash
#
# Clona/atualiza o repositório, cria o comando global 'hermes-sdr' e abre o assistente.
set -euo pipefail

REPO_URL="${HERMES_SDR_REPO:-https://github.com/kleinelizeu/hermes-sdr-ccb.git}"
DEST="${HERMES_SDR_DEST:-/opt/hermes-sdr-ccb}"

c_ok()  { printf '\033[32m✔\033[0m %s\n' "$*"; }
c_err() { printf '\033[31m✘\033[0m %s\n' "$*" >&2; }
c_inf() { printf '→ %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  c_err "Rode como root:  curl -fsSL <url> | sudo bash"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  c_inf "Instalando o git..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1
  fi
  command -v git >/dev/null 2>&1 || { c_err "Não consegui instalar o git. Instale-o e tente de novo."; exit 1; }
fi

if [[ -d "$DEST/.git" ]]; then
  c_inf "Atualizando o Hermes SDR by CCB..."
  git -C "$DEST" pull --ff-only >/dev/null 2>&1 || c_inf "(seguindo com a versão local)"
else
  c_inf "Baixando o Hermes SDR by CCB..."
  git clone --depth 1 "$REPO_URL" "$DEST" >/dev/null 2>&1 || { c_err "Falha ao baixar o repositório ($REPO_URL)."; exit 1; }
fi

chmod +x "$DEST/instalar.sh" "$DEST/doctor.sh" 2>/dev/null || true

# Comando global 'hermes-sdr'
ln -sf "$DEST/instalar.sh" /usr/local/bin/hermes-sdr
c_ok "Comando 'hermes-sdr' instalado."

# Precisa de terminal interativo para as perguntas. curl|bash não tem stdin.
if [[ -t 0 ]]; then
  exec bash "$DEST/instalar.sh"
elif [[ -e /dev/tty ]]; then
  exec bash "$DEST/instalar.sh" </dev/tty
else
  c_ok "Instalado! Agora rode o assistente com:"
  printf '\n    hermes-sdr\n\n'
fi
