$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

try {
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'app\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $model = [string]$config.model
    $ollamaUrl = ([string]$config.ollama_url).TrimEnd('/')
    if ($model -cne 'gpt-oss:20b' -or $ollamaUrl -notmatch '^http://(?:127\.0\.0\.1|localhost):\d+$') {
        throw 'config.json: gpt-oss:20b моделін және жергілікті Ollama адресін көрсетіңіз.'
    }

    $command = Get-Command ollama.exe -ErrorAction SilentlyContinue
    $ollama = if ($command) { $command.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe' }
    if (-not (Test-Path -LiteralPath $ollama)) {
        Write-Host 'Ollama орнатылмаған. Мына ресми беттен Windows нұсқасын орнатыңыз:'
        Write-Host 'https://ollama.com/download/windows'
        Start-Process 'https://ollama.com/download/windows'
        throw 'Ollama орнатқаннан кейін Start-Storage.cmd файлын қайта ашыңыз.'
    }

    function Test-OllamaReady {
        try {
            return (Invoke-RestMethod -Uri ($ollamaUrl + '/api/tags') -TimeoutSec 3)
        } catch { return $null }
    }
    $tags = Test-OllamaReady
    if ($null -eq $tags) {
        Write-Host 'Ollama іске қосылуда...'
        $oldHost = $env:OLLAMA_HOST
        try {
            $env:OLLAMA_HOST = $ollamaUrl
            Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
        } finally { $env:OLLAMA_HOST = $oldHost }
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            $tags = Test-OllamaReady
            if ($null -ne $tags) { break }
        }
    }
    if ($null -eq $tags) { throw 'Ollama сервері іске қосылмады. Ollama қолданбасын ашып, қайта көріңіз.' }

    $installed = @($tags.models | ForEach-Object { if ($_.name) { [string]$_.name } elseif ($_.model) { [string]$_.model } })
    if ($installed -cnotcontains $model) {
        Write-Host ('Орнатылған модельдер: ' + ($installed -join ', '))
        throw 'gpt-oss:20b табылмады. Терминалда: ollama list орындаңыз. Модель автоматты жүктелмейді.'
    }
    $env:TUZE_SELECTED_MODEL = $model
    Write-Host ('Қолданылатын модель: ' + $model)
    & (Join-Path $PSScriptRoot 'app\server.ps1') -OllamaUrl $ollamaUrl
} catch {
    Write-Host ('Қате: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
