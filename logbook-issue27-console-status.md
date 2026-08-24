# Logbook — Issue #27: console status su tty1 (stile DCUI ESXi)

Diario di design e collaudo per l'issue #27. Non una delle 14 fasi
mappate da Vast.ai (Vast.ai non ha un equivalente DCUI) — aggiunta
originale, proposta dall'utente durante il primo collaudo reale su
hardware fisico (Z8, 2026-08-23), nel momento esatto in cui è mancato
un modo di leggere l'IP del nodo dallo schermo locale (vedi
`logbook_first_boot.md`). Branch: `claude/issue27-console-status`,
basato su `develop`.

## 2026-08-23 — Design

Obiettivo (issue #27): sostituire il prompt di login su tty1 — comunque
inutilizzabile, nessuna password valida esiste per design (CLAUDE.md
direttiva #1, solo chiave SSH) — con una schermata informativa di sola
lettura: hostname, IP, versione OS/kernel, stato Datastore, GPU, comando
SSH pronto. Nessun equivalente di `<F2>`/`<F12>` della DCUI ESXi che ha
ispirato l'issue: nessuna interazione gestita.

Due file nuovi in `postinstall/`, stesso pattern di
`kickstart-berlin-postinstall.service`:

- `console-status.sh` — loop infinito (refresh interno, non demandato a
  `Restart=` systemd, che copre solo un crash del processo), stampa lo
  stato corrente e dorme. Nessun `set -e`: un comando fallito in
  un'iterazione (es. `nvidia-smi` non ancora pronto) non deve fermare
  lo script, solo quella riga in quel giro.
- `kickstart-berlin-console-status.service` — `Conflicts=getty@tty1.service`
  (ferma il getty di tty1 quando la nostra unit parte, lasciando
  tty2-6 intonsi per la shell classica via Alt+F2…Alt+F6, richiesta
  esplicita dell'utente), `StandardInput=null` (nessun input mai letto,
  difesa in profondità oltre al fatto che lo script non legge stdin),
  `TTYPath=/dev/tty1` + `TTYReset`/`TTYVHangup`/`TTYVTDisallocate`.

Installazione automatica: nuova `console_status_setup()` in
`postinstall/setup.sh`, chiamata da `main()` — qualifica per
l'automazione secondo CLAUDE.md direttiva #2 (nessun segreto, nessuno
stato che esiste solo dopo un passo manuale, legge solo stato locale
già disponibile). Copia la unit da `/opt/kickstart-berlin/` (già lì
via le late-commands di `iso/user-data`, che copiano l'intero
`postinstall/` — direttiva #6) a `/etc/systemd/system/`, poi
`enable --now`. Idempotente: confronto col contenuto esistente prima di
riscrivere/ricaricare (stesso pattern di `daemon.json` in
`phase3_docker_storage()`).

`scripts/build-iso.sh`: `console-status.sh` riusa gli stessi
placeholder Datastore di `setup.sh` (`__DATASTORE_MOUNT_ROOT__`,
`__DATASTORE_SYMLINK_NAME__`), stessa sostituzione `sed`. Il file
`.service` non ha placeholder, copiato così com'è (stesso trattamento
di `kickstart-berlin-postinstall.service`).

## 2026-08-23 — Collaudo reale su Z8

Deploy manuale sul nodo reale (stessa logica di `console_status_setup()`,
eseguita a mano) per un collaudo end-to-end vero, non solo sandbox:

- Servizio `active (running)` subito dopo l'abilitazione.
- `getty@tty1.service` correttamente fermato (`Conflicts=`) — verificato
  con `systemctl status`.
- `autovt@tty2.service` ancora abilitato (Alt+F2 continua a funzionare
  per la shell classica) — non toccato dalla nuova unit.
- **Verifica del contenuto reale senza foto dello schermo**: dump del
  framebuffer testuale della console (`sudo cat /dev/vcs1`, e
  `/dev/vcsu1` per la variante Unicode-aware) — tecnica non usata prima
  in questo repo, utile per collaudi futuri di qualunque cosa scriva
  sulla console fisica.

**Due problemi trovati e corretti nello stesso giro di collaudo** (non
solo sandbox — bug reali su schermo reale):

1. **Em-dash (`—`) invisibile sulla console reale**: presente nel sorgente
   ma assente sia in `/dev/vcs1` sia in `/dev/vcsu1` — non un artefatto
   del dump, il carattere non arriva a renderizzare sulla console
   virtuale reale (font/modalità console, non approfondito oltre).
   Sostituito con trattino ASCII (`-`) in tutto l'output mostrato
   (i commenti nel sorgente, mai mostrati sullo schermo, restano con
   l'em-dash originale per coerenza di stile col resto del repo).
2. **`docker0` (172.17.0.1) elencato tra gli IP**: tecnicamente
   corretto (interfaccia attiva) ma rumore fuorviante — un bridge
   privato mai raggiungibile dall'esterno, in un elenco il cui scopo è
   proprio "far trovare velocemente l'IP giusto". Rischio concreto: se
   l'ordine di enumerazione del kernel avesse messo `docker0` prima
   dell'interfaccia fisica, il comando SSH suggerito sarebbe stato
   sbagliato (non testato quel caso specifico, ma il filtro lo rende
   strutturalmente impossibile ora). Escluse `docker0`, `br-*`, `veth*`
   dal filtro AWK, oltre a `lo`.

Anche il refresh è stato cambiato da 5s (valore iniziale di design) a
30s su richiesta esplicita dell'utente — 5s produceva un refresh
percepito come eccessivo per una schermata la cui utilità principale è
"leggere l'IP una volta", non un dashboard di monitoraggio live.
Nota dell'utente, riportata anche come commento su issue #27: le
informazioni mostrate (hostname, IP, Datastore, GPU) sono per lo più
statiche — un intervallo anche più alto di 30s andrebbe bene. Lasciato
a 30s per ora, nessuna urgenza di ottimizzare oltre.

Ridistribuito e riverificato dopo entrambi i fix: output corretto
(niente `docker0`, trattini ASCII visibili, refresh 30s).

## Stato

Verificato end-to-end su hardware reale (Z8, RTX 3090). Non ancora
verificato: comportamento dopo un vero riavvio completo del nodo (il
collaudo qui ha installato/abilitato la unit su un sistema già avviato,
non tramite un ciclo autoinstall→boot→postinstall completo con questa
issue inclusa fin dall'ISO) — il meccanismo (`main()` →
`console_status_setup()`, stesso schema di ogni altra fase) non ha
ragione strutturale per comportarsi diversamente, ma non è lo stesso
grado di conferma delle Fasi già passate per un boot reale completo.

## Prossimi passi

- [ ] Collaudo di un boot completo da ISO ricostruita con questa issue
      inclusa (non solo deploy a caldo su un sistema già installato).
- [ ] Valutare se aggiungere alla schermata anche lo stato `ufw`
      (attivo/inattivo, porte aperte) — non incluso nella prima
      versione, l'issue originale non lo richiedeva esplicitamente tra
      le "informazioni minime".
