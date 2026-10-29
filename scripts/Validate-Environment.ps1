<# Validate-Environment.ps1 - checks that the tools needed for VendorFlow are installed. #>
$tools = @(
    @{ Name = 'git';     Cmd = 'git --version' },
    @{ Name = 'dotnet';  Cmd = 'dotnet --version' },
    @{ Name = 'node';    Cmd = 'node --version' },
    @{ Name = 'npm';     Cmd = 'npm --version' },
    @{ Name = 'ng';      Cmd = 'ng version' },
    @{ Name = 'flutter'; Cmd = 'flutter --version' },
    @{ Name = 'docker';  Cmd = 'docker --version' },
    @{ Name = 'psql';    Cmd = 'psql --version' }
)
foreach ($t in $tools) {
    if (Get-Command $t.Name -ErrorAction SilentlyContinue) {
        $first = (Invoke-Expression $t.Cmd 2>&1 | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        Write-Host ("OK      {0,-8} {1}" -f $t.Name, $first)
    } else {
        Write-Host ("MISSING {0}" -f $t.Name) -ForegroundColor Yellow
    }
}
# psql is normally in the PostgreSQL install folder rather than on PATH.
$pg = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pg) { Write-Host "Found psql at $($pg.FullName)" }
