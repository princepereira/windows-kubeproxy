# Custom Kube-Proxy for Windows HPC DaemonSet

This guide covers building a custom Windows kube-proxy from this repository, packaging it in a container image, deploying it as an HPC DaemonSet, and replacing the default kube-proxy on the target nodes.

---

## 1. Build the Custom Kube-Proxy Binary

From a Linux / WSL / macOS machine, cross-compile for Windows:

```bash
cd ~/GoProjects/src/windows-kubeproxy

GOOS=windows GOARCH=amd64 go build \
  -ldflags "\
  -X k8s.io/component-base/version.gitVersion=v1.35.0-custom \
  -X k8s.io/component-base/version.gitCommit=$(git rev-parse HEAD) \
  -X k8s.io/component-base/version.gitTreeState=clean" \
  -o windows-kubeproxy.exe ./cmd
```

Verify the binary was produced:

```bash
file windows-kubeproxy.exe
# Expected: PE32+ executable (console) x86-64, for MS Windows
```

---

## 2. Build the Container Image

Create a `Dockerfile` (Windows Server Core based):

```dockerfile
# Use a Windows Server Core base matching your node OS version
ARG WINDOWS_VERSION=ltsc2022
FROM mcr.microsoft.com/windows/servercore:${WINDOWS_VERSION}

WORKDIR /kubeproxy

COPY windows-kubeproxy.exe .

ENTRYPOINT ["windows-kubeproxy.exe"]
```

Build and push the image:

```powershell
# From PowerShell on a Windows build host (or using Docker buildx for cross-platform)
docker build -t <your-registry>/windows-kubeproxy:v1.35.0 .
docker push <your-registry>/windows-kubeproxy:v1.35.0
```

> **Note:** The base image tag (`ltsc2022`, `ltsc2025`, etc.) must match the Windows version running on your HPC nodes.

---

## 3. Stop the Default Kube-Proxy on the Nodes

Before starting the custom proxy, disable the default kube-proxy to avoid conflicts.

### Option A: Remove nodes from the default kube-proxy DaemonSet (recommended)

Add a node label to your HPC nodes and use a `nodeAffinity` anti-affinity rule on the default `kube-proxy` DaemonSet so it no longer schedules on those nodes:

```bash
# Label the HPC Windows nodes
kubectl label nodes <node-name> kubeproxy=custom

# Patch the default kube-proxy DaemonSet to skip nodes with the custom label
kubectl -n kube-system patch daemonset kube-proxy --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/affinity",
    "value": {
      "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
          "nodeSelectorTerms": [
            {
              "matchExpressions": [
                {
                  "key": "kubeproxy",
                  "operator": "NotIn",
                  "values": ["custom"]
                }
              ]
            }
          ]
        }
      }
    }
  }
]'
```

### Option B: Delete the default kube-proxy DaemonSet entirely

Only use this if **all** nodes will run the custom proxy:

```bash
kubectl -n kube-system delete daemonset kube-proxy
```

### Option C: Stop and disable the service on the node (manual / non-production)

The default kube-proxy is registered as a Windows service, so simply stopping it is not enough — it will restart automatically on node reboot. You must also **disable** the service to prevent it from starting again.

The default kube-proxy is managed by [NSSM (Non-Sucking Service Manager)](https://nssm.cc/), which wraps it as a Windows service and will automatically restart it on failure or reboot. You must use `nssm` commands to stop and remove (or disable) it.

On the Windows node via PowerShell:

```powershell
# Stop the NSSM-managed kube-proxy service
nssm stop kubeproxy

# Remove the service entirely so it cannot restart on reboot
nssm remove kubeproxy confirm

# Verify it is gone
nssm status kubeproxy
# Expected: SERVICE_NOT_FOUND or error indicating the service does not exist
```

If you prefer to **disable** instead of removing (to make rollback easier):

```powershell
# Stop the service
nssm stop kubeproxy

# Set startup type to disabled via nssm
nssm set kubeproxy Start SERVICE_DISABLED

# Verify
nssm get kubeproxy Start
# Expected: SERVICE_DISABLED
```

> **To re-enable later:**
> ```powershell
> nssm set kubeproxy Start SERVICE_AUTO_START
> nssm start kubeproxy
> ```

---

## 4. Deploy the Custom Kube-Proxy as an HPC DaemonSet

The DaemonSet uses two init containers and a main container:
1. **stop-default-kubeproxy** — Stops and disables the default NSSM-managed `kubeproxy` service
2. **install-kubeproxy-service** — Copies the custom binary to `c:\k\`, registers it as a Windows service via NSSM with auto-start, restart-on-failure, and log rotation
3. **main container** — Tails the service log file to stdout for `kubectl logs` access

Create the DaemonSet manifest (`deploy/windows-kubeproxy-daemonset.yaml`):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: windows-kubeproxy
  namespace: kube-system
  labels:
    app: windows-kubeproxy
spec:
  selector:
    matchLabels:
      app: windows-kubeproxy
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: windows-kubeproxy
    spec:
      nodeSelector:
        kubernetes.io/os: windows
      tolerations:
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
        - key: os
          value: "windows"
          effect: NoSchedule
      serviceAccountName: kube-proxy
      hostNetwork: true
      initContainers:
        - name: stop-default-kubeproxy
          image: mcr.microsoft.com/windows/servercore:ltsc2022
          command:
            - powershell.exe
          args:
            - -ExecutionPolicy
            - Bypass
            - -NoProfile
            - -Command
            - >-
              $ErrorActionPreference = 'Continue';
              $nssm = 'c:\k\nssm.exe';
              Write-Host 'Stopping default kubeproxy service...';
              & $nssm stop kubeproxy 2>&1 | Out-Null;
              & $nssm set kubeproxy Start SERVICE_DISABLED 2>&1 | Out-Null;
              Write-Host 'Default kubeproxy stopped and disabled'
          securityContext:
            windowsOptions:
              hostProcess: true
              runAsUserName: "NT AUTHORITY\\SYSTEM"
        - name: install-kubeproxy-service
          image: <your-registry>/windows-kubeproxy:v1.32.7
          command:
            - powershell.exe
          args:
            - -ExecutionPolicy
            - Bypass
            - -NoProfile
            - -Command
            - >-
              $ErrorActionPreference = 'Continue';
              $nssm = 'c:\k\nssm.exe';
              $src = Join-Path $env:CONTAINER_SANDBOX_MOUNT_POINT 'kubeproxy\windows-kubeproxy.exe';
              $dst = 'c:\k\windows-kubeproxy.exe';
              Write-Host "Copying $src to $dst";
              Copy-Item -Path $src -Destination $dst -Force;
              if (!(Test-Path $dst)) { Write-Host 'ERROR: Copy failed'; exit 1 };
              Write-Host 'Copy succeeded';
              $svcName = 'windows-kubeproxy';
              & $nssm stop $svcName 2>&1 | Out-Null;
              & $nssm remove $svcName confirm 2>&1 | Out-Null;
              Start-Sleep -Seconds 2;
              Write-Host "Installing $svcName via NSSM...";
              & $nssm install $svcName $dst;
              & $nssm set $svcName AppParameters "--v=$env:LOG_LEVEL --proxy-mode=kernelspace --hostname-override=$env:NODE_NAME --kubeconfig=$env:KUBECONFIG_PATH --enable-dsr=$env:ENABLE_DSR --feature-gates=$env:FEATURE_GATES --root-hnsendpoint-name=$env:ROOT_HNS_ENDPOINT_NAME";
              & $nssm set $svcName AppEnvironmentExtra "KUBE_NETWORK=$env:KUBE_NETWORK";
              & $nssm set $svcName Start SERVICE_AUTO_START;
              & $nssm set $svcName AppRestartDelay 5000;
              & $nssm set $svcName AppStdout 'c:\k\windows-kubeproxy.log';
              & $nssm set $svcName AppStderr 'c:\k\windows-kubeproxy.err.log';
              & $nssm set $svcName AppRotateFiles 1;
              & $nssm set $svcName AppRotateBytes 10485760;
              & $nssm start $svcName;
              Write-Host "$svcName service installed and started via NSSM"
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: KUBE_NETWORK
              value: "azure"
            - name: LOG_LEVEL
              value: "3"
            - name: KUBECONFIG_PATH
              value: "c:\\k\\config"
            - name: ENABLE_DSR
              value: "true"
            - name: FEATURE_GATES
              value: "WinDSR=true,WinOverlay=false"
            - name: ROOT_HNS_ENDPOINT_NAME
              value: "cbr0"
          securityContext:
            windowsOptions:
              hostProcess: true
              runAsUserName: "NT AUTHORITY\\SYSTEM"
      containers:
        - name: windows-kubeproxy
          image: mcr.microsoft.com/windows/servercore:ltsc2022
          command:
            - powershell.exe
          args:
            - -ExecutionPolicy
            - Bypass
            - -NoProfile
            - -Command
            - >-
              $logFile = 'c:\k\windows-kubeproxy.err.log';
              while (!(Test-Path $logFile)) { Start-Sleep -Seconds 2 };
              Get-Content -Path $logFile -Wait -Tail 0
          securityContext:
            windowsOptions:
              hostProcess: true
              runAsUserName: "NT AUTHORITY\\SYSTEM"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: kube-config
          hostPath:
            path: c:\k
            type: Directory
```

Apply the manifest:

```bash
kubectl apply -f deploy/windows-kubeproxy-daemonset.yaml
```

---

## 5. Verify the Deployment

```bash
# Check DaemonSet rollout status
kubectl -n kube-system rollout status daemonset/windows-kubeproxy

# Verify pods are running on the expected nodes
kubectl -n kube-system get pods -l app=windows-kubeproxy -o wide

# View live logs via kubectl (tailed from the NSSM service log)
kubectl -n kube-system logs -f <pod-name>

# Check the Windows service status on a node
Get-Service windows-kubeproxy

# Logs on disk are also available at:
#   c:\k\windows-kubeproxy.log       (stdout)
#   c:\k\windows-kubeproxy.err.log   (stderr)
```

---

## Summary of Steps

| Step | Action |
|------|--------|
| 1 | Build the custom `windows-kubeproxy.exe` from this repo |
| 2 | Package the binary into a Windows container image |
| 3 | Init container stops the default NSSM-managed kube-proxy service |
| 4 | Init container copies the binary, registers it as a Windows service via NSSM with auto-start, restart-on-failure, and log rotation |
| 5 | Main container tails the service log to stdout for `kubectl logs` access |
| 6 | Verify pods are running and the `windows-kubeproxy` Windows service is active |
