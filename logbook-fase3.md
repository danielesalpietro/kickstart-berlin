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

## Prossimi passi

- [ ] Boot test reale (sandbox o hardware) per confermare che il
      servizio post-install completi al primo boot e che
      `/var/lib/docker`/`daemon.json` risultino corretti.
- [ ] Verificare l'idempotenza invocando `postinstall/setup.sh` una
      seconda volta a mano sull'host installato.
- [ ] Aprire la PR quando confermato.
