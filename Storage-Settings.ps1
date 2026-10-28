param([ValidateSet('Menu','Export','Import')][string]$Action = 'Menu', [string]$Path = '')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'app\secrets.ps1')

function Read-PrivateValue([string]$Prompt) {
    $secret = Read-Host $Prompt -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $secret.Dispose() }
}

function Save-RecoveryFile([string]$Destination) {
    if (-not $Destination) { throw 'Файл жолын енгізіңіз.' }
    $path = [System.IO.Path]::GetFullPath($Destination.Trim('"'))
    $project = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($path.StartsWith($project,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Қалпына келтіру кілтін Storage қалтасына сақтамаңыз. Бөлек орын таңдаңыз.'
    }
    if (-not [System.IO.Directory]::Exists([System.IO.Path]::GetDirectoryName($path))) {
        throw 'Көрсетілген қалта табылмады.'
    }
    $value = Get-TuzeMaster
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($value + "`r`n")
    $file = [System.IO.FileStream]::new($path,[System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,[System.IO.FileShare]::None,4096,[System.IO.FileOptions]::WriteThrough)
    try { $file.Write($bytes,0,$bytes.Length); $file.Flush($true) }
    finally { $file.Dispose() }
    Write-Host ('Кілт сақталды: ' + $path)
    Write-Host 'Бұл файлды құпия ұстаңыз; репозиторийге жүктемеңіз.'
}

function Load-RecoveryFile([string]$Source) {
    $path = $Source.Trim('"')
    $key = [System.IO.File]::ReadAllText($path,[System.Text.Encoding]::UTF8).Trim()
    [void](Import-TuzeMaster $key)
    $key = $null
    Write-Host 'Кілт қорғалып сақталды. Ашық чат беті өзі жаңарады.'
}

if ($Action -eq 'Export') { Save-RecoveryFile $Path; return }
if ($Action -eq 'Import') { Load-RecoveryFile $Path; return }

while ($true) {
    Write-Host ''
    Write-Host 'TUZE · сыртқы баптау'
    Write-Host '1  GitHub-қа браузер арқылы кіру (Google аккаунтымен де болады)'
    Write-Host '2  Қалпына келтіру кілтін файлға шығару'
    Write-Host '3  Қалпына келтіру кілтін файлдан енгізу'
    Write-Host '4  Ескі чат кілтсөзін көшіруге беру'
    Write-Host '5  Қолмен енгізілген GitHub токенін өшіру'
    Write-Host '6  GitHub токенін қолмен сақтау (балама)'
    Write-Host '0  Шығу'
    $choice = Read-Host 'Таңдау'
    try {
        switch ($choice) {
            '1' {
                $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue
                if (-not $gh) {
                    Write-Host 'GitHub CLI орнатылмаған. Алдымен ресми нұсқасын орнатыңыз:'
                    Write-Host 'winget install --id GitHub.cli --source winget'
                    Start-Process 'https://cli.github.com/'
                    Write-Host 'Орнатқан соң бұл терезені қайта ашып, 1 таңдаңыз.'
                } else {
                    & $gh.Source auth login --hostname github.com --web --git-protocol https --skip-ssh-key
                    if ($LASTEXITCODE -ne 0) { throw 'GitHub арқылы кіру аяқталмады.' }
                    & $gh.Source auth status --active --hostname github.com | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'GitHub рұқсаты алынбады.' }
                    Write-Host 'GitHub қосылды. Ашық Tuze чаты өзі синхрондалады.'
                }
            }
            '2' { Save-RecoveryFile (Read-Host 'Storage қалтасынан тыс толық файл жолы') }
            '3' { Load-RecoveryFile (Read-Host 'Бұрын сақталған кілт файлының толық жолы') }
            '4' {
                $old = Read-PrivateValue 'Ескі нұсқадағы чат кілтсөзі (экранда көрінбейді)'
                [void](Save-LegacyPassphrase $old)
                $old = $null
                Write-Host 'Кілтсөз уақытша қорғалып сақталды. Чаттарды көшіру автоматты басталады.'
            }
            '5' { [void](Remove-TuzeSecret 'github-token'); Write-Host 'Қолмен берілген GitHub токені өшірілді.' }
            '6' {
                $token = Read-PrivateValue 'GitHub токені (экранда көрінбейді)'
                [void](Save-GitHubToken $token)
                $token = $null
                Write-Host 'Токен Windows профилінде қорғалып сақталды. Чат беті өзі қосылады.'
            }
            '0' { return }
            default { Write-Host '0–6 арасындағы санды таңдаңыз.' }
        }
    } catch { Write-Host ('Қате: ' + $_.Exception.Message) -ForegroundColor Red }
}
