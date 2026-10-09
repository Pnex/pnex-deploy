# PNeX Helm chart

Deploys PNeX on Kubernetes: `pnex-server` (API, websockets, web UI, flow
runtime), `pnex-builder` (firmware builds, 360° stitching), Rauthy (OIDC),
OpenObserve, Valkey, RustFS and a PostgreSQL cluster managed by
[CloudNativePG](https://cloudnative-pg.io/).

## Requirements

- Kubernetes ≥ 1.27, a default StorageClass.
- The CloudNativePG operator.
- An ingress controller (`ingress-nginx` by default) for the web UI. TLS is
  terminated by the ingress (`ingress.tls`) or in front of the cluster
  (Cloudflare, a load balancer).
- A `LoadBalancer` Service provider (cloud LB, MetalLB, k3s ServiceLB) and
  a DNS name for the **device endpoint** (`deviceEdge.host`, default
  `devices.<publicHost>`), pointed at the external IP of
  `<release>-device-edge`. Devices authenticate with a client certificate
  (mTLS, D153), which an Ingress cannot forward: they connect to a
  dedicated nginx, never through the ingress or a CDN.
- By default the chart generates a private CA and a certificate for the
  device endpoint (Secret `<release>-device-edge-tls`, kept across
  upgrades): every firmware pins that CA. To use a public certificate
  instead, set `deviceEdge.tls.existingSecret` (a `kubernetes.io/tls`
  Secret, e.g. from cert-manager) and put its root CA in `deviceCa.pem`
  (default ISRG Root X1). One root only on ESP8266 (2047 bytes of PEM), two
  on ESP32 (4095); a bigger CA fails the build with `build_ca_too_large`.
- A CNI that enforces NetworkPolicies (Calico, Cilium...) for
  `networkPolicy.enabled` to have any effect.

## Install

```bash
helm upgrade --install pnex ./pnex -n pnex --create-namespace \
  --set publicHost=pnex.example.com --set admin.email=admin@example.com
```

Every secret left empty in `values.yaml` is generated in-cluster on first
install and kept afterwards (the Secret carries
`helm.sh/resource-policy: keep`, upgrades never rotate it). To manage them
yourself, keep them in an encrypted values file (sops) or point
`secrets.existingSecret` at a Secret with the same keys as
`templates/secrets.yaml`.

**Back up `secrets-keys`** with the database backups: it is the keyring of
the organisations' secrets vault (notification tokens, HTTP credentials,
Wi-Fi passwords, LLM keys). `pnex-server` refuses to start without it, and
a database restored without it holds unreadable secrets.

## Security defaults

- Pods run as non-root with no privilege escalation, all capabilities
  dropped (PNeX, Rauthy, Valkey), RuntimeDefault seccomp, and no service
  account token.
- Valkey requires a password; Valkey, OpenObserve and RustFS accept
  connections from PNeX pods only (NetworkPolicy).
- Rate limiting of unauthenticated routes is on. Behind a CDN, add its IP
  ranges to `api.rateLimit.trustedProxies` so the limit applies per client.
- Sign-in is authorization code + PKCE only (no password grant).
- The custom firmware IDE is off (`customFirmware.enabled`).
- Devices reach the API only through the device endpoint: TLS 1.2+, their
  token in the `Authorization` header, a client certificate issued by
  their organisation's CA. The endpoint adds a shared secret
  (`secrets.edgeSecret`, generated) without which the API trusts no TLS or
  certificate header, so a pod reaching the API Service directly cannot
  impersonate it. Its access log is off.

## Scaling

`api.replicas > 1` is supported: pods form a flow execution cluster (each
organisation's flows run on exactly one pod, moved on failure or drain),
share Valkey and RustFS, and migrate the database once under an advisory
lock. Keep `replicas × (api.dbMaxConnections + 2)` below Postgres
`max_connections`. Rolling updates drain the old pod before it stops.

## Upgrading from 0.2.x

Breaking (device security, D153–D158): every device must be **rebuilt and
reflashed** after the upgrade; firmware built before is refused.

- New device endpoint (`deviceEdge`, on by default): create the DNS record
  of `deviceEdge.host` for the `<release>-device-edge` Service.
- With the generated certificate, firmware now pins the device endpoint's
  CA instead of `deviceCa.pem`.
- New secret key `edge-secret`: with `secrets.existingSecret`, add it
  (≥ 16 random characters).
- The `<release>-ws` Ingress now only carries browser websockets: device
  links arriving through it are refused.

## Upgrading from 0.2.0

- `deviceCa.pem` (new) is mounted into the API and the worker as
  `PNEX_CA_CERT_FILE`: chart 0.2.0 set none, so every wss firmware build
  failed with `build_no_ca`. Behind a CDN, set the root of its certificate
  (see [Requirements](#requirements)), then rebuild the devices.
- With server 0.1.0-beta.7 or later, `api.deploymentMode: self_hosted`
  applies no subscription tier (device quotas, build interval), even to
  organisations created while the install ran in `saas` mode.

## Upgrading from 0.1.x

- The API is now stateless: its `<release>-api-data` PVC is no longer used
  and is deleted by the upgrade (flows are rebuilt from the database).
- New generated secrets: `secrets-keys`, `flow-cluster-token`,
  `valkey-password`. With `secrets.existingSecret`, add them to your
  Secret **before** upgrading (`secrets-keys` = `k1:` followed by
  `openssl rand -base64 32`).
- Valkey restarts with a password and the `volatile-lru` eviction policy
  (it now holds device presence leases).
