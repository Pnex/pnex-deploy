# PNeX Helm chart

Deploys PNeX on Kubernetes: `pnex-server` (API, websockets, web UI, flow
runtime), `pnex-builder` (firmware builds, 360° stitching), Rauthy (OIDC),
OpenObserve, Valkey, RustFS and a PostgreSQL cluster managed by
[CloudNativePG](https://cloudnative-pg.io/).

## Requirements

- Kubernetes ≥ 1.27, a default StorageClass.
- The CloudNativePG operator.
- An ingress controller (`ingress-nginx` by default). TLS is terminated by
  the ingress (`ingress.tls`) or in front of the cluster (Cloudflare, a
  load balancer). Devices need a publicly trusted certificate: the chart
  runs in `cloud` edge mode (no private CA).
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

## Scaling

`api.replicas > 1` is supported: pods form a flow execution cluster (each
organisation's flows run on exactly one pod, moved on failure or drain),
share Valkey and RustFS, and migrate the database once under an advisory
lock. Keep `replicas × (api.dbMaxConnections + 2)` below Postgres
`max_connections`. Rolling updates drain the old pod before it stops.

## Upgrading from 0.1.x

- The API is now stateless: its `<release>-api-data` PVC is no longer used
  and is deleted by the upgrade (flows are rebuilt from the database).
- New generated secrets: `secrets-keys`, `flow-cluster-token`,
  `valkey-password`. With `secrets.existingSecret`, add them to your
  Secret **before** upgrading (`secrets-keys` = `k1:` followed by
  `openssl rand -base64 32`).
- Valkey restarts with a password and the `volatile-lru` eviction policy
  (it now holds device presence leases).
