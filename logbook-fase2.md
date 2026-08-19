# Logbook — Fase 2: partizionamento disco (issue #2)

Diario di design e test per la Fase 2. Branch di riferimento:
`claude/fase2-partizionamento-disco`. Per il contesto della Fase 1
(ISO/autoinstall base) vedi [`logbook-fase1.md`](logbook-fase1.md).

## 2026-08-18 — Decisioni di design (con l'utente, prima di implementare)

- **Datastore path**: nessun path già definito da Grastorp altrove →
  default deciso qui, poi rivisto (vedi sotto) a convenzione ESXi-style
  su richiesta esplicita: `/vmfs/volumes/<UUID>` con symlink
  human-readable è il pattern VMware; per non promettere compatibilità
  con tooling VMware che qui non esiste (non gira ESXi), si usa un
  namespace proprio: `/grastorp/volumes/<UUID>` + symlink
  `/grastorp/volumes/datastore` → UUID. Nome symlink fisso ("datastore"),
  non parametrizzato a build-time (un solo datastore per nodo in questa
  fase).
- **Multi-disco/RAID — scope ristretto rispetto alla scelta iniziale**:
  la prima proposta fatta all'utente prevedeva due opzioni per gestire
  dischi extra oltre a quello di sistema; l'utente ha scelto
  esplicitamente "Opzione 1: un unico LVM datastore aggregando **tutti**
  i dischi extra in un solo volume group". Discutendo poi la ridondanza,
  è emerso che quella logica ("se N dischi extra, scegli il livello di
  ridondanza adeguato: RAID1/5/6 o EC") non è esprimibile in modo
  dichiarativo nello `storage.config` di Subiquity/curtin (azioni
  statiche, nessun costrutto condizionale sul conteggio dischi a
  runtime). **La soluzione implementata di conseguenza è più stretta
  della scelta LVM originale**: gestisce esattamente 1 o 2 dischi totali
  (`--disks 1|2`), senza alcuna aggregazione LVM e senza supporto per
  N>2 dischi extra — non solo la ridondanza, ma anche la semplice
  aggregazione multi-disco è stata rimandata. La ridondanza vera e
  propria resta demandata a uno script post-install dinamico (Fase 3,
  issue #3) dove la logica condizionale è banale in bash. Coerente con
  come Vast.ai stesso gestisce il proprio equivalente (`/var/lib/docker`
  su partizione singola o "RAID array" già pronto a monte — il loro
  installer non orchestra RAID).
- **Aperto, non risposto**: chiesto esplicitamente all'utente se per la
  ridondanza di Fase 3 preferisse mdadm+LVM+ext4 (RAID Linux standard)
  o ZFS RAIDZ (checksum end-to-end, utile contro il bitrot sui blob del
  Model Library) — domanda respinta ("aspetta prossima istruzione").
  **Resta da decidere prima di iniziare la Fase 3.**
- Riferimento primario usato per la conferma dello schema Vast.ai (EFI +
  root ext4 ≥80GB + resto XFS su `/var/lib/docker`, tre varianti manuale/
  auto/fallback loopback): guida host-setup ufficiale, fornita
  dall'utente.

## 2026-08-18 — Verifica schema autoinstall storage: doc ufficiale irraggiungibile dal sandbox, poi fornita dall'utente

Tentativi di raggiungere `canonical-subiquity.readthedocs-hosted.com` (e
mirror: `ubuntu.com/server/docs`, `web.archive.org`) via `WebFetch` da
questo sandbox: tutti bloccati dal proxy di rete dell'ambiente (stesso
limite già visto in Fase 1). Recuperata nel frattempo la doc di **curtin**
(il motore sottostante, non Subiquity-specific) via
`raw.githubusercontent.com/canonical/curtin` — utile ma non conclusiva
sulle estensioni Subiquity (`match` spec, sizing con percentuali).

L'utente ha fornito il PDF ufficiale ("Autoinstall configuration
reference manual") non raggiungibile dal sandbox. Estratto testo con
`pdftotext -layout` (via `poppler-utils`, installato per l'occasione) e
analizzata la sezione `storage`. Punti chiave confermati:

- **`match` spec** (azione `disk`, estensione Subiquity oltre curtin
  puro): chiavi supportate — `model`, `vendor`, `path`, `id_path`,
  `devpath`, `serial` (con globbing), `ssd: true|false`,
  `size: largest|smallest`. Chiave speciale `install-media: true`
  identifica il disco/chiavetta di boot dell'installer, **escluso
  automaticamente** dai match `ssd`/`size`.
- **Assegnazione dischi**: "Any disk action is assigned a matching
  disk – chosen arbitrarily from the set of unassigned disks if there
  is more than one, and causing the installation to fail if there is no
  unassigned matching disk." → conferma diretta che due azioni `disk`
  consecutive (`match: {size: smallest}` poi `match: {}`) assegnano
  dischi diversi per esclusione reciproca, e che uno storage.config
  scritto per 2 dischi **fallisce intenzionalmente** (fail-fast) su una
  macchina con un solo disco reale — da cui la scelta di due frammenti
  statici separati (`storage-single-disk.yaml` / `storage-dual-disk.yaml`)
  invece di un unico file "adattivo": non è possibile scriverne uno che
  si adatti dinamicamente al conteggio dischi nello YAML dichiarativo.
- **Sizing partizioni**: oltre alle unità assolute (`100G`) già note da
  curtin, Subiquity aggiunge supporto a percentuali (`size: 50%`) e al
  valore speciale `size: -1` ("riempi lo spazio restante" sull'ultima
  partizione di un device) — usato per la partizione Datastore in
  entrambe le topologie, elimina la necessità di calcoli.

Questa verifica ha confermato/corretto il piano proposto prima di
scrivere qualunque YAML — nessun tentativo alla cieca su un meccanismo
potenzialmente distruttivo (partizionamento disco), a differenza di
alcuni bug della Fase 1 scoperti solo a runtime.

## 2026-08-18 — Implementazione

- `config/autoinstall-defaults.json`: nuova fonte unica di verità per i
  default di build (versione Ubuntu, size partizione sistema, topologia
  dischi, parametri Datastore — filesystem/label/mount-root/nome
  symlink), su richiesta esplicita dell'utente ("tutti i parametri e
  scelte per l'auto-install andranno memorizzati in un file json"). Letta
  da `build-iso.sh` via `python3` (con `shlex.quote` per l'export sicuro
  come variabili shell); i flag CLI restano per override puntuali.
- `iso/storage-single-disk.yaml`, `iso/storage-dual-disk.yaml`: le due
  topologie statiche, con placeholder `__SYSTEM_PARTITION_SIZE__`,
  `__DATASTORE_FILESYSTEM__`, `__DATASTORE_LABEL__` sostituiti a
  build-time. Nessuna azione `mount` per la partizione Datastore nello
  storage.config: il mountpoint dipende dalla UUID generata da
  `mkfs.xfs` in quello stesso step, non prevedibile staticamente —
  montato invece via `late-commands` (stesso procedimento manuale
  documentato da Vast.ai per `/var/lib/docker`: `mkfs` → `blkid` →
  `fstab`, qui automatizzato) con la convenzione UUID+symlink decisa.
- `iso/user-data`: bug trovato e corretto in fase di scrittura, non a
  runtime — il placeholder `__STORAGE_CONFIG__` su una riga propria
  senza indentazione rendeva il *template* non valido come YAML a sé
  stante (scalare non chiave/valore a livello di mapping). Corretto a
  `storage: __STORAGE_CONFIG__` (placeholder come valore scalare,
  YAML-valido); lo script di build ora sostituisce prima il testo del
  placeholder sulla riga (lasciando `storage:`), poi accoda il
  frammento scelto con l'idioma sed `r`/`d` — stesso risultato, template
  sempre valido nel repo.
- `scripts/build-iso.sh`: nuovi flag `--system-size` e `--disks 1|2`
  (quest'ultimo seleziona il frammento storage e aggiorna anche l'help
  testuale con i default correnti letti dal JSON).
- `scripts/validate-autoinstall.py`: riscritto per validare, oltre al
  template `iso/user-data` (ora richiede che `storage` sia ancora il
  placeholder, non hardcoded), anche i frammenti `storage-*-disk.yaml`
  scoperti automaticamente nella stessa directory — sostituzione con
  valori fittizi, parsing YAML, verifica che ogni riferimento
  `device`/`volume` punti a un id già definito da un'azione precedente
  (l'ordine conta, per lo schema Subiquity), verifica `swap.size: 0` e
  presenza di un `format` ext4 per la root. Validato con successo su
  entrambe le topologie prima di qualunque build reale.
- `scripts/boot-test-qemu.sh`: nuovo flag `--disks 1|2` (crea N dischi
  virtio throwaway invece di uno fisso); dopo il login SSH, verifica
  aggiuntiva via `findmnt` remoto che `/grastorp/volumes/datastore`
  risolva a un mountpoint XFS reale (non solo che l'host sia
  raggiungibile).
- `.github/workflows/ci.yml`: il job di integrazione ora usa una
  matrice `disks: [1, 2]`, eseguendo build+boot separatamente per
  entrambe le topologie — replica il piano di test dell'issue #2
  ("scenario disco singolo e scenario doppio disco").

Verificato prima di procedere: merge dei frammenti simulato manualmente
per entrambe le topologie (placeholder sostituiti, YAML risultante
parsato, sequenza id delle azioni ispezionata) — struttura corretta in
entrambi i casi. `shellcheck` pulito su tutti gli script modificati.

## 2026-08-18/19 — Ciclo di test reali in sandbox cloud: 5 bug trovati e corretti

Stesso ambiente dei test di Fase 1 (container isolato, senza `/dev/kvm`,
rete verso gli archivi Ubuntu bloccata dal proxy del sandbox — vedi
`logbook-fase1.md`). Boot test in QEMU/TCG del solo scenario a 1 disco
(il 2 dischi richiede la stessa catena di fix, non ancora rieseguito
dopo l'ultimo fix — vedi prossimi passi).

**Nota (collaborazione in parallelo)**: durante questa serie di fix,
un'altra sessione ha lavorato in parallelo sullo stesso branch,
estendendo `scripts/boot-test-hyperv.ps1` con supporto a due VHD di
dimensione diversa (commit `39bb6d1`, `-DiskGB`/`-DiskGB2`). Il `git
push` di questa sessione è stato respinto (remote aggiornato nel
frattempo), risolto con `git pull --rebase`. Quel commit segnalava un
gap reale nel lato QEMU: `scripts/boot-test-qemu.sh --disks 2` creava
due dischi virtuali **della stessa dimensione**, quindi non esercitava
davvero l'euristica "disco più piccolo = sistema" di
`storage-dual-disk.yaml` (con dischi identici, `match: {size:
smallest}` è arbitraria). Fix (commit `6f69f53`): nuovo flag
`--disk2-size` (default 40G, contro i 20G del primo — stessi default
usati da `boot-test-hyperv.ps1` per coerenza tra i due script), con
errore esplicito se uguale a `--disk-size` invece di un test che
"passa" senza aver verificato nulla; aggiunto anche un controllo
informativo post-test sulla dimensione del device root per confermare
indirettamente che il sistema sia finito sul disco piccolo atteso.

1. **Label XFS troppo lunga** (segnalato dall'utente prima del primo
   boot test): `grastorp-datastore` (18 caratteri) supera il limite di
   12 per le label XFS — `mkfs.xfs -L` sarebbe fallito. Fix: label
   ridotta a `datastore` (9 caratteri). Aggiunto anche un controllo
   automatico dei limiti label-per-filesystem in
   `validate-autoinstall.py` (xfs:12, ext4:16, fat32:11), e i valori di
   sostituzione per la validazione ora si leggono da
   `config/autoinstall-defaults.json` invece che da una copia hardcoded
   nello script — la copia hardcoded era proprio il motivo per cui il
   primo fix del JSON non sarebbe stato comunque verificato in CI.

2. **Log seriale non persistito su fallimento**: il trap di cleanup di
   `boot-test-qemu.sh` rimuove `WORK_DIR` (quindi il log seriale) a fine
   script; su timeout l'unica diagnostica era una tail delle ultime 200
   righe, insufficiente per errori tardivi (tutto ciò che succede prima
   scorre via dalla finestra). Fix: il log completo viene copiato accanto
   all'ISO (`<iso>.serial.log`) prima della pulizia.

3. **Mismatch dimensione disco di test vs default di produzione**: con
   il fix del log completo, il primo run mostrava il partizionamento
   fermarsi silenziosamente dopo `root-partition` (nessun traceback in
   console, solo "An error occurred"). Causa: il disco throwaway di
   `boot-test-qemu.sh` è 20G di default, ma il default di produzione per
   `--system-size` è 100G (giusto per hardware reale, convenzione
   Vast.ai) — curtin non può creare una partizione root di quella
   dimensione su un disco più piccolo. Non un bug della logica
   storage.config: un mismatch tra default di produzione e dimensione
   dei dischi di test. Fix: CI e test locali passano ora esplicitamente
   `--system-size 10G` in fase di build. Approfittato per rimuovere
   anche `package_update`/`package_upgrade` da `iso/user-data`
   (chiavi cloud-init generiche non riconosciute a livello autoinstall
   da Subiquity, viste come warning "Unrecognized top-level key" negli
   stessi log — ridondanti con `updates: security` già presente).

4. **Nessun traceback reale disponibile per crash tardivi**: col fix
   #3, un run è arrivato molto più lontano — l'intero `storage.config`
   (inclusa la partizione/format del Datastore) si completa con
   successo, confermando che la logica di partizionamento della Fase 2
   funziona. Il run però crasha comunque subito dopo (`finish:
   subiquity/Install/install:` seguito immediatamente da un
   `ErrorReporter/install_fail`, presumibilmente in postinstall/
   late-commands, mai iniziato a tracciare prima del crash). La sola
   trace ad alto livello che Subiquity scrive sulla console
   (`start:`/`finish:`) non include mai il traceback reale, che finisce
   solo nel crash report (`/var/crash/*.crash`) e nel log interno di
   Subiquity — entrambi visibili solo dalla shell di recovery in cui
   l'installer cade dopo l'errore. Investimento infrastrutturale invece
   di continuare a indovinare alla cieca: la console seriale di
   `boot-test-qemu.sh` passa da `-serial file:...` (sola scrittura) a un
   chardev `socket` con `logfile=` (stesso log continuo di prima, ma ora
   anche collegabile). Nuovo `scripts/_qemu_serial_diag.py`: su rilevata
   shell di recovery, si connette al socket, preme invio, invia un
   comando che stampa crash report + coda del log Subiquity, salva
   l'output accanto all'ISO. Best-effort, non blocca lo script se fallisce.

5. **`xorriso` non rilevava un fallimento reale**: un run successivo ha
   riportato "ISO generata" (`build-iso.sh` exit 0) ma il file non
   esisteva. Causa root: lo scratchpad di questa sessione aveva
   accumulato ~15GB di ISO di test precedenti mai ripulite, esaurendo lo
   spazio disco disponibile; `xorriso` ha incontrato un problema di
   severità FAILURE ("Image size ... exceeds free space on media",
   "Image write cancelled") ma di default non traduce quella severità in
   un exit code non-zero — lo script ha proseguito come se tutto fosse
   andato bene. Fix: aggiunto `-abort_on FAILURE` all'invocazione
   xorriso (ora un problema di quella severità fa fallire il processo,
   intercettato da `set -e`) più un controllo indipendente che l'ISO
   generata esista e non sia più piccola dell'ISO sorgente. Pulito anche
   lo scratchpad.

**Nota generale**: nessuno di questi 5 bug riguarda la correttezza della
logica di partizionamento vera e propria (`storage.config`), che si è
dimostrata corretta al primo run reale che ha avuto la possibilità di
arrivarci (fix #3) — riguardano tutti l'infrastruttura di test
(diagnostica, gestione spazio disco, rilevamento errori) attorno ad essa,
scoperti proprio perché si è insistito a testare con hardware/rete reali
invece di fermarsi al "sembra corretto sulla carta".

6. **BIOS Boot Partition mancante** (trovato grazie alla diagnostica
   interattiva del punto 4, prima corretta perché catturava solo l'eco
   del comando — vedi fix separato): il run successivo arriva fino a
   curthooks e crasha lì. Il crash report completo (`Title: curthooks
   crashed with CurtinInstallError`) mostra il comando reale fallito:

   ```
   Command: ['unshare', '--fork', '--pid', '--mount-proc=/target/proc',
             '--', 'chroot', '/target', 'grub-install', '/dev/vda']
   Stderr: grub-install: warning: this GPT partition label contains no
           BIOS Boot Partition; embedding won't be possible.
   ```

   Su GPT, `grub-install` per la piattaforma legacy i386-pc (BIOS, non
   UEFI — la VM di test QEMU non usa OVMF/UEFI) richiede una partizione
   dedicata (`flag: bios_grub`, nessun filesystem) per il proprio
   core.img. Non specifico del test: si presenterebbe identico su
   qualunque nodo reale con boot BIOS legacy invece di UEFI. Fix:
   aggiunta una partizione da 1M con `flag: bios_grub` a entrambe le
   topologie, prima delle altre partizioni.

### Esito: run completo dopo il fix #6

Con tutti i fix precedenti (1-6), un nuovo run supera per la prima volta
`install-grub`/curthooks senza errori e arriva in postinstall: installa
`openssh-server`, avvia `run_unattended_upgrades`. Si ferma lì per
timeout (4500s) — **stesso limite di rete del sandbox già documentato in
`logbook-fase1.md`** (la VM guest non raggiunge gli archivi Ubuntu
attraverso il proxy di questo ambiente), non un bug nuovo. Coerente con
la decisione già presa in Fase 1: non si continua a testare questo
specifico step nel sandbox; la validazione del ciclo completo
install→reboot→SSH+Datastore per la Fase 2 resta da confermare su rete
reale (CI GitHub Actions con `workflow_dispatch`, o sessione locale con
Hyper-V/WSL+QEMU) — la stessa strada già percorsa con successo in Fase 1.

**Il partizionamento stesso (obiettivo di questa issue) è confermato
funzionante end-to-end**: disco di sistema, EFI, BIOS boot, root, e
Datastore XFS tutti creati e formattati correttamente, grub installato
con successo sul risultato.

## 2026-08-19 — Analisi critica del branch (nuova sessione) + test reali su Z8 (Hyper-V)

Nuova sessione (continuazione da Fase 1, stessa HP Z8 G4). Prima di
qualunque test: analisi critica del branch così com'era stato lasciato
(11 commit, mai in PR). Verificato di persona (non solo fidandosi del
logbook): letto ogni file toccato, validato YAML/shellcheck in modo
indipendente. Giudizio: metodo migliorato rispetto alla Fase 1 (verifica
doc ufficiale prima di scrivere lo storage.config), buon riuso
dell'infrastruttura Fase 1, 6 bug reali trovati con test veri. Rischio
principale segnalato prima di procedere: l'euristica "disco più piccolo
= sistema" (dual-disk) mai verificata; scenario a 2 dischi mai testato
nemmeno nel sandbox; nessun run mai arrivato a reboot+SSH completo.

Checklist pre-volo eseguita su Z8: sessione riavviata come Amministratore
(richiesto per Hyper-V, stesso limite della Fase 1), verificato switch
"Default Switch" disponibile, ~346GB liberi su disco, tooling WSL
(xorriso/qemu/python3-yaml) ancora presente e riusabile dalla Fase 1.

**Bug #7 — encoding PowerShell reintrodotto**: `boot-test-hyperv.ps1`
(modificato in Fase 2 per supportare `-Disks 2`) conteneva di nuovo
caratteri non-ASCII (em-dash "—") in stringhe/commenti, stesso problema
già risolto in Fase 1 (Windows PowerShell 5.1 legge il file con encoding
sbagliato, corrompendo i caratteri e rompendo il parsing). Fix:
rimossi tutti i caratteri non-ASCII dal file (`sed 's/—/-/g'`).

**Bug #8 (falso positivo, non un bug reale) — controllo dimensione ISO
troppo rigido**: build dell'ISO a 2 dischi segnalata come fallita dal
controllo difensivo aggiunto per il bug #5 ("ISO generata più piccola
dell'ISO sorgente di 798KB"). Verificato con `xorriso -osirrox` che
l'ISO generata contiene correttamente tutto il necessario (2 azioni
`disk`, euristiche `match` corrette, nessun placeholder residuo) e che
il boot record (El Torito, GPT, EFI) è intatto — confermato in modo
definitivo dal boot test reale che segue, arrivato fino a un ciclo
d'installazione completo. Lo scarto di ~798KB è risultato **riproducibile
e costante** su build successive identiche (stesso identico byte count
ogni volta): quasi certamente un artefatto benigno del meccanismo di
"replay" del boot catalog di xorriso quando si sostituiscono i file di
boot (allineamento/padding), non perdita di dati. **Il controllo
`>=` andrebbe ammorbidito o approfondito** (non ancora corretto in
questa sessione, segnalato per non bloccare CI in futuro con falsi
positivi).

**Bug #9 (il più importante) — bootloader partition mancante su UEFI**:
primo boot test reale a 2 dischi (Hyper-V Gen2, sempre UEFI) fallito
**immediatissimo**, prima ancora dell'inizio del partizionamento:
`subiquity/Filesystem/apply_autoinstall_config: autoinstall config did
not create needed bootloader partition`. Causa: lo storage.config aveva
`grub_device: true` solo sul disco (necessario per il boot BIOS legacy,
unico scenario testato finora nel sandbox Fase 2), ma su un sistema UEFI
Subiquity richiede quel flag esplicitamente **sulla partizione ESP
stessa**. Confermato non a memoria ma con prove concrete: `gh search
code` su repository terzi che hanno incontrato lo stesso identico errore
("grub_device: true is required on the ESP partition (not just the
disk) because Subiquity in Ubuntu 24.04.3 fails to recognize the ESP as
the bootloader partition without it") più il sorgente di Subiquity
stesso (`subiquity/models/storage.py`: `grub_device` è un campo valido
anche a livello di partizione, non solo disco).

**Implicazione più ampia di questo bug**: l'intero storage.config
esplicito della Fase 2 non era mai stato testato in un ambiente
genuinamente UEFI (il test QEMU del sandbox usava boot BIOS legacy per
default) — e la maggior parte dell'hardware server reale moderno
(incluso il target finale di questo progetto) boota UEFI, non BIOS
legacy. Senza questo fix, la Fase 2 avrebbe fallito su qualunque nodo
reale UEFI.

Fix applicato a **entrambe** le topologie (`storage-single-disk.yaml`,
`storage-dual-disk.yaml`): aggiunto `grub_device: true` anche
sull'azione `efi-partition`, mantenuto anche sul disco (serve comunque
per BIOS legacy, che continua a funzionare).

**Esito dopo il fix**: rieseguito il boot test a 2 dischi. **L'intera
installazione completa con successo**, zero errori: partizionamento
(entrambi i dischi, euristica dimensione rispettata), curthooks/grub,
`openssh-server`, `unattended-upgrades`, **entrambi i late-commands**
(NOPASSWD sudo e mount Datastore via UUID/fstab/symlink) — tutti
confermati riusciti dal trace seriale. La VM avvia il reboot
(`subiquity/Shutdown/shutdown: mode=REBOOT`) ma non torna mai
raggiungibile via SSH entro il timeout (5400s): il log seriale mostra
lo stesso identico timestamp del kernel (531.373256s) ripetuto per
l'intera attesa — non un loop di reinstallazione (si vedrebbero nuovi
messaggi di boot), più probabile un blocco della VM durante il reset
ACPI dopo il reboot, specifico di Hyper-V (es. il DVD dell'ISO resta
collegato come primo boot device dopo l'installazione, mai staccato dallo
script). **Non sembra un bug della logica Fase 2**: tutta la parte di cui
questa issue è responsabile (partizionamento, Datastore) è confermata
corretta end-to-end fino a un ciclo di installazione completo — il
problema residuo è nell'infrastruttura di test Hyper-V (gestione del
reboot), non nell'autoinstall. Retry in corso per capire se è un blocco
isolato o sistematico.

## Stato rispetto alla Definition of Done (issue #2)

- [x] Sezione `storage` con partizione sistema + partizione dedicata
      Datastore, size sistema parametrizzata (non hardcoded).
- [x] Gestione del caso multi-disco: topologia dedicata (`--disks 2`),
      fail-fast intenzionale se il conteggio dischi reale non corrisponde.
- [x] Layout verificato via boot reale **con rete diretta** (Hyper-V su
      HP Z8 G4, non solo il sandbox limitato): partizionamento a 2 dischi
      (EFI con `grub_device` corretto per UEFI, BIOS boot, root,
      Datastore XFS) completato con successo, grub installato
      correttamente, **entrambi i late-commands riusciti** (NOPASSWD
      sudo, mount Datastore via UUID/fstab/symlink).
- [x] Euristica "disco più piccolo = sistema" (dual-disk): **verificata
      con un test reale** — install completata correttamente con dischi
      di dimensione esplicitamente diversa (20GB/40GB).
- [~] Ciclo completo fino a login SSH post-reboot: install confermata al
      100% (zero errori in tutto il trace), ma la VM non torna
      raggiungibile dopo il reboot entro il timeout — probabile problema
      di infrastruttura test Hyper-V (non della logica Fase 2), in fase
      di verifica (retry in corso per capire se isolato o sistematico).
- [~] Integrazione CI reale su dischi virtuali QEMU (scenario singolo e
      doppio) — pipeline pronta (matrice in `ci.yml`), non ancora
      eseguita su CI GitHub Actions in questa fase.
- [ ] Verifica su hardware fisico multi-disco reale — manuale, fuori
      scope di questa fase di sviluppo.

## Prossimi passi

- [ ] Capire se il mancato ritorno SSH post-reboot (dual-disk, Hyper-V)
      è un blocco isolato o sistematico (retry in corso) — se
      sistematico, indagare la gestione del boot device dopo
      l'installazione (es. staccare il DVD/ISO prima del reboot).
- [ ] Ripetere lo stesso test anche per lo scenario a 1 disco (qui non
      ancora rieseguito con i fix di questa sessione: encoding
      PowerShell, `grub_device` su ESP — quest'ultimo rilevante anche lì).
- [ ] Ammorbidire o approfondire il controllo dimensione ISO in
      `build-iso.sh` (falso positivo trovato in questa sessione, rischia
      di bloccare CI con build in realtà valide).
- [ ] Eseguire lo scenario CI reale (`workflow_dispatch`, rete diretta
      GitHub Actions) per un secondo riscontro indipendente.
- [ ] Aprire la PR quando il ciclo completo (incluso reboot+SSH) è
      confermato per entrambi gli scenari.

## 2026-08-19 — Bug critico: `grub_device` su disco+ESP rompeva il boot BIOS legacy (nuova sessione, sandbox)

Durante un boot test Fase 3 nel sandbox (nessun hardware reale
disponibile: Z8 fuori uso fino al 23/08, vedi `logbook-fase3.md`), un
run è arrivato fino a `curthooks`/`install-grub` e ha fallito con
`CurtinInstallError`. Crash report completo (`/var/crash/*.crash`,
recuperato via `scripts/_qemu_serial_diag.py`):

```
Grub install cmds:
[['dpkg-reconfigure', 'grub-pc'], ['update-grub'],
 ['grub-install', '/dev/vda'], ['grub-install', '/dev/vda2']]
...
Command: [... 'grub-install', '/dev/vda2']
grub-install: warning: File system `fat' doesn't support embedding.
grub-install: warning: Embedding is not possible. GRUB can only be
    installed in this setup by using blocklists. However, blocklists
    are UNRELIABLE and their use is discouraged..
grub-install: error: will not proceed with blocklists.
```

**Causa**: `iso/storage-{single,dual}-disk.yaml` avevano `grub_device:
true` sia sul disco di sistema (necessario per il boot BIOS legacy, fix
del punto 6 sopra) sia sulla partizione ESP (necessario per UEFI, fix
del 2026-08-19 precedente — vedi sotto). Curtin non filtra i target
`grub_device` in base al firmware effettivamente rilevato al momento
dell'installazione: raccoglie *ogni* device/partizione con quel flag e
ci gira `grub-install` sopra incondizionatamente. Su un boot UEFI reale
questo non è un problema (confermato: il test Hyper-V Gen2 sopra ha
avuto successo con lo stesso doppio flag — `grub-install` sul disco
intero non fallisce quando EFI è già rilevato). Ma su un boot BIOS
legacy (il default di QEMU senza firmware esplicito, cioè esattamente
il metodo con cui questo sandbox aveva sempre testato finora — vedi
punto 6 sopra), il tentativo aggiuntivo `grub-install /dev/vda2` su una
partizione FAT32 fallisce sempre e manda in errore l'intero
autoinstall. Il fix per UEFI (Hyper-V) aveva quindi rotto silenziosamente
il boot BIOS legacy, mai più testato dopo quel fix perché tutti i test
successivi in sandbox erano su altre parti della pipeline (Fase 3) e non
erano arrivati abbastanza lontano da toccare di nuovo `install-grub`.

**Decisione** (chiesta esplicitamente all'utente, comporta una scelta di
compatibilità hardware): **solo UEFI**, non entrambi. L'hardware GPU
target di Vast.ai/Grastorp boota quasi universalmente UEFI; l'alternativa
(rilevare il firmware a runtime via un early-command che riscrive
`/autoinstall.yaml` prima che curtin giri) è stata scartata per
complessità/superficie di test aggiuntiva non giustificata al momento.

**Fix**: rimossi da entrambe le topologie sia `grub_device: true` sul
disco di sistema sia la partizione `bios-boot-partition`
(`flag: bios_grub`, ora inutile senza target BIOS) — resta
`grub_device: true` solo sulla partizione ESP. `scripts/
boot-test-qemu.sh` ora richiede esplicitamente firmware OVMF (cerca
`OVMF_CODE_4M.fd`/`OVMF_VARS_4M.fd` in `/usr/share/OVMF` e percorsi
equivalenti, fallisce con errore chiaro se non trovato) invece di
lasciare che QEMU faccia fallback silenzioso su BIOS legacy — il sandbox
di sviluppo ora testa la stessa modalità firmware del target reale.
`.github/workflows/ci.yml` aggiorna l'installazione dipendenze del job
di integrazione per includere il pacchetto `ovmf`.

**Nota collaterale sulla diagnostica**: lo stesso run ha rivelato un
buco nel harness di test stesso — `boot-test-qemu.sh` scartava lo
stderr di QEMU (`>/dev/null 2>&1`) e salvava il log seriale accanto
all'ISO solo nel percorso di timeout, non quando QEMU moriva prima del
timeout (un secondo test in parallelo, con un flag di sviluppo non
correlato, ha effettivamente perso la diagnostica in questo modo).
Corretto in questa stessa sessione: stderr di QEMU ora va su file
(`${WORK_DIR}/qemu-stderr.log`), e sia quello sia il log seriale vengono
persistiti accanto all'ISO su *qualunque* percorso di uscita anomala.

**Confermato**: ri-eseguito il boot test single-disk in sandbox con
OVMF. `install-grub` completa questa volta senza errori (prima falliva
sempre a questo punto) e l'installazione prosegue regolarmente fino a
`run_unattended_upgrades` (dove va comunque in timeout per il limite di
rete/velocità già noto del sandbox sotto TCG, non un fallimento — vedi
`logbook-fase3.md` per il flag `--dev-skip-security-updates` pensato
proprio per questo). Il fix risolve il problema. Resta comunque sospesa
la conferma finale su hardware reale fino al ritorno della Z8 (23/08).
