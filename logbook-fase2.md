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
- **Multi-disco/RAID**: la logica "se N dischi extra, scegli il livello
  di ridondanza adeguato (RAID1/5/6 o EC)" non è esprimibile in modo
  dichiarativo nello `storage.config` di Subiquity/curtin (azioni
  statiche, nessun costrutto condizionale sul conteggio dischi a
  runtime). Decisione: la ridondanza multi-disco resta fuori scope per
  questa issue, demandata a uno script post-install dinamico (Fase 3,
  issue #3) dove la logica condizionale è banale in bash. Coerente con
  come Vast.ai stesso gestisce il proprio equivalente (`/var/lib/docker`
  su partizione singola o "RAID array" già pronto a monte — il loro
  installer non orchestra RAID).
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

## Stato rispetto alla Definition of Done (issue #2)

- [x] Sezione `storage` con partizione sistema + partizione dedicata
      Datastore, size sistema parametrizzata (non hardcoded).
- [x] Gestione del caso multi-disco: topologia dedicata (`--disks 2`),
      fail-fast intenzionale se il conteggio dischi reale non corrisponde.
- [x] Layout verificato via boot reale in QEMU (scenario 1 disco):
      partizionamento (EFI, BIOS boot, root, Datastore XFS) completato
      con successo, grub installato correttamente sul risultato.
      `lsblk`/`findmnt` non ancora eseguiti manualmente sull'host finale
      (il run si ferma prima, sul limite di rete del sandbox per
      `run_unattended_upgrades` — non blocca la verifica del
      partizionamento, che avviene prima).
- [~] Integrazione CI reale su dischi virtuali QEMU (scenario singolo e
      doppio) — pipeline pronta (matrice in `ci.yml`), verificata
      manualmente per lo scenario a 1 disco in questo sandbox (rete
      limitata); l'esecuzione reale su CI (rete diretta) e lo scenario a
      2 dischi restano da eseguire.
- [ ] Verifica su hardware fisico multi-disco reale — manuale, fuori
      scope di questa fase di sviluppo.

## Prossimi passi

- [ ] Rieseguire lo scenario a 1 disco su rete reale (CI
      `workflow_dispatch`, o sessione locale) per confermare il ciclo
      completo install→reboot→login SSH→Datastore montato, oltre il
      punto già raggiunto in sandbox.
- [ ] Eseguire lo scenario a 2 dischi (qui non ancora rilanciato dopo i
      fix 1-6, tutti scoperti sullo scenario a 1 disco ma applicabili a
      entrambi) — in particolare confermare o smentire l'euristica
      "disco più piccolo = sistema" con un test reale (segnalata come
      assunzione non verificata da fonte).
- [ ] Aprire la PR quando entrambi gli scenari sono confermati.
