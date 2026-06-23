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

# Localiza o Hermes (define PERFIL_BIN/CONTAINER se necessário para o modo Docker).
type _localizar_hermes >/dev/null 2>&1 && { _localizar_hermes 2>/dev/null || true; }

wd_tick || true
exit 0
