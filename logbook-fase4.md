# Logbook — Fase 4: driver NVIDIA + NVIDIA Container Toolkit (issue #4)

Diario di design e test per la Fase 4. Branch di riferimento:
`claude/fase4-nvidia-driver-toolkit`, basato sulla punta di
`claude/fase3-storage-lvm-docker` (non ancora mergiata: stesso motivo già
documentato in `logbook-fase3.md` per il branch precedente). Per il
contesto delle fasi precedenti vedi [`logbook-fase1.md`](logbook-fase1.md),
[`logbook-fase2.md`](logbook-fase2.md), [`logbook-fase3.md`](logbook-fase3.md).

## 2026-08-19 — Limite noto: niente GPU disponibile

La VM Azure usata per Fase 2/3 (vedi `logbook-fase3.md`) è una taglia
general-purpose (Ev4/Ev6), senza GPU — tutt'altra famiglia su Azure
(NC/ND/NV-series), molto più costosa e con disponibilità spesso limitata
(come già visto con Scaleway per il bare-metal). La Z8 (target reale del
progetto Grastorp, presumibilmente con GPU vera) resta non disponibile
fino al 23/08.

Decisione: procedere comunque con la parte di Fase 4 che **non richiede**
una GPU reale (scrittura dell'automazione, rilevamento hardware, gestione
del caso "nessuna GPU", pacchettizzazione del Container Toolkit), lasciando
esplicitamente sospesa la conferma end-to-end (il driver carica davvero,
`nvidia-smi` risponde, un container vede la GPU) fino a quando non sarà
disponibile hardware reale (Z8, o un'istanza GPU cloud dedicata).

## 2026-08-19 — Decisione di design: driver auto-rilevato, non pinnato

Rileggendo la guida ufficiale Vast.ai (sezione "Install NVIDIA GPU Driver
& CUDA", fornita dall'utente in questa sessione — `docs.vast.ai` non
raggiungibile dal sandbox, stesso limite di rete già noto da Fase 1),
emerge lo stesso disallineamento già visto per l'LVM di Fase 3: il testo
originale dell'issue #4/README ("driver pinnato, es. 535") non corrisponde
alla guida ufficiale, che dice esplicitamente **"we don't require a
specific version... using the latest CUDA-supported driver is
recommended"** — nessuna versione imposta, tre metodi di installazione
equivalenti a scelta (driver Ubuntu, PPA graphics-drivers, o repository
ufficiale NVIDIA).

Chiesto esplicitamente all'utente (coerente col principio "seguiamo
strettamente vast.ai" già applicato in Fase 3): **auto-rilevamento**
(`ubuntu-drivers autoinstall`, nessuna versione hardcoded) invece di una
versione pinnata fissa. Motivazione della scelta: si adatta a modelli GPU
diversi su host diversi senza bisogno di aggiornare manualmente una
versione nel tempo, ed è l'opzione più coerente con la formulazione della
guida ufficiale.

Punti non ambigui della guida, implementati a prescindere dalla decisione
sopra:
- **Disable Auto Updates**: un upgrade automatico del driver può causare
  mismatch NVML tra `nvidia-smi`/driver, con deverifica automatica della
  macchina (terminologia Vast.ai, ma il problema tecnico — mismatch tra
  modulo kernel caricato e libreria userspace — è generale). Implementato
  come `apt-mark hold` su *tutti* i pacchetti `nvidia-*` installati (non
  solo il driver principale: un upgrade parziale di un pacchetto correlato,
  es. `nvidia-dkms-*`, causerebbe lo stesso mismatch).
- Test post-install con `nvidia-smi -q` (qui `nvidia-smi -q` implicito nel
  controllo di funzionamento, vedi sotto).

## 2026-08-19 — Implementazione

Nuova funzione `phase4_nvidia_driver()` in `postinstall/setup.sh`, seconda
fase della sequenza in `main()` dopo `phase3_docker_storage()`:

- **Rilevamento GPU**: lettura diretta di `/sys/bus/pci/devices/*/vendor`
  per il vendor id NVIDIA (`0x10de`), non `lspci` (dipendenza da
  `pciutils`, non garantita su un Ubuntu Server minimale). Se nessuna GPU
  NVIDIA è presente, la fase si ferma con un log esplicito e ritorna
  senza errore — comportamento voluto: un nodo senza GPU non deve far
  fallire l'intero post-install, e questo è esattamente il caso testabile
  senza hardware reale (vedi sotto).
- **Installazione driver**: se `nvidia-smi -q` non funziona (driver
  assente o modulo non caricato), `apt-get install ubuntu-drivers-common`
  + `ubuntu-drivers autoinstall`, poi `apt-mark hold` come sopra.
- **Riavvio gestito in modo idempotente, non un loop**: il modulo kernel
  DKMS appena installato non è caricato nel kernel in esecuzione — serve
  un riavvio prima che `nvidia-smi` funzioni. Un marker
  (`.phase4-nvidia-reboot-attempted`) viene scritto *prima* del riavvio:
  dato che `kickstart-berlin-postinstall.service` scrive
  `.setup-complete` solo dopo che lo script esce con successo
  (`ExecStartPost`), un riavvio a metà script impedisce quella scrittura,
  e al boot successivo l'unit systemd riesegue l'intero script da capo
  (per costruzione idempotente: la Fase 3 e l'installazione driver sono
  no-op se già fatte). Al secondo giro, `phase4_nvidia_driver()` trova il
  driver già installato e verifica `nvidia-smi` invece di reinstallare. Se
  anche al secondo giro `nvidia-smi` non funziona, il marker impedisce un
  ulteriore riavvio automatico e la fase fallisce esplicitamente
  (intervento manuale necessario) — **un solo riavvio automatico, mai un
  loop infinito** su un nodo con un problema hardware/driver reale.
- **NVIDIA Container Toolkit**: repository ufficiale NVIDIA
  (`nvidia.github.io/libnvidia-container`), GPG key + apt source list +
  `apt-get install nvidia-container-toolkit`. Solo il *pacchetto*: la
  configurazione del runtime Docker (`nvidia-ctk runtime configure
  --runtime=docker` + restart del servizio Docker) **non è qui** — Docker
  non è ancora installato a questo punto della sequenza (Fase 5, non Fase
  4: nel README la voce "config con runtime NVIDIA" è esplicitamente
  descritta sotto Fase 5, non Fase 4). Quel passaggio andrà nella futura
  `phase5_docker()`.

Nessun nuovo placeholder `__PLACEHOLDER__` introdotto: Fase 4 non ha
parametri di build-time (a differenza del Datastore di Fase 2/3), quindi
nessuna modifica a `build-iso.sh`/`validate-autoinstall.py`.

## 2026-08-19 — Cosa è stato verificato e cosa no

**Verificato in sandbox** (nessuna GPU disponibile, comportamento atteso
e confermato):
- `shellcheck` pulito, sintassi bash valida (`bash -n`).
- Il percorso "nessuna GPU rilevata" funziona correttamente: invocando
  `phase4_nvidia_driver()` in isolamento su questo sandbox (che non ha
  hardware NVIDIA), la funzione rileva correttamente l'assenza di device
  PCI vendor `0x10de` e ritorna puliata (log esplicito, exit 0) senza
  tentare alcuna installazione.

**Non verificabile in sandbox** (limiti noti, non ipotesi):
- `nvidia.github.io` (repository ufficiale del Container Toolkit) è
  **bloccato dalla policy di rete del sandbox** (stesso tipo di
  restrizione già visto per `docs.vast.ai` in Fase 1 — non un errore del
  server target, ma un diniego a livello di gateway/proxy del sandbox:
  `curl` restituisce 403 sul CONNECT, confermato anche da
  `$HTTPS_PROXY/__agentproxy/status` → `recentRelayFailures` con
  `"kind": "connect_rejected"` per `nvidia.github.io:443`). I comandi di
  aggiunta del repository/installazione del pacchetto **non sono stati
  eseguiti con successo qui**: la logica è scritta seguendo la
  documentazione ufficiale NVIDIA, ma resta da confermare su un ambiente
  con rete diretta (la VM Azure usata per Fase 2/3, che non ha questa
  restrizione).
- Tutto ciò che richiede una GPU reale: se `ubuntu-drivers autoinstall`
  seleziona davvero un driver funzionante, se il modulo kernel carica
  dopo il riavvio, se `nvidia-smi` risponde, se un container vede
  davvero la GPU tramite il Container Toolkit. Nessuna di queste cose è
  testabile senza hardware NVIDIA reale (Z8 o istanza GPU cloud dedicata,
  vedi discussione con l'utente su Azure/RunPod/Scaleway/DataPacket in
  questa sessione).

## 2026-08-20 — Comandi Container Toolkit verificati su rete diretta (VM Azure)

Branch aggiornato prima di procedere: `claude/fase4-nvidia-driver-toolkit`
era stato creato a partire da un punto di Fase 3 non ancora definitivo
(mancava il commit `08d4871`, hardening `datasource_list`/fix leak
hostname test) — mergiato `develop` (dopo il merge della PR #18 di Fase
3) nel branch Fase 4, nessun conflitto.

Eseguiti a mano, uno per uno, esattamente i comandi di
`phase4_nvidia_driver()` relativi al Container Toolkit (non l'intero
`postinstall/setup.sh`: la funzione salta l'intera fase se non rileva una
GPU, e questa VM Azure non ne ha una — verifica mirata solo alla parte
raggiungibilità rete/repo, non al percorso driver+GPU) sull'host VM-TEST2
(rete diretta, nessuna restrizione di sandbox):

1. `curl https://nvidia.github.io/libnvidia-container/gpgkey` → `200`,
   3195 byte, blocco PGP valido (confermato anche `gpg --dearmor`
   riuscito senza errori).
2. `curl https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list`
   → `200`, contenuto atteso (`deb [...] https://nvidia.github.io/...`).
3. Repo aggiunto (`sed` con `signed-by`, stessa trasformazione esatta
   dello script) + `apt-get update`: pulito, nessun errore, catalogo
   pacchetti raggiunto (`apt-cache policy` mostra tutte le versioni
   disponibili, candidate `1.20.0-1`).
4. `apt-get install -y nvidia-container-toolkit`: **riuscito, exit 0**.
   `nvidia-ctk --version` → `NVIDIA Container Toolkit CLI version
   1.20.0`, conferma diretta che il pacchetto installato è funzionante
   (al netto della configurazione runtime Docker, che nello script resta
   volutamente rimandata alla Fase 5).

**Il blocco di rete del sandbox era l'unico ostacolo**: nessun bug nella
logica dello script, nessuna modifica necessaria a
`postinstall/setup.sh`. Pulizia post-test: pacchetto e repo rimossi
dall'host VM-TEST2 (non è un requisito permanente di quella VM).

**Resta non verificabile qui** (nessuna GPU su questa VM): se
`ubuntu-drivers autoinstall` seleziona un driver funzionante, se il
modulo kernel carica dopo il riavvio, se `nvidia-smi` risponde, se un
container vede davvero la GPU — richiede hardware NVIDIA reale (Z8,
disponibile dal 23/08, o un'istanza GPU cloud dedicata).

## Prossimi passi

- [x] Testare su VM Azure (rete diretta, senza GPU): confermare che i
      comandi di aggiunta repository + installazione pacchetto del
      NVIDIA Container Toolkit funzionino davvero — **confermato sopra**.
- [x] Testare il percorso completo (driver + riavvio + `nvidia-smi` +
      Container Toolkit funzionante) su hardware con GPU NVIDIA reale —
      **confermato il 2026-08-23** su HP Z8 G4 + RTX 3090 (driver 595.84,
      CUDA 13.2). Bug trovato e corretto durante questo collaudo:
      `apt-mark hold` su pacchetti `nvidia-*` falliva per voci "fantasma"
      restituite da `dpkg-query -W` non filtrate per stato installato —
      vedi [`logbook_first_boot.md`](logbook_first_boot.md) (Problema 2)
      per il dettaglio completo, fix già applicato in `postinstall/setup.sh`.
- [x] Aprire la PR — fatto (PR #28, `claude/postinstall-firstboot-fixes`,
      mergiata in `develop`); DoD dell'issue #4 ora completa.
