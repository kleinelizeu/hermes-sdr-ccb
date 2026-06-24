#!/usr/bin/env bash
# watchdog.sh — Entrada do vigia do webhook do Hermes SDR.
# Roda um ciclo de verificação/reconexão (chamado pelo timer systemd a cada minuto).
# Também pode ser rodado na mão para diagnosticar:  bash watchdog.sh
set -uo pipefail

# Resolve symlinks, igual ao instalar.sh/doctor.sh.
BASE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for f in "$BASE_DIR"/lib/*.sh; do source "$f"; done

init_estado 2>/dev/null || true
carregar_estado

# Nada configurado ainda nesta VPS? Não há o que vigiar — sai quieto.
if [[ -z "${MODO:-}" ]]; then
  exit 0
fi

# Em Docker o NOME do container pode mudar (recriação/upgrade/rename), então o
# valor salvo na instalação fica obsoleto. Redescobre ao vivo — exatamente como
# detectar_hermes e check_hermes fazem — em vez de confiar no nome persistido.
if [[ "${MODO:-}" == "docker" ]] && command -v docker >/dev/null 2>&1; then
  _c="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 hermes-agent || true)"
  [[ -n "$_c" ]] && CONTAINER="$_c"
fi

# Garante o log do vigia com permissão restrita (defesa em profundidade).
if [[ ! -e "$WD_LOG" ]]; then { : > "$WD_LOG"; } 2>/dev/null || true; fi
chmod 640 "$WD_LOG" 2>/dev/null || true

wd_tick || true
exit 0
