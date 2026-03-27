param(
    [Parameter(Mandatory=$true, HelpMessage="Version tag, e.g. v1.32.7")]
    [string]$Version
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
Push-Location $RootDir

Write-Host "Building windows-kubeproxy.exe $Version ..."

$env:GOOS = "windows"
$env:GOARCH = "amd64"

$gitCommit = git rev-parse HEAD

go build `
  -ldflags "`
  -X k8s.io/component-base/version.gitVersion=$Version `
  -X k8s.io/component-base/version.gitCommit=$gitCommit `
  -X k8s.io/component-base/version.gitTreeState=clean" `
  -o windows-kubeproxy.exe ./cmd

Pop-Location
Write-Host "Build complete: windows-kubeproxy.exe ($Version)"
