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

# Run Kubernetes e2e tests against a cluster with Windows nodes.
# Uses the upstream e2e.test binary with sig-network/sig-windows focus,
# matching the pattern used by sig-windows community CI.
#
# Prerequisites:
#   - A running K8s cluster with Windows nodes
#   - kubectl configured or --kubeconfig provided
#   - windows-kubeproxy daemonset already deployed
#
# Usage:
#   ./hack/conformance-test.sh [OPTIONS]
#
# Modes:
#   network-proxy  - sig-network kube-proxy/Services tests (default)
#   sig-windows    - All sig-windows tests
#   full           - Full [Conformance] suite (slow)
#
# Examples:
#   ./hack/conformance-test.sh --mode network-proxy
#   ./hack/conformance-test.sh --mode sig-windows --k8s-version v1.35.0
#   ./hack/conformance-test.sh --focus '\[sig-network\].*NodePort'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
RESULTS_DIR="${ROOT_DIR}/_results"
TOOLS_DIR="${ROOT_DIR}/_tools"

MODE="network-proxy"
FOCUS=""
SKIP=""
K8S_VERSION="v1.35.0"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
TIMEOUT="2h"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Run Kubernetes e2e tests against a cluster with Windows nodes.

Options:
  --mode MODE           Test mode: network-proxy (default), sig-windows, full
  --focus REGEX         Custom ginkgo focus regex (overrides mode)
  --skip REGEX          Custom ginkgo skip regex (overrides mode)
  --k8s-version VER     Kubernetes version for e2e.test binary (default: ${K8S_VERSION})
  --kubeconfig PATH     Path to kubeconfig (default: \$KUBECONFIG or ~/.kube/config)
  --timeout DURATION    Ginkgo timeout (default: 2h)
  --results-dir DIR     Directory for test results (default: _results/)
  -h, --help            Show this help

Modes:
  network-proxy   sig-network tests for kube-proxy, Services, NodePort, ClusterIP
  sig-windows     All sig-windows and sig-network+sig-windows tests
  full            Full [Conformance] suite (excludes LinuxOnly, very slow)

Examples:
  $0 --mode network-proxy
  $0 --mode sig-windows --k8s-version v1.35.0
  $0 --focus '\\[sig-network\\].*NodePort' --kubeconfig ~/.kube/my-cluster
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        MODE="$2"; shift 2 ;;
        --focus)       FOCUS="$2"; shift 2 ;;
        --skip)        SKIP="$2"; shift 2 ;;
        --k8s-version) K8S_VERSION="$2"; shift 2 ;;
        --kubeconfig)  KUBECONFIG="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --results-dir) RESULTS_DIR="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

# Resolve focus/skip from mode if not explicitly set
if [[ -z "${FOCUS}" ]]; then
    case "${MODE}" in
        network-proxy)
            FOCUS='\[sig-network\].*(Services|kube-proxy|NodePort|ClusterIP|Endpoints|Conntrack)'
            ;;
        sig-windows)
            FOCUS='\[sig-windows\]|\[sig-network\].*\[sig-windows\]'
            ;;
        full)
            FOCUS='\[Conformance\]'
            ;;
        *)
            echo "ERROR: Unknown mode '${MODE}'"
            usage
            ;;
    esac
fi

if [[ -z "${SKIP}" ]]; then
    case "${MODE}" in
        full)
            SKIP='\[LinuxOnly\]|\[Flaky\]'
            ;;
        *)
            SKIP='\[LinuxOnly\]|\[Serial\]|\[Slow\]|\[Flaky\]|\[Feature:|\[Disruptive\]'
            ;;
    esac
fi

# ── Ensure e2e.test binary ──────────────────────────────────────────
ensure_e2e_binary() {
    if command -v e2e.test &>/dev/null; then
        echo "Using e2e.test from PATH"
        return
    fi

    local e2e_bin="${TOOLS_DIR}/e2e.test"
    if [[ -x "${e2e_bin}" ]]; then
        export PATH="${TOOLS_DIR}:${PATH}"
        echo "Using cached e2e.test from ${TOOLS_DIR}"
        return
    fi

    echo "Downloading e2e.test for ${K8S_VERSION}..."
    mkdir -p "${TOOLS_DIR}"

    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)       arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac

    local url="https://dl.k8s.io/${K8S_VERSION}/kubernetes-test-${os}-${arch}.tar.gz"
    curl -sSL "${url}" \
        | tar xz --strip-components=3 -C "${TOOLS_DIR}" \
          kubernetes/test/bin/e2e.test \
          kubernetes/test/bin/ginkgo
    chmod +x "${TOOLS_DIR}/e2e.test" "${TOOLS_DIR}/ginkgo"
    export PATH="${TOOLS_DIR}:${PATH}"
    echo "e2e.test installed to ${TOOLS_DIR}"
}

# ── Verify cluster ──────────────────────────────────────────────────
verify_cluster() {
    echo "Checking cluster connectivity..."
    if ! kubectl --kubeconfig "${KUBECONFIG}" cluster-info &>/dev/null; then
        echo "ERROR: Cannot connect to cluster. Check kubeconfig at ${KUBECONFIG}"
        exit 1
    fi

    echo ""
    echo "Nodes:"
    kubectl --kubeconfig "${KUBECONFIG}" get nodes -o wide
    echo ""

    # Verify Windows nodes exist
    local win_nodes
    win_nodes=$(kubectl --kubeconfig "${KUBECONFIG}" get nodes -l kubernetes.io/os=windows --no-headers 2>/dev/null | wc -l)
    if [[ "${win_nodes}" -eq 0 ]]; then
        echo "WARNING: No Windows nodes found in the cluster."
        echo "         sig-network/sig-windows tests require Windows nodes."
    else
        echo "Found ${win_nodes} Windows node(s)"
    fi

    # Check if windows-kubeproxy is deployed
    if kubectl --kubeconfig "${KUBECONFIG}" get daemonset windows-kubeproxy -n kube-system &>/dev/null; then
        echo "windows-kubeproxy daemonset is deployed"
        kubectl --kubeconfig "${KUBECONFIG}" get pods -n kube-system -l app=windows-kubeproxy --no-headers
    else
        echo "WARNING: windows-kubeproxy daemonset not found in kube-system"
    fi
    echo ""
}

# ── Run tests ───────────────────────────────────────────────────────
run_tests() {
    mkdir -p "${RESULTS_DIR}"

    echo "============================================"
    echo " Windows KubeProxy E2E Tests"
    echo " Mode:        ${MODE}"
    echo " Focus:       ${FOCUS}"
    echo " Skip:        ${SKIP}"
    echo " K8s version: ${K8S_VERSION}"
    echo " Timeout:     ${TIMEOUT}"
    echo " Results:     ${RESULTS_DIR}"
    echo "============================================"
    echo ""

    local exit_code=0
    e2e.test \
        --kubeconfig="${KUBECONFIG}" \
        --provider=skeleton \
        --ginkgo.focus="${FOCUS}" \
        --ginkgo.skip="${SKIP}" \
        --node-os-distro=windows \
        --report-dir="${RESULTS_DIR}" \
        --ginkgo.timeout="${TIMEOUT}" \
        --ginkgo.no-color \
        --ginkgo.v \
        2>&1 | tee "${RESULTS_DIR}/e2e.log" || exit_code=$?

    echo ""
    echo "============================================"
    if [[ "${exit_code}" -eq 0 ]]; then
        echo " ALL TESTS PASSED"
    else
        echo " TESTS FAILED (exit code: ${exit_code})"
    fi
    echo " Results saved to: ${RESULTS_DIR}"
    echo "============================================"

    # Print JUnit summary if xmllint is available
    if command -v xmllint &>/dev/null; then
        for f in "${RESULTS_DIR}"/*.xml; do
            [[ -f "$f" ]] || continue
            echo ""
            echo "JUnit: $(basename "$f")"
            xmllint --xpath '//testsuite/@tests | //testsuite/@failures | //testsuite/@errors' "$f" 2>/dev/null || true
        done
    fi

    return "${exit_code}"
}

ensure_e2e_binary
verify_cluster
run_tests
