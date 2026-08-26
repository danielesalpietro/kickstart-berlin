# lib-node-status.sh — funzioni condivise per la schermata informativa
# su tty1 (console-status.sh, issue #27) e per il banner SSH al login
# (motd-vastai-status, stessa issue: "le stesse informazioni le
# riporterei come banner alla prima connessione via ssh"). Solo lettura,
# nessuna delle due modalità gestisce input.
#
# Va SORGENTATO (source), mai eseguito direttamente — non ha uno
# shebang eseguibile di proposito, solo funzioni. Il chiamante deve
# definire "set -uo pipefail" (non "set -e": una singola riga di stato
# fallita non deve terminare il chiamante).
#
# Questo file è un template: i placeholder __DATASTORE_MOUNT_ROOT__ e
# __DATASTORE_SYMLINK_NAME__ vengono sostituiti da scripts/build-iso.sh,
# stesso meccanismo di postinstall/setup.sh.

DATASTORE_LINK="__DATASTORE_MOUNT_ROOT__/__DATASTORE_SYMLINK_NAME__"
VASTAI_KAALIA_DIR="/var/lib/vastai_kaalia"
VASTAI_MACHINE_ID_FILE="${VASTAI_KAALIA_DIR}/machine_id"

# Esclude, oltre a "lo", le interfacce create da Docker (bridge
# "docker0", reti "br-*", veth dei container): IP privati mai
# raggiungibili dall'esterno, che qui sarebbero solo rumore/fuorvianti
# per l'operatore che cerca l'IP reale della macchina (issue #27:
# l'obiettivo è "leggere l'IP dallo schermo", non elencare ogni
# interfaccia del kernel). Stesso filtro AWK duplicato nelle due
# funzioni sotto (letterale, non interpolato da bash) per evitare i
# problemi di escaping di un programma AWK passato tramite variabile.
_ip_lines() {
  local out
  out="$(ip -brief addr show scope global up 2>/dev/null | awk '
    $1 == "lo" || $1 ~ /^docker[0-9]*$/ || $1 ~ /^br-/ || $1 ~ /^veth/ { next }
    { sub(/\/.*/, "", $3); print "    " $1 ": " $3 }
  ')"
  if [[ -z "$out" ]]; then
    echo "    In attesa di un indirizzo IP (DHCP)..."
  else
    printf '%s\n' "$out"
  fi
}

_first_ip() {
  ip -brief addr show scope global up 2>/dev/null | awk '
    $1 == "lo" || $1 ~ /^docker[0-9]*$/ || $1 ~ /^br-/ || $1 ~ /^veth/ { next }
    { sub(/\/.*/, "", $3); print $3; exit }
  '
}

# Soglia di avviso "disco quasi pieno" condivisa fra Datastore/Docker e
# disco di sistema sotto - stessa soglia per entrambi, nessun motivo
# noto per differenziarle. Solo testo ASCII per l'avviso ("ATTENZIONE",
# non un simbolo/emoji): la console fisica reale non renderizza
# caratteri fuori font (stessa lezione già imparata con l'em-dash
# altrove in questo repo).
DISK_WARN_PCENT=90

_datastore_line() {
  if [[ -L "$DATASTORE_LINK" && -d "$DATASTORE_LINK" ]]; then
    local total avail pcent warn=""
    read -r total avail < <(df -h --output=size,avail "$DATASTORE_LINK" 2>/dev/null | tail -n1)
    pcent="$(df --output=pcent "$DATASTORE_LINK" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    if [[ -n "$pcent" && "$pcent" -ge "$DISK_WARN_PCENT" ]]; then
      warn=" - ATTENZIONE: spazio quasi esaurito, rischio di non poter avviare nuovi container Docker"
    fi
    echo "    Montato - ${avail:-?} liberi su ${total:-?} (${pcent:-?}% usato, ${DATASTORE_LINK})${warn}"
  else
    echo "    Non montato"
  fi
}

# Disco di root separato dal Datastore: se questo si riempie il nodo si
# blocca (systemd/journal/apt/ssh hanno tutti bisogno di scrivere su
# root), non solo Docker - richiesto esplicitamente dall'utente con
# questa distinzione di gravità.
_system_disk_line() {
  local size avail pcent warn=""
  read -r size avail < <(df -h --output=size,avail / 2>/dev/null | tail -n1)
  pcent="$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9')"
  if [[ -n "$pcent" && "$pcent" -ge "$DISK_WARN_PCENT" ]]; then
    warn=" - ATTENZIONE: disco di sistema quasi pieno, rischio di blocco generale del nodo"
  fi
  echo "    ${avail:-?} liberi su ${size:-?} (${pcent:-?}% usato)${warn}"
}

# Gateway di default - utile per diagnosticare problemi di rete dalla
# console fisica senza dover già avere un altro modo di raggiungere il
# nodo (che è esattamente il caso in cui questa schermata serve di più).
_gateway_line() {
  local gw dev
  read -r gw dev < <(ip -4 route show default 2>/dev/null | awk '{print $3, $5; exit}')
  if [[ -n "$gw" ]]; then
    echo "    ${gw} (via ${dev:-?})"
  else
    echo "    Non disponibile"
  fi
}

# DNS: prova prima "resolvectl" (systemd-resolved, mostra i server DNS
# reali a monte) - fallback su /etc/resolv.conf diretto se resolvectl
# non è disponibile (con systemd-resolved attivo quel file punta spesso
# solo allo stub locale 127.0.0.53, meno utile, ma è comunque un
# fallback ragionevole se resolvectl manca del tutto).
_dns_line() {
  local dns=""
  if command -v resolvectl >/dev/null 2>&1; then
    dns="$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1{print $2}' | tr -s ' \n' ' ' | sed 's/[[:space:]]*$//')"
  fi
  if [[ -z "$dns" && -r /etc/resolv.conf ]]; then
    dns="$(awk '/^nameserver/{print $2}' /etc/resolv.conf | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
  echo "    ${dns:-Non disponibile}"
}

# CPU: modello + carico come percentuale (richiesto esplicitamente
# "carico in %", non il load average grezzo) - approssimazione
# standard load1/core_count*100, non una misura precisa istantanea
# (richiederebbe due letture di /proc/stat con un intervallo, troppo
# per una singola riga di stato).
_cpu_line() {
  local model load1 cores pct=""
  model="$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[[:space:]]*//')"
  read -r load1 _ < /proc/loadavg 2>/dev/null || load1=""
  cores="$(nproc 2>/dev/null)"
  if [[ -n "$load1" && -n "$cores" && "$cores" -gt 0 ]]; then
    pct="$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.0f", (l/c)*100}')"
  fi
  echo "    ${model:-CPU sconosciuta}"
  echo "    Carico: ${pct:-?}% (load1 ${load1:-?}, ${cores:-?} core)"
}

_gpu_line() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "    Nessuna GPU NVIDIA rilevata"
    return
  fi
  local info
  if info="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"; then
    printf '%s\n' "$info" | sed 's/^/    /'
  else
    echo "    Driver NVIDIA installato ma nvidia-smi non risponde"
  fi
}

_os_line() {
  local pretty_name="Ubuntu"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    pretty_name="${PRETTY_NAME:-Ubuntu}"
  fi
  echo "${pretty_name} (kernel $(uname -r))"
}

# Vero solo se Fase 7 (daemon Vast.ai, install-vastai-host.sh) è stata
# eseguita su questo nodo — entrambe le sezioni Vast.ai sotto vanno
# omesse del tutto sugli altri nodi (es. futuri host Grastorp non
# Vast.ai), non solo mostrate vuote.
_vastai_installed() {
  [[ -d "$VASTAI_KAALIA_DIR" ]]
}

# Stato dei servizi systemd del daemon Vast.ai — locale, nessuna
# dipendenza di rete, sempre veloce. "vastai.service" è il daemon host
# vero e proprio (Kaalia); "vast_metrics.service" il collettore metriche
# associato. Elenca solo le unit realmente presenti (LoadState=loaded):
# nomi/versioni del daemon potrebbero cambiare in una release futura di
# Vast.ai, meglio non assumere che esistano sempre entrambe.
_vastai_services_line() {
  local svc load_state active_state out=""
  for svc in vastai.service vast_metrics.service; do
    load_state="$(systemctl show "$svc" -p LoadState --value 2>/dev/null)"
    [[ "$load_state" == "loaded" ]] || continue
    active_state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    out+="    ${svc}: ${active_state:-sconosciuto}"$'\n'
  done
  if [[ -z "$out" ]]; then
    echo "    Nessun servizio Vast.ai trovato (attesa dopo il boot?)"
  else
    printf '%s' "$out"
  fi
}

# Stato della macchina lato Vast.ai (affidabilità, verifica, listing,
# manutenzione) — replica le informazioni chiave che il portale
# cloud.vast.ai/host/machines mostra per questa macchina. A differenza
# delle altre righe sopra, richiede rete + CLI `vastai` autenticata
# (Fase 10): "timeout 5" limita il ritardo massimo che una singola
# iterazione del loop di console-status.sh può subire per una chiamata
# di rete lenta/assente, così un problema di rete rallenta il refresh
# di al più 5s invece di bloccarlo indefinitamente.
#
# NON usa VASTAI_MACHINE_ID_FILE (/var/lib/vastai_kaalia/machine_id):
# contiene un identificativo interno lungo (hash), non l'ID numerico
# che "vastai show machine <id>" si aspetta (es. 148447) - scoperto sul
# primo collaudo reale, vedi logbook-issue27-console-status.md. Usa
# invece "vastai show machines" (senza ID, elenca tutte le macchine
# dell'account) e filtra per hostname - più robusto, non dipende dal
# formato di quel file.
_vastai_machine_line() {
  command -v vastai >/dev/null 2>&1 || { echo "    CLI vastai non installata (Fase 10 non ancora completata?)"; return; }

  # HOME=/home/admin esplicito: questa funzione gira anche dal servizio
  # systemd di console-status.sh (root, nessun HOME utente) - l'API key
  # di "vastai" viene però configurata dall'operatore come utente
  # "admin" (unico account del nodo, vedi iso/user-data), quindi vive
  # sotto /home/admin/.config/vastai/, non root. Senza questo, "vastai"
  # come root non trova nessuna autenticazione e la sezione risulta
  # sempre vuota anche a API key correttamente configurata - scoperto
  # sul primo collaudo reale, vedi logbook-issue27-console-status.md.
  local raw
  raw="$(HOME=/home/admin timeout 5 vastai show machines --raw 2>/dev/null)"
  if [[ -z "$raw" ]]; then
    echo "    dati non disponibili (rete assente o API non raggiungibile)"
    return
  fi

  printf '%s' "$raw" | python3 -c '
import json
import sys
import time
import socket

try:
    data = json.load(sys.stdin)
    machines = data.get("machines", []) if isinstance(data, dict) else data
    hostname = socket.gethostname()
    d = next((m for m in machines if m.get("hostname") == hostname), None)
    if d is None and machines:
        d = machines[0]
    if not d:
        raise ValueError("empty")

    rel = d.get("reliability2")
    rel_str = f"{rel * 100:.1f}%" if isinstance(rel, (int, float)) else "?"

    verification = d.get("verification", "?")

    listed = d.get("listed")
    price = d.get("listed_gpu_cost")
    if listed and isinstance(price, (int, float)):
        listed_str = f"si (${price:.2f}/GPU/h)"
    elif listed:
        listed_str = "si"
    else:
        listed_str = "no"

    running = d.get("current_rentals_running", 0)

    maint_str = ""
    maint = d.get("machine_maintenance") or []
    if maint:
        m = maint[0]
        start = m.get("start_time")
        dur = m.get("duration_hours")
        if isinstance(start, (int, float)) and isinstance(dur, (int, float)):
            remaining_h = (start + dur * 3600 - time.time()) / 3600
            if remaining_h > 0:
                maint_str = f", MANUTENZIONE attiva (~{remaining_h:.0f}h rimanenti)"

    machine_id = d.get("id", "?")
    print(f"    ID {machine_id}  affidabilita {rel_str}  {verification}  listato: {listed_str}  in uso: {running}{maint_str}")
except Exception:
    print("    dati ricevuti ma non interpretabili")
'
}
