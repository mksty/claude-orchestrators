param([string]$StateRoot = (Join-Path $PSScriptRoot 'state'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Routing guard for the orchestration profiles in profiles.psd1. It authorizes a profile's workers
# for the prompt of a user-typed command (or, for toggle profiles, while the toggle is on), pins each
# worker to its model, and enforces the tier hierarchy. It never grants tool permissions.

function Get-WorkerList($Profile) { return (@($Profile.Workers.Keys | Sort-Object) -join ', ') }

try {
    $rawEvent = [Console]::In.ReadToEnd()
    if ($env:ORCH_GUARD_DEBUG) { [IO.File]::AppendAllText($env:ORCH_GUARD_DEBUG, $rawEvent + [Environment]::NewLine) }
    $event = $rawEvent | ConvertFrom-Json
    $kind = [string]$event.hook_event_name
    $profiles = Import-Profiles
    $sessionId = [string]$event.session_id
    $promptId = [string]$event.prompt_id
    if (-not $sessionId) { throw 'Missing session_id in hook input.' }
    $sessionDir = Join-Path $StateRoot (Get-Key $sessionId)
    $authorizationPath = if ($promptId) { Join-Path $sessionDir ('prompt-' + (Get-Key $promptId) + '.json') } else { $null }

    if ($kind -eq 'UserPromptExpansion') {
        $command = [string]$event.command_name
        if (-not $profiles.ContainsKey($command) -or $event.expansion_type -ne 'slash_command') { exit 0 }
        $profile = $profiles[$command]
        $arguments = Get-CommandArguments $event
        $sub = if ($arguments.Count) { $arguments[0].ToLowerInvariant() } else { '' }

        # The usage guard owns the graceful-stop state and confirmation. Do not create a
        # new authorization record for this control command: it must never become a task.
        if ($command -in @('fable-orchestrator', 'fable-peer') -and $sub -eq 'stop') { exit 0 }

        if ($profile.Toggle -and $sub -in @('on', 'off', 'status')) {
            $sessionToggle = Get-TogglePath $command $sessionDir
            $persistentToggle = Get-TogglePath $command $sessionDir -Persistent
            $say = { param($Message) 'Reply to the user with exactly this one line and nothing else, using no tools: "' + $Message + '"' }
            if ($sub -eq 'on') {
                $conflict = Test-ConflictingEnvironment $profile.Label
                if ($conflict) { Emit @{ decision = 'block'; reason = $conflict }; exit 0 }
                $persist = ($arguments | Where-Object { $_ -in @('--persist', 'persist', '--persistent') }).Count -gt 0
                $record = @{ command = $command; session_id = $sessionId; created = [DateTime]::UtcNow.ToString('o'); scope = $(if ($persist) { 'persistent' } else { 'session' }) }
                if ($persist) { Save-Json $persistentToggle $record } else { Save-Json $sessionToggle $record }
                $scopeText = if ($persist) { 'persistently, across sessions, until you run /' + $command + ' off' } else { 'for this session' }
                Emit @{ hookSpecificOutput = @{ hookEventName = $kind; updatedPrompt = (& $say ($profile.Label + ' mode is now ON ' + $scopeText + '. Ordinary prompts will follow the ' + $profile.Label + ' routing policy; /fable-orchestrator still overrides it on its own prompt.')) } }
                exit 0
            }
            if ($sub -eq 'off') {
                foreach ($p in @($sessionToggle, $persistentToggle)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
                Emit @{ hookSpecificOutput = @{ hookEventName = $kind; updatedPrompt = (& $say ($profile.Label + ' mode is now OFF (session and persistent toggles cleared). Ordinary prompts no longer use the workflow; /' + $command + ' <task> still works as a one-shot.')) } }
                exit 0
            }
            $toggle = Get-ActiveToggle $profiles $sessionDir
            $state = if ($toggle -and $toggle.Command -eq $command) { 'ON (' + $toggle.Scope + ' toggle)' } else { 'OFF' }
            Emit @{ hookSpecificOutput = @{ hookEventName = $kind; updatedPrompt = (& $say ($profile.Label + ' mode is ' + $state + '.')) } }
            exit 0
        }

        if (-not $promptId) { throw 'Missing prompt_id; cannot authorize this invocation safely.' }
        $conflict = Test-ConflictingEnvironment $profile.Label
        if ($conflict) { Emit @{ decision = 'block'; reason = $conflict }; exit 0 }
        Save-Json $authorizationPath @{ session_id = $sessionId; prompt_id = $promptId; command = $command; created = [DateTime]::UtcNow.ToString('o') }
        Emit @{ hookSpecificOutput = @{ hookEventName = $kind; additionalContext = ($command + ' authorized for this user invocation only. ' + $profile.Label + ' coordinates; the named workers (' + (Get-WorkerList $profile) + ') execute. Normal permissions and account billing remain in force.') } }
        exit 0
    }

    if ($kind -eq 'UserPromptSubmit') {
        if (Test-SlashCommandPrompt $event) { exit 0 }
        $toggle = Get-ActiveToggle $profiles $sessionDir
        if (-not $toggle) { exit 0 }
        $profile = $profiles[$toggle.Command]
        $policyPath = Join-Path $PSScriptRoot ('policies\' + $toggle.Command + '.md')
        $policy = if (Test-Path -LiteralPath $policyPath) { [IO.File]::ReadAllText($policyPath) } else { 'Policy file missing: ' + $policyPath }
        $warning = ''
        $quota = Get-QuotaSnapshot $sessionId
        if ($quota -and $quota.model_id -and $profile.HeadModel -and ([string]$quota.model_id) -notmatch [regex]::Escape([string]$profile.HeadModel)) {
            $warning = 'WARNING: ' + $profile.Label + ' expects the head model to be ' + $profile.HeadModel + ', but the session model is ' + [string]$quota.model_id + '. Tell the user to switch with /model or run /' + $toggle.Command + ' off. '
        }
        $context = $warning + $profile.Label + ' mode is ON (' + $toggle.Scope + ' toggle) for this ordinary prompt. Follow this routing policy:' + [Environment]::NewLine + [Environment]::NewLine + $policy
        Emit @{ hookSpecificOutput = @{ hookEventName = $kind; additionalContext = $context } }
        exit 0
    }

    if ($kind -eq 'SubagentStart') {
        if ((Find-WorkerProfile $profiles ([string]$event.agent_type)) -and $event.agent_id) {
            Save-Json (Join-Path $sessionDir ('agent-' + (Get-Key ([string]$event.agent_id)) + '.json')) @{ type = [string]$event.agent_type; prompt_id = $promptId }
        }
        exit 0
    }

    if ($kind -ne 'PreToolUse' -or $event.tool_name -notin @('Agent', 'Task')) { exit 0 }
    $target = [string]$event.tool_input.subagent_type
    $caller = [string]$event.agent_type
    if ($event.tool_input.resume) {
        $record = Join-Path $sessionDir ('agent-' + (Get-Key ([string]$event.tool_input.resume)) + '.json')
        if (Test-Path -LiteralPath $record) {
            $recordedType = [string]((Read-Json $record).type)
            if ($target -and $target -ne $recordedType) { Deny 'A resumed workflow worker must retain its original subagent type.'; exit 0 }
            $target = $recordedType
        }
    }
    $targetProfile = Find-WorkerProfile $profiles $target
    $callerProfile = Find-WorkerProfile $profiles $caller
    $auth = Resolve-Authorization $profiles $authorizationPath $sessionDir
    if (-not $targetProfile -and -not $callerProfile -and -not $auth) { exit 0 }
    if (-not $auth) {
        Deny 'Orchestration workers are available only for a user-typed /fable-orchestrator or /magnum-opus invocation, or while /magnum-opus is toggled on. Ordinary prompts do not activate a workflow; invoke the command again for a follow-up.'
        exit 0
    }
    $profile = $profiles[$auth.Command]
    if ($callerProfile -and $callerProfile -ne $auth.Command) {
        Deny ('A ' + $profiles[$callerProfile].Label + ' worker cannot delegate under the ' + $profile.Label + ' workflow that is active for this prompt.')
        exit 0
    }
    if (-not $profile.Workers.ContainsKey($target)) {
        $where = if ($auth.Source -eq 'toggle') { 'While ' + $profile.Label + ' mode is on' } else { 'Within /' + $auth.Command }
        Deny ($where + ', use only ' + (Get-WorkerList $profile) + ' (including for resumed workers); other agents would run on the wrong model or outside the workflow.')
        exit 0
    }
    if ($callerProfile -and $profile.Workers[$target].HeadOnly) {
        Deny ($target + ' may be dispatched only by the ' + $profile.Label + ' head, not by ' + $caller + '.')
        exit 0
    }
    $callerTier = if ($callerProfile) { [int]$profile.Workers[$caller].Tier } else { 0 }
    $targetTier = [int]$profile.Workers[$target].Tier
    if ($targetTier -le $callerTier) {
        $deeper = @($profile.Workers.Keys | Where-Object { [int]$profile.Workers[$_].Tier -gt $callerTier } | Sort-Object)
        if ($deeper.Count) { Deny ($caller + ' may delegate only to a deeper tier: ' + ($deeper -join ', ') + '.') }
        else { Deny ($caller + ' is a leaf worker and cannot delegate.') }
        exit 0
    }
    # Modify only the model/type fields, without granting or bypassing tool permissions.
    $event.tool_input | Add-Member -NotePropertyName model -NotePropertyValue $profile.Workers[$target].Model -Force
    $event.tool_input | Add-Member -NotePropertyName subagent_type -NotePropertyValue $target -Force
    Emit @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; updatedInput = $event.tool_input } }
}
catch {
    # Exit 2 blocks expansion/tool execution on malformed input or state failure.
    [Console]::Error.WriteLine('orchestrator guard: ' + $_.Exception.Message)
    exit 2
}
