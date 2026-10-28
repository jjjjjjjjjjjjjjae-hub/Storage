# Logo&AI: Kazakh clarification -> faithful model-oriented English instructions.
# tuze.ps1 must be sourced and Initialize-Tuze called before this function is used.
function Invoke-LogoAi([string]$Text, [string]$Stage, [object[]]$Answers) {
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 4000) { throw 'Logo&AI: мәтін ұзындығы 1–4000 таңба болуы керек.' }
    if ($Stage -cnotin @('analyze','build')) { throw 'Logo&AI кезеңі белгісіз.' }
    if ($null -eq $Answers) { $Answers = @() }
    if ($Answers.Count -gt 3) { throw 'Logo&AI ең көбі 3 сұрақ қабылдайды.' }
    foreach ($answer in $Answers) {
        if ($answer -isnot [pscustomobject] -or $answer.question -isnot [string] -or $answer.answer -isnot [string] -or
            $answer.question.Length -gt 240 -or $answer.answer.Length -gt 500) { throw 'Logo&AI жауабы жарамсыз.' }
    }
    $schema = @{
        type = 'object'; additionalProperties = $false;
        required = @('interpreted_kk','questions','prompt_en','uncertain');
        properties = @{
            interpreted_kk = @{type='string'};
            questions = @{type='array'; maxItems=3; items=@{type='string'}};
            prompt_en = @{type='string'};
            uncertain = @{type='boolean'}
        }
    }
    $system = @'
You are Logo&AI, a faithful task clarifier for a Kazakh-speaking user of a small local AI model.
The original text may have many typos, mixed Kazakh/Russian, slang, abbreviations, and broken punctuation.
Your ONLY jobs: identify the likely intended task, ask up to 3 targeted questions IN KAZAKH if a critical detail is ambiguous, and write a precise ENGLISH task prompt for a downstream assistant.
Never change the user's objective. Preserve negations, file paths, code, names, numbers, URLs, constraints, and requested output format. Do not add assumptions, invented specifications, promises, or unsupported facts.
The output 'interpreted_kk' is a brief, readable explanation of what you believe the user means, in Kazakh. If uncertain say that explicitly.
The output 'questions' contains 0-3 direct, short, specific questions in Kazakh, ONLY when the answers affect the requested result. Do not ask questions when the request is sufficiently clear. Avoid repeating facts already supplied.
The output 'prompt_en' is the strongest faithful English instruction for the downstream AI, using only known facts. Make requirements explicit and actionable. For uncertain details, say 'unspecified' rather than guessing. End by requesting the downstream assistant to answer in Kazakh unless the user explicitly asks otherwise.
The JSON property 'uncertain' is true when a key ambiguity remains.
In stage 'analyze', make questions for missing essential details.
In stage 'build', incorporate the question-answer pairs faithfully; unanswered questions remain unspecified. Set questions to [] — do not ask more.
You MUST return a JSON object following the supplied schema, with no Markdown.
'@
    $requestInput = @{stage=$Stage;original_text=$Text;clarifications=@($Answers)} | ConvertTo-Json -Depth 8 -Compress
    $request = @{
        model = [string]$script:TuzeConfig.model; stream = $false; think = 'low';
        format = $schema; keep_alive = '10m';
        messages = @(@{role='system';content=$system},@{role='user';content=$requestInput});
        options = @{temperature=0.1;top_p=0.75;num_ctx=[int]$script:TuzeConfig.num_ctx;num_predict=950}
    }
    $data = Invoke-TuzeOllama 'POST' '/api/chat' $request ([int]$script:TuzeConfig.timeout_seconds)
    if ($data.done -cne $true -or $data.done_reason -eq 'length') { throw 'Logo&AI жауабы аяқталмады. Қайта көріңіз.' }
    if ($null -eq $data.message -or $data.message.content -isnot [string]) { throw 'Logo&AI мәтін қайтармады.' }
    try { $result = ConvertFrom-Json -InputObject $data.message.content -ErrorAction Stop }
    catch { throw 'Logo&AI JSON жауабы дұрыс емес. Қайта көріңіз.' }
    if ($result -isnot [pscustomobject] -or $result.interpreted_kk -isnot [string] -or
        $result.prompt_en -isnot [string] -or $result.prompt_en.Trim().Length -lt 5 -or
        $result.prompt_en.Length -gt 3600 -or $result.interpreted_kk.Length -gt 1200 -or
        $result.uncertain -isnot [bool] -or $null -eq $result.questions -or
        $result.questions -isnot [array] -or $result.questions.Count -gt 3) {
        throw 'Logo&AI жауап құрылымы дұрыс емес.'
    }
    $questions = @()
    foreach ($q in $result.questions) {
        if ($q -isnot [string] -or $q.Trim().Length -lt 3 -or $q.Length -gt 240) { throw 'Logo&AI сұрақтары қате.' }
        $questions += $q.Trim()
    }
    if ($Stage -eq 'build') { $questions = @() }
    return @{interpreted_kk=$result.interpreted_kk.Trim();questions=@($questions);prompt_en=$result.prompt_en.Trim();uncertain=[bool]$result.uncertain;stage=$Stage;model=[string]$script:TuzeConfig.model}
}
