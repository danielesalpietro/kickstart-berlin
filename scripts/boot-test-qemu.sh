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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

ISO=""
SSH_PRIVATE_KEY=""
TIMEOUT="${TIMEOUT:-3600}"
MEMORY_MB="${MEMORY_MB:-4096}"
DISK_SIZE="${DISK_SIZE:-20G}"
DISK_SIZE_2="${DISK_SIZE_2:-40G}"
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
      --disk-size <sz>   Dimensione del primo disco virtuale throwaway
                          (default: ${DISK_SIZE}). Con --disks 2 è il
                          disco "piccolo" atteso per il sistema
                          (euristica match:{size:smallest} di
                          iso/storage-dual-disk.yaml).
      --disk2-size <sz>  Dimensione del secondo disco (solo --disks 2,
                          default: ${DISK_SIZE_2}). Deve restare diversa
                          da --disk-size: dischi identici non
                          eserciterebbero davvero l'euristica
                          "più piccolo = sistema".
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
    --disk2-size) DISK_SIZE_2="$2"; shift 2 ;;
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

if [[ "$NUM_DISKS" == 2 && "$DISK_SIZE" == "$DISK_SIZE_2" ]]; then
  err "--disk-size e --disk2-size sono uguali (${DISK_SIZE}): la topologia dual-disk" \
      "assegna il sistema al disco più piccolo (match:{size:smallest}), dischi identici" \
      "non eserciterebbero davvero l'euristica"
fi

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
DISK_SIZES=("$DISK_SIZE" "$DISK_SIZE_2")
for ((i = 1; i <= NUM_DISKS; i++)); do
  SIZE="${DISK_SIZES[$((i - 1))]}"
  DISK="${WORK_DIR}/test-disk-${i}.qcow2"
  qemu-img create -f qcow2 "$DISK" "$SIZE" >/dev/null
  DISK_ARGS+=(-drive "file=${DISK},if=virtio,format=qcow2")
  log "Disco virtuale throwaway ${i}/${NUM_DISKS} creato: ${SIZE}"
done

KVM_ARGS=(-cpu max)
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_ARGS=(-enable-kvm -cpu host)
  log "KVM disponibile: uso accelerazione hardware."
else
  log "ATTENZIONE: /dev/kvm non disponibile, uso emulazione software (TCG, molto più lenta)."
fi

# Firmware UEFI obbligatorio (OVMF), non piu' opzionale: iso/storage-*-disk.yaml
# supporta solo UEFI dal 2026-08-19 (decisione: "grub_device: true" sia sul
# disco che sulla ESP mandava in errore l'intero autoinstall in boot BIOS
# legacy - curtin invoca grub-install su ogni device con quel flag senza
# filtrare per firmware reale - vedi logbook-fase2.md). Un test in BIOS
# legacy (default QEMU senza firmware esplicito) fallirebbe sempre con
# l'ISO attuale: niente fallback silenzioso, si richiede OVMF esplicitamente.
OVMF_CODE=""
OVMF_VARS_TEMPLATE=""
for candidate_dir in /usr/share/OVMF /usr/share/ovmf /usr/share/qemu; do
  for code_name in OVMF_CODE_4M.fd OVMF_CODE.fd OVMF.fd; do
    if [[ -f "${candidate_dir}/${code_name}" ]]; then
      OVMF_CODE="${candidate_dir}/${code_name}"
      break 2
    fi
  done
done
for candidate_dir in /usr/share/OVMF /usr/share/ovmf /usr/share/qemu; do
  for vars_name in OVMF_VARS_4M.fd OVMF_VARS.fd; do
    if [[ -f "${candidate_dir}/${vars_name}" ]]; then
      OVMF_VARS_TEMPLATE="${candidate_dir}/${vars_name}"
      break 2
    fi
  done
done
[[ -n "$OVMF_CODE" && -n "$OVMF_VARS_TEMPLATE" ]] \
  || err "firmware UEFI (OVMF) non trovato: richiesto per testare l'ISO (solo UEFI dal 2026-08-19, vedi logbook-fase2.md). Installa il pacchetto 'ovmf'."
OVMF_VARS="${WORK_DIR}/OVMF_VARS.fd"
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
UEFI_ARGS=(
  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
  -drive "if=pflash,format=raw,file=${OVMF_VARS}"
)
log "Firmware UEFI: ${OVMF_CODE}"

SERIAL_LOG="${WORK_DIR}/serial.log"
SERIAL_SOCK="${WORK_DIR}/serial.sock"
QEMU_STDERR_LOG="${WORK_DIR}/qemu-stderr.log"
: > "$SERIAL_LOG"

log "Avvio QEMU (ISO: ${ISO}, RAM: ${MEMORY_MB}MB, dischi: ${NUM_DISKS}) ..."
# La console seriale è un chardev "socket" (non "file" diretto): "logfile"
# mantiene lo stesso log testuale continuo di prima, ma il socket permette
# anche, su fallimento, di collegarsi e inviare comandi diagnostici alla
# shell di recovery di Subiquity (vedi scripts/_qemu_serial_diag.py) — la
# sola trace ad alto livello sulla console non include mai il traceback
# reale di un errore.
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  "${UEFI_ARGS[@]}" \
  -m "$MEMORY_MB" -smp 2 \
  -machine q35 \
  -display none -nographic -monitor none \
  -chardev "socket,id=serial0,path=${SERIAL_SOCK},server=on,wait=off,logfile=${SERIAL_LOG}" \
  -serial chardev:serial0 \
  -boot once=d \
  -cdrom "$ISO" \
  "${DISK_ARGS[@]}" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
  >"$QEMU_STDERR_LOG" 2>&1 &
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
    # WORK_DIR (e quindi SERIAL_LOG/QEMU_STDERR_LOG) sparisce col trap di
    # cleanup non appena lo script esce: senza questa copia, "err" qui sotto
    # avrebbe lasciato solo un percorso puntato a file già rimossi (scoperto
    # perdendo la diagnostica di un crash QEMU reale durante la Fase 3).
    cp "$SERIAL_LOG" "${ISO}.serial.log" 2>/dev/null || true
    cp "$QEMU_STDERR_LOG" "${ISO}.qemu-stderr.log" 2>/dev/null || true
    log "--- stderr di QEMU (log completo: ${ISO}.qemu-stderr.log) ---"
    tail -n 50 "$QEMU_STDERR_LOG" 2>/dev/null || true
    err "QEMU è terminato inaspettatamente prima del timeout (log seriale: ${ISO}.serial.log, stderr QEMU: ${ISO}.qemu-stderr.log)"
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
  # Subiquity caduto nella shell di recovery del live environment: la sola
  # trace ad alto livello (start/finish) sulla console non include mai il
  # traceback reale. Best-effort: collegati al socket seriale e prova a
  # leggere il crash report + la coda del log di Subiquity prima di
  # arrenderti (vedi scripts/_qemu_serial_diag.py). Se QEMU è già morto o
  # non è quello stato (es. timeout puro senza crash) semplicemente non
  # produce nulla di utile, ignorato.
  if grep -q "An error occurred. Press enter to start a shell" "$SERIAL_LOG" 2>/dev/null \
      && kill -0 "$QEMU_PID" 2>/dev/null; then
    log "Rilevata shell di recovery: provo a leggere crash report + log Subiquity ..."
    DIAG_OUT="${ISO}.crash-diag.txt"
    if python3 "${SCRIPT_DIR}/_qemu_serial_diag.py" "$SERIAL_SOCK" "$DIAG_OUT" 2>/dev/null \
        && [[ -s "$DIAG_OUT" ]]; then
      log "Diagnostica extra salvata in: ${DIAG_OUT}"
    else
      log "Diagnostica extra non disponibile (best-effort, nessun blocco)."
    fi
  fi

  # WORK_DIR (e quindi SERIAL_LOG) viene rimosso dal trap di cleanup a fine
  # script: salva il log seriale completo accanto all'ISO prima che sparisca,
  # altrimenti l'unica diagnostica disponibile sarebbe la tail qui sotto
  # (insufficiente per errori tardivi, es. nei late-commands).
  PERSISTED_LOG="${ISO}.serial.log"
  cp "$SERIAL_LOG" "$PERSISTED_LOG" 2>/dev/null || true
  cp "$QEMU_STDERR_LOG" "${ISO}.qemu-stderr.log" 2>/dev/null || true
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

log "Datastore verificato: ${DATASTORE_LINK} montato come ${DATASTORE_FILESYSTEM}."

if [[ "$NUM_DISKS" == 2 ]]; then
  ROOT_SIZE_CHECK="lsblk -bno SIZE \"\$(findmnt -no SOURCE --target /)\" | head -1"
  ROOT_SIZE_BYTES="$("${SSH_CMD[@]}" "$ROOT_SIZE_CHECK" | tr -d '\r')"
  log "Dimensione del device root riportata dalla VM: ${ROOT_SIZE_BYTES} byte" \
      "(disco system atteso: ${DISK_SIZE}, il più piccolo dei due)."
fi

log "Verifico il post-install (Fase 3, issue #3: storage Docker sul Datastore) ..."
POSTINSTALL_MARKER_ELAPSED=0
POSTINSTALL_OK=0
while (( POSTINSTALL_MARKER_ELAPSED < 120 )); do
  if "${SSH_CMD[@]}" '[ -f /opt/kickstart-berlin/.setup-complete ]' 2>/dev/null; then
    POSTINSTALL_OK=1
    break
  fi
  sleep 10
  POSTINSTALL_MARKER_ELAPSED=$(( POSTINSTALL_MARKER_ELAPSED + 10 ))
done
if [[ "$POSTINSTALL_OK" != "1" ]]; then
  "${SSH_CMD[@]}" "systemctl status kickstart-berlin-postinstall.service --no-pager 2>&1; journalctl -u kickstart-berlin-postinstall.service --no-pager 2>&1" || true
  err "kickstart-berlin-postinstall.service non ha completato entro 120s dal login SSH"
fi

DOCKER_DATA_ROOT="${DATASTORE_LINK}/docker"
POSTINSTALL_CHECK="set -e; \
[ \"\$(readlink -f /var/lib/docker)\" = \"\$(readlink -f '${DOCKER_DATA_ROOT}')\" ]; \
python3 -c \"import json; d=json.load(open('/etc/docker/daemon.json')); assert d['data-root']=='${DOCKER_DATA_ROOT}', d\""
if ! "${SSH_CMD[@]}" "$POSTINSTALL_CHECK"; then
  "${SSH_CMD[@]}" "readlink -f /var/lib/docker; echo ---; cat /etc/docker/daemon.json 2>&1" || true
  err "storage Docker non preparato correttamente: /var/lib/docker o /etc/docker/daemon.json non puntano a ${DOCKER_DATA_ROOT}"
fi

log "Post-install verificato: /var/lib/docker -> ${DOCKER_DATA_ROOT}, daemon.json coerente."

log "Test superato."
