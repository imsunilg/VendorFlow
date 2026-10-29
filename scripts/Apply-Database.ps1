<#
  Apply-Database.ps1 - applies VendorFlowDB scripts with psql (developer helper, same order the API uses).
  The API does this automatically on start; use this only to inspect the database or reset it.
  Password is read from the git-ignored appsettings.Development.json (never printed).
  -Reset drops and recreates the database first.
#>
param([string]$Database = 'Vendor_db', [switch]$Reset)

$root = Split-Path $PSScriptRoot -Parent
$psql = (Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' | Select-Object -First 1).FullName
$cfg = Get-Content (Join-Path $root 'VendorFlowAPI/VendorFlow.API/appsettings.Development.json') -Raw | ConvertFrom-Json
$cs = $cfg.ConnectionStrings.VendorFlow
$env:PGPASSWORD = [regex]::Match($cs, 'Password=([^;]+)').Groups[1].Value
$h = '-h', 'localhost', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q'

if ($Reset) {
    & $psql @h -d postgres -c "DROP DATABASE IF EXISTS `"$Database`" WITH (FORCE)"
}
$exists = & $psql @h -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$Database'"
if (-not $exists) {
    # Windows PowerShell 5.1 strips embedded quotes when calling native tools, so escape them as \" for psql.
    & $psql @h -d postgres -c ('CREATE DATABASE \"' + $Database + '\"')
}

foreach ($dir in '01_Schemas','02_Tables','03_Indexes','04_Sequences','05_Functions','06_Views','07_Triggers','08_SeedData') {
    Get-ChildItem (Join-Path $root "VendorFlowDB/$dir/*.sql") -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        Write-Host "applying $dir/$($_.Name)"
        & $psql @h -d $Database -f $_.FullName
        if ($LASTEXITCODE -ne 0) { throw "failed: $($_.Name)" }
    }
}
