# Logbook — Fase 11: vastai self-test (issue #11)

Diario di design e test per la Fase 11. Prerequisito diretto:
[`logbook-fase10.md`](logbook-fase10.md) (CLI `vastai`) e
[`logbook-fase7.md`](logbook-fase7.md) (daemon host reale, unica fonte
di un `machine_id` valido).

## 2026-08-20 — Fonte: PDF ufficiale fornito dall'utente

L'utente ha fornito il PDF `docs.vast.ai/host/how-to-self-test`
direttamente (la pagina non era fetchabile da questa sessione: dominio
`docs.vast.ai` bloccato dalla policy di rete, vedi
`logbook-fase10.md`). Contenuto chiave della guida ufficiale:

- Il self-test verifica: driver/CUDA, velocità e stabilità di rete,
  porte aperte, banda PCIe, capacità/affidabilità VRAM, prestazioni
  RAM/CPU, e affidabilità generale sotto un carico di lavoro simulato
  reale.
- Prerequisiti espliciti: la macchina deve essere già listata e senza
  client attivi che la stanno affittando in quel momento.
- Comando: `vastai self-test machine <machine_id>`.
- Flag `--ignore-requirements`: bypassa alcuni controlli per poter
  comunque verificare noleggiabilità/pressure test, ma **anche in
  questa modalità servono almeno 3 porte dirette aperte**, altrimenti
  il test fallisce comunque; e il superamento in questa modalità non
  equivale a soddisfare i requisiti minimi di verifica.
- Troubleshooting "not found or not rentable": ritirare e rilistare la
  macchina; verificare che la pagina host/machines non abbia dati
  mancanti (banda upload/download, RAM, porte).

Confermato anche via lettura diretta del codice sorgente
(`vast-ai/vast-cli` su GitHub, raggiungibile a differenza di
`docs.vast.ai`): sottocomando reale in
`vastai/cli/commands/machines.py` + package `vastai/cli/self_test/`
(`runtime_diagnostics.py`, `machine_diagnostics.py`,
`support_bundle.py`), produce un tarball diagnostico redatto in caso
di fallimento (`vast_selftest_<id>_<timestamp>.tar.gz`).

## 2026-08-20 — Decisione: script standalone, non fase automatica

Stesso ragionamento di Fase 7 (`install-vastai-host.sh`): il self-test
richiede un `machine_id` reale, che esiste solo **dopo** che il daemon
di Fase 7 ha listato con successo la macchina — impossibile da avere a
disposizione al primo boot automatico. `postinstall/vastai-self-test.sh`
resta quindi fuori da `main()`, invocato a mano dall'operatore quando
pronto, con la stessa struttura (`usage`/`log`/`err`, `--help`) già
usata da `install-vastai-host.sh`.

A differenza del comando daemon di Fase 7, qui non c'è un segreto che
scade in un'ora da distruggere: `machine_id` e API key (quest'ultima
già persistita da Fase 10) non sono effimeri — lo script si limita a
verificarne la presenza (`command -v vastai`, `vastai show user`) prima
di procedere, con errori chiari se mancano.

## 2026-08-20 — Implementazione e bug trovato in sandbox

Prima versione di `vastai-self-test.sh`: parsing di `--machine-id` con
`shift 2` diretto, senza verificare che un secondo argomento fosse
presente. Testato in sandbox con `./vastai-self-test.sh --machine-id`
(nessun valore dopo il flag): **bug trovato** — `set -u` produce
`line 60: $2: unbound variable`, un errore bash grezzo invece del
messaggio chiaro `[vastai-self-test] ERRORE: ...` usato ovunque nel
resto dello script. Corretto aggiungendo `[[ $# -ge 2 ]] || err ...`
prima dello `shift 2`, stesso pattern ora presente in altri punti del
repo. Ritestato: messaggio chiaro, exit 1.

## 2026-08-20 — Verificato in sandbox

Nessuna dipendenza di rete esterna (CLI `vastai` stubbata con script
fittizi, mai il binario reale):

1. Nessun argomento → `usage` + errore chiaro, exit 1.
2. `--help` → `usage`, exit 0.
3. `--machine-id` senza valore → errore chiaro (bug corretto sopra),
   exit 1, non più `unbound variable`.
4. Opzione sconosciuta → errore chiaro, exit 1.
5. `vastai` non installato (comando assente da PATH) → errore chiaro
   che rimanda a Fase 10, exit 1.
6. `vastai` installato ma non autenticato (`vastai show user`
   fallisce) → errore chiaro che rimanda a `vastai set api-key`,
   exit 1.
7. `vastai` installato e autenticato, ma `vastai self-test machine`
   fallisce (stub con exit non-zero) → errore chiaro con riferimento al
   tarball diagnostico, exit 1.
8. Percorso "felice" con stub che accetta il comando: log di successo,
   exit 0; confermato che i flag extra dopo `--` (es.
   `--ignore-requirements --raw`) passano invariati a
   `vastai self-test machine`.

`bash -n` pulito. `scripts/build-iso.sh` aggiornato per copiare anche
questo script nello staging dell'ISO (stesso trattamento di
`install-vastai-host.sh`).

## Non verificabile in sandbox (per costruzione)

Il vero comando `vastai self-test machine <machine_id>` richiede una
macchina reale già listata su un account Vast.ai — non simulabile.
Resta bloccato dallo stesso prerequisito già annotato in
`logbook-fase7.md`: serve prima un comando reale di
`cloud.vast.ai/host/setup` che confermi un listing riuscito, da cui
ricavare un `machine_id` reale su cui lanciare questo script.

## 2026-08-20 — Registrato come test case di collaudo funzionale

Su richiesta dell'utente: il repo aveva solo test *automatici* tracciati
formalmente (CI: `validate-autoinstall`, `build-and-boot-test`) — i test
che richiedono hardware/account reali restavano sparsi come voci "Da
fare" nei singoli logbook, senza un elenco unico. Creato
[`docs/collaudo-funzionale.md`](docs/collaudo-funzionale.md): distingue
esplicitamente test automatici (CI) da test manuali (checklist per
operatore su hardware/account reali), consolidando le voci già aperte
nei logbook delle Fasi 1/3/4/5/7/8/10/11. `./vastai-self-test.sh
--machine-id <ID>` è la voce Fase 11 di quella checklist.

## 2026-08-23/24 — Self-test reale eseguito (Z8, machine_id 148447)

Primo self-test in assoluto con un `machine_id` reale, sbloccato dal
listing riuscito di Fase 7 (vedi `logbook-fase7.md`). Tre run
successivi, ciascuno ha avanzato la diagnosi di uno step:

1. **Primo run**: `Machine lookup failed with HTTP 403`,
   `Root state: api_permission_failed`. Causa apparente: la CLI
   `vastai` non aveva ancora l'API key configurata quando il wizard
   aveva provato il proprio self-test interno (`vast.py` legacy,
   `"Invalid user key"`) — la vera CLI moderna (`vastai 1.5.5`) è stata
   autenticata correttamente subito dopo (`vastai set api-key`,
   confermato con `vastai show user`).
2. **Secondo run** (stessa API key, pochi minuti dopo): il 403 è
   sparito da solo (`vastai show machine 148447` già funzionava
   direttamente), ma `vastai self-test` falliva ora con
   `Root state: zero_active_offers` — **nessuna offerta attiva**
   (`vastai search offers 'machine_id=148447 rentable=any rented=any'`
   restituiva vuoto). La macchina non era mai stata effettivamente
   listata (il wizard aveva esplicitamente avvisato di non listare
   finché il SUO self-test interno non fosse passato — cosa mai
   avvenuta, per il problema di API key del punto 1 sopra). **Il
   self-test standalone via CLI, a differenza del check interno del
   wizard, richiede un'offerta attiva per affittare un'istanza
   diagnostica temporanea** — va listata la macchina prima, non dopo.
3. **Terzo run**, dopo `vastai list machine 148447 -g 0.30` (listing
   manuale, $0.30/GPU/ora): l'offerta è stata trovata, il self-test è
   arrivato ai controlli reali (preflight requirement checks) e ha
   fallito su **3 requisiti oggettivi**, non bug:
   - Reliability: `0.5999925` contro `> 0.9` richiesto — normale per un
     host nuovo, si accumula con l'uso, nulla da configurare.
   - Download: `25.5 Mb/s` contro `>= 100.0 Mb/s` richiesto.
   - Upload: `4.4 Mb/s` contro `>= 100.0 Mb/s` richiesto.

   Anche un avviso non bloccante: 256 porte mappate contro un
   consigliato `<= 64` per GPU listata — probabile eccesso dovuto al
   range di default di questo repo (16384-32768, dimensionato per host
   multi-GPU secondo la guida ufficiale), non un errore.

**Conclusione**: i punti 2 e 3 confermano esattamente l'avviso di banda
già visto nel primissimo step "Network Speed" del wizard (Fase 7,
connessione ISP Wind Tre, ben sotto i 500 Mbps consigliati) — non è un
problema riproducibile del nostro stack software, è un limite fisico
della rete attuale del nodo. **Lo stack software è validato
end-to-end fino in fondo**: daemon (Fase 7), listing, self-test
arrivato ai controlli reali senza errori di configurazione/permessi.
L'unico blocco residuo per superare il self-test è la rete fisica
(serve una connessione con banda simmetrica sufficiente) — non
risolvibile da questo repo.

## 2026-08-24 — Scoperta esplorando `/var/lib/vastai_kaalia/`: `--ignore-requirements` bypassa banda/reliability

Su suggerimento dell'utente ("nella cartella vastai ci sono molti .py
ed altro... capire come funziona fa sempre bene"), letto
`start_self_test.sh` (script interno del daemon Kaalia, non
documentato nella guida ufficiale che avevamo). Rivela il **vero flusso
automatico** del daemon, diverso da quanto testato finora a mano:

1. Il daemon aspetta 10 minuti dopo l'avvio, poi controlla se la
   macchina è già listata (`vast show machine --raw | grep listed`).
2. Se non lo è: la lista **temporaneamente** (scadenza 3 ore da quel
   momento), lancia `vast self-test machine <ID> --ignore-requirements`,
   poi la **de-lista** comunque alla fine, sia in caso di successo che
   di fallimento — un listing è solo un mezzo per il test, non
   l'obiettivo.

Il dettaglio chiave: il daemon usa sempre `--ignore-requirements`,
flag mai passato nei nostri test manuali. Riprovato con
`vastai-self-test.sh --machine-id 148447 -- --ignore-requirements`
(il passthrough dopo `--` era già supportato dal nostro script, mai
usato finora):

- **Confermato**: bypassa correttamente i tre gate falliti prima
  (reliability, download, upload) — log esplicito "Continuing despite
  unmet requirements because --ignore-requirements is set." Coerente
  con quanto già annotato dalla guida ufficiale ("anche in modalità
  --ignore-requirements servono almeno 3 porte dirette aperte" — sotto
  quella soglia fallirebbe comunque; il nostro host ne ha 16385 aperte).
- Seleziona correttamente l'immagine di test in base alla CUDA
  dell'host (`vastai/test:self-test-v2-cuda-13.0` per CUDA 13.2 /
  compute_cap 860, RTX 3090) — logica di compatibilità non documentata
  altrove, utile saperla.
- **Nuovo blocco**, diverso dai precedenti: `Error creating instance:
  403 Client Error: Forbidden for url: .../asks/48511760/` — fallisce
  nel creare l'istanza diagnostica temporanea (cioè "affittare" la
  propria macchina per testarla), non nella lettura dei dati.

**Causa isolata**: `vastai show user` mostra `Can Pay: False` e
`Billing Creditonly: 1` — l'account non ha (ancora) un metodo di
pagamento pienamente verificato, nonostante l'utente abbia aggiunto
PayPal durante questa sessione (il campo non è cambiato subito dopo
l'aggiunta — probabile verifica aggiuntiva in sospeso lato Vast.ai,
es. conferma email/microtransazione, o propagazione non istantanea).
Anche un "noleggio verso se stessi" per il self-test richiede
evidentemente che l'account risulti abilitato a pagare. **Non
risolvibile da questo repo** — dipende dallo stato dell'account Vast.ai
dell'utente, non dallo stack software.

## Prossimi passi

- [x] Eseguire il self-test reale — **fatto sopra**, `machine_id`
      148447.
- [x] Trovare un modo per bypassare i gate di banda/reliability
      (bloccanti su questa rete) — **`--ignore-requirements` confermato
      funzionante** per quello scopo specifico.
- [ ] Riprovare il self-test con `--ignore-requirements` non appena
      `vastai show user` mostra `Can Pay: True` (verifica PayPal
      completata lato utente) — a quel punto dovrebbe arrivare fino in
      fondo, dato che gli altri due blocchi (permessi API, listing
      mancante, banda/reliability) sono già stati superati uno per uno.
- [ ] Valutare se aggiungere `--ignore-requirements` come default (o
      opzione documentata) in `postinstall/vastai-self-test.sh` per
      collaudi futuri su reti non conformi ai requisiti Vast.ai —
      **da decidere con l'utente**, non implementato in questa
      sessione: bypassare i requisiti di verifica ha implicazioni
      (guida ufficiale: "passing this self-test does not qualify this
      machine for verification" con questo flag).
- [ ] Aprire/aggiornare la PR includendo Fasi 10 e 11 insieme, dato che
      condividono la stessa dipendenza bloccante — ora sbloccata.
