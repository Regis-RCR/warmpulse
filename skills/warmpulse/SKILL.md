---
name: warmpulse
description: Use when a Claude Code session enters an idle-wait state (operator AFK, parallel session output, external job pending, PR convergence, cron trigger), especially a long or open-ended one. Arms a Monitor heartbeat at an adaptive interval (default 3300s just under the ~1h main TTL, scaled down to the requested wait window) emitting BEAT-N lines that count as session activity and keep the Anthropic prompt cache warm across the wait. The main interactive thread runs a ~1-hour effective TTL (measured), so the heartbeat buys resume-latency readiness, with a dollar payoff only on AFKs approaching ~1 hour with large context. Skip in pure-read responses, one-shot completion waits, and short dollar-neutral waits.
license: Apache-2.0
allowed-tools: Monitor Bash
metadata:
  version: 1.3.0
---

# WarmPulse

Heartbeat Monitor against the Anthropic prompt-cache TTL (measured two-tier: main interactive thread ~1 hour, subagent tier ~5 minutes; WarmPulse runs on the main thread). Doctrine: `~/.claude/rules/warmpulse.md`.

## Arming procedure

1. **Idempotency check**: if a task with `summary="WarmPulse"` is already running, refuse with "WarmPulse already armed (task `<id>`)." Do NOT arm a second instance.

2. **Compute the interval** from the requested window (the `/warmpulse` argument, natural form: `5 minutes`, `1h`, `55 minutes`; empty = open-ended):

   - `W` = window in seconds (empty -> open-ended).
   - `margin = clamp(W/12, 60s, 300s)` ; `INTERVAL = clamp(W - margin, 60s, 3300s)`.
   - Empty window -> `INTERVAL=3300`, persistent.
   - The 3300s cap sits just under the proven ~1h main TTL: a BEAT every <=55 min resets the 1h cache, so one cadence holds any wait length. Below 1h the cadence matches the named window (5 min -> 240s, 30 min -> 1650s), not a fixed 240s.

3. **Invoke Monitor** with the computed INTERVAL:

```
Monitor(
  command="ITER=0 ; while true ; do ITER=$((ITER+1)) ; echo \"BEAT-${ITER}\" ; sleep <INTERVAL> ; done",
  persistent=<true if open-ended ; false + timeout_ms=W*1000 if a finite window was named>,
  summary="WarmPulse",
  description="WarmPulse heartbeat at <INTERVAL>s interval"
)
```

4. **Announce**: `WarmPulse armed (task <id>, BEAT every <INTERVAL>s, <persistent until operator stop | bounded ~<window>>).`

## ARM / SKIP

ARM in any idle-wait state, especially a long or open-ended one: operator AFK, parallel session output, external job, PR convergence, cron trigger. The dollar payoff needs an AFK approaching ~1 hour with large context (the ~1-hour main TTL holds shorter waits for free); shorter waits buy resume-latency only.

SKIP: pure read-only response; one-shot completion wait (use `Bash run_in_background` + `until` instead); short dollar-neutral waits the ~1-hour main cache already holds.

## Canonical pattern

```bash
INTERVAL=3300   # default ; scale down to the requested window (5 min -> 240)
ITER=0
while true; do
  ITER=$((ITER+1))
  echo "BEAT-${ITER}"
  sleep "$INTERVAL"
done
```

## Composable variant

Use when domain signal is also worth surfacing (same interval, no extra cost):

```bash
INTERVAL=3300   # default ; scale down to the requested window
PREV=""
ITER=0
while true; do
  ITER=$((ITER+1))
  CUR=$(git log -1 --format=%h 2>/dev/null || echo "n/a")
  if [[ "$CUR" != "$PREV" && -n "$PREV" ]]; then
    echo "CHG-${ITER} HEAD $PREV to $CUR"
  else
    echo "BEAT-${ITER}"
  fi
  PREV=$CUR
  sleep "$INTERVAL"
done
```

`BEAT-N` = heartbeat; `CHG-N` = state change. Use minimal 6-liner for pure AFK; composable when domain signal wanted AND heartbeat remains primary purpose. When watch-for-end intent dominates: use a domain monitor (TERMINAL self-exit legitimate), not a WarmPulse.

## Tool selection rationale

**Monitor over Bash run_in_background**: Bash gives one notification (job exit). Between start and exit, conversation goes silent. If the wait exceeds the main-thread TTL (~1 hour), the cache expires before that single exit notification arrives. Monitor's streaming events arrive on every loop tick, keeping the prefix warm; even below 1 hour Monitor preserves resume-latency (the prefix stays hot for the next interaction).

**Monitor over ScheduleWakeup**: ScheduleWakeup is for `/loop` autonomous mode. A delay approaching the ~1h main TTL pays a cache miss on wake. Use ScheduleWakeup for recurring cron-like tasks, not for interactive WarmPulse.

## Decision rules

**ARM proactively** (Pro/Max subscription): marginal CASH is zero (quota-metered, not pay-as-you-go), so arm for any long or open-ended AFK where resume-latency matters; the only cost is bounded quota tokens (`cache_read` at ~10% of base). Largest value on AFKs with a big context.

**ARM** (API key, pay-as-you-go): arm only when the AFK approaches or exceeds ~1 hour with a large context (>80k tokens), where a real reprime on the ~1-hour main TTL is at stake. Below ~1 hour the cache holds for free and the heartbeat net-costs dollars.

**DO NOT ARM**: short waits the ~1-hour main TTL absorbs for free (on API key, paying dollars for nothing); exception: multi-hour AFK with 200k+ context where the reprime is large and certain.

**WarmPulse vs domain monitor**: WarmPulse if intent = "keep cache warm while I wait"; domain monitor if intent = "watch X until done" (TERMINAL self-exit legitimate for domain monitors).

## Full arming defaults

- `persistent=true`: runs until operator TaskStop or session end. `timeout_ms` ignored. Use `persistent=false` + `timeout_ms` ONLY for a bounded wait (e.g. within the ~1-hour main TTL).
- `summary="WarmPulse"` (literal): each extra word costs ~1 token per tick on multi-day runs.
- Interval: adaptive, default 3300s (cap 3300s, just under the ~1h main TTL); scales down to the requested window (5 min -> 240s); floor 60s. The legacy fixed 240s default was a 5-minute-tier artifact and over-ticks ~15x against the measured ~1h main TTL.
- TERMINAL self-exit: NONE for WarmPulses.

## Zero-gap swap

When swapping WarmPulse targets:

1. Ask operator via AskUserQuestion (WarmPulse stays running during question).
2. On approval: arm new FIRST, verify INIT.
3. THEN stop old WarmPulse.

A gap between stop and arm reintroduces the cache miss this rule exists to prevent.

## Ack discipline

- **Surface-N** [DEFAULT]: emit `BEAT-N` from event. ~3 to 5 output tokens per tick. Operator sees counter in TUI scroll.
- **Single-space fallback**: 1 token per tick. Invisible in TUI. Use on 200h+ unattended runs only.
- **Narration**: only for ERR (persistent polling failure) or CHG- (real state change). Never for pure BEAT-N.

Retired: middle-dot `·` ack (v1.2.3, operator pushback 2026-05-28). True zero-output (v1.2.4 aspiration, impossible: API requires non-empty assistant content).

## Cross-references

- Operator rule (eager-loaded): `~/.claude/rules/warmpulse.md`
- Full rule snapshot: `references/canonical-rule.md`
- Honest cost counterfactual (net-cost on dollars; value on quota/latency/zero subscription cash): `send-package/04-IMPLEMENTATION-ANNEX.md` + `05-CACHE-MECHANICS-ANNEX.md` (dev repo, v0.8.0 forensic report)
- Slash command: `/warmpulse` or `commands/warmpulse.md`
- Codification history: `doctrine-snapshots/warmpulse-empirical-anchors.md` (dev repo)

∵ Regis RCR ∴

*v1.3.0 - 2026-06-03 | [Changelog](.development/changelog.md)*
