<#
  Setup-Development.ps1 - one-time local setup.
  Creates the git-ignored appsettings.Development.json from the example file.
  The API creates the database "Vendor_db" and schema automatically on first start.
#>
param([string]$DbPassword = 'CHANGE_ME')

$root = Split-Path $PSScriptRoot -Parent
$dir = Join-Path $root 'VendorFlowAPI/VendorFlow.API'
$example = Join-Path $dir 'appsettings.Example.json'
$target = Join-Path $dir 'appsettings.Development.json'

if (Test-Path $target) { Write-Host 'appsettings.Development.json already exists.'; exit 0 }
(Get-Content $example -Raw).Replace('CHANGE_ME', $DbPassword) | Set-Content $target -Encoding utf8
Write-Host 'Created appsettings.Development.json (git-ignored). Edit it if your Postgres settings differ.'
Write-Host 'Then run:  dotnet run --project VendorFlowAPI/VendorFlow.API'
