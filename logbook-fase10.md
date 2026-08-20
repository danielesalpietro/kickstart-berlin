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

- L'installer reale (`vast.ai/install.sh`) non è mai stato eseguito in
  questa sessione: dominio bloccato dalla policy di rete. Il
  comportamento di fallback ("cerca sotto `$HOME/.local/share/vastai`,
  linka in `/usr/local/bin`") è basato sulla sola dichiarazione del
  README del repo ufficiale, non su un test diretto dell'installer —
  da confermare sul primo host reale con accesso a `vast.ai` (VM Azure
  o Z8).

## Prossimi passi

- [ ] Eseguire `phase10_vastai_cli()` su un host reale con accesso di
      rete a `vast.ai`: confermare che l'installer funzioni, che
      `vastai` risulti su PATH (con o senza il fallback di symlink), e
      che `vastai set api-key` + `vastai show user` funzionino come
      documentato.
- [ ] Una volta confermato, la CLI è il prerequisito diretto per
      Fase 11 (`vastai-self-test.sh`) — vedi `logbook-fase11.md`.
