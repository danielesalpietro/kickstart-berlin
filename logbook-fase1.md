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

## Stato rispetto alla Definition of Done (issue #1)

- [x] Script di repack ISO con verifica checksum.
- [x] Utente admin con SSH, chiave iniettabile a build-time (non hardcoded).
- [x] Versione Ubuntu pinnata (24.04.2) e documentata.
- [~] L'ISO boota e completa l'installazione senza prompt: **confermato
      fino allo step di security update incluso** (partizionamento,
      pacchetti, grub, ssh-server); il reboot finale e il login SSH non
      sono ancora stati osservati in un run completo (bloccati dal
      vincolo di rete del sandbox, vedi sopra). Da confermare su rete
      reale (CI o PC locale).
- [ ] Boot reale su hardware fisico da USB (manuale, fuori sandbox).

## Prossimi passi

- [x] Utente: avviare `workflow_dispatch` su CI con `run_integration: true`
      — lanciato (serviva prima registrare `ci.yml` su `develop`, commit
      `c4bfe59`); esito ancora pendente.
- [ ] Riavviare la sessione Claude Code come Amministratore per poter
      pilotare Hyper-V direttamente (`New-VM`/`Start-VM`).
- [ ] Eseguire il boot test in una VM Hyper-V Gen2 (accelerazione
      hardware, molto più veloce del TCG usato nel test #3) con l'ISO
      già generata (`build/kickstart-berlin-test.iso`); riportare esito.
- [ ] Aggiornare questo logbook con l'esito di CI e Hyper-V.
- [ ] Se confermato il ciclo completo, aggiornare la checklist DoD
      nell'issue #1 e chiuderla.
