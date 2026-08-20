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

## Prossimi passi

- [ ] Eseguire il self-test reale non appena Fase 7 avrà un
      `machine_id` da un listing riuscito (VM Azure o Z8, quando
      l'utente fornirà il comando d'installazione del daemon) — vedi
      `docs/collaudo-funzionale.md` per il test case completo.
- [ ] Aprire/aggiornare la PR includendo Fasi 10 e 11 insieme, dato che
      condividono la stessa dipendenza bloccante.
