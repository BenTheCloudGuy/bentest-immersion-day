[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

## Deletes a leftover diagnostic setting from a resource; settings arrive as JSON in LAB_DIAG_CLEANUP_SETTINGS.
## Deleting a setting that does not exist succeeds, so this is safe on a fresh deployment.
$settings = $env:LAB_DIAG_CLEANUP_SETTINGS | ConvertFrom-Json

$output = az monitor diagnostic-settings delete --name $settings.name --resource $settings.resource_id --only-show-errors 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "Deleting the diagnostic setting '$($settings.name)' failed: $output"
}
Write-Output "Cleared any leftover diagnostic setting '$($settings.name)' on $($settings.resource_id)."
