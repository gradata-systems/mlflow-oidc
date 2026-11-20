# Production example

Values for a highly available MLflow with OIDC single sign-on:

- 2 to 4 replicas (HPA), spread across zones, rolling updates with no downtime
- PostgreSQL for the tracking database and the plugin's users database
- Redis for the permission cache shared between replicas
- S3 artifacts proxied by the server, with an IAM role (EKS IRSA) instead of
  static keys
- HTTPS ingress (ingress-nginx and cert-manager), secure session cookies,
  trusted proxy headers, and audience checks on bearer tokens
- a NetworkPolicy limiting egress to DNS, HTTPS, PostgreSQL and Redis

| File                   | Contents                                                     |
| ---------------------- | ------------------------------------------------------------ |
| `values.yaml`          | Everything except credentials. Safe to commit.               |
| `secrets.example.yaml` | Credentials, as chart values. Template for your secrets file |

Every credential is a chart value. The chart writes them into its Secret
`mlflow-oidc`, so none of them appear in the Deployment or ConfigMap, including
the tracking database password (see `backendStoreUri` in the chart's
`values.yaml`).

## Prerequisites

- PostgreSQL with two databases, `mlflow` and `mlflow_auth`, and a user for
  each. MLflow and the plugin create their tables on first start; before
  upgrading to a new MLflow release, back up the tracking database and run
  `mlflow db upgrade <URI>` if the release notes mention a migration.
- Redis reachable from the namespace.
- An S3 bucket and an IAM role for the `mlflow` service account with
  `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` and `s3:ListBucket` on it.
- A confidential OIDC client with redirect URI
  `https://mlflow.example.com/callback` whose tokens carry a `groups` claim
  and an audience of `mlflow`. See the chart README's identity provider setup.

## Install

1. Copy `values.yaml` and replace the hosts, groups, bucket, role ARN and
   `trustedProxies` CIDR.
2. Copy `secrets.example.yaml` to `secrets.yaml`, replace every `CHANGE_ME`,
   and encrypt it, e.g. with [SOPS](https://github.com/getsops/sops). Never
   commit it unencrypted.
3. Install:

   ```bash
   helm secrets upgrade --install mlflow oci://ghcr.io/gradata-systems/charts/mlflow-oidc \
     --version <chart version> \
     --namespace mlflow --create-namespace \
     -f values.yaml -f secrets.yaml
   ```

   Without the [helm-secrets](https://github.com/jkroepke/helm-secrets)
   plugin, use `helm upgrade --install` with a decrypted `secrets.yaml`, or
   pass each credential with `--set` from your CI secret store, e.g.
   `--set oidc.clientSecret="$OIDC_CLIENT_SECRET"`.

Name the release `mlflow`, or change the labels in
`topologySpreadConstraints`.

## Not included

- **Garbage collection.** With proxied artifacts, `mlflow gc` deletes a run's
  artifacts through the MLflow server (`mlflow-artifacts:` URIs), which the
  plugin protects, and the upstream `garbageCollection` CronJob has no
  credentials for it. Don't enable it until you have given it a way to
  authenticate and tested it.
- **Metrics.** `mlflow.metrics.enabled: true` serves `/metrics` without
  authentication, including through the ingress. Restrict the path at the
  ingress before enabling it, then set `mlflow.serviceMonitor.enabled: true`
  if you run the Prometheus Operator.
- **PodDisruptionBudget.** The upstream chart does not create one. With
  `minReplicas: 2`, add a PDB with `maxUnavailable: 1` if node drains must
  not take MLflow down.
