$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

# Pinned official Windows CPU build and the official SD-Turbo checkpoint.
$cliUrl='https://github.com/leejet/stable-diffusion.cpp/releases/download/master-1024-77b72a2/sd-master-77b72a2-bin-win-cpu-x64.zip'
$cliHash='f56a021629bfbff2a4725af97147ae84090eb075489a5ce7883daaaf87d4169d'
$modelUrl='https://huggingface.co/stabilityai/sd-turbo/resolve/9fee4496504b3b0e95e11c80bdf0fb0c7a5d4aa8/sd_turbo.safetensors?download=true'
$modelHash='3f067a1b943cf162f2b8f8588f6cf5824bd5b4c7d1d88d87164b9ca123616549'
$folder=Join-Path $env:LOCALAPPDATA 'TuzeStorage\image'
[void][System.IO.Directory]::CreateDirectory($folder)

function Download-Verified([string]$Url,[string]$Destination,[string]$ExpectedHash) {
    if ([System.IO.File]::Exists($Destination)) {
        if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ieq $ExpectedHash) {
            Write-Host ('Дайын: '+$Destination)
            return
        }
        throw ('Бар файлдың хэші сәйкес емес: '+$Destination+'. Оны қолмен тексеріп, қайта орнатыңыз.')
    }
    $partial=$Destination+'.partial'
    if ([System.IO.File]::Exists($partial)) { [System.IO.File]::Delete($partial) }
    Write-Host ('Бір рет жүктелуде: '+$Url)
    Add-Type -AssemblyName System.Net.Http
    $handler=[System.Net.Http.HttpClientHandler]::new()
    $client=[System.Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromHours(3)
    try {
        $response=$client.GetAsync($Url,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            [void]$response.EnsureSuccessStatusCode()
            $source=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $target=[System.IO.File]::Open($partial,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
                try {
                    $buffer=[byte[]]::new(1048576)
                    $received=0L
                    $total=$response.Content.Headers.ContentLength
                    while (($count=$source.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $target.Write($buffer,0,$count)
                        $received+=$count
                        if ($received % 52428800 -lt 1048576) {
                            $detail=('{0:N0} МБ' -f ($received / 1MB))
                            if ($total -and $total -gt 0) {
                                Write-Progress -Activity 'Сурет моделі жүктелуде' -Status $detail -PercentComplete ([Math]::Min(100,100*$received/$total))
                            } else { Write-Progress -Activity 'Сурет моделі жүктелуде' -Status $detail }
                        }
                    }
                    Write-Progress -Activity 'Сурет моделі жүктелуде' -Completed
                } finally { $target.Dispose() }
            } finally { $source.Dispose() }
        } finally { $response.Dispose() }
    } finally { $client.Dispose(); $handler.Dispose() }
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $ExpectedHash) {
        [System.IO.File]::Delete($partial)
        throw 'Жүктелген файлдың SHA256 тексерісі өтпеді.'
    }
    [System.IO.File]::Move($partial,$Destination)
}

try {
    $archive=Join-Path $folder 'sd-cli-win-cpu.zip'
    $bin=Join-Path $folder 'bin'
    $model=Join-Path $folder 'sd_turbo.safetensors'
    $cli=Get-ChildItem -LiteralPath $bin -Filter 'sd-cli.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cli) {
        Download-Verified $cliUrl $archive $cliHash
        Expand-Archive -LiteralPath $archive -DestinationPath $bin -Force
        $cli=Get-ChildItem -LiteralPath $bin -Filter 'sd-cli.exe' -Recurse -File | Select-Object -First 1
        if (-not $cli) { throw 'sd-cli.exe архивтен табылмады.' }
    }
    Write-Host 'SD-Turbo салмағы 5,21 ГБ. Жүктеу уақыты интернетке байланысты.'
    Download-Verified $modelUrl $model $modelHash
    Write-Host 'Сурет жасау дайын. TUZE чат терезесін қайта ашып, «Сурет» батырмасын басыңыз.'
} catch {
    Write-Host ('Орнату қатесі: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
}
