# Release Process for windows-kubeproxy

This document describes how to create a new release of windows-kubeproxy aligned with an upstream Kubernetes release.

## Versioning Strategy

windows-kubeproxy follows the same version scheme as upstream Kubernetes:

| Kubernetes Release | windows-kubeproxy Tag |
|---|---|
| v1.35.0 | v1.35.0 |
| v1.35.1 | v1.35.1 |
| v1.36.0-alpha.1 | v1.36.0-alpha.1 |

The version is embedded at build time via `-ldflags` using `k8s.io/component-base/version`.

## Release Checklist

### 1. Identify the target Kubernetes version

Determine the upstream tag or release branch to sync against:

```bash
# For a stable release
TARGET_VERSION=v1.35.0

# For tracking a release branch
TARGET_BRANCH=release-1.35
```

### 2. Sync the staging directory

Clone (or update) the upstream Kubernetes repo and check out the target version:

**Linux / WSL / macOS:**
```bash
cd /path/to/kubernetes
git fetch --tags
git checkout $TARGET_VERSION
rsync -av --delete staging/ /path/to/windows-kubeproxy/staging/
```

**Windows PowerShell:**
```powershell
cd C:\path\to\kubernetes
git fetch --tags
git checkout $TARGET_VERSION
robocopy staging "C:\path\to\windows-kubeproxy\staging" /E /FFT /Z /MT:16 /MIR
```

> **Note:** Use `--delete` (rsync) or `/MIR` (robocopy) to remove staging files that were deleted upstream.

### 3. Sync the winkernel proxy package

Copy the upstream winkernel source to the local package:

**Linux / WSL / macOS:**
```bash
rsync -av --delete \
  /path/to/kubernetes/pkg/proxy/winkernel/ \
  /path/to/windows-kubeproxy/pkg/winkernel/
```

**Windows PowerShell:**
```powershell
robocopy "C:\path\to\kubernetes\pkg\proxy\winkernel" `
  "C:\path\to\windows-kubeproxy\pkg\winkernel" /E /FFT /Z /MIR
```

After copying, update import paths in `pkg/winkernel/` from `k8s.io/kubernetes/pkg/proxy/winkernel` to `github.com/windows-kubeproxy/pkg/winkernel` if needed.

### 4. Sync the kube-proxy app (cmd/) files

Compare and update `cmd/app/` against upstream:

```bash
# Diff against upstream
diff /path/to/kubernetes/cmd/kube-proxy/app/server_windows.go \
     /path/to/windows-kubeproxy/cmd/app/server_windows.go
```

Manually apply relevant changes, keeping the local import paths (`github.com/windows-kubeproxy/pkg/winkernel`).

### 5. Update go.mod

Update the `k8s.io/kubernetes` version and any changed dependencies in `go.mod`:

```bash
# Update the kubernetes dependency version marker
# Edit go.mod: require k8s.io/kubernetes v1.XX.X

# Tidy and re-vendor
go mod tidy
go mod vendor
```

### 6. Verify the build

```bash
# Linux / WSL / macOS
GOOS=windows GOARCH=amd64 go build -o kube-proxy.exe ./cmd

# Windows PowerShell
go build -o kube-proxy.exe ./cmd
```

### 7. Run tests

```bash
go test ./pkg/winkernel/...
```

### 8. Commit and tag

```bash
git add -A
git commit -m "Sync with Kubernetes $TARGET_VERSION"
git tag -a $TARGET_VERSION -m "Release $TARGET_VERSION (synced with Kubernetes $TARGET_VERSION)"
```

### 9. Push

```bash
git push origin main
git push origin $TARGET_VERSION
```

## Tracking Release Branches

For ongoing patch releases (e.g., `release-1.35`), create a corresponding branch:

```bash
# After the initial v1.35.0 release
git checkout -b release-1.35
git push origin release-1.35
```

When Kubernetes publishes a patch (e.g., v1.35.1):

1. Check out the `release-1.35` branch
2. Repeat steps 2-9 above targeting `v1.35.1`

## Build with Embedded Version Info

To produce a binary that reports the correct version via `kube-proxy --version`:

**Linux / WSL / macOS:**
```bash
GOOS=windows GOARCH=amd64 go build \
  -ldflags "\
    -X k8s.io/component-base/version.gitVersion=$TARGET_VERSION \
    -X k8s.io/component-base/version.gitCommit=$(git rev-parse HEAD) \
    -X k8s.io/component-base/version.gitTreeState=clean \
    -X k8s.io/component-base/version.buildDate=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  -o kube-proxy.exe ./cmd
```

**Windows PowerShell:**
```powershell
$commit = git rev-parse HEAD
$date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

go build -ldflags `
  "-X k8s.io/component-base/version.gitVersion=$TARGET_VERSION `
   -X k8s.io/component-base/version.gitCommit=$commit `
   -X k8s.io/component-base/version.gitTreeState=clean `
   -X k8s.io/component-base/version.buildDate=$date" `
  -o kube-proxy.exe ./cmd
```

## Quick Reference

| Step | Command |
|---|---|
| Sync staging | `rsync -av --delete` / `robocopy /MIR` |
| Sync winkernel | `rsync -av --delete` / `robocopy /MIR` |
| Update deps | `go mod tidy && go mod vendor` |
| Build | `go build -o kube-proxy.exe ./cmd` |
| Test | `go test ./pkg/winkernel/...` |
| Tag | `git tag -a vX.Y.Z` |
