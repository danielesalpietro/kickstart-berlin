# Logbook — Release (trasversale alle fasi)

Diario delle versioni taggate/pubblicate su GitHub Releases — non legato
a una singola fase, cresce a ogni nuova release. Le note di rilascio
vere e proprie vivono su GitHub (Releases); questo file traccia *come* e
*perché* si è arrivati a taggare in quel momento, per chi deve decidere
la prossima release senza dover ricostruire il contesto da zero.

## v0.1.0-beta.1 — 2026-08-26

**Prima release pubblica del progetto.** Tag creato dall'utente via UI
GitHub (Draft a new release), target `develop`. Title e note di
rilascio redatte in sessione, poi rifinite e pubblicate come
pre-release (checkbox "Set as a pre-release" attiva, "Set as the latest
release" disattiva — corretto per una beta).

### Sequenza che ha portato al tag

1. Prima [Project Plan Review](docs/project-plan-review-2026-08-25.md)
   (2026-08-25): analisi incrociata di 14 fasi, issue e PR aperte —
   scopre che 6 PR erano già pronte/mergeable ma non riflesse nei
   documenti di stato, e che l'issue #41 (containerd) non aveva ancora
   un fix di codice dedicato.
2. Merge delle 6 PR segnalate (#32, #38, #39, #40, #42, #43) — un solo
   conflitto reale (#38 vs #32, stessa sezione di
   `docs/collaudo-funzionale.md`), risolto a mano unendo i contenuti.
   Checkpoint di governance su PR #39/issue #33 chiuso con conferma
   esplicita dell'utente sul perimetro implementato (commento su
   issue #33).
3. Fix strutturale del gap `containerd` (issue #41, PR #46) — vedi
   `logbook-fase7.md` per il dettaglio tecnico. Deciso con l'utente di
   includerlo nella beta prima di pubblicare, non lasciarlo per dopo.
4. Tag `v0.1.0-beta.1` creato dall'utente; title e note di rilascio
   redatte sulla base dello stato `develop` a quel punto (`f9820eb`),
   verificate fresche (nessun nuovo merge nel frattempo) subito prima
   della pubblicazione.

### Cosa NON è incluso in questa beta (per scelta o per limite)

- Fase 9 (manutenzione Docker), Fase 12 (port forwarding), Fase 14
  (report finale) — mai iniziate.
- Fix selezione disco PMem (PR #30) e fix `containerd` (PR #46):
  mergiati ma **non ancora confermati con un boot reale da zero** —
  nessuna GPU disponibile per riverificarli in questa sessione.
- Self-test Fase 11: bloccato per design da Vast.ai stesso
  (anti-self-rent), non risolvibile da questo repo — vedi
  `logbook-fase11.md`.

### Convenzione per le prossime release

Prima di taggare una nuova versione: rileggere questo file per non
ripetere la stessa analisi pre-release da zero, verificare che
`docs/collaudo-funzionale.md` sia aggiornato, e registrare qui la
sequenza che ha portato al tag (non solo il changelog delle modifiche,
che resta in `CHANGELOG.md`) — cosa era pronto, cosa si è deciso di
includere/escludere e perché.
