$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Start-Storage.ps1','app\server.ps1','app\local.ps1','app\tuze.ps1')) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ('PowerShell parse: ' + $name + ' ' + $errors[0].Message) }
}
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $env:TEMP ('tuze-storage-test-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
$port = 28765
$base = 'http://127.0.0.1:' + $port
$server = Join-Path $root 'app\server.ps1'
$stdout = Join-Path $env:LOCALAPPDATA 'stdout.txt'
$stderr = Join-Path $env:LOCALAPPDATA 'stderr.txt'
$process = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $server + '"'),'-Port',[string]$port,'-NoBrowser') -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
    $ready = $false
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if ($process.HasExited) { break }
        try { $page = Invoke-WebRequest -Uri ($base + '/') -UseBasicParsing -TimeoutSec 2; if ($page.StatusCode -eq 200) { $ready = $true; break } } catch {}
    }
    if (-not $ready) { throw ('Server did not respond: ' + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue) + (Get-Content $stdout -Raw -ErrorAction SilentlyContinue)) }
    if ($page.Content -notmatch 'Tuze') { throw 'HTML was not served.' }
    $script = Invoke-WebRequest -Uri ($base + '/app.mjs') -UseBasicParsing
    if ($script.Content -notmatch 'syncCurrent') { throw 'JavaScript was not served.' }
    function Envelope([string]$Filename) {
        return @{schema_version=2;id=[guid]::NewGuid().ToString();filename=$Filename;updated_at='2026-10-28T00:00:00.000Z';version=[guid]::NewGuid().ToString();
            encryption=@{algorithm='AES-256-GCM';kdf='PBKDF2-HMAC-SHA256';iterations=600000;salt='AA==';nonce='AA==';ciphertext='AA=='}}
    }
    function Put($Filename, $Body) {
        return Invoke-RestMethod -Uri ($base+'/api/local/'+$Filename) -Method Put -ContentType 'application/json' -Body (ConvertTo-Json -InputObject $Body -Depth 10 -Compress)
    }
    $first = Envelope 'chat_001.json'; $second = Envelope 'chat_002.json'
    [void](Put 'chat_001.json' @{envelope=$first;expected_version=$null})
    [void](Put 'chat_002.json' @{envelope=$second;expected_version=$null})
    $files = (Invoke-RestMethod -Uri ($base+'/api/local')).files
    if ($files.Count -ne 2) { throw 'Expected two separate chat files.' }
    $firstNext = Envelope 'chat_001.json'; $firstNext.id=$first.id
    [void](Put 'chat_001.json' @{envelope=$firstNext;expected_version=$first.version})
    $actual = (Invoke-RestMethod -Uri ($base+'/api/local/chat_001.json')).envelope
    $other = (Invoke-RestMethod -Uri ($base+'/api/local/chat_002.json')).envelope
    if ($actual.version -ne $firstNext.version -or $other.version -ne $second.version) { throw 'Chats mixed or update lost.' }
    try { [void](Put 'chat_001.json' @{envelope=$first;expected_version=$first.version}); throw 'Stale write was accepted.' }
    catch [System.Net.WebException] { if ([int]$_.Exception.Response.StatusCode -ne 409) { throw } }
    if (@(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'TuzeStorage\chats') -Filter 'chat_001.json.bak.*').Count -lt 1) { throw 'Local backup missing.' }
    Write-Host 'WINDOWS_PASS: PS5.1 parse, page, static JS, two chats, same-file update, SHA-like CAS, backup'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $env:LOCALAPPDATA = $savedLocalAppData
}
