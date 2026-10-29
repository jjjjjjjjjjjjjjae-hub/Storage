$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Start-Storage.ps1','app\server.ps1','app\chat-model.ps1','app\chat-worker.ps1','app\local.ps1','app\tuze.ps1','app\secrets.ps1','app\github-login.ps1','app\tuze-worker.ps1','app\logo-worker.ps1','app\logo-ai.ps1','app\image-model.ps1','app\image-worker.ps1','Setup-Images.ps1')) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ('PowerShell parse: ' + $name + ': ' + $errors[0].Message) }
}
$oldLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $env:TEMP ('tuze-account-test-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
$base = 'http://127.0.0.1:28765'
$server = Join-Path $root 'app\server.ps1'
$stdout = Join-Path $env:LOCALAPPDATA 'server.out'
$stderr = Join-Path $env:LOCALAPPDATA 'server.err'
$oldImageCli=$env:TUZE_IMAGE_CLI; $oldImageModel=$env:TUZE_IMAGE_MODEL; $oldImagePng=$env:TUZE_IMAGE_TEST_PNG
$fakeCli=Join-Path $env:LOCALAPPDATA 'sd-cli.exe'
$env:TUZE_IMAGE_MODEL=Join-Path $env:LOCALAPPDATA 'test-model.safetensors'
$env:TUZE_IMAGE_TEST_PNG=Join-Path $env:LOCALAPPDATA 'image.png'
$env:TUZE_IMAGE_CLI=$fakeCli
[System.IO.File]::WriteAllText($env:TUZE_IMAGE_MODEL,'mock',[System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllBytes($env:TUZE_IMAGE_TEST_PNG,[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lNsAAAAASUVORK5CYII='))
$fakeSource=@'
using System;
using System.IO;
public class MockImageCli {
  public static int Main(string[] args) {
    for (int i=0;i<args.Length-1;i++) {
      if (args[i]=="--prompt-file") Console.Error.WriteLine("Prompt: "+File.ReadAllText(args[i+1]));
      if (args[i]=="--output") { File.Copy(Environment.GetEnvironmentVariable("TUZE_IMAGE_TEST_PNG"),args[i+1],true); return 0; }
    }
    return 2;
  }
}
'@
Add-Type -TypeDefinition $fakeSource -OutputAssembly $fakeCli -OutputType ConsoleApplication
$mock = Start-Process -FilePath node.exe -ArgumentList @(('"' + (Join-Path $root 'tests\mock-ollama.mjs') + '"'),'11439') -PassThru -WindowStyle Hidden
$proc = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $server + '"'),'-Port','28765','-OllamaUrl','http://127.0.0.1:11439','-NoBrowser') -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
    $ready = $false
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { break }
        try { $page = Invoke-WebRequest -Uri ($base + '/') -UseBasicParsing -TimeoutSec 2; if ($page.StatusCode -eq 200) { $ready = $true; break } } catch { }
    }
    if (-not $ready) { throw ('Server did not respond: ' + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)) }
    if ($page.Content -notmatch 'login-screen' -or $page.Content -notmatch 'GitHub') { throw 'Account-only login HTML missing.' }
    if ($page.Content -match 'id="(?:token|import-key|legacy-passphrase|save-token|restore-key)"') { throw 'Forbidden input in interface.' }
    $session = Invoke-RestMethod -Uri ($base + '/api/session')
    if ($session.master) { throw 'A new master key was unexpectedly created.' }
    if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'TuzeStorage\master.dpapi')) { throw 'Secret creation was not removed.' }
    if (Test-Path -LiteralPath (Join-Path $root 'Storage-Settings.cmd')) { throw 'Old menu still present.' }
    $health = Invoke-RestMethod -Uri ($base + '/api/health')
    if (-not $health.ready -or $health.model -ne 'gpt-oss:20b' -or -not $health.vision_ready -or -not $health.image_ready) { throw 'gpt-oss:20b model health failed.' }
    $chatBody = @{messages=@(@{role='user';content='Hi'})} | ConvertTo-Json -Depth 8 -Compress
    $response = Invoke-RestMethod -Uri ($base + '/api/chat') -Method Post -ContentType 'application/json' -Body $chatBody
    if ($response.text -ne 'Мәтін көрінді') { throw 'Ollama chat request failed.' }
    # Chat model runs asynchronously; verify the exact model goes through the worker.
    $chatJob = Invoke-RestMethod -Uri ($base + '/api/chat/start') -Method Post -ContentType 'application/json' -Body $chatBody
    if ([string]$chatJob.job_id -cnotmatch '^[0-9a-f]{32}$') { throw 'Chat worker job creation failed.' }
    $chatOutput = $null
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 200
        $poll = Invoke-RestMethod -Uri ($base + '/api/chat/result/' + $chatJob.job_id) -TimeoutSec 3
        if ($poll.done) { $chatOutput = $poll; break }
    }
    if ($null -eq $chatOutput -or $chatOutput.error -or
        $chatOutput.result.model -ne 'gpt-oss:20b' -or $chatOutput.result.text -ne 'Мәтін көрінді') {
        throw ('gpt-oss:20b chat worker failed: ' + (ConvertTo-Json -InputObject $chatOutput -Depth 6 -Compress))
    }
    # Async correction must remain nonblocking even while Ollama is generating.
    $tuzeBody = @{text='салем калайсын';mode='correct'} | ConvertTo-Json -Compress
    $job = Invoke-RestMethod -Uri ($base + '/api/tuze/start') -Method Post -ContentType 'application/json' -Body $tuzeBody
    if ([string]$job.job_id -cnotmatch '^[0-9a-f]{32}$') { throw 'Correction job creation failed.' }
    $corrected = $null
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 200
        $poll = Invoke-RestMethod -Uri ($base + '/api/tuze/result/' + $job.job_id) -TimeoutSec 3
        if ($poll.done) { $corrected = $poll; break }
    }
    if ($null -eq $corrected -or $corrected.result.corrected_text -ne 'Сәлем, әлем!') {
        throw ('Async correction failed: ' + (ConvertTo-Json -InputObject $corrected -Depth 6 -Compress))
    }
    # Logo&AI multi-step question / translation runs in background, without modifying chat files.
    $logoBody = @{text='бро сайт анимацны дұрыста';stage='analyze';answers=@()} | ConvertTo-Json -Depth 6 -Compress
    $logoJob = Invoke-RestMethod -Uri ($base + '/api/logo/start') -Method Post -ContentType 'application/json' -Body $logoBody
    if ([string]$logoJob.job_id -cnotmatch '^[0-9a-f]{32}$') { throw 'Logo&AI analyze job missing.' }
    $logoOutput = $null
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 200
        $candidate = Invoke-RestMethod -Uri ($base + '/api/logo/result/' + $logoJob.job_id) -TimeoutSec 3
        if ($candidate.done) { $logoOutput=$candidate; break }
    }
    if ($null -eq $logoOutput -or $logoOutput.error -or $logoOutput.result.questions.Count -ne 1 -or
        $logoOutput.result.prompt_en -notmatch 'Improve website') { throw ('Logo&AI analyze failed: ' + (ConvertTo-Json $logoOutput -Depth 6 -Compress)) }
    $logoBuild = @{text='бро сайт анимацны дұрыста';stage='build';answers=@(@{question='Қай бөлімді өзгертейін?';answer='Құрылғылар'})} | ConvertTo-Json -Depth 6 -Compress
    $buildJob = Invoke-RestMethod -Uri ($base + '/api/logo/start') -Method Post -ContentType 'application/json' -Body $logoBuild
    $buildOutput = $null
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 200
        $candidate = Invoke-RestMethod -Uri ($base + '/api/logo/result/' + $buildJob.job_id) -TimeoutSec 3
        if ($candidate.done) { $buildOutput=$candidate; break }
    }
    if ($null -eq $buildOutput -or $buildOutput.error -or $buildOutput.result.questions.Count -ne 0 -or
        $buildOutput.result.prompt_en -notmatch 'Devices') { throw ('Logo&AI build failed: ' + (ConvertTo-Json $buildOutput -Depth 6 -Compress)) }
    $imageBody = @{text='Қызыл алма, шынайы фото'} | ConvertTo-Json -Compress
    $imageJob = Invoke-RestMethod -Uri ($base + '/api/image/start') -Method Post -ContentType 'application/json' -Body $imageBody
    if ([string]$imageJob.job_id -cnotmatch '^[0-9a-f]{32}$') { throw 'Image job creation failed.' }
    $imageResult=$null
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 200
        $candidate=Invoke-RestMethod -Uri ($base + '/api/image/result/' + $imageJob.job_id) -TimeoutSec 3
        if ($candidate.done) { $imageResult=$candidate; break }
    }
    if ($null -eq $imageResult -or $imageResult.error -or
        [Convert]::FromBase64String([string]$imageResult.result.image_base64).Length -lt 16 -or
        $imageResult.result.prompt_en -notmatch 'A red apple') {
        throw ('Local image generation failed: ' + (ConvertTo-Json $imageResult -Depth 5 -Compress))
    }
    $now = '2026-10-28T00:00:00.000Z' 
    function New-Envelope([string]$Filename) {
        return @{schema_version=3;id=[guid]::NewGuid().ToString();version=[guid]::NewGuid().ToString();filename=$Filename;
            title='Test';created_at=$now;updated_at=$now;messages=@()}
    }
    function Put-Envelope([string]$Filename,$Envelope,[string]$ExpectedVersion) {
        $json = @{envelope=$Envelope;expected_version=$ExpectedVersion} | ConvertTo-Json -Depth 12 -Compress
        return Invoke-RestMethod -Uri ($base+'/api/local/'+$Filename) -Method Put -ContentType 'application/json' -Body $json
    }
    $one = New-Envelope 'chat_001.json'; $two = New-Envelope 'chat_002.json'
    [void](Put-Envelope 'chat_001.json' $one $null)
    [void](Put-Envelope 'chat_002.json' $two $null)
    $files = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'TuzeStorage\chats') -Filter 'chat_*.json')
    if ($files.Count -ne 2) { throw 'Two separate chat files expected.' }
    $update = New-Envelope 'chat_001.json'; $update.id=$one.id
    [void](Put-Envelope 'chat_001.json' $update $one.version)
    $actual = (Invoke-RestMethod -Uri ($base+'/api/local/chat_001.json')).envelope
    if ($actual.version -ne $update.version) { throw 'Chat update missing.' }
    try { [void](Put-Envelope 'chat_001.json' $one $one.version); throw 'Stale write was accepted.' }
    catch [System.Net.WebException] { if ([int]$_.Exception.Response.StatusCode -ne 409) { throw } }
    if (@(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'TuzeStorage\chats') -Filter 'chat_001.json.bak.*').Count -lt 1) { throw 'Old version backup missing.' }
    try { [void](Invoke-RestMethod -Uri ($base+'/api/legacy/clear') -Method Post -ContentType 'application/json' -Body '{}'); throw 'Legacy settings endpoint must not exist.' }
    catch [System.Net.WebException] { if ([int]$_.Exception.Response.StatusCode -ne 404) { throw } }
    $socket = [System.Net.Sockets.TcpClient]::new('127.0.0.1',28765)
    try {
        $stream = $socket.GetStream()
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("GET /api/session HTTP/1.1`r`nHost: attacker.example:28765`r`nConnection: close`r`n`r`n")
        $stream.Write($bytes,0,$bytes.Length)
        $reader = [System.IO.StreamReader]::new($stream)
        if ($reader.ReadLine() -notmatch '^HTTP/1\.1 403 ') { throw 'Host header injection was accepted.' }
    } finally { $socket.Dispose() }
    Write-Host 'WINDOWS_PASS: local image generation, account login, JSON v3, model, async TUZE, Logo&AI, Host check'
} finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    if (-not $mock.HasExited) { Stop-Process -Id $mock.Id -Force }
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:TUZE_IMAGE_CLI=$oldImageCli; $env:TUZE_IMAGE_MODEL=$oldImageModel; $env:TUZE_IMAGE_TEST_PNG=$oldImagePng
}
