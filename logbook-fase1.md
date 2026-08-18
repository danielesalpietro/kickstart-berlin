# Logbook — Fase 1: ISO autoinstall (issue #1)

Diario di lavoro/test per la Fase 1 (README, issue #1, master issue #15).
Aggiornato ad ogni sviluppo significativo: implementazione, test, bug
trovati/corretti, decisioni. Branch di riferimento:
`claude/iso-autoinstall-vast-ai-zgkwy3`.

## 2026-08-18 — Implementazione iniziale

Creati (commit `d1648de`):

- `iso/user-data`, `iso/meta-data` — autoinstall Subiquity: locale,
  tastiera, utente `admin`, SSH abilitato/password disabilitata, chiave
  pubblica iniettabile a build-time (placeholder `__SSH_AUTHORIZED_KEY__`,
  mai hardcoded).
- `scripts/build-iso.sh` — download ISO ufficiale + verifica checksum
  SHA256 (+ GPG se disponibile) + repack via `xorriso`
  (`-boot_image any replay`, preserva il boot catalog originale BIOS+UEFI).
- `scripts/boot-test-qemu.sh` — boot headless in QEMU su disco throwaway,
  verifica completamento autoinstall + login SSH con la chiave iniettata.
- `scripts/validate-autoinstall.py` — validazione schema/struttura YAML.
- `.github/workflows/ci.yml` — job unit (YAML+shellcheck, ogni PR) e job
  integrazione (build ISO reale + boot QEMU, su push/workflow_dispatch).
- `docs/usb-boot.md` — istruzioni scrittura USB + nota PXE/iPXE futura.

Validazione locale: shellcheck pulito, YAML validi. Non esguito boot reale
in questa fase (nessun `xorriso`/`qemu` ancora testati end-to-end).

## 2026-08-18 — Test #1 in sandbox cloud: FALLITO (bug trovato)

Ambiente: sessione Claude Code Remote (container Linux isolato, senza
`/dev/kvm`, rete solo via proxy configurato per l'host). Eseguito
`build-iso.sh` (ISO 24.04.2, checksum verificato OK) poi
`boot-test-qemu.sh` con QEMU in emulazione software (TCG), timeout 7200s.

**Esito**: timeout. Log seriale si ferma subito dopo il countdown del menu
GRUB (schermo che si pulisce all'avvio del kernel), nessun output
successivo per l'intera durata del test.

**Causa**: la riga kernel generata in `boot/grub/grub.cfg` non includeva
`console=ttyS0`. Di default solo GRUB scrive sulla console seriale;
kernel/casper/Subiquity, senza `console=`, scrivono solo sulla console
video (framebuffer), invisibile a un setup headless (`-nographic
-serial file:...`).

**Fix** (commit `253a851`): aggiunto `console=ttyS0,115200n8` sia alla
riga `linux .../casper/vmlinuz` (GRUB) sia alla riga `append` (isolinux
legacy), oltre al parametro `autoinstall ds=nocloud\;s=/cdrom/server/`
già presente. Aggiunto anche un heartbeat ogni 120s in
`boot-test-qemu.sh` (ultima riga della console seriale) per diagnosticare
più in fretta run futuri lenti.

## 2026-08-18 — Test #2 in sandbox cloud: PROGRESSO REALE, poi stallo di rete

Stesso ambiente, ISO ricostruita con il fix. Timeout 5400s.

**Esito**: progresso reale e verificabile via heartbeat — partizionamento,
installazione pacchetti, grub-pc, kernel, initramfs, `openssh-server`
tutti completati. Si blocca poi ~40 minuti sullo step
`postinstall/run_unattended_upgrades` (Subiquity esegue gli aggiornamenti
di sicurezza dentro il target via curtin `in-target`) fino al timeout,
senza mai raggiungere reboot/login SSH.

**Diagnosi**: lo step richiede rete verso gli archivi Ubuntu. Questo
sandbox instrada l'uscita HTTPS dell'host tramite un proxy applicativo
preconfigurato; la VM guest QEMU (rete SLIRP/NAT) non ha alcuna
conoscenza di quel proxy e le sue connessioni dirette agli archivi Ubuntu
restano probabilmente bloccate/silenti a livello di rete dell'host. Non è
un difetto della configurazione autoinstall né degli script.

## 2026-08-18 — Tentativo di skip update per isolare la diagnosi: fallito (config non valida)

Editato **temporaneamente e solo in locale** `iso/user-data`
(`updates: none`, `package_update: false`) per bypassare lo step di rete
e confermare che il resto della pipeline (reboot + SSH) funzioni. File
ripristinato subito dopo il build via `git checkout` (mai committato,
working tree verificato pulito).

**Esito**: Subiquity rifiuta la config con
`Malformed autoinstall in 'updates' section` e resta bloccato in loop di
retry-validazione — `updates: none` non è un valore valido per lo schema
Subiquity (valori ammessi noti: `security`, `all`). Il run è quindi
fallito per un motivo diverso (errore mio nel valore di test), non ha
potuto confermare né smentire ulteriormente l'ipotesi di rete.

**Decisione**: non proseguire con altri tentativi di configurazione alla
cieca nel sandbox (ogni iterazione costa 15-60+ minuti di wall-clock per
un singolo segnale debole). La causa più probabile resta il vincolo di
rete del sandbox (confermato dal progresso reale fino esattamente allo
step che richiede rete esterna). La validazione definitiva di questo
step, e del ciclo completo install→reboot→SSH, viene demandata a:

1. **CI GitHub Actions** (`build-and-boot-test` in `.github/workflows/ci.yml`)
   — rete diretta, nessun proxy. **Bloccato**: il token di questa sessione
   non ha permesso di lanciare `workflow_dispatch`
   (`403 Resource not accessible by integration`). Serve che l'utente
   avvii manualmente il workflow da GitHub → Actions → CI → "Run workflow"
   sul branch `claude/iso-autoinstall-vast-ai-zgkwy3`, con
   `run_integration: true`.
2. **Sessione locale dell'utente con Hyper-V** (sessione Claude Code
   Remote in modalità "bridge", connessa al PC Windows con rete reale).
   Non raggiungibile via `SendMessage` da questa sessione cloud (non
   compare tra gli agenti indirizzabili) — richiede che l'utente stesso
   esegua build+boot lì, o incolli le istruzioni preparate in quella
   sessione.

## 2026-08-18 — Test #3: ambiente Docker locale (HP Z8 G4), rete reale — interrotto volontariamente

Ambiente: workstation Windows locale dell'utente (HP Z8 G4, hostname
`DESKTOP-6MP79TM`), Docker Desktop (28 CPU / ~468GB RAM disponibili).
Creati `docker/Dockerfile` + `docker/docker-compose.yml` (Ubuntu 24.04 +
xorriso/qemu/shellcheck/python3-yaml) per non dover installare tooling
Linux sull'host Windows né toccare la distro WSL Ubuntu esistente.
Nessun `/dev/kvm` esposto nel container (limite noto di Docker Desktop su
Windows): QEMU gira in TCG, non accelerato. Rete diretta reale, nessun
proxy applicativo (a differenza del sandbox cloud dei test #1/#2).

**Bug collaterale trovato e corretto**: il working tree Windows aveva
`core.autocrlf=true` e il repo non aveva un `.gitattributes` — al
checkout, `scripts/*.sh`, `iso/user-data`, `.github/workflows/ci.yml` e
altri file testuali venivano convertiti in CRLF, rompendo gli script per
qualunque tool Linux (shellcheck falliva con `SC1017`, literal carriage
return). I blob committati erano già LF puro (verificato byte a byte):
il problema riguardava solo il checkout locale, ma si sarebbe ripetuto
per chiunque clonasse il repo su Windows. Fix: aggiunto `.gitattributes`
(commit `a796ee9`, forza `eol=lf` su script/YAML/config) e ripulito il
working tree locale.

**Build ISO**: `scripts/build-iso.sh` eseguito nel container con una
chiave SSH usa-e-getta generata ad hoc (mai committata, coerente con la
politica "nessuna chiave hardcoded"). Completata con successo:
`build/kickstart-berlin-test.iso`, checksum
`03e82a1da2e7f15b254d5f9ad7f0815c51aba33ef66b3cfb39fbde70fab0ae82`.

**Boot test**: `scripts/boot-test-qemu.sh` avviato alle
`2026-08-18T18:10:39Z` (timeout 5400s, RAM VM 8192MB). Interrotto
volontariamente (`docker stop`) alle `2026-08-18T18:15:08Z` — **~4m28s**
di wall-clock. Ultimo heartbeat a 255s, ancora nel boot del live
environment dell'installer (`systemd-logind.service` in fase di avvio):
non ancora arrivato allo stage Subiquity/autoinstall. Nessun bug
osservato in questo run — la causa dell'interruzione è solo la lentezza
di TCG (emulazione software pura, nessuna accelerazione hardware); a
quel ritmo il ciclo completo (install + reboot + SSH) avrebbe richiesto
probabilmente diverse ore.

**Decisione**: interrompere questo percorso e passare a un boot test
Hyper-V nativo sulla stessa macchina (hypervisor già attivo, VM Gen2,
accelerazione hardware reale — molto più veloce di TCG). Bloccante
trovato: la sessione Claude Code corrente non ha privilegi elevati
(`IsInRole(Administrator) = False`) e non può pilotare `New-VM`/`Start-VM`
(errore di autorizzazione); l'elevazione UAC non è ottenibile a sessione
già avviata, va decisa alla creazione del processo. Prossimo passo:
riavviare l'app/CLI Claude Code come Amministratore per sbloccare il
controllo diretto di Hyper-V nelle sessioni future.

In parallelo, il run CI GitHub Actions (`workflow_dispatch` su runner
ufficiale, rete diretta) resta in corso, non interrotto — esito ancora
pendente.

## 2026-08-18 — Bug reale trovato (CI + Hyper-V): late-commands "usermod -L admin" fallisce

Con la rete reale finalmente raggiunta sia in CI (GitHub Actions,
`workflow_dispatch` su `c4bfe59`) sia in un boot test Hyper-V locale sulla
Z8, l'installazione arriva per la prima volta fino allo stage
`subiquity/Late/run`. Lì fallisce, **in modo identico e riproducibile in
entrambi gli ambienti indipendenti**:

```
subiquity/Late/run/command_0: curtin in-target --target=/target -- usermod -L admin
Command [...] returned non-zero exit status 6.
An error occurred. Press enter to start a shell
```

`usermod` exit 6 = "specified user does not exist". La documentazione
ufficiale Subiquity (verificata via fetch di
canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
afferma che gli utenti definiti in `identity` vengono creati **durante
l'installazione** (non al primo boot come quelli da `user-data`
cloud-init puro), e che `late-commands` gira dopo, a target montato —
quindi secondo la documentazione l'utente `admin` dovrebbe già esistere a
quel punto. L'evidenza empirica (doppia, indipendente) dice il contrario.
Il debug interattivo via console seriale Hyper-V (script automatico) si è
bloccato su una read sincrona rimasta appesa, ma l'utente ha verificato
direttamente dalla console della VM bloccata: `cat /target/etc/passwd`
conferma che **l'utente admin non esiste affatto** in quello stage (solo
account di sistema: root, daemon, bin, sys, ..., sshd — nessun `admin`).
Contraddice quindi direttamente quanto riportato dalla documentazione
Subiquity, con prova diretta e non solo per esclusione.

**Fix applicato** (senza dipendere dalla causa esatta): invece di creare
l'account con un hash placeholder e poi bloccarlo via `late-commands`,
l'account viene ora creato **già bloccato fin dall'inizio**, anteponendo
`!` all'hash in `identity.password` — la stessa convenzione standard di
`/etc/shadow` che `usermod -L` applica sotto il cofano. Rimosso
interamente `late-commands`. Nessuna finestra temporale con hash valido,
nessuna dipendenza dal timing/ordine di creazione dell'account durante
l'installazione. `ssh.allow-pw: false` resta comunque la protezione
primaria per l'accesso remoto (unico canale previsto per un nodo
headless).

ISO ricostruita con il fix; nuovo boot test in corso.

## 2026-08-18 — Test #4 (Hyper-V, HP Z8 G4): PRIMO CICLO COMPLETO RIUSCITO

Sessione riavviata come Amministratore (necessario per pilotare Hyper-V:
`New-VM`/`Start-VM` falliscono senza privilegi elevati, l'elevazione va
decisa alla creazione del processo, non è ottenibile a sessione già
avviata). VM Gen2 (4GB RAM, 20GB disco, switch "Default Switch" per
rete NAT diretta reale) creata con `scripts/boot-test-hyperv.ps1`
(nuovo script, analogo a `boot-test-qemu.sh` ma per Hyper-V: VM
throwaway, console seriale via named pipe, poll IP+SSH, cleanup finale).

**Esito**: install completo, reboot, **login SSH riuscito** con la
chiave permanente `~/.ssh/id_ed25519_kickstart_berlin` (generata per
questo nodo, non più usa-e-getta). `hostname` = `kickstart-berlin`,
corretto. Verificato anche `ssh -v`: il server offre solo
`publickey` come metodo di autenticazione — `ssh.allow-pw: false`
confermato funzionante con prova diretta, non solo per assunzione.

**Due bug nuovi trovati con l'accesso reale, entrambi corretti**:

1. **`sudo` inutilizzabile**: l'account `admin` ha la password bloccata
   di proposito (vedi fix del test #3), ma questo significa che anche
   `sudo` (che di default richiede la password dell'utente stesso) non
   ha nulla da verificare — `admin` risultava di fatto senza privilegi
   amministrativi, bloccante per tutte le fasi successive (Docker,
   NVIDIA, ecc.). Fix: aggiunto un late-command che scrive
   `/etc/sudoers.d/90-admin-nopasswd` con `admin ALL=(ALL) NOPASSWD:ALL`.
   Non è un problema di sicurezza reale: l'unico accesso possibile è già
   la chiave SSH, una seconda password per sudo non aggiungerebbe nulla
   contro chi ha già quell'accesso. A differenza di `usermod -L admin`
   (rimosso in precedenza), scrivere un file statico in `/etc/sudoers.d`
   non dipende dall'esistenza dell'utente nel database NSS del target
   in quel momento dell'installazione — quindi non soggetto allo stesso
   bug di timing.
2. **IP non visibile da `Get-VMNetworkAdapter`**: mancavano i demoni di
   integrazione Hyper-V (KVP/VSS/FCOPY) sul guest. Aggiunto pacchetto
   `hyperv-daemons` a `packages:`. No-op innocuo su hardware non
   Hyper-V (i demoni restano inattivi se non trovano i canali hv_vmbus).

**Nota sulla VM di test**: è scomparsa (non solo spenta, rimossa del
tutto) durante la sessione senza un'azione esplicita mia — causa non
determinata con certezza (l'utente ha interagito direttamente con la
console nel frattempo). Non ha impedito di raccogliere tutte le prove
necessarie prima che sparisse.

## 2026-08-18 — Note operative sull'ambiente locale (HP Z8 G4)

Raccolte qui per non doverle re-imparare da zero in una sessione futura.

- **Docker Desktop è diventato inaffidabile dopo il crash di sistema**
  (BSOD 0x139 KERNEL_SECURITY_CHECK_FAILURE, causa non confermata,
  concomitante con l'avvio della prima VM Hyper-V — vedi test #3/#4).
  Il primo riavvio di Docker Desktop dopo il crash ha impiegato solo
  15s; i successivi non rispondevano più (`docker info` in timeout)
  nonostante i processi risultassero attivi. **Se Docker Desktop non
  risponde dopo un riavvio del sistema, non insistere a lungo: passare
  a WSL diretto (sotto) è più rapido che debuggare Docker Desktop.**
  Ipotesi non confermata sulla causa: Docker Desktop gira sulla propria
  distro WSL2 (`docker-desktop`), separata da `Ubuntu`; puo' darsi che
  ci sia contesa sulle risorse di virtualizzazione nested dell'hypervisor
  quando piu' distro/VM tentano di reclamarle contemporaneamente (KVM
  attivo su `Ubuntu`, VM Hyper-V native, `docker-desktop`), aggravata da
  risorse non rilasciate correttamente dopo il crash. Da verificare in
  futuro se rilevante, non bloccante per ora (WSL diretto funziona).
- **WSL come alternativa a Docker Desktop per xorriso/qemu**: la distro
  `Ubuntu` (WSL2) già presente sul sistema può ospitare `xorriso`,
  `qemu-system-x86`, `qemu-utils`, `shellcheck`, `python3-yaml` via
  `apt`, senza passare da Docker Desktop. **`/dev/kvm` è disponibile
  dentro WSL2** (verificato: `crw-rw---- root kvm`) — a differenza del
  container Docker Desktop (nessun KVM, solo TCG), quindi un boot test
  QEMU lanciato da WSL può essere accelerato via hardware.
- **Eseguire comandi privilegiati in WSL senza sudo interattivo**:
  `wsl -d <distro> -u root -- <comando>` esegue come root usando la
  funzionalità nativa di `wsl.exe` (analoga a `docker exec -u root`),
  **senza toccare `/etc/sudoers`** e senza richiedere una password
  interattiva che l'agente non può fornire (per policy non gestisce
  credenziali, e in ogni caso non modifica configurazioni di sicurezza
  di sistema anche se l'utente lo autorizza esplicitamente — unica
  eccezione accettabile: l'utente stesso lancia `sudo` a mano in un
  terminale interattivo). Esempio:
  `wsl -d Ubuntu -u root -- apt-get install -y xorriso`.
- **Passare script multi-riga a WSL senza rogne di quoting**: evitare
  `wsl -d Ubuntu -- bash -c "..."` con variabili `$var` — l'escaping
  tra Git Bash (MSYS) e `wsl.exe` le espande prematuramente lato host.
  Soluzione: scrivere lo script su file e passarlo via stdin:
  `wsl -d Ubuntu -u root -- bash < script.sh`. Nota: `/tmp` di Git Bash
  (`C:\Users\...\AppData\Local\Temp`) **non** è lo stesso `/tmp` visto
  da WSL (filesystem separato) — passare via stdin evita anche questo
  problema di path.
- **`docker compose` + volume persistente per la cache dell'ISO
  ufficiale**: `scripts/build-iso.sh` supporta ora `--cache-dir <path>`
  (opzionale, default disattivo — CI/produzione scaricano sempre da
  zero). Nelle nostre run locali via `docker/docker-compose.yml`, il
  volume nominato `iso-cache` è montato su `/cache`: la seconda build
  in poi riusa l'ISO ufficiale già scaricata (~3GB, verificato comunque
  ad ogni build via checksum fresco da SHA256SUMS) invece di
  riscaricarla. Se si passa a WSL come builder, si può ottenere lo
  stesso beneficio scaricando l'ISO ufficiale una volta in un path
  persistente dentro la distro WSL (es. `~/iso-cache/`) e passandolo a
  `--cache-dir`.
- **`.gitattributes`** (commit `a796ee9`) forza `eol=lf` su
  script/YAML/config: senza, `core.autocrlf=true` di Git per Windows
  corrompe questi file in CRLF ad ogni checkout, rompendoli per
  qualunque tool Linux.

## 2026-08-18 — Test #5 (WSL+QEMU/KVM): bug in `hyperv-daemons`, rimosso

Prima build+test dopo il pivot da Docker Desktop a WSL diretto (vedi note
operative sopra). Build riuscita (ISO con entrambi i fix del test #4:
NOPASSWD sudo + `hyperv-daemons`), cache ISO ufficiale funzionante anche
da WSL (`~/iso-cache`, stesso meccanismo `--cache-dir` di
`build-iso.sh`). Boot test con `scripts/boot-test-qemu.sh` da dentro WSL:
**KVM disponibile e usato** (accelerazione hardware confermata nel log:
"KVM disponibile: uso accelerazione hardware"), molto più veloce dei
test precedenti in TCG.

**Esito**: fallito, ma con causa cristallina — a differenza del test #4
(dove l'errore era su `linux-generic` con stdout/stderr vuoti, causa
sospetta ma non certa), qui il traceback e' chiaro:
`subiquity/Install/install/postinstall/install_hyperv-daemons`, comando
`curtin ... system-install -t /target --download-only -- hyperv-daemons`
fallisce con `exit 100`, ritentato automaticamente 3 volte da Subiquity,
poi abbandona e l'intera installazione fallisce (stesso comportamento
"un solo pacchetto broken blocca tutto" già visto). **Non e' un problema
di rete**: `openssh-server`, installato subito prima con lo stesso
meccanismo (`postinstall/install_X` → `curtin system-install
--download-only`), riesce senza problemi nello stesso run. Il pacchetto
`hyperv-daemons` stesso e' il problema (nome non risolvibile in questo
contesto, o dipendenze non soddisfatte — causa esatta non investigata
oltre, non ne valeva la pena data la scarsa importanza del pacchetto).

**Decisione**: rimosso `hyperv-daemons` da `packages:` (era solo comodo
per il testing locale, non un requisito della Fase 1 — il nodo target
reale e' bare-metal). Per l'IP di una VM Hyper-V di test resta
disponibile il lookup ARP host per MAC address (usato con successo nel
test #4 quando i demoni non erano ancora installati). ISO ricostruita
senza `hyperv-daemons`, nuovo test in corso.

## 2026-08-18 — Test #6 (WSL+QEMU/KVM): CICLO COMPLETO RIUSCITO, automatico

Stessa build del test #5 ma senza `hyperv-daemons` (rimosso). Interruzione
di mezzo: la distro `Ubuntu` è stata fermata (`wsl --terminate`, test #5
sacrificato) per un esperimento mirato a capire perché Docker Desktop non
ripartiva dopo il crash — ipotesi contesa risorse con `Ubuntu`/KVM
**esclusa**: fermare `Ubuntu` non ha risolto Docker Desktop (la sua
distro `docker-desktop` restava comunque `Stopped`, e una volta avviata a
mano il daemon rispondeva con `500 Internal Server Error` dalla propria
API — sintomo di stato interno corrotto dal crash, non di contesa
risorse; richiederebbe un reset di Docker Desktop, non perseguito perché
non bloccante). Riavviata `Ubuntu`, ripetuto il boot test.

**Esito**: **successo end-to-end, rilevato automaticamente dallo script**
(a differenza del test #4 dove la rilevazione IP di Hyper-V era rotta e
la verifica fu manuale): `[boot-test] Login SSH riuscito con la chiave
iniettata a build-time: autoinstall completato senza prompt, host
installato e raggiungibile. Test superato.` Circa 500s di wall-clock
totale (accelerazione KVM, molto più veloce del TCG dei test precedenti).

Poiché un fallimento di un late-command fa fallire l'intera
installazione (comportamento fail-fast di Subiquity, verificato più
volte in questa fase), il fatto che l'installazione sia arrivata fino al
reboot+login SSH conferma implicitamente che anche il fix NOPASSWD sudo
(late-command) ha funzionato — non solo l'assenza dell'errore
`usermod`/`hyperv-daemons` dei test precedenti.

**Questo chiude, per la prima volta, un run reale e completo con TUTTI i
fix della Fase 1 inclusi**, in un ambiente riproducibile (WSL Ubuntu +
QEMU/KVM, non legato a Hyper-V) e senza intervento manuale per la
verifica del successo.

## Stato rispetto alla Definition of Done (issue #1)

- [x] Script di repack ISO con verifica checksum.
- [x] Utente admin con SSH, chiave iniettabile a build-time (non hardcoded).
- [x] Versione Ubuntu pinnata (24.04.2) e documentata.
- [x] L'ISO boota e completa l'installazione senza prompt, fino a reboot
      e login SSH, **con tutti i fix inclusi e rilevazione automatica del
      successo** — confermato nel test #6 (WSL + QEMU/KVM).
- [x] Account admin utilizzabile end-to-end: SSH con chiave (non
      password), `sudo` funzionante via NOPASSWD (nessuna seconda
      password richiesta, dato che l'unico accesso è già la chiave SSH).
- [ ] Boot reale su hardware fisico da USB (manuale, fuori sandbox) —
      unico punto della DoD non ancora verificabile da remoto/locale.

## Prossimi passi

- [x] Avviare `workflow_dispatch` su CI con `run_integration: true` —
      fatto; quel run è però precedente ai fix usermod/sudo/hyperv-daemons,
      da rilanciare per un doppio riscontro indipendente (facoltativo,
      il test #6 locale è già una conferma end-to-end completa).
- [x] Riavviare la sessione come Amministratore per pilotare Hyper-V —
      fatto (poi non più necessario: il path WSL+QEMU/KVM si è rivelato
      più affidabile e altrettanto rappresentativo).
- [x] Eseguire un boot test completo con successo, rilevato
      automaticamente — fatto (test #6).
- [ ] Decidere se/quando mergiare il branch `claude/iso-autoinstall-vast-ai-zgkwy3`
      in `develop` e chiudere issue #1 — la Fase 1 è ora funzionalmente
      completa salvo il test USB fisico.
- [ ] (Opzionale) Diagnosticare Docker Desktop (500 Internal Server
      Error dalla propria API dopo il crash) se si vuole tornare a
      usarlo — non bloccante, WSL diretto è pienamente funzionante.
