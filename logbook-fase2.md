# Logbook — Fase 2: partizionamento disco (issue #2)

Diario di design e test per la Fase 2. Branch di riferimento:
`claude/fase2-partizionamento-disco`. Per il contesto della Fase 1
(ISO/autoinstall base) vedi [`logbook-fase1.md`](logbook-fase1.md).

## 2026-08-18 — Decisioni di design (con l'utente, prima di implementare)

- **Datastore path**: nessun path già definito da Grastorp altrove →
  default deciso qui, poi rivisto (vedi sotto) a convenzione ESXi-style
  su richiesta esplicita: `/vmfs/volumes/<UUID>` con symlink
  human-readable è il pattern VMware; per non promettere compatibilità
  con tooling VMware che qui non esiste (non gira ESXi), si usa un
  namespace proprio: `/grastorp/volumes/<UUID>` + symlink
  `/grastorp/volumes/datastore` → UUID. Nome symlink fisso ("datastore"),
  non parametrizzato a build-time (un solo datastore per nodo in questa
  fase).
- **Multi-disco/RAID**: la logica "se N dischi extra, scegli il livello
  di ridondanza adeguato (RAID1/5/6 o EC)" non è esprimibile in modo
  dichiarativo nello `storage.config` di Subiquity/curtin (azioni
  statiche, nessun costrutto condizionale sul conteggio dischi a
  runtime). Decisione: la ridondanza multi-disco resta fuori scope per
  questa issue, demandata a uno script post-install dinamico (Fase 3,
  issue #3) dove la logica condizionale è banale in bash. Coerente con
  come Vast.ai stesso gestisce il proprio equivalente (`/var/lib/docker`
  su partizione singola o "RAID array" già pronto a monte — il loro
  installer non orchestra RAID).
- Riferimento primario usato per la conferma dello schema Vast.ai (EFI +
  root ext4 ≥80GB + resto XFS su `/var/lib/docker`, tre varianti manuale/
  auto/fallback loopback): guida host-setup ufficiale, fornita
  dall'utente.

## 2026-08-18 — Verifica schema autoinstall storage: doc ufficiale irraggiungibile dal sandbox, poi fornita dall'utente

Tentativi di raggiungere `canonical-subiquity.readthedocs-hosted.com` (e
mirror: `ubuntu.com/server/docs`, `web.archive.org`) via `WebFetch` da
questo sandbox: tutti bloccati dal proxy di rete dell'ambiente (stesso
limite già visto in Fase 1). Recuperata nel frattempo la doc di **curtin**
(il motore sottostante, non Subiquity-specific) via
`raw.githubusercontent.com/canonical/curtin` — utile ma non conclusiva
sulle estensioni Subiquity (`match` spec, sizing con percentuali).

L'utente ha fornito il PDF ufficiale ("Autoinstall configuration
reference manual") non raggiungibile dal sandbox. Estratto testo con
`pdftotext -layout` (via `poppler-utils`, installato per l'occasione) e
analizzata la sezione `storage`. Punti chiave confermati:

- **`match` spec** (azione `disk`, estensione Subiquity oltre curtin
  puro): chiavi supportate — `model`, `vendor`, `path`, `id_path`,
  `devpath`, `serial` (con globbing), `ssd: true|false`,
  `size: largest|smallest`. Chiave speciale `install-media: true`
  identifica il disco/chiavetta di boot dell'installer, **escluso
  automaticamente** dai match `ssd`/`size`.
- **Assegnazione dischi**: "Any disk action is assigned a matching
  disk – chosen arbitrarily from the set of unassigned disks if there
  is more than one, and causing the installation to fail if there is no
  unassigned matching disk." → conferma diretta che due azioni `disk`
  consecutive (`match: {size: smallest}` poi `match: {}`) assegnano
  dischi diversi per esclusione reciproca, e che uno storage.config
  scritto per 2 dischi **fallisce intenzionalmente** (fail-fast) su una
  macchina con un solo disco reale — da cui la scelta di due frammenti
  statici separati (`storage-single-disk.yaml` / `storage-dual-disk.yaml`)
  invece di un unico file "adattivo": non è possibile scriverne uno che
  si adatti dinamicamente al conteggio dischi nello YAML dichiarativo.
- **Sizing partizioni**: oltre alle unità assolute (`100G`) già note da
  curtin, Subiquity aggiunge supporto a percentuali (`size: 50%`) e al
  valore speciale `size: -1` ("riempi lo spazio restante" sull'ultima
  partizione di un device) — usato per la partizione Datastore in
  entrambe le topologie, elimina la necessità di calcoli.

Questa verifica ha confermato/corretto il piano proposto prima di
scrivere qualunque YAML — nessun tentativo alla cieca su un meccanismo
potenzialmente distruttivo (partizionamento disco), a differenza di
alcuni bug della Fase 1 scoperti solo a runtime.

## 2026-08-18 — Implementazione

- `config/autoinstall-defaults.json`: nuova fonte unica di verità per i
  default di build (versione Ubuntu, size partizione sistema, topologia
  dischi, parametri Datastore — filesystem/label/mount-root/nome
  symlink), su richiesta esplicita dell'utente ("tutti i parametri e
  scelte per l'auto-install andranno memorizzati in un file json"). Letta
  da `build-iso.sh` via `python3` (con `shlex.quote` per l'export sicuro
  come variabili shell); i flag CLI restano per override puntuali.
- `iso/storage-single-disk.yaml`, `iso/storage-dual-disk.yaml`: le due
  topologie statiche, con placeholder `__SYSTEM_PARTITION_SIZE__`,
  `__DATASTORE_FILESYSTEM__`, `__DATASTORE_LABEL__` sostituiti a
  build-time. Nessuna azione `mount` per la partizione Datastore nello
  storage.config: il mountpoint dipende dalla UUID generata da
  `mkfs.xfs` in quello stesso step, non prevedibile staticamente —
  montato invece via `late-commands` (stesso procedimento manuale
  documentato da Vast.ai per `/var/lib/docker`: `mkfs` → `blkid` →
  `fstab`, qui automatizzato) con la convenzione UUID+symlink decisa.
- `iso/user-data`: bug trovato e corretto in fase di scrittura, non a
  runtime — il placeholder `__STORAGE_CONFIG__` su una riga propria
  senza indentazione rendeva il *template* non valido come YAML a sé
  stante (scalare non chiave/valore a livello di mapping). Corretto a
  `storage: __STORAGE_CONFIG__` (placeholder come valore scalare,
  YAML-valido); lo script di build ora sostituisce prima il testo del
  placeholder sulla riga (lasciando `storage:`), poi accoda il
  frammento scelto con l'idioma sed `r`/`d` — stesso risultato, template
  sempre valido nel repo.
- `scripts/build-iso.sh`: nuovi flag `--system-size` e `--disks 1|2`
  (quest'ultimo seleziona il frammento storage e aggiorna anche l'help
  testuale con i default correnti letti dal JSON).
- `scripts/validate-autoinstall.py`: riscritto per validare, oltre al
  template `iso/user-data` (ora richiede che `storage` sia ancora il
  placeholder, non hardcoded), anche i frammenti `storage-*-disk.yaml`
  scoperti automaticamente nella stessa directory — sostituzione con
  valori fittizi, parsing YAML, verifica che ogni riferimento
  `device`/`volume` punti a un id già definito da un'azione precedente
  (l'ordine conta, per lo schema Subiquity), verifica `swap.size: 0` e
  presenza di un `format` ext4 per la root. Validato con successo su
  entrambe le topologie prima di qualunque build reale.
- `scripts/boot-test-qemu.sh`: nuovo flag `--disks 1|2` (crea N dischi
  virtio throwaway invece di uno fisso); dopo il login SSH, verifica
  aggiuntiva via `findmnt` remoto che `/grastorp/volumes/datastore`
  risolva a un mountpoint XFS reale (non solo che l'host sia
  raggiungibile).
- `.github/workflows/ci.yml`: il job di integrazione ora usa una
  matrice `disks: [1, 2]`, eseguendo build+boot separatamente per
  entrambe le topologie — replica il piano di test dell'issue #2
  ("scenario disco singolo e scenario doppio disco").

Verificato prima di procedere: merge dei frammenti simulato manualmente
per entrambe le topologie (placeholder sostituiti, YAML risultante
parsato, sequenza id delle azioni ispezionata) — struttura corretta in
entrambi i casi. `shellcheck` pulito su tutti gli script modificati.

## Stato rispetto alla Definition of Done (issue #2)

- [x] Sezione `storage` con partizione sistema + partizione dedicata
      Datastore, size sistema parametrizzata (non hardcoded).
- [x] Gestione del caso multi-disco: topologia dedicata (`--disks 2`),
      fail-fast intenzionale se il conteggio dischi reale non corrisponde.
- [ ] Layout verificato via `lsblk`/`parted` dopo il boot — da
      confermare con un build+boot reale (vedi prossimi passi).
- [ ] Integrazione CI reale su dischi virtuali QEMU (scenario singolo e
      doppio) — pipeline pronta (matrice in `ci.yml`), esecuzione reale
      da verificare.
- [ ] Verifica su hardware fisico multi-disco reale — manuale, fuori
      scope di questa fase di sviluppo.

## Prossimi passi

- [ ] Eseguire un build+boot reale (locale o CI) per almeno lo scenario
      a 1 disco e verificare `lsblk`/`findmnt` sull'host installato.
- [ ] Idem per lo scenario a 2 dischi — in particolare confermare o
      smentire l'euristica "disco più piccolo = sistema" con un test
      reale (segnalata come assunzione non verificata da fonte).
- [ ] Aggiornare questo logbook con l'esito.
