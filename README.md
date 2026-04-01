# windows-kubeproxy
Windows kube-proxy enables Kubernetes Services on Windows nodes by managing networking rules, load balancing, and traffic routing through Windows HNS. It ensures Windows workloads integrate seamlessly with Kubernetes networking alongside Linux nodes.

## Setup Development Environment

### Sync Staging Directory with Kubernetes (From WSL/Linux)

```
git clone https://github.com/kubernetes/kubernetes.git
cd kubernetes
git checkout master   # or v1.32.x
rsync -av staging/ ~/GoProjects/src/windows-kubeproxy/staging/
```

### Sync Staging Directory with Kubernetes (From Windows Powershell)

```
git clone https://github.com/kubernetes/kubernetes.git
cd kubernetes
git checkout master   # or v1.32.x
robocopy staging "$HOME\GoProjects\src\windows-kubeproxy\staging" /E /FFT /Z /MT:16
```

### Update Vendor Dependencies
After syncing the staging directory, update the vendor directory to ensure all required packages are fully vendored:
```
go mod tidy
go mod vendor
```

### Build From Linux / WSL / macOS
```
GOOS=windows GOARCH=amd64 go build -o kube-proxy.exe ./cmd
```

### Build From Windows PowerShell
```
$env:GOOS="windows"
$env:GOARCH="amd64"

go build -o kube-proxy.exe ./cmd
```

### Build Specific Kubeproxy version From Linux / WSL / macOS
```
GOOS=windows GOARCH=amd64 go build \
  -ldflags "\
  -X k8s.io/component-base/version.gitVersion=v1.32.7 \
  -X k8s.io/component-base/version.gitCommit=$(git rev-parse HEAD) \
  -X k8s.io/component-base/version.gitTreeState=clean" \
  -o windows-kubeproxy.exe ./cmd
```

### Build Specific Kubeproxy version From Powershell
```powershell
$env:GOOS="windows"
$env:GOARCH="amd64"

go build `
  -ldflags `
  "-X k8s.io/component-base/version.gitVersion=v1.32.7 `
  -X k8s.io/component-base/version.gitCommit=$(git rev-parse HEAD) `
  -X k8s.io/component-base/version.gitTreeState=clean" `
  -o windows-kubeproxy.exe ./cmd
```

## Deployment

### 1. Build & Push the Windows Container Image via ACR (No Local Docker Needed)
```
az acr login --name wcninternal
az acr build --registry wcninternal --image windows-kubeproxy:v1.32.7 --platform windows/amd64 .
```

### 2. Attach ACR to AKS

```powershell
az aks update -n <ClusterName> -g <ResourceGroup> --attach-acr wcninternal
```

### 3. Deploy the DaemonSet

```powershell
kubectl apply -f deploy/windows-kubeproxy-daemonset.yaml
```

To update an existing deployment (e.g. after changing the image or configuration):

```powershell
kubectl replace --force -f deploy/windows-kubeproxy-daemonset.yaml
```

The DaemonSet will:
1. Stop and disable the default NSSM-managed `kubeproxy` service on each Windows node
2. Copy the custom `windows-kubeproxy.exe` to `c:\k\` and register it as a Windows service via NSSM
3. Start the `windows-kubeproxy` service with auto-start and auto-restart on failure
4. Tail the service logs to stdout so they are accessible via `kubectl logs`

### 4. Verify the Deployment

```powershell
# Check pods are running
kubectl get pods -n kube-system -l app=windows-kubeproxy -o wide

# View live logs
kubectl logs -f <pod-name> -n kube-system

# Check the Windows service status on a node
Get-Service windows-kubeproxy

# Logs on disk are also available at:
#   c:\k\windows-kubeproxy.log       (stdout)
#   c:\k\windows-kubeproxy.err.log   (stderr)
```


