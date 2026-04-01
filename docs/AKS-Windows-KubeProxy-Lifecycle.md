# AKS Windows Kube-Proxy: Full Lifecycle & Deployment Guide

> **Node analysed:** `hpc-ds-win-sxr8b` (aksnpwin000000) — AKS Windows Server 2022 (ltsc2022)
> **Kubernetes version:** v1.32.7 — **Networking:** Dual-stack (IPv4 + IPv6), L2Bridge, DSR enabled
> **Date of analysis:** March 26, 2026

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  AKS Windows Node (aksnpwin000000)                      │
│                                                         │
│  Custom Script Extension (CSE)                          │
│    │                                                    │
│    ├─ WriteKubeClusterConfig   → c:\k\kubeclusterconfig.json
│    ├─ DownloadKubeletBinaries  → c:\k\kube-proxy.exe    │
│    ├─ InstallKubernetesServices (NSSM)                  │
│    │     └─ Registers "Kubeproxy" Windows service       │
│    ├─ UpdateKubeClusterConfig  → patch node IPs         │
│    └─ NodeResetScriptTask      → starts services        │
│                                                         │
│  kube-proxy.exe (kernelspace mode)                      │
│    ├─ Reads kubeconfig from c:\k\config                 │
│    ├─ Programs HNS load balancers & policies            │
│    ├─ DSR enabled for externalTrafficPolicy: Local      │
│    └─ Syncs every 30s via bounded_frequency_runner      │
│                                                         │
│  HNS (Host Networking Service)                          │
│    ├─ Network: "azure" (L2Bridge)                       │
│    ├─ Endpoints per service (4 each)                    │
│    └─ Load Balancers: 16                                │
└─────────────────────────────────────────────────────────┘
```

---

## 2. CSE Bootstrap Sequence

The Custom Script Extension (AgentBaker) runs during node provisioning. The full
sequence, extracted from `CustomDataSetupScript.log`, is:

| Step | CSE Function | What it does |
|------|-------------|--------------|
| 1 | `WriteKubeClusterConfig` | Creates `c:\k\kubeclusterconfig.json` with cluster/network config |
| 2 | `DownloadKubeletBinaries` | Downloads Kubernetes zip from `packages.aks.azure.com` to `c:\k\` |
| 3 | `InstallKubernetesServices` | Registers **Kubelet** and **Kubeproxy** as Windows services via NSSM |
| 4 | `UpdateKubeClusterConfig` | Patches `kubeclusterconfig.json` with the node's actual IPv4/IPv6 addresses |
| 5 | `RegisterNodeResetScriptTask` | Creates scheduled task `NodeResetScriptTask` → `windowsnodereset.ps1` |
| 6 | `StartScheduledTask` | Triggers `NodeResetScriptTask` which starts Kubelet and Kubeproxy |

### NSSM Registration Details

```
nssm install Kubeproxy c:\k\kube-proxy.exe
nssm set Kubeproxy AppDirectory c:\k
nssm set Kubeproxy AppParameters <flags built from kubeclusterconfig.json>
nssm set Kubeproxy DependOnService Kubelet
nssm set Kubeproxy AppStdout  c:\k\kubeproxy.out.log
nssm set Kubeproxy AppStderr  c:\k\kubeproxy.err.log
nssm set Kubeproxy AppRotateFiles 1
nssm set Kubeproxy AppRotateOnline 1
nssm set Kubeproxy AppRotateBytes 10485760
```

> **Key detail:** Services are NOT started directly by the CSE script. They are
> started by the `NodeResetScriptTask` scheduled task (`windowsnodereset.ps1`),
> which is triggered as the final CSE step.

---

## 3. kubeclusterconfig.json → CLI Flags Mapping

The CSE PowerShell scripts read `kubeclusterconfig.json` and translate the config
into kube-proxy CLI flags:

| JSON Path | CLI Flag | Value (this node) |
|-----------|----------|-------------------|
| `Kubernetes.Kubeproxy.FeatureGates[*]` | `--feature-gates` | `WinDSR=true,WinOverlay=false` |
| `Kubernetes.Kubeproxy.ConfigArgs[]` | (passed directly) | `--metrics-bind-address=0.0.0.0:10249` |
| *(derived from WinDSR feature gate)* | `--enable-dsr` | `true` |
| *(always set)* | `--proxy-mode` | `kernelspace` |
| *(node hostname)* | `--hostname-override` | `aksnpwin000000` |
| *(kubeconfig path)* | `--kubeconfig` | `c:\k\config` |
| *(log verbosity)* | `--v` | `3` |

> **Note:** `--enable-dsr=true` is NOT in `ConfigArgs` — it is auto-derived by
> the CSE scripts when `WinDSR=true` appears in the feature gates.

---

## 4. Effective Startup Flags

Complete non-default flags extracted from the kube-proxy FLAG dump at startup:

```
c:\k\kube-proxy.exe \
  --proxy-mode=kernelspace \
  --kubeconfig=c:\k\config \
  --hostname-override=aksnpwin000000 \
  --enable-dsr=true \
  --feature-gates="WinDSR=true,WinOverlay=false" \
  --metrics-bind-address=0.0.0.0:10249 \
  --v=3
```

### All Flags (from log)

| Flag | Value |
|------|-------|
| `--bind-address` | `0.0.0.0` |
| `--enable-dsr` | `true` |
| `--feature-gates` | `WinDSR=true,WinOverlay=false` |
| `--healthz-bind-address` | `0.0.0.0:10256` |
| `--hostname-override` | `aksnpwin000000` |
| `--kubeconfig` | `c:\k\config` |
| `--metrics-bind-address` | `0.0.0.0:10249` |
| `--proxy-mode` | `kernelspace` |
| `--root-hnsendpoint-name` | `cbr0` |
| `--v` | `3` |

---

## 5. Runtime Behavior

### Node Networking

- **Dual-stack:** IPv4 `10.224.0.5` + IPv6 `fd78:2f2b:ad5f:accb::5`
- **HNS Network:** `azure` (L2Bridge)
- **Primary IP family:** IPv4
- **ClusterCIDR:** `10.224.0.0/16`
- **ServiceCIDR:** `10.0.0.0/16`

### HNS Feature Support

| Feature | Supported |
|---------|-----------|
| DSR | Yes |
| IPv6DualStack | Yes |
| SetPolicy | Yes |
| L4Proxy | Yes |
| L4WfpProxy | Yes |
| SessionAffinity | Yes |
| TierAcl | No |
| NetworkACL | No |
| ModifyLoadbalancer | No |

### Sync Cycle Performance

kube-proxy syncs HNS policies every **30 seconds**. Each sync cycle for this
node (2 dual-stack services, 4 endpoints each, 16 load balancers):

| Metric | Value |
|--------|-------|
| Average | 4.94 ms |
| Min | 2.72 ms |
| Max | 7.25 ms |
| Cycles measured | 31 |

Each 30-second sync cycle produces two runs (one per IP family: IPv4 then IPv6).
The sequence per run is:

1. **Query endpoints** from HNS network `azure`
2. **Query load balancers** (count=16)
3. **Sync policies** ("Prince DupEP Syncing Policies")
4. **Report healthchecks** for services with `externalTrafficPolicy: Local`
5. **bounded_frequency_runner** logs completion

### Services Being Proxied

| Service | Port | DSR | Endpoints |
|---------|------|-----|-----------|
| `demo/httpserver-ipv4-local` | NodePort 30517 | Yes (localTrafficDSR=true) | 4 |
| `demo/httpserver-ipv6-local` | NodePort 31314 | Yes (localTrafficDSR=true) | 4 |
| `demo/httpserver-ipv4-cluster` | — | No | — |
| `demo/httpserver-ipv6-cluster` | — | No | — |
| `kube-system/kube-dns` | — | No | — |
| `kube-system/metrics-server` | — | No | — |
| `default/kubernetes` | — | No | — |

---

## 6. Deploying a Custom kube-proxy Binary

### Option A: In-Place Swap via NSSM (Recommended)

SSH or RDP into the Windows node, then:

```powershell
# 1. Stop the service
nssm stop Kubeproxy

# 2. Back up the original binary
Copy-Item c:\k\kube-proxy.exe c:\k\kube-proxy.exe.bak

# 3. Copy your custom binary
Copy-Item .\kube-proxy.exe c:\k\kube-proxy.exe

# 4. Start the service (same flags, same log rotation)
nssm start Kubeproxy
```

To get the binary onto the node:
```powershell
# From your dev machine, copy via kubectl
kubectl cp kube-proxy.exe <pod-name>:/kube-proxy.exe -c <container> -n <namespace>

# Or use SCP / Azure Bastion file transfer
```

### Option B: Manual Run (for debugging)

```powershell
# 1. Stop the NSSM service
nssm stop Kubeproxy

# 2. Run your custom binary directly with the same flags
.\kube-proxy.exe `
  --proxy-mode=kernelspace `
  --kubeconfig=c:\k\config `
  --hostname-override=aksnpwin000000 `
  --enable-dsr=true `
  --feature-gates="WinDSR=true,WinOverlay=false" `
  --metrics-bind-address=0.0.0.0:10249 `
  --v=3
```

This gives you live stderr output for immediate debugging.

### Option C: Build and Deploy from This Repo

```powershell
# Build with version info
$env:GOOS="windows"
$env:GOARCH="amd64"
go build -ldflags "-X k8s.io/component-base/version.gitVersion=v1.32.7" `
  -o kube-proxy.exe ./cmd

# Then follow Option A or B to deploy
```

### Important Notes

- **NSSM auto-restart:** NSSM will restart the service if it crashes. If you want
  to prevent this during debugging, either stop the service properly or set
  `nssm set Kubeproxy AppExit Default Exit`.
- **NodeResetScriptTask:** The scheduled task `NodeResetScriptTask` runs
  `windowsnodereset.ps1` on reboot. It will restart services using the original
  binary path (`c:\k\kube-proxy.exe`). Your in-place swap (Option A) survives
  reboots; a manual run (Option B) does not.
- **Rollback:** Simply restore the backup: `Copy-Item c:\k\kube-proxy.exe.bak c:\k\kube-proxy.exe`
  and restart with `nssm start Kubeproxy`.

---

## 7. Useful Diagnostic Commands

```powershell
# Check service status
nssm status Kubeproxy

# View NSSM parameters
nssm get Kubeproxy AppParameters

# Tail kube-proxy logs
Get-Content c:\k\kubeproxy.err.log -Tail 50 -Wait

# Check HNS load balancers
Get-HnsLoadBalancer | Measure-Object

# Check HNS endpoints
Get-HnsEndpoint | Select-Object Name, IPAddress, MacAddress

# Check HNS networks
Get-HnsNetwork | Select-Object Name, Type, Subnets

# Query kube-proxy metrics
Invoke-RestMethod http://localhost:10249/metrics

# Query kube-proxy health
Invoke-RestMethod http://localhost:10256/healthz
```

---

## 8. File Locations on the AKS Windows Node

| File | Path |
|------|------|
| kube-proxy binary | `c:\k\kube-proxy.exe` |
| kubeconfig | `c:\k\config` |
| Cluster config | `c:\k\kubeclusterconfig.json` |
| kube-proxy stderr log | `c:\k\kubeproxy.err.log` |
| kube-proxy stdout log | `c:\k\kubeproxy.out.log` |
| CSE bootstrap log | `c:\k\CustomDataSetupScript.log` |
| Node reset script | `c:\k\windowsnodereset.ps1` |
| NSSM binary | `c:\k\nssm.exe` |
