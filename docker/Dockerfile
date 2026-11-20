# MLflow with the mlflow-oidc-auth plugin (https://github.com/mlflow-oidc/mlflow-oidc-auth).
#
# Built on the upstream release image rather than from source, so the
# MLflow code in the image is exactly what upstream released and tested.
# Versions are pinned in charts/mlflow-oidc/Chart.yaml; see README.md.
ARG MLFLOW_VERSION
FROM ghcr.io/mlflow/mlflow:v${MLFLOW_VERSION}-full

ARG MLFLOW_VERSION
ARG MLFLOW_OIDC_AUTH_VERSION

# Pinning mlflow alongside the plugin makes the build fail, instead of silently
# swapping MLflow versions, if the plugin does not support this MLflow release.
# The `cache` extra adds Redis support for multi-replica permission caching.
RUN pip install --no-cache-dir \
      "mlflow==${MLFLOW_VERSION}" \
      "mlflow-oidc-auth[cache]==${MLFLOW_OIDC_AUTH_VERSION}"

LABEL org.opencontainers.image.source="https://github.com/gradata-systems/mlflow-oidc" \
      org.opencontainers.image.description="MLflow ${MLFLOW_VERSION} with mlflow-oidc-auth ${MLFLOW_OIDC_AUTH_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"

EXPOSE 5000
CMD ["mlflow", "server", "--app-name", "oidc-auth", "--host", "0.0.0.0", "--port", "5000"]
