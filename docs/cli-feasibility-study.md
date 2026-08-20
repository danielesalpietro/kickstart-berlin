# Studio di fattibilità — CLI di gestione stile `esxcli`

> Stato: **studio, nessuna implementazione**. Risponde alla domanda posta
> nella discussione che ha originato questo documento: prima di scrivere
> codice per una CLI di gestione del nodo (ispirata a `esxcli`/ESXi Shell),
> vale la pena capire *cosa* dovrebbe gestire, *dove* dovrebbe vivere e se
> il repo è già maturo abbastanza da giustificarla. Risposta breve:
> **non ancora** — vedi [Raccomandazione](#raccomandazione).

## 1. Il modello di riferimento: `esxcli`

`esxcli` è la CLI di gestione locale/remota di VMware ESXi: un dispatcher a
namespace (`esxcli storage ...`, `esxcli network ...`, `esxcli software vib
...`, `esxcli hardware ...`, `esxcli system ...`) che espone in modo uniforme
lo stato e le operazioni di un host già installato e in esercizio — non
l'installazione stessa (quella è compito di un instsallatore separato, il
kickstart ESXi). Caratteristiche rilevanti per il confronto:

- **Namespace stabili** che rispecchiano i sottosistemi dell'host (storage,
  rete, hardware, software/pacchetti, sistema).
- **Uso continuativo nel tempo**: un amministratore la usa per ispezionare e
  modificare un host che resta in esercizio per mesi/anni, non solo al primo
  boot.
- **Output strutturato** (`--formatter=csv|json|xml`) pensato per scripting
  e automazione di terze parti.
- **Superficie ampia perché il sottostante (ESXi) è maturo**: la CLI è uno
  specchio di funzionalità del kernel/hypervisor già esistenti, non le
  precede.

Quest'ultimo punto è il più rilevante per la fattibilità qui: **una CLI di
questo tipo ha senso quando esiste già abbastanza "stato gestito" sotto di
lei da giustificare dei namespace stabili.**

## 2. Cosa gestisce oggi kickstart-berlin (stato reale, non il piano)

Dal README e dal codice in `postinstall/setup.sh`, lo stato **implementato**
è:

| Sottosistema | Cosa esiste oggi | Dove |
|---|---|---|
| OS/installazione | ISO autoinstall (Subiquity), non interattiva | `iso/`, `scripts/build-iso.sh` — **build-time, non runtime** |
| Storage | Partizionamento disco singolo/doppio, Datastore XFS montato a convenzione ESX-style (`/grastorp/volumes/<uuid>` + symlink `datastore`) | `iso/storage-*-disk.yaml`, late-commands |
| Docker (storage) | `data-root` puntato al Datastore, `/var/lib/docker` diventa symlink, migrazione dati esistenti | `postinstall/setup.sh: phase3_docker_storage()` |
| GPU/driver | Rilevamento PCI NVIDIA, install driver via `ubuntu-drivers autoinstall`, hold pacchetti, NVIDIA Container Toolkit | `postinstall/setup.sh: phase4_nvidia_driver()` |

Tutto il resto della tabella fasi del README (5 Docker/runtime, 6 rete, 7
bootstrap agent Grastorp, 8 hardware info, 9 manutenzione, 11
self-test/benchmark, 12 port forwarding, 14 report finale) è **"Da fare"**:
issue aperte, nessun codice. Non esiste ancora, ad esempio, un container
Docker in esecuzione, un agente Grastorp, un profilo hardware, o una rete
configurata oltre il DHCP di installazione.

Questo è il fatto centrale dello studio: **la maggior parte dei namespace
che una CLI stile `esxcli` vorrebbe esporre (`storage`, `network`,
`hardware`, `system`, `software`) non hanno ancora nulla di sostanziale da
esporre**, perché il sottosistema che gestirebbero non è stato costruito.
Una CLI oggi avrebbe forse 2 comandi utili reali (stato Datastore, stato
driver NVIDIA) e il resto sarebbe superficie speculativa scritta prima del
suo scopo — esattamente il tipo di over-engineering che le convenzioni di
questo repo (e le istruzioni generali di sviluppo) chiedono di evitare.

## 3. Domanda architetturale prioritaria: CLI di *cosa*, esattamente?

Prima ancora della maturità, c'è un problema di collocazione che lo studio
deve risolvere perché cambia la risposta "sì/no" a seconda del ramo:

**kickstart-berlin è un bootstrapper one-shot, non un host manager
persistente.** Il suo intero ciclo di vita è: boot da ISO → autoinstall →
`kickstart-berlin-postinstall.service` (systemd oneshot, `ConditionPathExists=
!/opt/kickstart-berlin/.setup-complete`) → si disattiva da solo dopo il primo
run. Non c'è un processo kickstart-berlin che gira mentre il nodo è in
esercizio — a differenza del vSphere/ESXi daemon dietro `esxcli`, o del
processo NSX/vCenter agent. Il corrispettivo di "un host in esercizio a
lungo termine da amministrare" in questo stack non è kickstart-berlin: è
**Grastorp** (il backend/agent che il README stesso descrive come sostituto
del daemon Vast.ai in Fase 7, non ancora implementato).

Questo porta a due letture diverse della richiesta originale:

- **CLI di kickstart-berlin** (ispezione/debug del bootstrap): avrebbe senso
  solo come strumento diagnostico *durante* l'installazione o subito dopo
  (`kickstart-berlin status`: Datastore montato? driver caricato? fase X
  completata?), utile soprattutto in CI/debug hardware reale. Ambito
  volutamente piccolo e stabile nel tempo (le fasi 1-4 già fatte più le
  poche altre di bootstrap).
- **CLI del nodo in esercizio** (l'equivalente concettuale di `esxcli`:
  gestione storage/rete/GPU/container per tutta la vita del nodo): è per
  definizione competenza di **Grastorp**, non di questo repo. Costruirla
  qui la metterebbe nel posto sbagliato dello stack e duplicherebbe
  responsabilità che Grastorp dovrà comunque avere (l'agente stesso parla
  con Docker, la rete, l'hardware).

Se l'intento è il secondo caso (una vera CLI "alla esxcli" per amministrare
il nodo per tutta la sua vita), lo studio di fattibilità corretto va aperto
**su Grastorp**, non su kickstart-berlin — questo repo può al più fornire i
dati bootstrap (percorso Datastore, convenzioni di mount, versione driver)
che quella CLI leggerebbe.

## 4. Cosa sarebbe fattibile *oggi*, se si limitasse l'ambito al bootstrap

Ipotesi B (CLI diagnostica di kickstart-berlin, ambito volutamente minimo):

| Comando ipotetico | Fattibile oggi? | Note |
|---|---|---|
| `kickstart-berlin status` | Sì | Datastore montato/symlink coerente, `.setup-complete` presente, driver NVIDIA attivo o "non applicabile" |
| `kickstart-berlin datastore info` | Sì | Legge mount reale + symlink, spazio libero (`df`) |
| `kickstart-berlin gpu info` | Sì | Wrapper leggibile su `_phase4_gpu_present` + `nvidia-smi` |
| `kickstart-berlin network info` | No | Fase 6 non esiste |
| `kickstart-berlin hardware info` | No | Fase 8 non esiste |
| `kickstart-berlin software ...` (gestione pacchetti) | No | Non è un modello pertinente: qui non c'è un package manager custom da esporre, è Ubuntu/apt |
| `kickstart-berlin maintenance ...` | No | Fase 9 non esiste |

Anche nell'ipotesi più conservativa, la superficie reale oggi è **2-3
sotto-comandi read-only**. Non giustifica un framework CLI dedicato
(namespace, help strutturato, formatter multipli): quel valore lo si ottiene
già oggi con un flag `--status`/`--check` su `postinstall/setup.sh` stesso,
o uno script separato minimale, senza introdurre una nuova convenzione di
progetto.

## 5. Costi/rischi di procedere ora

- **Manutenzione doppia**: ogni nuova fase (5-14) andrebbe implementata sia
  nella logica di `setup.sh` sia nella CLI che la espone, raddoppiando il
  lavoro su un repo che il README stesso dichiara "early stage".
- **Superficie stabile promessa troppo presto**: `esxcli` vale perché i suoi
  namespace sono stabili nel tempo; fissare oggi un contratto di comandi per
  sottosistemi che non esistono ancora rischia rework non appena le fasi
  5-14 definiscono la forma reale di rete/hardware-info/manutenzione.
  Meglio lasciare che l'interfaccia emerga da `setup.sh` via via che le fasi
  vengono implementate.
- **Posto sbagliato nello stack** se l'intento è la gestione a lungo
  termine (vedi §3): il lavoro andrebbe rifatto su Grastorp comunque.
- **Nessuna issue/richiesta pregressa**: il mapping fasi del README (issue
  #15 e sotto-issue #1-#14) non prevede una CLI di gestione — l'unica voce
  "CLI" nel piano è l'issue #10, che è un altro concetto (CLI/SDK di
  *terze parti*, Vast.ai/RunPod, esplicitamente fuori scope).

## Raccomandazione

**Non implementare ora.** Motivazioni, in ordine di peso:

1. Il repo gestisce oggi solo storage/Datastore e driver GPU: non c'è
   abbastanza "host gestito" da giustificare namespace stabili in stile
   `esxcli`.
2. Il ruolo che `esxcli` gioca nello stack VMware (gestione dell'host per
   tutta la sua vita operativa) corrisponde concettualmente a **Grastorp**,
   non a kickstart-berlin, che è e resta un bootstrapper one-shot.
3. Il valore diagnostico disponibile oggi (stato Datastore, stato driver) è
   ottenibile con una estensione minima di `setup.sh` (es. flag `--status`),
   senza introdurre una nuova convenzione/framework di progetto.

**Quando riconsiderare**: dopo che le Fasi 5 (Docker/runtime), 6 (rete), 7
(bootstrap agent Grastorp) e 8 (hardware info) sono implementate, ha senso
riaprire la domanda — a quel punto (a) kickstart-berlin avrà abbastanza
stato bootstrap da meritare un vero comando diagnostico multi-namespace, e
soprattutto (b) sarà chiaro se Grastorp stesso vuole/deve esporre una CLI di
gestione a lungo termine sul nodo, che è la vera controparte di `esxcli` in
questo stack.

**Se e quando si procede**, farlo incrementalmente: un namespace per fase
già implementata, non un framework generico progettato in anticipo per fasi
future — coerente con come `postinstall/setup.sh` stesso è cresciuto finora
(una funzione per fase, non un file per fase).

## Riferimenti

- [README.md](../README.md) — tabella fasi Vast.ai → kickstart-berlin/Grastorp.
- [`postinstall/setup.sh`](../postinstall/setup.sh) — unica logica di
  gestione runtime esistente oggi (fasi 3-4).
- Issue #15 — piano a fasi (repo kickstart-berlin).
- Issue #10 — CLI/SDK provider esterni (Vast.ai/RunPod): concetto distinto,
  fuori scope, non sovrapposto a questo studio.
- [Grastorp](https://github.com/danielesalpietro/grastorp) — repo
  destinatario naturale di una futura CLI di gestione a lungo termine del
  nodo, se l'intento è replicare il ruolo di `esxcli`.
