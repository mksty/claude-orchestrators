# Shared helpers for the orchestration hooks. Dot-sourced by guard.ps1, usage-guard.ps1 and
# usage-statusline.ps1; expects $StateRoot to be defined by the caller.

function Get-Key([string]$Value) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function ConvertTo-OrchestratorUtc($Value) {
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
        return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    catch { return $null }
}
function Emit($Value) { $Value | ConvertTo-Json -Depth 30 -Compress | Write-Output }
function Deny([string]$Reason) {
    Emit @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } }
}
function Save-Json([string]$Path, $Value) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $tempPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($tempPath, ($Value | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
    # Unique prompt/agent filenames avoid competing session writes.
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}
function Import-Profiles {
    return Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'profiles.psd1')
}
function Find-WorkerProfile($Profiles, [string]$Worker) {
    # Returns the command name whose profile declares this worker, or $null.
    if (-not $Worker) { return $null }
    foreach ($command in $Profiles.Keys) {
        if ($Profiles[$command].Workers.ContainsKey($Worker)) { return $command }
    }
    return $null
}
function Get-AllWorkers($Profiles) {
    $names = @()
    foreach ($command in $Profiles.Keys) { $names += @($Profiles[$command].Workers.Keys) }
    return ,$names
}
function Get-TogglePath([string]$Command, [string]$SessionDir, [switch]$Persistent) {
    $name = 'toggle-' + $Command + '.json'
    if ($Persistent) { return Join-Path $StateRoot $name }
    return Join-Path $SessionDir $name
}
function Get-ActiveToggle($Profiles, [string]$SessionDir) {
    # A session marker wins over a persistent one; only Toggle-enabled profiles are considered.
    foreach ($command in $Profiles.Keys) {
        if (-not $Profiles[$command].Toggle) { continue }
        foreach ($scope in @('session', 'persistent')) {
            $path = if ($scope -eq 'session') { Get-TogglePath $command $SessionDir } else { Get-TogglePath $command $SessionDir -Persistent }
            if (Test-Path -LiteralPath $path) { return @{ Command = $command; Scope = $scope; Path = $path } }
        }
    }
    return $null
}
function Resolve-Authorization($Profiles, [string]$AuthorizationPath, [string]$SessionDir) {
    # Explicit per-prompt authorization (a typed command) takes precedence over a toggle.
    if ($AuthorizationPath -and (Test-Path -LiteralPath $AuthorizationPath)) {
        $record = Read-Json $AuthorizationPath
        if ($record -and $Profiles.ContainsKey([string]$record.command)) { return @{ Command = [string]$record.command; Source = 'prompt' } }
    }
    $toggle = Get-ActiveToggle $Profiles $SessionDir
    if ($toggle) { return @{ Command = $toggle.Command; Source = 'toggle'; Scope = $toggle.Scope } }
    return $null
}
function Get-CommandArguments($Event) {
    # Real payloads carry a single string in command_args; the documented command_arguments array
    # and raw_prompt are accepted as fallbacks.
    $text = ''
    if ($Event.command_args) { $text = [string]$Event.command_args }
    elseif ($Event.command_arguments) { $text = (@($Event.command_arguments | ForEach-Object { [string]$_ }) -join ' ') }
    elseif ($Event.raw_prompt) { $text = [string]$Event.raw_prompt }
    # The comma keeps a single argument from unrolling into a scalar string on return.
    return ,@($text -split '\s+' | Where-Object { $_ })
}
function Test-SlashCommandPrompt($Event) {
    if ($Event.is_slash_command) { return $true }
    return ([string]$Event.prompt) -match '^\s*/'
}
function Get-QuotaSnapshot([string]$SessionId) {
    $quotaRoot = Join-Path $StateRoot 'quota'
    # Plan allowance is shared by the account, not reserved per Claude session.
    # Some clients give statusLine a different session ID to their hook events, so
    # latest.json is the authoritative source for the cross-client usage guard.
    return Read-Json (Join-Path $quotaRoot 'latest.json')
}
function Get-ActiveOrchestrations($Profiles) {
    $now = [DateTime]::UtcNow
    $items = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue)) {
        $record = Read-Json (Join-Path $directory.FullName 'quota-guard.json')
        if (-not $record -or -not $record.command -or -not $record.expires_at) { continue }
        $expires = ConvertTo-OrchestratorUtc $record.expires_at
        if ($null -eq $expires) { continue }
        if ($now -gt $expires) { continue }
        $command = [string]$record.command
        if ($Profiles.ContainsKey($command)) { $items += @{ Command = $command; Record = $record } }
    }
    foreach ($command in $Profiles.Keys) {
        if (-not $Profiles[$command].Toggle) { continue }
        $path = Get-TogglePath $command '' -Persistent
        if (Test-Path -LiteralPath $path) { $items += @{ Command = $command; Toggle = $true } }
    }
    return ,@($items)
}
function Write-OrchestratorDiagnostic([string]$Kind, [string]$SessionId, $Details) {
    try {
        $entry = @{ at = [DateTime]::UtcNow.ToString('o'); kind = $Kind; session_key = if ($SessionId) { Get-Key $SessionId } else { $null }; details = $Details }
        $path = Join-Path $StateRoot 'diagnostics\session-correlation.jsonl'
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.File]::AppendAllText($path, (($entry | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    catch { }
}
function Test-ConflictingEnvironment([string]$Label) {
    # Returns a block reason when the environment would defeat the routing design, else $null.
    if ($env:ANTHROPIC_API_KEY -or $env:ANTHROPIC_AUTH_TOKEN -or $env:ANTHROPIC_BASE_URL) {
        return ($Label + ' is configured for your Claude subscription login. An API key, auth token, or gateway override is present. Use a subscription-authenticated session; this hook has changed no credentials.')
    }
    if ($env:CLAUDE_CODE_SUBAGENT_MODEL_FORCE -and $env:CLAUDE_CODE_SUBAGENT_MODEL_FORCE -notin @('0', 'false')) {
        return 'A forced global subagent model conflicts with the per-worker model split. Start a session without CLAUDE_CODE_SUBAGENT_MODEL_FORCE.'
    }
    return $null
}
