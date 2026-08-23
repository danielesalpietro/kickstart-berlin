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
# Questo file è un template: il placeholder __DATASTORE_MOUNT_ROOT__ e
# __DATASTORE_SYMLINK_NAME__ vengono sostituiti da scripts/build-iso.sh,
# stessa fonte/meccanismo di postinstall/setup.sh.
#
# Loop infinito con refresh interno (l'IP può arrivare in ritardo via
# DHCP, come "Waiting for DHCP..." nella DCUI ESXi che ha ispirato questa
# issue). Niente "set -e": un singolo comando che fallisce in
# un'iterazione (es. nvidia-smi non ancora pronto subito dopo il boot)
# non deve terminare lo script, solo quella riga di stato in quel giro.
set -uo pipefail

REFRESH_INTERVAL_SECONDS=30
DATASTORE_LINK="__DATASTORE_MOUNT_ROOT__/__DATASTORE_SYMLINK_NAME__"

# Esclude, oltre a "lo", le interfacce create da Docker (bridge
# "docker0", reti "br-*", veth dei container): IP privati mai
# raggiungibili dall'esterno, che qui sarebbero solo rumore/fuorvianti
# per l'operatore che cerca l'IP reale della macchina (issue #27:
# l'obiettivo è "leggere l'IP dallo schermo", non elencare ogni
# interfaccia del kernel). Stesso filtro AWK duplicato nelle due
# funzioni sotto (letterale, non interpolato da bash) per evitare i
# problemi di escaping di un programma AWK passato tramite variabile.
_ip_lines() {
  local out
  out="$(ip -brief addr show scope global up 2>/dev/null | awk '
    $1 == "lo" || $1 ~ /^docker[0-9]*$/ || $1 ~ /^br-/ || $1 ~ /^veth/ { next }
    { sub(/\/.*/, "", $3); print "    " $1 ": " $3 }
  ')"
  if [[ -z "$out" ]]; then
    echo "    In attesa di un indirizzo IP (DHCP)..."
  else
    printf '%s\n' "$out"
  fi
}

_first_ip() {
  ip -brief addr show scope global up 2>/dev/null | awk '
    $1 == "lo" || $1 ~ /^docker[0-9]*$/ || $1 ~ /^br-/ || $1 ~ /^veth/ { next }
    { sub(/\/.*/, "", $3); print $3; exit }
  '
}

_datastore_line() {
  if [[ -L "$DATASTORE_LINK" && -d "$DATASTORE_LINK" ]]; then
    local total avail
    read -r total avail < <(df -h --output=size,avail "$DATASTORE_LINK" 2>/dev/null | tail -n1)
    echo "    Montato - ${avail:-?} liberi su ${total:-?} (${DATASTORE_LINK})"
  else
    echo "    Non montato"
  fi
}

_gpu_line() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "    Nessuna GPU NVIDIA rilevata"
    return
  fi
  local info
  if info="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"; then
    printf '%s\n' "$info" | sed 's/^/    /'
  else
    echo "    Driver NVIDIA installato ma nvidia-smi non risponde"
  fi
}

_os_line() {
  local pretty_name="Ubuntu"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    pretty_name="${PRETTY_NAME:-Ubuntu}"
  fi
  echo "${pretty_name} (kernel $(uname -r))"
}

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
