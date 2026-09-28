#!/usr/bin/env bash
# PNeX client setup for Ubuntu / Debian desktops.
#
# Firmware is flashed from the browser through Web Serial (Chrome, Chromium,
# Edge). This script prepares the laptop once:
#   1. serial port access (dialout group)
#   2. removes brltty (it grabs CH340/CH341 USB-serial adapters)
#   3. tells ModemManager to leave ESP USB-serial chips alone
#   4. Chromium snap: USB/serial interface connections
#   5. trusts the PNeX server's local CA (system store, Chrome NSS, Firefox)
#
# Run as your normal user (it calls sudo when needed). Idempotent.
#   curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/client/setup-ubuntu.sh \
#     | bash -s -- --server pnex.local
set -euo pipefail

SERVER=""
CA_FILE=""
SKIP_CA=0
SKIP_SERIAL=0
CA_NAME="PNeX Local CA"
UDEV_RULE=/etc/udev/rules.d/99-pnex-esp-serial.rules

usage() {
    cat <<'EOF'
Usage: setup-ubuntu.sh [--server HOST[:PORT]] [--ca-file PATH] [--skip-ca] [--skip-serial]

  --server HOST     PNeX server name (e.g. pnex.local); the CA is downloaded
                    from https://HOST/api/v1/meta/ca and its fingerprint shown.
  --ca-file PATH    Use a CA file you already have (copied from the server,
                    `pnexctl ca cat`) instead of downloading it.
  --skip-ca         Only do the USB serial part.
  --skip-serial     Only trust the CA.
EOF
}

while (($#)); do
    case $1 in
        --server) SERVER=${2:?--server needs a value}; shift ;;
        --server=*) SERVER=${1#*=} ;;
        --ca-file) CA_FILE=${2:?--ca-file needs a value}; shift ;;
        --ca-file=*) CA_FILE=${1#*=} ;;
        --skip-ca) SKIP_CA=1 ;;
        --skip-serial) SKIP_SERIAL=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

step() { printf '\n\e[1m==> %s\e[0m\n' "$*"; }
ok() { printf '  \e[32m✓\e[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  \e[33m! %s\e[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] && warn "run this as your normal user (not root): group membership and browser stores are per user"
TARGET_USER=${SUDO_USER:-$USER}
NEED_RELOGIN=0

setup_serial() {
    step "1/4 Serial port access (dialout group)"
    info "USB-serial devices (/dev/ttyUSB*, /dev/ttyACM*) belong to the 'dialout' group."
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx dialout; then
        ok "$TARGET_USER is already in dialout"
    else
        sudo usermod -aG dialout "$TARGET_USER"
        NEED_RELOGIN=1
        ok "$TARGET_USER added to dialout (log out and back in for it to apply)"
    fi

    step "2/4 brltty (braille daemon)"
    info "On Ubuntu 22.04+, brltty claims CH340/CH341 adapters (1a86:7523) as braille"
    info "displays: the serial port appears then vanishes instantly."
    if dpkg-query -W -f='${Status}' brltty 2>/dev/null | grep -q "install ok installed"; then
        sudo systemctl stop brltty-udev.service brltty.service 2>/dev/null || true
        sudo systemctl mask brltty-udev.service brltty.service >/dev/null 2>&1 || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq brltty >/dev/null
        ok "brltty removed"
    else
        ok "brltty not installed"
    fi
    local r
    for r in /usr/lib/udev/rules.d/85-brltty.rules /lib/udev/rules.d/85-brltty.rules; do
        if [[ -f $r ]]; then
            sudo mv "$r" "$r.disabled-by-pnex"
            ok "disabled $r"
        fi
    done

    step "3/4 ModemManager exclusion for ESP USB-serial chips"
    info "ModemManager probes new serial ports with AT commands, which can reset or"
    info "confuse an ESP during flashing. The rule below makes it ignore them."
    local rule
    rule=$(cat <<'EOF'
# PNeX: ModemManager must ignore ESP USB-serial bridges (Web Serial flashing).
# CP210x (Silicon Labs)
ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ENV{ID_MM_DEVICE_IGNORE}="1"
# CH340 / CH341 / CH9102 (WCH)
ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d4", ENV{ID_MM_DEVICE_IGNORE}="1"
# FTDI FT232R
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", ENV{ID_MM_DEVICE_IGNORE}="1"
# Espressif native USB (ESP32-S2/S3/C3/C6 USB-Serial-JTAG)
ATTRS{idVendor}=="303a", ENV{ID_MM_DEVICE_IGNORE}="1"
EOF
)
    if [[ -f $UDEV_RULE ]] && [[ "$(cat "$UDEV_RULE")" == "$rule" ]]; then
        ok "$UDEV_RULE already up to date"
    else
        printf '%s\n' "$rule" | sudo tee "$UDEV_RULE" >/dev/null
        ok "wrote $UDEV_RULE"
    fi
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=tty || true
    ok "udev rules reloaded (unplug/replug the board)"

    step "4/4 Browser"
    if command -v snap >/dev/null && snap list chromium >/dev/null 2>&1; then
        info "Chromium is a snap: connecting its USB interfaces."
        if sudo snap connect chromium:raw-usb 2>/dev/null; then
            ok "chromium:raw-usb connected"
        else
            warn "could not connect chromium:raw-usb"
        fi
        info "If the port list stays empty, the snap may also need a serial-port plug for"
        info "your board (snap connections chromium) — or install Google Chrome (.deb),"
        info "which has no sandbox restriction on serial ports."
    elif command -v google-chrome >/dev/null || command -v google-chrome-stable >/dev/null; then
        ok "Google Chrome found (Web Serial supported)"
    elif command -v microsoft-edge >/dev/null; then
        ok "Microsoft Edge found (Web Serial supported)"
    else
        warn "no Chrome/Chromium/Edge found: Web Serial is not available in Firefox."
        info "Install Google Chrome: https://www.google.com/chrome/"
    fi
}

fetch_ca() {
    local out=$1
    if [[ -n $CA_FILE ]]; then
        [[ -s $CA_FILE ]] || { warn "$CA_FILE is empty or missing"; return 1; }
        cp "$CA_FILE" "$out"
        return 0
    fi
    [[ -n $SERVER ]] || { warn "pass --server HOST or --ca-file PATH to trust the CA"; return 1; }
    # First contact: the CA cannot be verified yet (that is what we are
    # installing). Show the fingerprint so it can be compared with the one
    # shown in PNeX (Profile -> About) or by `pnexctl ca cat | openssl x509 -fingerprint -sha256`.
    curl -fsSk "https://$SERVER/api/v1/meta/ca" -o "$out" ||
        { warn "could not download https://$SERVER/api/v1/meta/ca (name resolves? cloud mode has no local CA)"; return 1; }
}

trust_ca() {
    step "Trust the PNeX local CA"
    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    fetch_ca "$tmp" || return 0
    if ! openssl x509 -in "$tmp" -noout 2>/dev/null; then
        warn "the downloaded file is not a certificate"
        return 0
    fi
    info "subject:     $(openssl x509 -in "$tmp" -noout -subject | sed 's/^subject=//')"
    info "fingerprint: $(openssl x509 -in "$tmp" -noout -fingerprint -sha256 | sed 's/^.*=//')"
    if [[ -z $CA_FILE && -r /dev/tty ]]; then
        local answer
        read -r -p "  Trust this CA? [y/N] " answer </dev/tty
        [[ $answer =~ ^[Yy] ]] || { info "skipped"; return 0; }
    fi

    # System store: curl, Python, Rust native-certs...
    sudo install -m 644 "$tmp" /usr/local/share/ca-certificates/pnex-local-ca.crt
    sudo update-ca-certificates >/dev/null
    ok "system trust store"

    # Browsers use NSS: ~/.pki/nssdb (Chrome/Chromium .deb) and each Firefox profile.
    if ! command -v certutil >/dev/null; then
        info "installing libnss3-tools (certutil)"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libnss3-tools >/dev/null
    fi
    local dbs=("$HOME/.pki/nssdb") p db
    for p in "$HOME"/.mozilla/firefox/*.default* \
        "$HOME"/snap/firefox/common/.mozilla/firefox/*.default* \
        "$HOME"/snap/chromium/current/.pki/nssdb; do
        [[ -f $p/cert9.db ]] && dbs+=("$p")
    done
    for db in "${dbs[@]}"; do
        mkdir -p "$db"
        [[ -f $db/cert9.db ]] || certutil -N -d "sql:$db" --empty-password
        certutil -D -d "sql:$db" -n "$CA_NAME" >/dev/null 2>&1 || true
        certutil -A -d "sql:$db" -n "$CA_NAME" -t "C,," -i "$tmp"
        ok "NSS $db"
    done
    info "restart the browsers to pick up the new root"
}

((SKIP_SERIAL)) || setup_serial
((SKIP_CA)) || trust_ca

step "Done"
if ((NEED_RELOGIN)); then
    warn "log out and back in (or reboot) so the dialout group applies."
fi
info "open https://${SERVER:-<your-pnex-host>}/ in Chrome, then Devices -> Flash over USB"
