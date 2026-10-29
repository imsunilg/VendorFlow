<#
  Save-Phase.ps1 - stage and commit the current work locally.
  Usage: ./scripts/Save-Phase.ps1 -Message "feat(api): vendor management"
  Push is OFF unless -Push is passed explicitly.
#>
param(
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$Push
)

$ErrorActionPreference = 'Continue'  # git writes warnings to stderr; failures are checked via $LASTEXITCODE
Set-Location (Split-Path $PSScriptRoot -Parent)

if (-not (Test-Path .git)) { git init -b main | Out-Null }

# Never commit secrets or build output (the .gitignore handles most of it).
git add -A

$staged = git diff --cached --name-only
if (-not $staged) { Write-Host 'Nothing to commit.'; exit 0 }

$blockedNames = $staged | Where-Object { $_ -match 'appsettings\.Development\.json$|(^|/)\.env($|\.)|\.pfx$|\.key$' }
if ($blockedNames) {
    git reset | Out-Null
    throw "Refusing to commit secret files: $($blockedNames -join ', ')"
}

# Scan staged text for the local dev DB password marker stored in a local, git-ignored file.
$secretFile = Join-Path (Get-Location) 'VendorFlowAPI/VendorFlow.API/appsettings.Development.json'
if (Test-Path $secretFile) {
    $m = [regex]::Match((Get-Content $secretFile -Raw), 'Password=([^;"]+)')
    if ($m.Success -and $m.Groups[1].Value -ne 'CHANGE_ME') {
        $hits = git grep --cached -l -F -- $m.Groups[1].Value 2>$null
        if ($hits) {
            git reset | Out-Null
            throw "Refusing to commit: dev DB password found in staged file(s): $($hits -join ', ')"
        }
    }
}

git commit -m $Message -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
$hash = git rev-parse --short HEAD
Write-Host "Committed $hash : $Message"

if ($Push) { git push }
