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

set -euo pipefail

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

INSTALL_CMD="$(cat "$COMMAND_FILE")"

shred -u "$COMMAND_FILE" 2>/dev/null || rm -f "$COMMAND_FILE"

[[ -n "$INSTALL_CMD" ]] || err "il file col comando era vuoto"

log "Eseguo l'installer host Vast.ai (comando non stampato nei log: contiene l'identità del tuo account) ..."
if ! bash -c "$INSTALL_CMD"; then
  err "installer Vast.ai terminato con un errore — controlla vast_host_install.log nella directory corrente per il dettaglio (vedi guida ufficiale, sezione Troubleshooting)."
fi

log "Installer completato. Verifica su https://cloud.vast.ai/host/machines/ che la macchina compaia"
log "(può richiedere da pochi minuti a un'ora). Se non compare, controlla vast_host_install.log."
