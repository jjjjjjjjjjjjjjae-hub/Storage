# TUZE core; Windows PowerShell 5.1 and newer. No Python modules.
function Initialize-Tuze([string]$OllamaUrl = '') {
    $script:TuzeConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($env:TUZE_SELECTED_MODEL -and $env:TUZE_SELECTED_MODEL -ceq 'gpt-oss:20b') { $script:TuzeConfig.model = $env:TUZE_SELECTED_MODEL }
    $script:TuzePrompt = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tuze-prompt.txt') -Encoding UTF8 -Raw
    $script:TuzeSchema = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tuze-schema.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    $script:TuzeUrl = if ($OllamaUrl) { $OllamaUrl.TrimEnd('/') } else { ([string]$script:TuzeConfig.ollama_url).TrimEnd('/') }
    if ($script:TuzeUrl -notmatch '^http://(?:127\.0\.0\.1|localhost):\d+$') { throw 'Ollama адресі тек жергілікті болуы керек.' }
    if ([string]$script:TuzeConfig.model -cne 'gpt-oss:20b') { throw 'Модель gpt-oss:20b болуы керек.' }
}

function Invoke-TuzeOllama([string]$Method, [string]$Path, $Body = $null, [int]$Timeout = 5) {
    try {
        $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($script:TuzeUrl + $Path)
        $request.Method = $Method
        $request.Proxy = $null
        $request.Timeout = $Timeout * 1000
        $request.ReadWriteTimeout = $Timeout * 1000
        $request.Accept = 'application/json'
        if ($null -ne $Body) {
            $request.ContentType = 'application/json; charset=utf-8'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 20 -Compress))
            $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $response.Dispose() }
        $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) { throw 'JSON пішімі қате.' }
        if ($parsed.error) { throw 'Ollama модельді іске қоса алмады.' }
        return $parsed
    } catch {
        throw ('Ollama жауабы алынбады: ' + $_.Exception.Message)
    }
}

function Get-TuzeHealth {
    try {
        $data = Invoke-TuzeOllama 'GET' '/api/tags' $null 5
        $names = @($data.models | ForEach-Object { [string]$_.name })
        $ready = $names -ccontains [string]$script:TuzeConfig.model
        return @{ ready = $ready; model = [string]$script:TuzeConfig.model; available_models = $names; message = $(if ($ready) { 'Модель дайын.' } else { 'gpt-oss:20b моделі табылмады. ollama list орындап тексеріңіз.' }) }
    } catch {
        return @{ ready = $false; model = [string]$script:TuzeConfig.model; available_models = @(); message = 'Ollama-ға қосыла алмадым. Start-Storage.cmd файлын іске қосыңыз.' }
    }
}

function Get-TuzeMatches([string]$Value, [string]$Pattern) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($match in [regex]::Matches($Value, $Pattern)) { [void]$out.Add($match.Value) }
    return $out.ToArray()
}

function Test-TuzeBag([string[]]$A, [string[]]$B) {
    if ($A.Count -ne $B.Count) { return $false }
    $counts = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::Ordinal)
    foreach ($x in $A) { if ($counts.ContainsKey($x)) { $counts[$x]++ } else { $counts[$x] = 1 } }
    foreach ($x in $B) { if (-not $counts.ContainsKey($x)) { return $false }; $counts[$x]--; if ($counts[$x] -eq 0) { [void]$counts.Remove($x) } }
    return $counts.Count -eq 0
}

function Get-TuzeProtected([string]$Value) {
    $pattern = '(?s)```.*?```|`[^`\r\n]+`|https?://[^\s<>]+|www\.[^\s<>]+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|(?<!\w)@[\w.]+'
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($m in [regex]::Matches($Value, $pattern)) {
        $v = $m.Value
        if ($v -match '^(?:https?://|www\.)') { $v = $v.TrimEnd([char[]]'.,!?;:)]}') }
        [void]$out.Add($v)
    }
    return $out.ToArray()
}

function Convert-TuzeKeyboard([string]$Word) {
    $w = $Word.ToLowerInvariant()
    $from = 'әғқңөұүһі'; $to = 'агкноуухи'
    for ($i=0; $i -lt $from.Length; $i++) { $w = $w.Replace($from[$i], $to[$i]) }
    return $w
}

function Get-TuzeNegativeVerbs([string]$Value) {
    $pattern = '^(?i)[\p{L}]{2,}?(?:ма|ме|ба|бе|па|пе)(?:й(?:мын|мін|м|мыз|міз|сың|сің|сыз|сіз|сыңдар|сіңдер|ды|ді|тын|тін)|д[ыіи](?:м|ң|қ|к|ңыз|ңіз|ңдар|ңдер)?|ған[\p{L}]*|ген[\p{L}]*|са(?:м|ң|қ|ңыз|ңдар)?|се(?:м|ң|к|ңіз|ңдер)?|у(?:ы|і|ым|ім|ға|ге)?)$'
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($word in (Get-TuzeMatches $Value '[\p{L}]+')) { if ($word -match $pattern) { [void]$out.Add((Convert-TuzeKeyboard $word)) } }
    return $out.ToArray()
}

function Get-TuzeDistance([string]$A, [string]$B) {
    $n = $A.Length; $m = $B.Length
    $prev = [int[]]::new($m + 1); $cur = [int[]]::new($m + 1)
    for ($j=0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i=1; $i -le $n; $i++) {
        $cur[0] = $i
        for ($j=1; $j -le $m; $j++) {
            $cost = if ($A[$i - 1] -ceq $B[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [Math]::Min([Math]::Min(($prev[$j] + 1), ($cur[$j - 1] + 1)), ($prev[$j - 1] + $cost))
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return $prev[$m]
}

function Get-TuzeWarnings([string]$Original, [string]$Candidate) {
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if (-not $Candidate.Trim()) { [void]$warnings.Add('Модель бос мәтін қайтарды.'); return $warnings.ToArray() }
    if ($Candidate -match '(?i)<\|[^>]*\|>|</?think>|</?analysis>') { [void]$warnings.Add('Жауапта модельдің қызметтік белгілері бар.') }
    if (-not (Test-TuzeBag @(Get-TuzeMatches $Original '\d+(?:[.,:/-]\d+)*') @(Get-TuzeMatches $Candidate '\d+(?:[.,:/-]\d+)*'))) { [void]$warnings.Add('Сандар өзгерген. Бастапқы мәтін сақталды.') }
    if (-not (Test-TuzeBag @(Get-TuzeProtected $Original) @(Get-TuzeProtected $Candidate))) { [void]$warnings.Add('Сілтеме, email, пайдаланушы аты немесе код өзгерген.') }
    $neg = '(?i)\b(?:жоқ|емес|ешқашан|ешкім|ештеңе)\b'
    if (-not (Test-TuzeBag @((Get-TuzeMatches $Original $neg) | ForEach-Object { $_.ToLowerInvariant() }) @((Get-TuzeMatches $Candidate $neg) | ForEach-Object { $_.ToLowerInvariant() }))) { [void]$warnings.Add('Болымсыздық сөзі өзгерген.') }
    if (-not (Test-TuzeBag @(Get-TuzeNegativeVerbs $Original) @(Get-TuzeNegativeVerbs $Candidate))) { [void]$warnings.Add('Болымсыз етістік өзгерген; мағынаны тексеріңіз.') }
    $source = @(Get-TuzeMatches $Original '[\p{L}]+') | ForEach-Object { Convert-TuzeKeyboard $_ }
    $novel = New-Object 'System.Collections.Generic.List[string]'
    foreach ($word in @(Get-TuzeMatches $Candidate '[\p{L}]+')) {
        if ($word.Length -lt 7 -or $source.Count -eq 0) { continue }
        $norm = Convert-TuzeKeyboard $word; $best = 0.0
        foreach ($s in $source) {
            if ([Math]::Abs($norm.Length - $s.Length) -ge [Math]::Max($norm.Length, $s.Length) * 0.5) { continue }
            $ratio = 1.0 - ((Get-TuzeDistance $norm $s) / [double][Math]::Max($norm.Length, $s.Length))
            if ($ratio -gt $best) { $best = $ratio }
            if ($best -ge 0.5) { break }
        }
        if ($best -lt 0.5 -and -not $novel.Contains($word)) { [void]$novel.Add($word) }
    }
    if ($novel.Count) { [void]$warnings.Add('Бастапқы сөздерге ұқсамайтын жаңа сөз бар: ' + ($novel -join ', ')) }
    $repeat = '(?i)([\p{L}])\1{8,}|\b([\p{L}]+)(?:\s+\2){3,}\b'
    if ($Candidate -match $repeat -and $Original -notmatch $repeat) { [void]$warnings.Add('Модель мәтінді қайталай берген.') }
    if ($Candidate.Length -gt [Math]::Max(160, $Original.Length * 2.5)) { [void]$warnings.Add('Жауап бастапқы мәтіннен тым ұзақ.') }
    if ($Original.Trim().Length -gt 40 -and $Candidate.Trim().Length -lt $Original.Trim().Length * 0.45) { [void]$warnings.Add('Мәтіннің үлкен бөлігі жоғалған болуы мүмкін.') }
    if ($Candidate -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { [void]$warnings.Add('Жауапта жарамсыз басқару таңбалары бар.') }
    return $warnings.ToArray()
}

function Invoke-TuzeCorrection([string]$Text, [string]$Mode) {
    $model = [string]$script:TuzeConfig.model
    if (-not $Text.Trim()) { return @{ original_text=$Text; corrected_text=$Text; status='unchanged'; suggested_text=$null; warnings=@(); edits=@(); model=$model; mode=$Mode; duration_seconds=0.0; tokens_per_second=$null } }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $keep = @(Get-TuzeMatches $Text '[\p{L}]+') | Where-Object { $_ -match '(?i)^(?=.{4,}$)[\p{L}]+?(?:ма|ме|ба|бе|па|пе)(?:й(?:мын|мін|м|мыз|міз|сың|сің|сыз|сіз)|д[ыіи](?:м|ң)?|ған[\p{L}]*|ген[\p{L}]*)$' }
    $userData = @{mode=$Mode; text=$Text; keep_exactly=@($keep)} | ConvertTo-Json -Depth 6 -Compress
    $request = @{
        model=$model; stream=$false; think='low'; format=$script:TuzeSchema; keep_alive='10m'
        messages=@(@{role='system';content=($script:TuzePrompt + "`nJSON schema: " + (ConvertTo-Json -InputObject $script:TuzeSchema -Depth 10 -Compress))}, @{role='user';content=$userData})
        options=@{temperature=0.2; top_p=0.8; top_k=20; min_p=0; repeat_penalty=1.1; seed=42; num_ctx=[int]$script:TuzeConfig.num_ctx; num_predict=[int]$script:TuzeConfig.num_predict}
    }
    $data = Invoke-TuzeOllama 'POST' '/api/chat' $request ([int]$script:TuzeConfig.timeout_seconds)
    if ($data.done -cne $true -or $data.done_reason -eq 'length') { throw 'Модель жауабы аяқталмай қалды; нәтиже қолданылмады.' }
    if ($null -eq $data.message -or $data.message.content -isnot [string]) { throw 'Модель мәтіндік жауап қайтармады.' }
    try { $answer = ConvertFrom-Json -InputObject $data.message.content -ErrorAction Stop } catch { throw 'Модель JSON пішімін сақтамады; нәтиже қолданылмады.' }
    $keys = @($answer.PSObject.Properties.Name)
    if ($answer -isnot [pscustomobject] -or $keys.Count -ne 2 -or $keys -cnotcontains 'corrected_text' -or $keys -cnotcontains 'uncertain' -or $answer.corrected_text -isnot [string] -or $answer.corrected_text.Length -lt 1 -or $answer.corrected_text.Length -gt 3600 -or $answer.uncertain -isnot [bool]) { throw 'Модель жауабы талап етілген пішімге сай емес.' }
    $candidate = [string]$answer.corrected_text
    $warnings = @(Get-TuzeWarnings $Text $candidate)
    if ($answer.uncertain) { $warnings += 'Модель мағынаны нақты ажырата алмады. Ұсынысты қолмен тексеріңіз.' }
    $review = $warnings.Count -gt 0
    $corrected = if ($review) { $Text } else { $candidate }
    $edits = @()
    if (-not $review -and $Text -cne $corrected) {
        $prefix = 0
        while ($prefix -lt [Math]::Min($Text.Length, $corrected.Length) -and $Text[$prefix] -ceq $corrected[$prefix]) { $prefix++ }
        $aEnd = $Text.Length; $bEnd = $corrected.Length
        while ($aEnd -gt $prefix -and $bEnd -gt $prefix -and $Text[$aEnd - 1] -ceq $corrected[$bEnd - 1]) { $aEnd--; $bEnd-- }
        $edits = @(@{start=$prefix;end=$aEnd;before=$Text.Substring($prefix, $aEnd-$prefix);after=$corrected.Substring($prefix, $bEnd-$prefix)})
    }
    $clock.Stop()
    $speed = $null
    if ($data.eval_duration -is [ValueType] -and $data.eval_count -is [ValueType] -and [double]$data.eval_duration -gt 0) { $speed = [Math]::Round(([double]$data.eval_count * 1000000000.0 / [double]$data.eval_duration),2) }
    return @{ original_text=$Text; corrected_text=$corrected; status=$(if ($review) {'needs_review'} elseif ($Text -ceq $corrected) {'unchanged'} else {'corrected'}); suggested_text=$(if ($review) {$candidate} else {$null}); warnings=@($warnings); edits=@($edits); model=$model; mode=$Mode; duration_seconds=[Math]::Round($clock.Elapsed.TotalSeconds,3); tokens_per_second=$speed }
}
