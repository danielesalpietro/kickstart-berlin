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

main() {
  phase3_docker_storage
  # Fasi successive (4-9, 12-14, issue #15) verranno aggiunte qui come
  # nuove funzioni, chiamate in ordine da main().
}

main "$@"
