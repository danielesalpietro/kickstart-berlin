# Changelog

Registro delle modifiche rilevanti a livello di progetto (non sostituisce
i `logbook-faseN.md`, che restano la fonte di dettaglio per le decisioni
di design e i bug trovati in sandbox/hardware reale — vedi `CLAUDE.md`).
Non esisteva prima del 2026-08-25: le voci partono da qui, non è un
riepilogo retroattivo dell'intera storia del repo.

## 2026-08-25

- Aggiunta la prima **Project Plan Review** del progetto
  (`docs/project-plan-review-2026-08-25.md`, con copie derivate
  `.html`/`.docx`): analisi incrociata delle 14 fasi del piano, delle 6
  issue emerse dal collaudo reale su Z8 (#33-#37, #41) e delle 6 pull
  request aperte non ancora mergiate (#32, #38, #39, #40, #42, #43).
  Individua il fix `containerd` (issue #41) come debito tecnico senza PR
  dedicata, segnala il checkpoint di governance non chiuso su PR #39/
  issue #33, e propone di riclassificare la Fase 11 come "bloccata
  esternamente" (design anti-self-rent Vast.ai) invece che "da fare".
  Vedi `logbook-project-plan-review.md` per il diario della sessione.

## 2026-08-26

- Mergiate tutte le 6 PR segnalate dalla Project Plan Review come pronte
  (#32, #38, #39, #40, #42, #43) — riallineamento documentale (`CLAUDE.md`
  direttiva 10, `README.md`, `docs/collaudo-funzionale.md`), fix gruppo
  `docker` (#34), priorità disco SATA/NVMe, menu di gestione del nodo via
  SSH (issue #33, checkpoint di governance chiuso con conferma esplicita
  dell'utente).
- **Fix strutturale del gap `containerd`** (issue #41, PR #46): il path
  di storage di `containerd` ora segue il Datastore come `data-root` di
  Docker — prima di questo fix la maggior parte dei dati Docker reali
  (i layer immagine) finiva fuori dal Datastore nonostante `daemon.json`
  fosse corretto. Nuovo regression test in CI. Vedi `logbook-fase7.md`.
- **Prima release pubblica: [`v0.1.0-beta.1`](https://github.com/danielesalpietro/kickstart-berlin/releases/tag/v0.1.0-beta.1)**
  (pre-release, tag su `develop`) — vedi `logbook-releases.md`.
