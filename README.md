# kickstart-berlin

Automazione dell'installazione **from-scratch** di un nodo GPU: dalla ISO di
boot fino a un host pronto (OS, driver NVIDIA, Docker, rete, benchmark
hardware). Base derivata dal flusso di setup host di **Vast.ai**, propedeutica
all'integrazione in [Grastorp](https://github.com/danielesalpietro/grastorp).

> Stato: **early stage**, ma con la prima conferma end-to-end su hardware
> fisico reale (HP Z8 G4 + RTX 3090, primo boot 2026-08-23) per le Fasi
> 1-6, 8 e 10 — vedi [`logbook_first_boot.md`](logbook_first_boot.md) per
> il diario completo del collaudo (3 bug trovati e corretti in
> `postinstall/setup.sh`: pacchetti NVIDIA "fantasma" in Fase 4, `$HOME`
> non definita e permessi `/root` in Fase 10) e
> [`docs/collaudo-funzionale.md`](docs/collaudo-funzionale.md) per lo
> stato aggiornato test-per-test. Fase 7 (daemon Vast.ai reale) e Fase 11
> (self-test) restano da eseguire sullo stesso nodo — vedi
> [`docs/setup.md`](docs/setup.md), Step 5 in poi. **Problema noto**: la
> selezione automatica del disco (`match: {}`) non esclude i moduli
> Optane PMem, quindi su hardware con PMem installato l'esito non è
> deterministico — vedi `docs/collaudo-funzionale.md`.

## Perché

Prima di poter installare Grastorp su un nodo fisico "vuoto", serve un
procedimento ripetibile che porti una macchina da ISO di boot a host pronto
(OS configurato, driver NVIDIA, Docker con runtime GPU, rete, primo
assessment hardware). Piuttosto che progettare questo flusso da zero, si parte
da un procedimento già maturo e testato su migliaia di macchine reali: quello
che i provider [RunPod](https://runpod.io) e [Vast.ai](https://vast.ai) usano
per trasformare una macchina in un nodo del loro marketplace GPU. Vast.ai in
particolare pubblica una guida host-setup dettagliata (`docs.vast.ai`) e
diversi script community ne replicano fedelmente i passi.

Questo repo isola quel procedimento (OS → driver → container runtime → rete →
benchmark) dalla parte specifica di Vast.ai (il suo daemon proprietario, il
suo marketplace), per poterlo riusare come base d'installazione di un nodo
Grastorp, con le dovute sostituzioni (vedi mapping sotto).

## Nota terminologica su "Kickstart"

Il nome è preso in prestito da **Kickstart**, il formato storico di
installazione automatizzata di Red Hat/Fedora (file `.ks`). Il sistema
operativo di riferimento in questo flusso è però **Ubuntu Server** (coerente
con quanto usato da Vast.ai e da Grastorp stesso), che non usa il formato
Kickstart ma il meccanismo di installazione automatizzata di Subiquity,
**autoinstall** (basato su cloud-init). Il nome del repo va quindi letto come
riferimento generico al concetto ("installazione automatizzata da zero"), non
come indicazione tecnica del formato file che verrà effettivamente usato.

## Le fasi del setup host, mappate da Vast.ai

Ricostruite analizzando la documentazione host di Vast.ai
(`docs.vast.ai/host/hosting-overview`) e uno script community che la
replica (`vastai-host-setup`). Ogni fase Vast.ai è annotata con il suo
equivalente per un nodo Grastorp.

| # | Fase (Vast.ai) | Cosa fa Vast.ai | Equivalente kickstart-berlin / Grastorp | Stato |
|---|---|---|---|---|
| 1 | Sistema operativo | Ubuntu Server 22.04/24.04 da ISO ufficiale | Stessa base OS, via `autoinstall` invece di installazione manuale interattiva | **Fatto** ([#1](https://github.com/danielesalpietro/kickstart-berlin/issues/1)) |
| 2 | Partizionamento disco | `/` ext4 (~100GB) + resto disco separato (xfs, non montato) | Stesso schema: partizione di sistema + partizione dedicata allo storage (Datastore Grastorp) | **In corso** ([#2](https://github.com/danielesalpietro/kickstart-berlin/issues/2)) |
| 3 | Preparazione storage | Estensione LVM, rimozione loopback Docker, dati Docker sul filesystem principale | Adattato: nessuna estensione LVM (non prevista dalla guida ufficiale Vast.ai, seguita strettamente — vedi `logbook-fase3.md`), Docker configurato sul Datastore ESX-style con symlink di compatibilità da `/var/lib/docker` | **In corso** ([#3](https://github.com/danielesalpietro/kickstart-berlin/issues/3)) |
| 4 | Driver NVIDIA + Container Toolkit | Driver pinnato (es. 535) + NVIDIA Container Toolkit da repo ufficiale | Adattato: nessuna versione pinnata (non richiesta dalla guida ufficiale Vast.ai, seguita strettamente — vedi `logbook-fase4.md`), driver auto-rilevato via `ubuntu-drivers autoinstall` | **In corso** ([#4](https://github.com/danielesalpietro/kickstart-berlin/issues/4)) |
| 5 | Docker | Install da `get.docker.com`, config con runtime NVIDIA | Identico | **In corso** ([#5](https://github.com/danielesalpietro/kickstart-berlin/issues/5)) |
| 6 | Rete | DHCP via Netplan, DNS pubblici, hostname | Identico, propedeutico al rilevamento NIC di Grastorp ([grastorp#11](https://github.com/danielesalpietro/grastorp/issues/11)); range di porte TCP+UDP aperto su ufw se attivo (guida ufficiale Vast.ai) | **In corso** ([#6](https://github.com/danielesalpietro/kickstart-berlin/issues/6)) |
| 7 | Installazione daemon del provider | Wizard ufficiale Vast.ai (Kaalia daemon) + API key utente | **Riordinato**: si valida prima il nodo come host Vast.ai reale (daemon ufficiale, installato a mano dall'operatore) per confermare la piena compatibilità dello stack — l'evoluzione verso il backend/agent Grastorp resta il passo successivo, non sostituisce più questa fase (vedi `logbook-fase7.md`) | **In corso** ([#7](https://github.com/danielesalpietro/kickstart-berlin/issues/7)) |
| 8 | Raccolta info hardware | `dmidecode` + permessi sudo dedicati, usato per popolare il "machine info" del marketplace | **Riusato as-is**: stesso meccanismo alla base del node profiling di Grastorp ([grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14)) — permessi sudo dedicati non necessari (l'admin ha già NOPASSWD completo) | **In corso** ([#8](https://github.com/danielesalpietro/kickstart-berlin/issues/8)) |
| 9 | Manutenzione | Timer systemd per pulizia oraria container/immagini inutilizzati | Riusabile as-is | Da fare |
| 10 | CLI del provider | Install CLI Vast.ai, config con API key | **Riordinato**, stessa logica di Fase 7: installata automaticamente in `setup.sh` (nessun segreto d'account nell'installer), per validare lo stack "as-is" prima dell'evoluzione verso Grastorp/RunPod ([grastorp#15](https://github.com/danielesalpietro/grastorp/issues/15)) | **Fatto** ([#10](https://github.com/danielesalpietro/kickstart-berlin/issues/10)) |
| 11 | Self-test/benchmark | Speedtest di rete + verifica GPU/RAM/rete, esito inviato al backend Vast.ai | **Riordinato**, stessa logica di Fase 7: `vastai self-test machine <machine_id>` reale (script standalone, a mano dall'operatore dopo un listing riuscito), non l'assessment Grastorp — resta comunque il passo successivo previsto, non sostituito da questa fase (vedi [grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14)) | **Fatto** ([#11](https://github.com/danielesalpietro/kickstart-berlin/issues/11)) |
| 12 | Port forwarding | Range di porte da aprire manualmente sul router, mostrato all'utente | Stesso principio, range di porte adattato ai deployment Grastorp invece che al range Vast.ai (16384-32768) | Da fare |
| 13 | Listing marketplace | Pubblicazione della macchina sul marketplace Vast.ai (prezzo, durata) | **Non applicabile** al nodo locale; diventa rilevante solo per l'integrazione provider di [grastorp#15](https://github.com/danielesalpietro/grastorp/issues/15) | Fuori scope iniziale |
| 14 | Report finale | Riepilogo: Machine ID, GPU, IP, porte, stato servizi | Riepilogo equivalente a fine installazione: stato Grastorp, GPU rilevate, IP, porte, esito assessment | Da fare |

## Architettura prevista

- **ISO di boot**: immagine Ubuntu Server con file `autoinstall`
  (cloud-init) per rendere il partizionamento (fase 2) e l'installazione
  base non interattivi.
- **Script post-install**: uno script idempotente (stile
  `vastai-host-setup/setup.sh`, ma senza le parti specifiche Vast.ai) per le
  fasi 3-9 e 12-14, eseguito al primo boot via systemd unit oneshot.
- **Nessun daemon proprietario di terzi**: al posto del Kaalia daemon (fase
  7) e della CLI/listing Vast.ai (fasi 10/13), il post-install porta
  direttamente all'avvio di Grastorp via `docker compose up`.

## Fase 1 — build dell'ISO autoinstall

- `iso/user-data`, `iso/meta-data` — configurazione autoinstall (Subiquity):
  locale, tastiera, utente `admin` con SSH abilitato e login via password
  disabilitato. La chiave pubblica SSH **non** è hardcoded: viene iniettata
  a build-time.
- `scripts/build-iso.sh` — scarica l'ISO ufficiale Ubuntu Server, ne
  verifica checksum SHA256 (e firma GPG, se `gpg` è disponibile), la
  ripacchetta iniettando `iso/user-data`/`iso/meta-data` e produce un'ISO
  bootabile pronta per l'installazione non interattiva:

  ```sh
  scripts/build-iso.sh -k ~/.ssh/id_ed25519.pub
  ```

- **Build su richiesta via GitHub Actions**: workflow `Build ISO (on-demand)`
  (`.github/workflows/build-iso.yml`), avviabile manualmente da tab Actions →
  seleziona workflow → "Run workflow". Richiede di incollare la chiave SSH
  pubblica nell'apposito campo (mai salvata nel repo) e opzionalmente
  versione Ubuntu, topologia dischi, size partizione, hostname prefix,
  range porte; l'ISO risultante è scaricabile come artifact della run al
  termine del build (conservato per `retention_days`, default 7 giorni).
  Il comando di installazione host Vast.ai (Fase 7) non è mai incluso
  nell'ISO: resta un passo manuale post-boot, vedi Fase 7 più sotto.
- `scripts/boot-test-qemu.sh` — boota l'ISO generata in QEMU headless su un
  disco virtuale throwaway e verifica che l'installazione completi senza
  prompt e che l'host risultante sia raggiungibile via SSH con la chiave
  iniettata (usato dal job di integrazione in CI).
- `scripts/validate-autoinstall.py` — validazione sintattica/strutturale di
  `iso/user-data` (job "unit" in CI, ad ogni PR).
- [`docs/usb-boot.md`](docs/usb-boot.md) — istruzioni per scrivere l'ISO su
  chiavetta USB (`dd`, balenaEtcher/Rufus) e nota su PXE/iPXE come
  alternativa futura.
- [`docs/collaudo-funzionale.md`](docs/collaudo-funzionale.md) — elenco dei
  test case, automatici (CI) e manuali (richiedono hardware GPU reale e/o
  un account Vast.ai reale), con stato aggiornato per fase.
- [`docs/setup.md`](docs/setup.md) — guida operativa passo-passo dal
  BIOS/UEFI al check finale, requisiti per i diversi setup, tabella delle
  informazioni richieste durante l'installazione.

## Fase 2 — partizionamento disco (sistema + Datastore Grastorp)

- `config/autoinstall-defaults.json` — default centralizzati (versione
  Ubuntu, size partizione di sistema, topologia dischi, parametri
  Datastore): unica fonte di verità, letta da `build-iso.sh` a build-time;
  i flag CLI, quando passati, hanno sempre precedenza.
- `iso/storage-single-disk.yaml`, `iso/storage-dual-disk.yaml` — schema di
  partizionamento ad azioni esplicite (curtin/Subiquity `storage.config`):
  EFI + root ext4 (size configurabile) + partizione dati XFS per il
  Datastore. Topologia scelta a build-time con `--disks 1|2`:

  ```sh
  scripts/build-iso.sh -k ~/.ssh/id_ed25519.pub --disks 2 --system-size 120G
  ```

- Il Datastore viene montato via `late-commands` a convenzione
  ESXi-style: mountpoint reale `/grastorp/volumes/<UUID>` (UUID generata
  da `mkfs.xfs`, non prevedibile a design-time) con symlink leggibile
  fisso `/grastorp/volumes/datastore`.
- `scripts/boot-test-qemu.sh` supporta ora `--disks 1|2` (dischi virtuali
  multipli) e verifica anche il mount del Datastore, non solo il login
  SSH.
- `scripts/validate-autoinstall.py` valida anche la struttura di
  `iso/storage-*-disk.yaml` (azioni con riferimenti `device`/`volume`
  coerenti, fstype, `swap.size: 0`).
- Boot **solo UEFI** (es. Hyper-V Gen2, e la gran parte dell'hardware
  server moderno) — decisione 2026-08-19: entrambe le topologie impostano
  `grub_device: true` sulla partizione ESP; senza, Subiquity rifiuta
  l'intera installazione con "autoinstall config did not create needed
  bootloader partition" (mai emerso nei primi test, tutti su boot BIOS
  legacy). Il legacy BIOS non è supportato: avere `grub_device: true`
  anche sul disco (necessario per BIOS) faceva sì che curtin tentasse
  `grub-install` pure sulla ESP FAT32 in un boot BIOS, fallendo sempre
  ("File system 'fat' doesn't support embedding") — vedi
  [`logbook-fase2.md`](logbook-fase2.md). `scripts/boot-test-qemu.sh`
  richiede quindi firmware OVMF (pacchetto `ovmf`), niente fallback su
  BIOS legacy.
- Validato su hardware reale (HP Z8 G4, VM Hyper-V Gen2): installazione
  a 2 dischi completa senza errori (partizionamento, grub, Datastore
  montato via late-commands); il rientro SSH dopo il reboot non è ancora
  confermato in modo affidabile nell'ambiente di test — vedi
  [`logbook-fase2.md`](logbook-fase2.md) per lo stato aggiornato.
- Dettagli di design e ricerca (schema `match` di Subiquity, scelta
  XFS/mountpoint) in [`logbook-fase2.md`](logbook-fase2.md).

## Fase 3 — preparazione storage: Docker sul Datastore

- `postinstall/setup.sh` — primo script post-install idempotente
  (systemd oneshot al primo boot, `postinstall/
  kickstart-berlin-postinstall.service`): prepara `/etc/docker/
  daemon.json` con `data-root` dentro il Datastore
  (`/grastorp/volumes/datastore/docker`) prima ancora che Docker sia
  installato (Fase 5). Cresce con le fasi successive (4-9, 12-14) come
  nuove funzioni nello stesso file, non un file per fase.
- **Nessuna estensione LVM**: la guida host-setup ufficiale di Vast.ai
  non la prevede (partizioni dirette, come il nostro `storage.config` di
  Fase 2) — il riferimento LVM nel testo originale dell'issue #3 viene
  dallo script community citato come fonte secondaria, non dalla guida
  ufficiale seguita qui. Dettaglio della decisione in
  [`logbook-fase3.md`](logbook-fase3.md).
- **Compatibilità Vast.ai ↔ ESX-style**: `/var/lib/docker` diventa un
  symlink verso il Datastore (Vast.ai monta lì la propria partizione
  dati direttamente; noi restiamo sulla convenzione ESX-style di Fase
  2) — qualunque tooling che si aspetti il path standard continua a
  funzionare. Gestisce anche la migrazione di dati Docker già esistenti
  fuori ordine, per idempotenza.
- `scripts/boot-test-qemu.sh` verifica, dopo il login SSH, che il
  servizio post-install completi e che `/var/lib/docker`/`daemon.json`
  risultino coerenti col Datastore.

## Fase 4 — driver NVIDIA + NVIDIA Container Toolkit

- `postinstall/setup.sh` — nuova `phase4_nvidia_driver()`: rileva la
  presenza di una GPU NVIDIA (PCI vendor `0x10de`), salta la fase
  pulitamente se assente (nodo non-GPU). Se presente, installa il driver
  via `ubuntu-drivers autoinstall` (nessuna versione pinnata — vedi
  sotto), blocca gli aggiornamenti automatici del driver (`apt-mark
  hold`, previene mismatch NVML segnalato dalla guida ufficiale), gestisce
  il riavvio necessario per caricare il modulo kernel in modo idempotente
  (un solo riavvio automatico, mai un loop), poi installa il pacchetto
  NVIDIA Container Toolkit dal repository ufficiale.
- **Nessuna versione driver pinnata**: la guida host-setup ufficiale di
  Vast.ai non la richiede ("we don't require a specific version") — stesso
  disallineamento già trovato per l'LVM di Fase 3 tra il testo originale
  dell'issue e la guida ufficiale. Dettaglio della decisione in
  [`logbook-fase4.md`](logbook-fase4.md).
- **Configurazione del runtime Docker non qui**: `nvidia-ctk runtime
  configure --runtime=docker` richiede Docker già installato (Fase 5, non
  Fase 4) — andrà nella futura `phase5_docker()`.
- **Limite noto**: nessuna GPU disponibile per la validazione end-to-end
  in questa fase di sviluppo (Z8 non disponibile fino al 23/08, VM Azure
  usata per Fase 2/3 senza GPU) — verificato solo il percorso "nessuna
  GPU rilevata" e la sintassi; il Container Toolkit non è stato testabile
  nemmeno per i soli comandi di rete (repository `nvidia.github.io`
  bloccato dalla policy del sandbox di sviluppo, stesso tipo di
  restrizione già vista per `docs.vast.ai` in Fase 1). Vedi
  [`logbook-fase4.md`](logbook-fase4.md) per lo stato aggiornato.

## Fase 5 — Docker + runtime NVIDIA

- `postinstall/setup.sh` — nuova `phase5_docker()`: installa Docker
  (script di convenienza `get.docker.com`, idempotente), poi configura il
  runtime NVIDIA (`nvidia-ctk runtime configure --runtime=docker`) solo
  se il Container Toolkit di Fase 4 è presente (host con GPU) — su un
  host non-GPU questo passaggio viene saltato pulitamente.
- **Nessun disallineamento con la guida ufficiale da risolvere** qui (a
  differenza di Fase 3/4): la guida Vast.ai non descrive comandi
  espliciti per questo passaggio (nascosto nel proprio installer
  proprietario), quindi si segue la pratica standard Docker.
- **Verificato su rete diretta** (VM Azure, dove `get.docker.com` e
  `nvidia.github.io` non sono bloccati come nel sandbox di sviluppo):
  installazione Docker reale riuscita, e confermato che
  `nvidia-ctk runtime configure` fa un merge pulito in `daemon.json`
  senza perdere il `data-root` già scritto da Fase 3 — unico punto di
  interazione tra fasi rimasto da confermare, ora chiuso. Resta sospesa
  solo la verifica `docker run --gpus all` su GPU reale (Z8, dal 23/08).
  Vedi [`logbook-fase5.md`](logbook-fase5.md).

## Fase 6 — rete

- `postinstall/setup.sh` — nuova `phase6_network()`: apre il range di
  porte TCP+UDP richiesto (guida ufficiale Vast.ai, "Port Requirements":
  almeno 3 porte per GPU) su `ufw`, ma solo se `ufw` è già installato E
  già attivo — non lo installa né lo abilita, non tocca la postura
  firewall esistente dell'host. Range configurabile via
  `config/autoinstall-defaults.json`/`--port-range` di `build-iso.sh`.
- **Scope deliberatamente limitato**: DHCP è già il default Ubuntu
  Server, l'hostname univoco è già gestito in Fase 3. Il meccanismo
  vast.ai-specifico di config del proprio daemon
  (`/var/lib/vastai_kaalia/host_port_range`) non ha un equivalente qui —
  se il vero daemon Vast.ai viene installato (Fase 7), quel file va
  scritto a mano dall'operatore con lo stesso range configurato qui;
  l'override IP non ha un requisito Grastorp concreto ad oggi; il test
  di velocità appartiene a Fase 11, non qui. Dettaglio in
  [`logbook-fase6.md`](logbook-fase6.md).

## Fase 7 — daemon host Vast.ai reale (validazione as-is)

- Nuovo script standalone `postinstall/install-vastai-host.sh`,
  **deliberatamente escluso** dalla sequenza automatica di
  `postinstall/setup.sh` — va lanciato a mano dall'operatore
  (`sudo ./install-vastai-host.sh --command-file <path>`), mai al primo
  boot: il comando ufficiale d'installazione del daemon Vast.ai
  (`cloud.vast.ai/host/setup`) è specifico dell'account e valido solo
  un'ora dalla generazione, non incorporabile nell'ISO né sincronizzabile
  con un boot automatico.
- **Cambio di direzione** (deciso con l'utente): si valida prima il nodo
  come host Vast.ai reale e completo, per confermare che l'intero stack
  costruito finora (Datastore ESX-style, Docker, driver NVIDIA, rete) sia
  davvero compatibile end-to-end — l'evoluzione verso il backend/agent
  Grastorp resta il passo successivo, non sostituisce più questa fase.
  Il layer ESX-style di Fase 2/3 (symlink `/var/lib/docker`) è stato
  pensato fin dall'inizio per restare compatibile con questo scenario,
  nessuna modifica retroattiva necessaria.
- Il file col comando (contiene l'identità dell'account) non viene mai
  passato come argomento diretto (shell history) e viene distrutto
  (`shred -u`) subito dopo l'uso; il comando stesso non finisce mai nei
  log. Dettaglio in [`logbook-fase7.md`](logbook-fase7.md).
- **Limite noto**: non testabile con un comando reale in questa sessione
  (richiede un account host Vast.ai loggato) — verificati solo i
  percorsi di errore e la meccanica di distruzione del file col comando.

## Fase 8 — raccolta informazioni hardware

*(Fase 7, installazione backend/agent Grastorp, saltata per ora — su
richiesta esplicita, non ancora implementata.)*

- `postinstall/setup.sh` — nuova `phase8_hardware_info()`: raccoglie
  `dmidecode` (system/baseboard/memory/processor), `lscpu`, `lspci`,
  `lsblk`, info di rete e GPU (se presente) in uno snapshot JSON grezzo
  (`/opt/kickstart-berlin/hardware-info.json`). Ogni fonte è isolata (uno
  strumento mancante o fallito produce un errore solo in quel campo, non
  fa fallire l'intera raccolta) — verificato in sandbox con `lspci`/`ip`/
  `nvidia-smi` assenti: nessun crash, JSON comunque valido.
- **"Riusato as-is"** dalla guida Vast.ai, con due adattamenti non
  ambigui: i permessi sudo dedicati per `dmidecode` non servono (l'admin
  ha già NOPASSWD completo dalla Fase 1); l'output è uno snapshot grezzo,
  non lo schema "machine info" specifico di Grastorp (grastorp#14 non
  ancora esaminata, fuori scope di questo repo) — un futuro backend potrà
  trasformarlo. Dettaglio in [`logbook-fase8.md`](logbook-fase8.md).

## Fase 10 — CLI vastai

- `postinstall/setup.sh` — nuova `phase10_vastai_cli()`, parte della
  sequenza automatica (a differenza di Fase 7): installa la CLI
  ufficiale `vastai` ([`vast-ai/vast-cli`](https://github.com/vast-ai/vast-cli),
  MIT) via `curl -fsSL https://vast.ai/install.sh | bash`. Idempotente
  (`command -v vastai` prima di reinstallare).
- **Perché può essere automatica e Fase 7 no**: l'installer della CLI
  non contiene alcun segreto d'account (a differenza del comando
  daemon di `cloud.vast.ai/host/setup`, valido un'ora) — nessun vincolo
  di tempistica con il primo boot.
- L'autenticazione (`vastai set api-key <key>`) resta comunque a mano
  dell'operatore, dopo il boot — nessuna API key mai hardcoded o
  committata nel repo, stessa disciplina di Fase 7/chiave SSH.
- **Limite noto, non verificabile in questa sessione**: il README
  ufficiale del CLI dichiara solo che l'installer mette `vastai` sotto
  `$HOME/.local/share/vastai`, senza specificare se aggiunge anche un
  symlink su una directory di PATH di sistema (nessun accesso di rete a
  `vast.ai`/`docs.vast.ai` disponibile durante questa sessione, dominio
  bloccato dalla policy di rete). `phase10_vastai_cli()` gestisce
  comunque il caso "non trovato su PATH dopo l'installer" cercando
  l'eseguibile sotto la home e collegandolo in `/usr/local/bin` — non
  testabile end-to-end senza un host reale con accesso a `vast.ai`.
  Dettaglio in [`logbook-fase10.md`](logbook-fase10.md).

## Fase 11 — vastai self-test

- Nuovo script standalone `postinstall/vastai-self-test.sh`,
  **deliberatamente escluso** dalla sequenza automatica (stesso motivo
  di Fase 7): richiede un `machine_id` reale, che esiste solo dopo che
  il daemon di Fase 7 ha listato con successo la macchina.
- Esegue il comando ufficiale `vastai self-test machine <machine_id>`
  (guida ufficiale "How to Self-Test"): verifica driver/CUDA, banda di
  rete, porte aperte, banda PCIe, VRAM, RAM/CPU e affidabilità sotto
  carico simulato — comando reale della CLI, non una reimplementazione.
- Uso: `./vastai-self-test.sh --machine-id <ID> [-- --ignore-requirements ...]`.
  Verifica prima che `vastai` sia installato (Fase 10) e autenticato
  (`vastai show user`), con errori chiari se non lo è. Gli argomenti
  dopo `--` passano invariati a `vastai self-test machine` (es.
  `--ignore-requirements`, `--test-image`, `--raw`).
- **Nota dalla guida ufficiale, riportata nei commenti dello script**:
  anche in modalità `--ignore-requirements` servono almeno 3 porte
  dirette aperte (Fase 6) — sotto quella soglia il test fallisce
  comunque; se il test segnala "not found or not rentable", ritirare e
  rilistare la macchina.
- **Verificato in sandbox** (nessuna dipendenza di rete esterna, `vastai`
  stubbato): parsing argomenti (`--machine-id` mancante o senza valore,
  opzione sconosciuta, `--help`), CLI `vastai` assente, autenticazione
  fallita, self-test fallito, passthrough dei flag extra dopo `--`.
- **Non verificabile in sandbox** (per costruzione): il vero comando
  richiede una macchina già listata su un account Vast.ai reale — da
  testare quando Fase 7 avrà confermato un listing reale (stesso
  blocco già annotato in `logbook-fase7.md`). Dettaglio in
  [`logbook-fase11.md`](logbook-fase11.md).

## Console status su tty1 (issue #27)

*(Non una delle 14 fasi mappate da Vast.ai — Vast.ai non ha un
equivalente: aggiunta originale, ispirata alla DCUI di VMware ESXi.)*

- `postinstall/console-status.sh` + `postinstall/kickstart-berlin-console-status.service`,
  installati e abilitati da `console_status_setup()` in
  `postinstall/setup.sh` (automatica, nessun segreto coinvolto — stesso
  criterio di Fase 10). Rimpiazza il prompt di login su tty1 (comunque
  inutilizzabile: nessuna password valida per design) con una schermata
  di sola lettura, refresh ogni 30s: hostname, versione Ubuntu/kernel,
  IP delle interfacce reali (esclusi `lo`/`docker0`/bridge Docker),
  stato Datastore (montato/spazio libero), driver/GPU NVIDIA, comando
  SSH pronto da copiare.
- **Nessun accesso locale in più**: `StandardInput=null` nella unit
  systemd, nessun input gestito dallo script. La shell classica resta
  disponibile sui terminali secondari (Alt+F2 … Alt+F6, non toccati).
- Verificato end-to-end su hardware reale (Z8): dump del framebuffer
  della console (`/dev/vcs1`/`/dev/vcsu1`) usato per confermare il
  contenuto renderizzato senza bisogno di una foto dello schermo fisico.

## Riferimenti

- [`docs/project-plan-review-2026-08-25.md`](docs/project-plan-review-2026-08-25.md) —
  revisione del piano a fasi dopo il primo collaudo su hardware fisico
  reale (Z8): stato verificato per fase, PR aperte non ancora mergiate,
  debito tecnico senza fix in corso, raccomandazioni prioritizzate.
- [Grastorp](https://github.com/danielesalpietro/grastorp) — repo di
  destinazione finale, di cui questo è il prerequisito d'installazione.
- [grastorp#8](https://github.com/danielesalpietro/grastorp/issues/8),
  [grastorp#11](https://github.com/danielesalpietro/grastorp/issues/11) —
  networking Linux-nativo e rilevamento NIC, prerequisiti condivisi.
- [grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14) —
  node profiling/benchmark hardware (fasi 8 e 11 di questa tabella).
- [grastorp#15](https://github.com/danielesalpietro/grastorp/issues/15) —
  integrazione RunPod/Vast.ai come target di deploy remoto (fasi 10 e 13 di
  questa tabella, fuori scope per l'installazione del nodo locale).
- Fonti Vast.ai: `docs.vast.ai/host/hosting-overview`,
  `docs.vast.ai/cli/hello-world`, `docs.vast.ai/host/how-to-self-test`;
  [`Soumya001/vastai-host-setup`](https://github.com/Soumya001/vastai-host-setup),
  [`AG-Sec4/VastAI-GPU-Host-Guide`](https://github.com/AG-Sec4/VastAI-GPU-Host-Guide)
  (guide community che replicano il flusso ufficiale);
  [`vast-ai/vast-cli`](https://github.com/vast-ai/vast-cli) — sorgente
  ufficiale MIT della CLI installata in Fase 10 e usata dal self-test di
  Fase 11.
