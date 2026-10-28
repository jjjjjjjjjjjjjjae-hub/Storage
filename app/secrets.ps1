# Secrets are protected for the current Windows user. Never commit these files.
Add-Type -AssemblyName System.Security
$script:SecretFolder = Join-Path $env:LOCALAPPDATA 'TuzeStorage'
[void][System.IO.Directory]::CreateDirectory($script:SecretFolder)
$script:SecretEntropy = [System.Text.Encoding]::UTF8.GetBytes('TuzeStorage-DPAPI-v1')
$script:SecretScope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser

function Read-TuzeSecret([string]$Name) {
    if ($Name -cnotin @('master','github-token','legacy-passphrase')) { throw 'Secret name invalid.' }
    $path = Join-Path $script:SecretFolder ($Name + '.dpapi')
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $protected = [System.IO.File]::ReadAllBytes($path)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($protected,$script:SecretEntropy,$script:SecretScope)
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } catch { throw 'Windows кілтін аша алмадым. Файлдар өзгертілмеді; қалпына келтіру кілтін пайдаланыңыз.' }
}

function Write-TuzeSecret([string]$Name,[string]$Value) {
    if ($Name -cnotin @('master','github-token','legacy-passphrase')) { throw 'Secret name invalid.' }
    $path = Join-Path $script:SecretFolder ($Name + '.dpapi')
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($plain,$script:SecretEntropy,$script:SecretScope)
    $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $stream = [System.IO.FileStream]::new($temp,[System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,[System.IO.FileShare]::None,4096,[System.IO.FileOptions]::WriteThrough)
        try { $stream.Write($protected,0,$protected.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if ([System.IO.File]::Exists($path)) {
            [System.IO.File]::Replace($temp,$path,$path+'.bak.'+[guid]::NewGuid().ToString('N'),$true)
        } else { [System.IO.File]::Move($temp,$path) }
    } finally { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } }
}

function Get-TuzeMaster {
    $mutex = [System.Threading.Mutex]::new($false,'Local\TuzeStorageMasterKey')
    $entered = $false
    try {
        try { $entered = $mutex.WaitOne(10000) }
        catch [System.Threading.AbandonedMutexException] { $entered = $true }
        if (-not $entered) { throw 'Кілтті күту уақыты бітті.' }
        $existing = Read-TuzeSecret 'master'
        if ($existing) { return $existing }
        $bytes = [byte[]]::new(32)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $master = [Convert]::ToBase64String($bytes)
        Write-TuzeSecret 'master' $master
        return $master
    } finally { if ($entered) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Import-TuzeMaster([string]$Master) {
    try { $bytes = [Convert]::FromBase64String($Master) }
    catch { throw 'Қалпына келтіру кілті жарамсыз.' }
    if ($bytes.Length -ne 32) { throw 'Қалпына келтіру кілті 32 байт болуы керек.' }
    Write-TuzeSecret 'master' $Master
    return @{ imported = $true }
}

function Save-GitHubToken([string]$Token) {
    if ($Token.Length -lt 20 -or $Token.Length -gt 512 -or $Token -match '\s') {
        throw 'GitHub токені жарамсыз.'
    }
    Write-TuzeSecret 'github-token' $Token
    return @{ saved = $true }
}

function Save-LegacyPassphrase([string]$Passphrase) {
    if ($Passphrase.Length -lt 12 -or $Passphrase.Length -gt 512) {
        throw 'Ескі кілтсөз 12–512 таңба болуы керек.'
    }
    Write-TuzeSecret 'legacy-passphrase' $Passphrase
    return @{ saved = $true }
}

function Remove-TuzeSecret([string]$Name) {
    if ($Name -cnotin @('github-token','legacy-passphrase')) { throw 'Secret name invalid.' }
    $path = Join-Path $script:SecretFolder ($Name + '.dpapi')
    if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
    return @{ removed = $true }
}

# gh performs a one-time browser login and manages its own credential refresh.
# Keep the manually entered PAT as a fallback for machines without GitHub CLI.
function Get-GitHubAuthToken([string]$GhCommand = 'gh') {
    $gh = Get-Command $GhCommand -CommandType Application -ErrorAction SilentlyContinue
    if ($gh) {
        try {
            $lines = @(& $gh.Source auth token --hostname github.com 2>$null)
            if ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) {
                $token = ([string]$lines[0]).Trim()
                if ($token.Length -ge 20 -and $token.Length -le 512 -and $token -notmatch '\s') {
                    return $token
                }
            }
        } catch { }
    }
    return Read-TuzeSecret 'github-token'
}
