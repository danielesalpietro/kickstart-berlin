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

- [ ] Utente: avviare `workflow_dispatch` su CI con `run_integration: true`.
- [ ] Utente: eseguire build+boot (QEMU o Hyper-V) sulla sessione locale
      con rete reale; riportare esito.
- [ ] Aggiornare questo logbook con l'esito di entrambi.
- [ ] Se confermato il ciclo completo, aggiornare la checklist DoD
      nell'issue #1 e chiuderla.
