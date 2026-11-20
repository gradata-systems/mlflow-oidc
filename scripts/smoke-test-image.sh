#!/usr/bin/env bash
# Start an mlflow-oidc image the way the Helm chart runs it (non-root, read-only
# root filesystem, several workers, Prometheus metrics) and check that the plugin
# is loaded: health is public, the tracking API demands authentication.
#
# Usage: scripts/smoke-test-image.sh IMAGE MLFLOW_VERSION OIDC_AUTH_VERSION
set -euo pipefail

image=$1
mlflow_version=$2
oidc_auth_version=$3
name="mlflow-oidc-smoke-$$"
port="${SMOKE_TEST_PORT:-5055}"

# Git Bash on Windows would otherwise rewrite the container paths below.
export MSYS_NO_PATHCONV=1

cleanup() {
  if [[ "${status:-1}" != 0 ]] && docker container inspect "$name" > /dev/null 2>&1; then
    docker logs "$name" 2>&1 | tail -50
  fi
  docker rm -f "$name" > /dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Checking installed versions"
versions=$(docker run --rm --entrypoint python "$image" -c \
  "from importlib.metadata import version as v; print(v('mlflow'), v('mlflow-oidc-auth'))")
if [[ "$versions" != "$mlflow_version $oidc_auth_version" ]]; then
  echo "Expected mlflow $mlflow_version and mlflow-oidc-auth $oidc_auth_version, got: $versions" >&2
  exit 1
fi

echo "Starting server"
# The discovery URL is deliberately unreachable: the server must still start,
# since a briefly unavailable IdP must not crash-loop the pods.
docker run -d --name "$name" -p "$port:5000" --user 1000 --read-only --tmpfs /tmp \
  -e MLFLOW_BACKEND_STORE_URI=sqlite:////tmp/mlflow.db \
  -e OIDC_USERS_DB_URI=sqlite:////tmp/auth.db \
  -e OIDC_DISCOVERY_URL=https://idp.invalid/.well-known/openid-configuration \
  -e OIDC_CLIENT_ID=smoke-test \
  -e OIDC_CLIENT_SECRET=smoke-test \
  -e SECRET_KEY=smoke-test-secret-key-smoke-test-secret-key \
  "$image" \
  mlflow server --app-name=oidc-auth --host=0.0.0.0 --port=5000 --workers=2 \
  --expose-prometheus=/tmp/metrics > /dev/null

status_of() { curl -s -m 10 -o /dev/null -w '%{http_code}' "http://localhost:$port$1" || true; }

for _ in $(seq 1 60); do
  [[ "$(status_of /health)" == 200 ]] && break
  sleep 2
done

expect_status() {
  local path=$1 expected=$2 actual
  actual=$(status_of "$path")
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $path to return $expected, got $actual" >&2
    exit 1
  fi
  echo "  $path -> $actual"
}

expect_status /health 200
expect_status /metrics 200
expect_status /api/2.0/mlflow/experiments/search 401
expect_status / 401

status=0
echo "Smoke test passed."
