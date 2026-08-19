# Logbook — Fase 8: raccolta informazioni hardware (issue #8)

Diario di design e test per la Fase 8. Branch di riferimento:
`claude/fase8-hardware-info`, basato sulla punta di
`claude/fase6-network-setup` (Fase 7 saltata per ora, su richiesta
esplicita dell'utente — "saltiamo a fase 8, le altre le vediamo poi").
Per il contesto delle fasi precedenti vedi
[`logbook-fase1.md`](logbook-fase1.md) … [`logbook-fase6.md`](logbook-fase6.md).

## 2026-08-20 — Scope: "riusato as-is", ma l'output non è lo schema Grastorp

Il README descrive Fase 8 come "Riusato as-is: stesso meccanismo alla
base del node profiling di Grastorp (grastorp#14)" — a differenza di
Fase 3/4/6, qui non c'è un vero disallineamento da risolvere con la
guida ufficiale: il meccanismo (`dmidecode` + permessi sudo dedicati per
popolare il "machine info" del marketplace Vast.ai) è generico e si
applica as-is.

Due adattamenti comunque necessari, non ambigui:
- **Permessi sudo dedicati non servono qui**: Vast.ai li usa perché il
  proprio daemon gira con privilegi ristretti e necessita di un varco
  specifico per `dmidecode` (che richiede root). Il nostro account
  `admin` ha già sudo NOPASSWD completo fin dalla Fase 1 (unico accesso
  è via chiave SSH, vedi `iso/user-data`) — un permesso più stretto
  sarebbe una restrizione aggiuntiva non richiesta da alcun requisito di
  sicurezza noto per questo progetto, quindi non implementata.
- **Lo schema di output non è quello di Grastorp**: grastorp#14 (non
  ancora esaminata in dettaglio da questa sessione, fuori scope di
  questo repo) definirà probabilmente un formato "machine info"
  specifico. Qui si produce uno snapshot JSON grezzo (dmidecode, CPU,
  PCI, dischi, rete, GPU) — un futuro backend Grastorp potrà consumarlo
  e trasformarlo nel proprio schema, senza che kickstart-berlin debba
  indovinarlo.

## 2026-08-20 — Implementazione

Nuova funzione `phase8_hardware_info()` in `postinstall/setup.sh`, quinta
fase della sequenza in `main()` (dopo Fase 6; Fase 7 assente per ora):

- Garantisce `dmidecode` installato (`apt-get install` se assente).
- Raccoglie via Python (già usato altrove nel file per lo stesso motivo
  di robustezza JSON): `dmidecode -t system/baseboard/memory/processor`,
  `lscpu`, `lspci`, `lsblk`, `ip -brief addr`, `nvidia-smi` (se presente,
  info GPU). Ogni comando è avvolto in un try/except: uno strumento
  mancante o fallito produce una stringa di errore in quel campo, non fa
  fallire l'intera raccolta — importante perché non tutti questi
  strumenti sono garantiti presenti su ogni variante Ubuntu Server
  minimale (verificato: vedi sotto).
- Scrive tutto in `/opt/kickstart-berlin/hardware-info.json`.
- **Idempotente per costruzione**: fase interamente di sola lettura (a
  parte l'eventuale install di `dmidecode`), ogni esecuzione sovrascrive
  lo snapshot con dati freschi — nessuno stato da preservare tra
  esecuzioni, a differenza delle fasi precedenti (non serve nessun
  marker/guardia contro la doppia esecuzione).

## 2026-08-20 — Verificato

A differenza di Fase 4/5 (bloccate da restrizioni di rete del sandbox)
e Fase 6 (verificata solo con uno stub di `ufw`), questa fase è
**interamente di sola lettura e non ha dipendenze di rete esterne** —
completamente testabile qui, senza limiti da segnalare:

- `shellcheck` pulito, `validate-autoinstall.py` passa.
- **Eseguita per davvero** in sandbox (non solo un percorso isolato):
  `dmidecode` installato con successo via `apt-get` (assente di
  default in questo sandbox — coerente con l'ipotesi che non tutte le
  installazioni Ubuntu Server minimali lo includano di default);
  `lscpu`/`lsblk` hanno prodotto dati reali della macchina; `lspci`,
  `ip`, `nvidia-smi` erano assenti in questo sandbox (container minimale)
  e sono stati correttamente catturati come errore per-campo senza far
  fallire il resto della raccolta — esattamente il comportamento difensivo
  voluto, e la conferma pratica che serve (su un Ubuntu Server reale
  questi strumenti sono di serie, quindi lì la raccolta sarà più ricca).
  `dmidecode` stesso, privo di accesso a `/dev/mem` in un container, ha
  restituito output vuoto invece di un errore fatale — gestito
  correttamente dallo stesso meccanismo.
- Output JSON verificato manualmente: struttura valida, un campo per
  ogni fonte, nessuna eccezione propagata.

## Prossimi passi

- [ ] Quando grastorp#14 definisce lo schema "machine info" atteso,
      valutare se serve un passaggio di trasformazione qui o se resta
      responsabilità del backend Grastorp consumare lo snapshot grezzo.
- [ ] Confermare su hardware reale (VM Azure o Z8) che `dmidecode`
      restituisca dati reali (non lo "Scanning /dev/mem" vuoto visto in
      questo container) — atteso ma non ancora confermato fuori sandbox.
- [ ] Aprire la PR quando confermato su host reale.
