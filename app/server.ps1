param([int]$Port = 8790, [string]$OllamaUrl = '', [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tuze.ps1')
. (Join-Path $PSScriptRoot 'local.ps1')
. (Join-Path $PSScriptRoot 'secrets.ps1')
Initialize-Tuze $OllamaUrl
$script:JobFolder = Join-Path $env:LOCALAPPDATA 'TuzeStorage\jobs'
[void][System.IO.Directory]::CreateDirectory($script:JobFolder)
$encoding = [System.Text.UTF8Encoding]::new($false, $true)

function Send-Raw($Stream, [int]$Status, [string]$Type, [byte[]]$Body, [string]$CustomCsp = '') {
    $reasons = @{200='OK';400='Bad Request';403='Forbidden';404='Not Found';409='Conflict';
        411='Length Required';413='Payload Too Large';415='Unsupported Media Type';
        422='Unprocessable Entity';500='Internal Server Error';503='Service Unavailable'}
    $reason = $reasons[$Status]
    $csp = if ($CustomCsp) { $CustomCsp } else {
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' https://api.github.com; frame-src 'self'; base-uri 'none'; form-action 'none'"
    }
    $head = "HTTP/1.1 $Status $reason`r`nContent-Type: $Type`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nContent-Security-Policy: $csp`r`n`r`n"
    $h = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($h, 0, $h.Length)
    $Stream.Write($Body, 0, $Body.Length)
    $Stream.Flush()
}

function Send-Json($Stream, [int]$Status, $Data) {
    $body = $encoding.GetBytes((ConvertTo-Json -InputObject $Data -Depth 16 -Compress))
    Send-Raw $Stream $Status 'application/json; charset=utf-8' $body
}

. (Join-Path $PSScriptRoot 'chat-model.ps1')

$listener = $null
for ($candidate=$Port; $candidate -lt ($Port+20); $candidate++) {
    try {
        $socket = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$candidate)
        $socket.Start(); $listener=$socket; $Port=$candidate; break
    } catch { if ($socket) { $socket.Stop() }; $socket=$null }
}
if ($null -eq $listener) { throw 'Жергілікті серверге бос порт табылмады.' }
$url = 'http://127.0.0.1:' + $Port
Write-Host ('TUZE_STORAGE_URL=' + $url)
Write-Host 'Тоқтату: Ctrl+C'
if (-not $NoBrowser) { try { Start-Process $url } catch { Write-Host ('Браузерде ашыңыз: '+$url) } }

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout=15000; $client.SendTimeout=15000
            $stream=$client.GetStream()
            try {
                $bytes = [System.Collections.Generic.List[byte]]::new()
                $end=0
                while ($bytes.Count -lt 8192) {
                    $v=$stream.ReadByte(); if ($v -lt 0) { break }
                    [void]$bytes.Add([byte]$v)
                    $end=(($end -shl 8) -bor $v) -band 0xFFFFFFFF
                    if ($end -eq 0x0D0A0D0A) { break }
                }
                if ($end -ne 0x0D0A0D0A) { Send-Json $stream 400 @{error='HTTP сұрауы жарамсыз.'}; continue }
                $head=[System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
                $lines=$head.Split([string[]]@("`r`n"),[System.StringSplitOptions]::None)
                $requestLine=[regex]::Match($lines[0],'^(GET|POST|PUT) (\S+) HTTP/1\.[01]$')
                if (-not $requestLine.Success) { Send-Json $stream 400 @{error='HTTP әдісі жарамсыз.'}; continue }
                $method=$requestLine.Groups[1].Value; $path=$requestLine.Groups[2].Value
                $headers=[System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $bad=$false
                foreach ($line in $lines[1..($lines.Length-1)]) {
                    if (-not $line) { continue }
                    $split=$line.IndexOf(':')
                    if ($split -le 0) { $bad=$true; break }
                    $key=$line.Substring(0,$split).Trim()
                    if ($headers.ContainsKey($key)) { $bad=$true; break }
                    $headers[$key]=$line.Substring($split+1).Trim()
                }
                if ($bad) { Send-Json $stream 400 @{error='HTTP тақырыбы жарамсыз.'}; continue }
                $receivedHost = if ($headers.ContainsKey('Host')) { $headers['Host'] } else { '' }
                $expectedHost = '127.0.0.1:' + [string]$Port
                $localhostHost = 'localhost:' + [string]$Port
                if (-not ([string]::Equals($receivedHost,$expectedHost,[System.StringComparison]::OrdinalIgnoreCase) -or
                    [string]::Equals($receivedHost,$localhostHost,[System.StringComparison]::OrdinalIgnoreCase))) {
                    Send-Json $stream 403 @{error='Жергілікті Host керек.'}; continue
                }
                if ($method -ne 'GET' -and $headers.ContainsKey('Origin') -and
                    $headers['Origin'] -cne $url -and $headers['Origin'] -cne ('http://localhost:'+$Port)) {
                    Send-Json $stream 403 @{error='Басқа сайттан сұрауға рұқсат жоқ.'}; continue
                }
                $static = @{ '/'='index.html'; '/app.mjs'='app.mjs'; '/crypto.mjs'='crypto.mjs';
                    '/store.mjs'='store.mjs'; '/style.css'='style.css';
                    '/code-files.mjs'='code-files.mjs'; '/code-workspace.mjs'='code-workspace.mjs' }
                if ($method -eq 'GET' -and $static.ContainsKey($path)) {
                    $type=if ($path -eq '/') {'text/html; charset=utf-8'} elseif ($path -eq '/style.css') {'text/css; charset=utf-8'} else {'text/javascript; charset=utf-8'}
                    Send-Raw $stream 200 $type ([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $static[$path]))); continue
                }
                if ($method -eq 'GET' -and $path -eq '/preview-frame.html') {
                    # Preview is deliberately isolated from the app: this relaxed policy applies ONLY to
                    # an iframe with sandbox=allow-scripts and WITHOUT allow-same-origin.
                    $previewCsp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
                    Send-Raw $stream 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'preview-frame.html'))) $previewCsp
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/health') {
                    $health=Get-TuzeHealth; $vision=Get-VisionModel
                    $health.vision_ready=[bool]$vision; $health.vision_model=$vision
                    Send-Json $stream 200 $health; continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/session') {
                    try { Send-Json $stream 200 @{master=(Read-LegacyTuzeMaster); token=(Get-GitHubAuthToken)} }
                    catch { Send-Json $stream 503 @{error=$_.Exception.Message} }
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/login/status') {
                    $statusPath=Join-Path $env:LOCALAPPDATA 'TuzeStorage\github-login-status.json'
                    $token=Get-GitHubAuthToken
                    if ($token) { Send-Json $stream 200 @{authenticated=$true;waiting=$false;error=$null} }
                    elseif (Test-Path -LiteralPath $statusPath) {
                        try {
                            $status=Get-Content -LiteralPath $statusPath -Encoding UTF8 -Raw | ConvertFrom-Json -ErrorAction Stop
                            $expired=([DateTime]::UtcNow - [DateTime]::Parse([string]$status.updated_at)).TotalMinutes -gt 10
                            Send-Json $stream 200 @{authenticated=$false;waiting=($status.status -eq 'waiting' -and -not $expired);error=$(if($expired){'GitHub кіру уақыты аяқталды. Қайта басыңыз.'} elseif($status.status -eq 'error') {[string]$status.message} else {$null})}
                        } catch { Send-Json $stream 200 @{authenticated=$false;waiting=$false;error='GitHub статусы анықталмады.'} }
                    } else { Send-Json $stream 200 @{authenticated=$false;waiting=$false;error=$null} }
                    continue
                }
                $jobMatch = [regex]::Match($path,'^/api/(?:tuze|logo|chat)/result/([0-9a-f]{32})$')
                if ($method -eq 'GET' -and $jobMatch.Success) {
                    $jobId = $jobMatch.Groups[1].Value
                    $outputPath = Join-Path $script:JobFolder ($jobId + '.result.json')
                    $inputPath = Join-Path $script:JobFolder ($jobId + '.input.json')
                    $progressPath = Join-Path $script:JobFolder ($jobId + '.progress.json')
                    if ([System.IO.File]::Exists($outputPath)) {
                        try { $finished = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                            Send-Json $stream 200 $finished }
                        catch { Send-Json $stream 500 @{error='Түзету нәтижесін оқу мүмкін болмады.'} }
                    } elseif ([System.IO.File]::Exists($inputPath)) {
                        $age = [DateTime]::UtcNow - [System.IO.File]::GetCreationTimeUtc($inputPath)
                        if ($age.TotalMinutes -gt 16) { Send-Json $stream 503 @{error='gpt-oss:20b жауап беруге тым ұзақ уақыт жұмсады. Жедел жадты және Ollama-ны тексеріңіз.'} }
                        elseif ($path -like '/api/chat/result/*' -and [System.IO.File]::Exists($progressPath)) {
                            try {
                                $progress = Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                                Send-Json $stream 200 @{done=$false;stage=[string]$progress.stage;partial=[string]$progress.text}
                            } catch { Send-Json $stream 200 @{done=$false;stage='loading'} }
                        } else { Send-Json $stream 200 @{done=$false;stage='starting'} }
                    } else { Send-Json $stream 404 @{error='Түзету тапсырмасы табылмады.'} }
                    continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/local') { Send-Json $stream 200 @{files=@(Get-ChatFiles)}; continue }
                $localMatch=[regex]::Match($path,'^/api/local/(chat_\d{3,}\.json)$')
                if ($method -eq 'GET' -and $localMatch.Success) {
                    $file=$localMatch.Groups[1].Value
                    try { $envelope=Read-ChatEnvelope $file; if ($null -eq $envelope) { Send-Json $stream 404 @{error='Чат табылмады.'} } else { Send-Json $stream 200 @{envelope=$envelope} } }
                    catch { Send-Json $stream 500 @{error=$_.Exception.Message} }
                    continue
                }
                $retireMatch=[regex]::Match($path,'^/api/retire/(chat_\d{3,}\.json)$')
                $isWrite=($method -eq 'PUT' -and $localMatch.Success) -or
                    ($method -eq 'POST' -and ($retireMatch.Success -or $path -in @('/api/chat','/api/chat/start','/api/tuze','/api/tuze/start','/api/logo/start','/api/login')))
                if (-not $isWrite) { Send-Json $stream 404 @{error='Мекенжай табылмады.'}; continue }
                if (-not $headers.ContainsKey('Content-Type') -or $headers['Content-Type'] -notmatch '^application/json(?:\s*;|$)') {
                    Send-Json $stream 415 @{error='JSON сұрауы керек.'}; continue
                }
                if (-not $headers.ContainsKey('Content-Length')) { Send-Json $stream 411 @{error='Content-Length керек.'}; continue }
                $length=0
                if (-not [int]::TryParse($headers['Content-Length'],[ref]$length) -or $length -lt 1) {
                    Send-Json $stream 400 @{error='Content-Length жарамсыз.'}; continue
                }
                if ($length -gt 2097152) { Send-Json $stream 413 @{error='Сұрау тым үлкен.'}; continue }
                $body=[byte[]]::new($length); $read=0
                while ($read -lt $length) { $n=$stream.Read($body,$read,$length-$read); if ($n -le 0) { break }; $read+=$n }
                if ($read -ne $length) { Send-Json $stream 400 @{error='Сұрау толық келмеді.'}; continue }
                try { $payload=ConvertFrom-Json -InputObject $encoding.GetString($body) -ErrorAction Stop
                    if ($payload -isnot [pscustomobject]) { throw 'JSON object керек.' } }
                catch { Send-Json $stream 422 @{error='JSON жарамсыз.'}; continue }
                try {
                    if ($method -eq 'PUT') {
                        $file=$localMatch.Groups[1].Value
                        Send-Json $stream 200 (Save-ChatEnvelope $file $payload.envelope ([string]$payload.expected_version))
                    } elseif ($retireMatch.Success) {
                        Send-Json $stream 200 (Retire-ChatEnvelope $retireMatch.Groups[1].Value ([string]$payload.expected_version))
                    } elseif ($path -eq '/api/chat') {
                        # Legacy synchronous route kept for local compatibility tests.
                        Send-Json $stream 200 (Invoke-ChatModel $payload)
                    } elseif ($path -eq '/api/chat/start') {
                        # Local model generation must not block the single-threaded local web server.
                        if ($null -eq $payload.messages -or $payload.messages -isnot [array] -or
                            $payload.messages.Count -lt 1 -or $payload.messages.Count -gt 60 -or
                            $payload.messages[-1].role -cne 'user') { throw 'Чат хабарламалары жарамсыз.' }
                        $jobId = [guid]::NewGuid().ToString('N')
                        $inputPath = Join-Path $script:JobFolder ($jobId + '.input.json')
                        $workerPath = Join-Path $PSScriptRoot 'chat-worker.ps1'
                        $workJson = ConvertTo-Json -InputObject @{messages=@($payload.messages)} -Depth 16 -Compress
                        [System.IO.File]::WriteAllText($inputPath,$workJson,[System.Text.UTF8Encoding]::new($false))
                        try {
                            $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $workerPath + '" -Job ' + $jobId + ' -OllamaUrl ' + $script:TuzeUrl
                            Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop | Out-Null
                        } catch {
                            Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
                            throw
                        }
                        Send-Json $stream 200 @{job_id=$jobId;started=$true}
                    } elseif ($path -eq '/api/login') {
                        if (-not (Find-TuzeGh)) { Send-Json $stream 503 @{error='GitHub CLI табылмады. Windows PowerShell-де «winget install --id GitHub.cli --source winget» орындап, қайта кіріңіз.'} }
                        elseif (Get-GitHubAuthToken) { Send-Json $stream 200 @{started=$false;authenticated=$true} }
                        else {
                            $loginStatus=Join-Path $env:LOCALAPPDATA 'TuzeStorage\github-login-status.json'
                            [System.IO.File]::WriteAllText($loginStatus,'{"status":"waiting","updated_at":"'+[DateTime]::UtcNow.ToString('o')+'"}',[System.Text.UTF8Encoding]::new($false))
                            $launcher = Join-Path $PSScriptRoot 'github-login.ps1'
                            $arg = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"'
                            Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -ErrorAction Stop | Out-Null
                            Send-Json $stream 200 @{started=$true}
                        }
                    } elseif ($path -eq '/api/logo/start') {
                        if ($payload.text -isnot [string] -or $payload.text.Length -lt 1 -or
                            $payload.text.Length -gt 4000 -or $payload.stage -cnotin @('analyze','build') -or
                            $null -eq $payload.answers -or $payload.answers -isnot [array] -or
                            $payload.answers.Count -gt 3) { throw 'Logo&AI сұрауы жарамсыз.' }
                        foreach ($answer in $payload.answers) {
                            if ($answer -isnot [pscustomobject] -or $answer.question -isnot [string] -or
                                $answer.answer -isnot [string] -or $answer.question.Length -gt 240 -or
                                $answer.answer.Length -gt 500) { throw 'Logo&AI жауабы жарамсыз.' }
                        }
                        $jobId = [guid]::NewGuid().ToString('N')
                        $inputPath = Join-Path $script:JobFolder ($jobId + '.input.json')
                        $workerPath = Join-Path $PSScriptRoot 'logo-worker.ps1'
                        $workJson = ConvertTo-Json -InputObject @{text=$payload.text;stage=$payload.stage;answers=@($payload.answers)} -Depth 8 -Compress
                        [System.IO.File]::WriteAllText($inputPath,$workJson,[System.Text.UTF8Encoding]::new($false))
                        try {
                            $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $workerPath + '" -Job ' + $jobId + ' -OllamaUrl ' + $script:TuzeUrl
                            Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop | Out-Null
                        } catch {
                            Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
                            throw
                        }
                        Send-Json $stream 200 @{job_id=$jobId;started=$true}
                    } elseif ($path -eq '/api/tuze/start') {
                        if ($payload.text -isnot [string] -or $payload.text.Length -gt 4000 -or $payload.mode -cnotin @('correct','natural')) { throw 'Түзету сұрауы жарамсыз.' }
                        $jobId = [guid]::NewGuid().ToString('N')
                        $inputPath = Join-Path $script:JobFolder ($jobId + '.input.json')
                        $workerPath = Join-Path $PSScriptRoot 'tuze-worker.ps1'
                        $workJson = ConvertTo-Json -InputObject @{text=$payload.text;mode=$payload.mode} -Compress
                        [System.IO.File]::WriteAllText($inputPath,$workJson,[System.Text.UTF8Encoding]::new($false))
                        try {
                            $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $workerPath + '" -Job ' + $jobId + ' -OllamaUrl ' + $script:TuzeUrl
                            Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop | Out-Null
                        } catch {
                            Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
                            throw
                        }
                        Send-Json $stream 200 @{job_id=$jobId;started=$true}
                    } else {
                        if ($payload.text -isnot [string] -or $payload.text.Length -gt 4000 -or $payload.mode -cnotin @('correct','natural')) { throw 'Түзету сұрауы жарамсыз.' }
                        Send-Json $stream 200 (Invoke-TuzeCorrection $payload.text $payload.mode)
                    }
                } catch {
                    $message=$_.Exception.Message
                    if ($message.StartsWith('CONFLICT:')) { Send-Json $stream 409 @{error=$message} }
                    elseif ($path -in @('/api/chat','/api/tuze','/api/tuze/start','/api/logo/start')) { Send-Json $stream 503 @{error=$message} }
                    else { Send-Json $stream 422 @{error=$message} }
                }
            } finally { $stream.Dispose() }
        } catch { Write-Host ('Сұрау қатесі: '+$_.Exception.Message) }
        finally { $client.Close() }
    }
} finally { $listener.Stop() }
