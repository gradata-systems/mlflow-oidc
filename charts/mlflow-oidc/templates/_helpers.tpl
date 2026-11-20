{{/*
Non-secret plugin settings, as a dict of env var name -> value. Unset values
(empty string or null) are dropped so the plugin's defaults apply.
*/}}
{{- define "mlflow-oidc.configEnv" -}}
{{- $o := .Values.oidc }}
{{- $env := dict
  "OIDC_DISCOVERY_URL" $o.discoveryUrl
  "OIDC_CLIENT_ID" $o.clientId
  "OIDC_PUBLIC_CLIENT" $o.publicClient
  "OIDC_REDIRECT_URI" $o.redirectUri
  "OIDC_SCOPE" $o.scope
  "OIDC_PROVIDER_DISPLAY_NAME" $o.providerDisplayName
  "OIDC_AUDIENCE" $o.audience
  "OIDC_ISSUER" $o.issuer
  "OIDC_GROUPS_ATTRIBUTE" $o.groupsAttribute
  "OIDC_USERNAME_FIELD" $o.usernameField
  "OIDC_GROUP_NAME" $o.groupName
  "OIDC_ADMIN_GROUP_NAME" $o.adminGroupName
  "DEFAULT_MLFLOW_PERMISSION" $o.defaultPermission
  "AUTOMATIC_LOGIN_REDIRECT" $o.automaticLoginRedirect
  "TRUSTED_PROXIES" $o.trustedProxies
  "SESSION_COOKIE_SECURE" $o.sessionCookieSecure
}}
{{- if $o.cache.redisUrl }}
{{- $_ := set $env "CACHE_BACKEND" "redis" }}
{{- end }}
{{- include "mlflow-oidc.compact" (merge (dict) $o.extraEnv $env) }}
{{- end }}

{{/*
Secret plugin settings, as a dict of env var name -> value. SECRET_KEY is
taken from values, else from the existing Secret, else generated.
*/}}
{{- define "mlflow-oidc.secretEnv" -}}
{{- $o := .Values.oidc }}
{{- $secretKey := $o.secret.secretKey }}
{{- if not $secretKey }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $o.resourceName }}
{{- if and $existing (hasKey ($existing.data | default dict) "SECRET_KEY") }}
{{- $secretKey = index $existing.data "SECRET_KEY" | b64dec }}
{{- else }}
{{- $secretKey = randAlphaNum 64 }}
{{- end }}
{{- end }}
{{- $env := dict
  "OIDC_CLIENT_SECRET" $o.clientSecret
  "OIDC_USERS_DB_URI" $o.usersDbUri
  "CACHE_REDIS_URL" $o.cache.redisUrl
  "SECRET_KEY" $secretKey
}}
{{- include "mlflow-oidc.compact" (merge (dict) $o.secret.extraEnv $env) }}
{{- end }}

{{/*
Render a dict as YAML, dropping null and empty-string values and quoting the
rest, since ConfigMap and Secret values must be strings.
*/}}
{{- define "mlflow-oidc.compact" -}}
{{- range $k, $v := . }}
{{- if and (not (kindIs "invalid" $v)) (ne (toString $v) "") }}
{{ $k }}: {{ toString $v | quote }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mlflow-oidc.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Fail early on configuration the plugin would reject at runtime, or that
would leave the pod without its OIDC settings.
*/}}
{{- define "mlflow-oidc.validate" -}}
{{- $o := .Values.oidc }}
{{- if not $o.discoveryUrl }}
{{- fail "oidc.discoveryUrl is required" }}
{{- end }}
{{- if not $o.clientId }}
{{- fail "oidc.clientId is required" }}
{{- end }}
{{- if $o.secret.create }}
{{- if and (not $o.clientSecret) (not $o.publicClient) }}
{{- fail "oidc.clientSecret is required unless oidc.publicClient is true (or set oidc.secret.create=false and supply the Secret yourself)" }}
{{- end }}
{{- if not $o.usersDbUri }}
{{- fail "oidc.usersDbUri is required (or set oidc.secret.create=false and supply OIDC_USERS_DB_URI in your own Secret)" }}
{{- end }}
{{- end }}
{{- $replicas := ternary .Values.mlflow.autoscaling.maxReplicas .Values.mlflow.replicaCount .Values.mlflow.autoscaling.enabled }}
{{- if and (gt (int $replicas) 1) (hasPrefix "sqlite:" $o.usersDbUri) }}
{{- fail "oidc.usersDbUri cannot be SQLite with more than one replica; use a shared database" }}
{{- end }}
{{- $hasConfigMap := false }}
{{- $hasSecret := false }}
{{- range .Values.mlflow.envFrom }}
{{- if and .configMapRef (eq .configMapRef.name $o.resourceName) }}
{{- $hasConfigMap = true }}
{{- end }}
{{- if and .secretRef (eq .secretRef.name $o.resourceName) }}
{{- $hasSecret = true }}
{{- end }}
{{- end }}
{{- if not (and $hasConfigMap $hasSecret) }}
{{- fail (printf "mlflow.envFrom must contain a configMapRef and a secretRef named %q (oidc.resourceName), or the OIDC settings never reach the pod" $o.resourceName) }}
{{- end }}
{{- $appName := index .Values.mlflow.server.value_options "app_name" | default "" }}
{{- if ne $appName "oidc-auth" }}
{{- fail "mlflow.server.value_options.app_name must be oidc-auth, or the plugin is not loaded and MLflow runs without authentication" }}
{{- end }}
{{- end }}
