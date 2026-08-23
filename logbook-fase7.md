# Logbook — Fase 7: daemon host Vast.ai reale (issue #7)

Diario di design e test per la Fase 7. Branch di riferimento:
`claude/fase7-vastai-daemon-real`, basato sulla punta di
`claude/fase8-hardware-info`. Per il contesto delle fasi precedenti vedi
[`logbook-fase1.md`](logbook-fase1.md) … [`logbook-fase6.md`](logbook-fase6.md),
[`logbook-fase8.md`](logbook-fase8.md).

## 2026-08-20 — Cambio di direzione strategica (con l'utente)

Fino a questo punto il README classificava Fase 7 come "Sostituito: qui
va installato il backend/agent Grastorp stesso, non un daemon di terzi"
— decisione presa prima di questa sessione. L'utente ha chiarito la
sequenza corretta: **prima** il nodo deve funzionare come host Vast.ai
reale e completo (daemon, CLI, listing), per avere la certezza che
l'intero stack costruito finora (Fasi 1-6, 8) sia davvero compatibile
end-to-end con l'ecosistema Vast.ai — **poi**, solo dopo aver confermato
questo, si evolve verso l'architettura ESX-style specifica di Grastorp.
Non è quindi un ripensamento dell'architettura ESX-style già costruita,
ma un riordino: convalida "as-is" prima, adattamento dopo.

Buona notizia verificata rileggendo il lavoro già fatto: il layer
ESX-style di Fase 2/3 (Datastore su `/grastorp/volumes/<uuid>`,
`/var/lib/docker` come symlink verso di esso) è stato progettato fin
dall'inizio proprio per questo scenario — qualunque tooling Vast.ai che
si aspetti il path standard `/var/lib/docker` dovrebbe continuare a
funzionare senza modifiche, symlink o mount diretto non fa differenza
per un installer che controlla solo l'esistenza/scrivibilità del path.
Non è stato quindi necessario tornare indietro su Fase 2/3 per questo
cambio di direzione.

## 2026-08-20 — Vincolo pratico: comando d'installazione account-specifico

Il comando di installazione ufficiale del daemon Vast.ai (guida
ufficiale, sezione "Install the Vast.ai Manager Software") va copiato da
`https://cloud.vast.ai/host/setup`, da loggati come host — **contiene
l'identità dell'account ed è valido solo un'ora dalla generazione**.
Conseguenze dirette sul design:

- **Non può essere incorporato nell'ISO a build-time**: il tempo fra
  build e boot reale della macchina supera quasi certamente l'ora di
  validità.
- **Non può far parte della sequenza automatica di `postinstall/
  setup.sh`** (eseguita al primo boot via systemd oneshot,
  `main()` → `phaseN_...()`): l'orario del primo boot non è
  prevedibile/sincronizzabile con la generazione del comando dal
  portale.
- Va quindi eseguito **a mano dall'operatore**, dopo che il nodo è già
  installato e raggiungibile, nel momento in cui si è pronti a
  copiare il comando fresco dal portale — stessa disciplina già
  applicata alla chiave SSH: nessun segreto/identità mai hardcoded o
  committato nel repo.

## 2026-08-20 — Implementazione

Nuovo script standalone `postinstall/install-vastai-host.sh`,
deliberatamente **escluso** dalla sequenza automatica di `setup.sh` (non
è una `phaseN_...()` chiamata da `main()`, ma uno script separato
copiato comunque sul target dalla stessa infrastruttura late-commands
già esistente — `cp -r /cdrom/postinstall/. /target/opt/kickstart-berlin/`
copia già l'intera directory, il late-command `chmod +x` è stato esteso
da un singolo file (`setup.sh`) a `*.sh` per coprire anche questo nuovo
script senza doverlo elencare esplicitamente).

- **Input**: `--command-file <path>`, mai un argomento diretto sulla
  riga di comando (resterebbe nella shell history in chiaro). Il file
  deve contenere esattamente il comando copiato dal portale.
- Il file viene letto e **distrutto immediatamente** dopo (`shred -u`,
  fallback `rm -f` se `shred` non disponibile) — nessun motivo di
  lasciare un'identità d'account valida un'ora più a lungo del
  necessario su disco.
- Il comando non viene mai stampato nei log (solo un messaggio generico
  "eseguo l'installer, comando non loggato").
- Verifica permessi root (`EUID -eq 0`) prima di procedere.
- Su fallimento dell'installer, rimanda l'operatore a
  `vast_host_install.log` (stessa indicazione della guida ufficiale,
  sezione Troubleshooting) invece di tentare una diagnosi automatica —
  il contenuto/formato di quel log non è documentato nella guida.

`scripts/build-iso.sh`: il nuovo script non ha placeholder, copiato
così com'è nello staging dell'ISO (prima mancava — build-iso.sh copiava
esplicitamente solo `setup.sh` e il file `.service`, non l'intera
directory `postinstall/` del repo).

## 2026-08-20 — Cosa è stato verificato

**Verificato in sandbox** (interamente, nessuna dipendenza di rete
esterna: lo script non contatta mai la rete da solo, esegue solo il
comando fornito):
- `shellcheck` pulito, sintassi bash valida.
- Percorso `--command-file` mancante: errore chiaro.
- Percorso file non trovato: errore chiaro.
- Percorso file vuoto: errore chiaro.
- Percorso "felice" con un comando fittizio (`echo`, non il vero
  installer Vast.ai): eseguito con successo, e soprattutto confermato
  che il file col comando viene **davvero distrutto** subito dopo
  l'uso, non lasciato su disco.

**Non verificabile in sandbox** (per costruzione, non un limite
temporaneo): il vero comando d'installazione Vast.ai richiede un
account host reale e loggato — non è qualcosa che si possa simulare o
precostruire. Da testare quando l'utente fornirà un comando reale
copiato dal portale, sulla VM Azure o sulla Z8.

## 2026-08-20 — Percorsi sintetici confermati su host reale (VM Azure)

Nessuna dipendenza di rete/account in questi percorsi (lo script non
contatta mai la rete da solo), quindi rieseguibili identici fuori dal
sandbox — su VM-TEST2, con lo script vero (non uno stub):

1. `--command-file` mancante → `usage` + errore chiaro, exit 1.
2. File non trovato → errore chiaro, exit 1.
3. File vuoto → errore chiaro, exit 1, **e il file viene comunque
   distrutto** (la `shred -u`/fallback `rm -f` avviene prima del
   controllo di vuotezza nel codice — confermato che è così anche nella
   pratica, non solo leggendo la sorgente).
4. Eseguito senza `sudo` → controllo `EUID -eq 0` blocca correttamente
   con errore chiaro, exit 1.
5. Percorso felice con un comando finto (`echo "..."; hostname`):
   eseguito con successo (exit 0), il comando reale non è mai stampato
   nei log (solo un messaggio generico), e il file col comando è
   **confermato distrutto** dopo l'uso (`ls` → "No such file").

Nessun bug trovato: comportamento identico a quanto già validato in
sandbox con lo stub, ora confermato con il binario/ambiente reale.

**Resta non testabile senza un comando reale** (per costruzione, non un
limite temporaneo): l'installazione effettiva del daemon Vast.ai
richiede un comando account-specifico copiato da
`cloud.vast.ai/host/setup` (valido 1 ora) — va fornito dall'utente
quando pronto a testare il listing reale.

## Prossimi passi

- [x] Verificare i percorsi sintetici (validazione argomenti,
      distruzione del file) su un host reale, non solo nel sandbox con
      stub — **confermato sopra**.
- [ ] Testare con un comando reale copiato da `cloud.vast.ai/host/setup`
      su un host con rete diretta (VM Azure) — confermare che l'intero
      stack costruito finora (Datastore ESX-style, Docker, driver
      NVIDIA se disponibile, rete) sia davvero riconosciuto come
      compliant dall'installer/daemon Vast.ai. Richiede che l'utente
      generi e fornisca il comando (identità account, valido 1 ora).
- [ ] Se l'host viene listato con successo: Fase 10 (CLI `vastai` +
      self-test) e Fase 13 (listing) tornano ad avere un `machine_id`
      reale su cui operare — riprenderle a quel punto.
- [ ] Aprire la PR quando confermato con un comando reale (i percorsi
      sintetici sono già pienamente confermati e non bloccano la PR).
