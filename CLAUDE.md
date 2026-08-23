# CLAUDE.md — memoria di progetto per kickstart-berlin

Questo file esiste per un motivo preciso: ogni nuova sessione parte senza
memoria delle decisioni prese in quelle precedenti. Le direttive chiave di
questo repo sono state negoziate esplicitamente con l'utente, spesso in
esplicito **riordino** di una scelta precedente — non sono deducibili dal
solo codice. Leggi questo file per intero prima di toccare qualunque cosa.

## Cos'è questo repo, in una riga

Automazione **from-scratch** di un nodo GPU (ISO boot → host pronto),
derivata dal flusso host-setup ufficiale di **Vast.ai**, propedeutica
all'integrazione in [Grastorp](https://github.com/danielesalpietro/grastorp)
— non un sostituto di Grastorp, un prerequisito d'installazione.

## Checklist di orientamento a inizio sessione

1. Leggi il banner "Stato" in cima a `README.md` — fasi implementate vs da
   fare, e il vincolo hardware (Z8 G4) cambia nel tempo.
2. Leggi `docs/collaudo-funzionale.md` — stato aggiornato dei test
   automatici (CI) e manuali (hardware/account reali); non fidarti di un
   singolo logbook per lo stato complessivo.
3. Identifica la fase su cui stai per lavorare nella tabella "Le fasi del
   setup host" di `README.md`, poi apri **il `logbook-faseN.md`
   corrispondente per intero** — contiene le decisioni negoziate, i bug
   trovati in sandbox e cosa resta "non verificabile per costruzione". Non
   ripetere una ricerca/decisione già fatta lì.
4. Se il lavoro tocca GitHub issues, ricorda: **i numeri di fase
   corrispondono 1:1 ai numeri di issue** (`#1`…`#14`) nel repo
   `danielesalpietro/kickstart-berlin`.

## Mappa dei documenti

| File | Quando consultarlo |
|---|---|
| `README.md` | Prima cosa da leggere: tabella fasi↔issue↔stato, architettura prevista, sezione per fase con file coinvolti. Fonte di verità sullo **stato attuale**, va aggiornato ad ogni fase completata. |
| `docs/collaudo-funzionale.md` | Stato del collaudo: cosa è verificato in CI (automatico) vs cosa richiede ancora hardware/account reali (manuale, checklist per fase). Aggiornalo quando un test manuale viene eseguito. |
| `docs/usb-boot.md` | Procedura di scrittura ISO su USB e note PXE/iPXE — test manuale di Fase 1. |
| `logbook-fase1.md` … `logbook-fase8.md`, `logbook-fase10.md`, `logbook-fase11.md` | Diario per fase: decisioni negoziate con l'utente, bug trovati in sandbox e come sono stati corretti, cosa è "Verificato in sandbox" vs "Non verificabile per costruzione", prossimi passi. **Non esiste `logbook-fase9.md`/`fase12`/`fase13`/`fase14`: quelle fasi non sono ancora implementate.** |
| `config/autoinstall-defaults.json` | Unica fonte di verità per i default di build (versione Ubuntu, topologia dischi, parametri Datastore, range porte) — i flag CLI di `build-iso.sh` hanno sempre precedenza quando passati. |
| `postinstall/setup.sh` | Sequenza automatica post-install (systemd oneshot al primo boot): `main()` chiama in ordine le `phaseN_...()` già implementate. Cresce per fase, **un file solo**, non uno script per fase. |
| `postinstall/install-vastai-host.sh` | Script standalone Fase 7 — **mai** in `main()`, va lanciato a mano dall'operatore. |
| `postinstall/vastai-self-test.sh` | Script standalone Fase 11 — **mai** in `main()`, richiede `machine_id` reale da Fase 7. |
| `scripts/build-iso.sh` | Build dell'ISO: inietta `iso/user-data`, monta `postinstall/` nello staging ISO (`POSTINSTALL_STAGE`) — **ogni nuovo script standalone in `postinstall/` va aggiunto qui esplicitamente con `cp`**, non è copiato automaticamente. |
| `scripts/boot-test-qemu.sh` | Test di integrazione (CI): build ISO reale + boot QEMU/KVM, verifica login SSH e mount Datastore. |
| `scripts/validate-autoinstall.py` | Validazione sintattica/strutturale di `iso/user-data` e `iso/storage-*-disk.yaml` (job "unit" in CI). |
| `.github/workflows/ci.yml` | Definizione autorevole dei test automatici: job `validate-autoinstall` (ogni push/PR) e `build-and-boot-test` (push a `develop`/`main` o `workflow_dispatch`). |

## Direttive non negoziabili

Queste sono le decisioni che, se dimenticate, portano a rifare lavoro già
fatto o a reintrodurre problemi già risolti.

1. **Nessun segreto mai hardcoded o committato nel repo.** Chiave SSH
   pubblica: iniettata a build-time (`build-iso.sh -k`), mai nell'ISO
   template. Comando d'installazione daemon Vast.ai (Fase 7): identità
   account, valido 1 ora, passato via `--command-file`, **mai** come
   argomento diretto (shell history), distrutto con `shred -u` subito
   dopo l'uso. API key `vastai` (Fase 10): configurata a mano
   dall'operatore dopo il boot, mai automatizzata.

2. **Automatico in `setup.sh`/`main()` solo se non dipende da un segreto
   account-specifico né da uno stato che esiste solo dopo un passo
   manuale.** Criterio già applicato due volte: Fase 7 (daemon,
   comando che scade in un'ora) e Fase 11 (self-test, richiede
   `machine_id` reale da un listing riuscito) sono script standalone
   esclusi da `main()`. Fase 10 (CLI `vastai`) invece È automatica: il
   suo installer non contiene alcun segreto. Non spostare una fase
   dentro/fuori `main()` senza verificare quale caso si applica.

3. **Guida ufficiale Vast.ai (`docs.vast.ai`) prevale sempre sugli script
   community citati come fonte secondaria** (`Soumya001/vastai-host-setup`,
   `AG-Sec4/VastAI-GPU-Host-Guide`) quando i due divergono. Già successo
   due volte: LVM (Fase 3, la guida ufficiale non lo prevede) e driver
   NVIDIA pinnato (Fase 4, la guida ufficiale dice esplicitamente "we
   don't require a specific version"). Se un requisito sembra derivare
   dal testo originale delle issue ma non dalla guida ufficiale,
   **verifica la guida ufficiale prima di implementare**.

4. **Distingui sempre "Verificato in sandbox" da "Non verificabile per
   costruzione" (non un limite temporaneo).** Non affermare come
   confermato un comportamento mai eseguito realmente. Questo repo ha
   uno storico di bug trovati proprio testando in sandbox con stub
   (es. `vastai-self-test.sh`: `unbound variable` su `--machine-id`
   senza valore; `phase10_vastai_cli()`: fallback PATH basato su
   un'ipotesi rivelatasi sbagliata una volta letto il vero
   `install.sh`) — testa sempre i percorsi sintetici in sandbox anche
   quando il percorso reale non è raggiungibile.

5. **Idempotenza per ogni `phaseN_...()`** in `setup.sh`: deve poter
   essere rieseguita senza effetti collaterali (riavvii del servizio,
   riesecuzioni dopo un fallimento parziale). Pattern già in uso:
   `command -v` prima di installare, `mkdir -p`, controllo del contenuto
   di `daemon.json` prima di riscriverlo, marker file per il riavvio
   driver NVIDIA (un solo riavvio automatico, mai un loop).

6. **Ogni nuovo script standalone in `postinstall/` va aggiunto
   esplicitamente in `scripts/build-iso.sh`** (blocco `POSTINSTALL_STAGE`,
   `cp "${REPO_ROOT}/postinstall/<script>.sh" "${POSTINSTALL_STAGE}/"`) —
   non basta che esista nella directory, va copiato a mano nello staging
   dell'ISO come già fatto per `install-vastai-host.sh` e
   `vastai-self-test.sh`.

7. **`logbook-faseN.md` si aggiorna PRIMA di aprire/aggiornare una PR**
   per quella fase, non dopo — disciplina osservata in ogni fase finora.

8. **Cambio di direzione strategico Fase 7 (2026-08-20, con l'utente):**
   il README classificava Fase 7 come "Sostituito" dal backend/agent
   Grastorp. Decisione riordinata: si valida **prima** il nodo come host
   Vast.ai reale e completo (daemon, CLI, listing) per confermare che
   l'intero stack (Fasi 1-6, 8) sia compatibile end-to-end con
   l'ecosistema Vast.ai — **poi** si evolve verso Grastorp. Stesso
   riordino applicato a Fase 10 (CLI) e Fase 11 (self-test), prima
   "Sostituito/fuori scope". Non è un ripensamento dell'architettura
   ESX-style di Fase 2/3 (`/var/lib/docker` come symlink verso il
   Datastore): quel layer era già stato pensato per restare compatibile
   con Vast.ai as-is, nessuna modifica retroattiva necessaria. **Se una
   sessione futura vede "Sostituito"/"fuori scope" nel testo originale di
   un'issue, verificare prima lo stato reale in `README.md`: potrebbe
   essere stato riordinato.**

## Vincoli d'ambiente noti (da non riscoprire ogni volta)

- **Domini bloccati dalla policy di rete di questa sandbox di sviluppo**:
  `vast.ai` e tutti i suoi sottodomini (`docs.vast.ai`, `cloud.vast.ai`).
  `github.com`/`raw.githubusercontent.com` sono invece raggiungibili — per
  informazioni su Vast.ai, preferire la lettura diretta del codice
  sorgente di [`vast-ai/vast-cli`](https://github.com/vast-ai/vast-cli)
  (MIT, repo pubblico) invece di provare a fare fetch di `docs.vast.ai`.
  Se l'utente fornisce un PDF/file scaricato da `docs.vast.ai` o da
  `vast.ai`, è spesso l'unico modo di avere quell'informazione verificata
  in questa sessione — leggerlo per intero prima di supporre.
- **Hardware GPU reale**: HP Z8 G4, non disponibile fino al 23/08/2026 (a
  seconda della data della sessione, potrebbe essere già disponibile —
  verificare lo stato in `README.md`). Fino ad allora: VM Azure (rete
  diretta, nessuna GPU) usata per validare i percorsi di rete/installer
  che il sandbox di sviluppo blocca; percorsi GPU-reale restano
  "Da fare" in `docs/collaudo-funzionale.md`.
- **Branch di lavoro**: le sessioni Claude Code su questo repo sviluppano
  su branch dedicati per fase/argomento (es.
  `claude/vastai-fase7-integration-9eh1fw`) — controllare il branch
  corrente e le istruzioni di sessione prima di assumere `main`/`develop`.

## Struttura fasi ↔ file ↔ issue (stato al momento della scrittura)

| Fase | Stato | Script | Logbook | Automatica in `main()`? |
|---|---|---|---|---|
| 1-2 | Fatto/in corso | `iso/user-data`, `iso/storage-*.yaml` | fase1, fase2 | n/a (ISO/autoinstall, non postinstall) |
| 3 | In corso | `phase3_docker_storage()` | fase3 | Sì |
| 4 | In corso | `phase4_nvidia_driver()` | fase4 | Sì |
| 5 | In corso | `phase5_docker()` | fase5 | Sì |
| 6 | In corso | `phase6_network()` | fase6 | Sì |
| 7 | In corso | `install-vastai-host.sh` | fase7 | **No** (segreto account, 1h) |
| 8 | In corso | `phase8_hardware_info()` | fase8 | Sì |
| 9 | Da fare | — | — | — |
| 10 | In corso | `phase10_vastai_cli()` | fase10 | Sì |
| 11 | In corso | `vastai-self-test.sh` | fase11 | **No** (richiede `machine_id` reale) |
| 12-14 | Da fare | — | — | — |

Per lo stato aggiornato non fidarsi di questa tabella oltre la prima
lettura: verificare sempre `README.md` (può essere cambiato dopo la
scrittura di questo file).
