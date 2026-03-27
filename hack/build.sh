#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

VERSION="${1:?Usage: $0 <version> (e.g. v1.32.7)}"

echo "Building windows-kubeproxy.exe ${VERSION} ..."

GOOS=windows GOARCH=amd64 go build \
  -ldflags "\
  -X k8s.io/component-base/version.gitVersion=${VERSION} \
  -X k8s.io/component-base/version.gitCommit=$(git rev-parse HEAD) \
  -X k8s.io/component-base/version.gitTreeState=clean" \
  -o windows-kubeproxy.exe ./cmd

echo "Build complete: windows-kubeproxy.exe (${VERSION})"
