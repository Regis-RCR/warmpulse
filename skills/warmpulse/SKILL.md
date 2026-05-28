---
name: warmpulse
description: Use when a Claude Code session enters an idle-wait state (operator AFK, parallel session output, external job pending, PR convergence, cron trigger) that may exceed 5 minutes. Arms a Monitor heartbeat at 240-second interval emitting BEAT-N lines. Each line counts as session activity, keeping the Anthropic prompt cache hit-priced across the wait. Skip in pure-read responses, one-shot completion waits, and sub-5-minute work.
license: Apache-2.0
allowed-tools: Monitor Bash
metadata:
  version: 1.1.0
---

# WarmPulse

Heartbeat Monitor against the Anthropic 5-minute prompt-cache TTL. Doctrine: `~/.claude/rules/warmpulse.md`.

## Arming procedure

1. **Idempotency check**: if a task with `summary="WarmPulse"` is already running, refuse with "WarmPulse already armed (task `<id>`)." Do NOT arm a second instance.

2. **Invoke Monitor**:

```
Monitor(
  command="ITER=0 ; while true ; do ITER=$((ITER+1)) ; echo \"BEAT-${ITER}\" ; sleep 240 ; done",
  persistent=true,
  summary="WarmPulse",
  description="WarmPulse heartbeat at 240s interval"
)
```

3. **Announce**: `WarmPulse armed (task <id>, BEAT every 240s, persistent until operator stop).`

## ARM / SKIP

ARM in any idle-wait state that may exceed 5 minutes: operator AFK, parallel session output, external job, PR convergence, cron trigger.

SKIP: pure read-only response; one-shot completion wait under 5 min (use `Bash run_in_background` + `until` instead); sub-5-minute work.

## Canonical pattern

```bash
ITER=0
while true; do
  ITER=$((ITER+1))
  echo "BEAT-${ITER}"
  sleep 240
done
```

## Composable variant

Use when domain signal is also worth surfacing (same interval, no extra cost):

```bash
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
  sleep 240
done
```

`BEAT-N` = heartbeat; `CHG-N` = state change. Use minimal 6-liner for pure AFK; composable when domain signal wanted AND heartbeat remains primary purpose. When watch-for-end intent dominates: use a domain monitor (TERMINAL self-exit legitimate), not a WarmPulse.

## Tool selection rationale

**Monitor over Bash run_in_background**: Bash gives one notification (job exit). Between start and exit, conversation goes silent. If the job takes >5 min, the cache expires before notification arrives. Monitor streaming events arrive on every loop tick, keeping cache warm.

**Monitor over ScheduleWakeup**: ScheduleWakeup is for `/loop` autonomous mode. Any delay >270s pays a cache miss on wake. Use ScheduleWakeup for recurring cron-like tasks, not for interactive WarmPulse.

## Decision rules

**ARM proactively** (Pro/Max subscription): any idle wait >5 min with context >50k tokens. For API key: any wait >10 min with context >80k tokens.

**DO NOT ARM** (API key with 1h opt-in): 1h TTL absorbs AFK windows; exception: multi-hour AFK with 200k+ context.

**WarmPulse vs domain monitor**: WarmPulse if intent = "keep cache warm while I wait"; domain monitor if intent = "watch X until done" (TERMINAL self-exit legitimate for domain monitors).

## Full arming defaults

- `persistent=true`: runs until operator TaskStop or session end. `timeout_ms` ignored. Use `persistent=false` + `timeout_ms` ONLY for bounded wait under 1h.
- `summary="WarmPulse"` (literal): each extra word costs ~1 token per tick on multi-day runs.
- Interval: 240s (hard ceiling 270s; never 300s).
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
- Cost math, ROI analysis: `send-package/04-IMPLEMENTATION-ANNEX.md` + `05-CACHE-MECHANICS-ANNEX.md` (dev repo)
- Slash command: `/warmpulse` or `commands/warmpulse.md`
- Codification history: `doctrine-snapshots/warmpulse-empirical-anchors.md` (dev repo)

∵ Regis RCR ∴

*v1.1.0 - 2026-05-28 | [Changelog](.development/changelog.md)*
