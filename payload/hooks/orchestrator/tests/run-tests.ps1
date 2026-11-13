param(
    [string]$GuardPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'guard.ps1'),
    [string]$UsageGuardPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'usage-guard.ps1'),
    [switch]$LegacyOnly
)
# Offline replay harness. Feeds synthetic hook events to the guard scripts with a temporary
# state root and asserts on their JSON output. No Claude Code session or model call involved.
$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0
$script:failures = @()

function New-StateRoot {
    # Short root: state paths carry two 64-hex segments and must stay under MAX_PATH (260).
    $root = Join-Path ([IO.Path]::GetTempPath()) ('og-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = [IO.Directory]::CreateDirectory($root)
    return $root
}
function Invoke-Hook([string]$Script, [hashtable]$Event, [string]$StateRoot, [hashtable]$Env = @{}, [string[]]$ExtraArgs = @()) {
    $json = $Event | ConvertTo-Json -Depth 10 -Compress
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try {
        $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-StateRoot', $StateRoot) + $ExtraArgs
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ($args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write($json)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $parsed = $null
        if ($out.Trim()) { try { $parsed = $out | ConvertFrom-Json } catch { $parsed = $null } }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Raw = $out; Json = $parsed; Err = $err }
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}
function Assert([bool]$Condition, [string]$Name, $Result = $null) {
    if ($Condition) { $script:passed++; Write-Host ('  PASS ' + $Name) }
    else {
        $script:failed++
        $script:failures += $Name
        $detail = if ($Result) { ' | exit=' + $Result.ExitCode + ' out=' + $Result.Raw.Trim() + ' err=' + $Result.Err.Trim() } else { '' }
        Write-Host ('  FAIL ' + $Name + $detail) -ForegroundColor Red
    }
}
function Is-Deny($R) { $R.Json -and $R.Json.hookSpecificOutput.permissionDecision -eq 'deny' }
function Pinned($R) { if ($R.Json -and $R.Json.hookSpecificOutput.updatedInput) { [string]$R.Json.hookSpecificOutput.updatedInput.model } else { $null } }
function Silent($R) { $R.ExitCode -eq 0 -and -not $R.Raw.Trim() }

function Ev([string]$Kind, [string]$Session, [string]$Prompt, [hashtable]$More = @{}) {
    $e = @{ hook_event_name = $Kind; session_id = $Session; prompt_id = $Prompt; cwd = [IO.Path]::GetTempPath(); transcript_path = 'C:\nonexistent\transcript.jsonl' }
    foreach ($k in $More.Keys) { $e[$k] = $More[$k] }
    return $e
}
function Expansion([string]$Session, [string]$Prompt, [string]$Command, [string]$RawPrompt = 'do the task', [string[]]$CmdArgs = @('do', 'the', 'task')) {
    # Real Claude Code payloads carry command_args as one string and the full prompt; no command_arguments array.
    Ev 'UserPromptExpansion' $Session $Prompt @{ command_name = $Command; expansion_type = 'slash_command'; command_args = ($CmdArgs -join ' '); prompt = ('/' + $Command + ' ' + ($CmdArgs -join ' ')) }
}
function Dispatch([string]$Session, [string]$Prompt, [string]$Target, [string]$Caller = '', [hashtable]$Extra = @{}) {
    $ti = @{ description = 'x'; prompt = 'y' }
    if ($Target) { $ti.subagent_type = $Target }
    foreach ($k in $Extra.Keys) { $ti[$k] = $Extra[$k] }
    $more = @{ tool_name = 'Agent'; tool_input = $ti }
    if ($Caller) { $more.agent_type = $Caller }
    Ev 'PreToolUse' $Session $Prompt $more
}
function Started([string]$Session, [string]$Prompt, [string]$Type, [string]$AgentId) {
    Ev 'SubagentStart' $Session $Prompt @{ agent_type = $Type; agent_id = $AgentId }
}
function Get-Key([string]$Value) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Save-Quota([string]$StateRoot, [double]$Percent, [int]$AgeMinutes = 0, [string]$Model = 'claude-opus-5') {
    $dir = Join-Path $StateRoot 'quota'
    $null = [IO.Directory]::CreateDirectory($dir)
    $snap = @{ session_id = 'any'; captured_at = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes).ToString('o'); five_hour_used_percentage = $Percent; seven_day_used_percentage = 10; model_id = $Model }
    [IO.File]::WriteAllText((Join-Path $dir 'latest.json'), ($snap | ConvertTo-Json -Compress))
}

Write-Host ("Guard under test: " + $GuardPath)
Write-Host ("Usage guard under test: " + $UsageGuardPath)

# ---------------------------------------------------------------- legacy (Fable) routing guard
Write-Host "`n[1] Inactive access is denied"
$S = New-StateRoot
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'fable-opus-worker') $S
Assert (Is-Deny $r) 'fable-opus-worker denied without an authorized command' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'Explore') $S
Assert (Silent $r) 'built-in agent untouched when workflow inactive' $r
$r = Invoke-Hook $GuardPath (Ev 'PreToolUse' 'sess-A' 'p1' @{ tool_name = 'Read'; tool_input = @{ file_path = 'x' } }) $S
Assert (Silent $r) 'non-Agent tool untouched' $r

Write-Host "`n[2] Activation by a typed /fable-orchestrator"
$r = Invoke-Hook $GuardPath (Expansion 'sess-A' 'p1' 'fable-orchestrator') $S
Assert ($r.ExitCode -eq 0 -and $r.Json.hookSpecificOutput.additionalContext -match 'fable-orchestrator') 'expansion emits additionalContext' $r
Assert ((Get-ChildItem -Path $S -Recurse -Filter 'prompt-*.json').Count -eq 1) 'authorization record written'
$r2 = Invoke-Hook $GuardPath (Ev 'UserPromptExpansion' 'sess-A' 'p9' @{ command_name = 'other-skill'; expansion_type = 'slash_command'; command_arguments = @() }) $S
Assert (Silent $r2) 'unrelated command ignored' $r2

Write-Host "`n[3] Model pinning"
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'fable-opus-worker') $S
Assert ((Pinned $r) -eq 'opus') 'fable-opus-worker pinned to opus' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'fable-sonnet-helper' '' @{ model = 'opus' }) $S
Assert ((Pinned $r) -eq 'sonnet') 'fable-sonnet-helper pinned to sonnet even when opus requested' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'Explore') $S
Assert (Is-Deny $r) 'built-in agent denied inside an authorized command' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'general-purpose') $S
Assert (Is-Deny $r) 'general-purpose denied inside an authorized command' $r

Write-Host "`n[4] Prompt and session isolation"
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p2' 'fable-opus-worker') $S
Assert (Is-Deny $r) 'later prompt in same session denied' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-B' 'p1' 'fable-opus-worker') $S
Assert (Is-Deny $r) 'same prompt id in another session denied' $r

Write-Host "`n[5] Nested routing"
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'fable-sonnet-helper' 'fable-opus-worker') $S
Assert ((Pinned $r) -eq 'sonnet') 'opus worker may call sonnet helper' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'fable-opus-worker' 'fable-opus-worker') $S
Assert (Is-Deny $r) 'opus worker may not call another opus worker' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'fable-sonnet-helper' 'fable-sonnet-helper') $S
Assert (Is-Deny $r) 'sonnet helper may not delegate' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'Explore' 'fable-opus-worker') $S
Assert (Is-Deny $r) 'opus worker may not call built-in agents' $r

Write-Host "`n[6] Resumed workers"
$r = Invoke-Hook $GuardPath (Started 'sess-A' 'p1' 'fable-opus-worker' 'agent-111') $S
Assert ($r.ExitCode -eq 0) 'SubagentStart recorded' $r
Assert ((Get-ChildItem -Path $S -Recurse -Filter 'agent-*.json').Count -eq 1) 'agent record written'
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' '' '' @{ resume = 'agent-111' }) $S
Assert ((Pinned $r) -eq 'opus' -and $r.Json.hookSpecificOutput.updatedInput.subagent_type -eq 'fable-opus-worker') 'resume without type restores recorded type and model' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-A' 'p1' 'fable-sonnet-helper' '' @{ resume = 'agent-111' }) $S
Assert (Is-Deny $r) 'resume with a different type denied' $r
$r = Invoke-Hook $GuardPath (Started 'sess-A' 'p1' 'Explore' 'agent-222') $S
Assert ((Get-ChildItem -Path $S -Recurse -Filter 'agent-*.json').Count -eq 1) 'non-worker SubagentStart not recorded'

Write-Host "`n[7] Conflicting environment overrides"
$S2 = New-StateRoot
$r = Invoke-Hook $GuardPath (Expansion 'sess-C' 'p1' 'fable-orchestrator') $S2 @{ ANTHROPIC_API_KEY = 'sk-test' }
Assert ($r.Json.decision -eq 'block') 'API key present blocks activation' $r
Assert ((Get-ChildItem -Path $S2 -Recurse -Filter 'prompt-*.json').Count -eq 0) 'no authorization written when blocked'
$r = Invoke-Hook $GuardPath (Expansion 'sess-C' 'p1' 'fable-orchestrator') $S2 @{ CLAUDE_CODE_SUBAGENT_MODEL_FORCE = '1' }
Assert ($r.Json.decision -eq 'block') 'forced subagent model blocks activation' $r
$r = Invoke-Hook $GuardPath (Expansion 'sess-C' 'p1' 'fable-orchestrator') $S2 @{ CLAUDE_CODE_SUBAGENT_MODEL_FORCE = '0' }
Assert ($r.ExitCode -eq 0 -and $null -ne $r.Json.hookSpecificOutput) 'FORCE=0 does not block' $r

Write-Host "`n[8] Malformed input"
$r = Invoke-Hook $GuardPath @{ hook_event_name = 'PreToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'fable-opus-worker' } } $S
Assert ($r.ExitCode -eq 2) 'missing session_id exits 2 (blocks)' $r

# ---------------------------------------------------------------- legacy usage guard
Write-Host "`n[9] Usage guard: activation and thresholds"
$U = New-StateRoot
# The legacy usage guard has no -HandoffRoot parameter: it writes to the real handoff directory,
# so legacy mode uses that directory and removes only the files this run created (by session key).
$keyU = (Get-Key 'sess-U').Substring(0, 12)
if ($LegacyOnly) { $H = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude\fable-handoffs'; $HArgs = @() }
else { $H = Join-Path $U 'handoffs'; $HArgs = @('-HandoffRoot', $H) }
Save-Quota $U 96
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-U' 'p1' 'fable-orchestrator') $U @{} $HArgs
Assert ($r.Json.decision -eq 'block') 'command refused at >=95%' $r
Save-Quota $U 96 -AgeMinutes 30
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-U' 'p1' 'fable-orchestrator') $U @{} $HArgs
Assert ($r.Json.hookSpecificOutput.additionalContext -match 'usage guard') 'stale snapshot does not refuse Fable' $r
Save-Quota $U 50
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-U' 'p2' 'fable-orchestrator') $U @{} $HArgs
Assert ($r.Json.hookSpecificOutput.additionalContext -match '50%') 'activation reports current usage' $r
Assert ((Get-ChildItem -Path $U -Recurse -Filter 'quota-guard.json').Count -eq 1) 'active marker written'
$r = Invoke-Hook $UsageGuardPath (Dispatch 'sess-U' 'p2' 'fable-opus-worker') $U @{} $HArgs
Assert (Silent $r) 'dispatch allowed below 90%' $r
Save-Quota $U 91
$r = Invoke-Hook $UsageGuardPath (Dispatch 'sess-U' 'p2' 'fable-opus-worker') $U @{} $HArgs
Assert (Is-Deny $r) 'dispatch denied at >=90%' $r
$r = Invoke-Hook $UsageGuardPath (Dispatch 'sess-U' 'p2' 'Explore') $U @{} $HArgs
Assert (Silent $r) 'non-worker dispatch untouched by usage guard' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'PostToolBatch' 'sess-U' 'p2' @{ agent_type = 'fable-opus-worker' }) $U @{} $HArgs
Assert ($r.Json.hookSpecificOutput.additionalContext -match 'wind-down') 'worker told to wind down at >=90%' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'PostToolBatch' 'sess-U' 'p2' @{ agent_type = 'fable-opus-worker' }) $U @{} $HArgs
Assert (Silent $r) 'wind-down requested only once' $r
Save-Quota $U 93
$r = Invoke-Hook $UsageGuardPath (Ev 'PostToolUse' 'sess-U' 'p2' @{ tool_name = 'Agent'; tool_input = @{}; tool_response = @{} }) $U @{} $HArgs
Assert ($r.Json.hookSpecificOutput.additionalContext -match 'HANDOFF_START') 'parent asked for handoff at >=92%' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'Stop' 'sess-U' 'p2' @{ last_assistant_message = "text <!-- FABLE_HANDOFF_START --> handoff body <!-- FABLE_HANDOFF_END -->" }) $U @{} $HArgs
$handoffs = @(Get-ChildItem -Path $H -Filter ('*-' + $keyU + '.md') -ErrorAction SilentlyContinue)
Assert ($handoffs.Count -eq 1 -and (Get-Content $handoffs[0].FullName -Raw) -match 'handoff body') 'model-authored handoff saved at Stop' $r
Assert ((Get-ChildItem -Path $U -Recurse -Filter 'quota-guard.json').Count -eq 0) 'active marker cleared at main Stop'
Save-Quota $U 96
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-U' 'p3' 'fable-orchestrator') $U @{} $HArgs
Save-Quota $U 50
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-U' 'p3' 'fable-orchestrator') $U @{} $HArgs
Save-Quota $U 96
$r = Invoke-Hook $UsageGuardPath (Ev 'PostToolBatch' 'sess-U' 'p3' @{ agent_type = 'fable-sonnet-helper' }) $U @{} $HArgs
Assert ($r.Json.decision -eq 'block' -and $r.Json.reason -match 'fallback handoff') 'worker stopped with fallback handoff at >=95%' $r
Assert (@(Get-ChildItem -Path $H -Filter ('*-' + $keyU + '.md')).Count -eq 2) 'fallback handoff file written'
if ($LegacyOnly) { Get-ChildItem -Path $H -Filter ('*-' + $keyU + '.md') -ErrorAction SilentlyContinue | Remove-Item -Force }

if ($LegacyOnly) {
    Write-Host ("`nLegacy suite: {0} passed, {1} failed" -f $script:passed, $script:failed)
    if ($script:failed) { $script:failures | ForEach-Object { Write-Host (' - ' + $_) -ForegroundColor Red }; exit 1 }
    exit 0
}

# ---------------------------------------------------------------- Fable Peer
Write-Host "`n[10] /fable-peer one-shot peer-workstream authorization and pinning"
$FP = New-StateRoot
$r = Invoke-Hook $GuardPath (Expansion 'sess-FP' 'p1' 'fable-peer') $FP
Assert ($r.ExitCode -eq 0 -and $r.Json.hookSpecificOutput.additionalContext -match 'fable-peer') 'fable peer task expansion authorizes' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-FP' 'p1' 'fable-peer-opus-worker' '' @{ model = 'sonnet' }) $FP
Assert ((Pinned $r) -eq 'opus') 'fable peer worker pinned to opus' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-FP' 'p1' 'fable-opus-worker') $FP
Assert (Is-Deny $r) 'standard fable worker denied inside a fable peer prompt' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-FP' 'p1' 'fable-peer-opus-worker' 'fable-peer-opus-worker') $FP
Assert (Is-Deny $r) 'fable peer worker is a leaf' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-FP' 'p2' 'fable-peer-opus-worker') $FP
Assert (Is-Deny $r) 'fable peer worker denied on a later prompt' $r

# ---------------------------------------------------------------- Magnum Opus
Write-Host "`n[11] /magnum-opus one-shot authorization and pinning"
$M = New-StateRoot
$r = Invoke-Hook $GuardPath (Expansion 'sess-M' 'p1' 'magnum-opus') $M
Assert ($r.ExitCode -eq 0 -and $r.Json.hookSpecificOutput.additionalContext -match 'magnum-opus') 'magnum task expansion authorizes' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-sonnet-worker' '' @{ model = 'opus' }) $M
Assert ((Pinned $r) -eq 'sonnet') 'magnum-sonnet-worker pinned to sonnet' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-sonnet-reviewer') $M
Assert ((Pinned $r) -eq 'sonnet') 'magnum-sonnet-reviewer pinned to sonnet' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-haiku-scout' '' @{ model = 'sonnet' }) $M
Assert ((Pinned $r) -eq 'haiku') 'magnum-haiku-scout pinned to haiku' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'fable-opus-worker') $M
Assert (Is-Deny $r) 'fable worker denied inside a magnum prompt' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'Explore') $M
Assert (Is-Deny $r) 'built-in agent denied inside a magnum prompt' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p2' 'magnum-sonnet-worker') $M
Assert (Is-Deny $r) 'magnum worker denied on a later prompt without toggle' $r

Write-Host "`n[11] Magnum tiers"
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-haiku-scout' 'magnum-sonnet-worker') $M
Assert ((Pinned $r) -eq 'haiku') 'sonnet worker may call haiku scout' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-sonnet-worker' 'magnum-sonnet-worker') $M
Assert (Is-Deny $r) 'sonnet worker may not call another sonnet worker' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-sonnet-reviewer' 'magnum-sonnet-worker') $M
Assert (Is-Deny $r) 'sonnet worker may not call the reviewer' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-haiku-scout' 'magnum-sonnet-reviewer') $M
Assert (Is-Deny $r) 'reviewer is a leaf' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'magnum-haiku-scout' 'magnum-haiku-scout') $M
Assert (Is-Deny $r) 'scout is a leaf' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-M' 'p1' 'fable-sonnet-helper' 'magnum-sonnet-worker') $M
Assert (Is-Deny $r) 'magnum worker may not call fable workers' $r

Write-Host "`n[12] Toggle on / status / off"
$T = New-StateRoot
$r = Invoke-Hook $GuardPath (Expansion 'sess-T' 'p1' 'magnum-opus' 'on' @('on')) $T
Assert ($r.Json.hookSpecificOutput.updatedPrompt -match '(?i)\bon\b') 'toggle on replaces the prompt with a confirmation' $r
Assert ((Get-ChildItem -Path $T -Recurse -Filter 'toggle-magnum-opus.json').Count -eq 1) 'session toggle marker written'
Assert ((Get-ChildItem -Path $T -Recurse -Filter 'prompt-*.json').Count -eq 0) 'toggle on does not write a prompt authorization'
$r = Invoke-Hook $GuardPath (Dispatch 'sess-T' 'p2' 'magnum-sonnet-worker') $T
Assert ((Pinned $r) -eq 'sonnet') 'ordinary prompt dispatches magnum worker while toggled on' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-T' 'p2' 'magnum-haiku-scout' 'magnum-sonnet-worker') $T
Assert ((Pinned $r) -eq 'haiku') 'nested scout works under toggle' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-T' 'p2' 'fable-opus-worker') $T
Assert (Is-Deny $r) 'fable worker denied under toggle' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-T' 'p2' 'Explore') $T
Assert (Is-Deny $r) 'built-in agent redirected under toggle' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-T2' 'p2' 'magnum-sonnet-worker') $T
Assert (Is-Deny $r) 'session toggle does not leak to another session' $r
$r = Invoke-Hook $GuardPath (Expansion 'sess-T' 'p3' 'magnum-opus' 'status' @('status')) $T
Assert ($r.Json.hookSpecificOutput.updatedPrompt -match '(?i)\bON\b') 'status reports ON' $r
$r = Invoke-Hook $GuardPath (Expansion 'sess-T' 'p4' 'magnum-opus' 'off' @('off')) $T
Assert ($r.Json.hookSpecificOutput.updatedPrompt -match '(?i)\boff\b') 'toggle off confirms' $r
Assert ((Get-ChildItem -Path $T -Recurse -Filter 'toggle-magnum-opus.json').Count -eq 0) 'toggle marker removed'
$r = Invoke-Hook $GuardPath (Dispatch 'sess-T' 'p5' 'magnum-sonnet-worker') $T
Assert (Is-Deny $r) 'magnum worker denied after toggle off' $r
$r = Invoke-Hook $GuardPath (Expansion 'sess-T' 'p6' 'magnum-opus' 'status' @('status')) $T
Assert ($r.Json.hookSpecificOutput.updatedPrompt -match '(?i)\bOFF\b') 'status reports OFF' $r
$r = Invoke-Hook $GuardPath (Expansion 'sess-T' 'p7' 'magnum-opus' 'on' @('on')) $T @{ ANTHROPIC_API_KEY = 'sk-test' }
Assert ($r.Json.decision -eq 'block') 'toggle on blocked with API key present' $r

Write-Host "`n[13] Persistent toggle"
$r = Invoke-Hook $GuardPath (Expansion 'sess-T' 'p8' 'magnum-opus' 'on --persist' @('on', '--persist')) $T
Assert ((Test-Path (Join-Path $T 'toggle-magnum-opus.json'))) 'persistent marker at state root' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-T3' 'p1' 'magnum-sonnet-worker') $T
Assert ((Pinned $r) -eq 'sonnet') 'another session sees the persistent toggle' $r
$r = Invoke-Hook $GuardPath (Expansion 'sess-T3' 'p2' 'magnum-opus' 'off' @('off')) $T
Assert (-not (Test-Path (Join-Path $T 'toggle-magnum-opus.json'))) 'off removes the persistent marker' $r

Write-Host "`n[14] Precedence: typed /fable-orchestrator beats the toggle on its own prompt"
$P = New-StateRoot
$null = Invoke-Hook $GuardPath (Expansion 'sess-P' 'p1' 'magnum-opus' 'on' @('on')) $P
$null = Invoke-Hook $GuardPath (Expansion 'sess-P' 'p2' 'fable-orchestrator') $P
$r = Invoke-Hook $GuardPath (Dispatch 'sess-P' 'p2' 'fable-opus-worker') $P
Assert ((Pinned $r) -eq 'opus') 'fable worker allowed on the fable prompt' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-P' 'p2' 'magnum-sonnet-worker') $P
Assert (Is-Deny $r) 'magnum worker denied on the fable prompt' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-P' 'p2' 'fable-sonnet-helper' 'fable-opus-worker') $P
Assert ((Pinned $r) -eq 'sonnet') 'fable nesting intact on the fable prompt' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-P' 'p3' 'magnum-sonnet-worker') $P
Assert ((Pinned $r) -eq 'sonnet') 'magnum resumes on the next ordinary prompt' $r
$r = Invoke-Hook $GuardPath (Dispatch 'sess-P' 'p3' 'fable-opus-worker') $P
Assert (Is-Deny $r) 'fable worker denied on the next ordinary prompt' $r
$null = Invoke-Hook $GuardPath (Started 'sess-P' 'p2' 'fable-opus-worker' 'agent-F') $P
$r = Invoke-Hook $GuardPath (Dispatch 'sess-P' 'p3' '' '' @{ resume = 'agent-F' }) $P
Assert (Is-Deny $r) 'resuming a fable worker from a magnum prompt denied' $r

Write-Host "`n[15] UserPromptSubmit policy injection"
Save-Quota $P 40 -Model 'claude-opus-5'
$r = Invoke-Hook $GuardPath (Ev 'UserPromptSubmit' 'sess-P' 'p4' @{ prompt = 'fix the bug' }) $P
Assert ($r.Json.hookSpecificOutput.additionalContext -match 'Magnum Opus' -and $r.Json.hookSpecificOutput.additionalContext -match 'magnum-haiku-scout') 'policy injected on ordinary prompt while on' $r
Assert ($r.Json.hookSpecificOutput.additionalContext -notmatch 'head model') 'no head-model warning when Opus' $r
Save-Quota $P 40 -Model 'claude-sonnet-5'
$r = Invoke-Hook $GuardPath (Ev 'UserPromptSubmit' 'sess-P' 'p4' @{ prompt = 'fix the bug' }) $P
Assert ($r.Json.hookSpecificOutput.additionalContext -match 'head model') 'head-model warning when session model is not Opus' $r
$r = Invoke-Hook $GuardPath (Ev 'UserPromptSubmit' 'sess-P' 'p5' @{ prompt = '/fable-orchestrator do x' }) $P
Assert (Silent $r) 'no injection on slash commands' $r
$null = Invoke-Hook $GuardPath (Expansion 'sess-P' 'p6' 'magnum-opus' 'off' @('off')) $P
$r = Invoke-Hook $GuardPath (Ev 'UserPromptSubmit' 'sess-P' 'p7' @{ prompt = 'fix the bug' }) $P
Assert (Silent $r) 'no injection when toggled off' $r

Write-Host "`n[16] Usage guard with Magnum"
$V = New-StateRoot
$HV = Join-Path $V 'handoffs'
Save-Quota $V 50
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-V' 'p1' 'magnum-opus') $V @{} @('-HandoffRoot', $HV)
Assert ($r.Json.hookSpecificOutput.additionalContext -match 'Magnum') 'magnum task activates usage guard with its label' $r
$null = Invoke-Hook $UsageGuardPath (Ev 'Stop' 'sess-V' 'p1' @{ last_assistant_message = 'done' }) $V @{} @('-HandoffRoot', $HV)
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-V' 'p2' 'magnum-opus' 'on' @('on')) $V @{} @('-HandoffRoot', $HV)
Assert (Silent $r) 'toggle sub-command ignored by usage guard' $r
$null = Invoke-Hook $GuardPath (Expansion 'sess-V' 'p2' 'magnum-opus' 'on' @('on')) $V
$r = Invoke-Hook $UsageGuardPath (Ev 'UserPromptSubmit' 'sess-V' 'p3' @{ prompt = 'do x' }) $V @{} @('-HandoffRoot', $HV)
Assert ((Get-ChildItem -Path $V -Recurse -Filter 'quota-guard.json').Count -eq 1) 'ordinary prompt under toggle creates an active marker' $r
Save-Quota $V 91
$r = Invoke-Hook $UsageGuardPath (Dispatch 'sess-V' 'p3' 'magnum-sonnet-worker') $V @{} @('-HandoffRoot', $HV)
Assert (Silent $r) 'magnum dispatch remains allowed at >=90% under toggle' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'PostToolBatch' 'sess-V' 'p3' @{ agent_type = 'magnum-haiku-scout' }) $V @{} @('-HandoffRoot', $HV)
Assert ($r.Json.hookSpecificOutput.additionalContext -match 'Quota warning') 'magnum scout receives a quota warning without a stop' $r
Save-Quota $V 96
$r = Invoke-Hook $UsageGuardPath (Ev 'UserPromptSubmit' 'sess-V' 'p4' @{ prompt = 'do y' }) $V @{} @('-HandoffRoot', $HV)
Assert ($r.Json.hookSpecificOutput.additionalContext -match '96%' -and -not $r.Json.decision) 'ordinary prompt at >=95% warned but not blocked' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'Stop' 'sess-V' 'p4' @{ last_assistant_message = "<!-- ORCH_HANDOFF_START --> magnum handoff <!-- ORCH_HANDOFF_END -->" }) $V @{} @('-HandoffRoot', $HV)
$h = @(Get-ChildItem -Path $HV -Filter '*.md' -ErrorAction SilentlyContinue)
Assert ($h.Count -eq 1 -and $h[0].Name -match 'magnum' -and (Get-Content $h[0].FullName -Raw) -match 'magnum handoff') 'ORCH_HANDOFF markers accepted and file named by profile' $r

Write-Host "`n[17] Manual Fable graceful stop"
$G = New-StateRoot
$HG = Join-Path $G 'handoffs'
Save-Quota $G 50
$null = Invoke-Hook $GuardPath (Expansion 'sess-G' 'p1' 'fable-orchestrator') $G
$null = Invoke-Hook $UsageGuardPath (Expansion 'sess-G' 'p1' 'fable-orchestrator') $G @{} @('-HandoffRoot', $HG)
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-G' 'p2' 'fable-orchestrator' 'stop' @('stop')) $G @{} @('-HandoffRoot', $HG)
Assert ($r.Json.hookSpecificOutput.updatedPrompt -match 'graceful stop requested') 'manual stop confirms graceful shutdown' $r
Assert ((Get-ChildItem -Path $G -Recurse -Filter 'manual-graceful-stop.json').Count -eq 1) 'manual stop marker written'
Assert (@(Get-ChildItem -Path $HG -Filter '*.md' -ErrorAction SilentlyContinue).Count -eq 1) 'manual stop saves a fallback handoff'
$null = Invoke-Hook $GuardPath (Dispatch 'sess-G' 'p1' 'fable-opus-worker') $G
$r = Invoke-Hook $UsageGuardPath (Dispatch 'sess-G' 'p1' 'fable-opus-worker') $G @{} @('-HandoffRoot', $HG)
Assert (Is-Deny $r) 'manual stop denies new Fable worker dispatches' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'PostToolBatch' 'sess-G' 'p1' @{ agent_type = 'fable-opus-worker' }) $G @{} @('-HandoffRoot', $HG)
Assert ($r.Json.decision -eq 'block' -and $r.Json.reason -match 'graceful stop') 'manual stop halts a worker after its current batch' $r
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-G' 'p3' 'fable-orchestrator') $G @{} @('-HandoffRoot', $HG)
Assert ((Get-ChildItem -Path $G -Recurse -Filter 'manual-graceful-stop.json').Count -eq 0) 'a new explicit Fable task clears the manual stop marker' $r

Write-Host "`n[18] Manual Fable Peer graceful stop"
$GP = New-StateRoot
$HGP = Join-Path $GP 'handoffs'
Save-Quota $GP 50
$null = Invoke-Hook $GuardPath (Expansion 'sess-GP' 'p1' 'fable-peer') $GP
$null = Invoke-Hook $UsageGuardPath (Expansion 'sess-GP' 'p1' 'fable-peer') $GP @{} @('-HandoffRoot', $HGP)
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-GP' 'p2' 'fable-peer' 'stop' @('stop')) $GP @{} @('-HandoffRoot', $HGP)
Assert ($r.Json.hookSpecificOutput.updatedPrompt -match 'Fable Peer graceful stop requested') 'fable peer manual stop confirms graceful shutdown' $r
$null = Invoke-Hook $GuardPath (Dispatch 'sess-GP' 'p1' 'fable-peer-opus-worker') $GP
$r = Invoke-Hook $UsageGuardPath (Dispatch 'sess-GP' 'p1' 'fable-peer-opus-worker') $GP @{} @('-HandoffRoot', $HGP)
Assert (Is-Deny $r) 'fable peer manual stop denies new peer worker dispatches' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'PostToolBatch' 'sess-GP' 'p1' @{ agent_type = 'fable-peer-opus-worker' }) $GP @{} @('-HandoffRoot', $HGP)
Assert ($r.Json.decision -eq 'block' -and $r.Json.reason -match 'Fable Peer graceful stop') 'fable peer manual stop halts its worker after the current batch' $r
$r = Invoke-Hook $UsageGuardPath (Expansion 'sess-GP' 'p3' 'fable-peer') $GP @{} @('-HandoffRoot', $HGP)
Assert ((Get-ChildItem -Path $GP -Recurse -Filter 'manual-graceful-stop.json').Count -eq 0) 'a new explicit Fable Peer task clears its manual stop marker' $r

Write-Host "`n[19] Active marker survives the head while workers run"
$L = New-StateRoot
$HL = Join-Path $L 'handoffs'
Save-Quota $L 50
$null = Invoke-Hook $GuardPath (Expansion 'sess-L' 'p1' 'fable-orchestrator') $L
$null = Invoke-Hook $UsageGuardPath (Expansion 'sess-L' 'p1' 'fable-orchestrator') $L @{} @('-HandoffRoot', $HL)
$null = Invoke-Hook $GuardPath (Started 'sess-L' 'p1' 'fable-opus-worker' 'agent-L') $L
$r = Invoke-Hook $UsageGuardPath (Ev 'Stop' 'sess-L' 'p1' @{ last_assistant_message = 'head complete' }) $L @{} @('-HandoffRoot', $HL)
Assert ((Get-ChildItem -Path $L -Recurse -Filter 'quota-guard.json').Count -eq 1) 'main Stop retains the active marker while a tracked worker remains' $r
$r = Invoke-Hook $UsageGuardPath (Ev 'SubagentStop' 'sess-L' 'p1' @{ agent_type = 'fable-opus-worker'; agent_id = 'agent-L'; last_assistant_message = 'worker complete' }) $L @{} @('-HandoffRoot', $HL)
Assert ((Get-ChildItem -Path $L -Recurse -Filter 'quota-guard.json').Count -eq 0) 'final teammate SubagentStop clears the retained active marker' $r

Write-Host ("`nTotal: {0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed) { $script:failures | ForEach-Object { Write-Host (' - ' + $_) -ForegroundColor Red }; exit 1 }
exit 0
