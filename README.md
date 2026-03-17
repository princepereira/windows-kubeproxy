# windows-kubeproxy
Windows kube-proxy enables Kubernetes Services on Windows nodes by managing networking rules, load balancing, and traffic routing through Windows HNS. It ensures Windows workloads integrate seamlessly with Kubernetes networking alongside Linux nodes.

# How to Set Staging Directory Sync with Kubernetes (From WSL/Linux)

```
git clone https://github.com/kubernetes/kubernetes.git
cd kubernetes
git checkout master   # or v1.32.x
rsync -av staging/ ~/GoProjects/src/windows-kubeproxy/staging/
```

# How to Set Staging Directory Sync with Kubernetes (From Windows Powershell)

```
git clone https://github.com/kubernetes/kubernetes.git
cd kubernetes
git checkout master   # or v1.32.x
robocopy staging "$HOME\GoProjects\src\windows-kubeproxy\staging" /E /FFT /Z /MT:16
```

# How to Update Vendor Dependencies
After syncing the staging directory, update the vendor directory to ensure all required packages are fully vendored:
```
go mod tidy
go mod vendor
```

# How to Build From Linux / WSL / macOS
```
GOOS=windows GOARCH=amd64 go build -o kube-proxy.exe ./cmd
```

# How to Build From Windows PowerShell
```
$env:GOOS="windows"
$env:GOARCH="amd64"

go build -o kube-proxy.exe ./cmd
```

# How to Build Specific Kubeproxy version From Linux / WSL / macOS
```
GOOS=windows GOARCH=amd64 go build \
  -ldflags "\
  -X k8s.io/component-base/version.gitVersion=v1.32.0-custom \
  -X k8s.io/component-base/version.gitCommit=$(git rev-parse HEAD) \
  -X k8s.io/component-base/version.gitTreeState=clean" \
  -o kube-proxy.exe ./cmd
```


