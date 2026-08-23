#!/usr/bin/env bash
#
# vastai-self-test.sh — esegue il self-test ufficiale Vast.ai
# (`vastai self-test machine <machine_id>`, Fase 11, issue #11):
# verifica GPU/driver/CUDA e banda di rete minima per un host già
# listato sul marketplace. Comando reale della CLI ufficiale
# (vast-ai/vast-cli, MIT), non un'imitazione: produce anche un tarball
# diagnostico redatto in caso di fallimento.
#
# Deliberatamente NON fa parte della sequenza automatica di
# postinstall/setup.sh: richiede un machine_id reale, che esiste solo
# DOPO che il daemon di Fase 7 ha listato con successo la macchina su
# https://cloud.vast.ai/host/machines/, e richiede la CLI vastai
# (Fase 10, automatica) già autenticata a mano dall'operatore
# (`vastai set api-key ...`) — mai eseguito automaticamente, stessa
# disciplina già applicata alla chiave SSH e al comando d'installazione
# del daemon: nessun segreto mai hardcoded o committato nel repo.
#
# Prerequisiti (guida ufficiale, "How to Self-Test"): la macchina deve
# essere già listata e senza client attivi che la stanno affittando in
# quel momento. Anche in modalità --ignore-requirements, la macchina
# deve avere almeno 3 porte dirette aperte (Fase 6, range configurato in
# config/autoinstall-defaults.json) - sotto quella soglia il self-test
# fallisce comunque. Se il test segnala "not found or not rentable":
# ritira e rilista la macchina, e verifica che la pagina host/machines
# non abbia dati mancanti (banda upload/download, RAM, porte).
#
# Uso:
#   ./vastai-self-test.sh --machine-id <ID> [-- <flag extra per vastai self-test>]
#
# Esempio con i flag ufficiali della CLI (vedi
# `vastai self-test machine --help` per l'elenco completo):
#   ./vastai-self-test.sh --machine-id 12345 -- --ignore-requirements

set -euo pipefail

MACHINE_ID=""
EXTRA_ARGS=()

usage() {
  cat <<EOF
Uso: $(basename "$0") --machine-id <ID> [-- <flag extra per 'vastai self-test machine'>]

  --machine-id <ID>  ID della macchina già listata su Vast.ai (vedi
                      https://cloud.vast.ai/host/machines/ oppure
                      'vastai show machines').
  -h, --help          Mostra questo messaggio.

Tutto ciò che segue "--" viene passato invariato a
'vastai self-test machine' (es. --ignore-requirements, --test-image,
--raw). Vedi 'vastai self-test machine --help' per l'elenco completo.
EOF
}

log() { printf '[vastai-self-test] %s\n' "$*" >&2; }
err() { printf '[vastai-self-test] ERRORE: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine-id)
      [[ $# -ge 2 ]] || err "--machine-id richiede un valore"
      MACHINE_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    *) err "Opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

[[ -n "$MACHINE_ID" ]] || { usage; err "--machine-id obbligatorio"; }

command -v vastai >/dev/null 2>&1 \
  || err "CLI vastai non trovata (Fase 10 non eseguita/non riuscita?). Installa con: curl -fsSL https://vast.ai/install.sh | bash"

vastai show user >/dev/null 2>&1 \
  || err "API key non configurata o non valida: esegui 'vastai set api-key <la-tua-api-key>' (da https://cloud.vast.ai/manage-keys/?tab=api-keys) prima di ripetere il self-test."

log "Eseguo il self-test ufficiale Vast.ai sulla macchina ${MACHINE_ID} ..."
if ! vastai self-test machine "$MACHINE_ID" "${EXTRA_ARGS[@]}"; then
  err "self-test fallito - controlla il tarball diagnostico prodotto da vastai (vast_selftest_${MACHINE_ID}_*.tar.gz) per il dettaglio."
fi

log "Self-test completato con successo per la macchina ${MACHINE_ID}."
