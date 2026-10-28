# Private GitHub account mode: JSON v3 local files and read-only legacy v2 support.
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
        if ($data.filename -cne $Filename -or $data.schema_version -notin @(2,3)) { throw 'Файл сәйкеспейді.' }
        return $data
    } catch { throw 'Жергілікті чат файлын оқу мүмкін емес; сақтауды тоқтаттым.' }
}

function Get-ChatFiles {
    return @([System.IO.Directory]::GetFiles($script:ChatFolder, 'chat_*.json') |
        ForEach-Object { [System.IO.Path]::GetFileName($_) } |
        Where-Object { $_ -cmatch '^chat_\d{3,}\.json$' } | Sort-Object)
}

function Assert-Envelope($Envelope, [string]$Filename) {
    if ($null -eq $Envelope -or $Envelope -isnot [pscustomobject] -or
        $Envelope.schema_version -ne 3 -or $Envelope.filename -cne $Filename -or
        [string]$Envelope.id -cnotmatch '^[0-9a-fA-F-]{36}$' -or
        [string]$Envelope.version -cnotmatch '^[0-9a-fA-F-]{36}$' -or
        $Envelope.title -isnot [string] -or $Envelope.title.Length -gt 200 -or
        $Envelope.created_at -isnot [string] -or $Envelope.updated_at -isnot [string] -or
        $null -eq $Envelope.messages -or $Envelope.messages -isnot [array] -or
        $Envelope.messages.Count -gt 10000) {
        throw 'Чат JSON v3 пішімі жарамсыз.'
    }
    foreach ($m in $Envelope.messages) {
        if ($m.role -cnotin @('user','assistant') -or
            [string]$m.id -cnotmatch '^[0-9a-fA-F-]{36}$' -or
            $m.content -isnot [string] -or
            $m.content.Length -gt $(if ($m.role -ceq 'assistant') { 40000 } else { 4000 }) -or
            $m.created_at -isnot [string]) { throw 'Хабарлама жарамсыз.' }
        if ($null -ne $m.image -and ($m.role -cne 'user' -or $m.image.mime -cne 'image/jpeg' -or
            $m.image.data -isnot [string] -or $m.image.data.Length -gt 200000 -or
            $m.image.data -cnotmatch '^[A-Za-z0-9+/]+={0,2}$')) { throw 'Фото жарамсыз.' }
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
