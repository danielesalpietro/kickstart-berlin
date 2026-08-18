#!/usr/bin/env bash
#
# boot-test-qemu.sh — boota un'ISO autoinstall in QEMU headless su un disco
# virtuale throwaway e verifica che l'installazione completi senza alcun
# prompt e che l'host risultante sia raggiungibile via SSH con la chiave
# iniettata a build-time.
#
# Usato dal job di integrazione in CI (.github/workflows/ci.yml) e
# utilizzabile anche in locale per validare un'ISO prima del boot su
# hardware reale.
#
# Uso:
#   scripts/boot-test-qemu.sh -i build/kickstart-berlin-*.iso -k /path/chiave_privata

set -euo pipefail

ISO=""
SSH_PRIVATE_KEY=""
TIMEOUT="${TIMEOUT:-3600}"
MEMORY_MB="${MEMORY_MB:-4096}"
DISK_SIZE="${DISK_SIZE:-20G}"
SSH_PORT="${SSH_PORT:-2222}"

usage() {
  cat <<EOF
Uso: $(basename "$0") -i <path-iso> -k <path-chiave-privata-ssh> [opzioni]

Opzioni:
  -i, --iso <path>       ISO autoinstall da testare (obbligatorio).
  -k, --ssh-key <path>   Chiave privata SSH corrispondente alla chiave
                          pubblica iniettata nell'ISO in fase di build
                          (obbligatorio).
  -t, --timeout <sec>    Timeout totale, install + boot + SSH
                          (default: ${TIMEOUT}).
  -m, --memory <MB>      RAM della VM (default: ${MEMORY_MB}).
      --disk-size <sz>   Dimensione disco virtuale throwaway (default: ${DISK_SIZE}).
      --ssh-port <port>  Porta host da inoltrare alla porta 22 guest
                          (default: ${SSH_PORT}).
  -h, --help             Mostra questo messaggio.
EOF
}

log() { printf '[boot-test] %s\n' "$*" >&2; }
err() { printf '[boot-test] ERRORE: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--iso) ISO="$2"; shift 2 ;;
    -k|--ssh-key) SSH_PRIVATE_KEY="$2"; shift 2 ;;
    -t|--timeout) TIMEOUT="$2"; shift 2 ;;
    -m|--memory) MEMORY_MB="$2"; shift 2 ;;
    --disk-size) DISK_SIZE="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

[[ -n "$ISO" ]] || err "-i/--iso obbligatorio"
[[ -f "$ISO" ]] || err "ISO non trovata: $ISO"
[[ -n "$SSH_PRIVATE_KEY" ]] || err "-k/--ssh-key obbligatorio"
[[ -f "$SSH_PRIVATE_KEY" ]] || err "chiave privata non trovata: $SSH_PRIVATE_KEY"

for bin in qemu-system-x86_64 qemu-img ssh; do
  command -v "$bin" >/dev/null 2>&1 || err "comando richiesto non trovato: $bin"
done

WORK_DIR="$(mktemp -d)"
QEMU_PID=""
cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

DISK="${WORK_DIR}/test-disk.qcow2"
qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null

KVM_ARGS=(-cpu max)
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_ARGS=(-enable-kvm -cpu host)
  log "KVM disponibile: uso accelerazione hardware."
else
  log "ATTENZIONE: /dev/kvm non disponibile, uso emulazione software (TCG, molto più lenta)."
fi

SERIAL_LOG="${WORK_DIR}/serial.log"
: > "$SERIAL_LOG"

log "Avvio QEMU (ISO: ${ISO}, RAM: ${MEMORY_MB}MB, disco: ${DISK_SIZE}) ..."
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -m "$MEMORY_MB" -smp 2 \
  -machine q35 \
  -display none -nographic -serial "file:${SERIAL_LOG}" -monitor none \
  -boot once=d \
  -cdrom "$ISO" \
  -drive "file=${DISK},if=virtio,format=qcow2" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
  >/dev/null 2>&1 &
QEMU_PID=$!

log "QEMU avviato (pid ${QEMU_PID}). Attendo il completamento dell'autoinstall e il"
log "riavvio nel sistema installato, poi provo il login SSH (timeout ${TIMEOUT}s) ..."

START_TS="$(date +%s)"
SSH_OK=0
while true; do
  NOW="$(date +%s)"
  ELAPSED=$(( NOW - START_TS ))
  if (( ELAPSED > TIMEOUT )); then
    break
  fi
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    err "QEMU è terminato inaspettatamente prima del timeout (vedi ${SERIAL_LOG})"
  fi
  if ssh -p "$SSH_PORT" -i "$SSH_PRIVATE_KEY" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o BatchMode=yes \
      admin@127.0.0.1 'echo QEMU_SSH_OK' 2>/dev/null | grep -q QEMU_SSH_OK; then
    SSH_OK=1
    break
  fi
  sleep 15
done

if [[ "$SSH_OK" != "1" ]]; then
  log "--- ultime 200 righe della console seriale (${SERIAL_LOG}) ---"
  tail -n 200 "$SERIAL_LOG" || true
  err "timeout: impossibile completare l'autoinstall e connettersi via SSH entro ${TIMEOUT}s"
fi

log "Login SSH riuscito con la chiave iniettata a build-time: autoinstall completato"
log "senza prompt, host installato e raggiungibile. Test superato."
