# Logbook — Project Plan Review (trasversale alle fasi)

Diario della prima **Project Plan Review** del progetto — non una fase
del piano a 14 fasi (issue #15), ma un'analisi cross-cutting richiesta
esplicitamente dall'utente per rispondere a una domanda che nessun
documento esistente copriva da solo: cosa blocca davvero il progresso in
questo momento? Branch di lavoro: `claude/project-plan-review-c6hya8`.

## 2026-08-25 — Analisi

Letti per intero: `README.md`, `docs/collaudo-funzionale.md`, tutti i 12
`logbook-*.md` esistenti, le 20 issue aperte e le 2 chiuse su GitHub, e —
punto che nessun documento di stato esistente copriva — **l'elenco delle
pull request aperte**. Scoperta chiave: 6 PR (#32, #38, #39, #40, #42,
#43) risultavano già aperte, riviste (`mergeable_state: clean` contro
`develop`) e mai menzionate né in `README.md` né in
`docs/collaudo-funzionale.md` — la maggior parte del "lavoro da fare"
percepibile dai soli documenti di stato era in realtà già stato fatto e
solo in attesa di merge.

Nel farlo, un controllo incrociato tra il testo dell'issue #34 ("Fix:
Aggiunto direttamente in `postinstall/setup.sh`...") e il contenuto reale
di `postinstall/setup.sh` su `develop` ha rivelato che quell'affermazione
era vera solo sul branch `claude/fase5-docker-group-fix` (PR #38, non
mergiata) — lo stesso pattern "fix live/fix su branch mai arrivato a
`develop`" già visto tre volte nel collaudo Z8 del 23-24/08 (vedi
`logbook_first_boot.md`, Problemi 2-4). Non un nuovo bug, ma una conferma
che la disciplina "verificare `develop`, non fidarsi del testo
dell'issue" (CLAUDE.md, direttiva #9) va applicata anche al singolo file,
non solo al branch nel suo complesso.

Risultato: `docs/project-plan-review-2026-08-25.md`, 9 sezioni (stato
verificato delle 14 fasi, le 6 PR pronte non mergiate, debito tecnico
senza PR dedicata, un punto di governance da chiudere su PR #39/issue
#33, riclassificazione della Fase 11 come bloccata esternamente, gap di
collaudo CI, raccomandazioni prioritizzate P0-P3, domande aperte per
l'utente, prossimi passi).

## 2026-08-25 — Archiviazione in formato HTML e DOCX

Su richiesta esplicita dell'utente, generate due copie derivate della
review — stessa convenzione già in uso per `docs/setup.md`/
`docs/setup.docx` (CLAUDE.md, mappa dei documenti: "tenuti manualmente in
sync, nessun automatismo li collega" — vale anche qui, `.md` resta la
fonte di verità):

- `docs/project-plan-review-2026-08-25.html` — pagina statica
  autocontenuta (CSS inline, nessuna dipendenza esterna), scritta a mano
  a partire dal Markdown.
- `docs/project-plan-review-2026-08-25.docx` — generato via script
  `docx` (npm), stesso strumento usato per `docs/setup.docx`.

**Limite noto**: la verifica visiva del `.docx` (render → PDF →
screenshot, procedura standard della skill `docx`) non è stata
possibile in questa sessione — `soffice --headless --convert-to pdf`
fallisce con "source file could not be loaded" **anche su un `.docx`
minimo di test** (un solo paragrafo "hello world"), quindi è un limite
dell'ambiente sandbox di questa sessione, non un difetto del file
generato. Verificato invece per via strutturale:
`unzip -l` conferma un archivio ZIP valido con tutte le parti OOXML
attese (`word/document.xml`, `styles.xml`, `numbering.xml`, ecc.), `file`
lo riconosce come "Microsoft Word 2007+", e la validazione XSD dello
script `scripts/office/validate.py` della skill `docx` (dopo aver
installato le dipendenze Python mancanti nell'ambiente, `defusedxml` e
`lxml`) **passa senza errori** su 146 paragrafi. Non equivale a un
controllo visivo reale (l'unico modo per escludere problemi di layout,
non di struttura) — da fare al primo apertura reale in Word/LibreOffice
su una macchina con GUI.

## 2026-08-25 — PR aperta e mergiata

PR aperta da `claude/project-plan-review-c6hya8` verso `develop`. Nota di
processo: l'account GitHub autenticato in questa sessione
(`danielesalpietro`) è lo stesso autore/owner del repo — GitHub non
consente l'auto-approvazione di una propria PR (`pull_request_review_write`
con `event: APPROVE` fallisce su una PR aperta dallo stesso account
autenticato). Procedura seguita: nessuna review formale registrata (per
il vincolo tecnico di cui sopra), merge diretto della PR autorizzato
esplicitamente dall'utente in questa richiesta.

## Da fare (non affrontato in questa sessione)

- Le raccomandazioni P0-P3 della review restano da eseguire (merge delle
  altre 5 PR, fix containerd issue #41, chiarimento del checkpoint di
  governance su PR #39/issue #33, ecc.) — questa sessione ha prodotto
  solo l'analisi e l'ha archiviata, non ha agito sul backlog che
  descrive.
