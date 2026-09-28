# PNeX — production install

One command installs a complete, TLS-everywhere PNeX server on a Raspberry Pi
(4 or 5, 64-bit OS) or on any Debian / Ubuntu machine (amd64 or arm64):

```bash
curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/install.sh \
  | sudo bash -s -- --admin-user admin@acme.io --admin-password 'choose-a-strong-one'
```

Then open `https://<hostname>.local/` and trust the server's certificate
authority once per device (see [Trusting the local CA](#trusting-the-local-ca)).

Everything else is optional. A fuller example:

```bash
curl -fsSL https://raw.githubusercontent.com/Pnex/pnex-deploy/main/install.sh \
  | sudo bash -s -- --profile=raspi --storage=fs \
      --admin-user admin@acme.io --admin-password 'xxxx'
```

## Requirements

| | Minimum | Recommended |
|---|---|---|
| Board / CPU | Raspberry Pi 4 (4 GB), any amd64/arm64 | Raspberry Pi 5 (8 GB) or a small x86 box |
| OS | Raspberry Pi OS Lite 64-bit (bookworm/trixie), Debian 12/13, Ubuntu 22.04+ | Debian 13 / Pi OS trixie |
| Disk | 16 GB free | an **SSD** (USB 3 or NVMe) rather than the SD card |
| Network | LAN with mDNS, or a DNS name | a DHCP reservation for the server |

32-bit Raspberry Pi OS is **not** supported (images are `linux/amd64` and
`linux/arm64` only). Docker Engine and the compose plugin are installed
automatically when missing.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--admin-user EMAIL` | *(prompted)* | Admin account: Rauthy administrator + PNeX platform admin. Required on first install. |
| `--admin-password PASS` | *(prompted / generated)* | Used only when the identity provider initialises. Generated and printed once in `--non-interactive` mode. |
| `--domain NAME` | `<hostname>.local` | Public name. `.local` is announced by mDNS (avahi is installed). A DNS name or an IP address also works. |
| `--tls local\|cloud` | `local` | `local`: a private CA generated on the server. `cloud`: Let's Encrypt (needs a public DNS name and ports 80/443 open to the internet). |
| `--acme-email EMAIL` | | Let's Encrypt account (cloud mode). `--acme-staging` for tests. |
| `--profile raspi\|server` | auto | `raspi`: memory-tuned (small Postgres buffers, capped OpenObserve caches, one stitching job). Auto = `raspi` on a Pi or below 6 GB RAM. |
| `--storage fs\|s3` | `fs` | `fs`: firmware artefacts in Postgres, media on a Docker volume. `s3`: adds RustFS (S3-compatible) for both. Chosen once. |
| `--smtp-url HOST`, `--smtp-port`, `--smtp-user`, `--smtp-password`, `--smtp-from` | | Optional outgoing mail. Without SMTP, self-registration and password-reset mails are disabled; the admin creates users in the Rauthy admin UI. |
| `--tag TAG` | `VERSION` file | Image tag of `pnex-server-rs` / `pnex-builder-rs`. |
| `--ref REF` (`--version REF`) | `main` | Git ref of this recipe (branch, tag or commit). |
| `--http-port`, `--https-port` | `80`, `443` | Published ports. Keep the defaults in production. |
| `--home DIR` | `/opt/pnex` | Install directory. |
| `--non-interactive`, `-y` | | Never prompt. |
| `--dry-run` | | Render the configuration into a temporary directory and validate it; changes nothing. |
| `--force` | | Allow a storage backend switch (no data migration!). |

Run `install.sh --help` for the complete list.

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
| valkey | `valkey/valkey:9-alpine` | Live last-value cache, no persistence (no disk writes). |
| rustfs (+ rustfs-init) | `rustfs/rustfs:1.0.0-rc.2`, `amazon/aws-cli` | `--storage s3` only. |
| certbot | `certbot/certbot:v4.2.0` | `--tls cloud` only. |

All containers restart automatically (`unless-stopped`) and their logs are
capped (3 × 10 MB each).

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
sudo pnexctl upgrade           # latest recipe + the image tag in its VERSION file
sudo pnexctl upgrade dirty-1a2b3c4   # a specific image tag
sudo pnexctl backup            # pg_dump + .env + CA into /var/backups/pnex/
sudo pnexctl backup --volumes  # also archive every data volume (brief downtime)
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
`PNEX_DEFAULT_RETENTION_DAYS='90'`, `PNEX_DEFAULT_ORG_TIER='Pro'`). Apply with
`sudo pnexctl start`.

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
  a router DNS name (`--domain pnex.home`) or the IP address
  (`--domain 192.168.1.20`; passkeys are then unavailable, passwords work).
  Re-run the installer with the new `--domain`; devices flashed for the old
  name must be re-flashed.
- **Certificate warning** — the CA is not trusted on that device yet (see
  above), or you browse by a name that is not in the certificate (the
  certificate covers the domain, `<hostname>.local`, `localhost` and every LAN
  IP of the server at install time; re-run the installer after an IP change).
- **SD card wear** — PNeX limits writes (no Valkey persistence, capped logs,
  fewer Postgres checkpoints), but telemetry is written continuously. Prefer
  booting the Pi from an SSD; at least use a high-endurance card and take
  regular `pnexctl backup`s.
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
VERSION                 default image tag for this recipe
config/nginx/           TLS edge template + certificate hot-reload hook
config/pki/             local CA / certificate issuance (one-shot container)
config/certbot/         Let's Encrypt loop (cloud mode)
config/rauthy/          identity provider config + bootstrap templates, branding
scripts/pnexctl         day-2 helper
client/setup-ubuntu.sh  client laptop setup (USB serial + CA trust)
tests/                  compose validation used by CI
helm/                   Kubernetes chart (coming later)
```

Development and testing happen in the main PNeX repository, which contains a
QEMU/cloud-init virtual-machine harness (`deploy/vm/`) that simulates a
Raspberry Pi and runs this installer from a local checkout before anything is
pushed here.

## License

MIT — see [LICENSE](LICENSE).
