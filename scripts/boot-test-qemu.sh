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
NUM_DISKS="${NUM_DISKS:-1}"
DATASTORE_MOUNT_ROOT="${DATASTORE_MOUNT_ROOT:-/grastorp/volumes}"
DATASTORE_SYMLINK_NAME="${DATASTORE_SYMLINK_NAME:-datastore}"
DATASTORE_FILESYSTEM="${DATASTORE_FILESYSTEM:-xfs}"

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
      --disk-size <sz>   Dimensione di ciascun disco virtuale throwaway
                          (default: ${DISK_SIZE}).
      --disks <1|2>      Numero di dischi virtuali da creare (Fase 2,
                          issue #2): deve corrispondere alla topologia
                          usata per generare l'ISO (--disks di
                          build-iso.sh). Default: ${NUM_DISKS}.
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
    --disks)
      [[ "$2" == 1 || "$2" == 2 ]] || err "--disks accetta solo 1 o 2, ricevuto: $2"
      NUM_DISKS="$2"; shift 2 ;;
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

DISK_ARGS=()
for ((i = 1; i <= NUM_DISKS; i++)); do
  DISK="${WORK_DIR}/test-disk-${i}.qcow2"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
  DISK_ARGS+=(-drive "file=${DISK},if=virtio,format=qcow2")
done
log "Dischi virtuali throwaway creati: ${NUM_DISKS} x ${DISK_SIZE}"

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
  "${DISK_ARGS[@]}" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
  >/dev/null 2>&1 &
QEMU_PID=$!

log "QEMU avviato (pid ${QEMU_PID}). Attendo il completamento dell'autoinstall e il"
log "riavvio nel sistema installato, poi provo il login SSH (timeout ${TIMEOUT}s) ..."

START_TS="$(date +%s)"
LAST_HEARTBEAT=0
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
  if (( ELAPSED - LAST_HEARTBEAT >= 120 )); then
    LAST_HEARTBEAT=$ELAPSED
    log "... ancora in attesa (${ELAPSED}s/${TIMEOUT}s) — ultima riga seriale: $(tail -n1 "$SERIAL_LOG" 2>/dev/null | tr -d '\r')"
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
  # WORK_DIR (e quindi SERIAL_LOG) viene rimosso dal trap di cleanup a fine
  # script: salva il log seriale completo accanto all'ISO prima che sparisca,
  # altrimenti l'unica diagnostica disponibile sarebbe la tail qui sotto
  # (insufficiente per errori tardivi, es. nei late-commands).
  PERSISTED_LOG="${ISO}.serial.log"
  cp "$SERIAL_LOG" "$PERSISTED_LOG" 2>/dev/null || true
  log "--- ultime 200 righe della console seriale (log completo: ${PERSISTED_LOG}) ---"
  tail -n 200 "$SERIAL_LOG" || true
  err "timeout: impossibile completare l'autoinstall e connettersi via SSH entro ${TIMEOUT}s"
fi

log "Login SSH riuscito con la chiave iniettata a build-time: autoinstall completato"
log "senza prompt, host installato e raggiungibile."

log "Verifico il mount del Datastore Grastorp (Fase 2, issue #2) ..."
SSH_CMD=(ssh -p "$SSH_PORT" -i "$SSH_PRIVATE_KEY" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 -o BatchMode=yes admin@127.0.0.1)
DATASTORE_LINK="${DATASTORE_MOUNT_ROOT}/${DATASTORE_SYMLINK_NAME}"
REMOTE_CHECK="set -e; target=\$(readlink -f '${DATASTORE_LINK}'); \
fstype=\$(findmnt -no FSTYPE --target \"\$target\"); \
[ \"\$fstype\" = '${DATASTORE_FILESYSTEM}' ]"
if ! "${SSH_CMD[@]}" "$REMOTE_CHECK"; then
  log "--- diagnostica remota (lsblk, findmnt, symlink) ---"
  "${SSH_CMD[@]}" "lsblk -f; echo ---; findmnt; echo ---; ls -la '${DATASTORE_MOUNT_ROOT}' 2>&1" || true
  err "Datastore non montato correttamente su ${DATASTORE_LINK} (atteso fstype ${DATASTORE_FILESYSTEM})"
fi

log "Datastore verificato: ${DATASTORE_LINK} montato come ${DATASTORE_FILESYSTEM}. Test superato."
