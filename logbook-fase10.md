# Logbook — Fase 10: CLI vastai (issue #10)

Diario di design e test per la Fase 10. Per il contesto delle fasi
precedenti vedi [`logbook-fase1.md`](logbook-fase1.md) …
[`logbook-fase8.md`](logbook-fase8.md), [`logbook-fase7.md`](logbook-fase7.md)
per il cambio di direzione strategica ("validare prima il nodo come
host Vast.ai reale, poi evolvere verso Grastorp") di cui questa fase è
la continuazione diretta.

## 2026-08-20 — Origine: richiesta dell'utente, fonti ufficiali

L'utente ha fornito tre fonti ufficiali Vast.ai (due PDF caricati,
`docs.vast.ai/cli/hello-world` e `docs.vast.ai/host/market-metrics`, più
un terzo PDF `docs.vast.ai/host/how-to-self-test` fornito durante la
sessione — vedi `logbook-fase11.md`), chiedendo se il software CLI
(in parte Python) fosse recuperabile e integrabile come programma e
come procedura/check.

**Verificato**: il repo ufficiale è pubblico — [`vast-ai/vast-cli`](https://github.com/vast-ai/vast-cli)
su GitHub, licenza MIT, pacchetto Python (`pyproject.toml`:
`requires-python = ">=3.10,<4.0"`), pubblicato su PyPI come `vastai`
(entry point `vastai.cli.main:main`), attivamente mantenuto (commit
recenti, release taggate ~v1.5.5). Verificato tramite un agente di
ricerca dedicato (github.com raggiungibile da questa sessione, a
differenza di `docs.vast.ai`/`vast.ai` — bloccati dalla policy di rete,
vedi sotto).

## 2026-08-20 — Limite di rete: `docs.vast.ai` e `vast.ai` bloccati

Tentativo diretto di `curl` verso `docs.vast.ai/host/vms.md`,
`docs.vast.ai/host/how-to-self-test.md` e `vast.ai/install.sh`: tutti e
tre restituiscono `403` dal proxy di rete della sessione (policy
dell'organizzazione, non un problema TLS/certificati — confermato via
`$HTTPS_PROXY/__agentproxy/status`, `recentRelayFailures` mostra
`connect_rejected` su `docs.vast.ai:443`). `github.com` e
`raw.githubusercontent.com` restano invece raggiungibili, usati per
tutta la verifica del codice sorgente della CLI.

Conseguenza diretta: non è stato possibile leggere il contenuto reale
dell'installer `vast.ai/install.sh` da questa sessione. Il README del
repo dichiara solo che l'installer mette `vastai` sotto
`$HOME/.local/share/vastai` ("isolated managed runtime"), senza
specificare se aggiunge un symlink su una directory di PATH di sistema
o solo una riga in una rc di shell interattiva — `phase10_vastai_cli()`
in `postinstall/setup.sh` gira non interattiva (systemd oneshot,
nessuna rc caricata), quindi gestisce esplicitamente il caso "comando
non trovato dopo l'installer" cercando l'eseguibile sotto la home e
collegandolo in `/usr/local/bin`. Non verificabile end-to-end senza un
host reale con accesso a `vast.ai`.

## 2026-08-20 — Aggiornamento: `install.sh` reale fornito dall'utente

L'utente ha caricato direttamente il file `install.sh` (non fetchabile
da questa sessione, vedi sopra) — permette di sostituire la supposizione
del paragrafo precedente con dati reali, letti dal codice sorgente:

- Il binario stabile che l'installer crea è un symlink in
  **`$HOME/.local/bin/vastai`** (`LOCAL_BIN="$HOME/.local/bin"`,
  `link_swap "$ROOT/bin/vastai" "$LOCAL_BIN/vastai"`) — non sotto
  `$HOME/.local/share/vastai` (quello è solo `$ROOT`, il runtime interno
  con Python gestito via `uv`, mai pensato per essere referenziato
  direttamente).
- L'aggiunta al PATH avviene **solo** scrivendo una riga in
  `~/.bashrc`/`~/.zshrc`, e **solo se interattivo** — commento esplicito
  nel file: *"never written non-interactively/CI"*. La funzione
  `is_interactive()` controlla l'apertura di `/dev/tty`: sotto un
  systemd oneshot (nessun terminale di controllo) risulta falsa, quindi
  in `postinstall/setup.sh` la rc **non viene mai toccata** dall'installer
  stesso — confermato da codice, non più solo un'ipotesi.
- Nessun requisito di rete oltre a HTTPS verso `vast.ai/cli/manifest.env`
  e il download del runtime/wheel; nessun requisito di non-root visibile
  nel codice (scrive solo sotto `$HOME` e `$HOME/.local/bin`, compatibile
  con `$HOME=/root` in un postinstall che gira come root).
- Pagina reale di gestione API key: `https://cloud.vast.ai/manage-keys/?tab=api-keys`
  (stampata dall'installer stesso a fine esecuzione) — corretto anche nei
  messaggi di `phase10_vastai_cli()`/`vastai-self-test.sh`, che prima
  citavano `cloud.vast.ai/account/` (mai verificato, ora sostituito).

**Bug trovato e corretto** in `phase10_vastai_cli()`: il fallback per
"comando non trovato dopo l'installer" cercava con
`find ... -type f -name vastai` sotto `.local/share/vastai` — sbagliato
su due fronti, non solo la directory: `-type f` esclude esplicitamente i
symlink, e la catena reale di symlink dell'installer
(`link_swap`, più volte) non produce mai un file regolare con quel nome.
Sostituito con un controllo diretto su `$HOME/.local/bin/vastai` (il
percorso stabile e documentato che l'installer stesso crea), con `-e`
anziché `-type f` per seguire correttamente i symlink.

## 2026-08-20 — Decisione: perché la CLI può essere automatica e il daemon no

Fase 7 (`install-vastai-host.sh`) resta deliberatamente fuori da
`main()` perché il comando d'installazione del daemon è
account-specifico e valido un'ora. La CLI `vastai` non ha questo
vincolo: l'installer (`curl -fsSL https://vast.ai/install.sh | bash`)
non contiene alcun segreto — può quindi entrare nella sequenza
automatica di `setup.sh` come nuova `phase10_vastai_cli()`, idempotente
(`command -v vastai` prima di reinstallare). L'autenticazione
(`vastai set api-key <key>`) resta comunque manuale, a carico
dell'operatore dopo il primo boot — stessa disciplina già applicata
alla chiave SSH e al comando daemon di Fase 7: nessun segreto mai
hardcoded o committato nel repo.

## 2026-08-20 — Verificato in sandbox

- `bash -n` pulito su `postinstall/setup.sh` dopo la modifica.
- Percorso "già installato": `command -v vastai` positivo, log
  informativo, nessuna reinstallazione — verificato per lettura del
  codice (logica identica al pattern già usato in `phase5_docker` per
  Docker/`nvidia-ctk`).

## Non verificabile in sandbox (per costruzione)

- L'installer reale (`vast.ai/install.sh`) non è mai stato **eseguito**
  in questa sessione: dominio bloccato dalla policy di rete, nessuna
  connettività verso `vast.ai/cli/manifest.env`/il download del runtime
  è disponibile qui. Il codice sorgente è però stato letto per intero
  (fornito dall'utente) e il fallback di `phase10_vastai_cli()` è ora
  basato su quel codice, non più su un'inferenza dal solo README — resta
  comunque da confermare **in esecuzione** sul primo host reale con
  accesso a `vast.ai` (VM Azure o Z8): provisioning del Python gestito
  via `uv`, download effettivo del manifest/wheel, smoke test
  `vastai --version` interno all'installer, comportamento di
  `is_interactive()` sotto il vero systemd oneshot di questo progetto.

## Prossimi passi

- [ ] Eseguire `phase10_vastai_cli()` su un host reale con accesso di
      rete a `vast.ai`: confermare che l'installer funzioni, che
      `vastai` risulti su PATH (con o senza il fallback di symlink), e
      che `vastai set api-key` + `vastai show user` funzionino come
      documentato.
- [ ] Una volta confermato, la CLI è il prerequisito diretto per
      Fase 11 (`vastai-self-test.sh`) — vedi `logbook-fase11.md`.
