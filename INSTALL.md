# INSTALL.md — instructions for Claude

You are Claude Code, installing this package into the user's own Claude Code setup. This file is written for you. Work through it in order, tell the user what you are doing as you go, and ask before anything marked **(ask)**.

The package was built and tested on **Windows** with Windows PowerShell 5.1. The user you are helping may be on **macOS or Linux**. Part of your job is to make it work on their system (step 3) and prove it with the included test suite (step 6).

## What gets installed

| Package path | Installed to | Purpose |
|---|---|---|
| `payload/skills/<name>/SKILL.md` (3) | `~/.claude/skills/<name>/SKILL.md` | The slash commands `/fable-orchestrator`, `/fable-peer`, `/magnum-opus` |
| `payload/agents/*.md` (6) | `~/.claude/agents/` | The named worker subagents, each pinned to a model alias |
| `payload/hooks/orchestrator/` | `~/.claude/hooks/orchestrator/` | Guard scripts, worker profiles, the Magnum policy and an offline test suite |
| `settings-fragment.json` | merged into `~/.claude/settings.json` | Hook registrations, the status line and the Agent Teams env flag |

How the pieces fit:

- **`guard.ps1`** is the routing guard. It authorizes a profile's workers only for a user-typed command (or while the Magnum toggle is on), pins each worker to its model, and enforces the tier hierarchy (a caller may only dispatch to a deeper tier). It is the security-relevant part: on malformed input or a state failure it exits 2, which blocks.
- **`usage-guard.ps1`** watches the five-hour plan allowance. It reads quota snapshots and winds down, hands off or stops workers at 90/92/95%. It must never break a session: on any internal error it exits 0.
- **`usage-statusline.ps1`** is the status line. Besides showing guard state, it is the only thing that records the `rate_limits` payload into `state/quota/latest.json`, so the usage guard is blind without it.
- **`common.ps1`** holds shared helpers; **`profiles.psd1`** declares each workflow's workers, models and tiers; **`policies/magnum-opus.md`** is injected on ordinary prompts while the Magnum toggle is on.
- State is written under `hooks/orchestrator/state/` (created on first use). Handoff files go to `~/.claude/fable-handoffs/`.

## Step 1 — Check prerequisites

1. Run `claude --version` and tell the user the version. The hooks use the `UserPromptExpansion`, `PostToolBatch`, `SubagentStart` and `SubagentStop` events and Agent Teams. If anything in step 6 or 7 behaves as if an event never fires, the first fix is updating Claude Code.
2. Detect the OS and shell (`uname -s`, or `$PSVersionTable` on Windows).
3. Check how Claude Code is authenticated. The guard **refuses to activate** if `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_BASE_URL` is set, because the design assumes a Claude subscription login (Pro/Max), where Opus, Sonnet and Haiku draw on the plan allowance. If the user runs Claude Code on an API key, tell them; **(ask)** whether to stop here or to remove that check from `Test-ConflictingEnvironment` in `common.ps1` (the workflows still work on an API key, but every tier is then billed per token and the usage guard has no plan allowance to watch).
4. Check that the model aliases resolve on their account: `fable`, `opus`, `sonnet`, `haiku`. Fable may need usage credits or a plan that includes it. If Fable is not available to them, the two Fable commands will not work, but `/magnum-opus` will.

## Step 2 — Look before you overwrite

Check whether any of these already exist: `~/.claude/skills/{fable-orchestrator,fable-peer,magnum-opus}`, the six agent files, `~/.claude/hooks/orchestrator/`. If any do, show the user and **(ask)** before replacing. Back up `~/.claude/settings.json` to `~/.claude/settings.json.bak-orchestrators` before you edit it in step 5.

## Step 3 — Make the hooks run on this system

On **Windows**, nothing to do: use `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File` as the runner.

On **macOS or Linux**, choose one route and tell the user which and why. Recommend route A unless they object to installing PowerShell.

**Route A (recommended): PowerShell 7.** Smallest change; the guard logic and the test suite stay exactly as tested.

1. Check for `pwsh`. If missing, **(ask)** then install it: macOS `brew install --cask powershell` (or `brew install powershell`), Linux per Microsoft's instructions for the distro.
2. Fix the Windows-only assumptions in the copied scripts (in `~/.claude/hooks/orchestrator/` after step 4, not in this repo):
   - Backslash path fragments: `'policies\' + ...` in `guard.ps1`, `'diagnostics\session-correlation.jsonl'` in `common.ps1`, and `'.claude\fable-handoffs'` in `usage-guard.ps1` and `tests/run-tests.ps1`. Rewrite each with `Join-Path` (nest calls for multiple segments) so they work on every OS.
   - `tests/run-tests.ps1` launches `powershell.exe` and passes `-ExecutionPolicy Bypass`. Make it launch `pwsh` when not on Windows (`$IsWindows` is defined in PowerShell 7) and drop `-ExecutionPolicy` there.
   - In the test file, the fake `transcript_path` `'C:\nonexistent\transcript.jsonl'` is only a string; leave it or make it OS-neutral.
   - Search all four scripts for any other `\` path separator, `C:` drive letter or `.exe` and fix those too.
3. Runner for settings: `pwsh -NoProfile -NonInteractive -File`.

**Route B: port to Node.js** (Claude Code already ships with Node). Choose this only if the user does not want PowerShell. Port `common.ps1`, `guard.ps1`, `usage-guard.ps1`, `usage-statusline.ps1` and `profiles.psd1` faithfully, keeping every behaviour: the same JSON on stdout for each event, the same exit codes (guard exits 2 on error; usage guard and status line exit 0 on error), the same state file names and layout (SHA-256 hex keys of session, prompt and agent IDs), atomic writes (temp file + rename), the 10-minute quota freshness rule, and the 90/92/95% thresholds. Port the test suite too and get all of it passing before step 7. This is a substantial job; say so and **(ask)** before starting.

## Step 4 — Copy the files

Copy the `payload/` contents into `~/.claude/` at the paths in the table above. Then apply the step 3 fixes to the copies. On macOS/Linux make sure the scripts are readable; they do not need to be executable because the runner invokes them.

## Step 5 — Merge settings

Merge `settings-fragment.json` into `~/.claude/settings.json`, replacing `{{RUN}}` with the runner from step 3 and `{{HOOKS}}` with the absolute path of `~/.claude/hooks/orchestrator` written with forward slashes (`~` is not expanded inside hook commands; use the real home path). Rules:

- **Merge, never replace.** Keep every existing setting and every existing hook. For each event, append these hook groups to the user's existing array; do not drop theirs.
- **Status line:** if the user already has a `statusLine`, do not silently overwrite it. **(ask)** whether to (a) replace it, or (b) chain them: write a small wrapper script that passes stdin to `usage-statusline` (which records quota and prints only while an orchestration is active) and then to their existing status line, printing both outputs. The usage guard depends on `usage-statusline` receiving the status-line payload, so it must run one way or another.
- **`env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"`** is needed for the Fable lead to receive teammate messages. Add it to their `env` block.
- Do not set `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`; the guard blocks when it is set to anything but `0`/`false`.
- Optional, **(ask)**: `"model": "opus"` as the default session model (Magnum Opus expects an Opus head), and a per-model effort setting for Fable (`"modelSettings": { "claude-fable-<version>": { "effortLevel": "low" } }`) to make the Fable head cheaper. That key is an exact model ID, so it must name the current Fable and be updated when a new one ships.
- Validate the file parses as JSON after editing.

## Step 6 — Run the offline test suite

Run `tests/run-tests.ps1` with the runner (`pwsh -NoProfile -File ~/.claude/hooks/orchestrator/tests/run-tests.ps1` on Route A). It replays about 88 synthetic hook events through the guards with temporary state folders and makes no model calls. **Every test must pass.** If one fails, fix the cause in the installed scripts (usually a path or process-launch difference from step 3) and rerun. Do not edit a test to make it pass unless the test itself has a Windows-only assumption, and say so if you do.

## Step 7 — Live smoke test (ask first)

This spends a little plan allowance, so **(ask)**. In a scratch folder, have the user start a fresh `claude` session (hooks load at session start) and run:

1. `/magnum-opus status` → replies that Magnum Opus mode is OFF.
2. `/magnum-opus Create hello.txt containing "hi", then confirm its contents.` → the status line should show `Magnum Opus guard | 5h …% | 7d …%`, and `/tasks` (or the transcript) should show a Magnum worker or scout running on Sonnet or Haiku.
3. Only if Fable is available to them and they agree to spend credits: a tiny `/fable-orchestrator` task.

If the guard blocks with a message, the README's "If something is refused" section explains each one.

## Step 8 — Explain it to the user

Finish by walking the user through [README.md](README.md) in plain language: what each command is for and what it costs them, how to turn the Magnum toggle on and off, what the status line means, the stop command, where handoff files land, and how to remove everything. Keep it short and offer to answer questions.

## Updating

Pull the new version of this repo, then repeat steps 2–6. Re-apply the step 3 fixes to any script that changed. Keep the user's settings merge; only touch the orchestrator entries.

## Uninstalling

Remove the three skill folders, the six agent files, `~/.claude/hooks/orchestrator/` and (if the user wants) `~/.claude/fable-handoffs/`. Remove the orchestrator hook entries, the status line (or restore their previous one, if chained) and the Agent Teams env flag from `settings.json`, leaving everything else. Validate the JSON.
