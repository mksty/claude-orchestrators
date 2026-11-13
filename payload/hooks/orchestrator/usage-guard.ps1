param(
    [string]$StateRoot = (Join-Path $PSScriptRoot 'state'),
    [string]$HandoffRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude\fable-handoffs')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Usage guard shared by every orchestration profile. It reads the quota snapshots written by
# usage-statusline.ps1 and keeps an orchestration from exhausting the five-hour plan allowance.
# A snapshot is trusted only when less than ten minutes old. Unknown quota is warning-only;
# only a fresh, measured threshold can block or stop worker orchestration.

function Get-Percent($Quota) {
    if ($null -eq $Quota -or $null -eq $Quota.five_hour_used_percentage) { return $null }
    return [double]$Quota.five_hour_used_percentage
}
function Is-Fresh($Quota) {
    if ($null -eq $Quota -or -not $Quota.captured_at) { return $false }
    $captured = ConvertTo-OrchestratorUtc $Quota.captured_at
    if ($null -eq $captured) { return $false }
    return ([DateTime]::UtcNow - $captured).TotalMinutes -le 10
}
function Is-Active([string]$Path) {
    $active = Read-Json $Path
    if (-not $active) { return $false }
    try {
        $expires = ConvertTo-OrchestratorUtc $active.expires_at
        if (-not $expires -or [DateTime]::UtcNow -gt $expires) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    catch { return $false }
    return $true
}
function Percent-Text($Percent) {
    if ($null -eq $Percent) { return 'unknown' }
    return ('{0:N0}%' -f $Percent)
}
function Block-Loop([string]$Reason) {
    Emit @{ decision = 'block'; reason = $Reason }
}
function Is-WarningOnlyProfile($Profile) {
    return $Profile -and ([string]$Profile.UsagePolicy -eq 'warn')
}
function Is-GracefulStopCommand([string]$Command) {
    return $Command -in @('fable-orchestrator', 'fable-peer')
}
function New-ActiveMarker([string]$Path, [string]$SessionId, [string]$Command, [string]$PromptId) {
    Save-Json $Path @{
        session_id = $SessionId
        command    = $Command
        prompt_id  = $PromptId
        created_at = [DateTime]::UtcNow.ToString('o')
        expires_at = [DateTime]::UtcNow.AddHours(4).ToString('o')
    }
}
function Has-TrackedWorkers([string]$SessionDir, $Active, $Profiles) {
    if (-not $Active -or -not $Active.prompt_id) { return $false }
    $allWorkers = Get-AllWorkers $Profiles
    foreach ($file in @(Get-ChildItem -LiteralPath $SessionDir -Filter 'agent-*.json' -File -ErrorAction SilentlyContinue)) {
        $record = Read-Json $file.FullName
        if ($record -and [string]$record.prompt_id -eq [string]$Active.prompt_id -and [string]$record.type -in $allWorkers) { return $true }
    }
    return $false
}
function Restore-MissingFableMarker([string]$SessionDir, [string]$ActivePath, [string]$SessionId, $Profiles) {
    # Handles a run begun before the worker-lifecycle fix: agent records still identify its prompt.
    if (Test-Path -LiteralPath $ActivePath) { return Read-Json $ActivePath }
    $candidate = $null
    foreach ($file in @(Get-ChildItem -LiteralPath $SessionDir -Filter 'prompt-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
        $record = Read-Json $file.FullName
        if ($record -and (Is-GracefulStopCommand ([string]$record.command)) -and $record.prompt_id) { $candidate = $record; break }
    }
    if (-not $candidate) { return $null }
    $probe = [pscustomobject]@{ prompt_id = [string]$candidate.prompt_id }
    if (-not (Has-TrackedWorkers $SessionDir $probe $Profiles)) { return $null }
    New-ActiveMarker $ActivePath $SessionId ([string]$candidate.command) ([string]$candidate.prompt_id)
    $active = Read-Json $ActivePath
    $active | Add-Member -NotePropertyName restored_from_worker_records_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Save-Json $ActivePath $active
    return $active
}
function Get-ActiveLabel($Profiles, $Active) {
    $command = if ($Active -and $Active.command) { [string]$Active.command } else { 'fable-orchestrator' }
    if ($Profiles.ContainsKey($command)) { return $Profiles[$command].Label }
    return 'Orchestration'
}
function Get-HandoffPath([string]$SessionId, [string]$Command) {
    $slug = if ($Command) { $Command.Split('-')[0] } else { 'orch' }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    return Join-Path $HandoffRoot ($slug + '-handoff-' + $stamp + '-' + (Get-Key $SessionId).Substring(0, 12) + '.md')
}
function Save-Handoff([string]$Path, [string]$Content) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Content.Trim() + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
function Mark-Handoff([string]$ActivePath, [string]$HandoffPath, [string]$Kind) {
    $active = Read-Json $ActivePath
    if (-not $active) { return }
    $active | Add-Member -NotePropertyName handoff_path -NotePropertyValue $HandoffPath -Force
    $active | Add-Member -NotePropertyName handoff_kind -NotePropertyValue $Kind -Force
    Save-Json $ActivePath $active
}
function Mark-Requested([string]$ActivePath, [string]$PropertyName) {
    $active = Read-Json $ActivePath
    if (-not $active) { return }
    $active | Add-Member -NotePropertyName $PropertyName -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Save-Json $ActivePath $active
}
function Get-ManualStopPath([string]$SessionDir) {
    return Join-Path $SessionDir 'manual-graceful-stop.json'
}
function Request-ManualStop($Event, [string]$SessionDir, [string]$ActivePath, [string]$StopPath, $Profiles, $Quota) {
    $active = Read-Json $ActivePath
    if (-not $active) { $active = Restore-MissingFableMarker $SessionDir $ActivePath ([string]$Event.session_id) $Profiles }
    if (-not $active -or -not (Is-GracefulStopCommand ([string]$active.command))) {
        return $null
    }
    $command = [string]$active.command
    $label = Get-ActiveLabel $Profiles $active
    $path = Write-FallbackHandoff $Event $ActivePath $Quota $label $command 'The user requested a manual graceful stop. New workers were disabled and active workers were asked to finish their current tool batch before stopping.'
    $requestedAt = [DateTime]::UtcNow.ToString('o')
    $active | Add-Member -NotePropertyName manual_stop_requested_at -NotePropertyValue $requestedAt -Force
    $active | Add-Member -NotePropertyName manual_stop_handoff_path -NotePropertyValue $path -Force
    Save-Json $ActivePath $active
    Save-Json $StopPath @{ command = $command; requested_at = $requestedAt; handoff_path = $path }
    return $path
}
function Extract-ModelHandoff([string]$Message) {
    # ORCH_HANDOFF is the current marker; FABLE_HANDOFF is accepted for older prompts.
    $match = [regex]::Match($Message, '(?s)<!-- (?:ORCH|FABLE)_HANDOFF_START -->\s*(.*?)\s*<!-- (?:ORCH|FABLE)_HANDOFF_END -->')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}
function Write-FallbackHandoff($Event, [string]$ActivePath, $Quota, [string]$Label, [string]$Command, [string]$Reason) {
    $active = Read-Json $ActivePath
    if ($active -and $active.handoff_path -and (Test-Path -LiteralPath ([string]$active.handoff_path))) {
        return [string]$active.handoff_path
    }
    $cwd = [string]$Event.cwd
    $status = ''
    $diffStat = ''
    try { $status = (& git -C $cwd status --short 2>$null | Out-String).Trim() } catch {}
    try { $diffStat = (& git -C $cwd diff --stat 2>$null | Out-String).Trim() } catch {}
    $percent = Get-Percent $Quota
    $content = @"
# $Label session handoff (automatic fallback)

## Why this was saved

$Reason

## Resume information

- Session ID: $([string]$Event.session_id)
- Working directory: $cwd
- Transcript: $([string]$Event.transcript_path)
- Five-hour allowance at stop: $(Percent-Text $percent)

## Working-tree status

```text
$status
```

## Diff summary

```text
$diffStat
```

## Continue

After the reset, resume this Claude Code session or begin a new session in the working directory. Read this file, inspect the working tree, and continue from the transcript.
"@
    $path = Get-HandoffPath ([string]$Event.session_id) $Command
    Save-Handoff $path $content
    Mark-Handoff $ActivePath $path 'automatic-fallback'
    return $path
}

try {
    $event = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $kind = [string]$event.hook_event_name
    $sessionId = [string]$event.session_id
    if (-not $sessionId) { throw 'Missing session_id in hook input.' }
    $profiles = Import-Profiles
    $allWorkers = Get-AllWorkers $profiles

    $sessionDir = Join-Path $StateRoot (Get-Key $sessionId)
    $activePath = Join-Path $sessionDir 'quota-guard.json'
    $quota = Get-QuotaSnapshot $sessionId
    $percent = Get-Percent $quota
    Write-OrchestratorDiagnostic $kind $sessionId @{ quota_captured_at = if ($quota) { $quota.captured_at } else { $null }; five_hour = $percent; quota_session_key = if ($quota -and $quota.session_id) { Get-Key ([string]$quota.session_id) } else { $null } }

    if ($kind -eq 'UserPromptExpansion') {
        $command = [string]$event.command_name
        if (-not $profiles.ContainsKey($command) -or $event.expansion_type -ne 'slash_command') { exit 0 }
        $profile = $profiles[$command]
        $arguments = Get-CommandArguments $event
        $sub = if ($arguments.Count) { $arguments[0].ToLowerInvariant() } else { '' }
        $manualStopPath = Get-ManualStopPath $sessionDir
        if ((Is-GracefulStopCommand $command) -and $sub -eq 'stop') {
            $handoffPath = Request-ManualStop $event $sessionDir $activePath $manualStopPath $profiles $quota
            $label = $profile.Label
            $message = if ($handoffPath) {
                $label + ' graceful stop requested. A handoff was saved at ' + $handoffPath + '. No new workers will start; active workers will stop after their current tool batch.'
            }
            else {
                'No active ' + $label + ' orchestration was found in this session, so there is nothing to stop.'
            }
            Emit @{ hookSpecificOutput = @{ hookEventName = 'UserPromptExpansion'; updatedPrompt = ('Reply to the user with exactly this one line and nothing else, using no tools: "' + $message + '"') } }
            exit 0
        }
        if ($profile.Toggle -and $arguments.Count -and $arguments[0].ToLowerInvariant() -in @('on', 'off', 'status')) { exit 0 }
        $warningOnly = Is-WarningOnlyProfile $profile
        if (-not $warningOnly -and (Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 95) {
            Emit @{ decision = 'block'; reason = ($profile.Label + ' usage guard stopped this orchestration: the shared five-hour plan allowance is already {0}. Wait for its reset before starting more agent work.' -f (Percent-Text $percent)) }
            exit 0
        }
        # A new explicit Fable task is the clear opt-in that releases a prior manual stop.
        $priorManualStop = Read-Json $manualStopPath
        if ((Is-GracefulStopCommand $command) -and $priorManualStop -and [string]$priorManualStop.command -eq $command) {
            Remove-Item -LiteralPath $manualStopPath -Force -ErrorAction SilentlyContinue
        }
        New-ActiveMarker $activePath $sessionId $command ([string]$event.prompt_id)
        $reading = if (Is-Fresh $quota) { Percent-Text $percent } else { 'not available' }
        $policy = if ($warningOnly) { 'This profile is warning-only: it will not block or stop workers. At 92% or more, prepare a session handoff so work can resume cleanly after a plan-limit interruption.' } else { 'At 90% or more, do not start or resume workers; the guard denies their dispatch. At 95% or more, it stops a worker after its current tool batch.' }
        Emit @{ hookSpecificOutput = @{ hookEventName = 'UserPromptExpansion'; additionalContext = ($profile.Label + ' usage guard is active. Latest five-hour plan usage: {0}. {1}' -f $reading, $policy) } }
        exit 0
    }

    if ($kind -eq 'UserPromptSubmit') {
        # An ordinary prompt under an active toggle counts as an orchestration turn.
        if (Test-SlashCommandPrompt $event) { exit 0 }
        $toggle = Get-ActiveToggle $profiles $sessionDir
        if (-not $toggle) { exit 0 }
        $profile = $profiles[$toggle.Command]
        $warningOnly = Is-WarningOnlyProfile $profile
        if (-not (Is-Active $activePath)) { New-ActiveMarker $activePath $sessionId $toggle.Command ([string]$event.prompt_id) }
        if ((Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 90) {
            if ($warningOnly) {
                Emit @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = ($profile.Label + ' usage warning: the shared five-hour plan allowance is {0}. Workers may continue; at 92% or more, prepare a concise handoff in case the plan limit interrupts the session.' -f (Percent-Text $percent)) } }
                exit 0
            }
            $note = if ($percent -ge 95) { 'Worker dispatch is denied and any running worker will be stopped after its tool batch. Do the task directly only if it is small; otherwise tell the user to wait for the reset or run /' + $toggle.Command + ' off.' } else { 'Worker dispatch is denied until the reset; finish with what is already in context.' }
            Emit @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = ($profile.Label + ' usage guard: the shared five-hour plan allowance is {0}. {1}' -f (Percent-Text $percent), $note) } }
        }
        exit 0
    }

    if ($kind -in @('Stop', 'SubagentStop')) {
        # A worker Stop removes its tracking record. If the head already stopped, the final
        # worker Stop is the real end of the orchestration and may clean up the marker.
        if ([string]$event.agent_id) {
            $agentPath = Join-Path $sessionDir ('agent-' + (Get-Key ([string]$event.agent_id)) + '.json')
            Remove-Item -LiteralPath $agentPath -Force -ErrorAction SilentlyContinue
        }
        if ([string]$event.agent_type) {
            $active = Read-Json $activePath
            if ($active -and $active.main_turn_stopped_at -and -not (Has-TrackedWorkers $sessionDir $active $profiles)) {
                $label = Get-ActiveLabel $profiles $active
                $command = [string]$active.command
                if ((Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 92 -and -not $active.handoff_path) {
                    $null = Write-FallbackHandoff $event $activePath $quota $label $command ('The ' + $label + ' head ended while workers were still completing; the final worker has now stopped.')
                }
                Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
            }
            exit 0
        }
        # A main-turn Stop is not necessarily the end: background workers may still be active.
        if (-not [string]$event.agent_type) {
            $active = Read-Json $activePath
            if ($active -and (Has-TrackedWorkers $sessionDir $active $profiles)) {
                Mark-Requested $activePath 'main_turn_stopped_at'
                exit 0
            }
            $label = Get-ActiveLabel $profiles $active
            $command = if ($active -and $active.command) { [string]$active.command } else { 'fable-orchestrator' }
            if ($active -and (Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 92 -and -not $active.handoff_path) {
                $modelHandoff = Extract-ModelHandoff ([string]$event.last_assistant_message)
                if ($modelHandoff) {
                    $path = Get-HandoffPath $sessionId $command
                    Save-Handoff $path $modelHandoff
                    Mark-Handoff $activePath $path 'model-authored'
                }
                else {
                    $null = Write-FallbackHandoff $event $activePath $quota $label $command ('The ' + $label + ' turn ended near the plan limit before a model-authored handoff was captured.')
                }
            }
            Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
        }
        exit 0
    }

    if ($kind -eq 'PostToolUse') {
        $active = Read-Json $activePath
        $isParentAgentResult = $event.tool_name -eq 'Agent' -and -not [string]$event.agent_type
        if ($isParentAgentResult -and $active -and -not $active.handoff_requested_at -and (Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 92 -and $percent -lt 95) {
            Mark-Requested $activePath 'handoff_requested_at'
            Emit @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = 'Quota handoff required. Use minimal reasoning and no tools, file reads, commands, delegation, or further investigation. Using only the current conversation and returned worker reports, reply with at most 180 words enclosed exactly between <!-- ORCH_HANDOFF_START --> and <!-- ORCH_HANDOFF_END -->. Include: completed work, changed or verified items, and the single best next step after reset.' } }
        }
        exit 0
    }

    if ($kind -eq 'PostToolBatch') {
        $isWorker = [string]$event.agent_type -in $allWorkers
        $active = Read-Json $activePath
        $manualStop = Read-Json (Get-ManualStopPath $sessionDir)
        $manualCommand = if ($manualStop) { [string]$manualStop.command } else { '' }
        $manualProfile = if ($profiles.ContainsKey($manualCommand)) { $profiles[$manualCommand] } else { $null }
        if ($isWorker -and $manualProfile -and (Is-GracefulStopCommand $manualCommand) -and $event.agent_type -in @($manualProfile.Workers.Keys)) {
            Block-Loop ($manualProfile.Label + ' graceful stop is active. The handoff was saved at {0}; stop this worker now without another model call.' -f [string]$manualStop.handoff_path)
            exit 0
        }
        if ($isWorker -and $active) {
            $label = Get-ActiveLabel $profiles $active
            $profile = if ($active.command -and $profiles.ContainsKey([string]$active.command)) { $profiles[[string]$active.command] } else { $null }
            if (Is-WarningOnlyProfile $profile) {
                if ((Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 90 -and -not $active.quota_warning_requested_at) {
                    Mark-Requested $activePath 'quota_warning_requested_at'
                    Emit @{ hookSpecificOutput = @{ hookEventName = 'PostToolBatch'; additionalContext = 'Quota warning: continue only as needed. If the five-hour plan limit is reached, return a concise status with completed work, changed files, and the next step so the parent can hand off cleanly.' } }
                }
            }
            elseif ((Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 95) {
                $path = Write-FallbackHandoff $event $activePath $quota $label ([string]$active.command) 'The worker reached the hard five-hour plan-limit threshold.'
                Block-Loop ($label + ' usage guard saved a fallback handoff at {0} and stopped this worker before another model call: the shared five-hour plan allowance is {1}.' -f $path, (Percent-Text $percent))
            }
            elseif ($percent -ge 90 -and -not $active.wind_down_requested_at) {
                Mark-Requested $activePath 'wind_down_requested_at'
                Emit @{ hookSpecificOutput = @{ hookEventName = 'PostToolBatch'; additionalContext = 'Quota wind-down: do not start more tools, commands, reads, edits, or delegation. Use minimal reasoning; return a concise status to your parent in no more than 80 words: completed work, verification, changed files, and the next step. Then stop.' } }
            }
        }
        exit 0
    }

    if ($kind -ne 'PreToolUse' -or $event.tool_name -notin @('Agent', 'Task')) { exit 0 }
    if (-not (Is-Active $activePath)) { exit 0 }

    $target = [string]$event.tool_input.subagent_type
    if (-not $target -and $event.tool_input.resume) {
        $record = Join-Path $sessionDir ('agent-' + (Get-Key ([string]$event.tool_input.resume)) + '.json')
        $target = [string](Read-Json $record).type
    }
    if ($target -notin $allWorkers) { exit 0 }

    $manualStop = Read-Json (Get-ManualStopPath $sessionDir)
    $manualCommand = if ($manualStop) { [string]$manualStop.command } else { '' }
    $manualProfile = if ($profiles.ContainsKey($manualCommand)) { $profiles[$manualCommand] } else { $null }
    if ($manualProfile -and (Is-GracefulStopCommand $manualCommand) -and $target -in @($manualProfile.Workers.Keys)) {
        Deny ($manualProfile.Label + ' graceful stop is active. No new or resumed workers may start; use the saved handoff at {0} when ready to continue.' -f [string]$manualStop.handoff_path)
        exit 0
    }

    $active = Read-Json $activePath
    $profile = if ($active.command -and $profiles.ContainsKey([string]$active.command)) { $profiles[[string]$active.command] } else { $null }
    if (Is-WarningOnlyProfile $profile) { exit 0 }

    if ((Is-Fresh $quota) -and $null -ne $percent -and $percent -ge 90) {
        $label = Get-ActiveLabel $profiles $active
        Deny ($label + ' usage guard blocked a new {0}: the shared five-hour plan allowance is {1}. Let current work finish and wait for reset before starting more workers.' -f $target, (Percent-Text $percent))
    }
}
catch {
    # A quota-display fault must never replace the routing guard.
    exit 0
}
