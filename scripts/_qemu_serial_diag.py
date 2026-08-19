#!/usr/bin/env python3
"""Diagnostica best-effort per boot-test-qemu.sh.

Uso interno: scripts/boot-test-qemu.sh lo invoca quando la console
seriale mostra "An error occurred. Press enter to start a shell"
(Subiquity caduto nella shell di recovery del live environment dopo un
install_fail). La sola trace ad alto livello che Subiquity scrive di
norma sulla console (righe "start:"/"finish:") non include il traceback
reale dell'errore: questo script si collega al socket UNIX della console
seriale QEMU (chardev "socket"), attiva la shell e raccoglie l'eventuale
crash report e la coda del log di Subiquity.

Comandi inviati uno alla volta (non concatenati con ";"): un primo
tentativo con un unico comando lungo concatenato ha prodotto solo l'eco
del testo digitato senza alcun output reale, con l'ipotesi che il testo
sia arrivato mentre la shell di recovery era ancora a metà della propria
inizializzazione (bracketed-paste-mode, prompt) — comandi separati con
attese più larghe tra un invio e l'altro riducono il rischio di quella
corsa critica.

Uso: _qemu_serial_diag.py <path-socket> <path-output>
"""
from __future__ import annotations

import socket
import sys
import time


def drain(sock: socket.socket, idle_timeout: float = 3.0) -> bytes:
    """Legge tutto quello che arriva finché non c'è silenzio per idle_timeout secondi."""
    sock.settimeout(idle_timeout)
    data = b""
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    except TimeoutError:
        pass
    return data


def run_command(sock: socket.socket, cmd: str, settle: float = 8.0) -> bytes:
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    return drain(sock)


def main() -> None:
    if len(sys.argv) != 3:
        print(f"uso: {sys.argv[0]} <path-socket> <path-output>", file=sys.stderr)
        sys.exit(2)

    sock_path, out_path = sys.argv[1], sys.argv[2]

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock_path)

    # Due invii a vuoto separati (non uno solo) per dare tempo alla shell
    # di recovery di completare la propria inizializzazione (prompt,
    # bracketed paste mode) prima di considerarla pronta a ricevere
    # comandi reali.
    run_command(s, "", settle=5)
    run_command(s, "", settle=3)

    sections = [
        run_command(s, "cat /var/crash/*.crash 2>&1"),
        b"\n---SUBIQUITY-SERVER-DEBUG-LOG-TAIL---\n",
        run_command(s, "tail -c 20000 /var/log/installer/subiquity-server-debug.log 2>&1"),
    ]
    s.close()

    with open(out_path, "wb") as f:
        for section in sections:
            f.write(section)


if __name__ == "__main__":
    main()
