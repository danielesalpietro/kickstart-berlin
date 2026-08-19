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
      prima di ogni azione), da confermare con un test reale che invochi
      lo script due volte.
- [ ] Docker su storage driver reale (`overlay2`), non loopback — non
      verificabile fino alla Fase 5 (installazione Docker stesso); per
      ora verificato che `data-root` sia configurato correttamente
      *prima* che Docker esista.
- [ ] Spazio disco coerente con la partizione dati di Fase 2 — atteso
      per costruzione (stesso mountpoint), da confermare con un boot
      test reale.
- [ ] Nessuna estensione LVM prevista per questa fase (decisione sopra).

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

## Prossimi passi

- [ ] Boot test reale (sandbox o hardware) per confermare che il
      servizio post-install completi al primo boot e che
      `/var/lib/docker`/`daemon.json` risultino corretti.
- [ ] Verificare l'idempotenza invocando `postinstall/setup.sh` una
      seconda volta a mano sull'host installato.
- [ ] Confermare che `--dev-skip-security-updates` non comprometta il
      resto dell'autoinstall (test in corso).
- [ ] Aprire la PR quando confermato (sandbox); rimane comunque in sospeso
      la conferma su hardware reale, non disponibile fino al 23/08 (vedi
      sopra).
