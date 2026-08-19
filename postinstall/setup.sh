#!/usr/bin/env bash
#
# setup.sh — script post-install idempotente di kickstart-berlin.
#
# Eseguito una tantum al primo boot da kickstart-berlin-postinstall.service
# (systemd oneshot). Ogni fase del piano (README, issue #15) diventa una
# funzione qui dentro: questo file cresce con le fasi successive (4-9,
# 12-14), non va duplicato per fase.
#
# Questo file è un template: i placeholder __DATASTORE_MOUNT_ROOT__ e
# __DATASTORE_SYMLINK_NAME__ vengono sostituiti da scripts/build-iso.sh
# con i valori di config/autoinstall-defaults.json (stessa fonte usata
# per iso/user-data e i frammenti storage-*-disk.yaml).

set -euo pipefail

DATASTORE_LINK="__DATASTORE_MOUNT_ROOT__/__DATASTORE_SYMLINK_NAME__"
DOCKER_DATA_ROOT="${DATASTORE_LINK}/docker"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
VAR_LIB_DOCKER="/var/lib/docker"

log() { printf '[kickstart-berlin] %s\n' "$*" >&2; }
err() { printf '[kickstart-berlin] ERRORE: %s\n' "$*" >&2; exit 1; }

# Fase 3 (issue #3) — Preparazione storage: Docker sul Datastore, non su
# loopback. Segue l'Opzione 1 della guida host-setup ufficiale di Vast.ai
# (mkfs -> blkid -> mountpoint -> fstab -> mount, già fatto in Fase 2 per
# il Datastore) adattata alla convenzione ESX-style del Datastore stesso
# (Fase 2, issue #2) invece del path fisso /var/lib/docker di Vast.ai.
# Nessuna estensione LVM: la guida ufficiale Vast.ai non la prevede (usa
# partizioni dirette, come il nostro storage.config di Fase 2) — vedi
# logbook-fase3.md per il dettaglio della decisione.
phase3_docker_storage() {
  log "Fase 3: preparazione storage Docker su Datastore (${DOCKER_DATA_ROOT}) ..."

  if [[ ! -L "$DATASTORE_LINK" || ! -d "$DATASTORE_LINK" ]]; then
    err "Datastore non trovato/montato su ${DATASTORE_LINK} (Fase 2 non completata?)"
  fi

  mkdir -p "$DOCKER_DATA_ROOT"
  chown root:root "$DOCKER_DATA_ROOT"
  chmod 0710 "$DOCKER_DATA_ROOT"

  # daemon.json: merge con eventuali chiavi già presenti, non sovrascrive
  # l'intero file. Idempotente: se data-root è già corretto, non-op.
  mkdir -p "$(dirname "$DOCKER_DAEMON_JSON")"
  python3 - "$DOCKER_DAEMON_JSON" "$DOCKER_DATA_ROOT" <<'PYEOF'
import json
import os
import sys

path, data_root = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        content = f.read().strip()
        if content:
            cfg = json.loads(content)
if cfg.get("data-root") == data_root:
    sys.exit(0)
cfg["data-root"] = data_root
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF

  # /var/lib/docker -> symlink verso il Datastore. Compatibilità: Vast.ai
  # monta la propria partizione dati XFS direttamente su questo path;
  # qui il dato reale vive nel Datastore ESX-style altrove, quindi un
  # symlink mantiene funzionante qualunque tooling/documentazione che si
  # aspetti il path Docker/Vast.ai standard.
  if [[ -L "$VAR_LIB_DOCKER" ]]; then
    if [[ "$(readlink -f "$VAR_LIB_DOCKER")" == "$(readlink -f "$DOCKER_DATA_ROOT")" ]]; then
      log "${VAR_LIB_DOCKER} già symlink corretto verso il Datastore."
    else
      log "${VAR_LIB_DOCKER} è un symlink verso un target inatteso: lo correggo."
      rm -f "$VAR_LIB_DOCKER"
      ln -s "$DOCKER_DATA_ROOT" "$VAR_LIB_DOCKER"
    fi
  elif [[ -d "$VAR_LIB_DOCKER" ]]; then
    if [[ -z "$(ls -A "$VAR_LIB_DOCKER" 2>/dev/null)" ]]; then
      log "${VAR_LIB_DOCKER} esiste vuota: la sostituisco con un symlink."
      rmdir "$VAR_LIB_DOCKER"
      ln -s "$DOCKER_DATA_ROOT" "$VAR_LIB_DOCKER"
    else
      log "${VAR_LIB_DOCKER} contiene dati Docker esistenti: migrazione verso il Datastore ..."
      docker_was_active=0
      if systemctl is-active --quiet docker 2>/dev/null; then
        docker_was_active=1
        systemctl stop docker
      fi
      cp -a "${VAR_LIB_DOCKER}/." "${DOCKER_DATA_ROOT}/"
      rm -rf "$VAR_LIB_DOCKER"
      ln -s "$DOCKER_DATA_ROOT" "$VAR_LIB_DOCKER"
      if [[ "$docker_was_active" == "1" ]]; then
        systemctl start docker
      fi
      log "Migrazione completata."
    fi
  else
    ln -s "$DOCKER_DATA_ROOT" "$VAR_LIB_DOCKER"
    log "${VAR_LIB_DOCKER} creato come symlink verso il Datastore."
  fi

  log "Fase 3 completata."
}

NVIDIA_REBOOT_MARKER="/opt/kickstart-berlin/.phase4-nvidia-reboot-attempted"

# Vero solo se e' presente almeno un device PCI NVIDIA (vendor id 0x10de,
# lettura diretta da sysfs invece di dipendere da pciutils/lspci, non
# garantito installato su un Ubuntu Server minimale).
_phase4_gpu_present() {
  local vendor_file
  for vendor_file in /sys/bus/pci/devices/*/vendor; do
    [[ -r "$vendor_file" ]] || continue
    [[ "$(cat "$vendor_file")" == "0x10de" ]] && return 0
  done
  return 1
}

# Fase 4 (issue #4) — Driver NVIDIA + NVIDIA Container Toolkit. Segue la
# guida host-setup ufficiale di Vast.ai ("Install NVIDIA GPU Driver &
# CUDA"): nessuna versione di driver è imposta ("we don't require a
# specific version... using the latest CUDA-supported driver is
# recommended") — a differenza del testo originale dell'issue #4/README
# ("driver pinnato, es. 535", ereditato dallo script community come già
# successo per l'LVM di Fase 3, non dalla guida ufficiale). Qui si usa
# `ubuntu-drivers autoinstall`: rileva la GPU installata e sceglie il
# driver raccomandato da Ubuntu, senza versione hardcoded — decisione
# presa con l'utente, vedi logbook-fase4.md.
#
# Il "runtime configure --runtime=docker" del NVIDIA Container Toolkit
# NON viene fatto qui: Docker non è ancora installato a questo punto
# della sequenza (Fase 5, non Fase 4 — vedi README, dove "config con
# runtime NVIDIA" è esplicitamente descritto sotto Fase 5). Qui si
# installa solo il pacchetto nvidia-container-toolkit; la configurazione
# del runtime Docker va nella futura phase5_docker().
phase4_nvidia_driver() {
  log "Fase 4: driver NVIDIA + NVIDIA Container Toolkit ..."

  if ! _phase4_gpu_present; then
    log "Nessuna GPU NVIDIA rilevata (PCI vendor 0x10de): host non-GPU, fase 4 saltata."
    return 0
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -q >/dev/null 2>&1; then
    if [[ -f "$NVIDIA_REBOOT_MARKER" ]]; then
      err "Driver NVIDIA installato ma nvidia-smi non funziona dopo un riavvio: intervento manuale necessario (vedi ${NVIDIA_REBOOT_MARKER})."
    fi

    log "Driver NVIDIA non ancora funzionante: installo (ubuntu-drivers autoinstall) ..."
    apt-get update -qq
    apt-get install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall

    # Guida ufficiale Vast.ai, sezione "Disable Auto Updates": un upgrade
    # automatico del driver puo' disallineare il modulo kernel caricato
    # dalla libreria NVML usata da nvidia-smi/nvidia-docker (mismatch
    # NVML), causando deverifica automatica della macchina. "hold" su
    # tutti i pacchetti nvidia-* installati, non solo il driver
    # principale: un upgrade parziale di un pacchetto correlato
    # (nvidia-dkms-*, libnvidia-*, ...) puo' causare lo stesso mismatch.
    mapfile -t nvidia_pkgs < <(dpkg-query -W -f='${Package}\n' 'nvidia-*' 2>/dev/null)
    if [[ ${#nvidia_pkgs[@]} -gt 0 ]]; then
      apt-mark hold "${nvidia_pkgs[@]}"
    fi

    # Il modulo kernel del driver appena installato (DKMS) non e' ancora
    # caricato nel kernel in esecuzione: serve un riavvio prima che
    # nvidia-smi funzioni. Il marker precede il riavvio cosi' che, se lo
    # unit systemd non arriva a scrivere /opt/kickstart-berlin/
    # .setup-complete (il riavvio interrompe lo script prima del suo
    # normale exit, vedi kickstart-berlin-postinstall.service), il
    # prossimo boot riesegue lo script da capo (idempotente: fase 3 e
    # l'installazione driver sono no-op) e a quel punto verifica
    # nvidia-smi invece di reinstallare — un solo riavvio automatico,
    # mai un loop: il marker sopra impedisce un secondo tentativo.
    touch "$NVIDIA_REBOOT_MARKER"
    log "Driver installato: riavvio necessario per caricare il modulo kernel ..."
    reboot
    exit 0
  fi

  log "Driver NVIDIA attivo: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n1)"

  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    log "Installo NVIDIA Container Toolkit ..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
  else
    log "NVIDIA Container Toolkit già installato."
  fi

  log "Fase 4 completata."
}

# Fase 5 (issue #5) — Docker + config runtime NVIDIA. La guida ufficiale
# Vast.ai non descrive comandi espliciti per questo passaggio (nascosto
# nel proprio installer proprietario, come già notato per il Container
# Toolkit in Fase 4): si segue quindi la pratica standard Docker
# (script di convenienza get.docker.com, come da README) invece di una
# fonte vast.ai-specific da cui questo passaggio non è ricavabile.
#
# "nvidia-ctk runtime configure" (rimandato da phase4_nvidia_driver: lì
# Docker non esiste ancora) fa un merge nel daemon.json esistente, non lo
# sovrascrive - dovrebbe convivere con la chiave "data-root" scritta da
# phase3_docker_storage, ma il merge esatto non è verificabile qui
# (nvidia-ctk non installabile in questo sandbox, vedi phase4_nvidia_driver
# e logbook-fase4.md) - da confermare appena disponibile un host dove il
# Container Toolkit installa davvero.
phase5_docker() {
  log "Fase 5: installazione Docker ..."

  if command -v docker >/dev/null 2>&1; then
    log "Docker già installato."
  else
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker
  fi

  if command -v nvidia-ctk >/dev/null 2>&1; then
    log "Configuro il runtime NVIDIA per Docker ..."
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
  else
    log "NVIDIA Container Toolkit non presente (host non-GPU o Fase 4 non eseguita): salto la config del runtime."
  fi

  log "Fase 5 completata."
}

PORT_RANGE_START="__PORT_RANGE_START__"
PORT_RANGE_END="__PORT_RANGE_END__"

# Fase 6 (issue #6) — Rete: apertura del range di porte richiesto dalla
# guida ufficiale Vast.ai (sezione "Network Setup"/"Port Requirements":
# range continuo TCP+UDP, almeno 3 porte per GPU). Qui si copre solo la
# parte che ha senso a livello di HOST, indipendente da quale agente la
# userà: DHCP è già il default Ubuntu Server (nulla da fare), l'hostname
# univoco è già gestito a install-time (vedi iso/user-data late-commands).
#
# Cosa NON è qui, deliberatamente:
# - Il file di config vast.ai-specifico (/var/lib/vastai_kaalia/
#   host_port_range) non ha un equivalente: quel path appartiene al loro
#   daemon, che qui non installiamo (Fase 7 è sostituita dal backend/agent
#   Grastorp, non ancora implementato) - quando esiste, sarà lui a leggere
#   questo stesso range da config/autoinstall-defaults.json.
# - L'override IP (host_ipaddr nella guida) non ha un caso d'uso Grastorp
#   noto ad oggi - la guida stessa lo descrive come eccezione rara (NAT
#   asimmetrici) - non implementato senza un requisito concreto.
# - Il test di velocità di rete appartiene a Fase 11 (assessment one-shot,
#   vedi README), non qui.
phase6_network() {
  log "Fase 6: apertura porte ${PORT_RANGE_START}-${PORT_RANGE_END} (TCP+UDP) ..."

  if ! command -v ufw >/dev/null 2>&1; then
    log "ufw non installato: nessun firewall da configurare, nulla da fare."
    return 0
  fi

  if ! ufw status | grep -q "^Status: active"; then
    log "ufw installato ma non attivo: non lo abilito (non tocco la postura" \
      "firewall esistente dell'host) - range ${PORT_RANGE_START}-${PORT_RANGE_END}" \
      "da aprire manualmente se/quando ufw verrà attivato."
    return 0
  fi

  # Idempotente: ufw stesso non duplica una regola già presente, ma il
  # controllo esplicito evita comunque rumore nei log ad ogni riavvio del
  # servizio (la condition systemd previene la riesecuzione, ma lo script
  # resta invocabile a mano per la DoD di idempotenza).
  if ufw status | grep -q "${PORT_RANGE_START}:${PORT_RANGE_END}/tcp"; then
    log "Regole ufw per ${PORT_RANGE_START}-${PORT_RANGE_END} già presenti."
  else
    ufw allow "${PORT_RANGE_START}:${PORT_RANGE_END}/tcp"
    ufw allow "${PORT_RANGE_START}:${PORT_RANGE_END}/udp"
    log "Regole ufw aggiunte per ${PORT_RANGE_START}-${PORT_RANGE_END} (TCP+UDP)."
  fi

  log "Fase 6 completata."
}

HARDWARE_INFO_FILE="/opt/kickstart-berlin/hardware-info.json"

# Fase 8 (issue #8) — Raccolta informazioni hardware, "riusata as-is"
# dalla guida Vast.ai (dmidecode + permessi sudo dedicati, usato per
# popolare il "machine info" del proprio marketplace) — qui alimenta
# invece il node profiling di Grastorp (grastorp#14). Il "permesso sudo
# dedicato" di Vast.ai per dmidecode non serve qui: l'account admin ha
# già sudo NOPASSWD completo (Fase 1, iso/user-data late-commands) — un
# permesso più stretto sarebbe una restrizione IN PIÙ rispetto a quanto
# già garantito, non richiesta da alcun requisito di sicurezza noto per
# questo progetto.
#
# Fase 7 (installazione daemon/backend Grastorp) è saltata per ora
# (non ancora implementata) — questa fase non dipende dal suo codice,
# solo raccoglie dati grezzi che un futuro backend potrà consumare.
#
# Output: snapshot JSON grezzo (dmidecode/lscpu/lspci/lsblk/rete/GPU),
# non lo schema "machine info" specifico di Grastorp — non noto qui,
# grastorp#14 lo definirà quando il backend esisterà. Idempotente per
# costruzione: sola lettura, ogni esecuzione riscrive lo snapshot più
# recente, nessuno stato da preservare tra esecuzioni.
phase8_hardware_info() {
  log "Fase 8: raccolta informazioni hardware ..."

  if ! command -v dmidecode >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y dmidecode
  fi

  mkdir -p "$(dirname "$HARDWARE_INFO_FILE")"

  python3 - "$HARDWARE_INFO_FILE" <<'PYEOF'
import json
import subprocess
import sys


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception as exc:
        return f"<errore: {exc}>"


info = {
    "dmidecode_system": run(["dmidecode", "-t", "system"]),
    "dmidecode_baseboard": run(["dmidecode", "-t", "baseboard"]),
    "dmidecode_memory": run(["dmidecode", "-t", "memory"]),
    "dmidecode_processor": run(["dmidecode", "-t", "processor"]),
    "cpu": run(["lscpu"]),
    "pci": run(["lspci"]),
    "block_devices": run(["lsblk", "-o", "NAME,SIZE,TYPE,MODEL"]),
    "network": run(["ip", "-brief", "addr"]),
    "nvidia_gpu": run(["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader"]),
}

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(info, f, indent=2)
    f.write("\n")
PYEOF

  log "Informazioni hardware salvate in ${HARDWARE_INFO_FILE}."
  log "Fase 8 completata."
}

main() {
  phase3_docker_storage
  phase4_nvidia_driver
  phase5_docker
  phase6_network
  phase8_hardware_info
  # Fase 7 e 9, 12-14 (issue #15) verranno aggiunte qui come nuove
  # funzioni, chiamate in ordine da main(), quando implementate.
}

main "$@"
