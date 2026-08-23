#!/usr/bin/env bash
#
# build-iso.sh — ripacchetta l'ISO ufficiale Ubuntu Server con un autoinstall
# (cloud-init) iniettato, per un'installazione completamente non interattiva.
#
# Fasi 1-2 del piano kickstart-berlin (vedi README, issue #1, #2).
#
# Uso:
#   scripts/build-iso.sh -k ~/.ssh/id_ed25519.pub [-v 24.04.2] [-o output.iso]
#
# La chiave pubblica SSH è OBBLIGATORIA e viene iniettata nel file
# iso/user-data solo a build-time: non è mai hardcoded nel repo.
#
# Tutti gli altri default (versione Ubuntu, size partizione sistema,
# topologia dischi, parametri Datastore) vivono in
# config/autoinstall-defaults.json — i flag CLI qui sotto, quando passati,
# hanno sempre precedenza su quel file.

set -euo pipefail

OUTPUT_ISO=""
SSH_KEY_PATH=""
SSH_KEY_STRING=""
WORK_DIR=""
CACHE_DIR=""
SKIP_GPG_CHECK="${SKIP_GPG_CHECK:-0}"
UBUNTU_VERSION=""
SYSTEM_PARTITION_SIZE=""
DISK_TOPOLOGY=""
HOSTNAME_PREFIX=""
PORT_RANGE_START=""
PORT_RANGE_END=""
DEV_SKIP_SECURITY_UPDATES=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"

log() { printf '[build-iso] %s\n' "$*" >&2; }
err() { printf '[build-iso] ERRORE: %s\n' "$*" >&2; exit 1; }

DEFAULTS_JSON="${REPO_ROOT}/config/autoinstall-defaults.json"
[[ -f "$DEFAULTS_JSON" ]] || err "file di default non trovato: $DEFAULTS_JSON"
command -v python3 >/dev/null 2>&1 || err "python3 richiesto per leggere ${DEFAULTS_JSON}"

# shellcheck disable=SC1090
source <(python3 - "$DEFAULTS_JSON" <<'PYEOF'
import json, shlex, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
def emit(var, value):
    print(f"{var}={shlex.quote(str(value))}")
emit("DEFAULT_UBUNTU_VERSION", d["ubuntu_version"])
s = d["storage"]
emit("DEFAULT_SYSTEM_PARTITION_SIZE", s["system_partition_size"])
emit("DEFAULT_DISK_TOPOLOGY", s["disk_topology"])
ds = s["datastore"]
emit("DEFAULT_DATASTORE_FILESYSTEM", ds["filesystem"])
emit("DEFAULT_DATASTORE_LABEL", ds["label"])
emit("DEFAULT_DATASTORE_MOUNT_ROOT", ds["mount_root"])
emit("DEFAULT_DATASTORE_SYMLINK_NAME", ds["symlink_name"])
emit("DEFAULT_HOSTNAME_PREFIX", d["identity"]["hostname_prefix"])
net = d["network"]
emit("DEFAULT_PORT_RANGE_START", net["port_range_start"])
emit("DEFAULT_PORT_RANGE_END", net["port_range_end"])
PYEOF
)

UBUNTU_VERSION="$DEFAULT_UBUNTU_VERSION"
SYSTEM_PARTITION_SIZE="$DEFAULT_SYSTEM_PARTITION_SIZE"
DISK_TOPOLOGY="$DEFAULT_DISK_TOPOLOGY"
HOSTNAME_PREFIX="$DEFAULT_HOSTNAME_PREFIX"
PORT_RANGE_START="$DEFAULT_PORT_RANGE_START"
PORT_RANGE_END="$DEFAULT_PORT_RANGE_END"

usage() {
  cat <<EOF
Uso: $(basename "$0") -k <path-chiave-pubblica-ssh> [opzioni]

Opzioni:
  -k, --ssh-key <path>      Path al file di chiave pubblica SSH da iniettare
                             nell'utente admin (obbligatorio).
      --ssh-key-string <s>  In alternativa a -k, la chiave come stringa.
  -v, --version <ver>       Versione Ubuntu Server LTS da usare
                             (default da config/autoinstall-defaults.json:
                             ${UBUNTU_VERSION}).
  -o, --output <path>       Path dell'ISO generata
                             (default: build/kickstart-berlin-<ver>-autoinstall.iso).
      --skip-gpg-check      Salta la verifica della firma GPG di SHA256SUMS
                             (la verifica del checksum SHA256 resta comunque
                             obbligatoria).
      --cache-dir <path>    Directory di cache per l'ISO ufficiale scaricata
                             (opzionale, pensata per iterazioni locali
                             ripetute, es. su un volume Docker persistente).
                             Il checksum SHA256 viene comunque riverificato
                             ad ogni build contro SHA256SUMS scaricato al
                             momento: se non corrisponde (nuova versione,
                             cache corrotta) si ri-scarica automaticamente.
                             Se omesso (default, usato in CI/produzione),
                             l'ISO viene sempre scaricata da zero.
      --system-size <size>  Size della partizione di sistema (root ext4),
                             sintassi curtin (es. 100G). Rilevante solo con
                             topologia "single" (--disks 1): con "dual" il
                             disco di sistema è dedicato e viene usato per
                             intero. Default da
                             config/autoinstall-defaults.json: ${SYSTEM_PARTITION_SIZE}.
      --disks <1|2>          Topologia dischi target (Fase 2, issue #2):
                             1 = un solo disco fisico (sistema+datastore
                             condiviso), 2 = due dischi fisici (sistema sul
                             più piccolo, datastore sull'altro per intero).
                             Default da config/autoinstall-defaults.json:
                             $([[ "$DISK_TOPOLOGY" == dual ]] && echo 2 || echo 1).
      --hostname-prefix <p>  Prefisso per l'hostname (minuscolo, cifre e
                             trattini, deve iniziare con una lettera).
                             L'hostname finale <prefix>-XXXX (XXXX: fino a
                             4 caratteri alfanumerici casuali) viene
                             generato a install-time su ogni nodo, non qui
                             (vedi iso/user-data late-commands): la stessa
                             ISO puo' installare piu' nodi fisici diversi.
                             Default da config/autoinstall-defaults.json:
                             ${HOSTNAME_PREFIX}.
      --port-range <S-E>     Range di porte TCP+UDP continuo da aprire su
                             ufw (se attivo) per il traffico container
                             (Fase 6, issue #6 — guida ufficiale Vast.ai,
                             sezione "Port Requirements": almeno 3 porte
                             per GPU, 100 per GPU come ideale). Formato
                             "START-END", es. 16384-32768. Default da
                             config/autoinstall-defaults.json:
                             ${PORT_RANGE_START}-${PORT_RANGE_END}.
      --dev-skip-security-updates
                             SOLO sviluppo/test, MAI produzione: blocca
                             security.ubuntu.com nell'ambiente live (via
                             /etc/hosts, early-commands) cosi' lo step
                             "updates: security" fallisce subito invece
                             di impiegare decine di minuti in rete ad
                             ogni ciclo di test/CI. L'immagine risultante
                             NON ha gli update di sicurezza installati:
                             non usare questo flag per ISO destinate a
                             nodi reali. Default: disattivato (comporta-
                             mento nativo Subiquity, update reali).
  -h, --help                Mostra questo messaggio.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--ssh-key) SSH_KEY_PATH="$2"; shift 2 ;;
    --ssh-key-string) SSH_KEY_STRING="$2"; shift 2 ;;
    -v|--version) UBUNTU_VERSION="$2"; shift 2 ;;
    -o|--output) OUTPUT_ISO="$2"; shift 2 ;;
    --skip-gpg-check) SKIP_GPG_CHECK=1; shift ;;
    --cache-dir) CACHE_DIR="$2"; shift 2 ;;
    --system-size) SYSTEM_PARTITION_SIZE="$2"; shift 2 ;;
    --disks)
      case "$2" in
        1) DISK_TOPOLOGY="single" ;;
        2) DISK_TOPOLOGY="dual" ;;
        *) err "--disks accetta solo 1 o 2, ricevuto: $2" ;;
      esac
      shift 2 ;;
    --hostname-prefix) HOSTNAME_PREFIX="$2"; shift 2 ;;
    --port-range)
      [[ "$2" =~ ^([0-9]+)-([0-9]+)$ ]] || err "--port-range formato non valido: $2 (atteso START-END, es. 16384-32768)"
      PORT_RANGE_START="${BASH_REMATCH[1]}"
      PORT_RANGE_END="${BASH_REMATCH[2]}"
      shift 2 ;;
    --dev-skip-security-updates) DEV_SKIP_SECURITY_UPDATES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

STORAGE_FRAGMENT="${REPO_ROOT}/iso/storage-${DISK_TOPOLOGY}-disk.yaml"
[[ -f "$STORAGE_FRAGMENT" ]] \
  || err "frammento storage non trovato per topologia '${DISK_TOPOLOGY}': ${STORAGE_FRAGMENT}"

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

[[ "$HOSTNAME_PREFIX" =~ ^[a-z][a-z0-9-]*$ ]] \
  || err "--hostname-prefix non valido: ${HOSTNAME_PREFIX} (deve iniziare con una lettera minuscola, poi solo minuscole/cifre/trattini)"

for p in "$PORT_RANGE_START" "$PORT_RANGE_END"; do
  (( p >= 1 && p <= 65535 )) || err "--port-range: ${p} fuori dal range di porte valido (1-65535)"
done
(( PORT_RANGE_START < PORT_RANGE_END )) \
  || err "--port-range: l'inizio (${PORT_RANGE_START}) deve essere minore della fine (${PORT_RANGE_END})"
(( PORT_RANGE_END - PORT_RANGE_START >= 2 )) \
  || err "--port-range: range troppo stretto (${PORT_RANGE_START}-${PORT_RANGE_END}), la guida ufficiale Vast.ai richiede almeno 3 porte per GPU"

[[ -z "$OUTPUT_ISO" ]] && OUTPUT_ISO="${REPO_ROOT}/build/kickstart-berlin-${UBUNTU_VERSION}-autoinstall.iso"
mkdir -p "$(dirname "$OUTPUT_ISO")"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BASE_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}"
SOURCE_ISO_NAME="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

log "Scarico SHA256SUMS e SHA256SUMS.gpg ..."
curl -fL --retry 3 -o "${WORK_DIR}/SHA256SUMS" "${BASE_URL}/SHA256SUMS"
curl -fL --retry 3 -o "${WORK_DIR}/SHA256SUMS.gpg" "${BASE_URL}/SHA256SUMS.gpg"

EXPECTED_SUM="$(grep " \*${SOURCE_ISO_NAME}\$" "${WORK_DIR}/SHA256SUMS" | awk '{print $1}')"
[[ -n "$EXPECTED_SUM" ]] || err "checksum non trovato in SHA256SUMS per ${SOURCE_ISO_NAME}"

if [[ -n "$CACHE_DIR" ]]; then
  mkdir -p "$CACHE_DIR"
  SOURCE_ISO="${CACHE_DIR}/${SOURCE_ISO_NAME}"
else
  SOURCE_ISO="${WORK_DIR}/${SOURCE_ISO_NAME}"
fi

if [[ -n "$CACHE_DIR" && -f "$SOURCE_ISO" ]] \
    && [[ "$(sha256sum "$SOURCE_ISO" | awk '{print $1}')" == "$EXPECTED_SUM" ]]; then
  log "Trovata ${SOURCE_ISO_NAME} in cache (${CACHE_DIR}), checksum verificato: riuso senza riscaricare."
else
  log "Scarico ${SOURCE_ISO_NAME} da ${BASE_URL} ..."
  curl -fL --retry 3 -o "$SOURCE_ISO" "${BASE_URL}/${SOURCE_ISO_NAME}"
  ACTUAL_SUM="$(sha256sum "$SOURCE_ISO" | awk '{print $1}')"
  [[ "$EXPECTED_SUM" == "$ACTUAL_SUM" ]] \
    || err "checksum non corrispondente! atteso=${EXPECTED_SUM} ottenuto=${ACTUAL_SUM}"
  log "Checksum OK (${ACTUAL_SUM})"
fi

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

log "Topologia dischi: ${DISK_TOPOLOGY} (${STORAGE_FRAGMENT})"

if [[ "$DEV_SKIP_SECURITY_UPDATES" == "1" ]]; then
  log "ATTENZIONE: --dev-skip-security-updates attivo — gli update di sicurezza NON verranno installati in questa ISO (solo sviluppo/test)."
  DEV_SKIP_SECURITY_UPDATES_HOOK='echo "127.0.0.1 security.ubuntu.com" >> /etc/hosts'
else
  DEV_SKIP_SECURITY_UPDATES_HOOK="true"
fi

# Inserisce il frammento storage al posto del placeholder __STORAGE_CONFIG__
# (idioma sed "r file" + "d": accoda il contenuto del frammento dopo la riga
# placeholder, poi elimina la riga placeholder stessa), quindi sostituisce
# in un solo passaggio finale tutti i placeholder rimasti (chiave SSH, size
# partizione sistema, parametri Datastore) sul risultato unito.
# La riga placeholder "  storage: __STORAGE_CONFIG__" diventa "  storage:"
# (rimuovendo solo il valore placeholder, non l'intera riga/chiave) e subito
# dopo, nello stesso passaggio sed, viene accodato il contenuto del
# frammento scelto (già indentato correttamente come figlio di "storage:").
AUTOINSTALL_USER_DATA="${WORK_DIR}/user-data"
sed -e "s| __STORAGE_CONFIG__\$||" \
    -e "/^  storage:\$/r ${STORAGE_FRAGMENT}" \
    "${REPO_ROOT}/iso/user-data" \
  | sed \
      -e "s|__SSH_AUTHORIZED_KEY__|${SSH_KEY_STRING}|" \
      -e "s|__SYSTEM_PARTITION_SIZE__|${SYSTEM_PARTITION_SIZE}|g" \
      -e "s|__DATASTORE_FILESYSTEM__|${DEFAULT_DATASTORE_FILESYSTEM}|g" \
      -e "s|__DATASTORE_LABEL__|${DEFAULT_DATASTORE_LABEL}|g" \
      -e "s|__DATASTORE_MOUNT_ROOT__|${DEFAULT_DATASTORE_MOUNT_ROOT}|g" \
      -e "s|__DATASTORE_SYMLINK_NAME__|${DEFAULT_DATASTORE_SYMLINK_NAME}|g" \
      -e "s|__DEV_SKIP_SECURITY_UPDATES_HOOK__|${DEV_SKIP_SECURITY_UPDATES_HOOK}|" \
      -e "s|__HOSTNAME_PREFIX__|${HOSTNAME_PREFIX}|g" \
  > "$AUTOINSTALL_USER_DATA"

# Script post-install (Fase 3+, issue #3): stesso trattamento di
# iso/user-data, i placeholder Datastore vengono sostituiti a build-time
# dalla stessa fonte (config/autoinstall-defaults.json). Il file .service
# non ha placeholder, viene copiato così com'è.
POSTINSTALL_STAGE="${WORK_DIR}/postinstall"
mkdir -p "$POSTINSTALL_STAGE"
sed \
    -e "s|__DATASTORE_MOUNT_ROOT__|${DEFAULT_DATASTORE_MOUNT_ROOT}|g" \
    -e "s|__DATASTORE_SYMLINK_NAME__|${DEFAULT_DATASTORE_SYMLINK_NAME}|g" \
    -e "s|__PORT_RANGE_START__|${PORT_RANGE_START}|g" \
    -e "s|__PORT_RANGE_END__|${PORT_RANGE_END}|g" \
    "${REPO_ROOT}/postinstall/setup.sh" \
  > "${POSTINSTALL_STAGE}/setup.sh"
cp "${REPO_ROOT}/postinstall/kickstart-berlin-postinstall.service" "${POSTINSTALL_STAGE}/"
# install-vastai-host.sh (Fase 7, issue #7) e vastai-self-test.sh
# (Fase 11, issue #11): nessun placeholder, copiati così come sono -
# entrambi vanno invocati a mano dall'operatore, mai dalla sequenza
# automatica di setup.sh (vedi commenti in ciascun file).
cp "${REPO_ROOT}/postinstall/install-vastai-host.sh" "${POSTINSTALL_STAGE}/"
cp "${REPO_ROOT}/postinstall/vastai-self-test.sh" "${POSTINSTALL_STAGE}/"

VOLID="$(xorriso -indev "$SOURCE_ISO" -pvd_info 2>/dev/null \
  | awk -F': ' '/Volume Id/{print $2; exit}')"
[[ -n "$VOLID" ]] || VOLID="Ubuntu-Server ${UBUNTU_VERSION}"

log "Ripacchetto l'ISO iniettando autoinstall e preservando il boot catalog originale ..."
rm -f "$OUTPUT_ISO"
# "-abort_on FAILURE": senza, xorriso non restituisce un exit code diverso
# da zero per problemi di severità FAILURE (es. spazio insufficiente sulla
# destinazione) - lo script proseguirebbe come se l'ISO fosse stata scritta
# correttamente nonostante xorriso l'abbia esplicitamente annullata
# ("Image write cancelled"). Scoperto con un'ISO di build "riuscita" ma in
# realtà mai scritta su disco.
xorriso -abort_on FAILURE \
  -indev "$SOURCE_ISO" \
  -outdev "$OUTPUT_ISO" \
  -map "$AUTOINSTALL_USER_DATA" /server/user-data \
  -map "${REPO_ROOT}/iso/meta-data" /server/meta-data \
  -map "$POSTINSTALL_STAGE" /postinstall \
  "${MAP_ARGS[@]}" \
  -boot_image any replay \
  -volid "$VOLID" \
  >/dev/null

# Controllo difensivo aggiuntivo, indipendente dall'exit code del comando
# xorriso sopra: verifica che l'ISO risultante esista e contenga
# effettivamente i file appena iniettati. Una prima versione di questo
# controllo confrontava la dimensione totale con l'ISO sorgente
# (mai più piccola, dato che si aggiungono solo file) - si è rivelato un
# falso positivo: il meccanismo di "replay" del boot catalog di xorriso
# può produrre un output di qualche centinaio di KB più piccolo per
# differenze di allineamento/padding, pur essendo perfettamente valido
# (confermato con boot test reali riusciti). Verificare la presenza
# effettiva dei file iniettati è il controllo corretto, non la dimensione
# totale.
[[ -s "$OUTPUT_ISO" ]] || err "ISO non generata: ${OUTPUT_ISO} mancante o vuota dopo xorriso"
for injected_path in /server/user-data /server/meta-data; do
  xorriso -abort_on FAILURE -indev "$OUTPUT_ISO" -find "$injected_path" >/dev/null 2>&1 \
    || err "ISO generata ma ${injected_path} non trovato al suo interno: probabile scrittura incompleta"
done

log "ISO generata: ${OUTPUT_ISO}"
sha256sum "$OUTPUT_ISO" | tee "${OUTPUT_ISO}.sha256"
