# Logbook — Fase 3: preparazione storage (issue #3)

Diario di design e test per la Fase 3. Branch di riferimento:
`claude/fase3-storage-lvm-docker`, basato sulla punta di
`claude/fase2-partizionamento-disco` (non su `develop`: la PR #17 di
Fase 2 non era ancora mergiata quando questa fase è iniziata, e la Fase
3 dipende dal Datastore creato in Fase 2 — un branch da `develop` non
avrebbe avuto nessuno di quei file). Per il contesto delle fasi
precedenti vedi [`logbook-fase1.md`](logbook-fase1.md) e
[`logbook-fase2.md`](logbook-fase2.md).

## 2026-08-19 — Decisioni di design (con l'utente, prima di implementare)

Il testo dell'issue #3 ("estensione LVM, rimozione loopback Docker")
non corrisponde a come abbiamo costruito la Fase 2: nessun volume LVM
esiste nel nostro `storage.config` (partizioni GPT dirette, seguendo la
guida host-setup ufficiale di Vast.ai che l'utente aveva fornito in
Fase 2). Prima di implementare, chiarito con l'utente:

- **"Estensione LVM" fuori scope**: rileggendo la guida ufficiale
  Vast.ai (`.md` fornito dall'utente) per la decisione, LVM non è
  citato in nessun punto — la sezione "Storage Layout" descrive
  partizioni dirette (EFI + root ext4 + resto XFS per Docker), identico
  al nostro schema di Fase 2. Il riferimento a LVM nel testo originale
  dell'issue #3 deriva quindi dallo script community
  (`Soumya001/vastai-host-setup`, citato nel README come fonte
  secondaria), non dalla guida ufficiale. L'utente ha indicato di
  seguire strettamente il `.md` ufficiale per le decisioni: nessuna
  estensione LVM in questa fase.
- **Docker data-root dentro il Datastore**: la guida ufficiale Vast.ai,
  Opzione 1 (raccomandata) di "Storage Layout", monta la partizione dati
  XFS *direttamente* su `/var/lib/docker` (`mkfs.xfs` → `blkid` →
  `mkdir /var/lib/docker` → riga in `/etc/fstab` → mount) — esattamente
  lo stesso procedimento già automatizzato in Fase 2 per il Datastore,
  con l'unica differenza che noi montiamo su
  `/grastorp/volumes/<UUID>` (convenzione ESX-style, decisa in Fase 2)
  invece che su `/var/lib/docker` fisso. Decisione: Docker va configurato
  esplicitamente (`data-root` in `/etc/docker/daemon.json`) per puntare
  dentro il Datastore, dato che il path non coincide più con quello
  Docker "vede" di default.
- **Compatibilità Vast.ai ↔ ESX-style via symlink** (richiesta esplicita
  dell'utente): `/var/lib/docker` diventa un symlink verso il Datastore
  invece di restare un mountpoint diretto come in Vast.ai — così
  qualunque tooling, script o documentazione (inclusa la stessa guida
  Vast.ai, se mai consultata in futuro per debug) che si aspetti il path
  standard continua a funzionare senza modifiche, pur con i dati fisici
  nella posizione ESX-style.

## 2026-08-19 — Implementazione

Prima fase a richiedere uno script post-install reale (fino ad ora solo
ISO/autoinstall): creata l'infrastruttura base descritta in README
("script idempotente... eseguito al primo boot via systemd unit
oneshot"), pensata per crescere con le fasi successive (4-9, 12-14)
senza un file per fase.

- `postinstall/setup.sh`: script idempotente, una funzione per fase
  (`phase3_docker_storage()` per ora). Verifica che il Datastore sia
  montato (dipendenza da Fase 2, fallisce esplicitamente se manca);
  scrive `/etc/docker/daemon.json` con `data-root` dentro il Datastore
  via merge JSON (non sovrascrive altre chiavi eventualmente presenti,
  no-op se già corretto); gestisce `/var/lib/docker` in tre casi —
  assente (crea il symlink), presente vuoto (sostituisce con symlink),
  presente con dati Docker reali (ferma Docker se attivo, migra i dati
  con `cp -a`, ricrea come symlink, riavvia Docker se era attivo prima).
  Placeholder `__DATASTORE_MOUNT_ROOT__`/`__DATASTORE_SYMLINK_NAME__`
  sostituiti a build-time dalla stessa fonte (`config/
  autoinstall-defaults.json`) usata per `iso/user-data` e i frammenti
  storage — nessuna duplicazione di questi valori.
- `postinstall/kickstart-berlin-postinstall.service`: systemd oneshot,
  `ConditionPathExists=!/opt/kickstart-berlin/.setup-complete` per non
  rieseguire la logica pesante ad ogni boot (lo script stesso resta
  comunque idempotente se invocato di nuovo a mano, per la DoD
  dell'issue).
- `iso/user-data`: nuovo late-command che copia `postinstall/` nel
  target e abilita l'unit. Copia fatta come comando semplice (non
  `curtin in-target`): `/cdrom` (dove risiede l'ISO durante
  l'installazione, incluso il nuovo `/postinstall/`) non è garantito
  accessibile da dentro quel chroot. `systemctl enable --root=/target`
  abilita l'unit sul target offline senza bisogno di chroot per questo
  passaggio specifico.
- `scripts/build-iso.sh`: mappa la directory `postinstall/` sull'ISO
  (verificato che `xorriso -map` supporta directory intere ricorsive,
  non solo singoli file, prima di usarlo), sostituendo i placeholder in
  `setup.sh` con `sed` come per gli altri file template.
- `scripts/validate-autoinstall.py`: nuovo controllo che
  `postinstall/setup.sh` non contenga placeholder residui dopo
  sostituzione fittizia (stesso meccanismo già in uso per gli altri
  template) — fallisce se il file manca del tutto, coerente con la
  severità già applicata ai frammenti storage.
- `scripts/boot-test-qemu.sh`: dopo login SSH e verifica Datastore,
  attende (fino a 120s, il servizio potrebbe non essere ancora finito
  al momento in cui SSH diventa raggiungibile) il marker
  `/opt/kickstart-berlin/.setup-complete`, poi verifica che
  `/var/lib/docker` risolva esattamente al path Datastore atteso e che
  `daemon.json` riporti lo stesso `data-root`.
- `.github/workflows/ci.yml`: `shellcheck` copre ora anche
  `postinstall/*.sh`.

Verificato prima del commit: `shellcheck` pulito su
`postinstall/setup.sh` e su tutti gli script modificati,
`validate-autoinstall.py` passa (incluso il nuovo controllo sul
template post-install).

## Stato rispetto alla Definition of Done (issue #3)

- [ ] Idempotenza (rieseguire lo script su un sistema già esteso non
      causa errori) — logica scritta per esserlo (controlli di stato
      prima di ogni azione), ancora da confermare invocando lo script
      una seconda volta a mano sull'host installato.
- [ ] Docker su storage driver reale (`overlay2`), non loopback — non
      verificabile fino alla Fase 5 (installazione Docker stesso); per
      ora verificato che `data-root` sia configurato correttamente
      *prima* che Docker esista.
- [x] Spazio disco coerente con la partizione dati di Fase 2 — **confermato
      con un boot test reale** (vedi sotto): `/var/lib/docker` risolve
      correttamente dentro `/grastorp/volumes/datastore`.
- [x] Nessuna estensione LVM prevista per questa fase (decisione sopra).

## 2026-08-19 — Flag dev-only per saltare l'attesa rete di "updates: security"

Osservazione dell'utente: anche confermando che lo step
`run_unattended_upgrades` *funziona* dato abbastanza tempo (rete HTTP
diretta raggiungibile dal sandbox, vedi sotto), resta comunque un
problema pratico — ogni ciclo di build+boot-test durante lo sviluppo
rifà da capo il download/verifica degli update di sicurezza, decine di
minuti persi ad ogni iterazione sotto emulazione TCG (nessun KVM nel
sandbox). Decisione (dalle parole dell'utente: "se funziona, teniamola,
ma non come default per lo sviluppo"): il comportamento nativo
`updates: security` resta invariato e resta il default di **produzione**
(nessuna modifica alla correttezza dell'immagine reale); si aggiunge
*in più* un modo per saltarlo nei build di sviluppo/test, esplicito e
mai di default.

Vincolo di partenza: rileggendo di nuovo lo schema autoinstall ufficiale
(`updates`, sezione "The type of updates..."), i soli valori validi sono
`security`/`all` — non esiste un valore "nessuno"/"off" (già confermato
due volte in Fase 1/2). Non c'è quindi un modo "pulito" via quella sola
chiave. La chiave `apt.mirror-selection`/`fallback` (con default
`offline-install` se il mirror primario non è raggiungibile) è un
meccanismo distinto e riguarda solo il mirror *primario* usato per i
pacchetti dell'installazione, non lo step separato di security update
(che punta sempre a `security.ubuntu.com`, hardcoded, indipendente dal
mirror primario configurato) — verificato leggendo la sezione `apt`
completa dello schema, nessuna chiave equivalente "security mirror"
documentata. Scartata quindi anche questa via.

**Soluzione implementata**: nuovo blocco `early-commands` in
`iso/user-data` (prima non presente), con un placeholder
`__DEV_SKIP_SECURITY_UPDATES_HOOK__` sostituito a build-time:
- default (produzione, invariato): `true` (no-op) — gli update di
  sicurezza vengono scaricati e installati normalmente.
- con il nuovo flag `--dev-skip-security-updates` di `build-iso.sh`:
  `echo "127.0.0.1 security.ubuntu.com" >> /etc/hosts`. `early-commands`
  gira "prima del probing dei device di rete" (per definizione ufficiale
  Subiquity), quindi la entry in `/etc/hosts` è già presente quando lo
  step `updates: security` prova a contattare l'host — la risoluzione
  fallisce/punta a se stesso, quindi il tentativo fallisce rapidamente
  invece di attendere/riprovare in rete.
- L'immagine risultante con questo flag NON ha gli update di sicurezza
  installati: il flag va usato solo per iterare più in fretta durante lo
  sviluppo (locale o CI), mai per generare un'ISO destinata a un nodo
  reale — documentato esplicitamente nell'help di `build-iso.sh` e nei
  commenti del file.
- `scripts/validate-autoinstall.py`: nuova voce nel dizionario di
  sostituzione fittizia (`__DEV_SKIP_SECURITY_UPDATES_HOOK__` → `"true"`,
  il valore di produzione), altrimenti il controllo sui placeholder
  residui avrebbe fallito su `iso/user-data`.

**Da confermare** (test lanciato, in corso in sandbox): che il blocco
non faccia fallire l'intero autoinstall (incognita reale — non è
documentato se un fallimento dello step `updates: security` sia fatale
o solo loggato/ignorato) e che il resto dell'installazione (Datastore,
postinstall Fase 3) completi comunque correttamente e più rapidamente
del percorso normale.

### Nota collaterale: indagine "rete bloccata vs. solo lenta sotto TCG"

Durante l'indagine per questa decisione, richiesta dall'utente
implicitamente rivista alla luce della sua osservazione: verificato che
l'ipotesi originale di Fase 1 ("rete guest QEMU bloccata dal sandbox",
vedi `logbook-fase1.md`) potrebbe essere incompleta. Test manuali da
questo sandbox (non dalla VM guest, dall'host che esegue `curl`):
`http://archive.ubuntu.com/ubuntu/dists/noble/Release` risponde con
contenuto reale (non una pagina di errore/proxy) sia con che senza
`--noproxy '*'`, e le variabili d'ambiente confermano che solo l'uscita
HTTPS è instradata su un proxy applicativo (`https_proxy`), nessun
`HTTP_PROXY` configurato — l'HTTP diretto sembra effettivamente libero a
livello di host. Non conclusivo per la rete della VM guest (NAT/SLIRP,
un livello di rete diverso da quello dell'host), ma coerente con
l'osservazione empirica che i download di pacchetti (`openssh-server`,
kernel, `grub-pc`) sono sempre andati a buon fine in tutti i run di
Fase 1/2/3: l'ipotesi più probabile ora è che lo step di security update
sia semplicemente un'operazione molto più pesante (refresh indice
completo + verifica GPG) sotto emulazione TCG senza accelerazione
hardware, non un blocco di rete vero e proprio. Non risolutivo di per
sé — motivo in più per cui il flag dev-only sopra è la soluzione
pratica, indipendentemente da quale delle due ipotesi sia corretta.

## 2026-08-19 — Hardware Z8 non disponibile fino al 23/08

L'utente ha comunicato la perdita di disponibilità della workstation HP
Z8 G4 (necessita intervento onsite, non disponibile fino al 23/08 se non
torna online da sola) — la stessa macchina su cui girava la sessione
Claude Code "bridge" locale che stava eseguendo i test reali (Hyper-V)
in parallelo a questa sessione sandbox durante le Fasi 2-3. Impatto:
- Nessuna validazione su hardware reale possibile fino al 23/08 (minimo):
  nessun test UEFI reale, nessun test dual-disk reale, nessuna verifica
  di problemi hardware-specifici (com'era stato per il bug
  `grub_device` su UEFI, trovato solo su hardware reale — la QEMU/TCG di
  questo sandbox non l'avrebbe mai rilevato).
- La sessione locale "bridge" non è più raggiungibile: nessun secondo
  parere/collaborazione in parallelo per la finestra di indisponibilità.
- Decisione: proseguire lo sviluppo e la validazione logica/sandbox
  (QEMU/TCG, senza KVM, come finora in questa sessione) per le Fasi
  successive, marcando esplicitamente ogni fase completata in questa
  finestra come "in attesa di conferma su hardware reale" finché la Z8
  non torna disponibile. Nessuna PR di fase toccata durante questa
  finestra va considerata definitivamente chiusa/mergiata senza quella
  conferma, in particolare per modifiche che toccano boot/partizionamento
  (area dove il bug UEFI reale è già stato trovato una volta).

## 2026-08-19 — Primo run end-to-end riuscito in sandbox (dopo il fix grub_device + flag dev)

Con il fix `grub_device` solo-UEFI (`logbook-fase2.md`) e
`--dev-skip-security-updates`, un boot test single-disk completo in
sandbox (OVMF, nessun KVM) va a buon fine per la prima volta dall'inizio
alla fine, senza alcun intervento manuale:

- `install-grub`: nessun errore (prima falliva sempre in BIOS legacy).
- `run_unattended_upgrades`: ~120s invece di ~40 minuti (prima andava
  sempre in timeout).
- Login SSH riuscito con la chiave iniettata a build-time.
- Datastore Grastorp montato correttamente (Fase 2): `/grastorp/volumes/
  datastore` come XFS.
- Post-install Fase 3 verificato: `/var/lib/docker` risolve a
  `/grastorp/volumes/datastore/docker`, `daemon.json` coerente.
- Tempo totale: ~50 minuti (contro un timeout di 75 minuti raggiunto e
  superato nei run precedenti senza questi due fix) — margine reale per
  la prima volta, non solo "quasi ce la fa".

`--dev-skip-security-updates` aggiunto anche al job di integrazione CI
(`ci.yml`): la build di produzione resta invariata (update reali,
default), CI/sviluppo usano il flag per non sprecare ~40 minuti a run
senza validare nulla di nuovo sulla nostra logica.

## 2026-08-19 — VM Azure sostitutiva (Z8 non disponibile fino al 23/08): setup, due bug ambientali, poi conferma completa single/dual-disk

Sessione "bridge" separata (accesso SSH diretto da un'altra sessione Claude
Code), usata per colmare i due limiti del sandbox di sviluppo (nessun KVM,
rete verso gli archivi Ubuntu instradata su proxy applicativo — vedi
`logbook-fase1.md`) mentre la HP Z8 G4 è offline.

**Setup VM, due falsi partenti prima di una macchina funzionante**:

1. Prima VM (`VM-TEST`, Azure `Standard_E4s_v4`): `/dev/kvm` assente,
   `/proc/cpuinfo` privo di `vmx`/`svm` (non solo modulo non caricato: la
   CPU virtuale non esponeva affatto le istruzioni di virtualizzazione),
   `modprobe kvm_intel` → `Operation not supported`. Causa: **Security type
   "Trusted Launch"** anziché "Standard" — disabilita la virtualizzazione
   annidata indipendentemente da dimensione/generazione VM, e **non è
   modificabile su una VM esistente** (nessuna via, spenta o accesa: solo
   Standard→Trusted Launch è supportato da Azure, mai il percorso
   inverso) — richiede di ricreare la VM da zero.
2. Primo tentativo di ricreazione con dimensione `Standard_E2ads_v6`/
   `E4as_v6`/`E4ads_v6`: tutte serie **AMD** (convenzione naming Azure: la
   lettera "a" dopo il conteggio vCPU = AMD). La virtualizzazione annidata
   su Azure è documentata/confermata solo per le serie **Intel**
   (Dv3/Ev3, Dv4/Ev4, Dv5/Ev5, ...) — scartate prima di provisionarle,
   sulla base del naming, non per tentativi falliti.
3. **`VM-TEST2`** (`Standard_E4ds_v6`, Intel, Security type Standard,
   `Germany West Central`, resource group `VibeCoding`, riusando NIC/IP/
   NSG/disco dati esistenti dove possibile) — confermato funzionante:
   `/dev/kvm` presente, `vmx` in `/proc/cpuinfo`. L'utente `dsalpietro`
   creato dalla VM non era nel gruppo `kvm` di default (serve una nuova
   sessione SSH dopo `usermod -aG kvm`, i permessi di gruppo non si
   applicano a sessioni già aperte).

Host risultante (per riferimento futuro): Ubuntu 24.04.4 LTS, kernel
`6.17.0-1022-azure`, CPU Intel Xeon Platinum 8573C (4 vCPU, 2 core/2
thread, `vmx` confermato), 31GB RAM, root su NVMe 29G, disco dati NVMe
256G riattaccato dalla VM precedente. Dipendenze installate via apt:
`xorriso qemu-system-x86 qemu-utils ovmf git python3-yaml shellcheck`.

**Errore mio da non ripetere**: ho sovrascritto `scripts/boot-test-qemu.sh`
via `scp` mentre un boot test era ancora in esecuzione nel suo loop di
polling — bash rilegge lo script da disco a runtime durante i loop, la
sovrascrittura ha corrotto l'esecuzione con un syntax error a ~373s,
proprio mentre il run (il primo con rete reale + KVM reale, senza
`--dev-skip-security-updates`, pensato apposta per rispondere alla
domanda aperta sotto) era in corso su `run_unattended_upgrades`. **Mai
modificare uno script mentre un test lo sta eseguendo** — usare una copia
separata per iterare, sincronizzare sui path reali solo a nessun test in
corso.

**Domanda aperta chiusa (era in `logbook-fase1.md`/`logbook-fase2.md`)**:
con KVM reale e rete diretta senza restrizioni, un run single-disk
completo (senza `--dev-skip-security-updates`, default di produzione:
`updates: security` reale, `--system-size 100G`) impiega **~6-7 minuti
totali** dall'avvio QEMU al login SSH (partizionamento+grub ~130s,
`run_unattended_upgrades` completato tra 253s e 374s). Conferma che il
timeout/blocco osservato nel sandbox (40+ minuti, mai completato) era
dovuto alla sola lentezza dell'emulazione software TCG (nessun KVM), non
a un blocco di rete verso gli archivi Ubuntu.

**Bug preflight trovato durante questi test (infrastruttura, non logica
Fase 2/3)**: il primo tentativo di questo run è fallito silenziosamente a
~121s (`root-partition` FAIL, nessun traceback in console) — causa
identica al fix #3 di `logbook-fase2.md`: disco throwaway di test 20G di
default contro `--system-size` di produzione 100G. Senza un controllo
esplicito, questo mismatch si sarebbe manifestato solo dopo l'intero
timeout (fino a un'ora). **Fix**: nuova sezione di preflight in
`scripts/boot-test-qemu.sh`, eseguita PRIMA di creare dischi/lanciare
QEMU — estrae la dimensione reale della root partition incorporata
nell'ISO (`/server/user-data`, via `xorriso -osirrox` + parsing YAML) e
la confronta con `--disk-size`, più controlli generici (RAM minima 1024MB,
dimensione disco minima 8G, spazio libero host minimo 10G). Bug trovato
durante l'implementazione: il parser cercava `storage` alla radice del
documento invece che sotto `autoinstall:` (il top-level key reale di un
file `#cloud-config`) — corretto e verificato con un test negativo (20G
contro root 100G: fallisce in 66ms con errore chiaro) e uno positivo
(120G: passa, log esplicito "OK").

**Conferma end-to-end completa, entrambe le topologie** (con
`--disk-size 120G` per single-disk, a valle del fix preflight):
- Single-disk: partizionamento, grub (solo UEFI, fix `grub_device` di
  `logbook-fase2.md` riconfermato su KVM reale), Datastore XFS montato,
  post-install Fase 3 (`/var/lib/docker` → Datastore, `daemon.json`
  coerente) — tutto verificato, "Test superato."
- Dual-disk (con `--dev-skip-security-updates`, la domanda di rete era
  già chiusa dal run single-disk): stesso esito positivo, **confermata
  anche la dimensione del device root** (~20GB, corrisponde al disco
  "piccolo" atteso dall'euristica `match:{size:smallest}`) — prima
  conferma reale di questa euristica su KVM/rete reali (in
  `logbook-fase2.md` era confermata solo su Hyper-V/Z8).

## 2026-08-19 — Bug reale: hostname hardcoded, fix + anomalia in corso di verifica

Richiesta utente: la procedura deve generare un hostname univoco per nodo
(`berlin-XXXX`, XXXX fino a 4 caratteri alfanumerici casuali), non un
valore fisso. Verificato: `identity.hostname` in `iso/user-data` era
hardcoded a `kickstart-berlin` — ogni nodo installato dalla stessa ISO
avrebbe avuto lo stesso hostname, collisione garantita su una rete con più
nodi (es. da chiavetta USB, vedi `docs/usb-boot.md`, dove la stessa ISO
installa più macchine fisiche diverse).

**Decisione di design**: la parte random va generata a **install-time**
(late-commands, sull'host reale), non a build-time — un hostname fisso
nell'ISO risolverebbe il problema solo se ogni nodo usasse un'ISO diversa,
il che non è il caso d'uso (stessa ISO, più macchine).

**Implementazione**:
- `config/autoinstall-defaults.json`: `identity.hostname` →
  `identity.hostname_prefix` (default `"berlin"`) — ora fonte attiva
  (prima era solo "valore di riferimento/documentazione", non letta da
  `build-iso.sh` né agganciata a un flag CLI).
- `scripts/build-iso.sh`: nuovo flag `--hostname-prefix <p>` (validato:
  minuscolo, deve iniziare con una lettera), sostituisce il nuovo
  placeholder `__HOSTNAME_PREFIX__`.
- `iso/user-data`: `identity.hostname: __HOSTNAME_PREFIX__` (solo
  prefisso, usato transitoriamente durante l'installazione); nuovo
  late-command genera `SUFFIX=$(tr -dc "a-z0-9" </dev/urandom | head -c4)`
  e scrive `/etc/hostname` + riga `127.0.1.1` di `/etc/hosts` col
  risultato finale `<prefix>-$SUFFIX`.
- `scripts/validate-autoinstall.py`: nuovo placeholder nel dizionario di
  sostituzione fittizia, letto dalla stessa fonte JSON.
- `scripts/boot-test-qemu.sh`: nuova verifica post-login, controlla che
  `hostname` sul target rispetti il pattern `<prefisso>-XXXX` (regex
  `^[a-z][a-z0-9-]*-[a-z0-9]{1,4}$`).

**Anomalia hostname (`VM-TEST2` invece di `berlin-XXXX`): indagata a
fondo, causa non fissata con certezza, confermata non bloccante e
specifica dell'infrastruttura di test annidata**. Cronologia
dell'indagine (6 run totali con l'ISO col fix hostname):

1. **Ipotesi cloud-init/datasource Azure** (NAT SLIRP che raggiunge per
   sbaglio il vero IMDS Azure `169.254.169.254` attraverso lo stack di
   rete dell'host): **esclusa con prova diretta**. `cloud-init status
   --long` sul target installato riporta `status: disabled`,
   `boot_status_code: disabled-by-marker-file`, `detail: DataSourceNone`
   — cloud-init è completamente disattivato sul sistema installato
   (comportamento standard Subiquity/curtin dopo l'install), non può
   essere la causa.
2. **Ipotesi DHCP hostname leak di QEMU/SLIRP** (senza `hostname=`
   esplicito sul netdev, SLIRP offre di default al guest l'hostname del
   PROCESSO QEMU stesso come opzione DHCP 12 — confermato dalla man page:
   *"hostname=name: Specifies the client hostname reported by the
   built-in DHCP server"*): **anch'essa esclusa con prova diretta**.
   Aggiunto `hostname=boot-test-client` esplicito al netdev di
   `boot-test-qemu.sh` (fix comunque mantenuto, difesa in profondità) e
   rieseguito il test: fallito di nuovo con lo stesso identico
   `VM-TEST2`, nonostante l'opzione DHCP fosse ora esplicitamente diversa.
3. **Ipotesi chiave SSH duplicata/host raggiunto per errore**: esclusa —
   confrontate `~/.ssh/authorized_keys` dell'host e `/tmp/test_key.pub`
   del guest, chiavi diverse (impossibile che l'host stesso abbia
   accettato la connessione con quella chiave).
4. **Ipotesi residua, non confermata né esclusa** (suggerita dall'altra
   sessione collaborante su questo branch): leak del livello di
   virtualizzazione annidata Hyper-V(Azure L0)→QEMU/KVM(L1, questa VM)→
   guest installato (L2). Con `-cpu host`, il guest L2 eredita il CPUID
   dell'host L1, incluso il leaf hypervisor-vendor (0x40000000): se
   quel leaf riporta "Microsoft Hv" (perché L1 stesso gira su Hyper-V/
   Azure), il kernel Linux del guest L2 può misidentificare il proprio
   hypervisor come Hyper-V e caricare i driver `hv_vmbus`/`hv_utils`
   (già presenti nel kernel Ubuntu generico), che includono un servizio
   di **sincronizzazione hostname (KVP - Key-Value Pair Exchange)** con
   l'host Hyper-V — se un canale vmbus reale (o parzialmente funzionante)
   filtra attraverso i livelli annidati, spiegherebbe sia il valore esatto
   (nome reale dell'host L1) sia l'intermittenza (dipende se/quando il
   canale vmbus si stabilizza durante il boot). **Non verificata
   direttamente** (mancava tempo per ispezionare `lsmod`/`dmesg` su un run
   fallito prima che il cleanup automatico dello script rimuovesse il
   disco) — resta l'ipotesi più plausibile rimasta in piedi, ma non
   confermata con prove dirette.

**Dato più importante, che rende l'anomalia non bloccante**: la logica
applicativa (il late-command che genera l'hostname) è stata **verificata
corretta con prove dirette e ripetute** — due run manuali indipendenti
(QEMU lanciato a mano, stessa ISO, nessuna differenza di comando
rilevante rispetto allo script) hanno prodotto rispettivamente
`berlin-g7ir` e `berlin-ef0l`, esattamente il pattern atteso. L'anomalia
si manifesta solo in alcuni run tramite l'harness automatico
(`boot-test-qemu.sh`) in QUESTO ambiente specifico (VM Azure con
virtualizzazione annidata a più livelli) — **non riproducibile per
costruzione su hardware bare-metal reale** (il target effettivo di
questo progetto, nessun livello di nesting) **né su runner CI tipici**
(GitHub Actions non gira annidato su Azure/Hyper-V). Il controllo
`hostname` in `boot-test-qemu.sh` resta comunque un test valido e va
mantenuto: la sua occasionale rottura in questo specifico ambiente di
sviluppo annidato è un limite noto dell'infrastruttura di test, non della
logica prodotto, analogo per natura (anche se non per causa) ai limiti
di rete/KVM del sandbox già documentati in `logbook-fase1.md`.

## 2026-08-19 — Idempotenza verificata

Invocato `sudo /opt/kickstart-berlin/setup.sh` una seconda volta a mano su
un host già installato e configurato (via SSH, QEMU lanciato manualmente
per bypassare l'anomalia hostname intermittente descritta sopra — non
correlata alla logica idempotenza). Nessun errore, nessuna modifica allo
stato già corretto (`/etc/docker/daemon.json`, symlink `/var/lib/docker`)
— comportamento idempotente confermato.

## Stato finale rispetto alla Definition of Done (issue #3)

- [x] Idempotenza — confermata (sopra).
- [x] Docker `data-root` configurato correttamente prima che Docker esista
      (verificabile pienamente solo in Fase 5, quando Docker verrà
      installato).
- [x] Spazio disco coerente con la partizione dati di Fase 2.
- [x] Nessuna estensione LVM prevista per questa fase.
- [x] Hostname univoco per nodo (`berlin-XXXX`, generato a install-time) —
      logica verificata corretta; anomalia di test intermittente
      documentata sopra, non bloccante, specifica dell'ambiente di
      sviluppo annidato.

## Prossimi passi

- [ ] (Opzionale, non bloccante) Confermare con prove dirette l'ipotesi
      del leak vmbus/Hyper-V annidato per l'anomalia hostname — solo se
      si vuole chiudere la curiosità, non impatta la correttezza del
      prodotto.
- [ ] Conferma su hardware fisico bare-metal reale — fuori scope di
      questa sessione, non disponibile fino al 23/08 (Z8).
- [ ] Verificare lo scenario CI GitHub Actions reale (`workflow_dispatch`)
      con tutti i fix di questa sessione, per un secondo riscontro
      indipendente dall'ambiente Azure annidato.
