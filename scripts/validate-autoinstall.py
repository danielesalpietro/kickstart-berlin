#!/usr/bin/env python3
"""Valida sintassi e struttura minima dei file autoinstall (iso/).

Uso: validate-autoinstall.py <path-user-data>

Controlli su <path-user-data> (template, con placeholder intatti):
- Il file è YAML valido dopo aver sostituito i placeholder con valori fittizi
  (il file grezzo non è YAML valido di per sé: __STORAGE_CONFIG__ diventa
  reale solo a build-time, vedi scripts/build-iso.sh).
- Sono presenti le chiavi di primo livello richieste (version, identity,
  ssh, storage).
- L'autenticazione SSH via password è disabilitata (ssh.allow-pw: false).
- La chiave SSH non è hardcoded: deve esserci solo il placeholder
  __SSH_AUTHORIZED_KEY__.
- storage è ancora il placeholder __STORAGE_CONFIG__ (non hardcodato qui).

Controlli sui frammenti storage-*-disk.yaml trovati nella stessa
directory (Fase 2, issue #2):
- YAML valido dopo sostituzione placeholder con valori fittizi.
- 'config' è una lista di azioni con 'type'/'id'.
- Ogni riferimento (device/volume) punta a un id definito da un'azione
  precedente nella lista (l'ordine conta, vedi Autoinstall reference).
- 'swap.size' è 0 (nessuna swap, coerente con un nodo GPU dedicato).
"""
from __future__ import annotations

import glob
import os
import re
import sys

import yaml

REQUIRED_KEYS = ("version", "locale", "identity", "ssh", "storage")
SSH_KEY_PLACEHOLDER = "__SSH_AUTHORIZED_KEY__"
STORAGE_CONFIG_PLACEHOLDER = "__STORAGE_CONFIG__"

DUMMY_SUBSTITUTIONS = {
    "__SSH_AUTHORIZED_KEY__": "ssh-ed25519 AAAAvalidatedummykeyAAAA validate@kickstart-berlin",
    "__SYSTEM_PARTITION_SIZE__": "100G",
    "__DATASTORE_FILESYSTEM__": "xfs",
    "__DATASTORE_LABEL__": "grastorp-datastore",
    "__DATASTORE_MOUNT_ROOT__": "/grastorp/volumes",
    "__DATASTORE_SYMLINK_NAME__": "datastore",
}

PLACEHOLDER_RE = re.compile(r"__[A-Z_]+__")


def fail(msg: str) -> None:
    print(f"ERRORE: {msg}", file=sys.stderr)
    sys.exit(1)


def substitute_dummies(text: str) -> str:
    for placeholder, value in DUMMY_SUBSTITUTIONS.items():
        text = text.replace(placeholder, value)
    return text


def validate_user_data(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        raw = f.read()

    try:
        doc = yaml.safe_load(substitute_dummies(raw))
    except yaml.YAMLError as exc:
        fail(f"YAML non valido in {path} (dopo sostituzione placeholder): {exc}")

    if not isinstance(doc, dict) or "autoinstall" not in doc:
        fail("chiave di primo livello 'autoinstall' mancante")

    ai = doc["autoinstall"]

    missing = [k for k in REQUIRED_KEYS if k not in ai]
    if missing:
        fail(f"chiavi obbligatorie mancanti in autoinstall: {', '.join(missing)}")

    if ai["version"] != 1:
        fail(f"autoinstall.version non supportata: {ai['version']!r} (attesa: 1)")

    ssh_cfg = ai["ssh"]
    if ssh_cfg.get("allow-pw") is not False:
        fail("ssh.allow-pw deve essere 'false': solo login via chiave consentito")
    if not ssh_cfg.get("install-server"):
        fail("ssh.install-server deve essere true (server SSH abilitato)")

    identity = ai["identity"]
    if not identity.get("username"):
        fail("identity.username mancante")
    if not identity.get("password"):
        fail("identity.password mancante (richiesto dallo schema Subiquity)")

    # Questi controlli vanno sul file grezzo (prima della sostituzione
    # fittizia): la chiave SSH e lo storage.config devono restare
    # placeholder nel repo, mai valori reali/hardcoded.
    raw_doc = yaml.safe_load(raw.replace(STORAGE_CONFIG_PLACEHOLDER, f'"{STORAGE_CONFIG_PLACEHOLDER}"'))
    raw_ai = raw_doc["autoinstall"]
    raw_keys = raw_ai["ssh"].get("authorized-keys") or []
    if raw_keys != [SSH_KEY_PLACEHOLDER]:
        fail(
            "ssh.authorized-keys deve contenere solo il placeholder "
            f"{SSH_KEY_PLACEHOLDER!r} (nessuna chiave va hardcoded nel repo); "
            f"trovato: {raw_keys!r}"
        )
    if raw_ai.get("storage") != STORAGE_CONFIG_PLACEHOLDER:
        fail(
            f"autoinstall.storage deve essere il placeholder {STORAGE_CONFIG_PLACEHOLDER!r} "
            "(il partizionamento reale va in iso/storage-*-disk.yaml, mai hardcoded qui)"
        )

    print(f"OK: {path} è un autoinstall template valido "
          f"(utente={identity['username']!r}, ssh-password-auth=disabilitato)")
    return ai


def validate_storage_fragment(path: str) -> None:
    with open(path, encoding="utf-8") as f:
        raw = f.read()

    substituted = substitute_dummies(raw)
    leftover = PLACEHOLDER_RE.findall(substituted)
    if leftover:
        fail(f"{path}: placeholder non riconosciuti rimasti dopo la sostituzione: {sorted(set(leftover))}")

    try:
        storage = yaml.safe_load(f"storage:\n{substituted}")["storage"]
    except yaml.YAMLError as exc:
        fail(f"YAML non valido in {path} (dopo sostituzione placeholder): {exc}")

    if storage.get("swap", {}).get("size") != 0:
        fail(f"{path}: storage.swap.size deve essere 0 (nessuna swap)")

    actions = storage.get("config")
    if not isinstance(actions, list) or not actions:
        fail(f"{path}: storage.config deve essere una lista non vuota di azioni")

    defined_ids: set[str] = set()
    for i, action in enumerate(actions):
        if "type" not in action or "id" not in action:
            fail(f"{path}: azione #{i} priva di 'type' o 'id': {action!r}")
        for ref_key in ("device", "volume"):
            ref = action.get(ref_key)
            if ref is not None and ref not in defined_ids:
                fail(
                    f"{path}: azione '{action['id']}' referenzia "
                    f"{ref_key}={ref!r}, non ancora definito a quel punto "
                    "(l'ordine delle azioni conta)"
                )
        defined_ids.add(action["id"])

    fstypes = {a["fstype"] for a in actions if a.get("type") == "format"}
    if "ext4" not in fstypes:
        fail(f"{path}: nessuna azione 'format' con fstype ext4 per la root")

    print(f"OK: {path} è uno storage.config valido ({len(actions)} azioni, "
          f"fstype: {sorted(fstypes)})")


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"uso: {sys.argv[0]} <path-user-data>")

    user_data_path = sys.argv[1]
    validate_user_data(user_data_path)

    iso_dir = os.path.dirname(os.path.abspath(user_data_path))
    fragments = sorted(glob.glob(os.path.join(iso_dir, "storage-*-disk.yaml")))
    if not fragments:
        fail(f"nessun frammento storage-*-disk.yaml trovato in {iso_dir}")
    for fragment in fragments:
        validate_storage_fragment(fragment)


if __name__ == "__main__":
    main()
