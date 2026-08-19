# Logbook — Fase 5: Docker + runtime NVIDIA (issue #5)

Diario di design e test per la Fase 5. Branch di riferimento:
`claude/fase5-docker-nvidia-runtime`, basato sulla punta di
`claude/fase4-nvidia-driver-toolkit` (dipendenza reale, non solo
sequenziale: `phase5_docker()` chiama `nvidia-ctk runtime configure`, che
richiede il pacchetto NVIDIA Container Toolkit installato in Fase 4). Per
il contesto delle fasi precedenti vedi [`logbook-fase1.md`](logbook-fase1.md),
[`logbook-fase2.md`](logbook-fase2.md), [`logbook-fase3.md`](logbook-fase3.md),
[`logbook-fase4.md`](logbook-fase4.md).

## 2026-08-19 — Nessuna decisione di scope da chiarire con l'utente

A differenza di Fase 3 (LVM) e Fase 4 (versione driver), qui non c'è
alcun disallineamento tra il testo dell'issue #5/README e la guida
ufficiale Vast.ai da risolvere: la guida non descrive comandi espliciti
per l'installazione di Docker né per la config del runtime NVIDIA (questo
passaggio è nascosto dentro il proprio installer proprietario — la guida
dice solo "The installer will install Docker, nvidia-ctk, and other
related packages automatically"). Non essendoci una fonte vast.ai-specifica
da cui questo passaggio sia ricavabile, si segue la pratica standard
Docker (script di convenienza `get.docker.com`), già indicata come piano
nel README ancora prima di questa sessione.

## 2026-08-19 — Implementazione

Nuova funzione `phase5_docker()` in `postinstall/setup.sh`, terza fase
della sequenza in `main()` dopo `phase3_docker_storage()` e
`phase4_nvidia_driver()`:

- **Installazione Docker**: idempotente (`command -v docker` come check),
  script di convenienza `get.docker.com` + `systemctl enable --now docker`.
- **Runtime NVIDIA**: `nvidia-ctk runtime configure --runtime=docker` +
  restart del servizio, ma solo se `nvidia-ctk` è presente (cioè solo su
  host con GPU dove Fase 4 ha installato il Container Toolkit — su un
  host non-GPU questo passaggio viene saltato con un log esplicito,
  stesso pattern di `phase4_nvidia_driver()`).
- **Interazione con `daemon.json` di Fase 3**: `phase3_docker_storage()`
  scrive già `/etc/docker/daemon.json` con `data-root` puntato al
  Datastore. `nvidia-ctk runtime configure` fa un merge nel file
  esistente (non lo sovrascrive per intero, per documentazione NVIDIA)
  quindi in teoria le due modifiche convivono — ma questo merge esatto
  **non è verificabile in questo sandbox** (vedi sotto): resta da
  confermare che `data-root` sopravviva intatto dopo che `nvidia-ctk` ha
  scritto la sezione `runtimes`.

## 2026-08-19 — Cosa è stato verificato e cosa no

**Verificato in sandbox**:
- `shellcheck` pulito, sintassi bash valida.
- Percorso "NVIDIA Container Toolkit assente" (host non-GPU, o Fase 4 non
  ancora eseguita) testato in isolamento: la funzione salta correttamente
  la config del runtime con un log esplicito, senza errori.

**Non verificabile in sandbox**:
- `get.docker.com` è **bloccato dalla policy di rete del sandbox** (stesso
  tipo di restrizione già vista per `docs.vast.ai` in Fase 1 e
  `nvidia.github.io` in Fase 4 — confermato via
  `$HTTPS_PROXY/__agentproxy/status`, `connect_rejected` su
  `get.docker.com:443`). L'installazione Docker vera e propria non è
  stata eseguita qui.
- Il merge di `nvidia-ctk runtime configure` dentro un `daemon.json` che
  contiene già `data-root` (Fase 3) — richiede sia `nvidia-ctk`
  funzionante (Fase 4, bloccata dallo stesso limite di rete) sia una GPU
  reale per un test end-to-end pienamente rappresentativo.

## Prossimi passi

- [ ] Testare su un host con rete diretta (VM Azure) l'installazione
      Docker vera (`get.docker.com`) e, se anche il Container Toolkit di
      Fase 4 risulta installabile lì, la config del runtime NVIDIA e
      l'interazione con `daemon.json`/`data-root` di Fase 3.
- [ ] Confermare `docker run --rm --gpus all ...` (o equivalente) vede
      davvero la GPU — richiede hardware NVIDIA reale (Z8 o istanza GPU
      cloud dedicata), stesso limite già documentato per Fase 4.
- [ ] Aprire la PR quando: installazione Docker verificata su rete
      diretta; idealmente (non bloccante) confermato l'intero percorso
      Docker+GPU su hardware reale.
