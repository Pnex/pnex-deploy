#!/usr/bin/env bash
# PNeX installer — production install / upgrade on a single Debian-family
# host (Raspberry Pi OS, Debian, Ubuntu; amd64 or arm64).
#
#   curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/install.sh \
#     | sudo bash -s -- --admin-user admin@acme.io
#
# Idempotent: re-running it upgrades (new recipe + new image tag) and never
# regenerates secrets. Run with --help for all flags.
set -euo pipefail

REPO_SLUG="${PNEX_REPO_SLUG:-Pnex/pnex-deploy}"
RAUTHY_UID=10001
API_KEY_NAME="pnex-install"
MIN_COMPOSE="2.24"

# ── Output helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_B=$'\e[1m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_0=$'\e[0m'
else
    C_B="" C_G="" C_Y="" C_R="" C_0=""
fi
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok() { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  %s! %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
die() { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
PNeX installer

Usage: install.sh [flags]      (flags accept both --flag=value and --flag value)

Identity
  --admin-user EMAIL        Admin account (Rauthy admin + PNeX platform admin).
                            Required on first install (prompted if interactive).
  --admin-password PASS     Admin password. Generated and printed once when omitted
                            in non-interactive mode. Cannot contain a single quote.

Network / TLS
  --domain NAME             Public name (default: <hostname>.local, published by mDNS).
                            An IP address works too (passkeys are then unavailable).
  --tls local|cloud         local (default): private CA generated on this host.
                            cloud: Let's Encrypt (ports 80/443 reachable from the
                            internet, --domain and --acme-email required).
  --acme-email EMAIL        Let's Encrypt account email (cloud mode).
  --acme-staging            Use the Let's Encrypt staging CA (testing).
  --http-port N             Published HTTP port (default 80).
  --https-port N            Published HTTPS port (default 443).

Sizing / storage
  --profile raspi|server    raspi: memory-tuned for a 4-8 GB Raspberry Pi.
                            server: defaults. Default: auto-detected.
  --storage fs|s3           fs (default): firmware in Postgres, media on a volume.
                            s3: adds RustFS (S3-compatible) for firmware + media.
                            Chosen once: changing it later needs --force and loses
                            access to the objects stored with the previous backend.

Mail (optional — without it, self-registration and password-reset mails are off)
  --smtp-url HOST  --smtp-port N (587)  --smtp-user USER  --smtp-password PASS
  --smtp-from 'PNeX <noreply@example.com>'

Versions / source
  --tag TAG                 Image tag (default: the VERSION file of the recipe).
  --ref REF                 Recipe git ref (branch, tag or commit; default main).
  --version REF             Alias of --ref.
  --source auto|local|remote  Where the recipe comes from: remote = GitHub tarball
                            of --ref; local = the directory holding this script.
                            auto (default): local when run from a checkout.
  --home DIR                Install directory (default /opt/pnex).
  --registry PREFIX         Image registry prefix (default docker.io/shanisma).
  --no-pull                 Do not pull images (use images already loaded).

Behaviour
  --non-interactive, -y     Never prompt.
  --dry-run                 Render everything into a temporary directory, change
                            nothing on the system, do not start containers.
  --force                   Allow risky changes (storage backend switch).
  --timeout SECONDS         Health wait budget (default 600).
  -h, --help                This help.
EOF
}

# ── Flags ───────────────────────────────────────────────────────────────
F_ADMIN_USER="" F_ADMIN_PASSWORD="" F_DOMAIN="" F_TLS="" F_ACME_EMAIL=""
F_ACME_STAGING="" F_HTTP_PORT="" F_HTTPS_PORT="" F_PROFILE="" F_STORAGE=""
F_SMTP_URL="" F_SMTP_PORT="" F_SMTP_USER="" F_SMTP_PASSWORD="" F_SMTP_FROM=""
F_TAG="" F_REF="" F_SOURCE="auto" F_HOME="" F_REGISTRY=""
NO_PULL=0 NON_INTERACTIVE=0 DRY_RUN=0 FORCE=0 WAIT_SECS=600

parse_args() {
    local arg key val
    while (($#)); do
        arg=$1
        shift
        case $arg in
            -h | --help) usage; exit 0 ;;
            -y | --non-interactive) NON_INTERACTIVE=1; continue ;;
            --dry-run) DRY_RUN=1; continue ;;
            --force) FORCE=1; continue ;;
            --no-pull) NO_PULL=1; continue ;;
            --acme-staging) F_ACME_STAGING=1; continue ;;
            --*=*) key=${arg%%=*}; val=${arg#*=} ;;
            --*)
                key=$arg
                (($#)) || die "$key needs a value"
                val=$1
                shift
                ;;
            *) die "unexpected argument '$arg' (see --help)" ;;
        esac
        case $key in
            --admin-user) F_ADMIN_USER=$val ;;
            --admin-password) F_ADMIN_PASSWORD=$val ;;
            --domain) F_DOMAIN=$val ;;
            --tls) F_TLS=$val ;;
            --acme-email) F_ACME_EMAIL=$val ;;
            --http-port) F_HTTP_PORT=$val ;;
            --https-port) F_HTTPS_PORT=$val ;;
            --profile) F_PROFILE=$val ;;
            --storage) F_STORAGE=$val ;;
            --smtp-url) F_SMTP_URL=$val ;;
            --smtp-port) F_SMTP_PORT=$val ;;
            --smtp-user) F_SMTP_USER=$val ;;
            --smtp-password) F_SMTP_PASSWORD=$val ;;
            --smtp-from) F_SMTP_FROM=$val ;;
            --tag) F_TAG=$val ;;
            --ref | --version) F_REF=$val ;;
            --source) F_SOURCE=$val ;;
            --home) F_HOME=$val ;;
            --registry) F_REGISTRY=$val ;;
            --timeout) WAIT_SECS=$val ;;
            *) die "unknown flag '$key' (see --help)" ;;
        esac
    done
}

# ── .env handling ───────────────────────────────────────────────────────
# The .env is written with single-quoted values (literal for both Docker
# Compose and this parser). Lines after OVERRIDE_MARKER are user overrides,
# kept verbatim on every re-run (Compose: the last definition wins).
OVERRIDE_MARKER="# ---- user overrides below this line are kept on re-run ----"
declare -A OLD_ENV=()

load_env() { # $1 = file
    local line key val
    [[ -f $1 ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        if [[ $val =~ ^\'(.*)\'$ || $val =~ ^\"(.*)\"$ ]]; then
            val=${BASH_REMATCH[1]}
        fi
        OLD_ENV[$key]=$val
    done <"$1"
}

old() { printf '%s' "${OLD_ENV[$1]:-}"; }

# First non-empty argument.
pick() {
    local v
    for v in "$@"; do
        [[ -n $v ]] && { printf '%s' "$v"; return 0; }
    done
    return 0
}

rand_hex() { openssl rand -hex "$1"; }

# ── Environment probes ──────────────────────────────────────────────────
detect_arch() {
    case $(uname -m) in
        x86_64 | amd64) echo amd64 ;;
        aarch64 | arm64) echo arm64 ;;
        *) echo "unsupported:$(uname -m)" ;;
    esac
}

is_raspberry_pi() {
    grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null
}

mem_total_mb() {
    awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo
}

lan_ipv4s() {
    ip -4 -o addr show scope global 2>/dev/null |
        awk '$2 !~ /^(docker|br-|veth|virbr|lxcbr|cni|flannel)/ {split($4, a, "/"); print a[1]}' |
        sort -u
}

is_ip() { [[ $1 =~ ^[0-9]+(\.[0-9]+){3}$ ]]; }

version_ge() { # $1 >= $2 (dotted numeric)
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

prompt() { # $1 = question, $2 = secret(0/1) — reads from the terminal even when piped
    local answer=""
    [[ -r /dev/tty ]] || die "cannot prompt (no terminal): pass the value as a flag"
    if [[ $2 == 1 ]]; then
        read -r -s -p "  $1: " answer </dev/tty
        echo >/dev/tty
    else
        read -r -p "  $1: " answer </dev/tty
    fi
    printf '%s' "$answer"
}

# ── Main steps ──────────────────────────────────────────────────────────
resolve_settings() {
    step "Settings"
    ARCH=$(detect_arch)
    [[ $ARCH == unsupported:* ]] && die "unsupported CPU architecture ${ARCH#unsupported:} (amd64 or arm64 only)"
    HOSTNAME_LC=$(hostname | tr '[:upper:]' '[:lower:]')
    FIRST_INSTALL=1
    [[ -f $PNEX_HOME/.env ]] && FIRST_INSTALL=0

    # Admin identity.
    ADMIN_EMAIL=$(pick "$F_ADMIN_USER" "$(old PNEX_ADMIN_EMAIL)")
    if [[ -z $ADMIN_EMAIL ]]; then
        ((NON_INTERACTIVE)) && die "--admin-user is required on first install"
        ADMIN_EMAIL=$(prompt "Admin email" 0)
    fi
    [[ $ADMIN_EMAIL =~ ^[^@\'[:space:]]+@[^@\'[:space:]]+\.[^@\'[:space:]]+$ ]] ||
        die "invalid admin email '$ADMIN_EMAIL'"
    if [[ -n $(old PNEX_ADMIN_EMAIL) && $ADMIN_EMAIL != "$(old PNEX_ADMIN_EMAIL)" ]]; then
        warn "admin email changed: Rauthy only reads the bootstrap admin on first start —"
        warn "create $ADMIN_EMAIL in the Rauthy admin UI; it becomes PNeX platform admin now."
    fi
    ADMIN_PASSWORD=$(pick "$F_ADMIN_PASSWORD" "$(old PNEX_ADMIN_PASSWORD)")
    GENERATED_PASSWORD=0
    if [[ -z $ADMIN_PASSWORD ]]; then
        if ((NON_INTERACTIVE)); then
            ADMIN_PASSWORD="$(rand_hex 12)"
            GENERATED_PASSWORD=1
        else
            ADMIN_PASSWORD=$(prompt "Admin password (empty = generate one)" 1)
            [[ -n $ADMIN_PASSWORD ]] || { ADMIN_PASSWORD="$(rand_hex 12)"; GENERATED_PASSWORD=1; }
        fi
    fi
    [[ $ADMIN_PASSWORD == *"'"* ]] && die "the admin password cannot contain a single quote"
    ((${#ADMIN_PASSWORD} >= 8)) || die "the admin password must be at least 8 characters"
    if [[ -n $F_ADMIN_PASSWORD && -n $(old PNEX_ADMIN_PASSWORD) && $F_ADMIN_PASSWORD != "$(old PNEX_ADMIN_PASSWORD)" ]]; then
        warn "--admin-password only applies on first install; change it in Rauthy (account page)."
    fi

    # TLS + domain.
    TLS_MODE=$(pick "$F_TLS" "$(old PNEX_TLS_MODE)" local)
    [[ $TLS_MODE == local || $TLS_MODE == cloud ]] || die "--tls must be local or cloud"
    DOMAIN=$(pick "$F_DOMAIN" "$(old PNEX_DOMAIN)" "$HOSTNAME_LC.local")
    DOMAIN=$(tr '[:upper:]' '[:lower:]' <<<"$DOMAIN")
    [[ $DOMAIN =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "invalid domain '$DOMAIN'"
    if [[ -n $(old PNEX_DOMAIN) && $DOMAIN != "$(old PNEX_DOMAIN)" ]]; then
        warn "domain changes from $(old PNEX_DOMAIN) to $DOMAIN: devices flashed for the old name must be re-flashed."
    fi
    ACME_EMAIL=$(pick "$F_ACME_EMAIL" "$(old ACME_EMAIL)")
    ACME_STAGING=$(pick "$F_ACME_STAGING" "$(old ACME_STAGING)")
    if [[ $TLS_MODE == cloud ]]; then
        [[ -n $ACME_EMAIL ]] || die "--acme-email is required with --tls=cloud"
        is_ip "$DOMAIN" && die "--tls=cloud needs a public DNS name, not an IP"
        [[ $DOMAIN == *.local ]] && die "--tls=cloud needs a public DNS name (not .local): pass --domain"
    fi
    HTTP_PORT=$(pick "$F_HTTP_PORT" "$(old PNEX_HTTP_PORT)" 80)
    HTTPS_PORT=$(pick "$F_HTTPS_PORT" "$(old PNEX_HTTPS_PORT)" 443)
    [[ $HTTP_PORT =~ ^[0-9]+$ && $HTTPS_PORT =~ ^[0-9]+$ ]] || die "ports must be numbers"
    PUBLIC_HOST=$DOMAIN
    [[ $HTTPS_PORT != 443 ]] && PUBLIC_HOST="$DOMAIN:$HTTPS_PORT"
    if is_ip "$DOMAIN"; then RP_ID=localhost; else RP_ID=$DOMAIN; fi
    RP_ORIGIN="https://$RP_ID:$HTTPS_PORT"

    # Extra SANs (local mode): mDNS alias + every LAN IPv4, as IP: (browsers)
    # and DNS: (mbedTLS 2.x on ESP32 only matches dNSName entries).
    EXTRA_SANS=""
    DOMAIN_ALIAS=""
    if [[ $TLS_MODE == local ]]; then
        local ip
        for ip in $(lan_ipv4s); do
            [[ $ip == "$DOMAIN" ]] && continue
            EXTRA_SANS="${EXTRA_SANS:+$EXTRA_SANS,}IP:$ip,DNS:$ip"
        done
        if [[ "$HOSTNAME_LC.local" != "$DOMAIN" ]]; then
            DOMAIN_ALIAS="$HOSTNAME_LC.local"
            EXTRA_SANS="DNS:$DOMAIN_ALIAS${EXTRA_SANS:+,$EXTRA_SANS}"
        fi
        is_ip "$DOMAIN" && EXTRA_SANS="IP:$DOMAIN${EXTRA_SANS:+,$EXTRA_SANS}"
    fi

    # Profile.
    local auto_profile=server
    if is_raspberry_pi || (($(mem_total_mb) < 6000)); then auto_profile=raspi; fi
    PROFILE=$(pick "$F_PROFILE" "$(old PNEX_PROFILE)" "$auto_profile")
    [[ $PROFILE == raspi || $PROFILE == server ]] || die "--profile must be raspi or server"

    # Storage (sticky: no migration between backends).
    STORAGE=$(pick "$F_STORAGE" "$(old PNEX_STORAGE)" fs)
    [[ $STORAGE == fs || $STORAGE == s3 ]] || die "--storage must be fs or s3"
    if [[ -n $(old PNEX_STORAGE) && $STORAGE != "$(old PNEX_STORAGE)" ]] && ((!FORCE)); then
        die "storage is already '$(old PNEX_STORAGE)'; switching backends does not migrate data (re-run with --force if you really mean it)"
    fi

    # SMTP (optional).
    SMTP_URL=$(pick "$F_SMTP_URL" "$(old SMTP_URL)")
    SMTP_PORT=$(pick "$F_SMTP_PORT" "$(old SMTP_PORT)" 587)
    SMTP_USERNAME=$(pick "$F_SMTP_USER" "$(old SMTP_USERNAME)")
    SMTP_PASSWORD=$(pick "$F_SMTP_PASSWORD" "$(old SMTP_PASSWORD)")
    SMTP_FROM=$(pick "$F_SMTP_FROM" "$(old SMTP_FROM)")
    if [[ -n $SMTP_URL && -z $SMTP_FROM ]]; then
        SMTP_FROM="PNeX <noreply@$DOMAIN>"
    fi
    [[ "$SMTP_PASSWORD$SMTP_FROM$SMTP_USERNAME" == *"'"* ]] && die "SMTP values cannot contain a single quote"

    REF=$(pick "$F_REF" "$(old PNEX_REF)" main)
    REGISTRY=$(pick "$F_REGISTRY" "$(old PNEX_IMAGE_REGISTRY)" docker.io/shanisma)

    info "arch $ARCH, profile $PROFILE, storage $STORAGE, TLS $TLS_MODE"
    info "origin https://$PUBLIC_HOST (install dir $PNEX_HOME)"
    if ((FIRST_INSTALL)); then info "first install"; else info "existing install found: upgrade (secrets kept)"; fi
    if [[ $(getconf PAGESIZE 2>/dev/null || echo 4096) -gt 4096 ]]; then
        warn "kernel page size is $(getconf PAGESIZE) bytes (Raspberry Pi 5 default kernel)."
        warn "Some images (jemalloc) crash with it: add 'kernel=kernel8.img' to /boot/firmware/config.txt and reboot."
    fi
}

apt_ensure() { # packages...
    local missing=() p
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
    done
    ((${#missing[@]})) || return 0
    info "installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

# Tools the installer itself needs (secrets, JSON, downloads).
install_base_tools() {
    if ((DRY_RUN)); then
        local t
        for t in openssl curl tar; do
            command -v "$t" >/dev/null || die "$t is required"
        done
        return 0
    fi
    command -v apt-get >/dev/null || die "apt-get not found: only Debian-family systems are supported"
    apt_ensure ca-certificates curl openssl jq tar iproute2
}

install_prerequisites() {
    step "System packages"
    ((DRY_RUN)) && { info "dry-run: skipped"; return; }
    ok "base tools present (curl, openssl, jq)"
    if [[ $DOMAIN == *.local || -n $DOMAIN_ALIAS ]]; then
        apt_ensure avahi-daemon
        configure_avahi
    fi
}

# mDNS: publish <hostname>.local on the LAN interface only — by default
# avahi also announces the Docker bridge addresses, and clients may then
# resolve the name to an unreachable 172.x address.
configure_avahi() {
    local conf=/etc/avahi/avahi-daemon.conf iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    if [[ -f $conf && -n $iface ]] && ! grep -Eq '^[[:space:]]*allow-interfaces=' "$conf"; then
        sed -i "s/^\[server\]/[server]\nallow-interfaces=$iface/" "$conf"
        info "avahi restricted to $iface"
    fi
    systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
    systemctl restart avahi-daemon >/dev/null 2>&1 || true
    ok "mDNS: $HOSTNAME_LC.local"
}

install_docker() {
    step "Docker Engine"
    if ((DRY_RUN)); then
        if command -v docker >/dev/null; then info "docker present"; else info "dry-run: would install Docker from get.docker.com"; fi
        return
    fi
    if ! command -v docker >/dev/null; then
        info "installing Docker Engine (get.docker.com)"
        curl -fsSL https://get.docker.com | sh >/dev/null
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    if ! docker compose version >/dev/null 2>&1; then
        info "installing the compose plugin"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin >/dev/null ||
            die "could not install the Docker compose plugin"
    fi
    local v
    v=$(docker compose version --short 2>/dev/null | sed 's/^v//')
    version_ge "$v" "$MIN_COMPOSE" || die "docker compose $v is too old (need >= $MIN_COMPOSE)"
    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), compose $v"
}

# Directory holding this script when it is a real file (not piped).
script_dir() {
    local src=${BASH_SOURCE[0]:-}
    [[ -n $src && -f $src ]] || return 1
    (cd "$(dirname "$src")" && pwd)
}

fetch_recipe() {
    step "Recipe"
    local src="" sdir=""
    sdir=$(script_dir || true)
    case $F_SOURCE in
        local) [[ -n $sdir && -f $sdir/compose.yaml ]] || die "--source=local: no compose.yaml next to this script"; src=local ;;
        remote) src=remote ;;
        auto) if [[ -n $sdir && -f $sdir/compose.yaml ]]; then src=local; else src=remote; fi ;;
        *) die "--source must be auto, local or remote" ;;
    esac
    SOURCE=$src
    mkdir -p "$PNEX_HOME"
    local tmp
    tmp=$(mktemp -d)
    if [[ $src == local ]]; then
        if [[ $sdir -ef $PNEX_HOME ]]; then
            ok "running from $PNEX_HOME itself, recipe kept as is"
            rm -rf "$tmp"
            return
        fi
        tar -C "$sdir" --exclude=.git --exclude=.env --exclude=state -cf - . | tar -C "$tmp" -xf -
        info "local recipe: $sdir"
    else
        local url="https://github.com/$REPO_SLUG/archive/$REF.tar.gz"
        info "downloading $url"
        curl -fsSL "$url" | tar -C "$tmp" -xzf - --strip-components=1 ||
            die "could not download the recipe (ref '$REF')"
    fi
    [[ -f $tmp/compose.yaml ]] || die "recipe has no compose.yaml"
    # Replace every recipe entry; .env and state/ are never part of it.
    local entry name
    for entry in "$tmp"/* "$tmp"/.[!.]*; do
        [[ -e $entry ]] || continue
        name=$(basename "$entry")
        [[ $name == .env || $name == state || $name == .git ]] && continue
        rm -rf "${PNEX_HOME:?}/$name"
        cp -a "$entry" "$PNEX_HOME/$name"
    done
    rm -rf "$tmp"
    if [[ $src == remote ]]; then ok "recipe $REF installed in $PNEX_HOME"; else ok "local recipe installed in $PNEX_HOME"; fi
}

resolve_tag() {
    local version=""
    [[ -f $PNEX_HOME/VERSION ]] && version=$(tr -d '[:space:]' <"$PNEX_HOME/VERSION")
    TAG=$(pick "$F_TAG" "$version")
    [[ -n $TAG ]] || die "no image tag: pass --tag"
    if [[ $TAG == *PLACEHOLDER* ]]; then
        ((DRY_RUN)) || die "the recipe's VERSION is a placeholder ($TAG): pass --tag"
        warn "VERSION is a placeholder ($TAG)"
    fi
    if [[ -n $(old PNEX_TAG) && $(old PNEX_TAG) != "$TAG" ]]; then
        info "image tag: $(old PNEX_TAG) -> $TAG"
    else
        info "image tag: $TAG"
    fi
}

profile_tuning() {
    if [[ $PROFILE == raspi ]]; then
        cat <<'EOF'
PG_SHARED_BUFFERS='64MB'
PG_EFFECTIVE_CACHE_SIZE='256MB'
PG_WORK_MEM='2MB'
PG_MAINTENANCE_WORK_MEM='32MB'
PG_MAX_CONNECTIONS='40'
PNEX_DB_MAX_CONNECTIONS='5'
VALKEY_MAXMEMORY='64mb'
O2_MEM_LIMIT='1g'
ZO_MEMORY_CACHE_MAX_SIZE='128'
ZO_MEMORY_CACHE_DATAFUSION_MAX_SIZE='128'
ZO_MEM_TABLE_MAX_SIZE='64'
ZO_MAX_FILE_SIZE_IN_MEMORY='32'
ZO_DISK_CACHE_MAX_SIZE='512'
ZO_QUERY_THREAD_NUM='2'
PNEX_STITCH_MAX_CONCURRENT='1'
EOF
    else
        cat <<'EOF'
PG_SHARED_BUFFERS='256MB'
PG_EFFECTIVE_CACHE_SIZE='1GB'
PG_WORK_MEM='4MB'
PG_MAINTENANCE_WORK_MEM='64MB'
PG_MAX_CONNECTIONS='100'
PNEX_DB_MAX_CONNECTIONS='10'
VALKEY_MAXMEMORY='128mb'
O2_MEM_LIMIT='4g'
ZO_MEMORY_CACHE_MAX_SIZE='1024'
ZO_MEMORY_CACHE_DATAFUSION_MAX_SIZE='1024'
ZO_MEM_TABLE_MAX_SIZE='512'
ZO_MAX_FILE_SIZE_IN_MEMORY='128'
ZO_DISK_CACHE_MAX_SIZE='2048'
ZO_QUERY_THREAD_NUM='0'
PNEX_STITCH_MAX_CONCURRENT='2'
EOF
    fi
}

write_env() {
    step "Configuration (.env)"
    local envf=$PNEX_HOME/.env
    # Secrets: generated once, then always read back.
    POSTGRES_PASSWORD=$(pick "$(old POSTGRES_PASSWORD)" "$(rand_hex 24)")
    OPENOBSERVE_ROOT_PASSWORD=$(pick "$(old OPENOBSERVE_ROOT_PASSWORD)" "O2x$(rand_hex 16)Z9!")
    PNEX_NOTIFY_INTERNAL_TOKEN=$(pick "$(old PNEX_NOTIFY_INTERNAL_TOKEN)" "$(rand_hex 32)")
    PNEX_FLOW_RUNTIME_TOKEN=$(pick "$(old PNEX_FLOW_RUNTIME_TOKEN)" "$(rand_hex 32)")
    RAUTHY_SECRET_RAFT=$(pick "$(old RAUTHY_SECRET_RAFT)" "$(rand_hex 24)")
    RAUTHY_SECRET_API=$(pick "$(old RAUTHY_SECRET_API)" "$(rand_hex 24)")
    RAUTHY_ENC_KEY_ID=$(pick "$(old RAUTHY_ENC_KEY_ID)" "k$(rand_hex 7)")
    RAUTHY_ENC_KEY=$(pick "$(old RAUTHY_ENC_KEY)" "$(openssl rand -base64 32)")
    RAUTHY_API_KEY_SECRET=$(pick "$(old RAUTHY_API_KEY_SECRET)" "$(rand_hex 32)")
    RUSTFS_ACCESS_KEY=$(pick "$(old RUSTFS_ACCESS_KEY)" "pnex$(rand_hex 8)")
    RUSTFS_SECRET_KEY=$(pick "$(old RUSTFS_SECRET_KEY)" "$(rand_hex 20)")

    local profiles=() storage_backend=db media_backend=fs s3_endpoint="" s3_bucket="" s3_region=""
    if [[ $STORAGE == s3 ]]; then
        profiles+=(s3)
        storage_backend=s3 media_backend=s3
        s3_endpoint=http://rustfs:9000 s3_bucket=pnex s3_region=us-east-1
    fi
    [[ $TLS_MODE == cloud ]] && profiles+=(cloud)
    local joined
    joined=$(IFS=,; echo "${profiles[*]}")

    local overrides=""
    if [[ -f $envf ]]; then
        overrides=$(awk -v m="$OVERRIDE_MARKER" 'found {print} $0 == m {found = 1}' "$envf")
    fi

    local tmp
    tmp=$(mktemp)
    {
        echo "# PNeX — generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep it secret (chmod 600)."
        echo "# Re-running install.sh rewrites everything above the override marker;"
        echo "# secrets are generated once and always kept."
        echo
        echo "# ---- install settings ----"
        echo "COMPOSE_PROFILES='$joined'"
        echo "PNEX_TAG='$TAG'"
        echo "PNEX_IMAGE_REGISTRY='$REGISTRY'"
        echo "PNEX_REF='$REF'"
        echo "PNEX_SOURCE='$SOURCE'"
        echo "PNEX_PROFILE='$PROFILE'"
        echo "PNEX_STORAGE='$STORAGE'"
        echo "PNEX_TLS_MODE='$TLS_MODE'"
        echo "PNEX_DOMAIN='$DOMAIN'"
        echo "PNEX_PUBLIC_HOST='$PUBLIC_HOST'"
        echo "PNEX_DOMAIN_ALIAS='$DOMAIN_ALIAS'"
        echo "PNEX_EXTRA_SANS='$EXTRA_SANS'"
        echo "PNEX_RP_ID='$RP_ID'"
        echo "PNEX_RP_ORIGIN='$RP_ORIGIN'"
        echo "PNEX_HTTP_PORT='$HTTP_PORT'"
        echo "PNEX_HTTPS_PORT='$HTTPS_PORT'"
        echo "PNEX_NET_SUBNET='$(pick "$(old PNEX_NET_SUBNET)" 172.30.66.0/24)'"
        echo "ACME_EMAIL='$ACME_EMAIL'"
        echo "ACME_STAGING='$ACME_STAGING'"
        echo
        echo "# ---- identity ----"
        echo "# The admin password is only used when Rauthy initialises its database;"
        echo "# change it later from the Rauthy account page (this value then goes stale)."
        echo "PNEX_ADMIN_EMAIL='$ADMIN_EMAIL'"
        echo "PNEX_ADMIN_PASSWORD='$ADMIN_PASSWORD'"
        echo "PNEX_PLATFORM_ADMIN_EMAILS='$ADMIN_EMAIL'"
        echo "PNEX_DEPLOYMENT_MODE='self_hosted'"
        echo "PNEX_DEFAULT_RETENTION_DAYS='$(pick "$(old PNEX_DEFAULT_RETENTION_DAYS)" 30)'"
        echo "SMTP_URL='$SMTP_URL'"
        echo "SMTP_PORT='$SMTP_PORT'"
        echo "SMTP_USERNAME='$SMTP_USERNAME'"
        echo "SMTP_PASSWORD='$SMTP_PASSWORD'"
        echo "SMTP_FROM='$SMTP_FROM'"
        echo
        echo "# ---- storage ----"
        echo "STORAGE_BACKEND='$storage_backend'"
        echo "MEDIA_BACKEND='$media_backend'"
        echo "PNEX_S3_ENDPOINT='$s3_endpoint'"
        echo "PNEX_S3_BUCKET='$s3_bucket'"
        echo "PNEX_S3_REGION='$s3_region'"
        echo "PNEX_S3_PATH_STYLE='true'"
        echo
        echo "# ---- secrets (generated once) ----"
        echo "POSTGRES_PASSWORD='$POSTGRES_PASSWORD'"
        echo "OPENOBSERVE_ROOT_EMAIL='root@pnex.local'"
        echo "OPENOBSERVE_ROOT_PASSWORD='$OPENOBSERVE_ROOT_PASSWORD'"
        echo "PNEX_NOTIFY_INTERNAL_TOKEN='$PNEX_NOTIFY_INTERNAL_TOKEN'"
        echo "PNEX_FLOW_RUNTIME_TOKEN='$PNEX_FLOW_RUNTIME_TOKEN'"
        echo "RAUTHY_SECRET_RAFT='$RAUTHY_SECRET_RAFT'"
        echo "RAUTHY_SECRET_API='$RAUTHY_SECRET_API'"
        echo "RAUTHY_ENC_KEY_ID='$RAUTHY_ENC_KEY_ID'"
        echo "RAUTHY_ENC_KEY='$RAUTHY_ENC_KEY'"
        echo "RAUTHY_API_KEY_SECRET='$RAUTHY_API_KEY_SECRET'"
        echo "RUSTFS_ACCESS_KEY='$RUSTFS_ACCESS_KEY'"
        echo "RUSTFS_SECRET_KEY='$RUSTFS_SECRET_KEY'"
        echo
        echo "# ---- profile tuning ($PROFILE) ----"
        profile_tuning
        echo
        echo "$OVERRIDE_MARKER"
        [[ -n $overrides ]] && printf '%s\n' "$overrides"
    } >"$tmp"
    install -m 600 "$tmp" "$envf"
    rm -f "$tmp"
    ok "$envf (mode 600)"
}

# Replaces @KEY@ placeholders; quoted replacement keeps '&' literal.
render() { # $1 = template, $2 = output, rest = KEY=value pairs
    local tpl=$1 out=$2 content kv
    shift 2
    content=$(<"$tpl")
    for kv in "$@"; do
        content=${content//"@${kv%%=*}@"/"${kv#*=}"}
    done
    [[ $content == *@[A-Z_]*@* ]] && grep -o '@[A-Z_]*@' <<<"$content" | sort -u | sed 's/^/  unrendered /' >&2
    printf '%s\n' "$content" >"$out"
}

render_state() {
    step "Rauthy + PKI state"
    local st=$PNEX_HOME/state tpl=$PNEX_HOME/config/rauthy
    mkdir -p "$st/pki" "$st/rauthy/bootstrap"
    chmod 755 "$st" "$st/pki"
    local registration=false
    [[ -n $SMTP_URL ]] && registration=true
    render "$tpl/config.toml.tmpl" "$st/rauthy/config.toml" \
        "PUBLIC_HOST=$PUBLIC_HOST" "RAUTHY_SECRET_RAFT=$RAUTHY_SECRET_RAFT" \
        "RAUTHY_SECRET_API=$RAUTHY_SECRET_API" "RAUTHY_ENC_KEY_ID=$RAUTHY_ENC_KEY_ID" \
        "RAUTHY_ENC_KEY=$RAUTHY_ENC_KEY" "RAUTHY_REGISTRATION=$registration" \
        "ADMIN_EMAIL=$ADMIN_EMAIL" "RP_ID=$RP_ID" "RP_ORIGIN=$RP_ORIGIN"
    # Bootstrap files are only read by Rauthy on its very first start.
    render "$tpl/clients.json.tmpl" "$st/rauthy/bootstrap/clients.json" "PUBLIC_HOST=$PUBLIC_HOST"
    render "$tpl/api_keys.json.tmpl" "$st/rauthy/bootstrap/api_keys.json" \
        "RAUTHY_API_KEY_SECRET=$RAUTHY_API_KEY_SECRET"
    # SMTP variables must be absent (not empty) when mail is off.
    {
        echo "# Generated by install.sh — Rauthy SMTP settings (empty = no mail)."
        if [[ -n $SMTP_URL ]]; then
            echo "SMTP_URL=$SMTP_URL"
            echo "SMTP_PORT=$SMTP_PORT"
            [[ -n $SMTP_USERNAME ]] && echo "SMTP_USERNAME=$SMTP_USERNAME"
            [[ -n $SMTP_PASSWORD ]] && echo "SMTP_PASSWORD='$SMTP_PASSWORD'"
            echo "SMTP_FROM='$SMTP_FROM'"
        fi
    } >"$st/rauthy/smtp.env"
    chmod 600 "$st/rauthy/smtp.env"
    if ((DRY_RUN)); then
        info "dry-run: ownership change to uid $RAUTHY_UID skipped"
    else
        chown -R "$RAUTHY_UID:$RAUTHY_UID" "$st/rauthy/config.toml" "$st/rauthy/bootstrap"
        chown root:root "$st/rauthy/smtp.env"
        chown "$RAUTHY_UID:$RAUTHY_UID" "$st/rauthy"
    fi
    chmod 700 "$st/rauthy" "$st/rauthy/bootstrap"
    chmod 600 "$st/rauthy/config.toml" "$st/rauthy/bootstrap/"*.json
    ok "state/rauthy rendered (registration: $registration)"
}

compose() { (cd "$PNEX_HOME" && docker compose "$@"); }

start_stack() {
    step "Containers"
    if ((DRY_RUN)); then
        if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
            compose config -q && ok "docker compose config: valid"
            info "services: $(compose config --services | tr '\n' ' ')"
        fi
        info "dry-run: pull/up skipped"
        return
    fi
    if ((NO_PULL)); then
        info "--no-pull: using local images"
    else
        info "pulling images (first run on a Pi can take a while)"
        compose pull --quiet ||
            die "image pull failed (tag '$TAG' published for $ARCH? check: docker manifest inspect $REGISTRY/pnex-server-rs:$TAG)"
    fi
    compose up -d --remove-orphans --quiet-pull
    ok "stack started"
}

# curl through nginx on loopback, trusting the local CA (or -k while the
# cloud placeholder is served).
edge_curl() {
    local tls=(--cacert "$PNEX_HOME/state/pki/ca.pem")
    [[ $TLS_MODE == cloud ]] && tls=(-k)
    curl -sS --max-time 10 --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" "${tls[@]}" "$@"
}

wait_healthy() {
    step "Health"
    ((DRY_RUN)) && { info "dry-run: skipped"; return; }
    local deadline=$((SECONDS + WAIT_SECS)) issuer="" code=""
    local discovery="https://$PUBLIC_HOST/auth/v1/.well-known/openid-configuration"
    while ((SECONDS < deadline)); do
        issuer=$(edge_curl -f "$discovery" 2>/dev/null | jq -r .issuer 2>/dev/null) && [[ -n $issuer && $issuer != null ]] && break
        issuer=""
        sleep 3
    done
    [[ -n $issuer ]] || die "OIDC discovery unreachable at $discovery (pnexctl logs nginx / pnexctl logs rauthy)"
    ok "OIDC issuer: $issuer"
    [[ $issuer == "https://$PUBLIC_HOST/auth/v1"* ]] || warn "unexpected issuer (expected https://$PUBLIC_HOST/auth/v1/)"
    while ((SECONDS < deadline)); do
        code=$(edge_curl -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/" 2>/dev/null || true)
        [[ $code == 200 ]] && break
        sleep 3
    done
    [[ $code == 200 ]] || die "pnex-server not answering through nginx (HTTP ${code:-none}; pnexctl logs pnex-server)"
    ok "pnex-server: https://$PUBLIC_HOST/ -> 200"
}

# The bootstrap client only exists on first init: make sure the current
# origin is registered (domain or port changed on a re-run).
sync_oidc_client() {
    ((DRY_RUN)) && return
    local auth="Authorization: API-Key $API_KEY_NAME\$$RAUTHY_API_KEY_SECRET"
    local base="https://$PUBLIC_HOST/auth/v1" json new code origin="https://$PUBLIC_HOST"
    json=$(edge_curl -f -H "$auth" "$base/clients/pnex") || { warn "could not read the OIDC client (API key?) — skipped"; return; }
    new=$(jq --arg o "$origin" '
        .redirect_uris = ((.redirect_uris // []) + [$o + "/auth/callback", $o + "/api/v1/oauth2/native"] | unique)
        | .post_logout_redirect_uris = ((.post_logout_redirect_uris // []) + [$o + "/"] | unique)
        | .allowed_origins = ((.allowed_origins // []) + [$o] | unique)' <<<"$json")
    local norm='.redirect_uris |= sort | .post_logout_redirect_uris |= sort | .allowed_origins |= sort'
    if [[ "$(jq -S "$norm" <<<"$json")" == "$(jq -S "$norm" <<<"$new")" ]]; then
        ok "OIDC client pnex already knows $origin"
        return
    fi
    code=$(edge_curl -o /dev/null -w '%{http_code}' -X PUT -H "$auth" -H 'Content-Type: application/json' \
        -d "$new" "$base/clients/pnex") || true
    if [[ $code == 2* ]]; then ok "OIDC client pnex updated for $origin"; else warn "OIDC client update failed (HTTP $code)"; fi
}

apply_branding() {
    ((DRY_RUN)) && return
    local auth="Authorization: API-Key $API_KEY_NAME\$$RAUTHY_API_KEY_SECRET"
    local b=$PNEX_HOME/config/rauthy/branding base="https://$PUBLIC_HOST/auth/v1" c failed=0 theme
    for c in pnex rauthy; do
        theme=$(sed "s/\"client_id\": \"pnex\"/\"client_id\": \"$c\"/" "$b/theme.json")
        edge_curl -f -o /dev/null -X PUT -H "$auth" -H 'Content-Type: application/json' -d "$theme" "$base/theme/$c" || failed=1
        edge_curl -f -o /dev/null -X PUT -H "$auth" -F "image=@$b/logo-card.png;type=image/png" "$base/clients/$c/logo" || failed=1
        edge_curl -f -o /dev/null -X PUT -H "$auth" -F "image=@$b/logo-mark.png;type=image/png" "$base/clients/$c/favicon" || failed=1
    done
    if ((failed)); then warn "Rauthy branding partially failed (cosmetic only)"; else ok "Rauthy login pages branded"; fi
}

install_pnexctl() {
    ((DRY_RUN)) && return
    install -m 755 "$PNEX_HOME/scripts/pnexctl" /usr/local/bin/pnexctl
    ok "pnexctl installed in /usr/local/bin"
}

summary() {
    step "Done"
    local ips
    ips=$(lan_ipv4s | tr '\n' ' ')
    cat <<EOF

  PNeX is up:        https://$PUBLIC_HOST/
  Admin login:       $ADMIN_EMAIL
EOF
    if ((GENERATED_PASSWORD)); then
        echo "  Admin password:    $ADMIN_PASSWORD   (generated — shown once, also in $PNEX_HOME/.env)"
    else
        echo "  Admin password:    the one you chose (stored in $PNEX_HOME/.env, root only)"
    fi
    echo "  Rauthy admin UI:   https://$PUBLIC_HOST/auth/v1/admin (asks for a passkey/MFA)"
    if [[ $TLS_MODE == local ]]; then
        cat <<EOF

  This server uses its own certificate authority. Trust it once per device:
    - download:       https://$PUBLIC_HOST/api/v1/meta/ca  (also: pnexctl ca)
    - Ubuntu client:  curl -fsSL https://raw.githubusercontent.com/$REPO_SLUG/main/client/setup-ubuntu.sh | bash -s -- --server $PUBLIC_HOST
    - other systems:  pnexctl trust-help
  LAN addresses:      ${ips:-none found}
EOF
    else
        echo "  Certificates: Let's Encrypt (first issuance can take a minute: pnexctl logs certbot)"
    fi
    cat <<EOF

  Day-2:             pnexctl status | logs [svc] | upgrade [tag] | backup | uninstall
EOF
}

main() {
    parse_args "$@"
    if ((!DRY_RUN)) && [[ $EUID -ne 0 ]]; then
        die "run as root (curl ... | sudo bash -s -- ...)"
    fi
    PNEX_HOME=$(pick "$F_HOME" /opt/pnex)
    if ((DRY_RUN)) && [[ -z $F_HOME ]]; then
        PNEX_HOME=$(mktemp -d "${TMPDIR:-/tmp}/pnex-dry-run.XXXXXX")
        [[ -f /opt/pnex/.env ]] && cp /opt/pnex/.env "$PNEX_HOME/.env" 2>/dev/null || true
    fi
    install_base_tools
    load_env "$PNEX_HOME/.env"
    resolve_settings
    install_prerequisites
    install_docker
    fetch_recipe
    resolve_tag
    write_env
    render_state
    start_stack
    wait_healthy
    if ((!DRY_RUN)); then
        step "Rauthy"
        sync_oidc_client
        apply_branding
        install_pnexctl
        summary
    else
        step "Dry run finished"
        info "rendered files in $PNEX_HOME (inspect .env and state/), nothing else changed"
    fi
}

main "$@"
