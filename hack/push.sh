#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

VERSION="${1:?Usage: $0 <version> (e.g. v1.32.7)}"
REGISTRY="${ACR_NAME:-wcninternal}"

echo "Logging in to ACR '${REGISTRY}' ..."
az acr login --name "${REGISTRY}"

echo "Building and pushing windows-kubeproxy:${VERSION} via ACR ..."
az acr build \
  --registry "${REGISTRY}" \
  --image "windows-kubeproxy:${VERSION}" \
  --platform windows/amd64 \
  .

echo "Push complete: ${REGISTRY}.azurecr.io/windows-kubeproxy:${VERSION}"
