$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'secrets.ps1')
$script:LoginStatusPath = Join-Path $env:LOCALAPPDATA 'TuzeStorage\github-login-status.json'
function Set-TuzeLoginStatus([string]$Status,[string]$Info='') {
    $data = @{status=$Status; message=$Info; updated_at=[DateTime]::UtcNow.ToString('o')}
    $target = $script:LoginStatusPath
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null
    [System.IO.File]::WriteAllText($target, (ConvertTo-Json -InputObject $data -Compress), [System.Text.UTF8Encoding]::new($false))
}
try {
    Set-TuzeLoginStatus 'waiting' 'GitHub браузерін ашыңыз.'
    $gh = Find-TuzeGh
    if (-not $gh) {
        Write-Host 'GitHub CLI жоқ. Оны Windows PowerShell-де бір рет орнатыңыз:' -ForegroundColor Yellow
        Write-Host 'winget install --id GitHub.cli --source winget'
        Write-Host 'Содан кейін TUZE чатында «GitHub арқылы кіру» түймесін қайта басыңыз.'
        Set-TuzeLoginStatus 'error' 'GitHub CLI орнатылмаған. winget install --id GitHub.cli --source winget орындаңыз.'
    } else {
        Write-Host 'TUZE — GitHub ресми браузер авторизациясы' -ForegroundColor Cyan
        Write-Host 'Токенді TUZE терезесіне енгізудің қажеті жоқ.'
        if (Get-GitHubAuthToken) {
            Write-Host 'Бұл Windows пайдаланушысы GitHub-қа әлдеқашан кірген.' -ForegroundColor Green
            Set-TuzeLoginStatus 'authenticated' 'GitHub аккаунты қосылды.'
        } else {
            # The GitHub CLI might print a Git-not-installed warning after successful OAuth.
            # Authentication success is confirmed by a fresh auth token lookup below.
            Write-Host 'Git орнатылмаса, Git credentials сұрағына N таңдаңыз. TUZE үшін Git қажет емес.'
            & $gh auth login --hostname github.com --web --clipboard --scopes 'repo,read:user'
            if (Get-GitHubAuthToken) {
                Write-Host 'GitHub аккаунты қосылды! TUZE чат беті өздігінен ашылады.' -ForegroundColor Green
                Set-TuzeLoginStatus 'authenticated' 'GitHub аккаунты қосылды.'
            } else {
                Write-Host 'GitHub авторизациясы аяқталмады. Жоғарыдағы қатені тексеріп, қайта кіріңіз.' -ForegroundColor Red
                Set-TuzeLoginStatus 'error' 'Авторизация аяқталмады. GitHub терезесіндегі нұсқаулықты қараңыз.'
            }
        }
    }
} catch {
    Write-Host ('Кіру қатесі: ' + $_.Exception.Message) -ForegroundColor Red
    Set-TuzeLoginStatus 'error' ('GitHub авторизация қатесі: '+$_.Exception.Message)
    if (Get-GitHubAuthToken) { Write-Host 'GitHub авторизациясы сақталған. TUZE-ге қайта оралыңыз.' -ForegroundColor Green; Set-TuzeLoginStatus 'authenticated' 'GitHub қосылды.' }
}
Write-Host ''
Read-Host 'Терезені жабу үшін Enter' | Out-Null
