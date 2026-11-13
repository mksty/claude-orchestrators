# Claude orchestrators

Three Claude Code workflows that split a big task across several models: a strong model plans, reviews and integrates; cheaper models do the bulk reading and implementation. Each runs only when you type its command (or, for Magnum Opus, turn its toggle on). Ordinary prompts run Claude Code as normal.

## Installing

Clone this repo, open a terminal in it, start `claude`, and say:

> Install this for me.

Claude reads [INSTALL.md](INSTALL.md), adapts the hook scripts to your system (they were written on Windows), merges the settings without touching yours, runs the offline tests and explains how to use it. It asks before installing anything, replacing your status line, or spending usage on a live test. Start a **new** Claude Code session afterwards so the hooks load.

You need a Claude subscription login (Pro or Max). The guard refuses to run with an API key or gateway configured; Claude will explain your options if that applies.

## The three commands

| | `/fable-orchestrator` | `/fable-peer` | `/magnum-opus` |
|---|---|---|---|
| Lead | Fable | Fable | Opus |
| Workers | Opus workstream owners, which may use Sonnet helpers; Sonnet helpers for small independent jobs | One Opus peer that owns its own slice | Sonnet worker (implements), Sonnet reviewer (blind review), Haiku scout (searching, running tests) |
| How it runs | One prompt at a time | One prompt at a time | One prompt, or a toggle for every prompt |
| Use when | You have Fable access and want the strongest lead | You want Fable and Opus each to build an independent half | Everyday big tasks on your plan allowance |

Models are chosen by alias (`fable`, `opus`, `sonnet`, `haiku`), so they follow the newest release as Claude Code updates.

**Cost.** Check how your own account bills Fable before using the Fable commands: on some plans Fable uses paid usage credits rather than the plan allowance. Opus, Sonnet and Haiku run on the plan allowance with a subscription login. `/magnum-opus` is the safe default.

### /fable-orchestrator

```text
/fable-orchestrator Implement the feature in issue 42 and verify it.
```

- Applies to that prompt only. For a follow-up, type the command again.
- There is deliberately no toggle: every prompt would spend Fable usage.
- Fable stays active while workers run, answering their questions and reviewing their results, then gives you one final result.
- `/fable-orchestrator stop` stops a run gracefully: it saves a handoff file, starts no new workers, and lets a running worker finish its current step.

### /fable-peer

```text
/fable-peer Build the API and the UI for the export feature, then integrate and verify.
```

- Fable does one substantial part itself and hands exactly one independent part to an Opus peer, each with its own files. Fable integrates and checks the result.
- One prompt at a time; `/fable-peer stop` stops it gracefully.

### /magnum-opus

```text
/magnum-opus Fix the failing tests in src/parser and add a regression test.
```

Or turn it on for every prompt:

```text
/magnum-opus on              this session
/magnum-opus on --persist    every session, until turned off
/magnum-opus status
/magnum-opus off             clears both
```

- While on, just prompt normally. Small things (a question, a short edit) are done directly; bigger work is routed to the workers.
- The lead is your session model; keep it on Opus (`/model opus`). If you switch away while the toggle is on, you'll get a warning.
- `/fable-orchestrator <task>` still works while the toggle is on; that one prompt runs as Fable.

## Status line

Blank when nothing is active. Otherwise something like `Magnum Opus guard ON | 5h 42% | 7d 18%`: your five-hour and weekly plan usage. The prefix changes to `WARNING` at 85%, `WIND DOWN` at 90% and `STOP` at 95% of the five-hour allowance.

## Usage guard

`/fable-orchestrator` and `/magnum-opus` only ever **warn**; they never refuse or stop work. `/fable-peer` enforces the limits.

| Five-hour usage | `/fable-orchestrator`, `/magnum-opus` | `/fable-peer` |
|---|---|---|
| 90% | Running workers get a one-time warning and carry on. | No new workers; running workers are told to wrap up and report. |
| 92% | The lead writes a short handoff, saved to `~/.claude/fable-handoffs/`. | Same. |
| 95% | Still just a warning. | The command is refused at the start, and a running worker is stopped with an automatic handoff (git status, diff summary, transcript path). |

To make a command enforce or warn, change its `UsagePolicy` in `~/.claude/hooks/orchestrator/profiles.psd1` (`'warn'`, or remove the line to enforce).

After the reset, open the handoff file and carry on.

## If something is refused

- **"available only for a user-typed … invocation"**: a worker was requested with no workflow active. Type the command, or `/magnum-opus on`.
- **"use only …"**: the lead tried a built-in agent or the other workflow's worker. This is expected; it re-routes.
- **API key / gateway / forced subagent model**: start Claude Code without `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL` or `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`.
- **Usage guard refusal**: wait for the five-hour reset.

## Checking it works

While workers run, `/tasks` shows each one and its model. The offline test suite (`~/.claude/hooks/orchestrator/tests/run-tests.ps1`) replays about 110 synthetic hook events with no model calls.

## Removing it

Ask Claude: "Uninstall the orchestrators using INSTALL.md." It removes the files and only the settings entries it added.
