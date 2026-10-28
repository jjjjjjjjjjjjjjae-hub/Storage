# Shared chat model request logic for foreground test and background worker.
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

# Stream Ollama responses so the browser can show tokens while the local model is running.
# Progress is stored in LocalAppData, never in the public website or GitHub directly.
function Save-ChatProgress([string]$Path, [string]$Stage, [string]$Text) {
    if (-not $Path) { return }
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = ConvertTo-Json -InputObject @{ stage=$Stage; text=$Text; updated_at=[DateTime]::UtcNow.ToString('o') } -Depth 4 -Compress
        [System.IO.File]::WriteAllText($tmp,$json,[System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp,$Path,$null) }
        else { [System.IO.File]::Move($tmp,$Path) }
    } catch { # Progress is best effort; it must never interrupt the model response.
    } finally { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } }
}

function Invoke-TuzeOllamaStream($Payload, [string]$ProgressPath, [int]$TimeoutSeconds) {
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($script:TuzeUrl + '/api/chat')
    $request.Method = 'POST'
    $request.Proxy = $null
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $request.ContentType = 'application/json; charset=utf-8'
    $request.Accept = 'application/x-ndjson, application/json'
    $json = ConvertTo-Json -InputObject $Payload -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $request.ContentLength = $bytes.Length
    Save-ChatProgress $ProgressPath 'loading' ''
    try {
        $out = $request.GetRequestStream()
        try { $out.Write($bytes,0,$bytes.Length) } finally { $out.Dispose() }
        $response = $request.GetResponse()
        $text = [System.Text.StringBuilder]::new()
        $done = $false
        $reason = ''
        $lastUpdate = [DateTime]::UtcNow.AddSeconds(-2)
        try {
            $reader = [System.IO.StreamReader]::new($response.GetResponseStream(),[System.Text.Encoding]::UTF8)
            try {
                while ($null -ne ($line=$reader.ReadLine())) {
                    if (-not $line.Trim()) { continue }
                    $part = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                    if ($part.error) { throw ('Ollama: ' + [string]$part.error) }
                    if ($part.message -and $part.message.content -is [string]) {
                        [void]$text.Append([string]$part.message.content)
                    }
                    if (($text.Length -gt 0) -and ([DateTime]::UtcNow - $lastUpdate).TotalSeconds -ge 0.45) {
                        Save-ChatProgress $ProgressPath 'generating' $text.ToString()
                        $lastUpdate=[DateTime]::UtcNow
                    }
                    if ($part.done -eq $true) {
                        $done=$true; $reason=[string]$part.done_reason
                        break
                    }
                }
            } finally { $reader.Dispose() }
        } finally { $response.Dispose() }
        $answer=$text.ToString()
        Save-ChatProgress $ProgressPath 'generating' $answer
        if (-not $done -and -not $answer.Trim()) { throw 'Ollama жауап бермеді.' }
        if (-not $answer.Trim()) { throw 'Модель бос жауап қайтарды. RAM жетіспеуі мүмкін.' }
        if (-not $done -or $reason -eq 'length') {
            $answer += "`n`n⚠ Жауап толық аяқталмады. Қалғанын сұрау үшін «жалғастыр» деп жаз."
        }
        return @{text=$answer; model=[string]$Payload.model}
    } catch [System.Net.WebException] {
        $details=$_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $errReader=[System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                try { $errText=$errReader.ReadToEnd() } finally { $errReader.Dispose() }
                if ($errText) { $details=$errText }
            } catch { }
        }
        throw ('Ollama іске қосылмады: ' + $details + '. Жадты тексер: ollama ps')
    }
}

function Invoke-ChatModel($Payload, [string]$ProgressPath = '') {
    if ($null -eq $Payload.messages -or $Payload.messages -isnot [array] -or
        $Payload.messages.Count -lt 1 -or $Payload.messages.Count -gt 60) {
        throw 'Хабарламалар тізімі жарамсыз.'
    }
    $systemText = @'
You are TUZE, a helpful local assistant. Reply in Kazakh when the user writes in Kazakh.
If the user asks you to CREATE OR MODIFY CODE, include real complete code (not just a description) inside Markdown fenced code blocks.
Add a filename for EVERY code block. Use precisely this format:
```html filename="index.html"
<!doctype html><html>...</html>
```
For separate CSS and JS files, add separate code fences named style.css and script.js, and refer to them from index.html with local relative paths. For a simple demo, prefer a self-contained index.html. For Python use ```python filename="main.py". Do not invent unsupported APIs or report untested code as tested.
Do not omit key parts of runnable source code or replace code with placeholders. Explain briefly in Kazakh outside code blocks.
'@
    $msgs = @(@{role='system';content=$systemText})
    $total = 0; $hasImage = $false
    for ($i=0; $i -lt $Payload.messages.Count; $i++) {
        $m = $Payload.messages[$i]
        if ($m.role -cnotin @('user','assistant') -or $m.content -isnot [string] -or
            $m.content.Length -lt 1 -or
            $m.content.Length -gt $(if ($m.role -ceq 'assistant') { 11000 } else { 4000 })) { throw 'Хабарлама жарамсыз.' }
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
    # Short requests should not generate 3000 tokens on a slow laptop.
    $lastText = [string]$Payload.messages[-1].content
    $isCode = $lastText -match '(?i)(код|сайт|html|javascript|css|python|api|жаса|жазып|әзірле|build|create|code|program|файл|script|website|app)'
    $tokens = if ($isCode) { [int]$script:TuzeConfig.num_predict } else { 512 }
    $thinking = if ($hasImage) { $false } else { 'low' }
    $request = @{model=$model;messages=$msgs;stream=[bool]$ProgressPath;think=$thinking;keep_alive='5m';
        options=@{temperature=0.25;num_ctx=[int]$script:TuzeConfig.num_ctx;num_predict=$tokens}}
    if ($ProgressPath) { return Invoke-TuzeOllamaStream $request $ProgressPath ([int]$script:TuzeConfig.timeout_seconds) }
    $response = Invoke-TuzeOllama 'POST' '/api/chat' $request ([int]$script:TuzeConfig.timeout_seconds)
    if ($response.done -cne $true -or $response.done_reason -eq 'length' -or
        $response.message.content -isnot [string] -or -not $response.message.content.Trim()) {
        throw 'Модель жауабы аяқталмады. Чаттағы сұрақ сақталған; қайталап көріңіз.'
    }
    return @{text=[string]$response.message.content;model=$model}
}

