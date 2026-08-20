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
| 3 | Build ISO reale + boot QEMU/KVM completo, login SSH, mount Datastore, topologie disco singolo/doppio | `scripts/boot-test-qemu.sh`, job `build-and-boot-test` in CI (push a `develop`/`main`, o `workflow_dispatch` con `run_integration: true`) |

Non coperto qui: qualunque cosa dipenda da una GPU NVIDIA fisica, da un
account Vast.ai reale, o da hardware bare-metal — vedi sotto.

## Test manuali

Richiedono hardware reale (HP Z8 G4, disponibile dal 23/08) e/o un
account Vast.ai reale con daemon host installato. Da eseguire
dall'operatore quando l'ambiente è disponibile; stato aggiornato via PR.

| Fase | Test | Come | Prerequisito | Stato |
|---|---|---|---|---|
| 1 | Scrittura ISO su chiavetta USB reale e boot da USB | Procedura in [`docs/usb-boot.md`](usb-boot.md) | ISO buildata | Da fare |
| 3 | Preparazione storage su bare-metal reale | Boot autoinstall su Z8 | Z8 disponibile | Da fare |
| 4 | Driver NVIDIA + riavvio + `nvidia-smi` + NVIDIA Container Toolkit funzionante | Boot autoinstall su Z8 (GPU reale) | Z8 disponibile | Da fare |
| 5 | `docker run --rm --gpus all ...` vede davvero la GPU | Sullo stesso host di Fase 4 | GPU NVIDIA reale attiva | Da fare |
| 7 | Compatibilità dell'intero stack col daemon host Vast.ai (Kaalia) | `./postinstall/install-vastai-host.sh` con comando reale da `cloud.vast.ai/host/setup` (valido 1h, generato dall'utente) | Host con rete diretta, stack Fasi 1-6 completato | Da fare |
| 8 | Campo `nvidia_gpu` popolato con dati reali | `phase8_hardware_info()` su host con GPU reale | GPU NVIDIA reale attiva | Da fare |
| 10 | Installer CLI reale (`vast.ai/install.sh`): `vastai` su PATH, `vastai set api-key` + `vastai show user` | `phase10_vastai_cli()` su host con accesso di rete a `vast.ai` | Rete diretta verso `vast.ai` | Da fare |
| 11 | Self-test ufficiale Vast.ai su una macchina realmente listata | `./postinstall/vastai-self-test.sh --machine-id <ID>` | Fase 7 completata con listing riuscito (`machine_id` reale) + Fase 10 completata (CLI autenticata) | Da fare |

Già confermato su hardware reale (non più da ripetere, vedi il logbook
della fase per il dettaglio): Fase 2 (partizionamento, HP Z8 G4 + VM
Hyper-V Gen2), Fase 6 (regole `ufw` scritte correttamente).

## Convenzione

Quando un test manuale viene eseguito: aggiornare lo "Stato" qui
(`Da fare` → `Confermato`, con data e riferimento host), registrare il
dettaglio (comando usato, output, eventuali problemi) nel
`logbook-faseN.md` corrispondente, e solo allora aprire/aggiornare la PR
per quella fase — stessa disciplina già in uso nelle fasi 1-8.
