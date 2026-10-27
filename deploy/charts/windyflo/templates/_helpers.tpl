{{/* Expand the name of the chart. */}}
{{- define "windyflo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name. */}}
{{- define "windyflo.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "windyflo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
appVersion — the application version REPORTED to users (app.kubernetes.io/version, NOTES.txt, and
GCP's publishedVersion fallback).

Chart.yaml's appVersion is a single shared default across every profile, but profiles ship DIFFERENT
application versions: the AWS paid listing runs 3.0.16 while the BYOL listings still run 3.0.14. A
frozen shared value therefore misreports the version for whichever profile moved, which is exactly
what the 2026-08-17 EKS validation found (pods labelled 3.0.14 while running 3.0.16-amd64).

Resolution order:
  1. .Values.appVersionOverride — explicit, per profile
  2. the image tag actually being deployed, minus any arch suffix (3.0.16-amd64 → 3.0.16), when it
     looks like a SemVer version rather than a branch name such as 'modu.windyflo'
  3. .Chart.AppVersion

Trailing "-amd64" is stripped because it is a registry packaging detail, not part of the application
version, and GCP requires publishedVersion to be strict SemVer.
*/}}
{{- define "windyflo.appVersion" -}}
{{- if .Values.appVersionOverride -}}
{{- .Values.appVersionOverride -}}
{{- else -}}
{{- $tag := (.Values.image.tag | default "" | toString) -}}
{{- $tag = regexReplaceAll "-(amd64|arm64)$" $tag "" -}}
{{- if regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+" $tag -}}
{{- $tag -}}
{{- else -}}
{{- .Chart.AppVersion -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "windyflo.labels" -}}
helm.sh/chart: {{ include "windyflo.chart" . }}
{{ include "windyflo.selectorLabels" . }}
app.kubernetes.io/version: {{ include "windyflo.appVersion" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "windyflo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "windyflo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "windyflo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "windyflo.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Resolve the image ref: digest wins over tag (air-gap/prod pin by digest). */}}
{{/* Azure Marketplace (cpa) requires image refs resolvable via global.azure.images.<key> — its
     publish tooling rewrites these to Microsoft's own ACR mirror. Only that profile sets this map;
     other profiles resolve the optional full ref first, then image.repository/tag/digest. */}}
{{- define "windyflo.image" -}}
{{- if .Values.global.azure.images.windyflo -}}
{{- $img := .Values.global.azure.images.windyflo -}}
{{- printf "%s/%s:%s" $img.registry $img.image $img.tag -}}
{{- else if .Values.image.full -}}
{{- .Values.image.full -}}
{{- else if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/* Same global.azure.images override, generalized for the data-layer images (postgres, pgbouncer,
     minio, minio-mc) — each takes the map key to look up and the plain image ref to fall back to. */}}
{{- define "windyflo.azureImage" -}}
{{- $img := index .root.Values.global.azure.images .key -}}
{{- if $img -}}
{{- printf "%s/%s:%s" $img.registry $img.image $img.tag -}}
{{- else -}}
{{- .fallback -}}
{{- end -}}
{{- end -}}

{{/* Names for the data-layer resources the app points at. */}}
{{- define "windyflo.secretName" -}}{{ include "windyflo.fullname" . }}-secret{{- end -}}
{{- define "windyflo.configName" -}}{{ include "windyflo.fullname" . }}-config{{- end -}}

{{/* Postgres host: PgBouncer Pooler (rw) when enabled, else the CNPG -rw service. */}}
{{- define "windyflo.pgHost" -}}
{{- if .Values.data.postgres.embedded -}}
{{- if .Values.data.postgres.pooler.enabled -}}
{{ .Values.data.postgres.name }}-pooler-rw
{{- else -}}
{{ .Values.data.postgres.name }}-rw
{{- end -}}
{{- else -}}
{{ .Values.config.DATABASE_HOST | default "" }}
{{- end -}}
{{- end -}}

{{/* Redis host: bitnami sentinel exposes <release>-redis (routes 6379 to master); plain
     replication exposes <release>-redis-master. External → config.REDIS_HOST. */}}
{{- define "windyflo.redisHost" -}}
{{- if .Values.data.redis.embedded -}}
{{- if .Values.data.plain -}}
{{ .Release.Name }}-redis
{{- else if .Values.redis.sentinel.enabled -}}
{{ .Release.Name }}-redis
{{- else -}}
{{ .Release.Name }}-redis-master
{{- end -}}
{{- else -}}
{{ .Values.config.REDIS_HOST | default "" }}
{{- end -}}
{{- end -}}

{{/* MinIO endpoint (in-cluster headless service) when embedded. */}}
{{- define "windyflo.s3Endpoint" -}}
{{- if .Values.data.minio.embedded -}}
http://{{ .Values.data.minio.name }}-hl.{{ .Release.Namespace }}.svc:9000
{{- else -}}
{{ .Values.config.S3_ENDPOINT_URL | default "" }}
{{- end -}}
{{- end -}}

{{/*
resolveSecret — pick a secret value in priority order: explicitly supplied → the value already in
the live cluster Secret (base64, decoded here) → a freshly generated value (only when auto=true) →
fail (only when required=true). Used by secret.yaml and minio-tenant.yaml so auto-generated secrets
are chosen the SAME way everywhere and stay stable across `helm upgrade`.
  args: dict "supplied" <str> "existing" <b64|nil> "gen" <str> "auto" <bool> "required" <bool> "name" <str>
*/}}
{{- define "windyflo.resolveSecret" -}}
  {{- $a := . -}}
  {{- if $a.supplied -}}
    {{- $a.supplied -}}
  {{- else if $a.existing -}}
    {{- $a.existing | b64dec -}}
  {{- else if $a.auto -}}
    {{- $a.gen -}}
  {{- else if $a.required -}}
    {{- fail (printf "secrets.%s is required (or set secrets.autoGenerate=true). Generate with: openssl rand -base64 24" $a.name) -}}
  {{- end -}}
{{- end -}}

{{/*
dbPassword — SINGLE source of truth for the Postgres OWNER password, so the CNPG Cluster owner-auth
Secret (data/cnpg-cluster.yaml) and the app Secret's DATABASE_PASSWORD (secret.yaml) ALWAYS agree.
Before this existed, cnpg-cluster.yaml read the raw .Values.secrets.DATABASE_PASSWORD while secret.yaml
resolved it through resolveSecret — so on the autoGenerate/marketplace path the CNPG role got an EMPTY
password while the app got a random one → permanent auth failure. Priority mirrors minioRootCreds/
redisPassword:
  1. explicit secrets.DATABASE_PASSWORD (prod/local supply it)
  2. value already in the live app Secret (survives `helm upgrade`)
  3. autoGenerate: DETERMINISTICALLY derived from the release name — identical in every template on a
     fresh install (randAlphaNum would differ per-template and reintroduce the mismatch this fixes).
  4. else fail closed (same message secret.yaml used).
*/}}
{{- define "windyflo.dbPassword" -}}
  {{- $sec := (lookup "v1" "Secret" .Release.Namespace (include "windyflo.secretName" .)) -}}
  {{- $existing := "" -}}
  {{- if and $sec $sec.data (get $sec.data "DATABASE_PASSWORD") -}}{{- $existing = (get $sec.data "DATABASE_PASSWORD" | b64dec) -}}{{- end -}}
  {{- if .Values.secrets.DATABASE_PASSWORD -}}{{- .Values.secrets.DATABASE_PASSWORD -}}
  {{- else if $existing -}}{{- $existing -}}
  {{- else if .Values.secrets.autoGenerate -}}{{- printf "%s-pg-owner" .Release.Name | sha256sum | trunc 24 -}}
  {{- else -}}{{- fail "secrets.DATABASE_PASSWORD is required (or set secrets.autoGenerate=true). Generate with: openssl rand -base64 24" -}}{{- end -}}
{{- end -}}

{{/*
minioRootCreds — SINGLE source of truth for the MinIO root credentials, so the tenant config
Secret, the bootstrap Job, and the app Secret all agree. Returns "user|password" (split by the
two thin wrappers below) so every call site does exactly ONE live `lookup` of the tenant -config
Secret instead of one each for user and password — that Secret was being fetched twice per file
(minio-tenant.yaml, minio-bootstrap-job.yaml, secret.yaml each called both helpers back to back).
Priority:
  1. explicit secrets.extra.MINIO_ROOT_* (real deployments)
  2. value already in the live tenant -config Secret (survives upgrades)
  3. autoGenerate: a value DETERMINISTICALLY derived from the release name — identical in every
     template on a fresh install (randAlphaNum would differ per-template and break the login).
  4. else the standalone-only minioadmin/minioadmin123 dev default.
*/}}
{{- define "windyflo.minioRootCreds" -}}
  {{- $cfg := (lookup "v1" "Secret" .Release.Namespace (printf "%s-config" .Values.data.minio.name)) -}}
  {{- $existingUser := "" -}}
  {{- $existingPass := "" -}}
  {{- if and $cfg $cfg.data (get $cfg.data "MINIO_ROOT_USER") -}}{{- $existingUser = (get $cfg.data "MINIO_ROOT_USER" | b64dec) -}}{{- end -}}
  {{- if and $cfg $cfg.data (get $cfg.data "MINIO_ROOT_PASSWORD") -}}{{- $existingPass = (get $cfg.data "MINIO_ROOT_PASSWORD" | b64dec) -}}{{- end -}}
  {{- $user := "" -}}
  {{- if .Values.secrets.extra.MINIO_ROOT_USER -}}{{- $user = .Values.secrets.extra.MINIO_ROOT_USER -}}
  {{- else if $existingUser -}}{{- $user = $existingUser -}}
  {{- else if .Values.secrets.autoGenerate -}}{{- $user = "windyflo-minio" -}}
  {{- else -}}{{- $user = "minioadmin" -}}{{- end -}}
  {{- $pass := "" -}}
  {{- if .Values.secrets.extra.MINIO_ROOT_PASSWORD -}}{{- $pass = .Values.secrets.extra.MINIO_ROOT_PASSWORD -}}
  {{- else if $existingPass -}}{{- $pass = $existingPass -}}
  {{- else if .Values.secrets.autoGenerate -}}{{- $pass = (printf "%s-minio-root" .Release.Name | sha256sum | trunc 32) -}}
  {{- else -}}{{- $pass = "minioadmin123" -}}{{- end -}}
  {{- printf "%s|%s" $user $pass -}}
{{- end -}}
{{- define "windyflo.minioRootUser" -}}
  {{- (include "windyflo.minioRootCreds" .) | splitList "|" | first -}}
{{- end -}}
{{- define "windyflo.minioRootPassword" -}}
  {{- (include "windyflo.minioRootCreds" .) | splitList "|" | last -}}
{{- end -}}

{{/*
redisPassword — SINGLE source of truth for the bitnami Redis subchart's auth password, so the
windyflo-redis-auth Secret (serviceaccount.yaml, read by the subchart via auth.existingSecret) and
the app Secret's copy of REDIS_PASSWORD always agree. Priority mirrors windyflo.minioRootPassword:
  1. explicit secrets.extra.REDIS_PASSWORD (real deployments)
  2. value already in the live windyflo-redis-auth Secret (survives upgrades)
  3. autoGenerate: a value DETERMINISTICALLY derived from the release name (same reasoning as MinIO —
     identical in every template on a fresh install).
  4. else the standalone-only windyflo-redis dev default.
*/}}
{{- define "windyflo.redisPassword" -}}
  {{- $cfg := (lookup "v1" "Secret" .Release.Namespace "windyflo-redis-auth") -}}
  {{- $existing := "" -}}
  {{- if and $cfg $cfg.data (get $cfg.data "redis-password") -}}{{- $existing = (get $cfg.data "redis-password" | b64dec) -}}{{- end -}}
  {{- if .Values.secrets.extra.REDIS_PASSWORD -}}{{- .Values.secrets.extra.REDIS_PASSWORD -}}
  {{- else if $existing -}}{{- $existing -}}
  {{- else if .Values.secrets.autoGenerate -}}{{- printf "%s-redis" .Release.Name | sha256sum | trunc 24 -}}
  {{- else -}}windyflo-redis{{- end -}}
{{- end -}}

{{/*
GCP Marketplace usage-reporting sidecar (ubbagent).

Rendered only when gcpMarketplace.ubbagent.enabled — i.e. the PAID GCP listing. GCP meters
buyer-deployed Kubernetes apps by having the app report usage to Google Service Control; the
documented way is to run Google's usage-based billing agent alongside the app. Credentials arrive as
a Marketplace-provisioned Secret (name passed via the deployer's REPORTING_SECRET parameter), NOT via
Workload Identity.

Note GCP provides no entitlement check — this reports usage so the seller gets paid; it cannot block
an unpaid deployment. See packages/server/src/license/gcp.ts.
*/}}
{{- define "windyflo.ubbagentContainer" -}}
{{- with .Values.gcpMarketplace.ubbagent -}}
- name: ubbagent
  image: {{ .image | quote }}
  imagePullPolicy: IfNotPresent
  env:
    - name: AGENT_CONFIG_FILE
      value: /etc/ubbagent/config.yaml
    # consumer-id identifies the billing account usage is reported against.
    - name: AGENT_REPORTING_CONSUMER_ID
      valueFrom:
        secretKeyRef:
          name: {{ .reportingSecretName | quote }}
          key: consumer-id
    # reporting-key is the GCP service-account JSON key. Documented gotcha: it is
    # double-base64-encoded — Kubernetes decodes once, the consumer must decode again.
    - name: AGENT_REPORTING_KEY
      valueFrom:
        secretKeyRef:
          name: {{ .reportingSecretName | quote }}
          key: reporting-key
  volumeMounts:
    - name: ubbagent-config
      mountPath: /etc/ubbagent
      readOnly: true
    # Also mounted so license/gcp.ts can confirm the reporting credentials exist.
    - name: gcp-marketplace-reporting
      mountPath: /etc/gcp-marketplace/reporting
      readOnly: true
  resources:
    {{- toYaml .resources | nindent 4 }}
{{- end }}
{{- end -}}

{{/*
Volumes backing the ubbagent sidecar. Paired with windyflo.ubbagentContainer.
*/}}
{{- define "windyflo.ubbagentVolumes" -}}
{{- with .Values.gcpMarketplace.ubbagent -}}
- name: ubbagent-config
  configMap:
    name: {{ include "windyflo.fullname" $ }}-ubbagent
- name: gcp-marketplace-reporting
  secret:
    secretName: {{ .reportingSecretName | quote }}
{{- end }}
{{- end -}}
