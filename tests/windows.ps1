$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Start-Storage.ps1','app\server.ps1','app\local.ps1','app\tuze.ps1','app\secrets.ps1','Storage-Settings.ps1')) {
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
$mockScript = Join-Path $root 'tests\mock-ollama.mjs'
$mock = Start-Process -FilePath node.exe -ArgumentList @(('"' + $mockScript + '"'),'11439') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $env:LOCALAPPDATA 'mock-out.txt') -RedirectStandardError (Join-Path $env:LOCALAPPDATA 'mock-err.txt')
$process = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $server + '"'),'-Port',[string]$port,'-OllamaUrl','http://127.0.0.1:11439','-NoBrowser') -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
    $ready = $false
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if ($process.HasExited) { break }
        try { $page = Invoke-WebRequest -Uri ($base + '/') -UseBasicParsing -TimeoutSec 2; if ($page.StatusCode -eq 200) { $ready = $true; break } } catch {}
    }
    if (-not $ready) { throw ('Server did not respond: ' + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue) + (Get-Content $stdout -Raw -ErrorAction SilentlyContinue)) }
    if ($page.Content -notmatch 'Tuze') { throw 'HTML was not served.' }
    if ($page.Content -match 'id=\"(?:token|import-key|legacy-passphrase|restore-key|save-token)\"') { throw 'Secret input leaked into chat UI.' }
    if (-not (Test-Path (Join-Path $root 'Storage-Settings.cmd'))) { throw 'External settings launcher missing.' }
    $script = Invoke-WebRequest -Uri ($base + '/app.mjs') -UseBasicParsing
    if ($script.Content -notmatch 'syncCurrent') { throw 'JavaScript was not served.' }
    $session = Invoke-RestMethod -Uri ($base + '/api/session')
    $again = Invoke-RestMethod -Uri ($base + '/api/session')
    if ($session.master -ne $again.master -or [Convert]::FromBase64String($session.master).Length -ne 32) { throw 'Automatic key generation failed.' }
    $secretFile = Join-Path $env:LOCALAPPDATA 'TuzeStorage\master.dpapi'
    if (-not (Test-Path -LiteralPath $secretFile) -or
        [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($secretFile)).Contains($session.master)) { throw 'Master key is not protected.' }
    . (Join-Path $root 'app\secrets.ps1')
    $token = 'github_pat_test_1234567890abcdef'
    [void](Save-GitHubToken $token)
    if ((Invoke-RestMethod -Uri ($base + '/api/session')).token -ne $token) { throw 'Protected GitHub token did not persist.' }
    $fakeGh = Join-Path $env:LOCALAPPDATA 'gh.cmd'
    [System.IO.File]::WriteAllText($fakeGh, "@echo off`r`nif not `%1==auth exit /b 2`r`nif not `%2==token exit /b 2`r`necho gho_test_1234567890abcdef`r`n", [System.Text.Encoding]::ASCII)
    if ((Get-GitHubAuthToken $fakeGh) -ne 'gho_test_1234567890abcdef') { throw 'GitHub CLI credential path failed.' }
    if ((Get-GitHubAuthToken 'missing-gh-for-test') -ne $token) { throw 'PAT fallback failed.' }
    [void](Save-LegacyPassphrase 'old-test-passphrase-123')
    if ((Invoke-RestMethod -Uri ($base + '/api/session')).legacy_passphrase -ne 'old-test-passphrase-123') { throw 'Legacy migration secret missing.' }
    [void](Invoke-RestMethod -Uri ($base + '/api/legacy/clear') -Method Post -ContentType 'application/json' -Body '{"done":true}')
    if ((Invoke-RestMethod -Uri ($base + '/api/session')).legacy_passphrase) { throw 'Legacy secret was not removed.' }
    try { [void](Invoke-RestMethod -Uri ($base + '/api/token')); throw 'Browser token endpoint is still available.' }
    catch [System.Net.WebException] { if ([int]$_.Exception.Response.StatusCode -ne 404) { throw } }
    $socket = [System.Net.Sockets.TcpClient]::new('127.0.0.1',$port)
    try {
        $network = $socket.GetStream()
        $request = [System.Text.Encoding]::ASCII.GetBytes("GET /api/session HTTP/1.1`r`nHost: attacker.example:$port`r`nConnection: close`r`n`r`n")
        $network.Write($request,0,$request.Length)
        $reader = [System.IO.StreamReader]::new($network)
        $line = $reader.ReadLine()
        if ($line -notmatch '^HTTP/1\.1 403 ') { throw 'DNS rebinding Host was accepted.' }
    } finally { $socket.Dispose() }
    $health = Invoke-RestMethod -Uri ($base + '/api/health')
    if (-not $health.ready -or -not $health.vision_ready) { throw 'Text or vision model detection failed.' }
    $textRequest = @{messages=@(@{role='user';content='Сәлем'})} | ConvertTo-Json -Depth 8 -Compress
    $textReply = Invoke-RestMethod -Uri ($base + '/api/chat') -Method Post -ContentType 'application/json' -Body $textRequest
    if ($textReply.text -ne 'Мәтін көрінді' -or $textReply.model -ne 'qwen3:4b-instruct') { throw 'Text model routing failed.' }
    $tuzeRequest = @{text='Сәлем әлем';mode='correct'} | ConvertTo-Json -Compress
    $tuzeReply = Invoke-RestMethod -Uri ($base + '/api/tuze') -Method Post -ContentType 'application/json' -Body $tuzeRequest
    if ($tuzeReply.corrected_text -ne 'Сәлем, әлем!' -or $tuzeReply.status -ne 'corrected') { throw 'Tuze correction failed.' }
    $photoRequest = @{messages=@(@{role='user';content='Бұл не?';image=@{mime='image/jpeg';data='AA==';width=1;height=1}})} | ConvertTo-Json -Depth 8 -Compress
    $photoReply = Invoke-RestMethod -Uri ($base + '/api/chat') -Method Post -ContentType 'application/json' -Body $photoRequest
    if ($photoReply.text -ne 'Фото көрінді' -or $photoReply.model -ne 'qwen3-vl:4b-instruct') { throw 'Vision model routing failed.' }
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
    $settings = Join-Path $root 'Storage-Settings.ps1'
    $recoveryPath = Join-Path $env:LOCALAPPDATA 'Tuze-Recovery-Key.txt'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $settings -Action Export -Path $recoveryPath | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Get-Content -LiteralPath $recoveryPath -Raw).Trim() -ne $session.master) { throw 'External recovery export failed.' }
    $different = [Convert]::ToBase64String([byte[]](1..32))
    [void](Import-TuzeMaster $different)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $settings -Action Import -Path $recoveryPath | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Invoke-RestMethod -Uri ($base + '/api/session')).master -ne $session.master) { throw 'External recovery import failed.' }
    Write-Host 'WINDOWS_PASS: PS5.1, external settings, browser GitHub auth, DPAPI, Host guard, recovery, Tuze, text/photo routing, separate chats, CAS, backup'
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (-not $mock.HasExited) { Stop-Process -Id $mock.Id -Force }
    $env:LOCALAPPDATA = $savedLocalAppData
}
