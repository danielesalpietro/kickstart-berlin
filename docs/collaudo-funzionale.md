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
| 3 | Build ISO reale + boot QEMU/KVM completo, login SSH, mount Datastore, topologie disco singolo/doppio, `admin` nel gruppo `docker` (regression test fix #34) | `scripts/boot-test-qemu.sh`, job `build-and-boot-test` in CI (push a `develop`/`main`, o `workflow_dispatch` con `run_integration: true`) |

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
| 7 | Compatibilità dell'intero stack col daemon host Vast.ai (Kaalia) | `./postinstall/install-vastai-host.sh` con comando reale da `cloud.vast.ai/host/setup` (valido 1h, generato dall'utente) | Host con rete diretta, stack Fasi 1-6 completato | Da fare — non ancora raggiunto nella sessione del 2026-08-23 (fermata a Fase 10), vedi "Prossimi passi" in `logbook_first_boot.md` |
| 8 | Campo `nvidia_gpu` popolato con dati reali | `phase8_hardware_info()` su host con GPU reale | GPU NVIDIA reale attiva | **Confermato** — 2026-08-23, `nvidia_gpu` = "NVIDIA GeForce RTX 3090, 24576 MiB, 595.84" |
| 10 | Installer CLI reale (`vast.ai/install.sh`): `vastai` su PATH, `vastai set api-key` + `vastai show user` | `phase10_vastai_cli()` su host con accesso di rete a `vast.ai` | Rete diretta verso `vast.ai` | **Confermato** — 2026-08-23, `vastai 1.5.5` installato. Due bug trovati e corretti: `$HOME` non definita nell'ambiente del servizio systemd (installer falliva), e permessi `/root` (700) bloccavano l'esecuzione da utente `admin` senza sudo — vedi `logbook_first_boot.md` (Problemi 3 e 4). Autenticazione (`vastai set api-key`/`show user`) non ancora eseguita |
| 11 | Self-test ufficiale Vast.ai su una macchina realmente listata | `./postinstall/vastai-self-test.sh --machine-id <ID>` | Fase 7 completata con listing riuscito (`machine_id` reale) + Fase 10 completata (CLI autenticata) | Da fare — blocca su Fase 7 |

Già confermato su hardware reale (non più da ripetere, vedi il logbook
della fase per il dettaglio): Fase 2 (partizionamento, HP Z8 G4 + VM
Hyper-V Gen2), Fase 6 (regole `ufw` scritte correttamente — installato
ma inattivo sul nodo Z8 del 23/08, comportamento voluto: non tocca la
postura firewall esistente).

## Problemi noti (non bloccanti, in attesa di fix)

- **Selezione disco non deterministica con moduli Optane PMem —
  CORRETTO nel repo (2026-08-24)**: `iso/storage-single-disk.yaml`/
  `storage-dual-disk.yaml` usavano `match: {}` (curtin: "un disco
  qualsiasi"), senza esclusione dei device `/dev/pmem*`. Sostituito con
  un allowlist esplicito per path (mai `/dev/pmem*`) — vedi
  `logbook_first_boot.md` (Problema 1). **Non ancora verificato con un
  boot reale su hardware con PMem dopo il fix** (la Z8 attuale è
  ancora l'installazione pre-fix, root su PMem — reinstall pianificato
  ma non eseguito in questa sessione).
- **Priorità disco di sistema (SATA/SAS prima di NVMe) non coperta da
  CI**: il default corretto il 2026-08-24 (vedi PR #40) non ha un test
  automatico — `scripts/boot-test-qemu.sh` crea solo dischi `virtio`,
  non emula bus NVMe reali in QEMU. Verificato solo staticamente
  (lettura del match spec generato). Richiederebbe estendere il boot
  test con dischi di tipo diverso (`-device nvme` di QEMU) per
  diventare un test automatico reale — non fatto, scope più grande di
  una singola verifica.
- **`containerd` root path mai gestito dall'automazione (issue #41)**:
  `phase3_docker_storage()`/`install-vastai-host.sh` correggono solo
  `data-root` in `/etc/docker/daemon.json`, mai `root` in
  `/etc/containerd/config.toml` — scoperto sul collaudo reale Z8
  (2026-08-24): la maggior parte dei dati Docker (i layer immagine)
  finisce comunque fuori dal Datastore. Fix non ancora implementato nel
  repo, quindi nessun test automatico possibile finché non lo è — vedi
  issue #41 e `logbook-fase7.md`.

## Convenzione

Quando un test manuale viene eseguito: aggiornare lo "Stato" qui
(`Da fare` → `Confermato`, con data e riferimento host), registrare il
dettaglio (comando usato, output, eventuali problemi) nel
`logbook-faseN.md` corrispondente, e solo allora aprire/aggiornare la PR
per quella fase — stessa disciplina già in uso nelle fasi 1-8.
