# PNeX — production install

Pick the installation that matches your hardware:

| | Target | How |
|---|---|---|
| 🍓 | [Raspberry Pi](#raspberry-pi) (4 or 5, 64-bit OS) | one-line installer, `raspi` profile |
| 🖥️ | [Linux server or VM](#linux-server-or-vm) (Debian / Ubuntu, amd64 or arm64) | one-line installer |
| 🪟 | [Windows (WSL 2)](#windows-wsl-2) | the same installer inside WSL 2 |
| ☸️ | [Kubernetes](#kubernetes-helm) | Helm chart (`helm/pnex`) |
| ☁️ | Cloud providers (Terraform + Ansible) | coming soon |

Every Docker install is TLS everywhere. Without a domain name, PNeX still
gets a real host name and HTTPS: see [Names and TLS](#names-and-tls).

### Raspberry Pi

```bash
curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/install.sh \
  | sudo bash -s -- --admin-user admin@acme.io --admin-password 'choose-a-strong-one'
```

Then open `https://<hostname>.local/` (name the Pi `pnex` and it is
`https://pnex.local/`) and trust the server's certificate authority once per
device (see [Trusting the local CA](#trusting-the-local-ca)). The `raspi`
profile (small Postgres buffers, capped OpenObserve caches, one stitching
job) is picked automatically. Prefer an SSD to the SD card.

### Linux server or VM

The same command on Debian 12/13 or Ubuntu 22.04+ (bare metal, Proxmox,
VirtualBox, any cloud VM). Docker Engine and the compose plugin are
installed when missing.

On a public VM **without a domain name**, a [sslip.io name](#names-and-tls)
built from the VM's public IP gets a Let's Encrypt certificate (ports 80 and
443 open to the internet; `--ip` is needed when the VM only sees a private
address behind the provider's NAT):

```bash
curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/install.sh \
  | sudo bash -s -- --domain sslip --ip 203.0.113.7 --tls cloud \
      --acme-email ops@example.com --admin-user admin@example.com
```

With your own DNS record:

```bash
curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/install.sh \
  | sudo bash -s -- --domain pnex.example.com --tls cloud --acme-email ops@example.com \
      --admin-user admin@example.com
```

On a LAN, the default `<hostname>.local` name and the local CA apply, as on
a Raspberry Pi.

### Windows (WSL 2)

PNeX runs in a WSL 2 Ubuntu distribution, with Docker Engine inside WSL
(installed by the script) or Docker Desktop's WSL integration. Windows 11
22H2 or later is needed for **mirrored networking**, which lets devices on
the LAN reach the server.

1. In PowerShell (admin): `wsl --install -d Ubuntu`.
2. Create `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   networkingMode=mirrored
   ```

3. Inside Ubuntu, enable systemd (skip with Docker Desktop): add
   `[boot]` / `systemd=true` to `/etc/wsl.conf`.
4. In PowerShell (admin), restart WSL and open the ports to the LAN:

   ```powershell
   wsl --shutdown
   Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
   New-NetFirewallRule -DisplayName "PNeX HTTPS" -Direction Inbound -Protocol TCP -LocalPort 80,443 -Action Allow
   ```

5. Inside Ubuntu, run the installer. On WSL it defaults to a sslip.io name
   (`https://pnex-<lan-ip-with-dashes>.sslip.io`): mDNS does not cross WSL.

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/install.sh \
     | sudo bash -s -- --admin-user admin@acme.io
   ```

Keep the PC awake while devices are connected; a Raspberry Pi or a small
Linux box suits a permanent installation better.

### Kubernetes (Helm)

```bash
helm upgrade --install pnex ./helm/pnex -n pnex --create-namespace \
  --set publicHost=pnex.example.com --set admin.email=admin@example.com
```

Requires CloudNativePG and an ingress controller; TLS is terminated by the
ingress or in front of the cluster. Secrets are generated in-cluster.
Details, scaling and upgrades: [helm/README.md](helm/README.md).

## Requirements

| | Minimum | Recommended |
|---|---|---|
| Board / CPU | Raspberry Pi 4 (4 GB), any amd64/arm64 | Raspberry Pi 5 (8 GB) or a small x86 box |
| OS | Raspberry Pi OS Lite 64-bit (bookworm/trixie), Debian 12/13, Ubuntu 22.04+ | Debian 13 / Pi OS trixie |
| Disk | 16 GB free (the firmware builder image alone is ~8 GB; the installer refuses to start below that, `--force` to override) | 30 GB+, an **SSD** (USB 3 or NVMe) rather than the SD card |
| Network | LAN with mDNS, a DNS name, or a public IP (sslip.io) | a DHCP reservation for the server |

32-bit Raspberry Pi OS is **not** supported (images are `linux/amd64` and
`linux/arm64` only). Docker Engine and the compose plugin are installed
automatically when missing.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--admin-user EMAIL` | *(prompted)* | Admin account: Rauthy administrator + PNeX platform admin. Required on first install. |
| `--admin-password PASS` | *(prompted / generated)* | Used only when the identity provider initialises. Generated and printed once in `--non-interactive` mode. |
| `--domain NAME` | `<hostname>.local` (`sslip` on WSL) | Public name. `.local` is announced by mDNS (avahi is installed). `sslip` / `nip` build a wildcard-DNS name from the server IP. A DNS name or an IP address also works. See [Names and TLS](#names-and-tls). |
| `--ip ADDR` | default-route IPv4 | Address embedded in a `sslip` / `nip` name (e.g. the public IP of a VM behind NAT). |
| `--tls local\|cloud` | `local` | `local`: a private CA generated on the server. `cloud`: Let's Encrypt (needs a public DNS name and ports 80/443 open to the internet). |
| `--acme-email EMAIL` | | Let's Encrypt account (cloud mode). `--acme-staging` for tests. |
| `--profile raspi\|server` | auto | `raspi`: memory-tuned (small Postgres buffers, capped OpenObserve caches, one stitching job). Auto = `raspi` on a Pi or below 6 GB RAM. |
| `--storage fs\|s3` | `fs` | `fs`: firmware artefacts in Postgres, media on a Docker volume. `s3`: adds RustFS (S3-compatible) for both. Chosen once. |
| `--smtp-url HOST`, `--smtp-port`, `--smtp-user`, `--smtp-password`, `--smtp-from` | | Optional outgoing mail. Without SMTP, self-registration and password-reset mails are disabled; the admin creates users in the Rauthy admin UI. |
| `--tag TAG` | `VERSION` file (`latest`) | Image tag of `pnex-server-rs` / `pnex-builder-rs`. `latest` follows the last green `main`; pin `main-<sha>` for reproducible installs. |
| `--version VERSION` | `latest` | Release to install. `latest`: recipe of `main`, images following the last green `main`. A release such as `0.1.0-beta.1`: recipe tag `v0.1.0-beta.1`, images pinned to `0.1.0-beta.1`. Kept for upgrades (`pnexctl upgrade --version …` to move). |
| `--ref REF` | `main` | Git ref of this recipe (branch, tag or commit); overrides `--version`. |
| `--http-port`, `--https-port` | `80`, `443` | Published ports. Keep the defaults in production. |
| `--home DIR` | `/opt/pnex` | Install directory. |
| `--non-interactive`, `-y` | | Never prompt. |
| `--dry-run` | | Render the configuration into a temporary directory and validate it; changes nothing. |
| `--force` | | Allow a storage backend switch (no data migration!), or an install below the disk space minimum. |

Run `install.sh --help` for the complete list.

## Names and TLS

Devices, browsers and passkeys need a **host name** that resolves to the
server, and the certificate must carry it. Four ways to get one:

| `--domain` | Name | Resolution | TLS | When |
|---|---|---|---|---|
| *(default)* | `<hostname>.local` | mDNS on the LAN (avahi) | local CA | Raspberry Pi / Linux on a home or lab LAN |
| `sslip` or `nip` | `pnex-203-0-113-7.sslip.io` | public wildcard DNS, answers with the IP embedded in the name | Let's Encrypt (`--tls cloud`) | **public VM without a domain name**: a trusted certificate with no DNS to manage |
| `pnex.example.com` | your DNS record | your DNS | Let's Encrypt (`--tls cloud`) or local CA | production, public access |
| `192.168.1.20` | bare IP | none | local CA | last resort: passkeys unavailable (WebAuthn refuses IPs) |

[sslip.io](https://sslip.io) and [nip.io](https://nip.io) are free services:
`pnex-203-0-113-7.sslip.io` resolves to `203.0.113.7`. Their point is
**Let's Encrypt without DNS**: give a public VM such a name and it gets a
certificate every browser, app and device already trusts — no CA to import.
The dashed form keeps the name a single label, which certificates handle
best.

With a **private** IP they still work, with the local CA: the only gain
over a bare IP is a real host name where mDNS fails (WSL, Android < 12,
DNS-over-HTTPS browsers, VLANs), which keeps passkeys usable. That is why
the installer uses `sslip` by default on WSL. Limits to know:

- clients and devices need internet DNS (a fully offline LAN needs mDNS or
  your own DNS);
- some routers block public names that resolve to private addresses (DNS
  rebinding protection): allow-list `sslip.io` / `nip.io`, or use another
  resolver;
- the name embeds the IP: give the server a DHCP reservation. After an IP
  change, re-run the installer with the new `--domain sslip` and re-flash
  the devices;
- to avoid depending on a third party, delegate a subdomain of your own
  zone to a self-hosted sslip.io DNS server, or create a wildcard record
  (`*.lab.example.com`) pointing at the server.

## What gets installed

`/opt/pnex/` holds this recipe, the generated `.env` (all secrets, mode 600,
generated once and never regenerated), `state/` (Rauthy config, local CA and
certificates) and Docker volumes for the data. `pnexctl` goes to
`/usr/local/bin`.

| Service | Image | Role |
|---|---|---|
| nginx | `nginx:1.29-alpine` | The only public entry point: TLS for browsers, apps and devices (ESP8266-compatible TLS fragment sizes). |
| pki | `alpine:3.22` | One-shot: local root CA (10 years, created once) + server certificate (renewed automatically). |
| pnex-server | `shanisma/pnex-server-rs` | API, websockets, web UI, flow runtime. Migrates the database at start. |
| pnex-builder | `shanisma/pnex-builder-rs` | Job worker: firmware builds (PlatformIO) and 360° stitching. |
| rauthy | `ghcr.io/sebadob/rauthy:0.36.2` | OpenID Connect identity provider (`/auth/v1/`). |
| postgres | `postgres:18-alpine` | Main database. |
| openobserve | `openobserve/openobserve:v1.0.0` | Telemetry storage. |
| valkey | `valkey/valkey:9-alpine` | Device presence leases (anti-clone), device command bus, live last-value cache. No persistence (no disk writes). |
| rustfs (+ rustfs-init) | `rustfs/rustfs:1.0.0-rc.2`, `amazon/aws-cli` | `--storage s3` only. |
| certbot | `certbot/certbot:v4.2.0` | `--tls cloud` only. |

All containers restart automatically (`unless-stopped`). See
[Logs](#logs) for how logging is kept small.

**Rate limiting.** Unauthenticated and sensitive routes (OAuth bridge,
edge-agent enrolment, device and camera websockets, public tours) are rate
limited per client IP (HTTP 429 + `Retry-After`). The client IP is taken
from `X-Forwarded-For` only when the request comes from nginx on the
internal network (`PNEX_TRUSTED_PROXIES`, default: the Docker subnet).
`PNEX_RATE_LIMIT=off` disables it.

**No usage limits.** A self-hosted install has no subscription tiers: no
cap on devices, firmware builds or telemetry volume. Sign-in goes through
the browser login page only (authorization code + PKCE); the OIDC client
does not accept the password grant.

### Ports

| Port | Exposed to | Purpose |
|---|---|---|
| 443/tcp | LAN / internet | Everything: web UI, API, device websockets (`/ws/`), identity provider (`/auth/v1/`) |
| 80/tcp | LAN / internet | Redirect to HTTPS, Let's Encrypt challenges |
| 5353/udp | LAN | mDNS (avahi) for `<hostname>.local` |

Postgres, OpenObserve, Valkey, Rauthy and RustFS are **not** published: they
are only reachable on the internal Docker network.

## Day-2 operations: `pnexctl`

```bash
sudo pnexctl status            # containers, versions, endpoint health, certificate expiry
sudo pnexctl logs pnex-server -f
sudo pnexctl upgrade           # latest recipe + re-pull the VERSION tag (`latest`)
sudo pnexctl upgrade main-1a2b3c4    # pin an immutable image tag
sudo pnexctl backup            # pg_dump + .env + CA into /var/backups/pnex/
sudo pnexctl backup --volumes  # also archive every data volume (brief downtime)
sudo pnexctl log-level info    # more verbose logs while diagnosing (default: error)
pnexctl ca cat                 # print the local root CA
pnexctl trust-help             # how to trust it on Windows/macOS/Android/iOS/Linux
sudo pnexctl uninstall         # remove containers, keep data
sudo pnexctl uninstall --purge # remove EVERYTHING (data, CA, /opt/pnex)
```

**Upgrading** is simply re-running the installer (or `pnexctl upgrade`): it
fetches the recipe, keeps `.env` secrets, pulls the new images and recreates
what changed. Database migrations run when `pnex-server` starts.

**Customising**: lines added at the end of `/opt/pnex/.env`, below the
`user overrides` marker, survive re-runs (e.g. `O2_MEM_LIMIT='2g'`,
`PNEX_DEFAULT_RETENTION_DAYS='90'`). Apply with
`sudo pnexctl start`.

### Logs

Logging is kept small on purpose, to limit SD card wear:

- **Errors only by default.** PNeX (server, flow runtime, worker), Rauthy,
  OpenObserve and RustFS run at `error`. Postgres logs errors only (no
  checkpoint or autovacuum messages), Valkey logs warnings, and nginx logs
  errors with no access log.
- **Diagnosing:** `sudo pnexctl log-level info` (or `debug`) raises the level
  for PNeX, Rauthy, OpenObserve and RustFS and recreates those containers.
  Go back with `sudo pnexctl log-level error`. The setting survives upgrades.
- **Bounded size.** Docker's `local` driver compresses rotated files. The cap
  is **per container**: 20 MB × 3 files on `raspi`, 50 MB × 5 on `server`
  (`LOG_MAX_SIZE` / `LOG_MAX_FILE` overrides in `.env`). The same limits are
  set as Docker's defaults in `/etc/docker/daemon.json` (merged, never
  overwritten; an existing `log-driver` is left alone).
- **System journal.** On `raspi`, journald is capped at 100 MB
  (`/etc/systemd/journald.conf.d/pnex.conf`).

### Secrets vault key

Organisation secrets (notification channel tokens, HTTP node credentials,
Wi-Fi passwords, LLM keys) are encrypted in Postgres with a key ring that
lives **outside** the database: `PNEX_SECRETS_KEYS` in `/opt/pnex/.env`,
generated once by the installer (`pnex-server` refuses to start without
it). A database dump alone reveals no secret, but a database restored
without its key ring is unreadable: `pnexctl backup` saves `.env` with the
dump, keep both.

Rotation: generate a key (`openssl rand -base64 32`), put it **first** in
the user overrides of `.env`, keeping the old one after it
(`PNEX_SECRETS_KEYS='k2:<new>,k1:<old>'`), `sudo pnexctl start`, then run
the re-encryption from the platform status page in the web UI. Remove the
old key once the page reports no secret left under it.

**Backups**: `config.tar.gz` contains the local CA **private key** — firmware
flashed on your devices pins that CA, so losing it means re-flashing every
device. Keep backups off the Pi.

## Trusting the local CA

In `--tls local` mode the server has its own certificate authority. Import it
once per client device (the PNeX web UI also shows it under Profile → About,
with its SHA-256 fingerprint and a QR code).

- **Ubuntu / Debian desktop** — also prepares USB flashing (see below):

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/client/setup-ubuntu.sh \
    | bash -s -- --server pnex.local
  ```

- **Windows**: download `https://<server>/api/v1/meta/ca`, double-click
  `pnex-ca.crt` → Install Certificate → Local Machine → *Trusted Root
  Certification Authorities*.
- **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain pnex-ca.crt`
- **Android**: Settings → Security → Encryption & credentials → Install a
  certificate → CA certificate. The PNeX app also offers to pin the CA on first
  connection (fingerprint shown).
- **iOS**: open the `.crt` in Safari, install the profile, then enable it in
  Settings → General → About → Certificate Trust Settings.

## Flashing devices from the browser (USB)

Firmware is flashed with Web Serial: use **Chrome, Chromium or Edge** (Firefox
has no Web Serial). On Ubuntu run `client/setup-ubuntu.sh` once (above); it:

1. adds you to the `dialout` group (log out and back in afterwards);
2. removes `brltty`, which hijacks CH340/CH341 adapters on Ubuntu 22.04+;
3. makes ModemManager ignore ESP USB-serial chips (CP210x, CH340, FTDI,
   Espressif native USB) via a udev rule;
4. connects the Chromium snap's `raw-usb` interface when relevant;
5. trusts the server CA (system store, Chrome NSS database, Firefox profiles).

## Troubleshooting

- **The serial port appears then disappears / flashing fails at "connecting"**
  — `brltty` or ModemManager grabbed the adapter: run `client/setup-ubuntu.sh`,
  unplug and replug the board.
- **"Permission denied" on /dev/ttyUSB0** — you are not in `dialout` yet, or
  did not log out and back in.
- **`<hostname>.local` does not resolve** — Android (before 12) and some
  browsers with DNS-over-HTTPS ignore mDNS. Use a DHCP reservation and either
  a router DNS name
  (`--domain pnex.home`) or the IP address (`--domain 192.168.1.20`; passkeys
  are then unavailable, passwords work).
- **A sslip.io / nip.io name does not resolve on the LAN** — the router's
  DNS rebinding protection drops answers pointing at private addresses:
  allow-list the domain in the router, or use another DNS resolver.
  Re-run the installer with the new `--domain`; devices flashed for the old
  name must be re-flashed.
- **Certificate warning** — the CA is not trusted on that device yet (see
  above), or you browse by a name that is not in the certificate (the
  certificate covers the domain, `<hostname>.local`, `localhost` and every LAN
  IP of the server at install time; re-run the installer after an IP change).
- **SD card wear** — PNeX limits writes (no Valkey persistence, error-only
  and capped logs, fewer Postgres checkpoints), but the database and the
  telemetry are written continuously: these, not the logs, wear the card.
  The installer warns when Docker's data sits on the SD card. Prefer booting
  the Pi from a USB SSD. At the very least, use a high-endurance card and
  take regular `pnexctl backup`s.
- **A container crash-loops on a Raspberry Pi 5 with "Unsupported system page
  size"** — the Pi 5 kernel uses 16 KB pages; add `kernel=kernel8.img` to
  `/boot/firmware/config.txt` and reboot.
- **Image pull fails** — check the tag exists for your architecture:
  `docker manifest inspect docker.io/shanisma/pnex-server-rs:<tag>`.
- **Logs** — `sudo pnexctl logs nginx rauthy pnex-server`.

## Repository layout

```
install.sh              the installer (self-contained: fetches the rest when piped)
compose.yaml            the production stack (profiles: s3, cloud)
VERSION                 default image tag for this recipe (`latest` = last green main)
config/nginx/           TLS edge template + certificate hot-reload hook
config/pki/             local CA / certificate issuance (one-shot container)
config/certbot/         Let's Encrypt loop (cloud mode)
config/rauthy/          identity provider config + bootstrap templates, branding
scripts/pnexctl         day-2 helper
client/setup-ubuntu.sh  client laptop setup (USB serial + CA trust)
tests/                  compose validation used by CI
helm/pnex/              Kubernetes chart (see helm/README.md)
```

Development and testing happen in the main PNeX repository, which contains a
QEMU/cloud-init virtual-machine harness (`deploy/vm/`) that simulates a
Raspberry Pi and runs this installer from a local checkout before anything is
pushed here.

## License

MIT — see [LICENSE](LICENSE).
