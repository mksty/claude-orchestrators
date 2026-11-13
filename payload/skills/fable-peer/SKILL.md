---
name: fable-peer
description: Explicitly run one task with Fable and one Opus peer workstream, then integrate the result.
argument-hint: "<task or follow-up | stop>"
disable-model-invocation: true
user-invocable: true
model: fable
---

Delegation adds briefing, context, review, and integration overhead. Delegate only when the payoff clearly exceeds that overhead.

Use the Fable Peer workflow for this explicitly requested task:

$ARGUMENTS

`/fable-peer stop` is a control command, not a task. The installed guard saves a fallback handoff immediately, blocks new or resumed peer workers, and lets an active worker finish its current tool batch before stopping. Do not dispatch work for that command.

This policy applies only to this invocation. A later ordinary prompt does not activate it; use `/fable-peer` again for a follow-up. If there is no task and no clear task in context, ask for the task before taking action.

## Peer-workstream routing

You are not only a coordinator. First make a brief, concrete plan that separates the task into independent workstreams with non-overlapping file ownership. You personally own and execute one substantive Fable workstream: investigate it, make its local design decisions, implement it, and run its targeted checks.

When the task can be split safely, dispatch exactly one `fable-peer-opus-worker` to own a comparably substantive, independent Opus workstream. Its brief must state the outcome, relevant evidence, exclusive file ownership, constraints, dependencies, and acceptance checks. Start it promptly, then continue executing your own Fable workstream while it runs. Do not wait idly for the worker when you have independent work.

If the task genuinely cannot be divided without duplicated investigation, conflicting edits, or artificial work, do it directly and state that no safe Opus workstream existed.

Do not dispatch any other worker. In particular, the Opus worker is a leaf: it must not create helpers, agent teams, forks, or nested CLI agents. Do not send routine review-only work to Opus; it should own a real investigation or implementation slice.

## Integration and verification

Preserve existing user edits. Do not allow concurrent edits to the same file. When the Opus report returns, inspect its decisive diff and evidence, resolve cross-workstream issues, and complete the integration and final response yourself. Run verification proportionate to the combined change.

Require the Opus worker to return a compact report with outcome, changed files or evidence locations, checks actually run and their results, and remaining uncertainties or blockers.

## Billing and limits

This is a one-shot workflow, not a toggle. It selects Fable for this command and pins its single peer worker to Opus; account settings determine billing buckets. Do not change authentication, usage-credit settings, overflow, model aliases, routing hooks, or authorization state. If Fable or Opus is unavailable or quota blocks the worker, report that limitation rather than silently substituting a model.
