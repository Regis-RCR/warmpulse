---
name: warmpulse
description: Use when a Claude Code session enters an idle-wait state (operator AFK, parallel session output, external job pending, PR convergence, cron trigger) that may exceed 5 minutes. Arms a Monitor heartbeat at 240-second interval emitting BEAT-N lines. Each line counts as session activity, keeping the Anthropic prompt cache hit-priced across the wait. Skip in pure-read responses, one-shot completion waits, and sub-5-minute work.
license: Apache-2.0
allowed-tools: Monitor Bash
metadata:
  version: 1.0.0
---

# WarmPulse

Heartbeat Monitor pattern against the Anthropic 5-minute prompt-cache TTL.

## Invariant

The Anthropic prompt cache has a TTL of approximately **5 minutes**. After that interval without conversation activity, the cache entry expires and the next turn must re-prime the full eager-loaded context (CLAUDE.md, AGENTS.md, user-global rules, project memory). The cost is real: 10k to 50k tokens of re-prime per cache miss, plus billing, plus cold-start latency.

A WarmPulse is an active polling mechanism whose stdout serves as a conversation heartbeat. Polling intervals strictly under 270 seconds stay inside the cache window. The 240-second cadence is the empirical sweet spot.

## When this rule fires

Arm a WarmPulse in any of these idle-wait states:

- **Operator AFK**: the operator stepped away or said "I'll come back later" with an open question or pending decision.
- **Parallel session output**: another Claude Code session is running a cycle whose output the current session needs.
- **External job pending**: a CI run, a deploy, a remote queue job, a long-running background script.
- **PR state convergence**: bot pyramid reviewing (CodeRabbit + Codex + Gemini + Copilot + Kilo), merge gate waiting for approvals or CI green.
- **Cron / scheduled trigger**: anything on a wall-clock schedule outside the agent's control.

## Skip in

- **Pure read-only response**: question + answer + turn ends. No wait state.
- **One-shot completion wait**: when one notification at the end of a finite job is sufficient (use `Bash run_in_background` with an `until` loop instead).
- **Sub-5-minute work**: if the expected wait stays under 4 minutes, a single Bash poll is fine.

## Minimal pattern

The canonical WarmPulse watches nothing but the clock:

```bash
ITER=0
while true ; do
    ITER=$((ITER+1))
    echo "BEAT-${ITER}"
    sleep 240
done
```

Six lines. No `gh`, no `git`, no remote API. Each `echo` emits one short stdout line (`BEAT-1`, `BEAT-2`, ...). The line arrives as a conversation event, counts as session activity, and resets the cache TTL clock. The `BEAT-${ITER}` token is the operator's grep hook for cost auditing.

## Tool invocation

```
Monitor(
    command="ITER=0 ; while true ; do ITER=$((ITER+1)) ; echo \"BEAT-${ITER}\" ; sleep 240 ; done",
    persistent=true,
    summary="WarmPulse",
    description="WarmPulse heartbeat at 240s interval"
)
```

The `summary` field is rendered verbatim in every event notification. Keep it literally `"WarmPulse"`. Each extra word costs ~1 token per tick (cumulatively significant on multi-day runs).

## Surface-N ack discipline

Each BEAT event arrives as a task-notification. The agent MUST keep the ack minimal but SHOULD surface the BEAT counter visibly.

**Default (v1.2.5+): Surface-N ack.** Extract `BEAT-N` from the incoming event content and emit it as the agent response. Cost ~3 to 5 output tokens per tick. Visible in the TUI scroll under each `⏺ Monitor event` line, giving the operator a live counter and a grep-target for transcript audit.

**Fallback : single-space ack.** When output cost dominates over visibility on very long unattended runs (200h+), emit a single space character. Cost ~1 output token per tick. Invisible in the TUI scroll.

**Narration ack** is reserved for events carrying actionable signal (ERR lines on persistent polling failure, CHG- lines in the composable variant indicating real state change). Pure BEAT-N ticks are benign and never warrant prose acknowledgement.

## Maintain rule

A WarmPulse is operator property. Once armed (by explicit operator request OR by proactive activation), the agent MUST NOT stop it. The Monitor runs to its `timeout_ms` (when not persistent) OR until the operator explicitly instructs its termination.

**Forbidden actions:**

- `TaskStop` "because the watched state converged" (PR merged, CI green, deploy succeeded). WarmPulse purpose is unrelated to the watched state ; the watched state is incidental noise the poll loop emits, not the reason the WarmPulse exists.
- `TaskStop` "because the cycle reached true-zero" or any domain-level closure signal. Domain-level closure does NOT imply operator-level closure of the idle wait.
- `TaskStop` "because the session looks idle and the WarmPulse seems redundant". Idle is exactly when the WarmPulse is needed ; the cache TTL ticks during idle.
- `TaskStop` "because errors keep firing" (rate-limit, network blip). The poll loop self-handles transient failures via `|| true` and short `ERR` emissions ; persistent failure is information the operator wants, not authorisation to stop.

**Authorised conditions to stop:**

- Explicit operator instruction ("stop the WarmPulse", "kill task `<id>`"). Only.

The poll target is incidental ; the heartbeat is load-bearing. Whether the watched state happens to have converged is irrelevant ; WarmPulse is a property of the session-wall-clock, not of the watched state.

## Cross-references

- Full canonical operator rule (~437 lines, ~52KB) covering proactive activation triggers, idempotency check, Tier-conditional ROI analysis (Pro / Max / API key), filter discipline, common AFK patterns, empirical anchors : [`references/canonical-rule.md`](../../references/canonical-rule.md).
- Companion slash command (idempotent arming with canonical defaults) : [`commands/warmpulse.md`](../../commands/warmpulse.md).
- Standalone script for non-Claude-Code use : [`scripts/warmpulse.sh`](../../scripts/warmpulse.sh).

∵ Regis RCR ∴

*v1.0.0 - 2026-05-28 | [Changelog](.development/changelog.md)*
