#!/usr/bin/env bash
# Lint and render-test the mlflow-oidc chart. Needs helm; fetches the upstream
# chart dependency on first run. Usage: scripts/test-chart.sh
set -euo pipefail

chart="$(cd "$(dirname "$0")/../charts/mlflow-oidc" && pwd)"
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
  --set oidc.extraEnv.OIDC_USE_REFRESH_TOKEN=true \
  --set oidc.secret.secretKey=fixed-key)
expect_contains "$out" '^  OIDC_SCOPE: "openid,email"$'
expect_contains "$out" '^  AUTOMATIC_LOGIN_REDIRECT: "false"$'
expect_contains "$out" '^  CACHE_BACKEND: "redis"$'
expect_contains "$out" '^  CACHE_REDIS_URL: "redis://redis:6379/0"$'
expect_contains "$out" '^  OIDC_USE_REFRESH_TOKEN: "true"$'
expect_contains "$out" '^  SECRET_KEY: "fixed-key"$'

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
render --set oidc.clientSecret= --set oidc.publicClient=true > /dev/null

echo "All chart tests passed."
