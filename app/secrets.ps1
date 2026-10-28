# TUZE account login. Credentials stay in GitHub CLI's protected credential storage.
# No user-provided tokens/passwords are accepted by the TUZE interface.
Add-Type -AssemblyName System.Security
$script:SecretFolder = Join-Path $env:LOCALAPPDATA 'TuzeStorage'
[void][System.IO.Directory]::CreateDirectory($script:SecretFolder)
$script:SecretEntropy = [System.Text.Encoding]::UTF8.GetBytes('TuzeStorage-DPAPI-v1')
function Read-LegacyTuzeMaster {
    $path = Join-Path $script:SecretFolder 'master.dpapi'
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes,$script:SecretEntropy,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } catch { return $null }
}
function Find-TuzeGh {
    foreach ($commandName in @('gh.exe','gh')) {
        $found = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue
        if ($found -and [System.IO.File]::Exists($found.Source)) { return [string]$found.Source }
    }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE)) {
        if (-not $root) { continue }
        foreach ($suffix in @('GitHub CLI\gh.exe','Programs\GitHub CLI\gh.exe',
            'Microsoft\WinGet\Links\gh.exe','scoop\apps\gh\current\bin\gh.exe',
            'scoop\shims\gh.exe')) {
            [void]$paths.Add((Join-Path $root $suffix))
        }
    }
    foreach ($path in $paths) {
        if ([System.IO.File]::Exists($path)) { return $path }
    }
    # winget installs sometimes do not update the PATH of a running TUZE process.
    $wingetRoots = @((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'))
    if ($env:ProgramFiles) { $wingetRoots += (Join-Path $env:ProgramFiles 'WinGet\Packages') }
    foreach ($root in $wingetRoots) {
        if (-not [System.IO.Directory]::Exists($root)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'GitHub.cli*' -ErrorAction SilentlyContinue)) {
            $found = Get-ChildItem -LiteralPath $dir.FullName -File -Filter 'gh.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return [string]$found.FullName }
        }
    }
    return $null
}
function Get-GitHubAuthToken {
    $gh = Find-TuzeGh
    if (-not $gh) { return $null }
    try {
        $lines = @(& $gh auth token --hostname github.com 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) { return $null }
        $token = ([string]$lines[0]).Trim()
        if ($token.Length -ge 12 -and $token.Length -le 512 -and $token -notmatch '\s') { return $token }
    } catch { }
    return $null
}
