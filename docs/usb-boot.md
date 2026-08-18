# Scrivere l'ISO su chiavetta USB

L'ISO generata da `scripts/build-iso.sh` è un'immagine ibrida (BIOS legacy +
UEFI): può essere scritta direttamente su una chiavetta USB con `dd` o con
strumenti grafici come balenaEtcher/Rufus, senza bisogno di un tool di
"ISO-to-USB" dedicato.

## Linux/macOS — `dd`

```sh
# Trova il device della chiavetta (ATTENZIONE: dd sovrascrive senza chiedere
# conferma; verifica con cura di aver individuato il device giusto, es. con
# `lsblk` su Linux o `diskutil list` su macOS — MAI la partizione, es. sdb1).
lsblk

sudo dd if=build/kickstart-berlin-24.04.2-autoinstall.iso \
        of=/dev/sdX \
        bs=4M status=progress conv=fsync
sync
```

Sostituisci `/dev/sdX` con il device reale della chiavetta (es. `/dev/sdb`,
**non** `/dev/sdb1`). Su macOS il device tipicamente è `/dev/diskN` (usa
`/dev/rdiskN` per una scrittura più veloce).

## balenaEtcher / Rufus (Windows, macOS, Linux)

1. Apri [balenaEtcher](https://etcher.balena.io/) (multipiattaforma) o
   [Rufus](https://rufus.ie/) (Windows).
2. Seleziona il file ISO generato.
3. Seleziona la chiavetta USB di destinazione.
4. Avvia la scrittura ("Flash!" / "Start"). Su Rufus, se richiesto, scegli
   modalità **DD/immagine** (non "ISO image scritta in modalità file") per
   preservare la struttura ibrida dell'immagine.

## Boot dalla chiavetta

1. Collega la chiavetta al nodo target.
2. Entra nel boot menu/BIOS-UEFI setup (tipicamente `F11`/`F12`/`Esc`/`Del`
   all'accensione, a seconda della scheda madre) e seleziona la chiavetta
   come dispositivo di avvio.
3. L'installazione autoinstall parte automaticamente, senza alcun prompt
   (vedi `iso/user-data`); al termine il nodo si riavvia da solo.
4. A riavvio completato, il nodo è raggiungibile via SSH come utente
   `admin` con la chiave pubblica iniettata in fase di build
   (`scripts/build-iso.sh -k <chiave>`). Il login via password è
   disabilitato.

## Alternative future: boot via rete (PXE/iPXE)

Per un parco macchine più ampio, scrivere manualmente una chiavetta per
ogni nodo non scala. Un'alternativa da valutare in futuro è il boot via
rete con PXE o [iPXE](https://ipxe.org/): il nodo scarica kernel/initrd (e
lo stesso autoinstall `user-data`/`meta-data`, serviti via HTTP invece che
da `/cdrom/server/`) direttamente da un server di boot in rete, senza
bisogno di supporti fisici. Non è nello scope della Fase 1 (vedi README e
issue #1): l'ISO USB resta il meccanismo di riferimento per ora.
