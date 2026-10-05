{{/* Resource name prefix: the release name ("pnex" -> pnex-api, pnex-rauthy...). */}}
{{- define "pnex.fullname" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "pnex.labels" -}}
app.kubernetes.io/part-of: pnex
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector labels of one component: include "pnex.selector" (list . "api") */}}
{{- define "pnex.selector" -}}
{{- $ctx := index . 0 -}}
app.kubernetes.io/name: {{ index . 1 }}
app.kubernetes.io/instance: {{ $ctx.Release.Name }}
{{- end -}}

{{- define "pnex.secretName" -}}
{{- .Values.secrets.existingSecret | default (printf "%s-secrets" (include "pnex.fullname" .)) -}}
{{- end -}}

{{- define "pnex.pgCluster" -}}
{{- printf "%s-pg" (include "pnex.fullname" .) -}}
{{- end -}}

{{- define "pnex.imageTag" -}}
{{- .Values.image.tag | default .Chart.AppVersion -}}
{{- end -}}

{{- define "pnex.platformAdmins" -}}
{{- $admins := list .Values.admin.email -}}
{{- if .Values.admin.extraPlatformAdmins }}{{ $admins = append $admins .Values.admin.extraPlatformAdmins }}{{ end -}}
{{- join "," (compact $admins) -}}
{{- end -}}

{{- define "pnex.registration" -}}
{{- if eq (toString .Values.rauthy.registration) "" -}}
{{- .Values.smtp.enabled -}}
{{- else -}}
{{- .Values.rauthy.registration -}}
{{- end -}}
{{- end -}}

{{/* Environment shared by pnex-server (API) and pnex-builder (worker). */}}
{{- define "pnex.appEnv" -}}
{{- $secret := include "pnex.secretName" . -}}
{{- $fullname := include "pnex.fullname" . -}}
- name: RUST_LOG
  value: {{ .Values.logLevel | quote }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "pnex.pgCluster" . }}-app
      key: uri
- name: RAUTHY_URL
  value: http://{{ $fullname }}-rauthy:8080
- name: RAUTHY_ISSUER_URL
  value: https://{{ .Values.publicHost }}
{{- if .Values.api.lockServerHost }}
- name: PNEX_PROD_HOST
  value: {{ .Values.publicHost | quote }}
{{- end }}
- name: OPENOBSERVE_URL
  value: http://{{ $fullname }}-openobserve:5080
- name: OPENOBSERVE_ROOT_EMAIL
  value: {{ .Values.openobserve.rootEmail | quote }}
- name: OPENOBSERVE_ROOT_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: o2-root-password }
- name: VALKEY_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: valkey-password }
- name: VALKEY_URL
  value: redis://:$(VALKEY_PASSWORD)@{{ $fullname }}-valkey:6379
- name: PNEX_NOTIFY_INTERNAL_TOKEN
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: notify-internal-token }
- name: PNEX_FLOW_RUNTIME_TOKEN
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: flow-runtime-token }
# Org secrets vault keyring (`k1:<base64>`): the server refuses to start
# without it, and losing it makes every org secret unreadable.
- name: PNEX_SECRETS_KEYS
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: secrets-keys }
# Rate limiting of unauthenticated routes. The client IP is read from
# X-Forwarded-For only behind a trusted proxy (empty = private ranges,
# which covers the ingress controller).
- name: PNEX_RATE_LIMIT
  value: {{ ternary "on" "off" .Values.api.rateLimit.enabled | quote }}
{{- with .Values.api.rateLimit.trustedProxies }}
- name: PNEX_TRUSTED_PROXIES
  value: {{ . | quote }}
{{- end }}
# Custom firmware IDE (user C++ compiled by the worker): off by default.
- name: PNEX_FIRMWARE_CUSTOM_ENABLED
  value: {{ .Values.customFirmware.enabled | quote }}
- name: PNEX_FIRMWARE_SANDBOX
  value: {{ .Values.customFirmware.sandbox | quote }}
# Firmware artefacts and media both live in RustFS.
- name: STORAGE_BACKEND
  value: s3
- name: MEDIA_BACKEND
  value: s3
- name: PNEX_S3_ENDPOINT
  value: http://{{ $fullname }}-rustfs:9000
- name: PNEX_S3_BUCKET
  value: {{ .Values.rustfs.bucket | quote }}
- name: PNEX_S3_REGION
  value: {{ .Values.rustfs.region | quote }}
- name: PNEX_S3_PATH_STYLE
  value: "true"
- name: PNEX_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: rustfs-access-key }
- name: PNEX_S3_SECRET_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: rustfs-secret-key }
- name: PNEX_PLATFORM_ADMIN_EMAILS
  value: {{ include "pnex.platformAdmins" . | quote }}
- name: PNEX_DEPLOYMENT_MODE
  value: {{ .Values.api.deploymentMode | quote }}
- name: PNEX_DEFAULT_RETENTION_DAYS
  value: {{ .Values.api.defaultRetentionDays | quote }}
# TLS is terminated by a publicly trusted edge: no private CA to pin or
# to serve on /api/v1/meta/ca.
- name: PNEX_EDGE_MODE
  value: cloud
- name: DB_MAX_CONNECTIONS
  value: {{ .Values.api.dbMaxConnections | quote }}
- name: PNEX_STITCH_MAX_CONCURRENT
  value: {{ .Values.worker.stitchMaxConcurrent | quote }}
- name: PNEX_STITCH_OUT_WIDTH
  value: {{ .Values.worker.stitchOutWidth | quote }}
{{- end -}}

{{- define "pnex.persistence" -}}
accessModes: ["ReadWriteOnce"]
{{- with .storageClass }}
storageClassName: {{ . }}
{{- end }}
resources:
  requests:
    storage: {{ .size }}
{{- end -}}

{{/* Pod-level hardening shared by every workload. */}}
{{- define "pnex.podSecurity" -}}
automountServiceAccountToken: false
{{- end -}}

{{/* Container hardening for images that run as a non-root user. */}}
{{- define "pnex.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{/* Ingress annotations shared by the main and the websocket Ingress. */}}
{{- define "pnex.ingressAnnotations" -}}
{{- if not .Values.ingress.tls }}
# TLS terminated upstream (Cloudflare...): no http -> https redirect loop.
nginx.ingress.kubernetes.io/ssl-redirect: "false"
{{- end }}
# Media uploads (360 captures, firmware artefacts): the API enforces its
# own limits.
nginx.ingress.kubernetes.io/proxy-body-size: 1g
# Device + UI websockets and Rauthy SSE: long-lived, idle between frames.
nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
nginx.ingress.kubernetes.io/proxy-buffering: "off"
{{- with .Values.ingress.annotations }}
{{ toYaml . }}
{{- end }}
{{- end }}
