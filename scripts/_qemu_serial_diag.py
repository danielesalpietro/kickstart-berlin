#!/usr/bin/env python3
"""Diagnostica best-effort per boot-test-qemu.sh.

Uso interno: scripts/boot-test-qemu.sh lo invoca quando la console
seriale mostra "An error occurred. Press enter to start a shell"
(Subiquity caduto nella shell di recovery del live environment dopo un
install_fail). La sola trace ad alto livello che Subiquity scrive di
norma sulla console (righe "start:"/"finish:") non include il traceback
reale dell'errore: questo script si collega al socket UNIX della console
seriale QEMU (chardev "socket"), preme invio per attivare la shell e
raccoglie l'eventuale crash report e la coda del log di Subiquity.

Uso: _qemu_serial_diag.py <path-socket> <path-output>
"""
from __future__ import annotations

import socket
import sys
import time

MARKER = "___KB_DIAG___"


def recv_all(sock: socket.socket) -> bytes:
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


def main() -> None:
    if len(sys.argv) != 3:
        print(f"uso: {sys.argv[0]} <path-socket> <path-output>", file=sys.stderr)
        sys.exit(2)

    sock_path, out_path = sys.argv[1], sys.argv[2]

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock_path)

    # Invio prima un invio a vuoto per attivare il prompt della shell di
    # recovery, poi scarto quanto ricevuto (banner/prompt) prima di
    # inviare il comando diagnostico vero e proprio.
    s.sendall(b"\n")
    time.sleep(3)
    recv_all(s)

    cmd = (
        f"echo {MARKER}; "
        "cat /var/crash/*.crash 2>&1; "
        "echo ---SUBIQUITY-SERVER-DEBUG-LOG-TAIL---; "
        "tail -c 20000 /var/log/installer/subiquity-server-debug.log 2>&1; "
        f"echo {MARKER}\n"
    )
    s.sendall(cmd.encode())
    time.sleep(5)
    data = recv_all(s)
    s.close()

    with open(out_path, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main()
