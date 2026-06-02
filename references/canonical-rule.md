# WarmPulse: heartbeat against the prompt-cache TTL

> **Hard rule (activation):** when a session enters an idle-wait state (operator AFK, parallel session output, PR convergence, CI run, deploy, or any external trigger), arm a WarmPulse: a Monitor with intervals under 270 seconds whose stdout keeps the prompt cache warm. The main interactive thread runs a **~1-hour** effective cache TTL in the measured corpus (not 5 minutes), so a real re-prime is at stake only once the wait approaches or exceeds ~1 hour with a large context. Below that, the 1-hour cache holds the prefix for free and the heartbeat buys resume-latency readiness, not dollar savings (see "Cost, honest"). Arm when a long or open-ended AFK is plausible; the per-tick cost is small but not zero.
>
> **Hard rule (maintain):** once armed, the agent MUST NOT stop the WarmPulse. With `persistent=true` (default), runs until operator instruction only. With `persistent=false`, runs until `timeout_ms`. No other condition authorises `TaskStop`.

## Vocabulary

- **WarmPulse**: a Monitor task whose primary purpose is to emit periodic heartbeat events keeping the Anthropic prompt cache warm. Poll target is incidental; heartbeat is load-bearing.
- **Domain monitor**: a Monitor whose primary purpose is tracking domain state. TERMINAL self-exit on convergence is legitimate for domain monitors, NOT for WarmPulses.
- **Prompt cache**: Anthropic prompt cache holding eager-loaded context (CLAUDE.md, rules, project memory). Effective TTL is two-tier in the measured corpus: the **main interactive thread ~1 hour**, the **subagent/sidechain tier ~5 minutes**. WarmPulse runs on the main thread, so the TTL it defends is ~1 hour. A miss costs 10k to 50k re-prime tokens.
- **Heartbeat**: any stdout line emitted by the poll loop. Each line resets the TTL clock.

## Invariant

Effective prompt-cache TTL is **two-tier** in the measured corpus (286886 turns, replicated on 3 nodes): the **main interactive thread ~1 hour** (98.87% of main writes land in the 1-hour bucket; serve-probability stays high through 30-60 min then drops past 1-2 h), the **subagent/sidechain tier ~5 minutes**. WarmPulse runs on the main thread, so the TTL it defends is ~1 hour, not 5 minutes. After that interval without activity the cache expires and the next turn re-primes the full context at base token rate.

## ARM triggers

Arm a WarmPulse in any of:

- **Operator AFK**: stepped away with open question or pending decision.
- **Parallel session**: another session running a cycle whose result the current session needs.
- **External job**: CI run, deploy, background script, remote queue job.
- **PR convergence**: bot pyramid reviewing, merge gate waiting.
- **Cron trigger**: anything on a wall-clock schedule outside the agent's control.

## SKIP triggers

- **Pure read-only response**: question answered, turn ends, no wait state.
- **One-shot completion wait**: use `Bash run_in_background` + `until` loop instead (one notification on exit).
- **Short, dollar-neutral wait**: any wait the ~1-hour main cache holds for free (well under ~1 h). No re-prime is at stake, so arm only if you want resume-latency insurance, never for dollar savings.

## Canonical pattern

```bash
ITER=0
while true; do
  ITER=$((ITER+1))
  echo "BEAT-${ITER}"
  sleep 240
done
```

Six lines. No remote API. Each `echo` emits one stdout line; arrives as a conversation event; counts as session activity.

**Invocation**: `Monitor(command="...", persistent=true, summary="WarmPulse")`. Use `Skill(warmpulse)` or `/warmpulse` for canonical defaults.

## Maintain: no unilateral TaskStop

Forbidden `TaskStop` reasons:

- Watched state converged (PR merged, CI green, deploy succeeded).
- Cycle reached true-zero or any domain-level closure signal.
- Session looks idle and WarmPulse seems redundant.
- Errors keep firing (self-handle via `|| true` and `ERR` emission).

**Authorised stop**: explicit operator instruction only ("stop the WarmPulse", "kill task `<id>`").

**Zero-gap swap**: arm new FIRST, verify INIT, then stop old.

## Proactive activation

After idempotency check (no WarmPulse already running in session):

1. End of `/goal` block assembly destined for a later session.
2. After "surface in final message" per `session-handoff-discipline.md §2.1`.
3. After AskUserQuestion when the answer is plausibly a long wait away (a dollar payoff needs the wait to approach the ~1-hour main TTL; arm sooner if resume-latency matters).

**Defaults**: `persistent=true`; 240s interval; BEAT-${ITER} emit; NONE TERMINAL self-exit.

**Announcement** (one line): `WarmPulse armed (task <id>, BEAT every 240s, persistent until operator stop).`

## Cadence

| Resource | Interval |
|---|---|
| Local filesystem / process | 0.5 to 5 s |
| GitHub API | 90 to 240 s |
| CI run | 60 to 120 s |
| Pure WarmPulse | 240 s |

Hard ceiling: **270 seconds**. Never 300s.

Note on the 240s default: against a ~1-hour main TTL, 240s ticks roughly 15x more often than the TTL strictly requires. The tight interval is deliberate but it buys **resume-latency readiness** (the prefix is always warm for the next interaction), not dollar savings. A wider interval would still hold the 1-hour cache; the cost of the extra ticks is the per-tick `cache_read` of the full prefix (see "Cost, honest"). Keep 240s when resume-latency matters; widen it toward the 1-hour tier when only the dollar/quota floor matters.

## Surface-N ack

Default: emit `BEAT-N` from the incoming event. ~3 to 5 output tokens per tick. Fallback (200h+ unattended): single space. Narration only for ERR or CHG- events.

## Filter discipline

Composable variant and domain monitors: emit only on state change; `grep --line-buffered` in pipes; `ERR` on transient failure. Pure 6-liner WarmPulse: emits BEAT-N on every tick (by design). No TERMINAL self-exit for WarmPulses.

## Common AFK patterns

| Pattern | Interval | Terminal exit |
|---|---|---|
| PR merge watch | 120 s | state == MERGED |
| CI run watch | 60 s | conclusion != null |
| Parallel session commit | 90 s | new SHA |
| **WarmPulse** | 240 s | **NONE** |

## Cost, honest

The v0.8.0 forensic close-out measured the real economics on the pay-as-you-go dollar axis (per-MAIN-session counterfactual over the corpus):

- **Net-cost on dollars.** Removing WarmPulse saves ~$1144 across the corpus (BEAT spend $1247.95 vs counterfactual reprime $104.11). 96% of heartbeats bridge sub-5-minute gaps the 1-hour cache holds for free; only 24 reprime events were genuinely avoided. The earlier "12 misses/hour" / "8x ROI" figures assumed the 5-minute tier and do not hold on the main thread.
- **Per-tick cost is cache_read-dominated.** ~$0.13 per BEAT (the served read of the full prefix), not the ~200-token emit. Payback is far below the optimistic 700:1 / 11:1 estimates that counted only the emit.
- **Where the value survives** (the dollar model does not price these): **resume-latency** (a warm prefix avoids the wall-clock re-prime delay on the next interaction after a long AFK), **subscription quota** (cache_read is charged at ~10% of base; avoiding even ~1 reprime/hour on a large context saves quota tokens), and **zero marginal CASH on a subscription** (quota-metered, not pay-as-you-go, so the net-cost is a pay-as-you-go-equivalent statement, not a subscription bill).
- **No context pressure.** On length-normalized per-turn rates WarmPulse sessions reprime 0.33x and compact 0.21x relative to non-BEAT (observational contrast; BEAT sessions are self-selected long autonomous cycles).

Reframe: WarmPulse trades a small, bounded quota/latency cost for resume-readiness against a ~1-hour TTL. Net-neutral-to-slightly-negative on dollars; arm it for the latency/quota/continuity value on long AFKs, not for a dollar saving.

## Cross-references

- Honest cost counterfactual (net-cost on dollars; value on quota + latency + zero subscription cash): `send-package/05-CACHE-MECHANICS-ANNEX.md` + `04-IMPLEMENTATION-ANNEX.md` (v0.8.0 forensic report)
- Full procedure, composable variant: `Skill(warmpulse)` / `skills/warmpulse/SKILL.md`
- Monitor invocation: `/warmpulse` or `commands/warmpulse.md`
- Sibling rules: `goal-prompt-4000-char-limit.md`, `autonomous-mode-invariants.md`, `session-handoff-discipline.md §2.1`, `goal-subagent-orchestration.md`
- Codification history (v1.0.0 through v1.3.0): `doctrine-snapshots/warmpulse-empirical-anchors.md`

∵ RCR Regis ∴

*v2.1.0 - 2026-05-30 | TTL premise corrected to the measured two-tier model (main ~1h, subagent ~5m); activation, cadence rationale, and cost framing reconciled with the v0.8.0 forensic counterfactual (net-cost on dollars, value on quota/latency/zero subscription cash). Mechanics (no-unilateral-TaskStop, Monitor-vs-Bash, 270s ceiling) unchanged.*
