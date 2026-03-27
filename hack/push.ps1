param(
    [Parameter(Mandatory=$true, HelpMessage="Version tag, e.g. v1.32.7")]
    [string]$Version,

    [Parameter(Mandatory=$false)]
    [string]$Registry = "wcninternal"
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
Push-Location $RootDir

Write-Host "Logging in to ACR '$Registry' ..."
az acr login --name $Registry

Write-Host "Building and pushing windows-kubeproxy:$Version via ACR ..."
az acr build `
  --registry $Registry `
  --image "windows-kubeproxy:$Version" `
  --platform windows/amd64 `
  .

Pop-Location
Write-Host "Push complete: $Registry.azurecr.io/windows-kubeproxy:$Version"
