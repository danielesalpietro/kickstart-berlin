#!/usr/bin/env python3
"""Valida sintassi e struttura minima del file autoinstall (iso/user-data).

Uso: validate-autoinstall.py <path-user-data>

Controlli:
- Il file è YAML valido.
- Sono presenti le chiavi di primo livello richieste (version, identity,
  ssh, storage).
- L'autenticazione SSH via password è disabilitata (ssh.allow-pw: false).
- La chiave SSH non è hardcoded: iso/user-data deve contenere solo il
  placeholder __SSH_AUTHORIZED_KEY__, sostituito da scripts/build-iso.sh a
  build-time.
"""
from __future__ import annotations

import sys

import yaml

REQUIRED_KEYS = ("version", "locale", "identity", "ssh", "storage")
SSH_KEY_PLACEHOLDER = "__SSH_AUTHORIZED_KEY__"


def fail(msg: str) -> None:
    print(f"ERRORE: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"uso: {sys.argv[0]} <path-user-data>")

    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        raw = f.read()

    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        fail(f"YAML non valido in {path}: {exc}")

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

    keys = ssh_cfg.get("authorized-keys") or []
    if keys != [SSH_KEY_PLACEHOLDER]:
        fail(
            "ssh.authorized-keys deve contenere solo il placeholder "
            f"{SSH_KEY_PLACEHOLDER!r} (nessuna chiave va hardcoded nel repo); "
            f"trovato: {keys!r}"
        )

    identity = ai["identity"]
    if not identity.get("username"):
        fail("identity.username mancante")
    if not identity.get("password"):
        fail("identity.password mancante (richiesto dallo schema Subiquity)")

    print(f"OK: {path} è un autoinstall YAML valido "
          f"(utente={identity['username']!r}, ssh-password-auth=disabilitato)")


if __name__ == "__main__":
    main()
