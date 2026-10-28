# Encrypted envelopes only. Plaintext, passphrase and GitHub token never enter this module.
$script:ChatFolder = Join-Path $env:LOCALAPPDATA 'TuzeStorage\chats'
if (-not (Test-Path -LiteralPath $script:ChatFolder)) {
    [void][System.IO.Directory]::CreateDirectory($script:ChatFolder)
}

function Assert-ChatFilename([string]$Filename) {
    if ($Filename -cnotmatch '^chat_\d{3,}\.json$') { throw 'Файл атауы жарамсыз.' }
}

function Get-ChatPath([string]$Filename) {
    Assert-ChatFilename $Filename
    return Join-Path $script:ChatFolder $Filename
}

function Read-ChatEnvelope([string]$Filename) {
    $path = Get-ChatPath $Filename
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $data = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ($data.filename -cne $Filename -or $data.schema_version -ne 2) { throw 'Файл сәйкеспейді.' }
        return $data
    } catch { throw 'Жергілікті шифрланған файлды оқу мүмкін емес; сақтауды тоқтаттым.' }
}

function Get-ChatFiles {
    return @([System.IO.Directory]::GetFiles($script:ChatFolder, 'chat_*.json') |
        ForEach-Object { [System.IO.Path]::GetFileName($_) } |
        Where-Object { $_ -cmatch '^chat_\d{3,}\.json$' } | Sort-Object)
}

function Assert-Envelope($Envelope, [string]$Filename) {
    if ($null -eq $Envelope -or $Envelope -isnot [pscustomobject] -or
        $Envelope.schema_version -ne 2 -or $Envelope.filename -cne $Filename -or
        [string]$Envelope.id -cnotmatch '^[0-9a-fA-F-]{36}$' -or
        [string]$Envelope.version -cnotmatch '^[0-9a-fA-F-]{36}$' -or
        $null -eq $Envelope.encryption -or
        $Envelope.encryption.algorithm -cne 'AES-256-GCM' -or
        $Envelope.encryption.kdf -cne 'PBKDF2-HMAC-SHA256' -or
        $Envelope.encryption.iterations -ne 600000 -or
        [string]$Envelope.encryption.salt -cnotmatch '^[A-Za-z0-9+/=]+$' -or
        [string]$Envelope.encryption.nonce -cnotmatch '^[A-Za-z0-9+/=]+$' -or
        [string]$Envelope.encryption.ciphertext -cnotmatch '^[A-Za-z0-9+/=]+$') {
        throw 'Шифрланған файл пішімі жарамсыз.'
    }
}

function Save-ChatEnvelope([string]$Filename, $Envelope, [string]$ExpectedVersion) {
    $path = Get-ChatPath $Filename
    Assert-Envelope $Envelope $Filename
    $previous = Read-ChatEnvelope $Filename
    if ($null -eq $previous) {
        if ($ExpectedVersion) { throw 'CONFLICT: Чат файлы табылмады.' }
    } elseif (-not $ExpectedVersion -or $previous.version -cne $ExpectedVersion) {
        throw 'CONFLICT: Чаттың басқа нұсқасы сақталған.'
    }
    $json = ConvertTo-Json -InputObject $Envelope -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    if ($bytes.Length -gt 2097152) { throw 'Чат файлы тым үлкен.' }
    $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $stream = [System.IO.FileStream]::new($temp, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if ($null -eq $previous) { [System.IO.File]::Move($temp, $path) }
        else {
            $backup = $path + '.bak.' + [string]$previous.version
            [System.IO.File]::Replace($temp, $path, $backup, $true)
        }
        return @{ version = [string]$Envelope.version; filename = $Filename }
    } finally {
        if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
    }
}

function Retire-ChatEnvelope([string]$Filename, [string]$ExpectedVersion) {
    $path = Get-ChatPath $Filename
    $previous = Read-ChatEnvelope $Filename
    if ($null -eq $previous -or $previous.version -cne $ExpectedVersion) {
        throw 'CONFLICT: Чат файлы өзгерген; орын ауыстыру тоқтатылды.'
    }
    $backup = $path + '.retired.' + [string]$previous.version
    [System.IO.File]::Move($path, $backup)
    return @{ retired = $true }
}
