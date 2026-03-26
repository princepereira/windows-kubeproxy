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

Create the DaemonSet manifest (`custom-kube-proxy-daemonset.yaml`):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: custom-kube-proxy
  namespace: kube-system
  labels:
    app: custom-kube-proxy
spec:
  selector:
    matchLabels:
      app: custom-kube-proxy
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: custom-kube-proxy
    spec:
      # Only schedule on HPC Windows nodes labelled with kubeproxy=custom
      nodeSelector:
        kubernetes.io/os: windows
        kubeproxy: custom
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
        # Stop the default NSSM-managed kube-proxy before starting the custom one
        - name: stop-default-kubeproxy
          image: mcr.microsoft.com/windows/servercore:ltsc2022
          command:
            - powershell.exe
          args:
            - -Command
            - |
              $svc = Get-Service -Name kubeproxy -ErrorAction SilentlyContinue;
              if ($svc) {
                Write-Host 'Stopping default kubeproxy NSSM service...';
                nssm stop kubeproxy;
                nssm set kubeproxy Start SERVICE_DISABLED;
                Write-Host 'Default kubeproxy service stopped and disabled.';
              } else {
                Write-Host 'No default kubeproxy service found, skipping.';
              }
          securityContext:
            windowsOptions:
              hostProcess: true
              runAsUserName: "NT AUTHORITY\\SYSTEM"
      containers:
        - name: windows-kubeproxy
          image: <your-registry>/windows-kubeproxy:v1.35.0
          command:
            - windows-kubeproxy.exe
          args:
            - --v=$(LOG_LEVEL)
            - --proxy-mode=kernelspace
            - --hostname-override=$(NODE_NAME)
            - --kubeconfig=$(KUBECONFIG_PATH)
            - --enable-dsr=$(ENABLE_DSR)
            - --feature-gates=$(FEATURE_GATES)
            - --root-hnsendpoint-name=$(ROOT_HNS_ENDPOINT_NAME)
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
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
          volumeMounts:
            - name: kube-config
              mountPath: c:\k
              readOnly: true
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
kubectl apply -f custom-kube-proxy-daemonset.yaml
```

---

## 5. Verify the Deployment

```bash
# Check DaemonSet rollout status
kubectl -n kube-system rollout status daemonset/custom-kube-proxy

# Verify pods are running on the expected HPC nodes
kubectl -n kube-system get pods -l app=custom-kube-proxy -o wide

# Check logs of a specific pod
kubectl -n kube-system logs -l app=custom-kube-proxy --tail=50

# Confirm the custom version is running
kubectl -n kube-system exec <pod-name> -- windows-kubeproxy.exe --version
```

---

## Summary of Steps

| Step | Action |
|------|--------|
| 1 | Build the custom `windows-kubeproxy.exe` from this repo |
| 2 | Package the binary into a Windows container image |
| 3 | DaemonSet init container auto-stops the default NSSM kube-proxy |
| 4 | Deploy windows-kubeproxy as a HostProcess DaemonSet (env-var configurable) |
| 5 | Verify pods are running and proxying traffic correctly |
