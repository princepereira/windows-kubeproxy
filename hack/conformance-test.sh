#!/usr/bin/env bash

# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Run Kubernetes conformance tests using sonobuoy against an existing cluster.
#
# Usage:
#   ./hack/conformance-test.sh [--mode MODE] [--focus REGEX] [--kubeconfig PATH]
#
# Modes:
#   quick                 - Runs a single e2e test (smoke check)
#   certified-conformance - Full CNCF conformance suite (~2h)
#   network-proxy         - Network/kube-proxy focused e2e tests
#
# Examples:
#   ./hack/conformance-test.sh --mode quick
#   ./hack/conformance-test.sh --mode network-proxy
#   ./hack/conformance-test.sh --mode certified-conformance --kubeconfig ~/.kube/config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
RESULTS_DIR="${ROOT_DIR}/_conformance-results"

MODE="quick"
FOCUS=""
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
SONOBUOY_VERSION="0.57.3"
SONOBUOY=""
TIMEOUT_SECONDS=21600  # 6 hours for full conformance

usage() {
    echo "Usage: $0 [--mode MODE] [--focus REGEX] [--kubeconfig PATH]"
    echo ""
    echo "Modes:"
    echo "  quick                  Smoke test (single e2e test)"
    echo "  certified-conformance  Full CNCF conformance suite"
    echo "  network-proxy          Network/kube-proxy e2e tests"
    echo ""
    echo "Options:"
    echo "  --focus REGEX          Custom e2e test focus regex (overrides mode)"
    echo "  --kubeconfig PATH      Path to kubeconfig (default: \$KUBECONFIG or ~/.kube/config)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --focus)
            FOCUS="$2"
            shift 2
            ;;
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

ensure_sonobuoy() {
    if command -v sonobuoy &>/dev/null; then
        SONOBUOY="sonobuoy"
        return
    fi

    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac

    local sonobuoy_bin="${ROOT_DIR}/_tools/sonobuoy"
    if [[ -x "${sonobuoy_bin}" ]]; then
        SONOBUOY="${sonobuoy_bin}"
        return
    fi

    echo "Installing sonobuoy v${SONOBUOY_VERSION}..."
    mkdir -p "${ROOT_DIR}/_tools"
    local url="https://github.com/vmware-tanzu/sonobuoy/releases/download/v${SONOBUOY_VERSION}/sonobuoy_${SONOBUOY_VERSION}_${os}_${arch}.tar.gz"
    curl -sSL "${url}" | tar -xz -C "${ROOT_DIR}/_tools" sonobuoy
    chmod +x "${sonobuoy_bin}"
    SONOBUOY="${sonobuoy_bin}"
    echo "sonobuoy installed at ${sonobuoy_bin}"
}

build_sonobuoy_args() {
    local -a args=()

    case "${MODE}" in
        quick)
            args+=(--mode quick)
            TIMEOUT_SECONDS=600
            ;;
        certified-conformance)
            args+=(--mode certified-conformance)
            ;;
        network-proxy)
            args+=(--e2e-focus '\\[sig-network\\].*(kube-proxy|Services|Proxy|Network)')
            args+=(--e2e-skip '\\[Slow\\]|\\[Serial\\]|\\[Disruptive\\]|\\[Flaky\\]')
            TIMEOUT_SECONDS=7200
            ;;
        *)
            echo "Unknown mode: ${MODE}"
            usage
            ;;
    esac

    if [[ -n "${FOCUS}" ]]; then
        # Override mode focus if custom focus is provided
        args=(--e2e-focus "${FOCUS}")
    fi

    args+=(--kubeconfig "${KUBECONFIG}")
    args+=(--wait "${TIMEOUT_SECONDS}")

    echo "${args[@]}"
}

run_conformance() {
    echo "============================================"
    echo " Kubernetes Conformance Test"
    echo " Mode:       ${MODE}"
    echo " Kubeconfig: ${KUBECONFIG}"
    echo "============================================"

    # Verify cluster connectivity
    echo "Checking cluster connectivity..."
    if ! kubectl --kubeconfig "${KUBECONFIG}" cluster-info &>/dev/null; then
        echo "ERROR: Cannot connect to cluster. Check your kubeconfig at ${KUBECONFIG}"
        exit 1
    fi
    kubectl --kubeconfig "${KUBECONFIG}" get nodes
    echo ""

    # Clean up any previous sonobuoy run
    ${SONOBUOY} delete --kubeconfig "${KUBECONFIG}" --wait 2>/dev/null || true

    # Build args and run
    local -a sonobuoy_args
    read -r -a sonobuoy_args <<< "$(build_sonobuoy_args)"

    echo "Running: sonobuoy run ${sonobuoy_args[*]}"
    ${SONOBUOY} run "${sonobuoy_args[@]}"

    echo "Waiting for sonobuoy to complete (timeout: ${TIMEOUT_SECONDS}s)..."
    if ! ${SONOBUOY} wait --kubeconfig "${KUBECONFIG}" "${TIMEOUT_SECONDS}"; then
        echo "ERROR: Sonobuoy timed out"
        ${SONOBUOY} status --kubeconfig "${KUBECONFIG}"
        ${SONOBUOY} logs --kubeconfig "${KUBECONFIG}" || true
        exit 1
    fi

    # Retrieve results
    mkdir -p "${RESULTS_DIR}"
    local results_tar
    results_tar=$(${SONOBUOY} retrieve --kubeconfig "${KUBECONFIG}" "${RESULTS_DIR}")
    echo "Results saved to: ${results_tar}"

    # Print summary
    echo ""
    echo "============================================"
    echo " Results Summary"
    echo "============================================"
    ${SONOBUOY} results "${results_tar}"

    # Check for failures
    local status
    status=$(${SONOBUOY} results "${results_tar}" | grep -c "Status: failed" || true)
    if [[ "${status}" -gt 0 ]]; then
        echo ""
        echo "FAILED tests:"
        ${SONOBUOY} results "${results_tar}" --mode detailed | grep "failed" || true
        exit 1
    fi

    echo ""
    echo "All conformance tests passed."

    # Cleanup
    ${SONOBUOY} delete --kubeconfig "${KUBECONFIG}" --wait 2>/dev/null || true
}

ensure_sonobuoy
run_conformance
