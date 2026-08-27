# Logbook — Fase 7: daemon host Vast.ai reale (issue #7)

Diario di design e test per la Fase 7. Branch di riferimento:
`claude/fase7-vastai-daemon-real`, basato sulla punta di
`claude/fase8-hardware-info`. Per il contesto delle fasi precedenti vedi
[`logbook-fase1.md`](logbook-fase1.md) … [`logbook-fase6.md`](logbook-fase6.md),
[`logbook-fase8.md`](logbook-fase8.md).

## 2026-08-20 — Cambio di direzione strategica (con l'utente)

Fino a questo punto il README classificava Fase 7 come "Sostituito: qui
va installato il backend/agent Grastorp stesso, non un daemon di terzi"
— decisione presa prima di questa sessione. L'utente ha chiarito la
sequenza corretta: **prima** il nodo deve funzionare come host Vast.ai
reale e completo (daemon, CLI, listing), per avere la certezza che
l'intero stack costruito finora (Fasi 1-6, 8) sia davvero compatibile
end-to-end con l'ecosistema Vast.ai — **poi**, solo dopo aver confermato
questo, si evolve verso l'architettura ESX-style specifica di Grastorp.
Non è quindi un ripensamento dell'architettura ESX-style già costruita,
ma un riordino: convalida "as-is" prima, adattamento dopo.

Buona notizia verificata rileggendo il lavoro già fatto: il layer
ESX-style di Fase 2/3 (Datastore su `/grastorp/volumes/<uuid>`,
`/var/lib/docker` come symlink verso di esso) è stato progettato fin
dall'inizio proprio per questo scenario — qualunque tooling Vast.ai che
si aspetti il path standard `/var/lib/docker` dovrebbe continuare a
funzionare senza modifiche, symlink o mount diretto non fa differenza
per un installer che controlla solo l'esistenza/scrivibilità del path.
Non è stato quindi necessario tornare indietro su Fase 2/3 per questo
cambio di direzione.

## 2026-08-20 — Vincolo pratico: comando d'installazione account-specifico

Il comando di installazione ufficiale del daemon Vast.ai (guida
ufficiale, sezione "Install the Vast.ai Manager Software") va copiato da
`https://cloud.vast.ai/host/setup`, da loggati come host — **contiene
l'identità dell'account ed è valido solo un'ora dalla generazione**.
Conseguenze dirette sul design:

- **Non può essere incorporato nell'ISO a build-time**: il tempo fra
  build e boot reale della macchina supera quasi certamente l'ora di
  validità.
- **Non può far parte della sequenza automatica di `postinstall/
  setup.sh`** (eseguita al primo boot via systemd oneshot,
  `main()` → `phaseN_...()`): l'orario del primo boot non è
  prevedibile/sincronizzabile con la generazione del comando dal
  portale.
- Va quindi eseguito **a mano dall'operatore**, dopo che il nodo è già
  installato e raggiungibile, nel momento in cui si è pronti a
  copiare il comando fresco dal portale — stessa disciplina già
  applicata alla chiave SSH: nessun segreto/identità mai hardcoded o
  committato nel repo.

## 2026-08-20 — Implementazione

Nuovo script standalone `postinstall/install-vastai-host.sh`,
deliberatamente **escluso** dalla sequenza automatica di `setup.sh` (non
è una `phaseN_...()` chiamata da `main()`, ma uno script separato
copiato comunque sul target dalla stessa infrastruttura late-commands
già esistente — `cp -r /cdrom/postinstall/. /target/opt/kickstart-berlin/`
copia già l'intera directory, il late-command `chmod +x` è stato esteso
da un singolo file (`setup.sh`) a `*.sh` per coprire anche questo nuovo
script senza doverlo elencare esplicitamente).

- **Input**: `--command-file <path>`, mai un argomento diretto sulla
  riga di comando (resterebbe nella shell history in chiaro). Il file
  deve contenere esattamente il comando copiato dal portale.
- Il file viene letto e **distrutto immediatamente** dopo (`shred -u`,
  fallback `rm -f` se `shred` non disponibile) — nessun motivo di
  lasciare un'identità d'account valida un'ora più a lungo del
  necessario su disco.
- Il comando non viene mai stampato nei log (solo un messaggio generico
  "eseguo l'installer, comando non loggato").
- Verifica permessi root (`EUID -eq 0`) prima di procedere.
- Su fallimento dell'installer, rimanda l'operatore a
  `vast_host_install.log` (stessa indicazione della guida ufficiale,
  sezione Troubleshooting) invece di tentare una diagnosi automatica —
  il contenuto/formato di quel log non è documentato nella guida.

`scripts/build-iso.sh`: il nuovo script non ha placeholder, copiato
così com'è nello staging dell'ISO (prima mancava — build-iso.sh copiava
esplicitamente solo `setup.sh` e il file `.service`, non l'intera
directory `postinstall/` del repo).

## 2026-08-20 — Cosa è stato verificato

**Verificato in sandbox** (interamente, nessuna dipendenza di rete
esterna: lo script non contatta mai la rete da solo, esegue solo il
comando fornito):
- `shellcheck` pulito, sintassi bash valida.
- Percorso `--command-file` mancante: errore chiaro.
- Percorso file non trovato: errore chiaro.
- Percorso file vuoto: errore chiaro.
- Percorso "felice" con un comando fittizio (`echo`, non il vero
  installer Vast.ai): eseguito con successo, e soprattutto confermato
  che il file col comando viene **davvero distrutto** subito dopo
  l'uso, non lasciato su disco.

**Non verificabile in sandbox** (per costruzione, non un limite
temporaneo): il vero comando d'installazione Vast.ai richiede un
account host reale e loggato — non è qualcosa che si possa simulare o
precostruire. Da testare quando l'utente fornirà un comando reale
copiato dal portale, sulla VM Azure o sulla Z8.

## 2026-08-20 — Percorsi sintetici confermati su host reale (VM Azure)

Nessuna dipendenza di rete/account in questi percorsi (lo script non
contatta mai la rete da solo), quindi rieseguibili identici fuori dal
sandbox — su VM-TEST2, con lo script vero (non uno stub):

1. `--command-file` mancante → `usage` + errore chiaro, exit 1.
2. File non trovato → errore chiaro, exit 1.
3. File vuoto → errore chiaro, exit 1, **e il file viene comunque
   distrutto** (la `shred -u`/fallback `rm -f` avviene prima del
   controllo di vuotezza nel codice — confermato che è così anche nella
   pratica, non solo leggendo la sorgente).
4. Eseguito senza `sudo` → controllo `EUID -eq 0` blocca correttamente
   con errore chiaro, exit 1.
5. Percorso felice con un comando finto (`echo "..."; hostname`):
   eseguito con successo (exit 0), il comando reale non è mai stampato
   nei log (solo un messaggio generico), e il file col comando è
   **confermato distrutto** dopo l'uso (`ls` → "No such file").

Nessun bug trovato: comportamento identico a quanto già validato in
sandbox con lo stub, ora confermato con il binario/ambiente reale.

**Resta non testabile senza un comando reale** (per costruzione, non un
limite temporaneo): l'installazione effettiva del daemon Vast.ai
richiede un comando account-specifico copiato da
`cloud.vast.ai/host/setup` (valido 1 ora) — va fornito dall'utente
quando pronto a testare il listing reale.

## 2026-08-23/24 — Comando reale su hardware fisico (Z8): listing riuscito, 4 bug trovati

Primo test in assoluto con un comando d'installazione **reale** (non un
account host, non VM di sviluppo) — sulla Z8, dopo il primo boot
documentato in `logbook_first_boot.md`. L'installer Vast.ai non è lo
"one-liner" descritto dalla guida ma un **wizard TUI interattivo a
schermo intero** (`host-installer-wizard-linux-x86_64`, scaricato da
`s3.amazonaws.com/public.vast.ai/`, 10 step: Welcome → NVIDIA/CUDA →
System check → Network → Network speed → Ports → Storage → Review →
Installing → Rentability) — non pilotabile alla cieca via SSH non
interattivo (primo tentativo bloccato allo step "Welcome" per questo
motivo, vedi sotto). Va lanciato dall'operatore in un terminale
interattivo vero, non da un agente headless.

**Esito finale**: macchina **listata con successo** sul portale
(`berlin-3eie`, machine ID `148447`, 1x RTX 3090, stato iniziale
`Unverified`/`Not Listed` — normale a questo stadio, si risolve con
l'uso/il self-test). `install-vastai-host.sh` stesso ha funzionato
esattamente come progettato (file col comando letto e distrutto,
comando mai loggato) — **tutti i problemi trovati sono nell'installer
ufficiale Vast.ai stesso** (il binario scaricato da `install-wizard`,
non il nostro wrapper), scoperti perché è la prima volta che gira su
questo stack (ESX-style Datastore, `/var/lib/docker` come symlink) e su
questo hardware.

### Bug 1 — `os.rename()` fallisce su `/var/lib/docker` symlink

`docker_install()` nell'installer Vast.ai (`/home/admin/install`, riga
1023) fa `os.rename('/var/lib/docker/', '/var/lib/docker-temporarily-renamed/')`
per spostare via l'installazione Docker esistente prima di reinstallare
da zero. Il **trailing slash** sul path del symlink causa
`NotADirectoryError` in Python/POSIX (rename su un path
symlink-con-slash-finale richiede che sia una directory vera, non un
link) — la nostra architettura ESX-style (`/var/lib/docker` come
symlink verso il Datastore, Fase 3) non è un caso gestito
dall'installer ufficiale. Nessun dato toccato (l'eccezione avviene
*prima* di spostare qualunque cosa), ma Docker viene fermato
(`systemctl stop docker`) e l'intero installer abortisce.

**Fix applicato manualmente sul nodo**: rimosso il symlink, ricreata
`/var/lib/docker` come directory vuota reale (`0710 root:root`) —
l'installer la sposta via senza problemi (è vuota, costa nulla) e
reinstalla Docker fresco lì. **Non ancora automatizzato in
`install-vastai-host.sh`** (vedi Prossimi passi).

### Bug 2 — conflitto `dpkg` su `/etc/docker/daemon.json`

Il pacchetto `nvidia-docker2` (installato dall'installer come parte del
setup Docker) porta un proprio `/etc/docker/daemon.json` di default.
Il nostro `daemon.json` esiste già (scritto da `phase3_docker_storage()`/
`phase4_nvidia_driver()`, con `data-root` sul Datastore e il runtime
NVIDIA) — `dpkg` rileva il conffile modificato e chiede
interattivamente Y/I/N/O/D/Z, bloccandosi in attesa di input che non
arriva (l'installer non passa `DEBIAN_FRONTEND=noninteractive` alle sue
chiamate `apt-get`/`dpkg`).

Confrontato il default del pacchetto (estratto dal `.deb` in cache,
`dpkg-deb -x`) con il nostro:

```json
// pacchetto nvidia-docker2 (default)
{ "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] } } }
// il nostro (scritto da phase3/phase4)
{ "data-root": "/grastorp/volumes/datastore/docker",
  "runtimes": { "nvidia": { "args": [], "path": "nvidia-container-runtime" } } }
```

Nessun conflitto funzionale reale: il pacchetto non sa nulla del
`data-root` (non lo tocca), unica discrepanza `args` vs `runtimeArgs`
(entrambi lista vuota, innocuo — il passthrough GPU nei container era
già confermato funzionante con la nostra versione prima di questo
test). **Tenere la nostra versione è la scelta corretta.**

**Fix applicato manualmente**: `dpkg --force-confold --configure -a`
(completa la configurazione mantenendo il nostro file, senza prompt).
**Non ancora automatizzato** in `install-vastai-host.sh`.

### Bug 3 — lo step "Storage" del wizard crea un file XFS loop-mounted sul disco di root

Allo step "Storage" (selezione del device per i dati Docker/container),
il wizard non usa la partizione scelta direttamente: crea un **file XFS
sparse loop-mounted** (`/var/lib/docker-loop.xfs`, 81.3GB, montato via
`/dev/loop0` su `/var/lib/docker`). In un run, questo file è finito
sulla partizione di **root** (`pmem0s2`, solo 98GB totali) invece che
sul device effettivamente selezionato nel wizard (`pmem0s3`, il
Datastore) — esattamente il rischio che l'architettura Datastore di
Fase 2/3 voleva evitare (Docker che riempie il disco di sistema).
Non chiaro se sia un comportamento sempre così o solo in questo run
particolare (non riprodotto a fondo, priorità data a sbloccare
l'installazione).

Dato che il nostro `daemon.json` reindirizza già `data-root` altrove,
questo loop-mount risultava completamente inutilizzato (`lsof` vuoto) —
puro spreco di spazio, nessun dato reale a rischio.

**Fix applicato manualmente**: `systemctl stop docker`, `umount
/var/lib/docker`, rimosso il file sparse, `/var/lib/docker` ricreata
come directory vuota reale. **Non automatizzabile in modo ovvio** (è
l'installer stesso a decidere di creare questo loop file, non un nostro
step) — da tenere presente come problema noto piuttosto che da
"correggere" nel nostro codice.

### Bug 4 — lock `dpkg` conteso da un `apt-get` esterno

Un tentativo dell'installer è fallito con `E: Could not get lock
/var/lib/dpkg/lock-frontend` — un `apt-get` di qualcun altro (PID
diverso, probabilmente innescato dal cambio di rete del nodo durante
questa sessione, non i timer schedulati regolari di
`apt-daily.timer`/`apt-daily-upgrade.timer` che erano lontani nel
tempo) teneva il lock. Transitorio (il processo era già terminato al
momento della diagnosi), ma con più tentativi ravvicinati del wizard il
rischio di ricapitare è concreto.

**Fix applicato manualmente**: `systemctl mask apt-daily.timer
apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service`
per il resto del collaudo. **Non ancora automatizzato**.

### Tecnica utile per collaudi futuri: dump del framebuffer console

Per verificare cosa il wizard TUI mostrava realmente senza affidarsi
solo agli screenshot dell'utente, utile in generale per qualunque cosa
scriva sulla console fisica (vedi anche issue #27): `sudo cat
/dev/vcs1` (framebuffer testuale) e `/dev/vcsu1` (variante
Unicode-aware) dumpano il contenuto reale dello schermo del tty
indicato.

## 2026-08-24 — Fix live sulla Z8 reale: Docker Root Dir era sul loop-file di root (Bug 3), non sul Datastore

Durante una domanda dell'utente ("Docker Root Dir dove gira? è conforme
col setup originale di vast.ai o l'abbiamo modificato noi dopo?"),
ispezione live del nodo (`docker info`, `mount`, `blkid`, `/etc/fstab`)
ha rivelato che **Bug 3** (il file XFS loop-mounted che lo step
"Storage" del wizard Vast.ai piazza sulla partizione di root — già
documentato sopra come "non automatizzabile, problema noto, non
gestito") era ancora presente e attivo su questo nodo, con conseguenze
più serie del previsto:

- `/var/lib/docker` era una directory reale con `/var/lib/docker-loop.xfs`
  (81.3GB, 33G occupati) montato sopra via una riga in `/etc/fstab`
  (`loop,rw,auto,pquota`) — **non** il symlink verso il Datastore che
  `phase3_docker_storage()` dovrebbe garantire.
- **Scoperta più importante**: `daemon.json` in realtà indicava
  correttamente `data-root: /grastorp/volumes/.../docker` (il Datastore
  — probabilmente scritto dal postflight di `install-vastai-host.sh`,
  che forza sempre `data-root` sul Datastore indipendentemente dal
  merge) e `docker info` confermava quel path come "Docker Root Dir"
  reale. Ma quella directory conteneva solo 241K — nessun `overlay2`,
  nessun dato reale — mentre `docker images` mostrava comunque 6
  immagini reali (pytorch, vastai/test:*, ecc.) per un totale di ~33G.
  **Causa**: `/etc/containerd/config.toml` ha `root =
  "/var/lib/docker/containerd/"` **hardcoded**, mai toccato né da
  `phase3_docker_storage()` né da `install-vastai-host.sh` — è lì che
  containerd (il vero motore che scarica e tiene i layer immagine,
  invocato da `dockerd` via `--containerd=/run/containerd/containerd.sock`)
  teneva il grosso dei dati, sul loop-file di root, **indipendentemente**
  da dove puntava `data-root` di Docker. La configurazione
  dell'architettura Datastore-symlink di Fase 2/3, in pratica, non
  stava redirigendo la maggior parte dello spazio disco usato da Docker
  — solo i metadati propri di `dockerd` (piccoli). Aperta issue #41 per
  estendere l'automazione a containerd (vedi sotto).

### Fix live eseguito (su richiesta esplicita dell'utente, non nel repo)

Migrazione manuale via SSH, **verso il disco WDC** (`/dev/sda1`,
465.8G, XFS già formattato, completamente libero — confermato prima di
scrivere: i "9G usati" iniziali mostrati da `df` erano solo overhead
XFS, non dati preesistenti) invece che verso il Datastore esistente su
PMem (scelta esplicita dell'utente, via AskUserQuestion: vuole Docker
fuori dalla PMem, non solo fuori da root):

1. Montato `/dev/sda1` su `/mnt/wdc-docker` (riga persistente in
   `/etc/fstab` per UUID).
2. Fermati `docker` e `containerd`.
3. Copiati sia `/var/lib/docker/containerd` (i dati reali, 33G) sia il
   contenuto del Datastore `.../docker/` (i metadati Docker, 241K) in
   `/mnt/wdc-docker/docker/`.
4. Aggiornati `data-root` in `daemon.json` e `root` in
   `containerd/config.toml`, entrambi su `/mnt/wdc-docker/docker`
   (backup `.bak-<timestamp>` di entrambi i file lasciati sul posto).
5. Smontato il loop-file, riga fstab commentata, `/var/lib/docker`
   ricreato come symlink verso `/mnt/wdc-docker/docker` (stessa
   convenzione del repo).
6. Riavviati `containerd` poi `docker`. Verificato: `docker info` →
   root dir corretto, tutte le 6 immagini presenti, `vastai.service`/
   `vast_metrics.service` mai interrotti.
7. **Prima di cancellare il vecchio loop-file** (82G, su richiesta
   esplicita dell'utente "solo se siamo sicuri che la copia sia
   sicura"): rimontato in sola lettura su un mountpoint separato,
   `diff -rq` fra vecchio e nuovo `containerd/` — nessun file "Only in
   old" (nulla mancante), le uniche differenze reali erano i due
   database attivi di containerd (`meta.db`,
   `snapshotter.../metadata.db`, entrambi scritti dal daemon da quando
   è ripartito — atteso), conteggio file 116430 (vecchio) vs 116438
   (nuovo, +8 attività normale post-riavvio). Cancellato solo dopo
   questa verifica positiva. Root passato dal 44% (41G) al 9% (7.8G) —
   82G liberati sulla PMem.

### Effetto collaterale scoperto: la dashboard Vast.ai mostrava PMem etichettata come "Western WDC"

L'utente ha notato sulla console Vast.ai un disco "Western WDC" a
"2268 MB/s" — impossibile per un WD5000AAKS SATA 7200RPM reale (~150
MB/s). Confermato in `kaalia.log`: le righe periodiche
`update_image_cache() diskspace:81.3GB` combaciano esattamente con la
dimensione del vecchio loop-file (allora su PMem), e `send_mach_info.log`
mostra che il daemon lancia `fio` per il benchmark di banda inviato a
Vast.ai — quindi il benchmark misurava l'I/O di dove Docker teneva
davvero i dati (PMem, via il loop-file), ma la dashboard lo etichettava
col nome del modello disco "Western WDC" in modo fuorviante (probabile
mismatch fra il device realmente bendato e il device il cui nome
modello viene riportato, legato proprio al nostro setup non standard
con root su PMem). Da riverificare dopo il prossimo benchmark
automatico di Kaalia: atteso un valore molto più basso (~100-150 MB/s,
coerente con lo specifico reale del WDC) ora che Docker vive
genuinamente lì.

### Non ancora fatto

- Non toccati né `nvme0n1` (MZ1L2960HCJR, ancora NTFS/Windows) né
  `nvme1n1` (altro NVMe, ancora NTFS/Windows) — esplicitamente esclusi
  dalla richiesta dell'utente in questo fix live.
- Questo fix è **manuale, non nel repo**: un futuro reinstall da zero
  di questo nodo (già pianificato, vedi CLAUDE.md) userà comunque
  `--disk-serial`/`--datastore-disk-serial` per pinnare correttamente i
  ruoli dei dischi fin dall'inizio — il fix live qui sopra è
  un'interim fix per lo stato attuale, non un sostituto di
  quell'automazione.
- Issue #41 aperta per estendere `phase3_docker_storage()`/
  `install-vastai-host.sh` a gestire anche `/etc/containerd/config.toml`
  per i futuri install — senza quel fix, qualunque nuovo nodo avrebbe
  lo stesso problema (Datastore-symlink che redirige solo i metadati
  Docker, non i dati reali).

## Prossimi passi

- [x] Verificare i percorsi sintetici (validazione argomenti,
      distruzione del file) su un host reale — confermato in precedenza.
- [x] Testare con un comando reale copiato da `cloud.vast.ai/host/setup`
      su hardware fisico (Z8) — **confermato sopra, macchina listata**
      (ID 148447).
- [ ] **Automatizzare in `install-vastai-host.sh`** i 3 fix ripetibili
      trovati sopra (Bug 1, 2, 4): mascherare i timer `apt-daily*`
      prima di lanciare l'installer; convertire temporaneamente
      `/var/lib/docker` da symlink a directory vuota reale prima, e
      migrare i dati reali risultanti nel Datastore dopo (stessa logica
      già idempotente di `phase3_docker_storage()`); mettere da parte
      `/etc/docker/daemon.json` prima (evita il prompt `dpkg` a monte
      invece di doverlo risolvere a valle). **Non ancora implementato
      né testato end-to-end** in questa sessione — solo i singoli passi
      manuali sono stati verificati uno per uno.
- [ ] Rifare un collaudo completo con l'automazione sopra, quando
      pronta — idealmente sulla stessa Z8 dopo il prossimo reinstall da
      zero pianificato con l'utente.
- [ ] Fase 10 (CLI `vastai`) già confermata funzionante e autenticabile
      (vedi `logbook_first_boot.md`); Fase 11 (self-test) ora ha un
      `machine_id` reale (148447) su cui operare — riprenderla.
- [ ] Aprire/aggiornare la PR con questi fix quando l'automazione sopra
      è implementata.

## 2026-08-25 — Fix strutturale del gap containerd (issue #41), implementato

Il gap containerd descritto sopra ("2026-08-24 — Fix live sulla Z8
reale"/issue #41) aveva solo un fix manuale sul nodo, mai portato nel
repo. Implementato ora:

- **`configure_containerd_storage()`** in `postinstall/setup.sh`,
  chiamata da `phase5_docker()` subito dopo l'installazione di
  Docker/containerd (non da `phase3_docker_storage()`: containerd non
  esiste ancora a quel punto della sequenza, e scrivere
  `/etc/containerd/config.toml` prima che il pacchetto `containerd.io`
  lo generi a install-time rischierebbe un conflitto dpkg sul
  conffile). Root puntato su `${DOCKER_DATA_ROOT}/containerd` (stessa
  directory di `data-root`, sottodirectory dedicata).
- Stessa logica replicata nel `_postflight()` di
  `install-vastai-host.sh`: l'installer Vast.ai reinstalla
  `docker-ce`/`containerd.io` come parte del proprio wizard "Storage",
  che rigenera `config.toml` col default di sistema — va quindi
  ricorretto dopo l'installer, non solo prima.
- **Editing testuale mirato, non un parser TOML completo** (la stdlib
  Python ha solo `tomllib` in lettura, non in scrittura, e non c'è
  garanzia che un pacchetto `toml`/`tomli_w` sia disponibile
  sull'host): sostituisce solo la riga top-level `root = "..."`,
  lasciando intatto il resto del file. **Verificato in sandbox** con 4
  casi sintetici (file assente, file con `root` top-level da
  sostituire, riesecuzione idempotente sullo stesso valore, file con un
  `root` annidato sotto `[plugins."io.containerd.grpc.v1.cri"]` — stesso
  nome di chiave, sezione diversa): il regex `^root\s*=...` ancorato a
  inizio riga senza indentazione non tocca la chiave annidata, la
  preserva intatta, e prepende la riga desiderata in testa al file.
  Import interessante da CLAUDE.md direttiva #4: proprio questo tipo di
  ambiguità (due chiavi con lo stesso nome a livelli diversi) è la
  classe di bug che un test in sandbox può intercettare anche senza
  containerd reale disponibile.
- **Regression test aggiunto** in `scripts/boot-test-qemu.sh` (CI):
  dopo il check esistente su `data-root`/gruppo `docker`, verifica che
  `/etc/containerd/config.toml` contenga la riga `root` corretta —
  gira automaticamente ad ogni `build-and-boot-test`.
- **Non verificabile per costruzione in questa sessione**: nessun host
  con GPU disponibile per un boot reale end-to-end (il QEMU test di CI
  non ha GPU, verifica solo che il file venga scritto correttamente
  dopo l'installazione Docker, non l'intero stack Fase 4/5/7 insieme).
  Da confermare al prossimo collaudo reale su Z8, idealmente insieme
  alla riverifica del fix PMem di PR #30 (nessuno dei due è stato
  ancora testato con un boot reale da zero).

## Prossimi passi (aggiornato 2026-08-25)

- [x] Fix strutturale containerd (issue #41) — implementato e
      verificato in sandbox, vedi sopra.
- [ ] Confermare il fix containerd con un boot reale su Z8 (nessuna GPU
      disponibile in questa sessione).
- [ ] I 3 fix Bug 1/2/4 dell'installer Vast.ai restano da verificare
      end-to-end come blocco unico (solo i singoli passi manuali sono
      stati confermati uno per uno) — invariato rispetto a sopra.

## 2026-08-27 — Primo guadagno reale confermato: il nodo funziona come host Vast.ai a tutti gli effetti

L'utente ha condiviso uno screenshot di `cloud.vast.ai/earnings/`
(machine `berlin-3eie`, ID `148447`): **$0.39 di earnings reali**
accumulati nella finestra 28/07-27/08/2026, dettaglio GPU $0.37 +
Storage $0.02 (Bandwidth/Referral $0.00). Il grafico mostra guadagni
registrati su (almeno) due giornate distinte verso la fine della
finestra (intorno al 22 e al 27/08) — coerente con la macchina messa
in manutenzione per 48h il 24/08 (vedi `logbook_first_boot.md`, "Stato
a fine sessione") e poi rientrata attiva.

**Perché conta**: non è un self-test o un run interno del daemon, è un
**noleggio reale da un account terzo** — la prima conferma che l'intero
stack (Fasi 1-8, 10, daemon Fase 7) funziona end-to-end come host
Vast.ai vero e proprio, non solo "listato con successo". Aggiornato lo
stato di riga 7 in `docs/collaudo-funzionale.md` di conseguenza.

**Cosa NON dimostra**: un rental reale da terzi passa per un
meccanismo/account diverso da quello usato dal self-test (che tenta il
noleggio con l'API key dello stesso host, da cui il blocco anti-self-
rent indagato sopra) — non c'è motivo di aspettarsi che sblocchi anche
`vastai self-test machine 148447`, resta un problema distinto. Non
riverificato in questa sessione se lo stato "unverified" della macchina
sia cambiato a seguito del rental.
