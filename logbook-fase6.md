# Logbook — Fase 6: rete (issue #6)

Diario di design e test per la Fase 6. Branch di riferimento:
`claude/fase6-network-setup`, basato sulla punta di
`claude/fase5-docker-nvidia-runtime`. Per il contesto delle fasi
precedenti vedi [`logbook-fase1.md`](logbook-fase1.md),
[`logbook-fase2.md`](logbook-fase2.md), [`logbook-fase3.md`](logbook-fase3.md),
[`logbook-fase4.md`](logbook-fase4.md), [`logbook-fase5.md`](logbook-fase5.md).

## 2026-08-19/20 — Scope: cosa è di kickstart-berlin, cosa è di un'altra fase

L'utente ha fornito il testo esatto della guida ufficiale Vast.ai
("Network Setup", sezioni Port/IP/Speed Requirements). Prima di
implementare, chiarito lo scope: buona parte di quel testo descrive
meccanismi specifici del **daemon Vast.ai** (`/var/lib/vastai_kaalia/
host_port_range`, `host_ipaddr`, `systemctl restart vastai`), che non
installiamo — la Fase 7 del README lo sostituisce esplicitamente col
backend/agent Grastorp, non ancora implementato.

Decisione di scope (basata sulla mappatura fasi già in README, non una
scelta nuova):
- **Range di porte**: la parte host-level (aprire davvero le porte sul
  firewall) è compito di kickstart-berlin ed è implementata qui. La
  parte "scrivere il range in un file che l'agente legge" non ha ancora
  un path Grastorp noto — kickstart-berlin memorizza il range in
  `config/autoinstall-defaults.json` (stessa fonte di verità già usata
  per size partizione, hostname, ecc.), cosicché quando il backend
  Grastorp esisterà (Fase 7) potrà leggerlo da lì senza duplicare il
  valore.
- **Override IP**: non implementato. La guida stessa lo descrive come
  eccezione rara (NAT asimmetrici) — nessun requisito Grastorp concreto
  oggi per giustificarlo.
- **Speed test**: appartiene a Fase 11 (assessment one-shot, vedi
  README: "Self-test/benchmark... Speedtest di rete + verifica GPU/RAM/
  rete"), non a questa fase. Non implementato qui per non duplicare
  scope tra fasi.
- **DHCP e hostname**: già coperti da fasi precedenti (DHCP è il default
  Ubuntu Server, nessuna azione necessaria; hostname univoco per nodo
  implementato in Fase 3, vedi `logbook-fase3.md`) — non c'è altro da
  fare qui per questi due punti della mappatura README originale.

## 2026-08-19/20 — Implementazione

- `config/autoinstall-defaults.json`: nuova sezione `network` con
  `port_range_start`/`port_range_end` (default 16384-32768, stesso
  esempio della guida ufficiale — range ampiamente sufficiente per
  qualunque configurazione realistica, non scalato per numero di GPU).
- `scripts/build-iso.sh`: nuovo flag `--port-range <START-END>`,
  validato (range 1-65535, inizio < fine, almeno 3 porte — coerente col
  minimo della guida ufficiale).
- `postinstall/setup.sh`: nuova `phase6_network()`, quarta fase della
  sequenza. Apre il range su `ufw` (TCP+UDP) **solo se ufw è già
  installato E già attivo** — non lo installa né lo abilita: non tocca
  la postura firewall esistente dell'host, si limita ad assicurare che
  il range richiesto sia raggiungibile se un firewall sta già filtrando.
  Idempotente (controlla se le regole sono già presenti prima di
  aggiungerle).
- `scripts/validate-autoinstall.py`: nuove voci nel dizionario di
  sostituzione fittizia per `__PORT_RANGE_START__`/`__PORT_RANGE_END__`.

## 2026-08-19/20 — Cosa è stato verificato

**Verificato in sandbox** (nessuna dipendenza di rete esterna per questa
fase, a differenza di Fase 4/5 — interamente testabile qui):
- `shellcheck` pulito su `build-iso.sh` e `postinstall/setup.sh`,
  `validate-autoinstall.py` passa.
- Percorso "ufw assente" (questo sandbox non ha `ufw` installato, come
  probabilmente capiterà su alcune installazioni Ubuntu Server minimali):
  la funzione rileva l'assenza e ritorna puliata, nessun errore.
- Percorso "ufw attivo" testato con uno stub che simula `ufw status`/
  `ufw allow`: primo giro aggiunge le regole TCP+UDP per il range
  configurato, secondo giro le rileva già presenti e non le riaggiunge
  (idempotenza confermata).

**Non verificato** (richiede un host reale con `ufw` vero installato):
che `ufw allow <range>/tcp` e `/udp` producano davvero le regole attese
su un sistema reale — la logica è stata validata solo contro uno stub
del comando `ufw`, non contro il binario vero. Da confermare sulla VM
Azure (dove `ufw` dovrebbe essere presente di default su Ubuntu Server)
o sulla Z8.

## 2026-08-20 — Confermato su host reale (VM Azure) con ufw vero

VM-TEST2 (rete diretta), `ufw` già presente ma inattivo. Prima di
attivarlo: aggiunta esplicita la regola `OpenSSH` (`ufw allow OpenSSH`)
per non perdere l'accesso — verificato con una nuova connessione SSH
subito dopo `ufw --force enable` che l'accesso resta funzionante.

`postinstall/setup.sh` sorgentato con `main "$@"` disabilitato (stesso
procedimento delle fasi precedenti), placeholder sostituiti coi valori
reali (`16384`/`32768`), invocato `phase6_network` direttamente due
volte:

1. **Primo giro**: regole aggiunte correttamente — `16384:32768/tcp` e
   `/udp`, sia IPv4 che IPv6 (`ufw` genera automaticamente la coppia
   v4/v6 per ogni regola).
2. **Secondo giro (idempotenza)**: rilevate le regole già presenti
   (`ufw status | grep` trova il match), nessuna riaggiunta, nessuna
   duplicazione — confermato con `ufw status numbered`, ancora
   esattamente 6 regole (OpenSSH + range TCP/UDP, v4+v6).

Nessun bug trovato: il comportamento con `ufw` vero corrisponde
esattamente a quanto validato con lo stub in sandbox. Host ripristinato
allo stato precedente dopo il test (`ufw --force disable`).

## Prossimi passi

- [x] Confermare su un host reale (VM Azure o Z8) che le regole ufw
      vengano scritte correttamente col comando vero — **confermato
      sopra**.
- [ ] Quando la Fase 7 (backend/agent Grastorp) prende forma, collegare
      la lettura del range porte da `config/autoinstall-defaults.json`
      invece di lasciarlo solo nel firewall.
- [ ] Aprire la PR (la Fase 6 è ora pienamente confermata, nessun
      blocco residuo per questa fase specifica).
