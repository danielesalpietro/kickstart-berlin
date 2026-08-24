# Logbook — Primo boot reale su Z8 (hardware fisico, non VM)

Diario del primo collaudo end-to-end di un'ISO autoinstall su un nodo
fisico HP Z8 (non una VM Azure/Hyper-V/QEMU come nei collaudi precedenti,
vedi `docs/collaudo-funzionale.md` e i `logbook-faseN.md`). Procedura
seguita: `setup.docx` (guida operativa "dal BIOS al check finale",
fornita dall'utente, non presente nel repo). Branch di lavoro al momento
di questa sessione: `claude/fase7-vastai-daemon-real`.

## 2026-08-23 — Accesso al nodo: niente password, per design

Al primo avvio l'utente vede il prompt di login sulla console fisica
della Z8 ma non ha né password né IP del nodo. Verificato che è
comportamento atteso, non un problema:

- `iso/user-data` blocca l'account `admin` con un hash placeholder
  prefissato `!` fin dalla creazione (mai una password valida) — unico
  accesso previsto è SSH con la chiave pubblica iniettata a build-time
  (`build-iso.sh -k`). Il login da console locale non è mai stato
  previsto (vedi `docs/usb-boot.md`).
- IP sconosciuto: a differenza del caso VM (dove si può leggere l'ARP
  dell'host per il MAC della VM, nota in `iso/user-data`), su un nodo
  fisico non c'è questa scorciatoia. Risolto con un ping sweep asincrono
  sulla subnet della workstation operatore (`192.168.10.0/24`, 3 host
  attivi: gateway `.1`, operatore `.82`, nodo `.81`) seguito da conferma
  su porta 22 aperta. Nessun meccanismo dedicato nel repo per questo
  caso — da valutare se documentarlo in `docs/` per i prossimi collaudi
  bare-metal (mDNS/hostname `berlin-XXXX.local`? Sarebbe più robusto di
  un ping sweep manuale).
- Connessione confermata con la chiave privata fornita dall'utente:
  hostname generato `berlin-3eie`, utente `admin`, sudo NOPASSWD attivo.

## 2026-08-23 — Problema 1 (corretto nel repo il 2026-08-24): storage finito sui moduli PMem, non su sda

`lsblk` sul nodo mostra root, ESP e Datastore tutti su `/dev/pmem0s*`
(modulo Intel Optane Persistent Memory, modalità sector/BTT), mentre
`sda` (disco WD 465GB con partizione NTFS residua, probabilmente
Windows preesistente) è rimasto completamente intoccato. Presente anche
un secondo modulo PMem (`pmem1s`, 251GB) non partizionato.

**Causa**: `iso/storage-single-disk.yaml:9` usa `match: {}` — un match
vuoto che dice a curtin "prendi un disco qualsiasi disponibile", senza
criteri di esclusione. Su tutto l'hardware di collaudo usato finora (VM
Azure/Hyper-V/QEMU, vedi `logbook-fase1.md`…`logbook-fase8.md`) questo
ha sempre preso l'unico disco presente, quindi il problema non era mai
emerso: **è la prima volta che questo repo gira su hardware con moduli
Optane PMem installati**. `iso/storage-dual-disk.yaml` usa lo stesso
pattern `match: {}` (verificare, presumibilmente stesso rischio con due
dischi + PMem).

**Decisione utente**: tenere l'installazione così com'è (PMem è più
veloce di un HDD SATA per carichi Docker/GPU, e il risultato — per
quanto non deliberato — è tecnicamente accettabile su questo nodo).
Nessun reinstall.

**Da fare per il repo** (non ancora implementato in questa sessione):
`match: {}` dovrebbe escludere esplicitamente i device PMem (o
richiedere un criterio più specifico, es. `ssd: true` + esclusione
`/dev/pmem*`) in entrambi `iso/storage-single-disk.yaml` e
`iso/storage-dual-disk.yaml`, altrimenti il comportamento resta
non deterministico su qualunque hardware con Optane installato.

## 2026-08-23 — Problema 2 (bug, corretto live): Fase 4 si interrompe prima del reboot

Il servizio `kickstart-berlin-postinstall.service` è fallito (`exit
100`) durante la Fase 4 (driver NVIDIA), **prima** di eseguire il
reboot previsto per caricare il modulo kernel DKMS.

**Causa**, in `postinstall/setup.sh:164-166` (bug presente anche nel
checkout locale attuale, quindi non ancora corretto a monte):

```sh
mapfile -t nvidia_pkgs < <(dpkg-query -W -f='${Package}\n' 'nvidia-*' 2>/dev/null)
apt-mark hold "${nvidia_pkgs[@]}"
```

`dpkg-query -W 'nvidia-*'` su questo nodo ha restituito, insieme ai
pacchetti realmente installati, diverse voci "fantasma" note a dpkg ma
senza installazione né candidato in apt (`nvidia-smi`,
`nvidia-persistenced`, `nvidia-utils`, `nvidia-opencl-icd`, ecc. — tutte
con stato dpkg `unknown ok not-installed`). `apt-mark hold` fallisce su
quelle voci con `E: Can't select installed nor candidate version`; lo
script ha `set -euo pipefail` (riga 15), quindi l'intero setup si
interrompe lì, **senza mai arrivare** a `touch
$NVIDIA_REBOOT_MARKER && reboot`.

**Fix applicato live sul nodo** (non ancora riportato nel repo):
1. Calcolati i soli pacchetti `nvidia-*` realmente installati (`dpkg -l`
   filtrato su stato `ii`/`hi`+installed) e messi in hold manualmente.
2. Creato a mano `/opt/kickstart-berlin/.phase4-nvidia-reboot-attempted`
   (il marker che lo script avrebbe dovuto scrivere).
3. Riavvio (fatto manualmente dall'utente da console fisica — il
   riavvio via `ssh ... sudo reboot` sembrava non essere partito o
   comunque non è stato osservato completarsi da remoto; una volta
   riavviato manualmente il nodo è tornato raggiungibile via SSH).
4. Dopo il reboot: `nvidia-smi` funzionante (RTX 3090, driver 595.84).

**Da fare per il repo**: filtrare `dpkg-query -W` sul solo stato
`installed` prima di passare l'elenco a `apt-mark hold`, es.:

```sh
mapfile -t nvidia_pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-*' 2>/dev/null | awk '$1=="ii"||$1=="hi"{print $2}')
```

## 2026-08-23 — Problema 3 (bug, corretto live): Fase 10 (`vastai` CLI) — `HOME` non definita

Dopo il fix del Problema 2, il servizio è ripartito da solo (nessun
`.setup-complete` scritto) ed è arrivato fino alla **Fase 10** — fase
non presente nel checkout locale corrente di questo branch
(`postinstall/setup.sh` locale si ferma alla Fase 8): l'ISO usata in
questo collaudo è stata evidentemente costruita da un branch/commit più
avanzato di quello in uso in questa sessione. Da riconciliare (vedi
"Prossimi passi").

**Causa**, in `phase10_vastai_cli()` (riga 380 sul nodo):

```sh
curl -fsSL https://vast.ai/install.sh | bash
```

Il servizio systemd è `Type=oneshot`, gira come root senza
`Environment=`/PAM: `$HOME` non è definita nell'ambiente. L'installer
ufficiale Vast.ai (lato destro della pipe, il processo `bash` che
riceve lo script via stdin) referenzia `$HOME` e va in errore
(`bash: line 34: HOME: unbound variable`); con `pipefail` l'intero
script si interrompe di nuovo.

**Primo tentativo di fix, sbagliato**: `HOME="${HOME:-/root}" curl ...
| bash` — imposta `HOME` solo nell'ambiente di `curl` (lato sinistro
della pipe), non di `bash` (lato destro, dove serve). Non ha risolto
nulla, stesso errore.

**Fix corretto, applicato live**:

```sh
curl -fsSL https://vast.ai/install.sh | HOME="${HOME:-/root}" bash
```

Dopo il fix: Fase 10 completata, `vastai 1.5.5` installato,
`.setup-complete` scritto, servizio `active (exited)`.

**Da fare per il repo**: applicare lo stesso fix a
`postinstall/setup.sh` sul branch che contiene la Fase 10 (non questo
branch locale).

## 2026-08-23 — Problema 4 (bug, corretto e verificato): `vastai` non eseguibile da `admin` senza sudo

Verifica: `vastai --version` come utente `admin` (senza sudo) falliva
con `Permission denied`, mentre `sudo vastai --version` funzionava
(`1.5.5`).

**Causa**: l'installer Vast.ai, eseguito con `HOME=/root`, scrive sotto
`/root/.local/share/vastai/...`. `namei -l` sul path completo mostra
che **tutta** la catena è `755` tranne `/root` stesso (`700`, default)
— unico vero blocco.

**Primo tentativo di fix, sbagliato**: copiare il binario risolto
(`readlink -f` + `install -m 0755`) in `/usr/local/bin/vastai` invece
di un symlink. Il binario `vastai` **non è un eseguibile portabile**:
è un wrapper venv-style (installer `uv`) che risolve il proprio
`realpath "$0"` a runtime e si aspetta un interprete Python affiancato
nella stessa directory — la copia isolata fallisce con
`exec: python: not found`.

**Fix corretto, applicato e verificato end-to-end**: `chmod o+x
"${HOME:-/root}"` in cima a `phase10_vastai_cli()` (idempotente, prima
del check `command -v vastai` così si applica anche a
un'installazione preesistente). Concede solo attraversamento
(`o+x`), non lettura (`o+r`): `/root` resta non elencabile (`ls /root`
→ `Permission denied`) e sottodirectory sensibili come `/root/.ssh`
restano `700`, protette dai propri permessi. Ripristinato il symlink
originale (non la copia) in `/usr/local/bin/vastai`.

**Verifica end-to-end reale sul nodo**: rimossa l'installazione
esistente, ripristinato `/root` a `700`, rieseguita
`phase10_vastai_cli()` per intero dallo script corretto (come root, via
`sudo bash -c`) — reinstallazione completa (40 pacchetti Python),
`/root` risultante `701`, `vastai --version` funzionante come `admin`
senza sudo (`1.5.5`), `/root` ancora non listabile. Nessuna regressione.

**Impatto risolto**: lo Step 7 di `setup.docx` ("Configura
l'autenticazione a mano: `vastai set api-key ...`") ora funziona come
scritto, senza richiedere `sudo`.

## Log raccolti sul nodo

Output grezzi di `lsblk`, `lscpu`, `lspci`, `nvidia-smi` presi
direttamente sul nodo (`/home/admin/{lsblk,lscpu,lspci,nvidia}.txt`),
salvati come evidenza in [`first-boot-z8/`](first-boot-z8/):
`lsblk.txt` conferma il layout `sda`/`pmem0s`/`pmem1s` del Problema 1;
`nvidia.txt` conferma driver 595.84/CUDA 13.2 attivi sulla RTX 3090,
nessun errore ECC, nessun processo residuo.

## Stato finale verificato

- ☑ `nvidia-smi`: RTX 3090, driver 595.84.
- ☑ `docker run --rm --gpus all ... nvidia-smi` mostra la GPU dentro un
  container — **ma non con il tag `nvidia/cuda:12.4.1-base-ubuntu24.04`
  citato nel checklist di `setup.docx`**, che risulta non più
  disponibile su Docker Hub (`Unable to find image`). Verificato invece
  con `nvidia/cuda:12.6.0-base-ubuntu24.04` (pull riuscito, GPU visibile
  nel container). Da aggiornare il riferimento nella guida operativa se
  si conferma che il tag 12.4.1 è stato ritirato definitivamente.
- ☑ `/opt/kickstart-berlin/hardware-info.json` popolato,
  `nvidia_gpu` = "NVIDIA GeForce RTX 3090, 24576 MiB, 595.84".
- ☑ `vastai` installato (1.5.5), utilizzabile da `admin` **senza**
  `sudo` — vedi Problema 4 (corretto).
- `ufw`: installato ma inattivo — comportamento voluto ("non tocco la
  postura firewall esistente dell'host"), range 16384-32768 da aprire a
  mano se/quando attivato.
- Non ancora eseguiti in questa sessione: Step 4 (import branch
  corretto via git clone), Step 5 (Fase 7, daemon host reale), Step 6
  (verifica listing + porte router), Step 7 (autenticazione API key),
  Step 8 (self-test Fase 11).

## Riconciliazione branch — risolta

Identificato il branch che ha effettivamente generato questa ISO:
`claude/vastai-fase7-integration-9eh1fw` (`postinstall/setup.sh`
byte-identico a quello trovato sul nodo, contiene anche `docs/setup.docx`
e `CLAUDE.md`, entrambi citati nella guida ma assenti dal checkout
locale usato in questa sessione).

Verificato che **`develop` ha già il merge di quel branch** (PR #23,
commit `799abdb`…`12818ad` presenti nella storia di `origin/develop`) —
`postinstall/setup.sh` è identico tra `develop` e la punta del branch
feature. Mancano solo 3 commit successivi al merge, mai riportati:
`docs/setup.md`, `docs/setup.docx`, e uno step opzionale dev-only
("Claude Code CLI sul nodo"). `develop` è inoltre più avanti del branch
feature su altri fronti (workflow CI per la build ISO). **`develop` è
quindi la base corretta**, non il branch feature (stale).

I tre fix di questa sessione sono stati applicati su un nuovo branch
`claude/postinstall-firstboot-fixes`, creato da `origin/develop`.

## 2026-08-24 — Ricollegati altri 5 dischi: Windows reale, non solo teoria

Verso la fine della sessione l'utente ha ricollegato fisicamente altri
dischi che erano scollegati per tutta la sessione fino a quel momento:
`sdb` (membro RAID1 `isw_raid_member`, montato NTFS "Volume"), `sdc`
(NTFS "Volume"), `sdd` (ESP + partizione riservata + due NTFS — layout
classico di un'installazione Windows completa C:+Recovery), `nvme0n1`
(ESP + NTFS "Volume5GBs"), `nvme1n1` (NTFS). **Cinque dischi con dati
Windows reali**, mai visti prima in questa sessione.

Questo rende concreto un limite già annotato nel Problema 1: il fix
originario (`match` con allowlist per path `nvme*n1`/`sd*`/`vd*`,
committato su `claude/postinstall-firstboot-fixes`/PR #28) esclude i
moduli PMem ma **non basta più** quando ci sono più dischi "veri"
candidabili insieme — con path-glob da solo, un reinstall potrebbe
scegliere un disco Windows a caso invece di quello vuoto destinato al
sistema.

**Deciso con l'utente**: per il prossimo reinstall, scollegare
fisicamente i dischi Windows prima (hot-swap, facile) — i moduli PMem
restano collegati (banchi DDR, non hot-swap, molto più rischioso
scollegarli). Con solo `sda` (gia' preparato) + PMem presenti,
l'allowlist generico esistente basta e resta la soluzione primaria.

**Rete di sicurezza aggiuntiva, comunque implementata** (branch
`claude/fase7-real-host-hardening`, PR #30): `scripts/build-iso.sh`
ora accetta `--disk-serial <serial>` (e `--datastore-disk-serial
<serial>` per la sola topologia dual) per pinnare il disco esatto per
numero seriale invece dell'allowlist generico — deterministico,
ignora qualunque altro disco collegato. `iso/storage-single-disk.yaml`
e `iso/storage-dual-disk.yaml` usano ora placeholder
`__SYSTEM_DISK_MATCH__`/`__DATASTORE_DISK_MATCH__` (YAML flow-style) al
posto del match hardcoded, sostituiti da `build-iso.sh` in base a se il
flag è stato passato. Validato con `scripts/validate-autoinstall.py`
(sul nodo remoto, nessun Python locale disponibile) sia il caso
default sia con serial. **Non ancora testato con un boot reale.**

## 2026-08-24 — Strumenti di sviluppo installati sul nodo (dev-only)

Su richiesta esplicita dell'utente, installati sul nodo (`berlin-3eie`)
tre strumenti di sviluppo — **non fanno parte delle 14 fasi né di
`setup.sh`/`main()`**, stessa disciplina già documentata in
`setup.docx` per "Claude Code CLI sul nodo": da rimuovere prima che il
nodo passi in produzione definitiva.

- **GitHub CLI** (`gh 2.98.0`): installato via repository APT ufficiale
  di `cli.github.com` (chiave GPG dedicata, non `apt-key` deprecato).
- **Claude Code CLI** (`2.1.241`): installer nativo
  (`curl -fsSL https://claude.ai/install.sh | bash`), autenticato
  dall'utente via login OAuth interattivo (richiesto un terminale SSH
  interattivo vero, stesso motivo del wizard Vast.ai — non completabile
  da una sessione headless). Verificato funzionante con
  `claude -p "..."` non interattivo dopo il login.
- **GitHub Actions self-hosted runner** (`v2.336.0`, agent id 21,
  label `self-hosted,z8,gpu`), installato come servizio systemd
  persistente (`svc.sh install && svc.sh start`, gira come utente
  `admin` non root). **Considerazione di sicurezza sollevata prima di
  procedere**: il repo `danielesalpietro/kickstart-berlin` è
  **pubblico** — un self-hosted runner su repo pubblico è un rischio
  noto (PR da fork potrebbero eseguire codice arbitrario sul runner),
  aggravato qui dal fatto che il runner gira sulla stessa macchina
  fisica usata anche come host Vast.ai in affitto a terzi. L'utente ha
  modificato le impostazioni di sicurezza del repo (approvazione
  richiesta per workflow da collaboratori esterni) prima di procedere.
  Verificato che **nessun workflow esistente usa `runs-on:
  self-hosted`** al momento: il runner resta registrato ma inerte
  finché non viene deliberatamente agganciato a un job.
  - Nota tecnica: il comando `./config.sh` (contiene il token di
    registrazione GitHub in chiaro come argomento) è stato bloccato dal
    classificatore di sicurezza di Claude Code quando tentato via SSH
    da questa sessione — eseguito invece dall'utente nel proprio
    terminale, stesso pattern già usato per il comando daemon Vast.ai e
    l'API key.

## Stato a fine sessione (2026-08-24)

- Macchina (`berlin-3eie`, ID 148447) messa **in manutenzione per 48h**
  su Vast.ai, su richiesta dell'utente — sessione sospesa qui.
- Tre PR aperte sul repo: [#28](https://github.com/danielesalpietro/kickstart-berlin/pull/28)
  (mergiata: fix Fase 4/10), [#29](https://github.com/danielesalpietro/kickstart-berlin/pull/29)
  (aperta: console status issue #27), [#30](https://github.com/danielesalpietro/kickstart-berlin/pull/30)
  (aperta: fix storage PMem + `--disk-serial`, automazione fix
  installer Vast.ai, self-test Fase 11 completo).
- Self-test Fase 11 bloccato su un probabile blocco anti-self-rent
  lato Vast.ai (non risolvibile da questo repo) — vedi
  `logbook-fase11.md` per il dettaglio completo dell'indagine.

## 2026-08-24 (continua) — `ndctl`/`ipmctl` e `python3-pip` installati (issue #35, #37)

Ripresa la sessione dopo le 48h di manutenzione: stesse credenziali
SSH dell'utente, ma IP/porta diversi da prima (`151.64.182.141:2222`
invece di `:22` — DHCP dopo la manutenzione, o comunque non prevedibile
a priori). Da qui in poi confermato che l'accesso live al nodo funziona
di nuovo normalmente.

Su richiesta esplicita dell'utente, installati via `apt-get` (pacchetti
Ubuntu 24.04 standard, nessun repository esterno):

- **`ndctl` `77-2ubuntu2`** (repo `main`) e **`ipmctl`
  `03.00.00.0485-1build1`** (repo `universe`) — issue #35, prerequisito
  per ispezionare/riconfigurare le region PMem (`ndctl list -Ru`
  conferma quanto già visto in `lsblk`: `region0` e `region1` da 252GiB
  ciascuna, entrambe `available_size: 0` — `region1` ha già un
  namespace raw non partizionato sopra, coerente con `pmem1s` senza
  sotto-partizioni). Solo tooling di ispezione installato: **nessuna
  riconfigurazione fsdax/devdax eseguita** — quella decisione resta
  aperta in issue #35 (fsdax vs devdax, caso d'uso EMH-2 esatto).
- **`python3-pip`** (`pip 24.0` su Python 3.12.3) — issue #37.

Entrambe le installazioni verificate a basso rischio prima di
procedere (pacchetti standard, nessuna modifica a dati/config
esistenti) — nessun servizio interrotto (`docker`, `containerd`,
`vastai.service`, `vast_metrics.service` tutti ancora attivi dopo
entrambe). L'installazione di `ndctl`/`ipmctl` ha triggerato un
riavvio automatico di `vast_metrics.service` da parte di `needrestart`
(dipendenza di libreria toccata) — verificato attivo subito dopo,
nessun impatto.

## 2026-08-24 (continua) — `region1` riconfigurata in `fsdax` (issue #35)

Informazione arrivata da un'altra sessione/progetto (EMH-2), **non
presa per buona senza verifica indipendente**: dettaglio `ipmctl`/`ndctl`
sulla topologia PMem reale, con la conclusione che entrambe le region
AppDirect hanno `FreeCapacity: 0.000 GiB` (tutta la capacità è già
allocata in namespace esistenti, non c'è "spazio libero" da trovare) e
che abilitare EMH-2 richiede distruggere/ricreare il namespace di
`region1` (`pmem1s`, vuota/mai montata) in modalità `fsdax` o `devdax`.

Verificato di persona sul nodo prima di agire, non fidandosi del solo
testo incollato:

- `ipmctl show -dimm`: 4 DIMM Optane, 126.422 GiB ciascuno, `Disabled,
  Frozen` — confermato identico.
- `ipmctl show -region`: 2 region AppDirect da 252 GiB, entrambe
  `FreeCapacity: 0.000 GiB` — confermato identico.
- `ndctl list -Nu`: `namespace1.0` → `pmem1s`, modalità `sector` —
  confermato identico.
- `grep pmem1 /etc/fstab`: nessun risultato — nessuna automazione del
  repo né nient'altro sul nodo referenzia `pmem1s`. `namespace0.0` →
  `pmem0s` (root, `/boot/efi`, Datastore — tutto ciò che è vivo sul
  nodo) resta un namespace completamente separato, non toccato
  dall'operazione.

Eseguito su conferma esplicita dell'utente:

```
sudo ndctl destroy-namespace namespace1.0 --force
sudo ndctl create-namespace -r region1 -m fsdax
```

Risultato: `namespace1.0` ora in modalità `fsdax`, block device
`pmem1` (senza il suffisso "s" — la "s" indicava la modalità sector
precedente), 248.1G. Verificato dopo l'operazione: `docker`,
`containerd`, `vastai.service`, `vast_metrics.service` tutti ancora
attivi, `/` (su `pmem0s2`, namespace0.0) invariato — nessun impatto
sul resto del nodo, come atteso data la separazione fra region0/region1.

**Non ancora fatto**: nessun filesystem creato su `/dev/pmem1`, nessun
mount — la riconfigurazione fsdax è il prerequisito per EMH-2, non
l'integrazione stessa (fuori scope di questo repo, che tratta la Z8
come host GPU generico, non come nodo EMH-2 specifico — resta un'area
di lavoro esterna a kickstart-berlin, coordinarsi con l'altra
sessione/progetto per i passi successivi).

## 2026-08-24 (continua) — fix #34 (admin nel gruppo docker) applicato live, non solo nel repo

Il fix di `phase5_docker()` (PR #38, issue #34: `usermod -aG docker
admin`) corregge solo le **future** installazioni via `setup.sh` — non
si applica retroattivamente a un nodo già installato, come confermato
dall'utente con una sessione SSH del tutto nuova (`id admin` non
elencava `docker`, non un problema di cache di gruppo della sessione
corrente). Applicato lo stesso fix live sulla Z8:

```
sudo usermod -aG docker admin
```

Verificato da una sessione SSH nuova (necessario: l'appartenenza a un
gruppo si aggiorna solo al login successivo, non nella sessione già
attiva) — `id admin` ora include `988(docker)`, `docker ps` funziona
senza `sudo`. Il gruppo `docker` (gid 988) prima conteneva solo
`vastai_kaalia`, confermando il bug.

## Prossimi passi

- [x] Riconciliare il branch — vedi sezione sopra.
- [x] Portare nel repo i tre fix (Problema 2, 3, 4) — applicati su
      `claude/postinstall-firstboot-fixes` e verificati end-to-end sul
      nodo reale.
- [x] Decidere se/come rendere deterministica la selezione disco
      rispetto ai moduli PMem — Problema 1, **corretto** (allowlist per
      path) e rafforzato con `--disk-serial` opzionale per il caso
      multi-disco scoperto sopra.
- [x] `ndctl`/`ipmctl` installati (issue #35) — riconfigurazione
      fsdax/devdax di `region1` resta una decisione aperta, non ancora
      presa.
- [x] `python3-pip` installato (issue #37).
- [ ] Valutare se riportare anche `docs/setup.md`/`docs/setup.docx` in
      `develop` (mai fusi dopo la PR #23).
- [ ] Mergiare le PR aperte quando approvate/riviste dall'utente
      (vedi issue/PR tracker per lo stato aggiornato — cresciuto molto
      in questa sessione, non elencato singolarmente qui per evitare
      che questa lista invecchi rispetto a GitHub).
- [ ] Prossimo reinstall da zero: dischi Windows scollegati fisicamente
      prima, PMem lasciato collegato — verificare che il fix Problema 1
      funzioni davvero su un boot reale (non ancora testato). **Nota
      2026-08-24**: il piano è cambiato in corso di sessione — l'utente
      vuole riusare MZ1L2960HCJR (NVMe, oggi ancora NTFS/Windows) come
      disco Datastore/container invece di scollegarlo soltanto, quindi
      il reinstall futuro dovrà wipare quel disco specifico, non solo
      escluderlo — vedi conversazione, non ancora in un logbook
      dedicato al reinstall.
- [ ] Rimuovere gli strumenti dev-only (gh, claude, actions runner)
      prima che il nodo passi in produzione definitiva.
- [ ] Capire con supporto Vast.ai come sbloccare il self-test (Fase 11,
      vedi `logbook-fase11.md`).
- [ ] issue #36 (CUDA toolkit nativo): ancora da decidere se serve un
      caso d'uso non containerizzato prima di installarlo.
