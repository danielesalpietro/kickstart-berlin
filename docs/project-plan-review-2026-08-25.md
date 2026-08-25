# Project Plan Review — 25 agosto 2026

Revisione del piano a fasi ([issue #15](https://github.com/danielesalpietro/kickstart-berlin/issues/15))
alla luce di `README.md`, `docs/collaudo-funzionale.md`, i 12 `logbook-*.md`
e lo stato reale di issue/PR su GitHub. Non sostituisce nessuno di quei
documenti — li mette in relazione per rispondere a una domanda che nessuno
di essi copre da solo: **cosa blocca davvero il progresso in questo
momento?**

## Executive summary

Il piano a 14 fasi è concettualmente solido e per la prima volta è stato
validato end-to-end su hardware fisico reale (HP Z8 G4 + RTX 3090,
23-24/08/2026). Quel collaudo ha prodotto **9 nuove issue** (#33-#37,
#40-#41 più #40 già numerata) e, soprattutto, **6 pull request già scritte,
riviste e mergeable** che il `README.md` e `docs/collaudo-funzionale.md`
non menzionano ancora. Il collo di bottiglia oggi **non è la scrittura di
nuovo codice**: è la revisione umana e il merge di lavoro già pronto, più
una decisione di governance non ancora presa su una PR che ha bypassato un
checkpoint esplicito. La Fase 11 (self-test) va inoltre riclassificata: è
bloccata per design da Vast.ai stesso, non da un difetto di questo repo.

## 1. Stato delle 14 fasi (verificato, non solo dal README)

| # | Fase | Stato README | Verifica di questa review |
|---|---|---|---|
| 1 | OS/autoinstall | Fatto | Confermato, chiuso (#1) |
| 2 | Partizionamento disco | In corso | Confermato su hardware reale, ma con **debito aperto**: `match: {}` originale sostituito da un allowlist di path che esclude PMem (mergiato, PR #30) — **non ancora testato con un boot reale post-fix**. PR #40 (aperta) inverte l'ordine di priorità SATA/NVMe, altro cambiamento non ancora in `develop` |
| 3 | Storage/Datastore | In corso | Confermato indirettamente, ma **PR #41 rivela che il fix è incompleto**: `daemon.json` punta al Datastore, `containerd`'s `config.toml` no — la maggior parte dei dati reali (33G su 33.2G nel collaudo Z8) non segue il Datastore. Nessuna PR aperta risolve ancora questo in `setup.sh` (PR #42 è solo documentazione del fix live) |
| 4 | Driver NVIDIA | In corso | Confermato su GPU reale (RTX 3090, driver 595.84). Bug "pacchetti fantasma" in `apt-mark hold` **già corretto in `develop`** (verificato leggendo `postinstall/setup.sh:175`) |
| 5 | Docker | In corso | Confermato Docker+runtime NVIDIA, ma **bug reale**: `admin` non è mai aggiunto al gruppo `docker` in `develop` (verificato: nessun `usermod -aG docker` nel file). Fix pronto in **PR #38, non mergiata** |
| 6 | Rete | In corso | Confermato (regole ufw corrette, installato-ma-inattivo per design) |
| 7 | Daemon Vast.ai reale | In corso | Confermato: daemon installato, macchina listata (ID 148447). Bug storage containerd emerso qui (vedi Fase 3) |
| 8 | Info hardware | In corso | Confermato, `nvidia_gpu` popolato con dati reali |
| 9 | Manutenzione Docker | Da fare | Nessun lavoro iniziato, nessuna PR |
| 10 | CLI vastai | Fatto | Confermato, `vastai 1.5.5` installato e funzionante. 2 bug (`$HOME`, permessi `/root`) già corretti in `develop` |
| 11 | Self-test | Fatto (script) | **Da riclassificare** — vedi sezione 4. Lo script è pronto e corretto, ma il test funzionale reale è bloccato per design lato Vast.ai (anti-self-rent), non completabile da questo repo |
| 12 | Port forwarding | Da fare | Nessun lavoro iniziato |
| 13 | Listing marketplace | Fuori scope | Invariato, corretto lasciarlo così finché grastorp#15 non lo riapre |
| 14 | Report finale | Da fare | Nessun lavoro iniziato |

**Osservazione strutturale**: le fasi 9, 12, 14 sono ferme da prima del
collaudo reale (18/08) e non hanno ricevuto alcun lavoro nemmeno durante la
sessione Z8 del 23-24/08, che si è concentrata su 5-8/10/11 più le issue
impreviste. Non è un problema — riflette l'ordine di lavoro suggerito
dall'issue #15 stessa — ma vale la pena renderlo esplicito: sono le uniche
tre fasi rimaste "vergini" del piano originale.

## 2. Il vero collo di bottiglia: 6 PR pronte, non ancora mergiate

`docs/collaudo-funzionale.md` e `README.md` descrivono lo stato di
`develop`, ma **6 pull request aperte, tutte in `mergeable_state: clean`
contro l'attuale `develop` (a0bf4f1)**, contengono lavoro già rivisto che
quei documenti non riflettono ancora:

| PR | Chiude | Contenuto | Rischio di merge |
|---|---|---|---|
| [#38](https://github.com/danielesalpietro/kickstart-berlin/pull/38) | #34 | `usermod -aG docker admin` in `phase5_docker()` | Basso — 1 riga di fix idempotente, review statica già fatta |
| [#40](https://github.com/danielesalpietro/kickstart-berlin/pull/40) | — | Inverte priorità disco di sistema: SATA/SAS prima di NVMe (NVMe riservato al Datastore) | Basso — decisione già presa con l'utente, non tocca `--disk-serial` espliciti |
| [#42](https://github.com/danielesalpietro/kickstart-berlin/pull/42) | (documenta #41) | Solo `logbook-fase7.md` — nessun fix di codice, registra il gap containerd | Nullo — solo `.md` |
| [#43](https://github.com/danielesalpietro/kickstart-berlin/pull/43) | #35, #37 | Solo `logbook_first_boot.md` — documenta install live di `ndctl`/`ipmctl`/`pip3`, nessuna automazione in `setup.sh` | Nullo — solo `.md` |
| [#32](https://github.com/danielesalpietro/kickstart-berlin/pull/32) | — | `CLAUDE.md` (nuova direttiva: in conflitto Vast.ai vince), riconciliazione `README.md`/`docs/collaudo-funzionale.md`/`logbook-fase11.md` con PR #30 | Nullo — solo `.md`, ma **propedeutico**: senza questa PR, i documenti di progetto restano disallineati dallo stato reale confermato il 23-24/08 |
| [#39](https://github.com/danielesalpietro/kickstart-berlin/pull/39) | (issue #33) | `postinstall/node-manage.py`: menu curses interattivo via SSH che **modifica** stato reale (IP via `netplan try`, restart daemon Vast.ai, azioni CLI `vastai`) | **Vedi sezione 4 — non è un rischio tecnico, è un rischio di processo** |

**Raccomandazione d'ordine di merge**: #32 e #43 prima (solo doc, zero
rischio, riallineano i documenti di progetto alla realtà), poi #38 e #40
(fix comportamentali isolati, un file ciascuno), poi #42 (doc). #39 va
trattato separatamente — vedi sotto — perché non è un fix, è una nuova
capability con un checkpoint esplicito ancora aperto.

## 3. Debito tecnico reale non ancora coperto da nessuna PR

Due problemi confermati sul collaudo Z8 **non hanno ancora un fix in
nessun branch**, a differenza di quanto la tabella PR sopra potrebbe far
pensare:

- **Issue #41 (containerd root path)**: PR #42 la *documenta* ma non la
  *risolve* — `/etc/containerd/config.toml` continua a non essere gestito
  da `phase3_docker_storage()` né dal postflight di
  `install-vastai-host.sh`. Finché resta così, l'intera promessa
  dell'architettura ESX-style di Fase 2/3 ("Docker vive sul Datastore") è
  **falsa per la stragrande maggioranza dei dati reali** (33G su 33.2G nel
  collaudo Z8 erano fuori dal Datastore). Questo è, in termini di impatto,
  il bug più serio scoperto nell'intero collaudo — non ha ancora una PR
  dedicata al fix di codice.
- **Issue #36 (CUDA toolkit nativo)**: nessuna decisione presa, nessuna PR.
  Impatto oggi basso (i workload restano containerizzati), ma resta un
  item aperto senza owner.

## 4. Punto di governance da chiudere prima del merge: PR #39 / issue #33

L'issue #33, scritta dall'utente stesso, pone esplicitamente un vincolo
**prima** di iniziare l'implementazione:

> Da fare prima di iniziare l'implementazione: discussione esplicita con
> l'utente su quali azioni (se ce ne sono) il menu deve poter eseguire, ...

Le tre checkbox dell'issue risultano ancora **non spuntate**. Ciò
nonostante, PR #39 esiste già: 1683 righe aggiunte, un menu curses
completo che può riconfigurare la rete (`netplan try`), riavviare il
daemon Vast.ai e invocare comandi `vastai` in scrittura (unlist/self-test)
— esattamente il tipo di "azioni più ampie" che l'issue #33 elencava come
da valutare con cautela, in tensione diretta con la direttiva #1 di
`CLAUDE.md` ("nessun modo di login o azione locale, solo chiave SSH").

Questo non è necessariamente un problema — il design della PR è
ragionevole (`netplan try` con rollback automatico è la scelta giusta) — ma
**il checkpoint che l'issue stessa richiedeva non risulta documentato come
avvenuto**. Prima di mergiare #39, va chiarito esplicitamente con l'utente:

- Il "ok implicito" a procedere è già stato dato fuori da GitHub (es. in
  sessione diretta con l'utente, come suggerisce il fatto che la issue
  stessa nasce da una richiesta dell'utente)? Se sì, andrebbe comunque
  registrato come commento sull'issue #33 per chiudere le checkbox —
  coerente con la disciplina "logbook prima della PR" già in uso altrove.
- Il perimetro di azioni implementate (rete, daemon Vast.ai, CLI vastai)
  corrisponde a quanto l'utente si aspettava, o eccede quanto discusso?

**Raccomandazione**: non trattare #39 come le altre 5 PR "pronte al merge
meccanico". Serve una conferma esplicita dell'utente sul perimetro prima
del merge, anche se il codice stesso è già stato rivisto staticamente.

## 5. Fase 11 va riclassificata, non "completata"

`docs/collaudo-funzionale.md` e la tabella fasi la segnano "Fatto"/
"Confermato" con qualifiche già caute. Ma `logbook-fase11.md` (righe
213-286) documenta una conclusione più netta, che vale la pena portare
esplicitamente nei documenti di stato: il self-test reale fallisce con
**403 sistematico** perché Vast.ai blocca per design il noleggio di una
macchina da parte del proprio stesso host (`host_id` dell'offerta coincide
con l'account che tenta il rent) — confermato incrociando i log interni
del daemon (`self_test.log`), non un'ipotesi. **Non è risolvibile da
questo repo.**

Raccomandazione: aggiornare lo stato da "Da fare — blocca su Fase 7" a
qualcosa come "**Bloccato esternamente (design Vast.ai anti-self-rent)** —
riprovabile solo dopo un affitto reale della macchina, o dopo supporto
diretto Vast.ai". La distinzione conta: "Da fare" implica che c'è ancora
lavoro di questo repo da fare, mentre qui non c'è — è la stessa
distinzione "Verificato in sandbox" vs "Non verificabile per costruzione"
che CLAUDE.md (direttiva #4) già impone per altri casi, estesa a un terzo
stato: "non risolvibile qui".

## 6. Gap di collaudo automatico (CI)

`scripts/boot-test-qemu.sh` verifica login SSH e mount del Datastore, ma
**non ha GPU** (non può eseguire Fase 4/5 realmente) e **non verifica
`/etc/containerd/config.toml`** — motivo per cui il bug #41 è stato
scoperto solo su hardware fisico reale, non in CI, nonostante fosse
strutturalmente presente fin dalla Fase 3. Allo stesso modo, l'assenza di
`admin` dal gruppo `docker` (#34) non ha un check CI dedicato: `boot-test-
qemu.sh` verifica che il servizio postinstall completi, non che `docker`
sia utilizzabile senza `sudo` dall'utente `admin`.

**Raccomandazione**: due asserzioni aggiuntive, a basso costo, in
`scripts/boot-test-qemu.sh`:
1. `grep root /etc/containerd/config.toml` punta sotto il Datastore, non
   sotto `/var/lib/docker` di default.
2. `groups admin` include `docker`.

Nessuna delle due richiede GPU reale — sono entrambe verificabili nell'ISO
di test QEMU esistente, e avrebbero intercettato #34 e (parzialmente) #41
prima del collaudo su hardware fisico.

## 7. Raccomandazioni prioritizzate

**P0 — questa settimana, nessuna nuova decisione richiesta**
1. Mergiare PR #32 (riallinea `CLAUDE.md`/`README.md`/`docs/collaudo-
   funzionale.md`/`logbook-fase11.md` allo stato reale confermato) e #43
   (documentazione tooling) — zero rischio, sblocca la leggibilità degli
   altri documenti.
2. Mergiare PR #38 (#34, gruppo docker) e #40 (priorità disco) — fix
   isolati, review statica già fatta, nessuna decisione aperta.

**P1 — decisione breve, poi implementazione**
3. Aprire una issue/PR dedicata al fix vero di #41 (containerd root path)
   — PR #42 la documenta ma non la risolve. La issue #41 propone già la
   soluzione più semplice (stessa directory di `data-root`, sotto
   `${DATASTORE}/docker/containerd`) — sembra pronta per essere
   implementata senza bisogno di ulteriori decisioni.
4. Aggiungere le due asserzioni CI descritte in sezione 6.
5. Aggiornare lo stato di Fase 11 in `docs/collaudo-funzionale.md` come
   descritto in sezione 5 (probabilmente già coperto da PR #32 — verificare
   il diff prima di duplicare).

**P2 — richiede decisione esplicita dell'utente prima di procedere**
6. PR #39 / issue #33: chiudere il checkpoint di governance (sezione 4)
   prima del merge.
7. Issue #36 (CUDA toolkit): decidere se serve un caso d'uso nativo o resta
   fuori scope.
8. Issue #35 (PMem region1 fsdax/devdax): chiarire il caso d'uso EMH-2
   esatto prima di automatizzare — rischio di irreversibilità già segnalato
   nell'issue stessa.

**P3 — prima della produzione, non urgente ora**
9. Rimuovere gli strumenti dev-only dal nodo Z8 (`gh`, Claude Code CLI,
   GitHub Actions self-hosted runner) — rischio di sicurezza già
   esplicitamente notato in `logbook_first_boot.md` (runner self-hosted su
   repo pubblico, sulla stessa macchina affittata a terzi via Vast.ai).

**Non urgente, nessun lavoro in corso**
10. Fasi 9, 12, 14 restano ferme — nessuna azione richiesta ora, ma è la
    prossima area di lavoro "vergine" una volta esaurito il backlog delle 6
    PR aperte e delle issue impreviste.

## 8. Domande aperte per l'utente

- Il perimetro di azioni di PR #39 (rete, daemon, CLI vastai in scrittura)
  è quello concordato, o va ristretto/ampliato prima del merge?
- Issue #36: esiste già un caso d'uso reale non containerizzato per CUDA
  toolkit nativo, o resta "nice to have"?
- Issue #35: qual è il caso d'uso EMH-2 esatto per region1 (fsdax vs
  devdax)? Determina se/come automatizzare la riconfigurazione.
- Timeline per il prossimo reinstall da zero su Z8 (dischi Windows
  scollegati fisicamente, come deciso in `logbook_first_boot.md`) — è il
  momento in cui si può finalmente confermare end-to-end il fix PMem di PR
  #30 con un boot reale, mai testato dopo il merge.

## 9. Prossimi passi consigliati

1. Merge P0 (PR #32, #43, #38, #40) — sblocca la leggibilità dello stato
   di progetto per qualunque sessione futura.
2. Issue/PR dedicata al fix reale di #41 (containerd), la lacuna di
   impatto più alto ancora senza codice.
3. Rispondere alle domande in sezione 8 prima di toccare #33/#39, #35, #36.
4. Aggiungere le due asserzioni CI di sezione 6, per evitare che lo stesso
   tipo di bug (#34, #41) richieda di nuovo un collaudo su hardware fisico
   per essere scoperto.
