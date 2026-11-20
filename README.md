# mlflow-oidc

An [MLflow](https://github.com/mlflow/mlflow) container image with the
[mlflow-oidc-auth](https://github.com/mlflow-oidc/mlflow-oidc-auth) plugin for
OIDC single sign-on, and a Helm chart to deploy it:

| Artifact | Location                                                                    |
| -------- | --------------------------------------------------------------------------- |
| Image    | `ghcr.io/gradata-systems/mlflow-oidc:v<MLflow>-oidc<plugin>` (and `latest`) |
| Chart    | `oci://ghcr.io/gradata-systems/charts/mlflow-oidc`                          |

Deployment instructions are in [charts/mlflow-oidc/README.md](charts/mlflow-oidc/README.md).

## Layout

| Path                          | Purpose                                                                 |
| ----------------------------- | ----------------------------------------------------------------------- |
| `docker/Dockerfile`           | Upstream release image `ghcr.io/mlflow/mlflow:v<X.Y.Z>-full` + plugin   |
| `charts/mlflow-oidc/`         | Wrapper chart; depends on upstream `oci://ghcr.io/mlflow/charts/mlflow` |
| `scripts/versions.py`         | Reads, checks and bumps the version pins                                |
| `scripts/test-chart.sh`       | Chart lint and render tests                                             |
| `scripts/smoke-test-image.sh` | Starts the image and checks authentication is enforced                  |
| `.github/workflows/build.yml` | Tests on PRs; publishes image and chart on `main`                       |
| `.github/workflows/bump.yml`  | Daily PR for new MLflow and plugin releases                             |
| `.github/workflows/lint.yml`  | ruff, prettier, shellcheck and actionlint                               |
| `.github/dependabot.yml`      | Weekly PRs for the workflows' action pins                               |

## Design

**The image is built from upstream's released image, not from MLflow
source.** The MLflow code is exactly what upstream released and tested, and
the build takes about a minute instead of a full UI build.

**The chart wraps upstream's published chart of the same version.** Chart and
image are always the pair upstream released together, and upstream chart
improvements arrive with each MLflow version bump at no maintenance cost.

**Versions are pinned and bumped by pull request.** Three places must agree:
`appVersion` and the `mlflow` dependency in `Chart.yaml`, the
`mlflow-oidc-auth/version` annotation, and `mlflow.image.tag` in
`values.yaml`. `versions.py check` enforces this in CI, and `versions.py set`
rewrites them together. The chart's own `version` is independent semver: a
minor bump for an MLflow upgrade, a patch bump for a plugin upgrade, and a
manual bump for template changes.

**Published versions are immutable.** `build.yml` pushes an image tag or chart
version only if it does not exist yet. To publish a change, bump the version.

## Staying up to date

- **MLflow and plugin releases:** `bump.yml` runs daily (and on demand from the
  Actions tab). When a newer stable MLflow release or plugin release has been
  out for at least 7 days, it opens a PR that updates all the pins and
  `Chart.lock`. The delay avoids releases that get yanked. The PR runs the full
  build and test, including a Kind deployment, and merging it publishes. The
  pins never move backwards.
- **Workflow actions:** Dependabot opens a grouped PR weekly, also with a 7-day
  cooldown.

## One-time setup

1. **Create the `BUMP_TOKEN` secret** (Settings, Secrets and variables,
   Actions). Use a fine-grained personal access token, or a GitHub App token,
   scoped to this repository with read/write on **Contents** and **Pull
   requests**. With `GITHUB_TOKEN` instead, the bump PRs wouldn't trigger CI.
2. **Publish the first release:** push to `main`, or run "Build" from the
   Actions tab on `main`.
3. **Package visibility:** new ghcr.io packages are private. Either make
   `mlflow-oidc` and `charts/mlflow-oidc` public (organisation Packages, then
   package settings), or give clusters a pull secret through
   `mlflow.imagePullSecrets` and run `helm registry login ghcr.io` before
   installing.

## Manual version changes

```bash
python scripts/versions.py show                     # current pins
python scripts/versions.py set --oidc-auth 11.6.0   # or --mlflow 3.19.0
helm dependency update charts/mlflow-oidc           # after an MLflow change
python scripts/versions.py check
```

For a template-only change, bump `version` in `charts/mlflow-oidc/Chart.yaml` by hand.

## Testing locally

Requires Docker and Helm.

```bash
scripts/test-chart.sh

docker build --build-arg MLFLOW_VERSION=3.18.0 --build-arg MLFLOW_OIDC_AUTH_VERSION=11.0.5 \
  -t mlflow-oidc:dev docker
scripts/smoke-test-image.sh mlflow-oidc:dev 3.18.0 11.0.5
```

## License

[Apache-2.0](LICENSE). The image also contains MLflow and mlflow-oidc-auth,
which are distributed under their own licences.
