#!/usr/bin/env python3
#
# console-status.py — schermata informativa persistente su tty1 (issue
# #27), stile DCUI VMware ESXi (barra header/footer gialla, corpo nero)
# invece del testo semplice della prima versione (console-status.sh,
# ora sostituito da questo file) — su richiesta dell'utente, a partire
# da un mockup curses fornito come riferimento.
#
# Sola lettura per costruzione, non solo per convenzione: questo script
# non chiama MAI una funzione di lettura input (niente `stdscr.getch()`
# in nessun punto) — il refresh usa `time.sleep()`, non un timeout su
# `getch()`. Combinato con `StandardInput=null` nella unit systemd
# (verificato empiricamente compatibile con curses: l'unico requisito
# reale è `TERM` valorizzata, impostata esplicitamente sotto — non
# serve un vero stdin), la difesa in profondità originale dell'issue
# #27 resta doppia: né lo script né il servizio possono processare
# input anche se qualcuno lo inviasse.
#
# La raccolta delle informazioni resta in lib-node-status.sh (bash),
# condivisa col banner SSH (motd-vastai-status) — questo file chiama
# quelle funzioni via subprocess invece di duplicarle in Python, unica
# fonte di verità per la logica di raccolta dati.
import curses
import os
import subprocess
import time
from datetime import datetime

REFRESH_INTERVAL_SECONDS = 30
LIB_PATH = "/opt/kickstart-berlin/lib-node-status.sh"


def _bash_func(name):
    """Esegue una funzione di lib-node-status.sh e ne cattura lo stdout.
    Non solleva mai: un errore qui deve produrre una riga di stato
    vuota/mancante, non far cadere l'intero script (stesso principio
    di "niente set -e" nella libreria bash originale)."""
    try:
        result = subprocess.run(
            ["bash", "-c", f'set -uo pipefail; source "{LIB_PATH}"; {name}'],
            capture_output=True, text=True, timeout=10,
        )
        return result.stdout.rstrip("\n")
    except Exception:
        return ""


def _vastai_installed():
    try:
        result = subprocess.run(
            ["bash", "-c", f'set -uo pipefail; source "{LIB_PATH}"; _vastai_installed'],
            capture_output=True, timeout=5,
        )
        return result.returncode == 0
    except Exception:
        return False


def _build_lines():
    """Costruisce il corpo della schermata come lista di stringhe già
    formattate, stesso contenuto della versione bash precedente più la
    sezione Vast.ai (issue #27, estensione richiesta dall'utente). Una
    riga vuota TRA ogni sezione (non solo dentro), a differenza della
    prima versione: leggibilità, su richiesta esplicita dell'utente
    dopo aver visto il primo collaudo reale ("estensioni corrette, ma
    esteticamente migliorabile — spaziatura tra le sezioni")."""
    lines = []
    lines.append(_bash_func("_os_line"))
    lines.append("")
    lines.append("Indirizzi IP:")
    lines.extend(_bash_func("_ip_lines").splitlines())
    lines.append("")
    lines.append("Gateway:")
    lines.extend(_bash_func("_gateway_line").splitlines())
    lines.append("")
    lines.append("DNS:")
    lines.extend(_bash_func("_dns_line").splitlines())
    lines.append("")
    lines.append("CPU:")
    lines.extend(_bash_func("_cpu_line").splitlines())
    lines.append("")
    lines.append("Disco di sistema (/):")
    lines.extend(_bash_func("_system_disk_line").splitlines())
    lines.append("")
    lines.append("Datastore / Docker:")
    lines.extend(_bash_func("_datastore_line").splitlines())
    lines.append("")
    lines.append("GPU:")
    lines.extend(_bash_func("_gpu_line").splitlines())

    if _vastai_installed():
        lines.append("")
        lines.append("Servizi Vast.ai:")
        lines.extend(_bash_func("_vastai_services_line").splitlines())
        lines.append("")
        lines.append("Macchina Vast.ai:")
        lines.extend(_bash_func("_vastai_machine_line").splitlines())

    ip_first = _bash_func("_first_ip").strip()
    if ip_first:
        lines.append("")
        lines.append("Accesso SSH:")
        lines.append(f"    ssh admin@{ip_first}")

    return lines


def _safe_addstr(win, y, x, text, attr=0):
    """addstr che non fa crashare lo script se il testo eccede i
    margini della finestra (console piccola/ridimensionata) — stesso
    pattern try/except già usato nel mockup di riferimento per il
    footer sull'angolo in basso a destra."""
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass


# 132, non 96: la riga più lunga in pratica ("Macchina Vast.ai", con
# affidabilità/verifica/listing/manutenzione tutti sulla stessa riga)
# arriva intorno ai 120 caratteri - un limite più stretto la tronca a
# metà parola, scoperto sul primo collaudo reale (vedi
# logbook-issue27-console-status.md).
BOX_MAX_WIDTH = 132


def _draw_box(stdscr, h, w, content_lines):
    """Riquadro bordato centrato per il corpo, come nel mockup di
    riferimento dell'utente (curses.newwin + .box()) invece di testo
    libero su sfondo nero pieno — dimensionato sul contenuto reale
    (righe/larghezza), non fisso, entro i limiti dello schermo."""
    max_content_w = max((len(line) for line in content_lines), default=0)
    box_w = max(20, min(w - 4, max_content_w + 6, BOX_MAX_WIDTH))
    box_h = max(5, min(h - 5, len(content_lines) + 4))
    box_y = 2
    box_x = max(0, (w - box_w) // 2)

    win = curses.newwin(box_h, box_w, box_y, box_x)
    win.bkgd(" ", curses.color_pair(2))
    win.box()
    _safe_addstr(win, 0, 2, " Stato del nodo ", curses.color_pair(2) | curses.A_BOLD)

    inner_h = box_h - 2  # righe utilizzabili tra i due bordi orizzontali
    inner_w = box_w - 4  # spazio fra i due bordi verticali, con margine
    truncated = len(content_lines) > inner_h - 1
    visible = content_lines[: inner_h - 1] if truncated else content_lines

    row = 1
    for line in visible:
        # Ellissi ASCII ("...", non "…" Unicode: la console fisica reale
        # non renderizza caratteri fuori font, stessa lezione già
        # imparata con l'em-dash altrove in questo repo) se la singola
        # riga eccede la larghezza disponibile, invece di un
        # troncamento silenzioso a metà parola (successo con la riga
        # "Macchina Vast.ai" nel primo collaudo reale).
        if len(line) > inner_w:
            line = line[: max(0, inner_w - 3)] + "..."
        _safe_addstr(win, row, 2, line, curses.color_pair(2))
        row += 1
    if truncated:
        _safe_addstr(win, box_h - 2, 2, "...".ljust(inner_w), curses.color_pair(2))

    win.refresh()


def draw(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_YELLOW)  # header/footer
    curses.init_pair(2, curses.COLOR_WHITE, curses.COLOR_BLACK)   # corpo

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        hostname = os.uname().nodename

        stdscr.bkgd(" ", curses.color_pair(2))

        header = f" kickstart-berlin - {hostname} "
        _safe_addstr(stdscr, 0, 0, header.ljust(w), curses.color_pair(1) | curses.A_BOLD)

        footer_left = " Nessun login locale - solo chiave SSH | shell classica: Alt+F2...Alt+F6 "
        footer_right = f"Aggiornato: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} "
        footer = footer_left.ljust(max(0, w - len(footer_right))) + footer_right
        _safe_addstr(stdscr, h - 1, 0, footer[:w].ljust(w), curses.color_pair(1) | curses.A_BOLD)

        stdscr.refresh()
        _draw_box(stdscr, h, w, _build_lines())

        # Niente stdscr.getch(): il refresh e' un semplice sleep, mai
        # una lettura di input (vedi commento in cima al file).
        time.sleep(REFRESH_INTERVAL_SECONDS)


def main():
    # TERM esplicita: unico requisito reale di curses in questo
    # contesto (scoperto sul primo collaudo reale, vedi
    # logbook-issue27-console-status.md) - il servizio systemd non ne
    # imposta una propria, e senza "TERM" curses.wrapper() fallisce con
    # "setupterm: could not find terminal" ancora prima di arrivare al
    # tema di stdin=/dev/null. La console fisica del nodo e' sempre una
    # console Linux VT, "linux" e' il terminfo corretto.
    os.environ.setdefault("TERM", "linux")
    curses.wrapper(draw)


if __name__ == "__main__":
    main()
