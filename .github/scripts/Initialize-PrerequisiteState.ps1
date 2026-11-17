[CmdletBinding()]
param(
    [string]$DeploymentName,
    [string]$OpenTofuCommand = 'tofu'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$infraDirectory = Join-Path $repositoryRoot 'infra'
$tfvars = Get-Content -LiteralPath (Join-Path $infraDirectory 'terraform.tfvars') -Raw
$settings = @{}
foreach ($settingName in 'resource_group_name', 'location') {
    $match = [regex]::Match($tfvars, "(?m)^$settingName[ \t]*=[ \t]*`"(?<value>[^`"]+)`"")
    if (-not $match.Success) { throw "$settingName must be a quoted string in infra/terraform.tfvars." }
    $settings[$settingName] = $match.Groups['value'].Value
}
if (-not $DeploymentName) { $DeploymentName = $settings.resource_group_name }
if ($DeploymentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') {
    throw 'DeploymentName must contain 1-80 letters, digits, underscores or hyphens, starting with a letter or digit.'
}
if ([string]::IsNullOrWhiteSpace($env:ARM_SUBSCRIPTION_ID)) { throw 'ARM_SUBSCRIPTION_ID is required.' }

function Invoke-StateAzure {
    param([string[]]$Arguments)
    $output = & az @Arguments --subscription $env:ARM_SUBSCRIPTION_ID --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "State storage command 'az $($Arguments[0]) $($Arguments[1])' failed with exit code $LASTEXITCODE." }
    if ($output) { return (($output | Out-String) | ConvertFrom-Json) }
}

$stateResourceGroup = "$DeploymentName-state"
$identity = "$($env:ARM_SUBSCRIPTION_ID)/$DeploymentName".ToLowerInvariant()
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
$storageAccount = "stlab$($hash.Substring(0, 19))"
$container = 'infra'
$key = "prereq/$DeploymentName.tfstate"

Invoke-StateAzure @('group', 'create', '--name', $stateResourceGroup, '--location', $settings.location) | Out-Null
$accounts = @(Invoke-StateAzure @('storage', 'account', 'list', '--resource-group', $stateResourceGroup))
if (@($accounts | Where-Object { $_.name -eq $storageAccount }).Count -eq 0) {
    Invoke-StateAzure @('storage', 'account', 'create', '--name', $storageAccount, '--resource-group', $stateResourceGroup, '--location', $settings.location, '--sku', 'Standard_LRS', '--kind', 'StorageV2') | Out-Null
}
Invoke-StateAzure @('storage', 'container-rm', 'create', '--resource-group', $stateResourceGroup, '--storage-account', $storageAccount, '--name', $container) | Out-Null

$backendArguments = @(
    "-backend-config=resource_group_name=$stateResourceGroup"
    "-backend-config=storage_account_name=$storageAccount"
    "-backend-config=container_name=$container"
    "-backend-config=key=$key"
)
$cachedBackendPath = Join-Path $infraDirectory '.terraform/terraform.tfstate'
$remoteInitialized = $false
if (Test-Path -LiteralPath $cachedBackendPath) {
    $cachedBackend = Get-Content -LiteralPath $cachedBackendPath -Raw | ConvertFrom-Json
    $remoteInitialized = $cachedBackend.backend.type -eq 'azurerm'
}
$initArguments = @("-chdir=$infraDirectory", 'init', '-input=false')
if (-not $remoteInitialized) {
    $initArguments += '-migrate-state'
    $localStatePath = Join-Path $infraDirectory 'terraform.tfstate'
    if ((Test-Path -LiteralPath $localStatePath) -and (Get-Item -LiteralPath $localStatePath).Length -gt 0) {
        $blob = Invoke-StateAzure @('storage', 'blob', 'exists', '--account-name', $storageAccount, '--container-name', $container, '--name', $key, '--auth-mode', 'key')
        if ($blob.exists) {
            throw "Local and remote state both exist. Reconcile them before migration; refusing to overwrite $container/$key."
        }
        $initArguments += '-force-copy'
    }
}
& $OpenTofuCommand @initArguments @backendArguments
if ($LASTEXITCODE -ne 0) { throw "OpenTofu backend initialization failed with exit code $LASTEXITCODE." }

Write-Host "State backend: $stateResourceGroup / $storageAccount / $container/$key"
if ($env:GITHUB_OUTPUT) {
    @(
        "deployment_name=$DeploymentName"
        "lab_resource_group=$($settings.resource_group_name)"
        "state_resource_group=$stateResourceGroup"
        "storage_account=$storageAccount"
        "state_key=$key"
    ) | Add-Content -LiteralPath $env:GITHUB_OUTPUT
}
