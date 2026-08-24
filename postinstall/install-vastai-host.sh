#!/usr/bin/env bash
#
# install-vastai-host.sh — installa il vero daemon host Vast.ai (Kaalia),
# per la validazione "full-stack compliant as-is" (Fase 7, issue #7)
# richiesta prima di evolvere verso l'architettura ESX-style/Grastorp:
# prima si conferma che il nodo funziona come host Vast.ai reale (daemon,
# CLI, listing), poi si adatta. Vedi logbook-fase7.md.
#
# Deliberatamente NON fa parte della sequenza automatica di
# postinstall/setup.sh (main(), eseguita al primo boot via systemd
# oneshot): il comando di installazione ufficiale Vast.ai è specifico
# dell'account e valido solo un'ora dalla generazione (va copiato da
# https://cloud.vast.ai/host/setup, da loggato come host) — non può
# essere incorporato nell'ISO a build-time né eseguito automaticamente a
# un primo boot il cui orario non è prevedibile. Va lanciato a mano
# dall'operatore quando è pronto a rendere il nodo un host Vast.ai reale,
# con il comando appena copiato dal portale.
#
# Uso:
#   sudo ./install-vastai-host.sh --command-file /path/al/file
#
# Il file deve contenere ESATTAMENTE il comando copiato dal pulsante
# "copy" della pagina host/setup — mai passarlo come argomento diretto
# sulla riga di comando: resterebbe nella shell history in chiaro. Il
# file viene letto e poi distrutto subito dopo l'uso (contiene
# un'identità d'account valida solo 1 ora, nessun motivo di lasciarlo su
# disco più del necessario).
#
# IMPORTANTE: l'installer Vast.ai (`install-wizard`) è un wizard TUI a
# schermo intero (10 step: Welcome...Rentability) — questo script va
# lanciato da un TERMINALE INTERATTIVO VERO (SSH interattivo o console
# fisica), non da un'automazione headless: senza una TTY reale il
# wizard resta bloccato in attesa di input che non arriva mai. Scoperto
# sul primo collaudo reale (Z8), vedi logbook-fase7.md.
#
# Pre/post-flight (sotto): l'installer ufficiale Vast.ai non è pensato
# per l'architettura ESX-style di questo repo (Fase 2/3, /var/lib/docker
# come symlink verso il Datastore) né per un daemon.json già esistente —
# 3 bug reali trovati sul primo collaudo con un comando vero su hardware
# fisico, dettaglio completo in logbook-fase7.md:
#   1. `os.rename('/var/lib/docker/', ...)` fallisce con NotADirectoryError
#      su un symlink (path con trailing slash) — abortisce l'intero
#      installer PRIMA di reinstallare Docker.
#   2. `dpkg` si blocca su un prompt interattivo Y/I/N/O/D/Z per
#      /etc/docker/daemon.json già esistente (scritto dalle nostre
#      phase3/phase4) quando nvidia-docker2 prova a installare la sua
#      versione di default.
#   4. Un `apt-get` esterno (probabile trigger di rete) può tenere il
#      lock dpkg proprio mentre l'installer prova a usarlo.
# (Bug 3 — un file XFS loop-mounted che lo step "Storage" del wizard può
# piazzare sulla partizione di root — non è automatizzabile qui: è una
# scelta del wizard stesso durante l'uso interattivo, non un side effect
# di questo script. Resta un problema noto, non gestito.)
#
# Questi 3 fix sono scritti qui sotto ma NON ANCORA verificati end-to-end
# come blocco unico (solo i singoli passi manuali sono stati confermati
# uno per uno durante il collaudo reale) — vedi logbook-fase7.md,
# sezione "Prossimi passi", prima di fidarsene ciecamente su un nuovo
# host.

set -euo pipefail

DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
VAR_LIB_DOCKER="/var/lib/docker"
PREFLIGHT_STATE_DIR=""

COMMAND_FILE=""

usage() {
  cat <<EOF
Uso: $(basename "$0") --command-file <path>

  --command-file <path>  File di testo contenente il comando di
                          installazione copiato da
                          https://cloud.vast.ai/host/setup (da loggato
                          come host, valido solo 1 ora dalla
                          generazione). Il file viene letto e poi
                          distrutto in modo sicuro subito dopo l'uso.
  -h, --help              Mostra questo messaggio.
EOF
}

log() { printf '[vastai-host] %s\n' "$*" >&2; }
err() { printf '[vastai-host] ERRORE: %s\n' "$*" >&2; exit 1; }

# Bug 1/2/4 (vedi logbook-fase7.md): prepara l'ambiente prima di lanciare
# l'installer Vast.ai, che non gestisce né un /var/lib/docker symlink
# (Fase 3, ESX-style) né un daemon.json già esistente, ed è vulnerabile
# a un lock dpkg conteso da processi apt esterni.
_preflight() {
  log "Preflight: preparo l'ambiente per l'installer Vast.ai (bug noti, vedi logbook-fase7.md) ..."

  # Bug 4: timer automatici che possono tenere il lock dpkg proprio
  # mentre l'installer prova a usarlo. Mascherati per la durata di
  # questo script (non permanentemente): non c'e' un "unmask" a fine
  # script per design, l'operatore li riattiva a mano se/quando vuole
  # (idempotente: rieseguibile, mask di qualcosa gia' mascherato e' un
  # no-op silenzioso).
  systemctl mask apt-daily.timer apt-daily-upgrade.timer \
    apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

  # Bug 1: os.rename() dell'installer Vast.ai fallisce (NotADirectoryError)
  # su /var/lib/docker come symlink (path con trailing slash). Salviamo il
  # target reale (Datastore) per la migrazione in _postflight sotto.
  if [[ -L "$VAR_LIB_DOCKER" ]]; then
    readlink -f "$VAR_LIB_DOCKER" > "${PREFLIGHT_STATE_DIR}/docker-datastore-target"
    rm -f "$VAR_LIB_DOCKER"
    mkdir -p "$VAR_LIB_DOCKER"
    chown root:root "$VAR_LIB_DOCKER"
    chmod 0710 "$VAR_LIB_DOCKER"
    log "Preflight: ${VAR_LIB_DOCKER} era un symlink verso il Datastore, sostituito con una directory vuota per l'installer."
  fi

  # Bug 2: dpkg si blocca su un prompt interattivo Y/I/N/O/D/Z se
  # daemon.json esiste gia' (scritto dalle nostre phase3/phase4).
  if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
    mv "$DOCKER_DAEMON_JSON" "${PREFLIGHT_STATE_DIR}/daemon.json.backup"
    log "Preflight: ${DOCKER_DAEMON_JSON} esistente spostato da parte (ripristinato/mergiato in _postflight)."
  fi
}

# Ripristina lo stato coerente con l'architettura Datastore di questo
# repo dopo l'installer Vast.ai (successo o fallimento — vedi trap EXIT
# sotto: lasciare il nodo con /var/lib/docker vuota o senza daemon.json
# in caso di errore sarebbe peggio che ripristinarlo comunque).
_postflight() {
  [[ -n "$PREFLIGHT_STATE_DIR" && -d "$PREFLIGHT_STATE_DIR" ]] || return 0
  log "Postflight: ripristino la configurazione Docker del Datastore ..."

  local docker_target=""
  if [[ -f "${PREFLIGHT_STATE_DIR}/docker-datastore-target" ]]; then
    docker_target="$(cat "${PREFLIGHT_STATE_DIR}/docker-datastore-target")"
  fi

  if [[ -n "$docker_target" && -d "$VAR_LIB_DOCKER" && ! -L "$VAR_LIB_DOCKER" ]]; then
    if [[ -z "$(ls -A "$VAR_LIB_DOCKER" 2>/dev/null)" ]]; then
      rmdir "$VAR_LIB_DOCKER"
      ln -s "$docker_target" "$VAR_LIB_DOCKER"
      log "Postflight: ${VAR_LIB_DOCKER} era ancora vuota, ripristinato il symlink verso il Datastore."
    else
      log "Postflight: ${VAR_LIB_DOCKER} contiene dati scritti dall'installer, migrazione verso il Datastore (stessa logica di phase3_docker_storage()) ..."
      local docker_was_active=0
      if systemctl is-active --quiet docker 2>/dev/null; then
        docker_was_active=1
        systemctl stop docker
      fi
      cp -a "${VAR_LIB_DOCKER}/." "${docker_target}/"
      rm -rf "$VAR_LIB_DOCKER"
      ln -s "$docker_target" "$VAR_LIB_DOCKER"
      [[ "$docker_was_active" == "1" ]] && systemctl start docker
      log "Postflight: migrazione completata."
    fi
  fi

  if [[ -f "${PREFLIGHT_STATE_DIR}/daemon.json.backup" && -n "$docker_target" ]]; then
    # Merge: le nostre chiavi (backup) hanno precedenza su quelle
    # eventualmente scritte dall'installer/nvidia-docker2 per lo stesso
    # nome (confrontate in logbook-fase7.md: nessun conflitto funzionale
    # reale, solo "args" vs "runtimeArgs", entrambi lista vuota) — ma le
    # chiavi SOLO nel file post-installer vengono preservate. data-root
    # forzato comunque sul Datastore, indipendentemente dal merge.
    python3 - "$DOCKER_DAEMON_JSON" "${PREFLIGHT_STATE_DIR}/daemon.json.backup" "$docker_target" <<'PYEOF'
import json
import os
import sys

current_path, backup_path, data_root = sys.argv[1], sys.argv[2], sys.argv[3]

def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        content = f.read().strip()
        return json.loads(content) if content else {}

merged = {**load(current_path), **load(backup_path)}
merged["data-root"] = data_root
with open(current_path, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PYEOF
    log "Postflight: ${DOCKER_DAEMON_JSON} ripristinato/mergiato con data-root sul Datastore."
    systemctl restart docker 2>/dev/null || true
  fi

  rm -rf "$PREFLIGHT_STATE_DIR"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command-file) COMMAND_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

[[ -n "$COMMAND_FILE" ]] || { usage; err "--command-file obbligatorio"; }
[[ -f "$COMMAND_FILE" ]] || err "file non trovato: ${COMMAND_FILE}"
[[ "$EUID" -eq 0 ]] || err "questo script richiede i permessi di root (sudo)"
[[ -t 0 && -t 1 ]] || err "questo script va lanciato da un terminale interattivo vero (SSH interattivo o console fisica) — l'installer Vast.ai è un wizard TUI a schermo intero, resta bloccato senza una TTY reale (vedi logbook-fase7.md)."

INSTALL_CMD="$(cat "$COMMAND_FILE")"

shred -u "$COMMAND_FILE" 2>/dev/null || rm -f "$COMMAND_FILE"

[[ -n "$INSTALL_CMD" ]] || err "il file col comando era vuoto"

PREFLIGHT_STATE_DIR="$(mktemp -d /tmp/kickstart-berlin-vastai-preflight.XXXXXX)"
trap _postflight EXIT
_preflight

log "Eseguo l'installer host Vast.ai (comando non stampato nei log: contiene l'identità del tuo account) ..."
if ! bash -c "$INSTALL_CMD"; then
  err "installer Vast.ai terminato con un errore — controlla vast_host_install.log nella directory corrente per il dettaglio (vedi guida ufficiale, sezione Troubleshooting)."
fi

log "Installer completato. Verifica su https://cloud.vast.ai/host/machines/ che la macchina compaia"
log "(può richiedere da pochi minuti a un'ora). Se non compare, controlla vast_host_install.log."
