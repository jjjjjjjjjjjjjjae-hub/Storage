# TUZE local image generation. The model and executable live outside the project and GitHub.
function Get-TuzeImageRuntime {
    $folder = Join-Path $env:LOCALAPPDATA 'TuzeStorage\image'
    $model = if ($env:TUZE_IMAGE_MODEL) { $env:TUZE_IMAGE_MODEL } else { Join-Path $folder 'sd_turbo.safetensors' }
    $cli = $env:TUZE_IMAGE_CLI
    if (-not $cli -and [System.IO.Directory]::Exists((Join-Path $folder 'bin'))) {
        $found = Get-ChildItem -LiteralPath (Join-Path $folder 'bin') -File -Recurse -Filter 'sd-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $cli = $found.FullName }
    }
    return @{ready=([System.IO.File]::Exists($model) -and [System.IO.File]::Exists($cli));
        model=$model; cli=$cli}
}

function Invoke-TuzeImage([string]$Text, [string]$Job) {
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 800 -or
        $Job -cnotmatch '^[0-9a-f]{32}$') { throw 'Сурет сипаттамасы жарамсыз.' }
    $runtime = Get-TuzeImageRuntime
    if (-not $runtime.ready) { throw 'Сурет моделі жоқ. Storage\Setup-Images.cmd файлын бір рет іске қосыңыз.' }
    $prompt = $Text.Trim()
    # SD-Turbo understands English prompts best. Translation is optional if Ollama is busy.
    try {
        $schema = @{type='object';required=@('prompt_en');additionalProperties=$false;
            properties=@{prompt_en=@{type='string'}}}
        $request = @{model=[string]$script:TuzeConfig.model;stream=$false;think='low';format=$schema;
            keep_alive=0;messages=@(
                @{role='system';content='Translate the user image description into a faithful, concise English text-to-image prompt. Preserve objects, colors, people, negations and composition. Return only the requested JSON.'},
                @{role='user';content=$prompt});
            options=@{num_ctx=2048;num_predict=180;temperature=0.1}}
        $translated = Invoke-TuzeOllama 'POST' '/api/chat' $request 180
        if ($translated.done -eq $true) {
            $json = ConvertFrom-Json -InputObject ([string]$translated.message.content) -ErrorAction Stop
            if ($json.prompt_en -is [string] -and $json.prompt_en.Trim().Length -ge 3 -and $json.prompt_en.Length -le 900) {
                $prompt = $json.prompt_en.Trim()
            }
        }
    } catch { # An English description works even if Ollama could not translate.
    }
    $jobs = Join-Path $env:LOCALAPPDATA 'TuzeStorage\jobs'
    $promptFile = Join-Path $jobs ($Job + '.prompt.txt')
    $outputFile = Join-Path $jobs ($Job + '.png')
    $stdout = Join-Path $jobs ($Job + '.image.stdout.txt')
    $stderr = Join-Path $jobs ($Job + '.image.stderr.txt')
    $success = $false
    try {
        [System.IO.File]::WriteAllText($promptFile,$prompt,[System.Text.UTF8Encoding]::new($false))
        # All paths are controlled locally. The user's words are read from a file, never parsed as CLI options.
        $cliArgs = @('--model',('"' + $runtime.model + '"'),'--prompt-file',('"' + $promptFile + '"'),
            '--output',('"' + $outputFile + '"'),'--steps','2','--cfg-scale','1.0',
            '--backend','cpu','-W','512','-H','512')
        $process = Start-Process -FilePath $runtime.cli -ArgumentList $cliArgs -WorkingDirectory (Split-Path -Parent $runtime.cli) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $process.WaitForExit(1800000)) {
            try { $process.Kill() } catch { }
            throw 'Сурет жасау 30 минуттан асты. Ноутбуктің жедел жадын тексеріңіз.'
        }
        if (-not [System.IO.File]::Exists($outputFile)) {
            # Some sd-cli builds add an index to the output filename.
            $alternative = Get-ChildItem -LiteralPath $jobs -File -Filter ($Job + '_*.png') -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -cmatch ('^' + $Job + '_\d+\.png$') } | Select-Object -First 1
            if ($alternative) { $outputFile = $alternative.FullName }
        }
        if (-not [System.IO.File]::Exists($outputFile)) {
            # sd-cli commonly logs to stdout. Keep both local logs on failure.
            $details = @()
            foreach ($log in @($stderr,$stdout)) {
                if ([System.IO.File]::Exists($log)) {
                    $details += @(Get-Content -LiteralPath $log -Tail 12 -ErrorAction SilentlyContinue)
                }
            }
            $detailText = (($details -join ' ') -replace '\s+', ' ').Trim()
            if ($detailText.Length -gt 1500) { $detailText = $detailText.Substring($detailText.Length - 1500) }
            $exitCode = try { $process.Refresh(); [string]$process.ExitCode } catch { '?' }
            throw ('sd-cli сурет файлын жасамады (exit ' + $exitCode + '). ' + $detailText +
                ' Журналдар: ' + $stdout + ' және ' + $stderr)
        }
        $bytes = [System.IO.File]::ReadAllBytes($outputFile)
        if ($bytes.Length -lt 16 -or $bytes.Length -gt 4194304 -or
            $bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71) {
            throw 'Модель жарамды PNG суретін қайтармады.'
        }
        $success = $true
        return @{image_base64=[Convert]::ToBase64String($bytes);prompt_en=$prompt}
    } finally {
        $remove = @($promptFile,$outputFile)
        if ($success) { $remove += @($stdout,$stderr) }
        foreach ($path in $remove) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}
