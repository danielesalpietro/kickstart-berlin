#!/usr/bin/env bash
#
# console-status.sh — schermata informativa persistente su tty1 (issue #27).
#
# kickstart-berlin non offre login locale per design (account "admin"
# bloccato, solo chiave SSH — vedi CLAUDE.md direttiva #1): senza questo
# script tty1 mostrerebbe solo un prompt di login sempre inutilizzabile
# (nessuna password valida esiste per nessun account). Ispirato alla DCUI
# di VMware ESXi (schermata con hostname/IP/hardware) — qui senza alcun
# equivalente di <F2>/<F12>: sola lettura, nessun input gestito
# (kickstart-berlin-console-status.service manda stdin a /dev/null), non
# introduce alcun modo di accesso locale in più. La shell classica resta
# disponibile sui terminali secondari (Alt+F2 ... Alt+F6), non toccati.
#
# Le funzioni di raccolta informazioni sono condivise con il banner SSH
# al login (motd-vastai-status, stessa issue) — vedi lib-node-status.sh,
# copiato accanto a questo script nello stesso passo di build.
#
# Loop infinito con refresh interno (l'IP può arrivare in ritardo via
# DHCP, come "Waiting for DHCP..." nella DCUI ESXi che ha ispirato questa
# issue). Niente "set -e": un singolo comando che fallisce in
# un'iterazione (es. nvidia-smi non ancora pronto subito dopo il boot)
# non deve terminare lo script, solo quella riga di stato in quel giro.
set -uo pipefail

REFRESH_INTERVAL_SECONDS=30

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib-node-status.sh
source "${SCRIPT_DIR}/lib-node-status.sh"

while true; do
  clear
  hostname_now="$(hostname)"
  ip_first="$(_first_ip)"

  cat <<EOF
================================================================================

  kickstart-berlin - ${hostname_now}

================================================================================

  $(_os_line)

  Indirizzi IP:
$(_ip_lines)
  Datastore:
$(_datastore_line)
  GPU:
$(_gpu_line)
EOF

  if _vastai_installed; then
    cat <<EOF
  Servizi Vast.ai:
$(_vastai_services_line)
  Macchina Vast.ai:
$(_vastai_machine_line)
EOF
  fi

  if [[ -n "$ip_first" ]]; then
    echo
    echo "  Accesso SSH:"
    echo "    ssh admin@${ip_first}"
  fi

  cat <<EOF

  Nessun login locale disponibile - solo chiave SSH.
  Shell locale (nessuna password valida): Alt+F2 ... Alt+F6.

================================================================================
  Aggiornato: $(date '+%Y-%m-%d %H:%M:%S')  -  refresh ogni ${REFRESH_INTERVAL_SECONDS}s
================================================================================
EOF

  sleep "$REFRESH_INTERVAL_SECONDS"
done
