#Requires -Version 7.0
<#
.SYNOPSIS
    Grants the Microsoft Graph application permissions the lab deployment needs to create Entra lab users and groups, set the Temporary Access Pass (TAP) policy and issue TAPs.

.DESCRIPTION
    Run ONCE by a Global Administrator (or Privileged Role Administrator) signed in with 'az login' as yourself. It grants the seven Graph application roles below to the lab service principal. A service principal cannot grant these to itself, so this cannot run inside a workflow; the Phase 2 workflow checks the roles in its own first steps.
    This is the same grant the setup script's ServicePrincipal stage performs; the setup script skips that stage when ARM_* credentials already exist, so a pre-staged service principal never receives it.

.PARAMETER ClientId
    Application (client) ID of the lab service principal. Defaults to $env:ARM_CLIENT_ID.

.PARAMETER WhatIf
    List the roles that would be granted and change nothing.

.EXAMPLE
    az login
    ./.github/scripts/Grant-LabGraphPermissions.ps1 -ClientId <application-id>
#>
[CmdletBinding()]
param(
    [string]$ClientId = $env:ARM_CLIENT_ID,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphRoles = [ordered]@{
    'User.ReadWrite.All'                     = '741f803b-c850-494e-b5df-cde7c675a1ca'
    'Group.ReadWrite.All'                    = '62a82d76-70ea-41e2-9197-370581804d09'
    'Domain.Read.All'                        = 'dbb9058a-0e50-45d7-ae91-66909b5d4664'
    'Application.Read.All'                   = '9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30'
    'Policy.Read.All'                        = '246dd0d5-5bd0-4def-940b-0421030a5b68'
    'Policy.ReadWrite.AuthenticationMethod'  = '29c18626-4985-4dcd-85c0-193eef327366'
    'UserAuthenticationMethod.ReadWrite.All' = '50483e42-d915-4231-9639-7fdb7fd190e5'
}

# Runs az, returns parsed JSON (or $null when there is no output), and throws with az's own message on failure.
function Invoke-Az {
    param([string[]]$Arguments)
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors --output json 2>$errorFile
        $code = $LASTEXITCODE
        $errorText = (Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) { throw "az $($Arguments[0]) $($Arguments[1]) failed: $("$errorText".Trim())" }
    $text = ($output | Out-String).Trim()
    if ($text) { return ($text | ConvertFrom-Json) }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'The Azure CLI (az) was not found on PATH.' }

if (-not $ClientId) { throw 'Pass -ClientId (the lab service principal application ID) or set ARM_CLIENT_ID.' }
$account = Invoke-Az @('account', 'show')
if ($account.user.type -eq 'servicePrincipal') { throw 'You are signed in as a service principal, which cannot grant Graph roles. Run az logout, then az login as a Global Administrator.' }
Write-Host "Signed in as $($account.user.name) (tenant $($account.tenantId))."

$servicePrincipal = Invoke-Az @('ad', 'sp', 'show', '--id', $ClientId)
$graphObjectId = (Invoke-Az @('ad', 'sp', 'show', '--id', $graphAppId)).id
Write-Host "Target: $($servicePrincipal.displayName) (application $($servicePrincipal.appId), object $($servicePrincipal.id))."

$assignmentsUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipal.id)/appRoleAssignments"
$existing = @((Invoke-Az @('rest', '--method', 'GET', '--url', $assignmentsUrl)).value | ForEach-Object { $_.appRoleId })
$missing = @($graphRoles.Keys | Where-Object { $graphRoles[$_] -notin $existing })
foreach ($name in $graphRoles.Keys) { Write-Host ("{0,-42} {1}" -f $name, $(if ($name -in $missing) { 'to grant' } else { 'already granted' })) }
if ($missing.Count -eq 0) { Write-Host 'Nothing to grant.'; return }
if ($WhatIf) { Write-Host "WhatIf: $($missing.Count) role(s) would be granted; nothing was changed."; return }

# Lists the permissions under the app registration's API permissions blade; failure does not affect the grant.
$appPermissions = @($graphRoles.Values | ForEach-Object { "$_=Role" })
& az ad app permission add --id $servicePrincipal.appId --api $graphAppId --api-permissions @appPermissions --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Note: the permissions could not be listed on the app registration; the grants below are what matter.' }

foreach ($name in $missing) {
    $bodyFile = [IO.Path]::GetTempFileName()
    try {
        @{ principalId = $servicePrincipal.id; resourceId = $graphObjectId; appRoleId = $graphRoles[$name] } | ConvertTo-Json -Compress | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
        try {
            Invoke-Az @('rest', '--method', 'POST', '--url', $assignmentsUrl, '--headers', 'Content-Type=application/json', '--body', "@$bodyFile") | Out-Null
        } catch {
            throw "Could not grant $name. $($_.Exception.Message) Sign in as a Global Administrator or Privileged Role Administrator."
        }
        Write-Host "Granted $name."
    } finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

$after = @((Invoke-Az @('rest', '--method', 'GET', '--url', $assignmentsUrl)).value | ForEach-Object { $_.appRoleId })
$stillMissing = @($graphRoles.Keys | Where-Object { $graphRoles[$_] -notin $after })
if ($stillMissing.Count -gt 0) { throw "These roles are still not assigned: $($stillMissing -join ', ')." }
Write-Host "All $($graphRoles.Count) roles are assigned. New tokens pick them up within a few minutes; the workflow's first step checks this."
