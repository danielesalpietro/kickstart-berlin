# kickstart-berlin

Automazione dell'installazione **from-scratch** di un nodo GPU: dalla ISO di
boot fino a un host pronto (OS, driver NVIDIA, Docker, rete, benchmark
hardware). Base derivata dal flusso di setup host di **Vast.ai**, propedeutica
all'integrazione in [Grastorp](https://github.com/danielesalpietro/grastorp).

> Stato: **early stage**. Solo README con il piano mappato — nessuno script
> ancora implementato.

## Perché

Prima di poter installare Grastorp su un nodo fisico "vuoto", serve un
procedimento ripetibile che porti una macchina da ISO di boot a host pronto
(OS configurato, driver NVIDIA, Docker con runtime GPU, rete, primo
assessment hardware). Piuttosto che progettare questo flusso da zero, si parte
da un procedimento già maturo e testato su migliaia di macchine reali: quello
che i provider [RunPod](https://runpod.io) e [Vast.ai](https://vast.ai) usano
per trasformare una macchina in un nodo del loro marketplace GPU. Vast.ai in
particolare pubblica una guida host-setup dettagliata (`docs.vast.ai`) e
diversi script community ne replicano fedelmente i passi.

Questo repo isola quel procedimento (OS → driver → container runtime → rete →
benchmark) dalla parte specifica di Vast.ai (il suo daemon proprietario, il
suo marketplace), per poterlo riusare come base d'installazione di un nodo
Grastorp, con le dovute sostituzioni (vedi mapping sotto).

## Nota terminologica su "Kickstart"

Il nome è preso in prestito da **Kickstart**, il formato storico di
installazione automatizzata di Red Hat/Fedora (file `.ks`). Il sistema
operativo di riferimento in questo flusso è però **Ubuntu Server** (coerente
con quanto usato da Vast.ai e da Grastorp stesso), che non usa il formato
Kickstart ma il meccanismo di installazione automatizzata di Subiquity,
**autoinstall** (basato su cloud-init). Il nome del repo va quindi letto come
riferimento generico al concetto ("installazione automatizzata da zero"), non
come indicazione tecnica del formato file che verrà effettivamente usato.

## Le fasi del setup host, mappate da Vast.ai

Ricostruite analizzando la documentazione host di Vast.ai
(`docs.vast.ai/host/hosting-overview`) e uno script community che la
replica (`vastai-host-setup`). Ogni fase Vast.ai è annotata con il suo
equivalente per un nodo Grastorp.

| # | Fase (Vast.ai) | Cosa fa Vast.ai | Equivalente kickstart-berlin / Grastorp | Stato |
|---|---|---|---|---|
| 1 | Sistema operativo | Ubuntu Server 22.04/24.04 da ISO ufficiale | Stessa base OS, via `autoinstall` invece di installazione manuale interattiva | Da fare |
| 2 | Partizionamento disco | `/` ext4 (~100GB) + resto disco separato (xfs, non montato) | Stesso schema: partizione di sistema + partizione dedicata allo storage (Datastore Grastorp) | Da fare |
| 3 | Preparazione storage | Estensione LVM, rimozione loopback Docker, dati Docker sul filesystem principale | Stesso fix, necessario ugualmente per non limitare la Model Library di Grastorp a un loopback | Da fare |
| 4 | Driver NVIDIA + Container Toolkit | Driver pinnato (es. 535) + NVIDIA Container Toolkit da repo ufficiale | Identico: prerequisito già documentato nel README di Grastorp | Da fare |
| 5 | Docker | Install da `get.docker.com`, config con runtime NVIDIA | Identico | Da fare |
| 6 | Rete | DHCP via Netplan, DNS pubblici, hostname | Identico, propedeutico al rilevamento NIC di Grastorp ([grastorp#11](https://github.com/danielesalpietro/grastorp/issues/11)) | Da fare |
| 7 | Installazione daemon del provider | Wizard ufficiale Vast.ai (Kaalia daemon) + API key utente | **Sostituito**: qui va installato il backend/agent Grastorp stesso (Docker Compose), non un daemon di terzi | Da fare |
| 8 | Raccolta info hardware | `dmidecode` + permessi sudo dedicati, usato per popolare il "machine info" del marketplace | **Riusato as-is**: stesso meccanismo alla base del node profiling di Grastorp ([grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14)) | Da fare |
| 9 | Manutenzione | Timer systemd per pulizia oraria container/immagini inutilizzati | Riusabile as-is | Da fare |
| 10 | CLI del provider | Install CLI Vast.ai, config con API key | **Sostituito/opzionale**: solo se si integrano RunPod/Vast.ai come target di deploy remoto ([grastorp#15](https://github.com/danielesalpietro/grastorp/issues/15)), non è un prerequisito del nodo locale | Fuori scope iniziale |
| 11 | Self-test/benchmark | Speedtest di rete + verifica GPU/RAM/rete, esito inviato al backend Vast.ai | **Sostituito**: qui è l'assessment one-shot di Grastorp (stile Windows Experience Index, vedi [grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14)), non inviato a nessun backend esterno | Da fare |
| 12 | Port forwarding | Range di porte da aprire manualmente sul router, mostrato all'utente | Stesso principio, range di porte adattato ai deployment Grastorp invece che al range Vast.ai (16384-32768) | Da fare |
| 13 | Listing marketplace | Pubblicazione della macchina sul marketplace Vast.ai (prezzo, durata) | **Non applicabile** al nodo locale; diventa rilevante solo per l'integrazione provider di [grastorp#15](https://github.com/danielesalpietro/grastorp/issues/15) | Fuori scope iniziale |
| 14 | Report finale | Riepilogo: Machine ID, GPU, IP, porte, stato servizi | Riepilogo equivalente a fine installazione: stato Grastorp, GPU rilevate, IP, porte, esito assessment | Da fare |

## Architettura prevista

- **ISO di boot**: immagine Ubuntu Server con file `autoinstall`
  (cloud-init) per rendere il partizionamento (fase 2) e l'installazione
  base non interattivi.
- **Script post-install**: uno script idempotente (stile
  `vastai-host-setup/setup.sh`, ma senza le parti specifiche Vast.ai) per le
  fasi 3-9 e 12-14, eseguito al primo boot via systemd unit oneshot.
- **Nessun daemon proprietario di terzi**: al posto del Kaalia daemon (fase
  7) e della CLI/listing Vast.ai (fasi 10/13), il post-install porta
  direttamente all'avvio di Grastorp via `docker compose up`.

## Riferimenti

- [Grastorp](https://github.com/danielesalpietro/grastorp) — repo di
  destinazione finale, di cui questo è il prerequisito d'installazione.
- [grastorp#8](https://github.com/danielesalpietro/grastorp/issues/8),
  [grastorp#11](https://github.com/danielesalpietro/grastorp/issues/11) —
  networking Linux-nativo e rilevamento NIC, prerequisiti condivisi.
- [grastorp#14](https://github.com/danielesalpietro/grastorp/issues/14) —
  node profiling/benchmark hardware (fasi 8 e 11 di questa tabella).
- [grastorp#15](https://github.com/danielesalpietro/grastorp/issues/15) —
  integrazione RunPod/Vast.ai come target di deploy remoto (fasi 10 e 13 di
  questa tabella, fuori scope per l'installazione del nodo locale).
- Fonti Vast.ai: `docs.vast.ai/host/hosting-overview`;
  [`Soumya001/vastai-host-setup`](https://github.com/Soumya001/vastai-host-setup),
  [`AG-Sec4/VastAI-GPU-Host-Guide`](https://github.com/AG-Sec4/VastAI-GPU-Host-Guide)
  (guide community che replicano il flusso ufficiale).
