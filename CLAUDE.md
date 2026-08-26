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
| `logbook_first_boot.md` | Diario **trasversale alle fasi** (non `logbook-faseN.md`) del primo collaudo end-to-end su hardware fisico reale (HP Z8 G4 + RTX 3090, 2026-08-23): bug trovati e corretti in `postinstall/setup.sh` dopo che le fasi erano già "In corso"/confermate solo in sandbox o su VM. Consultalo per capire *perché* certe righe di `setup.sh` hanno commenti che citano un collaudo reale specifico. Log grezzi (`lsblk`/`lscpu`/`lspci`/`nvidia-smi`) in [`first-boot-z8/`](first-boot-z8/). |
| `logbook-project-plan-review.md` | Diario **trasversale alle fasi** delle Project Plan Review (analisi periodiche cross-cutting su issue/PR/documenti, non legate a una singola fase). Consultalo prima di produrne una nuova, per non ripetere lo stesso incrocio di dati già fatto. |
| `docs/project-plan-review-YYYY-MM-DD.md` (+ `.html`/`.docx`, copie derivate) | Snapshot dello stato del progetto a una data precisa: stato verificato delle fasi, PR aperte non ancora mergiate, debito tecnico senza fix in corso. Invecchia rapidamente (issue/PR cambiano stato) — usalo per il ragionamento che documenta, non come fonte di verità sullo stato *attuale* (quella resta `README.md`/`docs/collaudo-funzionale.md`). Copie `.html`/`.docx` tenute manualmente in sync con il `.md`, nessun automatismo le collega (stessa disciplina di `docs/setup.md`/`docs/setup.docx`). |
| `CHANGELOG.md` | Registro sintetico delle modifiche rilevanti a livello di progetto, non un sostituto dei `logbook-faseN.md`. Non esisteva prima del 2026-08-25: le voci partono da lì, non è un riepilogo retroattivo. |
| `config/autoinstall-defaults.json` | Unica fonte di verità per i default di build (versione Ubuntu, topologia dischi, parametri Datastore, range porte) — i flag CLI di `build-iso.sh` hanno sempre precedenza quando passati. |
| `postinstall/setup.sh` | Sequenza automatica post-install (systemd oneshot al primo boot): `main()` chiama in ordine le `phaseN_...()` già implementate. Cresce per fase, **un file solo**, non uno script per fase. |
| `postinstall/install-vastai-host.sh` | Script standalone Fase 7 — **mai** in `main()`, va lanciato a mano dall'operatore. |
| `postinstall/vastai-self-test.sh` | Script standalone Fase 11 — **mai** in `main()`, richiede `machine_id` reale da Fase 7. |
| `docs/setup.md` (+ `docs/setup.docx`, copia derivata) | Guida operativa passo-passo dal BIOS/UEFI al check finale per un operatore umano, con requisiti e tabella delle informazioni richieste — non ripete le motivazioni di design (quelle restano nei `logbook-faseN.md`). **Rigenera `setup.docx` da `setup.md`** (script docx-js, non nel repo) se cambi il sorgente Markdown: sono tenuti manualmente in sync, nessun automatismo li collega. |
| `scripts/build-iso.sh` | Build dell'ISO: inietta `iso/user-data`, monta `postinstall/` nello staging ISO (`POSTINSTALL_STAGE`) — **ogni nuovo script standalone in `postinstall/` va aggiunto qui esplicitamente con `cp`**, non è copiato automaticamente. |
| `.github/workflows/build-iso.yml` | Build ISO on-demand via GitHub Actions (tab Actions → "Run workflow"): stessa chiave SSH incollata a mano nel form (mai salvata), stesso `install-vastai-host.sh` mai incluso — alternativa al build locale con `scripts/build-iso.sh`, non lo sostituisce. |
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

9. **Prima di continuare un branch feature esistente (incluso il tuo
   stesso branch di una sessione precedente), fai `git fetch` e confronta
   con `origin/develop`.** Altre sessioni possono aver mergiato lavoro nel
   frattempo — successo concretamente il 2026-08-23: mentre il branch
   `claude/vastai-fase7-integration-9eh1fw` restava fermo al commit del
   merge della propria PR (#23), un'altra sessione ha fatto il primo
   collaudo reale su hardware fisico (Z8), trovato 3 bug in
   `postinstall/setup.sh`, e mergiato i fix in `develop` (PR #28) — tutto
   invisibile finché qualcuno non l'ha fatto notare. Se il tuo branch ha
   commit non ancora mergiati, `git rebase origin/develop` (mai
   scartarli) prima di aggiungere altro lavoro o aprire una nuova PR.

10. **Principio di priorità (2026-08-24, con l'utente): in caso di
    conflitto tra requisiti/limitazioni di Vast.ai e le nostre scelte
    architetturali, vince Vast.ai — il resto (Grastorp-oriented) si
    costruisce attorno, senza creare attrito.** "Berlin" (questo nodo)
    va usato sia come host Vast.ai sia per altri scopi: quando
    l'installer/la guida ufficiale Vast.ai si aspetta qualcosa che la
    nostra architettura non offre nella forma attesa, **il nostro codice
    si adatta per rendersi "ospitale"**, non il contrario. Precedente
    concreto: Bug 1/2 del collaudo Fase 7 su Z8 (PR #30,
    `logbook-fase7.md`) — entrambi causati dalla nostra pre-
    configurazione (`/var/lib/docker` come symlink ESX-style, `daemon.json`
    già scritto da `phase3`/`phase4` prima che l'installer Vast.ai
    giri), non da un difetto dell'installer che si manifesterebbe su un
    host "stock". Il fix corretto **non è** abbandonare l'architettura
    ESX-style (resta il prerequisito per Grastorp), ma il pattern
    preflight/postflight già in `install-vastai-host.sh` (presenta
    temporaneamente una directory vera invece del symlink, poi ripristina
    e migra i dati) — quel pattern è il riferimento per casi analoghi
    futuri, non un caso a sé. Se una fase futura Grastorp-specifica
    confliggerebbe con un'assunzione di Vast.ai, il criterio è lo
    stesso: adattare il nostro lato, non aspettarsi che l'installer
    Vast.ai gestisca la nostra architettura.

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
- **Hardware GPU reale**: HP Z8 G4 + RTX 3090, disponibile e già usato per
  un primo collaudo reale il 2026-08-23 (vedi `logbook_first_boot.md`) —
  Fasi 1-6, 8, 10 confermate su hardware fisico, Fase 7/11 (daemon
  Vast.ai reale, self-test) ancora da eseguire sullo stesso nodo. **Ha
  moduli Intel Optane PMem installati**: la selezione disco `match: {}`
  non li esclude, quindi l'esito del partizionamento non è deterministico
  su questo nodo specifico — vedi `docs/collaudo-funzionale.md`, sezione
  "Problemi noti". Verificare comunque lo stato aggiornato in
  `docs/collaudo-funzionale.md` prima di assumere che un test sia ancora
  "Da fare": questa nota può invecchiare.
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
