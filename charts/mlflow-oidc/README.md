# mlflow-oidc Helm chart

Deploys MLflow with OIDC single sign-on via the
[mlflow-oidc-auth](https://github.com/mlflow-oidc/mlflow-oidc-auth) plugin.

This chart wraps the upstream
[MLflow chart](https://github.com/mlflow/mlflow/tree/master/charts) of the same
MLflow version, so every upstream feature (ingress, TLS, HPA, metrics, network
policy, garbage collection) is available under the `mlflow:` key. On top of it,
this chart adds:

- the `ghcr.io/gradata-systems/mlflow-oidc` image (upstream `-full` image plus the plugin),
- `--app-name oidc-auth`, which loads the plugin,
- an `oidc:` block of typed settings, rendered into a ConfigMap and Secret that
  the MLflow container loads,
- render-time checks that fail on configurations that would leave MLflow
  without authentication or with an unworkable setup.

## Install

```bash
helm install mlflow oci://ghcr.io/gradata-systems/charts/mlflow-oidc \
  --version <chart version> \
  --namespace mlflow --create-namespace \
  -f my-values.yaml
```

`helm show values oci://ghcr.io/gradata-systems/charts/mlflow-oidc` lists every
setting. The chart's `appVersion` is the MLflow version, and the
`mlflow-oidc-auth/version` annotation (`helm show chart`) is the plugin version.

## Identity provider setup

Register a confidential OIDC client (authorization code flow) with:

- **Redirect URI:** `https://<your MLflow host>/callback`
- **Scopes:** `openid email profile`, plus whatever scope makes your IdP
  include the groups claim
- **Groups claim:** users must be in `oidc.groupName` (default `mlflow`) to
  log in, and in `oidc.adminGroupName` (default `mlflow-admin`) to administer
  permissions.

## Example: production values

```yaml
oidc:
  discoveryUrl: https://login.example.com/realms/main/.well-known/openid-configuration
  clientId: mlflow
  redirectUri: https://mlflow.example.com/callback
  groupName: ml-engineers
  adminGroupName: ml-platform-admins
  audience: mlflow
  # The ingress controller's pod CIDR, so X-Forwarded-* headers are honoured.
  trustedProxies: 10.0.0.0/8
  sessionCookieSecure: true
  # Shared permission cache across replicas; CACHE_REDIS_URL is in the Secret.
  extraEnv:
    CACHE_BACKEND: redis
  # OIDC_CLIENT_SECRET, SECRET_KEY, OIDC_USERS_DB_URI and CACHE_REDIS_URL come
  # from a Secret named `mlflow-oidc` that you manage (e.g. External Secrets).
  secret:
    create: false

mlflow:
  replicaCount: 2
  mlflow:
    backendStoreUriFrom:
      secretKeyRef:
        name: mlflow-db
        key: uri
    artifactsDestination: s3://my-bucket/mlflow
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: mlflow.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: mlflow-example-com-tls
        hosts: [mlflow.example.com]
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
```

When the chart creates the Secret instead, set `oidc.clientSecret`,
`oidc.usersDbUri` and `oidc.cache.redisUrl` (which also sets `CACHE_BACKEND`).

## Example: single-node evaluation

SQLite for both databases on a PersistentVolumeClaim. Not for production.

```yaml
oidc:
  discoveryUrl: https://login.example.com/.well-known/openid-configuration
  clientId: mlflow
  clientSecret: change-me
  usersDbUri: sqlite:////mlflow/auth.db

mlflow:
  storage:
    enabled: true
  mlflow:
    backendStoreUri: sqlite:////mlflow/mlflow.db
    artifactsDestination: /mlflow/artifacts
```

## Things to know

- **Two databases.** MLflow uses `mlflow.mlflow.backendStoreUri`; the plugin
  stores users, groups, permissions and sessions in `oidc.usersDbUri`. Use a
  separate database (it can be on the same server). The plugin migrates its
  own database at startup.
- **MLflow upgrades may need a schema migration.** If a new MLflow release
  changes the tracking schema, pods fail to start with "Detected out-of-date
  database schema" until you back up the database and run
  `mlflow db upgrade <backend store URI>` with the new image.
- **Multiple replicas** need a shared `oidc.usersDbUri` (not SQLite; the chart
  enforces this), one `SECRET_KEY` (automatic when the chart creates the
  Secret), and preferably Redis (`oidc.cache.redisUrl`).
- **SECRET_KEY** is generated on install and preserved on upgrade by looking
  up the existing Secret. Tools that render without cluster access, such as
  `helm template` and Argo CD, generate a new key on every render, which logs
  everyone out. Set `oidc.secret.secretKey` or use `oidc.secret.create: false`
  with those tools.
- **Config changes don't restart pods.** After changing `oidc.*` values, run
  `kubectl rollout restart deployment/<release>-mlflow`.
- **`mlflow.envFrom` is a list,** so setting it replaces the chart's default.
  Keep the two `mlflow-oidc` entries when adding your own; the chart fails to
  render if they are missing.
- **Public endpoints.** `/health` and `/metrics` respond without
  authentication, so probes and Prometheus work unchanged. Restrict `/metrics`
  at the ingress if it must not be public.
- **Network policy.** If you enable `mlflow.networkPolicy`, the default egress
  rules allow HTTPS (the IdP) and common databases. Add Redis (6379) via
  `mlflow.networkPolicy.additionalEgressRules` if you use it.
- **Other plugin settings** can be set through `oidc.extraEnv` (non-secret) and
  `oidc.secret.extraEnv` (secret). See the
  [plugin configuration reference](https://github.com/mlflow-oidc/mlflow-oidc-auth/blob/main/docs/configuration.md).
