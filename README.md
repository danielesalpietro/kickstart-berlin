# kickstart-berlin

Automazione dell'installazione **from-scratch** di un nodo GPU: dalla ISO di
boot fino a un host pronto (OS, driver NVIDIA, Docker, rete, benchmark
hardware). Base derivata dal flusso di setup host di **Vast.ai**, propedeutica
all'integrazione in [Grastorp](https://github.com/danielesalpietro/grastorp).

> Stato: **early stage**. Fase 1 (ISO autoinstall) completa e validata
> end-to-end (CI + hardware reale). Fase 2 (partizionamento disco +
> Datastore) implementata e validata su hardware reale per lo scenario a
> 2 dischi (install completa senza errori, incluso il mount del
> Datastore); resta da confermare in modo affidabile il rientro SSH dopo
> il reboot nell'ambiente di test Hyper-V (probabile problema
> d'infrastruttura di test, non della logica d'installazione — vedi
> [`logbook-fase2.md`](logbook-fase2.md)). Fase 3 (storage Docker sul
> Datastore) implementata, in attesa di boot test reale — vedi
> [`logbook-fase3.md`](logbook-fase3.md). Le altre fasi sono ancora da
> fare.

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
| 6 | Rete | DHCP via Netplan, DNS pubblici, hostname | Identico, propedeutico al rilevamento NIC di Grastorp ([grastorp#11](https://github.com/danielesalpietro/grastorp/issues/11)) | Da fare |
| 7 | Installazione daemon del provider | Wizard ufficiale Vast.ai (Kaalia daemon) + API key utente | **Sostituito**: qui va installato il backend/agent Grastorp stesso (Docker Compose), non un daemon di terzi | Da fare |
| 8 | Raccolta info hardware | `dmidecode` + permessi sudo dedicati, usato per popolare il "machine info" del marketplace | **Riusato as-is**: stesso meccanismo alla base del node profiling di Grastorp ([grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14)) | Da fare |
| 9 | Manutenzione | Timer systemd per pulizia oraria container/immagini inutilizzati | Riusabile as-is | Da fare |
| 10 | CLI del provider | Install CLI Vast.ai, config con API key | **Sostituito/opzionale**: solo se si integrano RunPod/Vast.ai come target di deploy remoto ([grastorp#15](https://github.com/danielesalpietro/grastorp/issues/15)), non è un prerequisito del nodo locale | Fuori scope iniziale |
| 11 | Self-test/benchmark | Speedtest di rete + verifica GPU/RAM/rete, esito inviato al backend Vast.ai | **Sostituito**: qui è l'assessment one-shot di Grastorp (stile Windows Experience Index, vedi [grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14)), non inviato a nessun backend esterno | Da fare |
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

- `scripts/boot-test-qemu.sh` — boota l'ISO generata in QEMU headless su un
  disco virtuale throwaway e verifica che l'installazione completi senza
  prompt e che l'host risultante sia raggiungibile via SSH con la chiave
  iniettata (usato dal job di integrazione in CI).
- `scripts/validate-autoinstall.py` — validazione sintattica/strutturale di
  `iso/user-data` (job "unit" in CI, ad ogni PR).
- [`docs/usb-boot.md`](docs/usb-boot.md) — istruzioni per scrivere l'ISO su
  chiavetta USB (`dd`, balenaEtcher/Rufus) e nota su PXE/iPXE come
  alternativa futura.

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
- **Limite noto**: `get.docker.com` è bloccato dalla policy di rete del
  sandbox di sviluppo (stessa restrizione già vista per `docs.vast.ai` e
  `nvidia.github.io`) — l'installazione Docker vera non è stata testata
  qui, così come l'interazione tra `nvidia-ctk runtime configure` e il
  `data-root` già scritto da Fase 3 in `daemon.json`. Vedi
  [`logbook-fase5.md`](logbook-fase5.md).

## Riferimenti

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
- Fonti Vast.ai: `docs.vast.ai/host/hosting-overview`;
  [`Soumya001/vastai-host-setup`](https://github.com/Soumya001/vastai-host-setup),
  [`AG-Sec4/VastAI-GPU-Host-Guide`](https://github.com/AG-Sec4/VastAI-GPU-Host-Guide)
  (guide community che replicano il flusso ufficiale).
