param([Parameter(Mandatory=$true)][string]$Job, [string]$OllamaUrl='')
$ErrorActionPreference='Stop'
if ($Job -cnotmatch '^[0-9a-f]{32}$') { throw 'Сурет тапсырмасының нөмірі жарамсыз.' }
$folder=Join-Path $env:LOCALAPPDATA 'TuzeStorage\jobs'
$inputPath=Join-Path $folder ($Job+'.input.json')
$resultPath=Join-Path $folder ($Job+'.result.json')
. (Join-Path $PSScriptRoot 'tuze.ps1')
. (Join-Path $PSScriptRoot 'image-model.ps1')
try {
    Initialize-Tuze $OllamaUrl
    $payload=Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $image=Invoke-TuzeImage ([string]$payload.text) $Job
    $result=@{done=$true;result=$image}
} catch {
    $result=@{done=$true;error=('Сурет жасау қатесі: '+$_.Exception.Message)}
}
$temp=$resultPath+'.tmp'
[System.IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $result -Depth 5 -Compress),[System.Text.UTF8Encoding]::new($false))
[System.IO.File]::Move($temp,$resultPath)
try { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue } catch { }
