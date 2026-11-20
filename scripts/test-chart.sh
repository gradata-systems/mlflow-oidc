#!/usr/bin/env bash
# Lint and render-test the mlflow-oidc chart. Needs helm; fetches the upstream
# chart dependency on first run. Usage: scripts/test-chart.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/mlflow-oidc"
production=(-f "$root/examples/production/values.yaml" -f "$root/examples/production/secrets.example.yaml")
helm dependency build "$chart" > /dev/null

required=(
  --set oidc.discoveryUrl=https://idp.example.com/.well-known/openid-configuration
  --set oidc.clientId=mlflow
  --set oidc.clientSecret=client-secret
  --set oidc.usersDbUri=postgresql://user:pass@db/mlflow_auth
  --set mlflow.mlflow.backendStoreUri=postgresql://user:pass@db/mlflow
)

render() { helm template mlflow "$chart" "${required[@]}" "$@"; }

expect_contains() {
  local output=$1 pattern=$2
  if ! grep -qE -- "$pattern" <<< "$output"; then
    echo "FAIL: expected output to match: $pattern" >&2
    exit 1
  fi
}

expect_absent() {
  local output=$1 pattern=$2
  if grep -qE -- "$pattern" <<< "$output"; then
    echo "FAIL: expected output not to match: $pattern" >&2
    exit 1
  fi
}

# Print one kind of document from a multi-document render.
document() {
  awk -v kind="kind: $2" '/^---/ { if (found) exit; doc = ""; next }
    { doc = doc $0 "\n" } $0 == kind { found = 1 } END { if (found) printf "%s", doc }' <<< "$1"
}

expect_failure() {
  local message=$1
  shift
  local output
  if output=$(helm template mlflow "$chart" "$@" 2>&1); then
    echo "FAIL: expected render to fail with: $message" >&2
    exit 1
  fi
  expect_contains "$output" "$message"
}

echo "Lint"
helm lint "$chart" "${required[@]}"

echo "Default render loads the plugin and its settings"
out=$(render)
expect_contains "$out" '^            - --app-name=oidc-auth$'
expect_contains "$out" 'image: ghcr\.io/gradata-systems/mlflow-oidc:v[0-9.]+-oidc[0-9.]+$'
expect_contains "$out" '^                name: mlflow-oidc$'
expect_contains "$out" '^  OIDC_DISCOVERY_URL: "https://idp\.example\.com/'
expect_contains "$out" '^  OIDC_CLIENT_SECRET: "client-secret"$'
expect_contains "$out" '^  SECRET_KEY: "[A-Za-z0-9]{64}"$'
# Unset options are omitted so the plugin's defaults apply.
expect_absent "$out" 'OIDC_SCOPE|CACHE_BACKEND|AUTOMATIC_LOGIN_REDIRECT'

echo "Optional settings render; Redis enables the shared cache"
out=$(render \
  --set 'oidc.scope=openid\,email' \
  --set oidc.automaticLoginRedirect=false \
  --set oidc.cache.redisUrl=redis://redis:6379/0 \
  --set oidc.cache.keyPrefix=prod: \
  --set oidc.useRefreshToken=true \
  --set oidc.usersDbPool.size=5 \
  --set oidc.usersDbPool.maxOverflow=0 \
  --set oidc.usersDbPool.recycleSeconds=1800 \
  --set oidc.extraEnv.PERMISSION_CACHE_TTL_SECONDS=60 \
  --set oidc.secret.secretKey=fixed-key \
  --set oidc.secret.sessionTokenEncryptionKey=fernet-key)
expect_contains "$out" '^  OIDC_SCOPE: "openid,email"$'
expect_contains "$out" '^  AUTOMATIC_LOGIN_REDIRECT: "false"$'
expect_contains "$out" '^  CACHE_BACKEND: "redis"$'
expect_contains "$out" '^  CACHE_REDIS_URL: "redis://redis:6379/0"$'
expect_contains "$out" '^  CACHE_KEY_PREFIX: "prod:"$'
expect_contains "$out" '^  OIDC_USE_REFRESH_TOKEN: "true"$'
expect_contains "$out" '^  OIDC_DB_POOL_SIZE: "5"$'
expect_contains "$out" '^  OIDC_DB_POOL_MAX_OVERFLOW: "0"$'
expect_contains "$out" '^  OIDC_DB_POOL_RECYCLE_SECONDS: "1800"$'
expect_contains "$out" '^  PERMISSION_CACHE_TTL_SECONDS: "60"$'
expect_contains "$out" '^  SECRET_KEY: "fixed-key"$'
expect_contains "$out" '^  SESSION_TOKEN_ENCRYPTION_KEY: "fernet-key"$'

echo "Production example renders, with every credential in the Secret only"
helm lint "$chart" "${production[@]}"
out=$(helm template mlflow "$chart" "${production[@]}")
secret=$(document "$out" Secret)
expect_contains "$secret" '^  MLFLOW_BACKEND_STORE_URI: "postgresql://'
expect_contains "$secret" '^  OIDC_CLIENT_SECRET: '
expect_contains "$secret" '^  OIDC_USERS_DB_URI: "postgresql://'
expect_contains "$secret" '^  CACHE_REDIS_URL: "rediss://'
expect_contains "$secret" '^  SESSION_TOKEN_ENCRYPTION_KEY: '
expect_contains "$(document "$out" ConfigMap)" '^  CACHE_BACKEND: "redis"$'
for kind in Deployment ConfigMap; do
  expect_absent "$(document "$out" "$kind")" 'CHANGE_ME|postgresql://|rediss://'
done
expect_contains "$(document "$out" Deployment)" '^                  key: MLFLOW_BACKEND_STORE_URI$'

echo "secret.create=false leaves the Secret to the user"
out=$(helm template mlflow "$chart" \
  --set oidc.discoveryUrl=https://idp/x --set oidc.clientId=mlflow \
  --set mlflow.mlflow.backendStoreUri=postgresql://db/mlflow \
  --set oidc.secret.create=false)
expect_absent "$out" '^kind: Secret$'
expect_contains "$out" '^kind: ConfigMap$'

echo "Renaming resources together works"
out=$(render --set oidc.resourceName=team-a-oidc \
  --set 'mlflow.envFrom[0].configMapRef.name=team-a-oidc' \
  --set 'mlflow.envFrom[1].secretRef.name=team-a-oidc')
expect_contains "$out" '^  name: team-a-oidc$'

echo "Misconfiguration fails at render time"
expect_failure "oidc.discoveryUrl is required" --set mlflow.mlflow.backendStoreUri=x
expect_failure "oidc.clientSecret is required" "${required[@]}" --set oidc.clientSecret=
expect_failure "oidc.usersDbUri is required" "${required[@]}" --set oidc.usersDbUri=
expect_failure "cannot be SQLite with more than one replica" "${required[@]}" \
  --set oidc.usersDbUri=sqlite:////mlflow/auth.db --set mlflow.replicaCount=2
expect_failure "must contain a configMapRef and a secretRef" "${required[@]}" \
  --set oidc.resourceName=other
expect_failure "app_name must be oidc-auth" "${required[@]}" \
  --set mlflow.server.value_options.app_name=null
expect_failure "backendStoreUriFrom must be secretKeyRef" "${required[@]}" \
  --set backendStoreUri=postgresql://db/mlflow
expect_failure "so backendStoreUri is required" "${production[@]}" --set backendStoreUri=
expect_failure "needs oidc.secret.create=true" "${production[@]}" --set oidc.secret.create=false
render --set oidc.clientSecret= --set oidc.publicClient=true > /dev/null

echo "All chart tests passed."
