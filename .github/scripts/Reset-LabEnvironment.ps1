#Requires -Version 7.0
<#
.SYNOPSIS
    Resets the lab foundation to nothing so Deploy Packer prerequisites can be tested from a clean slate.

.DESCRIPTION
    Deleting the lab resource group by hand leaves things behind that make the next deployment fail. This script removes them in the order that works:
      1. Diagnostic settings on the resources that keep them after the group is gone (Bastion and the AVD host pool, application group and workspace).
         They can only be removed while the resource still exists, and the next deployment fails with "already exists" if they survive.
      2. The Log Analytics workspace, permanently, so no soft-deleted workspace is recovered by the next deployment.
      3. The lab resource group.
      4. Any Key Vault that was in the group, purged. A vault with purge protection cannot be purged; the script reports the date its name is free again.
      5. Subscription-scope role assignments held by the managed identities of the deleted resources.
      6. The state resource group (unless -KeepState).
      7. In the GitHub repository (when -Repository is given): the registered runner and the repository variables the deployment sets. Secrets are never touched.
    It refuses to run when student resource groups or LabUser accounts exist; use the setup script's -Destroy for a populated lab.

.PARAMETER DeploymentName
    State deployment name; empty uses resource_group_name from infra/terraform.tfvars (same default as the state steps in phase0-prereqs.yml).

.PARAMETER Repository
    GitHub owner/repo whose runner and variables should be cleared, for example BenTheCloudGuy/bentest-immersion-day.

.PARAMETER KeepState
    Keep the <deploymentName>-state resource group.

.PARAMETER WhatIf
    List what would be removed and change nothing.

.PARAMETER Force
    Skip the typed confirmation.
#>
[CmdletBinding()]
param(
    [string]$DeploymentName,
    [string]$Repository,
    [switch]$KeepState,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tfvars = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra/terraform.tfvars') -Raw
function Get-TfVarString([string]$Name) {
    $match = [regex]::Match($tfvars, "(?m)^$Name[ \t]*=[ \t]*`"(?<value>[^`"]+)`"")
    if (-not $match.Success) { throw "$Name must be a quoted string in infra/terraform.tfvars." }
    return $match.Groups['value'].Value
}
$resourceGroup = Get-TfVarString 'resource_group_name'
$subscriptionId = Get-TfVarString 'subscription_id'
if (-not $DeploymentName) { $DeploymentName = $resourceGroup }
$stateResourceGroup = "$DeploymentName-state"
$diagnosticSettingName = 'lab-to-log-analytics'
$runnerName = 'msftlabs-runner'
$repositoryVariables = 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_LOCATION', 'GALLERY_RESOURCE_GROUP', 'GALLERY_NAME', 'IMAGE_DEFINITION_NAME', 'REPLICATION_REGIONS', 'VNET_NAME', 'VNET_RESOURCE_GROUP', 'VNET_SUBNET_NAME', 'RESOURCE_TAGS'
$diagnosticTypes = 'Microsoft.Network/bastionHosts', 'Microsoft.DesktopVirtualization/hostPools', 'Microsoft.DesktopVirtualization/applicationGroups', 'Microsoft.DesktopVirtualization/workspaces', 'Microsoft.Network/networkSecurityGroups'

function Write-Step([string]$Message) { Write-Host "$([DateTime]::UtcNow.ToString('HH:mm:ss')) $Message" }

# Runs az and returns parsed JSON, or $null for no output. Failures throw unless -AllowFailure.
function Invoke-AzJson {
    param([string[]]$Arguments, [switch]$AllowFailure, [switch]$NoSubscription)
    $scope = if ($NoSubscription) { @() } else { @('--subscription', $subscriptionId) }
    $output = & az @Arguments @scope --only-show-errors --output json 2>&1
    $text = ($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments[0]) $($Arguments[1]) failed: $(($output | Out-String).Trim())"
    }
    if ($text) { return ($text | ConvertFrom-Json) }
}

function Test-GroupExists([string]$Name) {
    return (& az group exists --name $Name --subscription $subscriptionId --only-show-errors | Out-String).Trim() -eq 'true'
}

function Wait-GroupDeleted([string]$Name) {
    $deadline = (Get-Date).AddMinutes(45)
    while (Test-GroupExists $Name) {
        if ((Get-Date) -gt $deadline) { throw "Resource group $Name was not deleted within 45 minutes." }
        Write-Step "Waiting for resource group $Name to finish deleting..."
        Start-Sleep -Seconds 30
    }
}

$account = Invoke-AzJson @('account', 'show')
if ($account.id -ne $subscriptionId) { throw "Azure CLI is on subscription $($account.id) but infra/terraform.tfvars targets $subscriptionId. Run az account set first." }
Write-Step "Signed in as $($account.user.name) on $($account.name)."

# Guard: a populated lab is reset with the setup script's -Destroy.
$studentGroups = @(Invoke-AzJson @('group', 'list') | Where-Object { $_.name -like 'LAB-*' -and $_.tags -and $_.tags.PSObject.Properties['LabUser'] })
$labUsers = @(Invoke-AzJson @('ad', 'user', 'list', '--display-name', 'LabUser') -AllowFailure -NoSubscription | Where-Object { $_.displayName -match '^LabUser\d{3}$' })
if ($studentGroups.Count -gt 0 -or $labUsers.Count -gt 0) {
    throw "Student resource groups ($($studentGroups.Name -join ', ')) or LabUser accounts ($($labUsers.displayName -join ', ')) exist. Use ./scripts/Setup-LabEnvironment.ps1 -Destroy for a populated lab."
}

$groupExists = Test-GroupExists $resourceGroup
$resources = @()
if ($groupExists) { $resources = @(Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup)) }
$stateExists = Test-GroupExists $stateResourceGroup

$diagnosticTargets = @($resources | Where-Object { $_.type -in $diagnosticTypes })
$workspaces = @($resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces' })
$vaults = @($resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults' })
$identityIds = @($resources | Where-Object { $_.PSObject.Properties['identity'] -and $_.identity -and $_.identity.PSObject.Properties['principalId'] -and $_.identity.principalId } | ForEach-Object { $_.identity.principalId })

Write-Step 'Plan:'
Write-Step "  resource group $resourceGroup : $(if ($groupExists) { "delete ($($resources.Count) resources)" } else { 'not present' })"
Write-Step "  diagnostic settings '$diagnosticSettingName' on $($diagnosticTargets.Count) resource(s) first"
Write-Step "  Log Analytics workspaces to delete permanently: $(if ($workspaces) { $workspaces.name -join ', ' } else { 'none' })"
Write-Step "  Key Vaults to purge: $(if ($vaults) { $vaults.name -join ', ' } else { 'none' })"
Write-Step "  subscription role assignments for $($identityIds.Count) managed identit(ies)"
Write-Step "  state resource group $stateResourceGroup : $(if (-not $stateExists) { 'not present' } elseif ($KeepState) { 'kept' } else { 'delete' })"
Write-Step "  GitHub repository: $(if ($Repository) { "$Repository (runner $runnerName and $($repositoryVariables.Count) variables)" } else { 'skipped (no -Repository)' })"
if ($WhatIf) { Write-Step 'WhatIf: nothing was changed.'; return }

if (-not $Force) {
    $typed = Read-Host "Type the resource group name '$resourceGroup' to confirm"
    if ($typed -cne $resourceGroup) { throw 'Cancelled: the confirmation did not match.' }
}

if ($groupExists) {
    foreach ($target in $diagnosticTargets) {
        & az monitor diagnostic-settings delete --name $diagnosticSettingName --resource $target.id --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not delete the diagnostic setting on $($target.name)." }
        Write-Step "Cleared diagnostic setting on $($target.name)."
    }
    foreach ($workspace in $workspaces) {
        & az monitor log-analytics workspace delete --resource-group $resourceGroup --workspace-name $workspace.name --force true --yes --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not permanently delete the Log Analytics workspace $($workspace.name)." }
        Write-Step "Permanently deleted Log Analytics workspace $($workspace.name)."
    }
    & az group delete --name $resourceGroup --yes --no-wait --subscription $subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not start deleting $resourceGroup." }
    Wait-GroupDeleted $resourceGroup
    Write-Step "Deleted resource group $resourceGroup."
}

foreach ($vault in $vaults) {
    $deleted = @(Invoke-AzJson @('keyvault', 'list-deleted') | Where-Object { $_.name -eq $vault.name })
    if ($deleted.Count -eq 0) { Write-Step "Key Vault $($vault.name) is not soft-deleted."; continue }
    & az keyvault purge --name $vault.name --location $vault.location --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Step "Purged Key Vault $($vault.name)." }
    else { Write-Step "WARNING: Key Vault $($vault.name) cannot be purged (purge protection); its name is held until $($deleted[0].properties.scheduledPurgeDate)." }
}

if ($identityIds.Count -gt 0) {
    $assignments = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', "/subscriptions/$subscriptionId") | Where-Object { $_.scope -eq "/subscriptions/$subscriptionId" -and $_.principalId -in $identityIds })
    foreach ($assignment in $assignments) {
        & az role assignment delete --ids $assignment.id --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not delete role assignment $($assignment.id)." }
        Write-Step "Removed $($assignment.roleDefinitionName) role assignment for deleted identity $($assignment.principalId)."
    }
}

if ($stateExists -and -not $KeepState) {
    & az group delete --name $stateResourceGroup --yes --no-wait --subscription $subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not start deleting $stateResourceGroup." }
    Wait-GroupDeleted $stateResourceGroup
    Write-Step "Deleted state resource group $stateResourceGroup."
}

if ($Repository) {
    $runners = (& gh api "repos/$Repository/actions/runners" --jq '[.runners[] | {id, name}]' | Out-String | ConvertFrom-Json)
    foreach ($runner in @($runners | Where-Object { $_.name -eq $runnerName })) {
        & gh api -X DELETE "repos/$Repository/actions/runners/$($runner.id)"
        if ($LASTEXITCODE -ne 0) { throw "Could not remove runner $($runner.name) from $Repository." }
        Write-Step "Removed runner $($runner.name) from $Repository."
    }
    $existing = @(& gh variable list --repo $Repository --json name --jq '.[].name')
    foreach ($name in $repositoryVariables | Where-Object { $_ -in $existing }) {
        & gh variable delete $name --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "Could not delete repository variable $name." }
        Write-Step "Deleted repository variable $name."
    }
}

Write-Step 'Verification:'
Write-Step "  resource group $resourceGroup exists: $(Test-GroupExists $resourceGroup)"
Write-Step "  state resource group $stateResourceGroup exists: $(Test-GroupExists $stateResourceGroup)"
foreach ($vault in $vaults) {
    $still = @(Invoke-AzJson @('keyvault', 'list-deleted') | Where-Object { $_.name -eq $vault.name })
    Write-Step "  Key Vault $($vault.name) still soft-deleted: $($still.Count -gt 0)"
}
$deletedWorkspaces = @(Invoke-AzJson @('monitor', 'log-analytics', 'workspace', 'list-deleted-workspaces') -AllowFailure | Where-Object { $_.resourceGroup -ieq $resourceGroup })
Write-Step "  soft-deleted Log Analytics workspaces from $resourceGroup : $($deletedWorkspaces.Count)"
Write-Step 'Reset complete.'
