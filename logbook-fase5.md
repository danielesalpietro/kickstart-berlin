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

## 2026-08-19/20 — Verificato su rete diretta (VM Azure): Docker + merge runtime NVIDIA, nessuna perdita di data-root

Stesso ambiente delle verifiche Fase 4 (VM-TEST2, Azure, rete diretta).
Eseguiti a mano, nell'ordine esatto di `main()` (Fase 3 → 4 → 5), i
comandi reali di `phase5_docker()` e ricreato lo scenario critico
segnalato come non verificabile: `daemon.json` che contiene già
`data-root` (scritto da `phase3_docker_storage()` prima che Docker
esista) quando `nvidia-ctk runtime configure` interviene.

1. Simulato l'output di Fase 3: `/etc/docker/daemon.json` con solo
   `{"data-root": "/tmp/fake-datastore/docker"}` (stesso formato esatto
   prodotto dal merge JSON di `phase3_docker_storage()`).
2. `curl https://get.docker.com | sh` (comando reale di
   `phase5_docker()`): **riuscito**, nessun errore — solo il blocco di
   rete del sandbox impediva questo test prima. `systemctl enable --now
   docker` OK, Docker si avvia rispettando già il `data-root` custom
   (`docker info` → `Docker Root Dir: /tmp/fake-datastore/docker`).
3. Reinstallato NVIDIA Container Toolkit (stessi comandi già verificati
   in Fase 4).
4. `nvidia-ctk runtime configure --runtime=docker`: **merge pulito
   confermato** — `daemon.json` dopo il comando contiene sia `data-root`
   (invariato) sia la nuova chiave `runtimes.nvidia`, nessuna perdita di
   dati. Era l'unico punto di interazione tra fasi non ancora confermato.
5. `systemctl restart docker` dopo la riconfigurazione: pulito, Docker
   riparte con `Docker Root Dir` ancora corretto e il runtime `nvidia`
   elencato tra quelli disponibili.
6. `docker run --rm hello-world`: eseguito con successo, conferma che
   l'intero stack (data-root custom + runtime nvidia registrato) è
   pienamente funzionante, non solo "il file JSON sembra corretto".

**Nessun bug trovato, nessuna modifica necessaria a `postinstall/
setup.sh`**: sia l'installazione Docker sia l'interazione col merge del
runtime NVIDIA funzionano esattamente come progettato. Pulizia completa
dell'host di test dopo la verifica (Docker, Container Toolkit, file di
config e directory di prova tutti rimossi).

**Resta non verificabile qui** (nessuna GPU su questa VM): `docker run
--gpus all ...` che veda davvero una GPU — richiede hardware NVIDIA
reale (Z8, dal 23/08, o istanza GPU cloud dedicata).

## Prossimi passi

- [x] Testare su un host con rete diretta (VM Azure) l'installazione
      Docker vera e la config del runtime NVIDIA — **confermato sopra**,
      incluso il punto critico data-root/merge JSON.
- [x] Confermare `docker run --rm --gpus all ...` vede davvero la GPU —
      **confermato il 2026-08-23** su HP Z8 G4 + RTX 3090, vedi
      [`logbook_first_boot.md`](logbook_first_boot.md). Nota: il tag
      `nvidia/cuda:12.4.1-base-ubuntu24.04` usato come riferimento in
      `docs/setup.md` è risultato ritirato da Docker Hub durante questo
      collaudo — sostituito con `12.6.0-base-ubuntu24.04` (già corretto
      in `docs/setup.md`).
- [x] Aprire la PR — fatto (PR #28, `claude/postinstall-firstboot-fixes`,
      mergiata in `develop`).

## 2026-08-24 — Bug trovato sul collaudo reale: admin non nel gruppo docker (issue #34)

`phase5_docker()` installava Docker e configurava il runtime NVIDIA, ma
non aggiungeva mai `admin` (unico account del nodo) al gruppo `docker`
— ogni comando `docker` senza `sudo` falliva con "permission denied".
Non emerso nei collaudi precedenti (VM Azure) perché lì i test erano
eseguiti con `sudo docker` esplicito, non verificando l'uso senza sudo
come farebbe un operatore reale.

**Fix** (PR #38): `usermod -aG docker admin` (idempotente) in coda a
`phase5_docker()`. **Regression test aggiunto** in
`scripts/boot-test-qemu.sh` (stesso PR): dopo la verifica del
post-install esistente, controlla `id -nG admin` include `docker` —
gira automaticamente ad ogni build-and-boot-test in CI, non serve più
scoprirlo di nuovo su hardware reale a ogni collaudo.

Applicato anche live sulla Z8 già installata (`usermod -aG docker
admin` via SSH, verificato da una sessione nuova) — il fix in
`setup.sh` vale solo per le installazioni future, non è retroattivo su
un nodo già esistente. Vedi `logbook_first_boot.md`.
