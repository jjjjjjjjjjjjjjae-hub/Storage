param([Parameter(Mandatory=$true)][string]$Job, [string]$OllamaUrl='')
$ErrorActionPreference = 'Stop'
if ($Job -cnotmatch '^[0-9a-f]{32}$') { throw 'Чат тапсырмасының нөмірі жарамсыз.' }
$folder = Join-Path $env:LOCALAPPDATA 'TuzeStorage\jobs'
$inputPath = Join-Path $folder ($Job + '.input.json')
$resultPath = Join-Path $folder ($Job + '.result.json')
$progressPath = Join-Path $folder ($Job + '.progress.json')
. (Join-Path $PSScriptRoot 'tuze.ps1')
. (Join-Path $PSScriptRoot 'chat-model.ps1')
try {
    Initialize-Tuze $OllamaUrl
    $payload = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $answer = Invoke-ChatModel $payload $progressPath
    $result = @{done=$true;result=$answer}
} catch {
    $result = @{done=$true;error=('gpt-oss:20b қатесі: ' + $_.Exception.Message)}
}
$temp = $resultPath + '.tmp'
[System.IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $result -Depth 18 -Compress),[System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($temp,$resultPath)
try { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue } catch { }
