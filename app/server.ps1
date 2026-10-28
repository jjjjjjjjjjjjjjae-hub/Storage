param([int]$Port = 8790, [string]$OllamaUrl = '', [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tuze.ps1')
. (Join-Path $PSScriptRoot 'local.ps1')
. (Join-Path $PSScriptRoot 'secrets.ps1')
Initialize-Tuze $OllamaUrl
$encoding = [System.Text.UTF8Encoding]::new($false, $true)

function Send-Raw($Stream, [int]$Status, [string]$Type, [byte[]]$Body) {
    $reasons = @{200='OK';400='Bad Request';403='Forbidden';404='Not Found';409='Conflict';
        411='Length Required';413='Payload Too Large';415='Unsupported Media Type';
        422='Unprocessable Entity';500='Internal Server Error';503='Service Unavailable'}
    $reason = $reasons[$Status]
    $csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' https://api.github.com; base-uri 'none'; form-action 'none'"
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

function Get-VisionModel {
    try {
        $tags = Invoke-TuzeOllama 'GET' '/api/tags' $null 5
        $installed = @($tags.models | ForEach-Object { if ($_.name) { [string]$_.name } elseif ($_.model) { [string]$_.model } })
        foreach ($name in @('qwen3-vl:4b-instruct','qwen3-vl:4b','qwen3-vl:2b-instruct','qwen3-vl:2b')) {
            if ($installed -ccontains $name) { return $name }
        }
    } catch { return $null }
    return $null
}

function Invoke-ChatModel($Payload) {
    if ($null -eq $Payload.messages -or $Payload.messages -isnot [array] -or
        $Payload.messages.Count -lt 1 -or $Payload.messages.Count -gt 60) {
        throw 'Хабарламалар тізімі жарамсыз.'
    }
    $msgs = @(@{role='system';content='You are a helpful assistant. Reply in the language of the user, preferably Kazakh. Do not invent facts. Be concise.'})
    $total = 0; $hasImage = $false
    for ($i=0; $i -lt $Payload.messages.Count; $i++) {
        $m = $Payload.messages[$i]
        if ($m.role -cnotin @('user','assistant') -or $m.content -isnot [string] -or
            $m.content.Length -lt 1 -or $m.content.Length -gt 4000) { throw 'Хабарлама жарамсыз.' }
        $total += $m.content.Length
        $item = @{role=[string]$m.role;content=[string]$m.content}
        if ($m.PSObject.Properties.Name -ccontains 'image') {
            $photo = $m.image
            if ($i -ne ($Payload.messages.Count-1) -or $m.role -cne 'user' -or
                $null -eq $photo -or $photo.mime -cne 'image/jpeg' -or
                $photo.data -isnot [string] -or $photo.data.Length -gt 200000 -or
                $photo.data -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') { throw 'Фото жарамсыз.' }
            $item.images = @([string]$photo.data)
            $hasImage = $true
        }
        $msgs += $item
    }
    if ($total -gt 16000 -or $Payload.messages[-1].role -cne 'user') { throw 'Сұрау тым ұзын немесе соңғы хабарлама user емес.' }
    $model = if ($hasImage) { Get-VisionModel } else { [string]$script:TuzeConfig.model }
    if (-not $model) { throw 'Фото чатта сақталды. Оны AI талдауы үшін «ollama pull qwen3-vl:4b-instruct» орындап, қайта жіберіңіз.' }
    $request = @{model=$model;messages=$msgs;stream=$false;think=$false;keep_alive='10m';
        options=@{temperature=0.6;num_ctx=4096;num_predict=1024}}
    $response = Invoke-TuzeOllama 'POST' '/api/chat' $request ([int]$script:TuzeConfig.timeout_seconds)
    if ($response.done -cne $true -or $response.done_reason -eq 'length' -or
        $response.message.content -isnot [string] -or -not $response.message.content.Trim()) {
        throw 'Модель жауабы аяқталмады. Чаттағы сұрақ сақталған; қайталап көріңіз.'
    }
    return @{text=[string]$response.message.content;model=$model}
}

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
                    '/store.mjs'='store.mjs'; '/style.css'='style.css' }
                if ($method -eq 'GET' -and $static.ContainsKey($path)) {
                    $type=if ($path -eq '/') {'text/html; charset=utf-8'} elseif ($path -eq '/style.css') {'text/css; charset=utf-8'} else {'text/javascript; charset=utf-8'}
                    Send-Raw $stream 200 $type ([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $static[$path]))); continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/health') {
                    $health=Get-TuzeHealth; $vision=Get-VisionModel
                    $health.vision_ready=[bool]$vision; $health.vision_model=$vision
                    Send-Json $stream 200 $health; continue
                }
                if ($method -eq 'GET' -and $path -eq '/api/session') {
                    try { Send-Json $stream 200 @{master=(Get-TuzeMaster); token=(Read-TuzeSecret 'github-token'); legacy_passphrase=(Read-TuzeSecret 'legacy-passphrase')} }
                    catch { Send-Json $stream 503 @{error=$_.Exception.Message} }
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
                    ($method -eq 'POST' -and ($retireMatch.Success -or $path -in @('/api/chat','/api/tuze','/api/legacy/clear')))
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
                        Send-Json $stream 200 (Invoke-ChatModel $payload)
                    } elseif ($path -eq '/api/legacy/clear') {
                        Send-Json $stream 200 (Remove-TuzeSecret 'legacy-passphrase')
                    } else {
                        if ($payload.text -isnot [string] -or $payload.text.Length -gt 1200 -or $payload.mode -cnotin @('correct','natural')) { throw 'Түзету сұрауы жарамсыз.' }
                        Send-Json $stream 200 (Invoke-TuzeCorrection $payload.text $payload.mode)
                    }
                } catch {
                    $message=$_.Exception.Message
                    if ($message.StartsWith('CONFLICT:')) { Send-Json $stream 409 @{error=$message} }
                    elseif ($path -in @('/api/chat','/api/tuze')) { Send-Json $stream 503 @{error=$message} }
                    else { Send-Json $stream 422 @{error=$message} }
                }
            } finally { $stream.Dispose() }
        } catch { Write-Host ('Сұрау қатесі: '+$_.Exception.Message) }
        finally { $client.Close() }
    }
} finally { $listener.Stop() }
