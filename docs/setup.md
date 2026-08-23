# Guida operativa: dal BIOS al check finale

Procedura passo-passo per portare un nodo fisico da spento a host pronto
(e, opzionalmente, listato su Vast.ai) con l'ISO generata da
`scripts/build-iso.sh`. Per il contesto di progetto e le decisioni dietro
ogni fase vedi [`CLAUDE.md`](../CLAUDE.md) e il `logbook-faseN.md`
corrispondente — questa guida è solo la sequenza operativa, non ripete le
motivazioni già documentate altrove.

> **Nota sull'ISO usata in questa procedura**: questa guida assume un'ISO
> già buildata in precedenza, **non ricostruita ora**. Il contenuto di
> `postinstall/` imposto sul nodo al primo boot è quello congelato al
> momento del build — se il branch `develop` del repo è avanzato da
> allora (nuove fasi, bug fix), l'ISO non lo sa. Lo **Step 4** qui sotto
> compensa questo scarto: appena il nodo ha rete, si importa il branch
> corretto dal repo GitHub prima di procedere con i passi manuali (Fase 7
> in poi), così questi ultimi girano sempre con l'ultima versione nota
> invece che con quella eventualmente superata congelata nell'ISO.

## Requisiti

### Comuni a qualunque setup

| Categoria | Requisito |
|---|---|
| Rete | Connessione diretta a Internet dal nodo target (raggiungibilità reale di `get.docker.com`, `nvidia.github.io`, `vast.ai` — nessuna di queste è bloccata su un host reale, a differenza del sandbox di sviluppo) |
| Chiavetta USB | ≥ 8 GB, scrivibile — vedi [`usb-boot.md`](usb-boot.md) per `dd`/balenaEtcher/Rufus |
| Chiave SSH | Coppia di chiavi SSH (es. `~/.ssh/id_ed25519`); la **pubblica** va iniettata a build-time dell'ISO (`build-iso.sh -k`), mai committata nel repo |
| Workstation operatore | `git`, accesso di rete a GitHub, un modo per scrivere l'ISO su USB |
| Firmware nodo | **Boot UEFI obbligatorio** — il legacy BIOS non è supportato (vedi `logbook-fase2.md`); verificare che il firmware non sia forzato in modalità legacy/CSM |

### Solo se si vuole completare anche Fase 7/10/11 (host Vast.ai reale)

| Categoria | Requisito |
|---|---|
| Account | Account host Vast.ai attivo, accesso a `cloud.vast.ai` da browser |
| Comando daemon (Fase 7) | Va **generato al momento** da `cloud.vast.ai/host/setup` — valido 1 ora, non recuperabile in anticipo |
| API key (Fase 10) | Da `cloud.vast.ai/manage-keys/?tab=api-keys`, configurata a mano dopo il boot — mai automatizzata |
| Router/firewall perimetrale | Il range di porte (vedi tabella sotto) va aperto **anche sul router**, non solo su `ufw` dell'host — passo manuale, Fase 12 (port forwarding) non ancora implementata in questo repo |

### Per topologia disco (scelta a build-time con `--disks`)

| Topologia | Requisito hardware | Quando usarla |
|---|---|---|
| `--disks 1` (default) | Un solo disco fisico | Sistema e Datastore condividono lo stesso disco |
| `--disks 2` | Due dischi fisici distinti | Sistema sul disco più piccolo, Datastore sull'intero secondo disco — topologia tipica su workstation con più bay, es. Z8 G4 |

## Informazioni richieste durante il setup

| # | Informazione | Dove si ottiene | Quando serve | Nota |
|---|---|---|---|---|
| 1 | Chiave pubblica SSH | Generata in anticipo dall'operatore (`ssh-keygen`) | Step 0, build ISO (`-k`) | Mai committata nel repo |
| 2 | Topologia dischi (1 o 2) | Decisione operatore, in base all'hardware del nodo | Step 0, build ISO (`--disks`) | Default: 1 (`config/autoinstall-defaults.json`) |
| 3 | Size partizione sistema | Decisione operatore (default `100G`) | Step 0, build ISO (`--system-size`) | Rilevante solo con `--disks 1` |
| 4 | Prefisso hostname | Decisione operatore (default `berlin`) | Step 0, build ISO (`--hostname-prefix`) | Hostname finale `<prefix>-XXXX` generato a install-time, non a build-time |
| 5 | Range porte TCP+UDP | Decisione operatore (default `16384-32768`, guida ufficiale Vast.ai) | Step 0, build ISO (`--port-range`); poi di nuovo Step 6 (router) | Va aperto sia su `ufw` (automatico, Fase 6) sia sul router (manuale) |
| 6 | Branch/commit da usare | `git log`/GitHub, repo `danielesalpietro/kickstart-berlin` | Step 4, dopo il primo boot | Vedi nota in cima al documento |
| 7 | Comando d'installazione daemon Vast.ai | `cloud.vast.ai/host/setup`, da loggati come host | Step 5 (Fase 7) | Valido 1 ora, mai in shell history, mai loggato |
| 8 | API key `vastai` | `cloud.vast.ai/manage-keys/?tab=api-keys` | Step 7 (Fase 10, configurazione) | Mai hardcoded/committata |
| 9 | `machine_id` | `vastai show machines`, dopo un listing riuscito | Step 8 (Fase 11, self-test) | Esiste solo dopo Step 5 completato con successo |

## Sequenza, passo-passo

### Step 0 — Preparazione (workstation operatore, prima di toccare il nodo)

```sh
# Esempio: 2 dischi fisici, hostname personalizzato
scripts/build-iso.sh \
  -k ~/.ssh/id_ed25519.pub \
  --disks 2 \
  --hostname-prefix berlin \
  --port-range 16384-32768
```

Scrivi l'ISO risultante su USB seguendo [`usb-boot.md`](usb-boot.md)
(`dd`, balenaEtcher o Rufus — modalità DD/immagine, non "file").

### Step 1 — BIOS/UEFI del nodo

1. Accendi il nodo, entra nel setup BIOS/UEFI (tipicamente `F10`/`F11`
   su workstation HP, verificare il tasto esatto a schermo all'accensione).
2. Conferma che il boot sia **UEFI**, non legacy/CSM (requisito non
   negoziabile di questo repo — vedi `logbook-fase2.md`).
3. **Secure Boot**: consigliato disattivarlo prima del primo boot.
   *Non è un passo automatizzato o testato da questo repo* — il driver
   NVIDIA installato in Fase 4 (`ubuntu-drivers autoinstall`, modulo
   DKMS) può richiedere l'enrollment MOK di una chiave se Secure Boot
   resta attivo; questo repo non gestisce quel flusso, quindi la via
   verificata è disattivarlo. Se necessario mantenerlo attivo, trattalo
   come collaudo manuale aggiuntivo, non coperto da
   `docs/collaudo-funzionale.md`.
4. Collega la chiavetta USB, seleziona il boot menu (tipicamente
   `F9`/`F11`/`Esc` a seconda della scheda madre) e avvia da USB.

### Step 2 — Autoinstall automatico (Fasi 1-2)

Nessuna interazione richiesta: l'autoinstall (`iso/user-data`) parte da
solo, partiziona i dischi secondo la topologia scelta a Step 0, installa
Ubuntu Server e inietta la chiave SSH. Al termine il nodo si riavvia da
solo.

### Step 3 — Postinstall automatico (Fasi 3-6, 8, 10 — dal contenuto congelato nell'ISO)

Al primo boot post-installazione, `kickstart-berlin-postinstall.service`
(systemd oneshot) esegue `postinstall/setup.sh` senza intervento:
storage Docker sul Datastore, driver NVIDIA + Container Toolkit (rileva
la RTX 3090 via PCI vendor `0x10de`, un solo riavvio automatico se serve
caricare il modulo kernel), Docker, apertura porte `ufw`, raccolta info
hardware, installazione CLI `vastai`. Attendi che il nodo torni
raggiungibile via SSH come utente `admin` con la chiave iniettata.

```sh
ssh admin@<ip-o-hostname-nodo>
```

### Step 4 — Importa il branch corretto (con la rete ora disponibile)

Questo è il passo che compensa il fatto che l'ISO non è stata
ricostruita per questa procedura (vedi nota in cima al documento). Dal
nodo, ora raggiungibile e con rete diretta:

```sh
git clone --branch develop https://github.com/danielesalpietro/kickstart-berlin.git /opt/kickstart-berlin-src
```

Confronta `/opt/kickstart-berlin-src/postinstall/` con
`/opt/kickstart-berlin/` (quanto eseguito allo Step 3, congelato
nell'ISO):

- Se identici (o le differenze non toccano fasi già eseguite), procedi:
  usa `/opt/kickstart-berlin-src/postinstall/install-vastai-host.sh` e
  `/opt/kickstart-berlin-src/postinstall/vastai-self-test.sh` per gli
  step manuali successivi — sono script standalone, non è un problema
  che non fossero nell'ISO originale o fossero una versione precedente.
- Se `setup.sh` è cambiato in un punto già eseguito (bug fix su una fase
  automatica): valuta se rieseguire a mano la funzione `phaseN_...()`
  corretta dalla copia clonata (sono tutte idempotenti per design — vedi
  `CLAUDE.md`, direttiva 5) prima di proseguire.

### Step 5 — Fase 7: daemon host Vast.ai reale (manuale)

1. Da browser, loggato come host su `cloud.vast.ai/host/setup`, genera
   il comando d'installazione (valido 1 ora) e salvalo in un file
   temporaneo sul nodo (mai incollato direttamente in shell).
2. Esegui:

```sh
sudo /opt/kickstart-berlin-src/postinstall/install-vastai-host.sh --command-file <path-al-file>
```

Lo script distrugge il file col comando (`shred -u`) subito dopo l'uso
e non stampa mai il comando nei log. Su fallimento, controlla
`vast_host_install.log` sul nodo.

### Step 6 — Verifica listing e apertura porte sul router

1. Verifica su `cloud.vast.ai/host/machines/` (o `vastai show machines`,
   dopo Step 7) che il nodo risulti listato.
2. Apri **sul router/firewall perimetrale** lo stesso range di porte
   configurato a Step 0 (default `16384-32768`, TCP+UDP) — passo
   manuale, non automatizzato da questo repo (Fase 12 non ancora
   implementata).

### Step 7 — Fase 10: verifica/configurazione CLI `vastai`

La CLI è già installata automaticamente allo Step 3. Configura
l'autenticazione a mano:

```sh
vastai set api-key <la-tua-api-key>   # da cloud.vast.ai/manage-keys/?tab=api-keys
vastai show user                       # conferma che l'autenticazione funzioni
vastai show machines                   # recupera il machine_id per lo step successivo
```

### Step 8 — Fase 11: self-test ufficiale (manuale)

```sh
/opt/kickstart-berlin-src/postinstall/vastai-self-test.sh --machine-id <ID>
```

Verifica driver/CUDA, banda di rete, porte aperte, banda PCIe, VRAM,
RAM/CPU e affidabilità sotto carico simulato. Se fallisce con "not
found or not rentable": ritira e rilista la macchina (Step 5/6), poi
riprova.

### Check finale

- [ ] `vastai show machines` mostra il nodo come listato e attivo.
- [ ] `/opt/kickstart-berlin/hardware-info.json` (Fase 8) ha il campo
      `nvidia_gpu` popolato con la RTX 3090 (non vuoto/errore).
- [ ] `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi`
      mostra la GPU dentro un container.
- [ ] Self-test Fase 11 (Step 8) completato con successo.
- [ ] Porte aperte confermate sia su `ufw` (Fase 6, automatico) sia sul
      router (Step 6, manuale).
- [ ] Aggiorna `docs/collaudo-funzionale.md`: sposta a "Confermato" le
      righe di questa procedura effettivamente verificate, con
      riferimento a questo run; registra il dettaglio (comandi, output,
      eventuali problemi) nel `logbook-faseN.md` di ciascuna fase
      coinvolta — disciplina di progetto, vedi `CLAUDE.md` direttiva 7.
