#!/usr/bin/env bash
#
# build-iso.sh — ripacchetta l'ISO ufficiale Ubuntu Server con un autoinstall
# (cloud-init) iniettato, per un'installazione completamente non interattiva.
#
# Fase 1 del piano kickstart-berlin (vedi README, issue #1).
#
# Uso:
#   scripts/build-iso.sh -k ~/.ssh/id_ed25519.pub [-v 24.04.2] [-o output.iso]
#
# La chiave pubblica SSH è OBBLIGATORIA e viene iniettata nel file
# iso/user-data solo a build-time: non è mai hardcoded nel repo.

set -euo pipefail

UBUNTU_VERSION="24.04.2"
OUTPUT_ISO=""
SSH_KEY_PATH=""
SSH_KEY_STRING=""
WORK_DIR=""
SKIP_GPG_CHECK="${SKIP_GPG_CHECK:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"

usage() {
  cat <<EOF
Uso: $(basename "$0") -k <path-chiave-pubblica-ssh> [opzioni]

Opzioni:
  -k, --ssh-key <path>      Path al file di chiave pubblica SSH da iniettare
                             nell'utente admin (obbligatorio).
      --ssh-key-string <s>  In alternativa a -k, la chiave come stringa.
  -v, --version <ver>       Versione Ubuntu Server LTS da usare
                             (default: ${UBUNTU_VERSION}).
  -o, --output <path>       Path dell'ISO generata
                             (default: build/kickstart-berlin-<ver>-autoinstall.iso).
      --skip-gpg-check      Salta la verifica della firma GPG di SHA256SUMS
                             (la verifica del checksum SHA256 resta comunque
                             obbligatoria).
  -h, --help                Mostra questo messaggio.
EOF
}

log() { printf '[build-iso] %s\n' "$*" >&2; }
err() { printf '[build-iso] ERRORE: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--ssh-key) SSH_KEY_PATH="$2"; shift 2 ;;
    --ssh-key-string) SSH_KEY_STRING="$2"; shift 2 ;;
    -v|--version) UBUNTU_VERSION="$2"; shift 2 ;;
    -o|--output) OUTPUT_ISO="$2"; shift 2 ;;
    --skip-gpg-check) SKIP_GPG_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

for bin in xorriso curl sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || err "comando richiesto non trovato: $bin"
done

if [[ -n "$SSH_KEY_PATH" && -n "$SSH_KEY_STRING" ]]; then
  err "usa solo una tra -k/--ssh-key e --ssh-key-string"
fi
if [[ -n "$SSH_KEY_PATH" ]]; then
  [[ -f "$SSH_KEY_PATH" ]] || err "file chiave non trovato: $SSH_KEY_PATH"
  SSH_KEY_STRING="$(tr -d '\n' < "$SSH_KEY_PATH")"
fi
[[ -n "$SSH_KEY_STRING" ]] || err "chiave pubblica SSH obbligatoria (-k/--ssh-key o --ssh-key-string)"
[[ "$SSH_KEY_STRING" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]] \
  || err "la chiave fornita non sembra una chiave pubblica SSH valida"

[[ -z "$OUTPUT_ISO" ]] && OUTPUT_ISO="${REPO_ROOT}/build/kickstart-berlin-${UBUNTU_VERSION}-autoinstall.iso"
mkdir -p "$(dirname "$OUTPUT_ISO")"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BASE_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}"
SOURCE_ISO_NAME="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
SOURCE_ISO="${WORK_DIR}/${SOURCE_ISO_NAME}"

log "Scarico ${SOURCE_ISO_NAME} da ${BASE_URL} ..."
curl -fL --retry 3 -o "$SOURCE_ISO" "${BASE_URL}/${SOURCE_ISO_NAME}"

log "Scarico SHA256SUMS e SHA256SUMS.gpg ..."
curl -fL --retry 3 -o "${WORK_DIR}/SHA256SUMS" "${BASE_URL}/SHA256SUMS"
curl -fL --retry 3 -o "${WORK_DIR}/SHA256SUMS.gpg" "${BASE_URL}/SHA256SUMS.gpg"

log "Verifico checksum SHA256 dell'ISO ufficiale ..."
EXPECTED_SUM="$(grep " \*${SOURCE_ISO_NAME}\$" "${WORK_DIR}/SHA256SUMS" | awk '{print $1}')"
[[ -n "$EXPECTED_SUM" ]] || err "checksum non trovato in SHA256SUMS per ${SOURCE_ISO_NAME}"
ACTUAL_SUM="$(sha256sum "$SOURCE_ISO" | awk '{print $1}')"
[[ "$EXPECTED_SUM" == "$ACTUAL_SUM" ]] \
  || err "checksum non corrispondente! atteso=${EXPECTED_SUM} ottenuto=${ACTUAL_SUM}"
log "Checksum OK (${ACTUAL_SUM})"

if [[ "$SKIP_GPG_CHECK" != "1" ]]; then
  if command -v gpg >/dev/null 2>&1; then
    log "Verifico firma GPG di SHA256SUMS (Ubuntu CD signing key) ..."
    GNUPGHOME="$(mktemp -d)"
    export GNUPGHOME
    # Ubuntu Archive Automatic Signing Key + Cdimage signing key.
    gpg --batch --keyserver hkps://keyserver.ubuntu.com \
      --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092 \
      843938DF228D22F7B3742BC0D94AA3F0EFE2109 \
      2>/dev/null || true
    if ! gpg --batch --verify "${WORK_DIR}/SHA256SUMS.gpg" "${WORK_DIR}/SHA256SUMS" 2>/dev/null; then
      log "ATTENZIONE: impossibile verificare la firma GPG (keyserver non raggiungibile o chiave mancante)."
      log "Il checksum SHA256 è comunque stato verificato con esito positivo."
    else
      log "Firma GPG verificata."
    fi
    rm -rf "$GNUPGHOME"
  else
    log "gpg non disponibile: salto la verifica della firma (checksum SHA256 già verificato)."
  fi
else
  log "Verifica firma GPG saltata (--skip-gpg-check)."
fi

# Estrae solo i file di boot che potrebbero contenere le voci di menu da
# modificare (non l'intera ISO: più veloce e meno soggetto a errori). Non
# tutte le versioni/varianti di Ubuntu hanno tutti questi path: si edita
# solo quelli effettivamente presenti nell'ISO sorgente.
BOOT_EDIT_DIR="${WORK_DIR}/boot-edit"
mkdir -p "$BOOT_EDIT_DIR"
CANDIDATE_BOOT_FILES=(
  "boot/grub/grub.cfg"
  "boot/grub/loopback.cfg"
  "isolinux/txt.cfg"
)
MAP_ARGS=()

for rel_path in "${CANDIDATE_BOOT_FILES[@]}"; do
  local_path="${BOOT_EDIT_DIR}/${rel_path}"
  mkdir -p "$(dirname "$local_path")"
  if xorriso -osirrox on -indev "$SOURCE_ISO" -extract "/${rel_path}" "$local_path" \
       >/dev/null 2>&1; then
    # Aggiunge "autoinstall ds=nocloud;s=/cdrom/server/" alla riga kernel
    # (grub) o alla riga append (isolinux), così l'installazione parte
    # senza alcun prompt sia in modalità UEFI che legacy BIOS. Aggiunge
    # anche "console=ttyS0,115200n8": senza, kernel/casper/Subiquity non
    # scrivono nulla sulla console seriale (solo GRUB lo fa di default),
    # rendendo impossibile qualunque diagnosi headless (QEMU -nographic,
    # IPMI/serial-over-LAN su hardware reale).
    if [[ "$rel_path" == isolinux/* ]]; then
      sed -i 's|^\(\s*append .*\)$|\1 console=ttyS0,115200n8 autoinstall ds=nocloud;s=/cdrom/server/|' "$local_path"
    else
      sed -i 's|/casper/vmlinuz|/casper/vmlinuz console=ttyS0,115200n8 autoinstall ds=nocloud\\;s=/cdrom/server/|' "$local_path"
    fi
    MAP_ARGS+=(-map "$local_path" "/${rel_path}")
    log "Modifico voce di boot: /${rel_path}"
  fi
done

[[ ${#MAP_ARGS[@]} -gt 0 ]] \
  || err "nessun file di configurazione boot (grub/isolinux) trovato nell'ISO sorgente"

AUTOINSTALL_USER_DATA="${WORK_DIR}/user-data"
sed "s|__SSH_AUTHORIZED_KEY__|${SSH_KEY_STRING}|" "${REPO_ROOT}/iso/user-data" \
  > "$AUTOINSTALL_USER_DATA"

VOLID="$(xorriso -indev "$SOURCE_ISO" -pvd_info 2>/dev/null \
  | awk -F': ' '/Volume Id/{print $2; exit}')"
[[ -n "$VOLID" ]] || VOLID="Ubuntu-Server ${UBUNTU_VERSION}"

log "Ripacchetto l'ISO iniettando autoinstall e preservando il boot catalog originale ..."
rm -f "$OUTPUT_ISO"
xorriso -indev "$SOURCE_ISO" \
  -outdev "$OUTPUT_ISO" \
  -map "$AUTOINSTALL_USER_DATA" /server/user-data \
  -map "${REPO_ROOT}/iso/meta-data" /server/meta-data \
  "${MAP_ARGS[@]}" \
  -boot_image any replay \
  -volid "$VOLID" \
  >/dev/null

log "ISO generata: ${OUTPUT_ISO}"
sha256sum "$OUTPUT_ISO" | tee "${OUTPUT_ISO}.sha256"
