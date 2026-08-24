# Logbook — issue #33: menu di gestione del nodo via SSH

## Origine e scope

Nato durante il lavoro su issue #27 (console status): l'utente ha
creato un secondo mockup curses, `esx_tree.py` (non nel repo, creato
sul nodo), un vero albero di navigazione stile `<F2> Customize System`
della DCUI VMware ESXi. issue #33 traccia la valutazione e
l'implementazione.

## Precisazione decisiva dell'utente (prima di iniziare)

issue #33, come aperta inizialmente, sollevava una tensione: l'intera
progettazione di questo repo si basa su "nessun accesso locale, solo
chiave SSH" — un menu di configurazione sulla console fisica
rischierebbe di reintrodurre un vettore di accesso locale.

L'utente ha chiarito che questo tool va usato **via SSH** (dentro una
sessione già autenticata con chiave SSH + sudo), non sulla console
fisica. Questo cambia la valutazione: non introduce nessun nuovo
vettore di accesso, è un'interfaccia più comoda sopra un accesso che
l'operatore ha già per intero. Il rischio reale è "azioni distruttive
rese troppo facili da un menu" (es. un ipotetico "Reset System
Configuration" stile ESXi) — non "chi può entrare", ma "quanto è
facile fare danni una volta dentro".

## Scope confermato dall'utente (risposta esplicita)

> "non solo visualizzazione, ma anche possibilità di change, es: la
> configurazione di rete parte DHCP, ma deve poter essere impostato
> anche IP statico su tutto lo stack IP (come su ESxi); possibilità di
> riavvio dei servizi di rete, ma anche di vastai, previa
> visualizzazione dello stato attuale; in diagnostica: wrapper via
> menu dei commandi vastai; cosi come la possibilità di visualizzare i
> logs più importati del sistema operativo, ma anche di vastai."

Tradotto in quattro capability, poi confermate nella struttura di menu
(nomenclatura successivamente corretta dall'utente: "Management
Network" non "Rete", "POD" non "Vast.ai", "View System Log" non
"Log" — "usiamo sempre l'inglese nelle interfacce di admin"):

1. **Management Network** → IP Configuration (DHCP/Statico)
2. **Management Network** → Restart Network Services (stato prima)
3. **POD** → Restart Daemon (stato prima) + Diagnostics (wrapper vastai)
4. **View System Log** → log OS + log POD

## Decisioni tecniche

### Sicurezza IP statico: `netplan try`, non un rollback scritto a mano

Il rischio più concreto del intero tool: un IP/gateway/DNS statico
sbagliato blocca fuori dall'unico accesso al nodo (SSH). Invece di
scrivere una logica di backup/timeout/rollback a mano, si usa il
meccanismo nativo di Netplan pensato esattamente per questo:
`netplan try --timeout 30` applica la configurazione e chiede conferma
entro il timeout, altrimenti ripristina automaticamente quella
precedente. Preferito a una soluzione custom per lo stesso principio
già in CLAUDE.md (preferire lo strumento ufficiale/standard a una
reinvenzione locale) applicato qui in generale, non solo al caso
Vast.ai vs script community.

### File di override dedicato, non il file generato da Subiquity

`node-manage.py` non modifica/fa parsing del file netplan generato
dall'installer (nome non garantito stabile, e fare merge YAML a mano è
fragile). Scrive invece `/etc/netplan/90-kickstart-berlin-override.yaml`
— Netplan unisce i file per nome in ordine numerico (i numeri più alti
vincono sulle stesse chiavi), quindi l'override è banalmente
reversibile: basta cancellare il file + `netplan apply` per tornare ai
default dell'installer.

### Validazione input di rete con `ipaddress` (stdlib)

L'indirizzo IP/CIDR, il gateway e i DNS inseriti dall'operatore vengono
validati con `ipaddress.ip_interface()`/`ip_address()` (libreria
standard Python, nessuna dipendenza esterna — issue #37 nota che pip3
non è nemmeno installato sul nodo) prima di essere interpolati nello
YAML scritto su disco: previene sia input malformato sia un'eventuale
iniezione nello YAML.

### Ogni azione sospende curses, gira come terminale semplice

Alternativa considerata: implementare prompt/conferma/output dentro
finestre curses (come il box di issue #27). Scartata: l'output di
comandi reali (`vastai`, `journalctl`, `ping`, `netplan try`) non ha
lunghezza/formato prevedibile, e `netplan try` stesso più i pager
(`journalctl`/`less`) sono già programmi interattivi che vogliono un
vero terminale. `curses.def_prog_mode()` / `curses.endwin()` prima
dell'azione, `curses.reset_prog_mode()` dopo — pattern standard per
"uscire temporaneamente da curses", più semplice e molto più robusto
che reimplementare un pager/prompt dentro una `newwin()`.

### `vastai` sempre con `HOME=/home/admin` esplicito

Stesso bug/fix già scoperto e documentato in
`logbook-issue27-console-status.md` per `lib-node-status.sh`: l'API
key di `vastai` vive sotto `/home/admin/`, non root — `node-manage.py`
gira come root (richiede sudo per le azioni di rete/systemd) ma invoca
sempre `env HOME=/home/admin vastai ...`, indipendentemente da chi
lancia lo script.

### machine_id: stessa tecnica di issue #27, non riletta da file

`_get_machine_id()` in `node-manage.py` duplica (non richiama, per
restare un file Python autonomo senza dipendenze bash aggiuntive oltre
a `lib-node-status.sh`) la stessa tecnica di
`_vastai_machine_line()`: `vastai show machines --raw` filtrato per
hostname, non il file `/var/lib/vastai_kaalia/machine_id` (contiene un
hash interno, non l'ID numerico che i comandi `vastai ... machine <id>`
si aspettano — bug già scoperto/risolto su issue #27).

### Comandi `vastai list machine`/`unlist machine`: verificati dal sorgente ufficiale

Prima di scrivere il wrapper diagnostica, letto direttamente
`vast.py` da `github.com/vast-ai/vast-cli` (MIT, fonte secondaria
autorizzata da CLAUDE.md quando `docs.vast.ai` non è raggiungibile
dalla sandbox) per confermare la sintassi esatta invece di supporre:

- `vastai list machine <id> --price_gpu <$/h> [--price_disk <$/GB/mese>]`
- `vastai unlist machine <id>`
- `vastai show machine <id>` / `vastai show machines`
- `vastai self-test machine <id> [flag]` (già noto da Fase 11)

### Self-test: riusa `vastai-self-test.sh`, non lo reimplementa

L'azione "Run Self-Test" nel menu Diagnostics chiama lo script
standalone esistente (`/opt/kickstart-berlin/vastai-self-test.sh`,
Fase 11) invece di duplicare la logica di verifica prerequisiti/CLI —
un solo punto di verità per quel comando.

### Reso eseguibile anche per i file `.py`, non solo `.sh`

`iso/user-data` faceva `chmod +x /target/opt/kickstart-berlin/*.sh`
dopo la copia in fase di install — non copriva `console-status.py`
(invocato con `/usr/bin/python3` esplicito dalla unit systemd, quindi
il bit eseguibile non gli serviva mai finora) né avrebbe coperto
`node-manage.py` (invocato a mano dall'operatore, dove l'ergonomia di
poterlo lanciare come `sudo ./node-manage.py` conta). Aggiunta una
riga `chmod +x /target/opt/kickstart-berlin/*.py` accanto a quella
esistente per `*.sh`.

## Problema di stato scoperto e corretto in questa sessione (non issue #33)

Durante la ricognizione per issue #33 si è scoperto che il rewrite
curses completo di issue #27 (box bordato, campi estesi, fix CRLF —
commit `9f2e3d6`..`46113a0` sul branch `claude/issue27-console-status`)
era rimasto **fuori da `develop`**: la PR #29 era stata mergiata
quando il branch era ancora alla versione bash iniziale (`73dfcd5`), e
quei 4 commit successivi erano stati pushati DOPO il merge, restando
orfani. Il branch era anche rimasto indietro rispetto a `develop`
(mancavano i contenuti di PR #30/#31/#32). Risolto con un rebase pulito
su `develop` (nessun conflitto residuo, verificato che
`install-vastai-host.sh` e gli YAML di storage non fossero toccati) e
una nuova PR aperta per recuperare il lavoro. **Lezione**: quando un
branch resta aperto dopo il merge della sua PR con altri commit in
coda, verificare che quei commit vengano davvero recuperati — non
assumere che "PR mergiata" significhi "tutto il lavoro su quel branch
è in `develop`".

## Altri problemi scoperti sul nodo reale in questa sessione (issue separate)

Segnalati dall'utente durante l'uso reale del nodo, aperti come issue
indipendenti (#34-#37), non nello scope di issue #33:

- **#34** (corretto direttamente, PR #38): `admin` non era mai
  aggiunto al gruppo `docker` da `phase5_docker()` — ogni comando
  `docker` senza `sudo` falliva con "permission denied". Fix piccolo e
  verificabile, applicato invece di solo aprire l'issue.
- **#35**: region1 PMem (`pmem1s`, ~252 GiB) libera, candidata a
  fsdax/devdax per esperimenti EMH-2 — richiede `ndctl`/`ipmctl` non
  installati, decisione su automazione vs passo manuale non ancora
  presa.
- **#36**: nessun CUDA toolkit nativo (solo driver) — da confermare se
  serve un caso d'uso non containerizzato prima di implementare.
- **#37**: `pip3` assente (Python 3.12.3 presente) — da decidere se
  automatico in `setup.sh` o dev-tooling manuale.

## Stato

- **Verificato in sandbox/nodo reale (2026-08-24, sessione parallela via
  `handoff_node-manage.md`)**: nodo `berlin-3eie` (Z8, ID Vast.ai
  148447) raggiungibile con le stesse credenziali SSH del handoff (IP e
  porta non erano cambiati). Controllo sintattico
  (`python3 -c "import ast; ast.parse(...)"`) eseguito sul file via SSH
  non interattiva: **OK**, nessun errore di sintassi. File copiato con
  `sudo cp` in `/opt/kickstart-berlin/node-manage.py` (root:root,
  eseguibile) — presente e pronto per il collaudo interattivo.
- **Deliberatamente non eseguito in questa sessione**: nessuna azione
  automatizzata oltre al controllo sintattico e al deploy — scelta
  esplicita dell'utente quando gli è stato chiesto conferma prima di
  lanciare comandi `sudo` aggiuntivi sul nodo reale (status di
  rete/POD, riavvii). Il collaudo delle singole azioni e della
  navigazione curses resta da fare dall'utente stesso da un terminale
  SSH interattivo vero.
- **Non verificabile per costruzione finché non lo esegue l'utente**:
  l'intero flusso `netplan try` (comportamento reale su una NIC fisica,
  non solo sintassi), il wrapper `vastai list/unlist machine` contro
  l'account reale, la lettura dei log reali
  (`/var/lib/vastai_kaalia/*.log`), la navigazione curses stessa
  (Su/Giù/Invio/Esc/Q, resize terminale).

## Prossimi passi

- [ ] Collaudo interattivo end-to-end sul nodo Z8 da parte dell'utente
  (menu curses, azioni una per una, seguendo l'ordine di rischio
  crescente già indicato in `handoff_node-manage.md`) — il file è già
  deployato in `/opt/kickstart-berlin/node-manage.py`, lanciabile con
  `sudo /opt/kickstart-berlin/node-manage.py` da una sessione SSH
  interattiva (`ssh -t ...`).
- [ ] Verificare che `netplan try` si comporti come atteso su questa
  NIC/rete specifica (non testato su hardware reale).
- [ ] Decidere se aggiungere un'azione "Reset to DHCP" più diretta
  (oggi richiede comunque passare da "Set DHCP", che è già la stessa
  cosa — probabilmente ridondante, da verificare con l'uso reale se
  serve una scorciatoia).
- [ ] Valutare se il menu "POD" debba mostrare anche un avviso quando
  `_vastai_installed()`-equivalente è falso (Fase 7 non eseguita) prima
  di entrare nel sottomenu, invece di scoprirlo azione per azione.
