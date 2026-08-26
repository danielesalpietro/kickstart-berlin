# Collaudo funzionale

Elenco unico dei test case previsti per kickstart-berlin, per distinguere
cosa è già coperto in automatico da cosa richiede ancora l'intervento
manuale di un operatore su hardware/account reali. Il dettaglio di
progettazione e le sessioni di verifica in sandbox restano nei singoli
`logbook-faseN.md`; questo file traccia solo lo stato del collaudo.

## Test automatici

Girano senza intervento umano, ripetibili ad ogni push/PR — non serve
hardware GPU né un account Vast.ai reale.

| # | Cosa verifica | Dove |
|---|---|---|
| 1 | Sintassi/struttura di `iso/user-data` (autoinstall) | `scripts/validate-autoinstall.py`, job `validate-autoinstall` in CI, ogni push/PR |
| 2 | Sintassi shell di tutti gli script (`scripts/*.sh`, `postinstall/*.sh`) | `shellcheck`, stesso job |
| 3 | Build ISO reale + boot QEMU/KVM completo, login SSH, mount Datastore, topologie disco singolo/doppio, `admin` nel gruppo `docker` (regression test fix #34), `containerd` root sul Datastore (regression test fix #41) | `scripts/boot-test-qemu.sh`, job `build-and-boot-test` in CI (push a `develop`/`main`, o `workflow_dispatch` con `run_integration: true`) |

Non coperto qui: qualunque cosa dipenda da una GPU NVIDIA fisica, da un
account Vast.ai reale, o da hardware bare-metal — vedi sotto.

## Test manuali

Richiedono hardware reale (HP Z8 G4, disponibile dal 23/08) e/o un
account Vast.ai reale con daemon host installato. Da eseguire
dall'operatore quando l'ambiente è disponibile; stato aggiornato via PR.

| Fase | Test | Come | Prerequisito | Stato |
|---|---|---|---|---|
| 1 | Scrittura ISO su chiavetta USB reale e boot da USB | Procedura in [`docs/usb-boot.md`](usb-boot.md) | ISO buildata | Da fare (il boot fisico del 2026-08-23 è avvenuto, ma il mezzo di scrittura USB non è esplicitamente confermato in `logbook_first_boot.md` — non affermarlo come testato) |
| 3 | Preparazione storage su bare-metal reale | Boot autoinstall su Z8 | Z8 disponibile | **Confermato (indiretto)** — 2026-08-23, HP Z8 G4: nessun errore riportato (Fase 4 ha potuto partire, quindi Fase 3 è completata), ma il Datastore è finito sui moduli Optane PMem invece che sul disco SATA `sda` — vedi "Problemi noti" sotto e `logbook_first_boot.md` (Problema 1) |
| 4 | Driver NVIDIA + riavvio + `nvidia-smi` + NVIDIA Container Toolkit funzionante | Boot autoinstall su Z8 (GPU reale) | Z8 disponibile | **Confermato** — 2026-08-23, HP Z8 G4 + RTX 3090, driver 595.84/CUDA 13.2. Bug trovato e corretto: `apt-mark hold` falliva su pacchetti "fantasma" restituiti da `dpkg-query -W` non filtrati per stato installato — vedi `logbook_first_boot.md` (Problema 2) |
| 5 | `docker run --rm --gpus all ...` vede davvero la GPU | Sullo stesso host di Fase 4 | GPU NVIDIA reale attiva | **Confermato** — 2026-08-23, GPU visibile nel container. Nota: il tag `nvidia/cuda:12.4.1-base-ubuntu24.04` citato in `docs/setup.md` risulta ritirato da Docker Hub, verificato invece con `12.6.0-base-ubuntu24.04` |
| 7 | Compatibilità dell'intero stack col daemon host Vast.ai (Kaalia) | `./postinstall/install-vastai-host.sh` con comando reale da `cloud.vast.ai/host/setup` (valido 1h, generato dall'utente) | Host con rete diretta, stack Fasi 1-6 completato | **Confermato** — 2026-08-23/24, HP Z8 G4: macchina `berlin-3eie` listata con successo, machine ID `148447`. 4 bug trovati nell'installer ufficiale Vast.ai stesso (non nel nostro wrapper), **causati dalla nostra architettura ESX-style pre-esistente** (`/var/lib/docker` symlink, `daemon.json` già scritto) più uno di contesa lock `dpkg` — vedi `logbook-fase7.md` e `CLAUDE.md` direttiva 10. Preflight/postflight automatizzati in `install-vastai-host.sh` (PR #30) ma **non ancora verificati end-to-end come blocco unico** — solo i singoli fix manuali confermati uno per uno |
| 8 | Campo `nvidia_gpu` popolato con dati reali | `phase8_hardware_info()` su host con GPU reale | GPU NVIDIA reale attiva | **Confermato** — 2026-08-23, `nvidia_gpu` = "NVIDIA GeForce RTX 3090, 24576 MiB, 595.84" |
| 10 | Installer CLI reale (`vast.ai/install.sh`): `vastai` su PATH, `vastai set api-key` + `vastai show user` | `phase10_vastai_cli()` su host con accesso di rete a `vast.ai` | Rete diretta verso `vast.ai` | **Confermato** — 2026-08-23, `vastai 1.5.5` installato e **autenticato** (`vastai set api-key`/`vastai show user` verificati). Due bug trovati e corretti: `$HOME` non definita nell'ambiente del servizio systemd (installer falliva), e permessi `/root` (700) bloccavano l'esecuzione da utente `admin` senza sudo — vedi `logbook_first_boot.md` (Problemi 3 e 4) |
| 11 | Self-test ufficiale Vast.ai su una macchina realmente listata | `./postinstall/vastai-self-test.sh --machine-id <ID>` | Fase 7 completata con listing riuscito (`machine_id` reale) + Fase 10 completata (CLI autenticata) | **Eseguito, arrivato ai controlli reali** — 2026-08-23/24, `machine_id` 148447: fallisce su 3 requisiti oggettivi di questa rete (reliability, download, upload — non uno stack/software issue, vedi sotto), e con `--ignore-requirements` si sblocca fino a un **403 persistente identificato come blocco anti-self-rent per design di Vast.ai** (l'host_id coincide con l'account che tenta il noleggio) — non risolvibile da questo repo, serve supporto Vast.ai. Vedi `logbook-fase11.md` per l'indagine completa. Nessun errore di configurazione/permessi lato nostro stack |

Già confermato su hardware reale (non più da ripetere, vedi il logbook
della fase per il dettaglio): Fase 2 (partizionamento, HP Z8 G4 + VM
Hyper-V Gen2), Fase 6 (regole `ufw` scritte correttamente — installato
ma inattivo sul nodo Z8 del 23/08, comportamento voluto: non tocca la
postura firewall esistente).

## Problemi noti (non bloccanti)

- **Selezione disco con moduli Optane PMem — corretto, non ancora
  testato con un boot reale.** `iso/storage-single-disk.yaml`/
  `storage-dual-disk.yaml` usavano `match: {}` (curtin: "un disco
  qualsiasi"), che su hardware con Optane installato può selezionare un
  modulo PMem invece del disco SATA/NVMe atteso. **Fix mergiato**
  (`develop`, PR #30): allowlist esplicito per path
  (`nvme*n1`/`sd*`/`vd*`, mai `/dev/pmem*`), più
  `--disk-serial`/`--datastore-disk-serial` in `build-iso.sh` per
  pinnare un disco per numero seriale sui nodi con più dischi reali
  candidabili insieme (es. altri dischi con OS preesistente ancora
  collegati — scoperto sulla Z8, vedi `logbook_first_boot.md`).
  Validato solo staticamente (`scripts/validate-autoinstall.py`) — **da
  confermare al prossimo boot reale da zero**, vedi
  `docs/collaudo-funzionale.md`, riga Fase 3 sopra (ancora "Confermato
  (indiretto)" sul vecchio comportamento `match: {}`, da riverificare
  con questo fix).
- **Priorità disco di sistema (SATA/SAS prima di NVMe) non coperta da
  CI**: il default corretto il 2026-08-24 (PR #40) non ha un test
  automatico — `scripts/boot-test-qemu.sh` crea solo dischi `virtio`,
  non emula bus NVMe reali in QEMU. Verificato solo staticamente
  (lettura del match spec generato). Richiederebbe estendere il boot
  test con dischi di tipo diverso (`-device nvme` di QEMU) per
  diventare un test automatico reale — non fatto, scope più grande di
  una singola verifica.
- **`containerd` root path — CORRETTO nel repo (2026-08-25), non ancora
  verificato con un boot reale (issue #41)**: `phase3_docker_storage()`/
  `install-vastai-host.sh` correggevano solo `data-root` in
  `/etc/docker/daemon.json`, mai `root` in `/etc/containerd/config.toml`
  — scoperto sul collaudo reale Z8 (2026-08-24): la maggior parte dei
  dati Docker (i layer immagine) finiva fuori dal Datastore nonostante
  `daemon.json` fosse corretto. **Fix**: nuova `configure_containerd_storage()`
  in `postinstall/setup.sh`, chiamata da `phase5_docker()` dopo
  l'installazione di Docker/containerd (non prima: il pacchetto
  `containerd.io` scrive `config.toml` a install-time, editarlo prima
  rischierebbe un conflitto dpkg sul conffile) — stessa directory di
  `data-root`, sottodirectory dedicata. Stessa logica replicata nel
  postflight di `install-vastai-host.sh` (l'installer Vast.ai reinstalla
  `docker-ce`/`containerd.io`, che rigenera `config.toml` col default di
  sistema). Editing testuale mirato (nessun parser TOML completo per la
  scrittura): sostituisce solo la riga top-level `root = ...`, verificato
  in sandbox che non tocchi la chiave `root` annidata sotto
  `[plugins."io.containerd.grpc.v1.cri"]` (chiave diversa, stesso nome).
  Nuovo regression test in `scripts/boot-test-qemu.sh` (CI). **Non ancora
  verificato con un boot reale su hardware GPU** (nessuna GPU disponibile
  in questa sessione) — vedi issue #41 e `logbook-fase7.md`.
- **Self-test Fase 11 bloccato su un limite esterno a questo repo**: il
  403 persistente (blocco anti-self-rent Vast.ai) non è risolvibile
  lato software — vedi riga Fase 11 sopra e `logbook-fase11.md`.

## Convenzione

Quando un test manuale viene eseguito: aggiornare lo "Stato" qui
(`Da fare` → `Confermato`, con data e riferimento host), registrare il
dettaglio (comando usato, output, eventuali problemi) nel
`logbook-faseN.md` corrispondente, e solo allora aprire/aggiornare la PR
per quella fase — stessa disciplina già in uso nelle fasi 1-8.
