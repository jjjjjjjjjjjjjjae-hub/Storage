param([Parameter(Mandatory=$true)][string]$Job, [string]$OllamaUrl='')
$ErrorActionPreference = 'Stop'
if ($Job -cnotmatch '^[0-9a-f]{32}$') { throw 'Жұмыс нөмірі жарамсыз.' }
$folder = Join-Path $env:LOCALAPPDATA 'TuzeStorage\jobs'
$inputPath = Join-Path $folder ($Job + '.input.json')
$resultPath = Join-Path $folder ($Job + '.result.json')
. (Join-Path $PSScriptRoot 'tuze.ps1')
. (Join-Path $PSScriptRoot 'logo-ai.ps1')
try {
    Initialize-Tuze $OllamaUrl
    $payload = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($payload.text -isnot [string] -or $payload.text.Length -lt 1 -or $payload.text.Length -gt 4000 -or
        $payload.stage -cnotin @('analyze','build') -or $null -eq $payload.answers -or
        $payload.answers -isnot [array]) { throw 'Logo&AI сұрауы дұрыс емес.' }
    $data = Invoke-LogoAi ([string]$payload.text) ([string]$payload.stage) (@($payload.answers))
    $result = @{done=$true;result=$data}
} catch {
    $result = @{done=$true;error=('Logo&AI қатесі: ' + $_.Exception.Message)}
}
$temporary = $resultPath + '.tmp'
[System.IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $result -Depth 18 -Compress), [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($temporary,$resultPath)
try { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue } catch { }
