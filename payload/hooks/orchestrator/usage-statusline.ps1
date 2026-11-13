param(
    [string]$StateRoot = (Join-Path $PSScriptRoot 'state')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Status line. Records the rate_limits payload (and the session model) for the usage guard, and
# shows the guard state while an orchestration or a toggle is active.

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw.Trim()) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    $sessionId = [string]$payload.session_id
    if (-not $sessionId) { exit 0 }

    $fiveHour = $payload.rate_limits.five_hour
    $sevenDay = $payload.rate_limits.seven_day
    if (-not $fiveHour -and -not $sevenDay) { exit 0 }

    $snapshot = @{
        session_id = $sessionId
        captured_at = [DateTime]::UtcNow.ToString('o')
        model_id = if ($payload.model -and $payload.model.id) { [string]$payload.model.id } else { $null }
        five_hour_used_percentage = if ($null -ne $fiveHour.used_percentage) { [double]$fiveHour.used_percentage } else { $null }
        five_hour_resets_at = if ($null -ne $fiveHour.resets_at) { [Int64]$fiveHour.resets_at } else { $null }
        seven_day_used_percentage = if ($null -ne $sevenDay.used_percentage) { [double]$sevenDay.used_percentage } else { $null }
        seven_day_resets_at = if ($null -ne $sevenDay.resets_at) { [Int64]$sevenDay.resets_at } else { $null }
    }
    $quotaDir = Join-Path $StateRoot 'quota'
    Save-Json (Join-Path $quotaDir ('session-' + (Get-Key $sessionId) + '.json')) $snapshot
    Save-Json (Join-Path $quotaDir 'latest.json') $snapshot

    $profiles = Import-Profiles
    $sessionDir = Join-Path $StateRoot (Get-Key $sessionId)
    $activePath = Join-Path $sessionDir 'quota-guard.json'
    $active = Read-Json $activePath
    $activeExpiry = if ($active -and $active.expires_at) { ConvertTo-OrchestratorUtc $active.expires_at } else { $null }
    if ($active -and $active.expires_at -and ($null -eq $activeExpiry -or [DateTime]::UtcNow -gt $activeExpiry)) {
        Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
        $active = $null
    }
    $toggle = Get-ActiveToggle $profiles $sessionDir
    $matches = Get-ActiveOrchestrations $profiles
    if (-not $active -and -not $toggle -and -not $matches.Count) {
        Write-OrchestratorDiagnostic 'statusline' $sessionId @{ active = $false; five_hour = $snapshot.five_hour_used_percentage }
        exit 0
    }

    $commands = @($matches | ForEach-Object { $_.Command } | Select-Object -Unique)
    $command = if ($active -and $active.command) { [string]$active.command } elseif ($toggle) { $toggle.Command } elseif ($commands.Count -eq 1) { [string]$commands[0] } else { $null }
    $label = if ($profiles.ContainsKey($command)) { $profiles[$command].Label } else { 'Orchestration' }
    $mode = if (($toggle -and $toggle.Command -eq $command) -or ($matches | Where-Object { $_.Toggle -and $_.Command -eq $command })) { ' ON' } else { '' }

    $five = if ($null -ne $snapshot.five_hour_used_percentage) { [Math]::Round($snapshot.five_hour_used_percentage) } else { '?' }
    $week = if ($null -ne $snapshot.seven_day_used_percentage) { [Math]::Round($snapshot.seven_day_used_percentage) } else { '?' }
    $upper = $label.ToUpperInvariant()
    $prefix = if ($five -ne '?' -and $five -ge 95) { "$upper GUARD STOP" } elseif ($five -ne '?' -and $five -ge 90) { "$upper GUARD WIND DOWN" } elseif ($five -ne '?' -and $five -ge 85) { "$upper GUARD WARNING" } else { "$label guard$mode" }
    Write-OrchestratorDiagnostic 'statusline' $sessionId @{ active = $true; command = $command; matching_commands = $commands; five_hour = $snapshot.five_hour_used_percentage }
    Write-Output ("$prefix | 5h $five% | 7d $week%")
}
catch {
    # A status line must never interfere with a Claude Code session.
    exit 0
}
