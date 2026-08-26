#!/usr/bin/env python3
#
# node-manage.py — menu di gestione/configurazione interattivo del nodo,
# stile DCUI VMware ESXi (<F2> Customize System), issue #33.
#
# A differenza di console-status.py (issue #27, sola lettura per
# costruzione, gira come servizio systemd su tty1), questo tool:
#   - va lanciato A MANO dall'operatore via SSH interattivo (mai come
#     servizio, mai in setup.sh/main()) — richiede una TTY reale
#     (sys.stdin/stdout.isatty()), sia per l'interazione col menu sia
#     perché alcune azioni (netplan try, i pager dei log) sono a loro
#     volta programmi interattivi;
#   - PUÒ modificare lo stato del sistema (rete, servizi POD), non solo
#     mostrarlo. Precisazione esplicita dell'utente su issue #33: questo
#     non introduce un nuovo vettore di accesso (l'operatore ha già pieno
#     accesso via SSH+sudo), il rischio da gestire è "azioni distruttive
#     rese troppo facili da un menu" — ogni azione che cambia stato reale
#     mostra prima la situazione attuale e chiede conferma esplicita
#     (mai un default "sì").
#
# Requisiti: root (sudo) — sia per le azioni di rete/systemd, sia perché
# la CLI vastai (Fase 10) viene comunque invocata con HOME=/home/admin
# esplicito (stessa convenzione di lib-node-status.sh: l'API key di
# vastai vive sotto /home/admin/, non root, indipendentemente da quale
# utente lancia questo script).
#
# Navigazione: menu ad albero curses (Su/Giù/Invio/Esc/Q), stessa idea
# del mockup esx_tree.py fornito dall'utente. Ogni AZIONE (a differenza
# della sola navigazione) sospende curses e gira come terminale normale
# (print/input) invece che dentro una finestra curses: più semplice e
# robusto per mostrare output di comandi reali (vastai, journalctl,
# ping, netplan try) di lunghezza/formato non prevedibile, e necessario
# comunque per 'netplan try' e i pager (journalctl/less), che vogliono
# un vero terminale interattivo.
#
# Rete/IP statico: usa 'netplan try --timeout 30' (meccanismo nativo di
# Netplan pensato esattamente per questo) invece di un rollback scritto
# a mano — applica la configurazione, chiede conferma entro il timeout,
# altrimenti ripristina automaticamente quella precedente. Scrive un
# file di override dedicato (90-kickstart-berlin-override.yaml) invece
# di modificare il file generato da Subiquity all'install: netplan
# unisce i file per nome in ordine numerico, un file di override è
# banalmente reversibile (basta cancellarlo + 'netplan apply' per
# tornare ai default dell'installer) senza dover fare parsing/riscrittura
# di uno YAML esistente.
import curses
import glob
import ipaddress
import json
import os
import subprocess
import sys
import time

LIB_PATH = "/opt/kickstart-berlin/lib-node-status.sh"
SELFTEST_SCRIPT = "/opt/kickstart-berlin/vastai-self-test.sh"
VASTAI_KAALIA_DIR = "/var/lib/vastai_kaalia"
NETPLAN_OVERRIDE_FILE = "/etc/netplan/90-kickstart-berlin-override.yaml"
POD_SERVICES = ("vastai.service", "vast_metrics.service")
POSTINSTALL_SERVICE = "kickstart-berlin-postinstall.service"


def _bash_func(name):
    """Esegue una funzione di lib-node-status.sh, stessa fonte di verità
    condivisa con console-status.py e motd-vastai-status."""
    try:
        result = subprocess.run(
            ["bash", "-c", f'set -uo pipefail; source "{LIB_PATH}"; {name}'],
            capture_output=True, text=True, timeout=10,
        )
        return result.stdout.rstrip("\n")
    except Exception:
        return ""


def _vastai(*args):
    """Invoca 'vastai' con HOME=/home/admin esplicito (l'API key vive lì,
    non sotto root — vedi lib-node-status.sh, stesso bug già risolto in
    issue #27). Output diretto sul terminale (nessuna cattura): questo
    script gira sempre in modalità sospesa/interattiva quando la chiama."""
    subprocess.run(["env", "HOME=/home/admin", "vastai", *args])


def _get_machine_id():
    """ID numerico della macchina su Vast.ai (es. 148447), NON l'hash
    interno in /var/lib/vastai_kaalia/machine_id — stessa tecnica e
    stesso motivo di _vastai_machine_line() in lib-node-status.sh."""
    try:
        result = subprocess.run(
            ["env", "HOME=/home/admin", "timeout", "5", "vastai", "show", "machines", "--raw"],
            capture_output=True, text=True,
        )
        data = json.loads(result.stdout)
    except Exception:
        return None
    machines = data.get("machines", []) if isinstance(data, dict) else data
    if not machines:
        return None
    hostname = os.uname().nodename
    d = next((m for m in machines if m.get("hostname") == hostname), machines[0])
    return d.get("id")


def _confirm(prompt):
    """Conferma esplicita, default 'no' — mai un'azione che cambia stato
    reale senza un sì esplicito dell'operatore (vedi header del file)."""
    try:
        answer = input(f"{prompt} [y/N] ").strip().lower()
    except EOFError:
        return False
    return answer == "y"


def _choose_iface():
    result = subprocess.run(["ip", "-brief", "link", "show", "up"], capture_output=True, text=True)
    ifaces = [line.split()[0] for line in result.stdout.splitlines() if line.split() and line.split()[0] != "lo"]
    if not ifaces:
        print("Nessuna interfaccia di rete trovata (a parte lo).")
        return None
    if len(ifaces) == 1:
        return ifaces[0]
    print("Interfacce disponibili:")
    for i, name in enumerate(ifaces, 1):
        print(f"  {i}) {name}")
    choice = input("Scegli l'interfaccia [numero]: ").strip()
    try:
        idx = int(choice) - 1
        if 0 <= idx < len(ifaces):
            return ifaces[idx]
    except ValueError:
        pass
    print("Scelta non valida.")
    return None


def _write_netplan_override(content):
    backup = None
    if os.path.exists(NETPLAN_OVERRIDE_FILE):
        backup = f"{NETPLAN_OVERRIDE_FILE}.bak-{int(time.time())}"
        subprocess.run(["cp", "-a", NETPLAN_OVERRIDE_FILE, backup], check=True)
    with open(NETPLAN_OVERRIDE_FILE, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(NETPLAN_OVERRIDE_FILE, 0o600)
    return backup


def _netplan_try():
    print("\nApplico la configurazione con 'netplan try' (30s per confermare).")
    print("Premi INVIO per CONFERMARE, oppure non fare nulla: allo scadere del")
    print("timeout la configurazione precedente viene ripristinata automaticamente.\n")
    result = subprocess.run(["netplan", "try", "--timeout", "30"])
    if result.returncode == 0:
        print("\nConfigurazione di rete confermata e applicata.")
    else:
        print("\n'netplan try' terminato senza conferma: la configurazione precedente resta attiva.")


# --- Azioni: Management Network -------------------------------------------

def action_network_status():
    print("=== Management Network: Status ===\n")
    print(_bash_func("_os_line"))
    print("\nIndirizzi IP:")
    print(_bash_func("_ip_lines"))
    print("\nGateway:")
    print(_bash_func("_gateway_line"))
    print("\nDNS:")
    print(_bash_func("_dns_line"))
    if os.path.exists(NETPLAN_OVERRIDE_FILE):
        print(f"\nOverride attivo ({NETPLAN_OVERRIDE_FILE}):")
        with open(NETPLAN_OVERRIDE_FILE, encoding="utf-8") as f:
            print(f.read())
    else:
        print("\nNessun override di rete presente: configurazione DHCP di default (installer).")


def action_ip_set_dhcp():
    print("=== IP Configuration: Set DHCP ===\n")
    iface = _choose_iface()
    if not iface:
        return
    print(f"\nInterfaccia selezionata: {iface}. Stato attuale:")
    subprocess.run(["ip", "-brief", "addr", "show", iface])
    if not _confirm(f"\nImpostare {iface} su DHCP?"):
        print("Annullato.")
        return
    content = f"network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    {iface}:\n      dhcp4: true\n"
    backup = _write_netplan_override(content)
    if backup:
        print(f"Backup della configurazione precedente: {backup}")
    _netplan_try()


def action_ip_set_static():
    print("=== IP Configuration: Set Static IP ===\n")
    iface = _choose_iface()
    if not iface:
        return
    print(f"\nInterfaccia selezionata: {iface}. Stato attuale:")
    subprocess.run(["ip", "-brief", "addr", "show", iface])

    addr_raw = input("\nIndirizzo IPv4 con prefisso CIDR (es. 192.168.1.50/24): ").strip()
    gw_raw = input("Gateway (es. 192.168.1.1): ").strip()
    dns_raw = input("Server DNS separati da virgola (es. 1.1.1.1,8.8.8.8): ").strip()

    try:
        iface_net = ipaddress.ip_interface(addr_raw)
        gw_ip = ipaddress.ip_address(gw_raw)
        dns_list = [str(ipaddress.ip_address(d.strip())) for d in dns_raw.split(",") if d.strip()]
    except ValueError as e:
        print(f"\nInput non valido: {e}")
        return
    if not dns_list:
        print("\nAlmeno un server DNS è obbligatorio.")
        return

    print(f"\nRiepilogo: {iface} -> {iface_net}, gateway {gw_ip}, DNS {', '.join(dns_list)}")
    print("ATTENZIONE: un valore errato può interrompere l'accesso SSH a questo nodo.")
    print("'netplan try' ripristina automaticamente la configurazione precedente se non confermata entro 30s.")
    if not _confirm("\nApplicare questa configurazione?"):
        print("Annullato.")
        return

    dns_yaml = ", ".join(dns_list)
    content = (
        "network:\n  version: 2\n  renderer: networkd\n  ethernets:\n"
        f"    {iface}:\n      dhcp4: false\n      addresses:\n        - {iface_net}\n"
        f"      routes:\n        - to: default\n          via: {gw_ip}\n"
        f"      nameservers:\n        addresses: [{dns_yaml}]\n"
    )
    backup = _write_netplan_override(content)
    if backup:
        print(f"Backup della configurazione precedente: {backup}")
    _netplan_try()


def action_network_restart():
    print("=== Restart Network Services ===\n")
    print("Stato attuale:")
    subprocess.run(["ip", "-brief", "addr"])
    print("\nGateway:")
    print(_bash_func("_gateway_line"))
    if not _confirm("\nRiavviare i servizi di rete (netplan apply)?"):
        print("Annullato.")
        return
    subprocess.run(["netplan", "apply"])
    time.sleep(2)
    print("\nStato dopo il riavvio:")
    subprocess.run(["ip", "-brief", "addr"])
    print("\nGateway:")
    print(_bash_func("_gateway_line"))


def action_network_test():
    print("=== Connectivity Test ===\n")
    result = subprocess.run(["ip", "-4", "route", "show", "default"], capture_output=True, text=True)
    parts = result.stdout.split()
    gw = parts[parts.index("via") + 1] if "via" in parts else None
    if gw:
        print(f"Ping verso il gateway ({gw}):")
        subprocess.run(["ping", "-c", "3", gw])
    else:
        print("Gateway non disponibile, salto il test verso il gateway.")
    print("\nPing verso 1.1.1.1 (raggiungibilità internet):")
    subprocess.run(["ping", "-c", "3", "1.1.1.1"])
    print("\nRisoluzione DNS di github.com:")
    subprocess.run(["getent", "hosts", "github.com"])


# --- Azioni: POD -------------------------------------------------------

def action_pod_status():
    print("=== POD: Status ===\n")
    print("Servizi:")
    print(_bash_func("_vastai_services_line"))
    print("\nMacchina:")
    print(_bash_func("_vastai_machine_line"))


def action_pod_restart():
    print("=== POD: Restart Daemon ===\n")
    print("Stato attuale:")
    print(_bash_func("_vastai_services_line"))
    if not _confirm("\nRiavviare i servizi POD (vastai.service, vast_metrics.service)?"):
        print("Annullato.")
        return
    for svc in POD_SERVICES:
        load_state = subprocess.run(
            ["systemctl", "show", svc, "-p", "LoadState", "--value"], capture_output=True, text=True
        ).stdout.strip()
        if load_state == "loaded":
            subprocess.run(["systemctl", "restart", svc])
    time.sleep(2)
    print("\nStato dopo il riavvio:")
    print(_bash_func("_vastai_services_line"))


def action_pod_diag_show():
    print("=== POD Diagnostics: Show Machine Info ===\n")
    machine_id = _get_machine_id()
    if machine_id is None:
        print("Impossibile determinare il machine_id (CLI vastai non installata/autenticata, o rete assente).")
        return
    _vastai("show", "machine", str(machine_id))


def action_pod_diag_list():
    print("=== POD Diagnostics: Enable Listing ===\n")
    machine_id = _get_machine_id()
    if machine_id is None:
        print("Impossibile determinare il machine_id.")
        return
    print("Stato attuale:")
    _vastai("show", "machine", str(machine_id))

    price_gpu = input("\nPrezzo per GPU in $/h (obbligatorio, es. 0.30): ").strip()
    try:
        float(price_gpu)
    except ValueError:
        print("Prezzo non valido.")
        return
    price_disk = input("Prezzo storage in $/GB/mese (opzionale, INVIO per il default): ").strip()
    args = ["list", "machine", str(machine_id), "--price_gpu", price_gpu]
    if price_disk:
        try:
            float(price_disk)
        except ValueError:
            print("Prezzo storage non valido.")
            return
        args += ["--price_disk", price_disk]

    if not _confirm(f"\nConfermi il listing di machine {machine_id} a ${price_gpu}/GPU/h?"):
        print("Annullato.")
        return
    _vastai(*args)


def action_pod_diag_unlist():
    print("=== POD Diagnostics: Disable Listing ===\n")
    machine_id = _get_machine_id()
    if machine_id is None:
        print("Impossibile determinare il machine_id.")
        return
    print("Stato attuale:")
    _vastai("show", "machine", str(machine_id))
    if not _confirm(f"\nConfermi la rimozione dal listing di machine {machine_id}?"):
        print("Annullato.")
        return
    _vastai("unlist", "machine", str(machine_id))


def action_pod_diag_selftest():
    print("=== POD Diagnostics: Self-Test ===\n")
    machine_id = _get_machine_id()
    if machine_id is None:
        print("Impossibile determinare il machine_id.")
        return
    if not os.path.exists(SELFTEST_SCRIPT):
        print(f"{SELFTEST_SCRIPT} non trovato (Fase 11 non presente su questo nodo?).")
        return
    print(f"Machine ID: {machine_id}")
    if not _confirm("\nEseguire il self-test ufficiale Vast.ai ora? Richiede macchina listata e senza affitti attivi."):
        print("Annullato.")
        return
    subprocess.run([SELFTEST_SCRIPT, "--machine-id", str(machine_id)])


# --- Azioni: View System Log --------------------------------------------

def action_log_postinstall():
    subprocess.run(["journalctl", "-u", POSTINSTALL_SERVICE])


def action_log_kaalia():
    files = sorted(glob.glob(os.path.join(VASTAI_KAALIA_DIR, "*.log")))
    if not files:
        print(f"Nessun file di log trovato in {VASTAI_KAALIA_DIR}/ (POD non installato su questo nodo?).")
        return
    if len(files) == 1:
        subprocess.run(["less", files[0]])
        return
    print("File di log disponibili:")
    for i, f in enumerate(files, 1):
        print(f"  {i}) {f}")
    choice = input("Scegli un file [numero]: ").strip()
    try:
        idx = int(choice) - 1
        if 0 <= idx < len(files):
            subprocess.run(["less", files[idx]])
            return
    except ValueError:
        pass
    print("Scelta non valida.")


def action_log_system():
    subprocess.run(["journalctl", "-xe"])


# --- Menu ad albero (curses) ---------------------------------------------

MENU = {
    "root": {"title": "kickstart-berlin", "items": [
        ("Management Network", "menu", "network"),
        ("POD", "menu", "pod"),
        ("View System Log", "menu", "logs"),
    ]},
    "network": {"title": "Management Network", "items": [
        ("Status", "action", "network_status"),
        ("IP Configuration", "menu", "ip_config"),
        ("Restart Network Services", "action", "network_restart"),
        ("Connectivity Test", "action", "network_test"),
    ]},
    "ip_config": {"title": "IP Configuration", "items": [
        ("Set DHCP", "action", "ip_set_dhcp"),
        ("Set Static IP", "action", "ip_set_static"),
    ]},
    "pod": {"title": "POD", "items": [
        ("Status", "action", "pod_status"),
        ("Restart Daemon", "action", "pod_restart"),
        ("Diagnostics", "menu", "pod_diag"),
    ]},
    "pod_diag": {"title": "POD - Diagnostics", "items": [
        ("Show Machine Info", "action", "pod_diag_show"),
        ("Enable Listing (set price)", "action", "pod_diag_list"),
        ("Disable Listing", "action", "pod_diag_unlist"),
        ("Run Self-Test", "action", "pod_diag_selftest"),
    ]},
    "logs": {"title": "View System Log", "items": [
        ("Postinstall Log", "action", "log_postinstall"),
        ("POD Daemon Log", "action", "log_kaalia"),
        ("System Log", "action", "log_system"),
    ]},
}

ACTIONS = {
    "network_status": action_network_status,
    "ip_set_dhcp": action_ip_set_dhcp,
    "ip_set_static": action_ip_set_static,
    "network_restart": action_network_restart,
    "network_test": action_network_test,
    "pod_status": action_pod_status,
    "pod_restart": action_pod_restart,
    "pod_diag_show": action_pod_diag_show,
    "pod_diag_list": action_pod_diag_list,
    "pod_diag_unlist": action_pod_diag_unlist,
    "pod_diag_selftest": action_pod_diag_selftest,
    "log_postinstall": action_log_postinstall,
    "log_kaalia": action_log_kaalia,
    "log_system": action_log_system,
}

# I visualizzatori di log (pager journalctl/less) restituiscono già il
# controllo quando l'operatore preme 'q' - un ulteriore "premi INVIO" dopo
# sarebbe ridondante, a differenza di ogni altra azione (dove il "premi
# INVIO" dà il tempo di leggere l'output prima di tornare al menu curses).
LOG_ACTIONS = {"log_postinstall", "log_kaalia", "log_system"}


def _safe_addstr(win, y, x, text, attr=0):
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass


def run_action(stdscr, action_name):
    fn = ACTIONS[action_name]
    curses.def_prog_mode()
    curses.endwin()
    subprocess.run(["clear"])
    try:
        fn()
    except Exception as e:
        print(f"\n[node-manage] ERRORE inatteso: {e}")
    if action_name not in LOG_ACTIONS:
        try:
            input("\nPremi INVIO per tornare al menu...")
        except EOFError:
            pass
    curses.reset_prog_mode()
    stdscr.clear()
    stdscr.refresh()


def draw_menu(stdscr, stack):
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    hostname = os.uname().nodename

    stdscr.bkgd(" ", curses.color_pair(2))
    header = f" kickstart-berlin - Node Management - {hostname} "
    _safe_addstr(stdscr, 0, 0, header.ljust(w), curses.color_pair(1) | curses.A_BOLD)

    breadcrumb = " > ".join(MENU[m[0]]["title"] for m in stack)
    _safe_addstr(stdscr, 2, 2, breadcrumb, curses.color_pair(2) | curses.A_BOLD)

    menu_id, sel = stack[-1]
    items = MENU[menu_id]["items"]
    start_row = 4
    for i, (label, kind, _target) in enumerate(items):
        attr = curses.color_pair(2)
        prefix = "  "
        if i == sel:
            attr |= curses.A_REVERSE
            prefix = "> "
        suffix = " >" if kind == "menu" else ""
        _safe_addstr(stdscr, start_row + i, 2, f"{prefix}{label}{suffix}".ljust(max(0, w - 4)), attr)

    footer = " Up/Down: Move  Enter: Select  Esc/Left: Back  Q: Quit "
    _safe_addstr(stdscr, h - 1, 0, footer.ljust(w), curses.color_pair(1) | curses.A_BOLD)
    stdscr.refresh()


def main_loop(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_YELLOW)  # header/footer
    curses.init_pair(2, curses.COLOR_WHITE, curses.COLOR_BLACK)   # corpo
    stdscr.keypad(True)

    stack = [["root", 0]]  # pila di [menu_id, indice selezionato]

    while True:
        draw_menu(stdscr, stack)
        key = stdscr.getch()
        menu_id, sel = stack[-1]
        items = MENU[menu_id]["items"]

        if key == curses.KEY_UP:
            stack[-1][1] = (sel - 1) % len(items)
        elif key == curses.KEY_DOWN:
            stack[-1][1] = (sel + 1) % len(items)
        elif key in (curses.KEY_ENTER, 10, 13):
            _label, kind, target = items[sel]
            if kind == "menu":
                stack.append([target, 0])
            elif kind == "action":
                run_action(stdscr, target)
        elif key in (curses.KEY_LEFT, 27):
            if len(stack) > 1:
                stack.pop()
        elif key in (ord("q"), ord("Q")):
            break


def main():
    if os.geteuid() != 0:
        print("Questo tool richiede i permessi di root (sudo).", file=sys.stderr)
        sys.exit(1)
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print(
            "Questo tool va lanciato da un terminale interattivo vero (SSH interattivo): "
            "azioni come 'netplan try' e la visualizzazione dei log richiedono una TTY reale.",
            file=sys.stderr,
        )
        sys.exit(1)
    os.environ.setdefault("TERM", "linux")
    curses.wrapper(main_loop)


if __name__ == "__main__":
    main()
