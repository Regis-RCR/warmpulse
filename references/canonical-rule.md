# WarmPulse: heartbeat against the prompt-cache TTL during idle sessions

> **Hard rule (activation):** when a session is in an idle-wait state (waiting for an operator reply, a parallel session output, a PR state change, a CI run, a deploy, or any external trigger that may take more than ~5 minutes), the agent MUST arm a WarmPulse: an active polling mechanism with intervals strictly under 270 seconds whose stdout serves as a conversation heartbeat. Going silent past the cache TTL costs the operator the full re-prime on resume.
>
> **Hard rule (maintain):** once a WarmPulse is armed (either on operator request OR by proactive activation per §"Proactive activation"), the agent MUST NOT stop it. The Monitor runs to its `timeout_ms` OR until the operator explicitly instructs its termination. No other condition authorises the agent to call `TaskStop` on a WarmPulse: not "state converged", not "no PR open", not "looks idle now", not "we are done". The WarmPulse is a heartbeat against the 5-minute prompt-cache TTL ; its purpose is NOT to watch GitHub or any specific state, even if its current poll loop happens to surface GitHub events as a side-effect.

## Vocabulary

- **WarmPulse**: the named discipline + the named artefact. A WarmPulse is a `Monitor` task whose primary purpose is to emit periodic heartbeat events that keep the Anthropic prompt cache warm. The poll target (`gh pr list`, `git fetch`, `ls`) is incidental ; the heartbeat is the load-bearing function. Capitalize as `WarmPulse` in prose, identifiers, and operator-facing announcements.
- **Domain monitor**: a `Monitor` task whose primary purpose is to track a specific domain state (PR merge convergence, CI run completion, deploy success). A domain monitor often serves as a WarmPulse in side-effect, but its lifecycle is governed by the watched state (TERMINAL self-exit on convergence is legitimate). The two roles are NOT identical ; the discriminator is intent.
- **prompt cache**: the Anthropic 5-minute TTL cache that holds the eager-loaded context (CLAUDE.md, AGENTS.md, user-global rules, project memory). A cache miss costs 10k to 50k re-prime tokens.
- **heartbeat**: any stdout line emitted by a poll loop. Each heartbeat resets the TTL clock on the prompt cache.

The distinction matters because the maintain rule below applies STRICTLY to WarmPulses and gracefully to domain monitors. A domain monitor watching `gh pr view 123 --merged` with TERMINAL self-exit on MERGED is fine ; a WarmPulse armed proactively to cover an AFK wait must NOT carry a TERMINAL self-exit, since cache-warm purpose has no end-state.

## Invariant

The Anthropic prompt cache has a TTL of approximately **5 minutes**. After that interval without activity on the conversation, the cache entry expires and the next turn must re-prime the full context. The cost is real: 5-10k+ tokens of eager-load (CLAUDE.md, AGENTS.md, eager rules, current memory) re-read on every cache-miss, plus the per-token billing on the re-prime, plus the latency of cold-start inference.

In an autonomous /goal cycle the runtime handles this transparently (the agent stays busy or schedules wakeups). In an **interactive session that legitimately needs to wait** (operator AFK, parallel session running, external job pending), the agent must NOT just stop and wait silently. Each silent 5+ minute gap is a paid re-prime.

The mitigation is structural: arm a WarmPulse, whose stdout serves as a conversation heartbeat, keeping the cache entry warm. Polling intervals strictly under 270 seconds stay inside the cache window and amortize over many checks ; 240-270s is the empirical sweet spot for remote APIs that have rate limits (one gh poll per ~4 minutes is well under any quota concern).

## When this rule fires

Apply in any of these idle-wait states:

- **Operator AFK**: the operator has explicitly stepped away or said "I'll come back later", and the session has an open question or a pending decision.
- **Parallel session output**: another Claude Code session is running a cycle (release, absorption, audit) whose output the current session needs before proceeding.
- **External job pending**: a CI run, a deploy, a remote queue job, a long-running script in background that the current session is monitoring.
- **PR state convergence**: bot pyramid reviewing (CodeRabbit + Codex + Gemini + Copilot + Kilo), merge gate waiting for approvals or CI green, cross-repo PR awaiting maintainer action.
- **Cron / scheduled trigger**: anything that fires on a wall-clock schedule outside the agent's control.

Skip in:

- **Pure read-only response**: the operator asks a question, the agent answers, the turn ends. No wait state.
- **One-shot completion wait**: when the only thing needed is a single notification at the end of a known finite job (use `Bash run_in_background` with an `until` loop ; you get one notification on exit, no WarmPulse needed because the job completes before the cache TTL or the wait is bounded).
- **Sub-5-minute work**: if the expected wait is reliably under 4 minutes, simple polling in a single Bash call is fine.

## Tool selection

The canonical WarmPulse tool is **`Monitor`**:

```
Monitor(command="<poll loop emitting event lines>", timeout_ms=<wait duration>, persistent=false)
```

Each stdout line from the poll loop arrives as a conversation event, which counts as activity for cache-warm purposes AND notifies the agent about the state change. The agent can act on substantive events (PR merged, new finding, deploy failed) and ignore routine progress (count unchanged, status still pending).

**Why Monitor over Bash run_in_background**: Bash run_in_background gives exactly one notification (job exit). Between start and exit, the conversation goes silent. If the job takes more than 5 minutes, the cache expires before the notification arrives. Monitor's streaming events arrive on every state change inside the polling loop, keeping the cache warm across the full wait.

**Why Monitor over ScheduleWakeup**: ScheduleWakeup is designed for `/loop` autonomous mode, not interactive idle. ScheduleWakeup with a delay over 270s pays the cache miss on every wake. Use ScheduleWakeup for genuine recurring tasks (cron-like), not for interactive WarmPulse.

## Minimal WarmPulse pattern

The canonical WarmPulse is a Monitor that **watches nothing but the clock**:

```bash
ITER=0
while true; do
  ITER=$((ITER+1))
  echo "BEAT-${ITER}"
  sleep 240
done
```

Six lines. No `gh`, no `git`, no `curl`, no remote API. Each `echo` emits ONE short stdout line (`BEAT-1`, `BEAT-2`, ...), which arrives as a conversation event and counts as session activity. Cache stays hit-priced across the wait. The `BEAT-${ITER}` token is the operator's grep hook for cost auditing after the fact ; wall-clock coverage is reconstructible from `(LAST_N - FIRST_N) * 240` seconds, so the timestamp + descriptive suffix are redundant in the event line itself and waste ~10 tokens per tick.

**Monitor description (the `summary` field surfaced in every event wrapper)** must be minimal: literally `"WarmPulse"`. The description text is included verbatim in every task-notification, so each extra word costs ~1 token per tick. Avoid embedding descriptive phrases like "pure heartbeat" or "every 240s" or "cache-warm tick" ; they convey no information the rule does not already carry, they consume ~15 tokens per tick cumulatively, and they read as runtime narration the operator did not ask for.

**Composable variant** (WarmPulse + state-change polling on the same Monitor, same interval, no extra cost):

```bash
PREV_HEAD=""
ITER=0
while true; do
  ITER=$((ITER+1))
  CUR_HEAD=$(git log -1 --format=%h 2>/dev/null || echo "n/a")
  NOW=$(date +%H:%M:%S)
  if [[ "$CUR_HEAD" != "$PREV_HEAD" && -n "$PREV_HEAD" ]]; then
    echo "$NOW CHG-${ITER} HEAD $PREV_HEAD to $CUR_HEAD"
  else
    echo "$NOW BEAT-${ITER} stable head $CUR_HEAD"
  fi
  PREV_HEAD=$CUR_HEAD
  sleep 240
done
```

`BEAT-${ITER}` lines cover cache continuity (heartbeat purpose). `CHG-${ITER}` lines cover actionable signal (state-change purpose). Same loop, same interval, no extra arming cost. Works for git HEAD, PR mergeability, CI conclusion, filesystem state, anything pollable.

**Pattern selection**: use the minimal 6-liner when proactive arming covers a pure AFK wait with no useful state to track ; use the composable variant when the wait has a domain signal worth surfacing AND the heartbeat is still the primary purpose. Both are WarmPulses (the maintain rule below applies to both). When the watch-for-end intent dominates and the heartbeat is incidental, that is a domain monitor, not a WarmPulse (see Vocabulary above).

## Per-event cost + cache invariant (empirical, v1.2.6 reality check)

Empirical measurement from session jsonl with 1980 BEAT events over ~132h (`-Users-regis-Development-GitHub-Regis-RCR-rcr-plugin-factory-dev/ec1cb12b-9ba7-4c82-9bb4-a209e0d5c354.jsonl`, 2026-05-28). Per-BEAT usage observed :

| Component | Tokens per BEAT | Rate Sonnet | Cost per BEAT Sonnet | Cost per BEAT Opus |
|---|---|---|---|---|
| `input_tokens` (new, non-cached) | 6 | $3/M | $0.000018 | $0.000090 |
| `cache_creation_input_tokens` (1h ephemeral) | 190-700 (avg ~250) | $6/M | $0.0015 | $0.0075 |
| `cache_read_input_tokens` (the cumulative prefix) | **448-449k** | $0.30/M | **$0.134** | $0.672 |
| `output_tokens` (ack) | 14 typical | $15/M | $0.00021 | $0.00105 |
| **TOTAL per BEAT** | | | **~$0.136** | **~$0.683** |

**Critical reality check vs v1.2.5 estimates**: the v1.2.5 cost figure of $0.00027 per BEAT ignored the `cache_read_input_tokens` component, which dominates the actual cost (~500x larger than the per-tick wrapper alone). The full prefix is read on every BEAT, and the read costs $0.30/M Sonnet ; on a 448k-token context this is ~$0.134 per BEAT. Multiply by Opus 5x factor for $0.672 per BEAT.

This dominates the math. WarmPulse cost on a 132h run with 448k-token context = **~$269 Sonnet / ~$1346 Opus**. Not negligible.

**Implication**: WarmPulse ROI depends on whether the avoided re-prime cost exceeds the cumulative cache_read cost it incurs. See §"Tier-conditional ROI" below.

(Earlier v1.2.4 and v1.2.5 figures of ~70 and ~130 tokens per tick referred to the per-tick WRAPPER size, which is correct in isolation but misses that EVERY BEAT also pays the cache_read of the entire accumulated prefix. The per-tick WRAPPER is what you see in the conversation transcript ; the cache_read is what you see in the API usage data. Both bill the operator.)

**Cache invariant**: the monotonically-incrementing ITER counter (BEAT-1, BEAT-2, ...) and the changing timestamp live in the TRAILING event content, never in the prefix the cache keys on. The hash of `eager-load + history-up-to-BEAT-N` is stable across the request for BEAT-N+1. The cache does not invalidate. Each tick pays only the ~95 new-suffix tokens at base rate, plus a small cache-write premium so BEAT-N becomes cached for BEAT-N+1's request.

**Cumulative context-window pressure** (input tokens added to the permanent transcript, no-ack discipline) :

| Wait duration | Ticks emitted | Input tokens added |
|---|---|---|
| 1 hour | 15 | ~1.4k |
| 8 hours overnight | 120 | ~11k |
| 24 hours | 360 | ~34k |
| 200 hours (empirical record) | 3000 | ~285k |

On Sonnet 4.5 (200k context window) the no-ack pressure stays under 20% of the window through 24 hours. With verbose-ack (100 tokens per tick), the same 24h consumes ~71%, saturating context and triggering auto-compaction. The no-ack discipline (next section) is therefore load-bearing on multi-day WarmPulses.

Full per-event token breakdown, cost tables across all ack-disciplines, cache mechanics walkthrough, and audit recipes : see `~/Development/GitHub/Regis-RCR/rcr-plugin-factory-dev/docs/monitor/send-package/04-IMPLEMENTATION-ANNEX.md`.

## Tier-conditional ROI (empirical, v1.2.7 reframed)

WarmPulse ROI must be analyzed in the appropriate currency for each tier. The v1.2.6 analysis used dollars uniformly, which is correct ONLY for API key (pay-per-token) ; subscription tiers (Pro, Max) are quota-bounded, not dollar-bounded, and the relevant metric is quota consumption per AFK window.

### Anthropic models (current as of 2026-05-28)

| Model family | Latest version | Model ID |
|---|---|---|
| Opus | 4.7 | `claude-opus-4-7` |
| Sonnet | 4.6 | `claude-sonnet-4-6` |
| Haiku | 4.5 | `claude-haiku-4-5-20251001` |

Earlier versions in this rule's history (Sonnet 4.5, Opus 4.x) are obsolete labels ; current cost math should reference 4.6 / 4.7 / 4.5 model rates. (Pricing structure differs minimally across the 4.5 to 4.7 versions ; the empirical cost ratios in this rule remain valid in shape, though absolute $ figures should be revalidated against current Anthropic published rates.)

### Cache TTL current state (2026-05-28)

The 1-hour cache for Max subscription was retired and Max returned to **5-minute TTL** several weeks before 2026-05-28. The 1-hour cache option remains available only as a paid premium on the API key (`ttl: 1h` in `cache_control`). The current TTL landscape :

| Tier | Current TTL | Quota / billing metric |
|---|---|---|
| Pro subscription | 5 minutes (default, no override) | Quota-bounded (weekly token allowance) |
| Max subscription | **5 minutes** (recently changed from 1 hour) | Quota-bounded (weekly token allowance + 5h rolling reset) |
| API key default | 5 minutes (default) | Dollar-billed per token |
| API key 1h-cache option | 1 hour (opt-in, paid premium) | Dollar-billed, with 2x base write rate |

This change is the empirical trigger for the WarmPulse technique : on Max + Pro, every AFK window over 5 minutes (a coffee, a parallel session, a meal, drafting a long prompt) now triggers a full cache re-prime that consumes the user's quota at the base-input rate, dramatically faster than the cache-hit-rate consumption WarmPulse incurs.

### Pro / Max subscription (quota-bounded, the dominant case for the WarmPulse audience)

The relevant question is NOT "does WarmPulse cost less in dollars than the avoided re-prime" but "does WarmPulse consume less of the weekly token quota than the avoided re-prime would".

Empirical comparison per AFK window of length T :

| Quantity | Without WarmPulse (5min TTL, idle) | With WarmPulse (240s tick) |
|---|---|---|
| Cache misses per hour | ~12 (one per 5-min TTL expiry) | 0 (TTL constantly refreshed) |
| Per-miss quota consumption | full context at base input rate (e.g. 448k tokens at full rate) | 0 |
| Per-tick quota consumption | n/a | ~448k cache_read at discount rate + ~250 cache_write + ~6 input + ~14 output |
| Quota consumed per hour AFK on 448k context | ~12 × 448k = 5.4M tokens at base rate | ~15 ticks × (~448k at discount + ~270 at write) = ~6.7M cache_read tokens + ~4k cache_write tokens |

**The quota math nuance**: Anthropic does not publish the exact subscription quota formula, but the published cache pricing structure suggests cache_read consumes quota at 10% of base rate (the cache-hit discount). If that ratio applies to quota counting :

- Without WarmPulse: 5.4M tokens at full quota rate = 5.4M "quota-tokens" per hour AFK.
- With WarmPulse: 6.7M cache_read tokens at 10% rate = 0.67M "quota-tokens" + ~50k base-rate for ticks + cache_write ≈ ~0.8M quota-tokens per hour AFK.

**Net : WarmPulse saves roughly 4.6M quota-tokens per hour AFK on a 448k context (~85% reduction)**. On a Pro/Max weekly quota of finite tokens, this is the difference between exhausting the quota in a few days vs surviving the week.

This INVERTS the v1.2.6 recommendation for Max. On Max under the current 5-minute TTL, WarmPulse is essential, not optional.

### API key (dollar-billed)

The dollar math still applies and matches the v1.2.6 empirical decomposition (~$269 Sonnet WarmPulse cost over 132h vs ~$2129 avoided re-prime cost on 448k context with 5-min TTL). API ROI ~8x on this empirical session.

### Operational rule (v1.2.7, current TTL landscape)

| Tier | TTL | WarmPulse recommendation |
|---|---|---|
| **Pro subscription** | 5 min | **ARM by default** for AFK windows over 5 minutes with context over ~50k tokens. Quota savings dominant. |
| **Max subscription** | 5 min (current, changed from 1h) | **ARM by default**, same logic as Pro. The TTL retirement is the empirical trigger for the WarmPulse technique. |
| **API key default** | 5 min | **ARM** when context > 80k and AFK window > 10 min ; strong dollar ROI as measured. |
| **API key 1h opt-in** | 1 hour (paid) | **Do NOT arm by default** ; the paid 1h cache absorbs AFK windows. Exception : multi-hour AFK with 200k+ context where re-primes still accumulate. |

This corrects the v1.2.6 recommendation that "Max users should not arm". The recommendation was based on outdated information (Max 1h TTL) which is no longer true. The 1h Max policy retirement makes WarmPulse essential for that tier.

### Why operators actually use WarmPulse (the human side)

The technique exists to make AFK windows over 5 minutes safe :

- Switching to another Claude Code session, Codex run, CodeRabbit review, GitHub PR triage
- Drafting a long prompt or a specification document outside the active session
- Stepping away for meals, commutes, sleep
- Forgetting to do a handoff and returning to a session whose context cache has fully expired (full re-prime at base rate, several minutes of compute, large quota / dollar burn)

Without WarmPulse, every one of these AFK patterns is a quota tax (Pro/Max) or a dollar tax (API). With WarmPulse, the cache stays warm at the discount rate, the operator can context-switch freely, and the session resumes instantly on return.

## Maintain: no unilateral TaskStop

A WarmPulse is operator property. Once armed (either by explicit operator request OR by proactive activation per the next section), the agent's responsibility is to LET IT RUN.

**Forbidden actions:**

- Calling `TaskStop` on a WarmPulse "because the watched state converged" (e.g. `open=0` PR reached, CI green, deploy succeeded). WarmPulse purpose is unrelated to the watched state ; the watched state is incidental noise the poll loop emits, not the reason the WarmPulse exists.
- Calling `TaskStop` "because the cycle reached true-zero" or "because v2.X.Y shipped" or any other domain-level closure signal. Domain-level closure does NOT imply operator-level closure of the idle wait.
- Calling `TaskStop` "because the session looks idle and the WarmPulse seems redundant". Idle is exactly when the WarmPulse is needed ; the cache TTL ticks during idle.
- Calling `TaskStop` "because errors keep firing" (rate-limit, network blip). The poll loop must self-handle transient failures via `|| true` and a short `ERR` emission ; persistent failure is information the operator wants, not authorisation to stop.

**Authorised conditions to stop:**

- Explicit operator instruction ("stop the WarmPulse", "kill task `<id>`", "tu peux arrêter le moniteur"). Only.

**Natural termination (not agent action):**

- `timeout_ms` expires. The Monitor harness terminates the task on its own ; this is not `TaskStop` called by the agent.

The discriminator is intent. `TaskStop` is an agent action that pre-empts the natural lifecycle. The hard rule above bans every agent-action stop on a WarmPulse except on explicit operator instruction. Whether the watched state happens to have converged is irrelevant ; WarmPulse is a property of the session-wall-clock, not of the watched state.

If the agent observes "this WarmPulse's poll loop is no longer surfacing useful events" and wants to swap to a different poll target (e.g. switch from `gh pr list` to `git fetch` because PR-level convergence is reached but commit-level work is still in flight), the correct procedure is:

1. Ask the operator via `AskUserQuestion` whether to swap (the WarmPulse must keep running during the question ; the question itself is an idle wait).
2. ONLY on operator approval, arm the new WarmPulse FIRST, verify it INITs, THEN stop the old one (zero-gap swap ; the cache must stay warm across the swap).

Stopping the old WarmPulse before arming a replacement reintroduces the silent gap that this rule exists to prevent.

## Proactive activation (idempotent)

The agent MUST arm a WarmPulse proactively (no operator request needed) in any of the following situations, after first verifying that no WarmPulse is already armed in the current session.

**Idempotency check** (run BEFORE arming any new WarmPulse):

Inspect the session's running tasks. If a WarmPulse is already active (same purpose, regardless of which poll target it happens to watch), do NOT arm a second one. Multiple overlapping WarmPulses are noise-multipliers and cost-multipliers ; one is sufficient (it serves the heartbeat purpose regardless of what its filter watches). If the existing WarmPulse's poll target is no longer the most useful one, follow the zero-gap swap procedure from the previous section ; do not arm-in-parallel.

A **domain monitor** running in the session does NOT satisfy the WarmPulse idempotency check unless its purpose was explicitly WarmPulse at arming time. A domain monitor watching `gh pr view 123` until merged is a watch-for-end task that may TERMINAL-exit before the operator's AFK wait ends ; if the agent is uncertain, the safer reading is "domain monitor present, WarmPulse not yet, arm WarmPulse".

How to check: the agent can recall its own recent tool calls in the session and see whether a Monitor task is still running and what its purpose was. If unsure, list session tasks (the harness exposes task state to the agent through prior tool results).

**Activation triggers** (arm proactively when any one fires, after idempotency check passes):

1. **End of `/goal` block assembly destined for a later session.** When the agent has just produced a paste-ready `/goal` block via `rcr-core:writing-goal-bootstraps` (or analogous) and the operator will need to copy + paste into a target session, an AFK wait is implied (the operator may not paste immediately). Arm the WarmPulse at the end of the assembly turn.

2. **End of "surface in final message" per `session-handoff-discipline.md` §2.1.** When the agent has just closed a cycle and surfaced the `/goal` block inline in the final session message, the same AFK assumption applies: the operator reads, may step away to plan, may return minutes or hours later. Arm at the end of the surfacing turn.

3. **After AskUserQuestion when the answer is plausibly >5 min away.** Signals: operator was just AFK in the session, current local time is night-time, the question itself is broad (multi-option strategy choice that requires the operator to think), prior turns showed AFK-style slow responses. When in doubt, lean toward arming ; the cost is bounded and the alternative is a paid re-prime.

4. (Reserved for future codification ; additional triggers may be added on empirical evidence.)

**Empirical sufficiency**: the 3 triggers above are sufficient to cover the empirical AFK-idle cases observed across the 2026-05 RCR cycles. The agent should not freelance additional triggers beyond these without operator validation.

**Parameters for proactive WarmPulse arming** (defaults):

- `persistent: true`. The WarmPulse runs until explicit operator `TaskStop` OR session end. `timeout_ms` is ignored when `persistent: true`. This is the only correct default for a heartbeat whose purpose has no end-state: the empirical cases (overnight 8h, multi-day 200h+ continuous per the public article baseline) exceed the Monitor tool's `timeout_ms` hard cap (3600000 ms = 1 hour). A non-persistent default would force re-arming at the cap, introducing exactly the silent gap the rule exists to prevent.
- Poll interval: 240 seconds (under the 270s ceiling ; tight enough to keep cache warm ; max-cadence-under-ceiling for a benign probe).
- Filter: emit on every poll tick (BEAT-${ITER}). The minimal pattern §"Minimal WarmPulse pattern" is the canonical body. Add CHG-${ITER} lines as composable state-change emissions when domain signal also wanted, same loop.
- Probe: `:` (no-op) is technically sufficient ; the minimal pattern uses `echo "$(date) BEAT-${ITER} ..."` because the date in the line is the operator's grep hook for cost auditing. The probe itself is incidental.
- TERMINAL self-exit: NONE. A WarmPulse never self-exits on watched-state convergence (see §"Filter discipline" below).

**When to deviate from `persistent: true`**: only when the AFK wait is bounded by a known external timer that fires under 1h (e.g. "wait for a 30-minute build then act"). In that case `persistent: false` + `timeout_ms` matching the bound is acceptable, but then the artefact is closer to a domain monitor than a pure WarmPulse and should be named accordingly in the announcement.

**Announcement to operator** (one line, after arming):

```
WarmPulse armed (task <id>, BEAT every 240s, persistent until operator stop).
```

If the harness exposes only an ITER counter (no task-id surfaced at arming time), fall back to:

```
WarmPulse armed (BEAT-<N> every 240s, persistent until operator stop).
```

The ITER counter (BEAT-1, BEAT-2, ...) is emitted in every subsequent event line ; this lets the operator track event count without polling task state. No further narration in the announcement ; the operator knows what this means from this rule. Do NOT include "I will stop it when X" or any condition ; the only condition for stop is explicit operator instruction.

## Polling cadence guidance

Pick the interval based on what is polled. The hard ceiling is **270 seconds** (one Anthropic recommendation buffer below the 300-second cache TTL) ; the practical floor depends on the polled resource:

| Polled resource | Interval | Reason |
|---|---|---|
| Local filesystem / process | 0.5 to 5 s | Cheap, fast state changes worth surfacing immediately |
| Bash subprocess output via tail -f | 1 to 5 s | Streaming-friendly, real-time |
| Daemon health / queue depth | 30 to 60 s | Local, but lower state-change frequency |
| GitHub API (`gh pr view`, `gh run list`) | 90 to 240 s | Remote, rate-limited (5000/hr authenticated) ; 120s is conservative and well under cache TTL |
| CI run status flips | 60 to 120 s | Faster than state changes typically arrive, surfacing transitions promptly |
| Cross-repo PR convergence | 120 to 240 s | Bot reviews trickle in over minutes ; faster polling adds noise without value |
| Long-poll deploys / migrations | 60 to 180 s | Deploys flip slowly ; tighter polling burns budget for no benefit |
| Pure WarmPulse (proactive arming) | 240 s | Heartbeat purpose only ; benign probe, max-cadence-under-ceiling |

**Never set interval at exactly 300s**: it lands exactly on the cache boundary and pays the worst-of-both penalty. Either drop to 270s (stays warm) or accept the cache miss and pick 600s+ to amortize it.

**Never set interval below the resource's minimum sensible cadence**: polling a remote API every 5s when the underlying event takes 60s to flip is pure waste.

## Filter discipline (signal vs noise)

The stdout of the poll loop is the event stream. Each line becomes a conversation message. Aggressive filtering is mandatory:

- Emit **only on state change** (use `prev_*` variables in the loop ; suppress lines when nothing changed).
- Emit **only fields that changed** in the change line (do not dump the full state on every event).
- Use `grep --line-buffered` in any pipe (pipe buffering otherwise delays events by minutes).
- Add an `ERR` line on transient failure (rate limit, network) so the agent knows polling stalled ; do not silently swallow errors.

A well-filtered poll loop emits 0 events while state is stable, 1 event per actual transition. **Do NOT code a TERMINAL self-exit on watched-state convergence for WarmPulses**: the WarmPulse's job is to heartbeat the cache, not to track a domain end-state. A self-exit on `open=0` (or any other domain-level "done" signal) defeats the WarmPulse purpose. Reserve TERMINAL self-exit for **domain monitors** that are explicitly armed by the operator with that intent ("watch this PR until merged") ; for WarmPulses armed proactively or for heartbeat purpose, the loop runs until `timeout_ms` or operator-instructed stop.

## Agent-side ack discipline (surface-N)

Each BEAT event arriving in the conversation is a task-notification with trailing instruction "Routine or benign output doesn't need [a PushNotification]". The agent MUST keep the ack minimal but SHOULD surface the BEAT counter visibly so the operator can read the heartbeat progress in the TUI scroll.

**Default ack (v1.2.5+): emit `BEAT-N` extracted from the event content.**

The Claude Code TUI renders only the Monitor's static description in the surfaced `⏺ Monitor event: "<summary>"` line ; the `<event>` field content (the actual `BEAT-N` counter) is NOT visible to the operator in the default rendering. Surfacing N as the agent ack closes that visibility gap at minimal cost.

Three response options, in preference order :

1. **Surface-N ack** [DEFAULT v1.2.5+]: emit `BEAT-N` (or just the integer `N`) extracted from the incoming event content. Cost: ~3 to 5 output tokens per tick = $0.00006 Sonnet / $0.0003 Opus per tick. Cumulative on 200h (3000 ticks) ≈ $0.18 Sonnet / $0.90 Opus. Visible in the TUI scroll under each `⏺ Monitor event` line, giving the operator a live counter and a grep-target for transcript audit.

2. **Strict no-ack via single space** [FALLBACK, when output cost dominates over visibility]: emit a single space character (the technical minimum the API accepts ; literal zero-output is not API-valid). Cost: ~1 output token per tick. Invisible in the TUI scroll. Use this only on very long unattended runs where every output token matters AND the operator has no need to visually track the counter.

3. **Narration-ack** [ONLY when event carries actionable signal]: emit prose ONLY if the event line carries an ERR (persistent polling failure), a CHG- in the composable variant indicating real state change, or any other content the operator would want surfaced. Cost: 50 to 300 output tokens. A pure `BEAT-N` tick line is benign by definition and triggers option 1, not option 3.

**Retired options (do not use):**

- The middle-dot `·` minimal-ack (v1.2.3 suggestion): operator pushback on 2026-05-28, reads as noise without carrying any information. Surface-N ack is strictly better (same order of cost, carries the counter).
- True zero-output (v1.2.4 aspirational claim "emit zero output"): empirically impossible because the Claude API requires non-empty assistant content. The technical minimum is one whitespace character. v1.2.5 corrects this assertion.

**Display behavior in Claude Code TUI** (clarification, important for cost intuition):

```
✻ Sautéed for 6m 34s · 1 monitor still running
⏺ Monitor event: "WarmPulse"
✻ Sautéed for 7s · 1 monitor still running
⏺ Monitor event: "WarmPulse"
```

The `✻ Sautéed/Baked/Crunched for Xs · 1 monitor still running` lines are **TUI-rendered locally by the Claude Code client** ; they cost ZERO tokens, they are NOT sent to the model, they are just a runtime activity indicator the operator sees in the terminal. The `Xs` counter is wall-clock since the last operator interaction (NOT inter-BEAT interval ; that interval is constant 240s by the shell sleep). The `1 monitor still running` annotation confirms the WarmPulse is alive.

The only line that costs tokens is `⏺ Monitor event: "WarmPulse"` (the task-notification wrapper + system-reminder header arriving in the agent context, ~70 tokens per tick on the minimal pattern). Everything else is local TUI rendering.

## Cost-effectiveness (break-even math)

WarmPulse polling is NOT free. Every event line emitted by the poll loop arrives as a conversation message that triggers an agent turn (even a short acknowledgment turn). The rule only earns its keep when total polling cost stays below the single re-prime cost it prevents.

**Cost model** (order-of-magnitude, billed-input tokens):

| Item | Tokens | Notes |
|---|---|---|
| Single re-prime on cache miss | 10000 to 50000 | Eager-load: CLAUDE.md + AGENTS.md + 6+ user-global rules + project memory + active plan-files ; size grows with session depth |
| Single event-turn (event line + agent ack) | 100 to 300 | Event line under 100 tokens + agent response 50 to 200 tokens ; minimal if filter is tight |
| Cache-hit input token | ~0.1x of non-cached | Anthropic cache-hit input is ~10x cheaper than non-cached ; only the events themselves pay full input rate |

**Break-even threshold**:

```
n_events_break_even  =  re_prime_tokens / event_turn_tokens
                     ~=  10000 to 50000 / 200
                     ~=  50 to 250 events
```

If the wait emits fewer than ~50 events end-to-end, WarmPulse is strictly cheaper than the re-prime it prevents. If it emits more than ~250 events, WarmPulse is more expensive than just letting the cache expire and paying one re-prime on resume.

**Typical wait profiles**:

| Pattern | Wait duration | Events emitted (filter strict) | Cost vs cold re-prime |
|---|---|---|---|
| PR bot pyramid converging | 10 to 40 min | 5 to 15 | Cheap (3x to 10x cheaper) |
| CI run watching | 3 to 15 min | 1 to 5 | Cheap (10x+ cheaper) |
| Parallel session cycle close | 20 to 90 min | 3 to 10 | Cheap (5x to 15x cheaper) |
| Deploy waiting for green | 5 to 30 min | 2 to 8 | Cheap |
| Operator AFK with no external trigger | unbounded | 0 (no state changes) | Indifferent ; polling emits nothing, cache stays warm via the silent ticks of the loop staying scheduled |

For the unbounded operator-AFK case where the watched resource has NO state changes (no PR, no CI, just waiting for the operator to come back), the cost is still minimal because the filter suppresses all output until something changes. The WarmPulse runs but emits zero events ; the agent receives zero turn-triggers ; the conversation stays scheduled and the cache stays warm because the runtime treats the persistent Monitor task as active session work.

**Rule of thumb (one-line summary)**: WarmPulse polling wins when (a) intervals are at or above 120 seconds, (b) the filter is state-change-only (no per-poll emission), AND (c) the wait duration is bounded under a couple of hours. Outside those bounds, recompute the break-even.

**Anti-patterns that flip the cost equation**:

- Polling interval under 60 seconds on a slow-changing resource (CI run that flips every 5 minutes ; PR convergence that takes 10+ minutes per round). Burns budget on non-events.
- Filter that emits on every poll regardless of state (e.g. `gh pr view ... | tee` without grep on a change marker). 30+ events per hour even with zero actual transitions.
- Multiple overlapping WarmPulses armed simultaneously on the same session. Cost multiplies ; filter coordination becomes a problem. Idempotency check (above) is the mitigation.
- Setting `timeout_ms` to a maximum (e.g. 3600000 = 1 hour) for a wait that should resolve in 5 minutes. The Monitor will run the full hour even when the work is done, emitting heartbeat events past the useful window.
- Using a WarmPulse for a wait that fits inside a single cache window (under 4 minutes). Just use a simple Bash poll ; Monitor's overhead is not justified.

**Audit before arming**: estimate the wait duration + the expected event count. If event count > 50, recompute. If it exceeds 250, switch to a different strategy (let cache expire, schedule a single resume via Bash run_in_background, OR exit the session and let the operator re-enter cold).

## Common AFK idle patterns

These are mostly **domain monitor** patterns ; the bottom row is the canonical WarmPulse pattern. For domain monitors, TERMINAL self-exit on the watched end-state is legitimate ; for the WarmPulse pattern, NONE.

| Pattern | What to poll | Interval | Terminal exit |
|---|---|---|---|
| Watching a PR for merge (domain monitor) | `gh pr view <N>` state + mergeable + reviews + checks | 120 s | state == MERGED or CLOSED |
| Watching a CI run (domain monitor) | `gh run view <ID>` conclusion | 60 s | conclusion != null |
| Waiting parallel session commit (domain monitor) | `git fetch && git log origin/main --oneline -1` | 90 s | new commit SHA detected |
| Watching cross-repo PR (domain monitor) | `gh pr view <N> --repo <owner>/<repo>` reviewDecision | 240 s | reviewDecision == APPROVED or CHANGES_REQUESTED |
| Tail a deploy log (domain monitor) | `tail -f deploy.log` with `grep --line-buffered` for failure / success markers | streaming | match for terminal marker |
| Wait for tmux pane output (domain monitor) | `tmux capture-pane -p -t <pane> \| tail -5` | 30 s | marker line appears |
| **WarmPulse** (proactive arming, heartbeat purpose) | benign probe: `gh pr list`, `git fetch && git log -1`, `ls ~/.claude/projects/.../memory/` | 240 s | NONE (only operator instruction or `timeout_ms`) |

## Composability with sibling rules

- `~/.claude/rules/goal-prompt-4000-char-limit.md` "Under 5 minutes (60s–270s): cache stays warm" section (which this rule extends to non-/goal idle states): the cache-window rationale is identical ; this rule documents the idle-interactive variant explicitly via the WarmPulse primitive.
- `~/.claude/rules/autonomous-mode-invariants.md` (zero pacing AskUserQuestion in /goal mode): this rule applies to interactive idle, NOT to /goal autonomous (which has its own pacing via ScheduleWakeup or runtime auto-resume).
- `~/.claude/rules/session-handoff-discipline.md` §2.1 "surface the /goal block inline at cycle close": composes naturally with WarmPulse trigger 2 ; a session that closes a cycle, surfaces the /goal block, then must wait for the operator to paste it elsewhere is exactly the AFK-idle case this rule covers.
- `~/.claude/rules/goal-subagent-orchestration.md`: subagent dispatch is a one-shot wait (single notification on completion) ; Bash run_in_background is the right tool there, not a WarmPulse. Use this rule only when the subagent is also expected to take longer than the cache TTL.

## Empirical anchors

**2026-05-21 rcr-plugin-factory v2.17.5+ closure period.** The operator stepped away while a parallel session ran the v2.17.5 PATCH cycle and then opened PR #111 (`feat/validate-manifest-deps-warn`, implementing AAR #110 absorption). The interactive session monitoring PR #111 needed to span 15+ minutes of bot pyramid review (CodeRabbit + Codex + Gemini + Copilot + Kilo). Without WarmPulse polling, the session would have paid 2 to 3 full re-primes over the wait period (3 cache misses x 5-10k tokens = 15-30k re-priming tokens, plus latency).

The mitigation: arm a `Monitor` watching `gh pr view 111` state + mergeable + reviews + checks, polling every 120 seconds (well under the 270s ceiling), filtering to emit only state changes. The first INIT event landed in seconds, subsequent NEW_REVIEW + CHECKS_CHANGE events arrived as bots converged, and the loop exits TERMINAL on MERGED. The cache stayed warm across the entire wait. Operator asked: "y a-t-il un moyen de faire un monitoring actif sous les 5 minutes pour éviter de perdre le contexte en cache et ne pas repayer la remise en cache?" Codified into v1.0.0 (then named `cache-warm-during-idle.md`) the same hour.

**2026-05-23 rcr-core-dev post-v2.1.0 true-zero closure session.** Operator requested a 240s WarmPulse right after the agent assembled a `/goal` block destined for a later session. The agent armed the WarmPulse correctly (`gh pr list` poll target, 240s interval, state-change filter). On INIT the WarmPulse surfaced `open=0` because PR #78 and PR #80 had been merged minutes earlier ; the agent then unilaterally called `TaskStop` on it with the reasoning "true-zero PR reached, monitor without added value". This was a doctrine violation: the WarmPulse's purpose was cache-warm heartbeat, NOT PR convergence tracking ; the `gh pr list` probe was incidental. The operator flagged the violation immediately ("tu n'est pas autorisé a stopper toi meme ce type de monitor demandé par moi pour maintenir cache warm") and directed (a) rearm with identical parameters minus the TERMINAL self-exit, (b) codify the maintain invariant + proactive activation triggers into the rule. v1.1.0 was the codification (maintain discipline + proactive triggers + idempotency check).

**2026-05-28 rename + concept formalization.** Same session, operator directed promoting the concept name from the descriptive "cache-warm" to the named primitive "WarmPulse" across rule name, contents, and operator-facing announcements. The rationale: cache-warm is a property (the prompt cache being kept warm) ; WarmPulse is the artefact-and-discipline that produces that property. The two are not synonyms ; cache-warm describes the effect, WarmPulse names the cause. Separating them in vocabulary makes the maintain rule sharper (one cannot "stop a cache-warm" but one CAN "stop a WarmPulse" only via authorised operator instruction). The rename is v1.2.0 ; the rule moves from `cache-warm-during-idle.md` to `warmpulse.md` ; the announcement format compresses from `Monitor armed (task <id>, 240s/1h, cache-warm heartbeat)` to `WarmPulse armed (task <id>, 240s/1h)`. Sibling distinction codified the same day: WarmPulse (heartbeat purpose, no TERMINAL self-exit) vs domain monitor (watch-for-end purpose, TERMINAL self-exit on convergence legitimate).

**2026-05-28 minimal pattern + public empirical baseline.** Same session, operator surfaced an unpublished article `/Users/regis/Development/GitHub/Regis-RCR/rcr-plugin-factory-dev/docs/monitor/send-package/02-ARTICLE.md` ("WarmPulse: a 240-second heartbeat that survives Claude Code's 5-minute cache TTL") consolidating the canonical 6-liner pattern (`BEAT-${ITER}` heartbeat watching nothing but the clock) and the composable variant (`BEAT-${ITER}` + `CHG-${ITER}` on a single Monitor). The article documents empirical baseline across operator sessions 2026-04-28 to 2026-05-25: 45+ distinct sessions, 8+ project contexts, 8000+ heartbeat events emitted, ~600+ hours of wall-clock covered, highest-density session 3001 BEAT events over 200+ hours continuous. Theoretical cost-avoided figures: ~$1230 on Sonnet 4.5, ~$6150 on Opus 4.x (upper-bound isolating idle-window re-prime cost). Payback ratio: ~11:1 on both models (12 acknowledgement turns per hour at $0.20 Sonnet / $1.00 Opus, vs avoided cache-write premium $2.25 Sonnet / $11.25 Opus per hour of idle on a 50k context). The article confirms the rule's break-even math (sweet spot interval 180-240s, wait window 10 min to a few hours) and surfaces a tier-agnostic result (Pro/Max/API key all benefit ; Max benefits even with the 1-hour cache option because the 2x write premium against weekly quota exceeds the heartbeat cost on routine multi-session work). v1.2.1 integrates the minimal pattern (§"Minimal WarmPulse pattern") and the empirical baseline above into the rule body ; the article remains the public-facing artefact.

**2026-05-28 default lifecycle correction.** Same session, operator challenged the `1h` in the v1.2.0 announcement format ("WarmPulse armed (task <id>, 240s/1h)") with the question "pourquoi 1h ?". The `1h` came from a `timeout_ms = 3600000, persistent = false` default codified in v1.1.0 with the rationale "timeout naturally terminates if operator never returns". This default was incoherent with three signals: (a) the public article empirics (highest-density session 3001 BEAT events over 200+ hours continuous ; overnight wait 8h ; multi-day operator AFK during meals/commutes/sleep), (b) the Monitor tool's hard `timeout_ms` cap at 3600000 (1 hour max ; longer waits REQUIRE `persistent: true`), (c) the article's own wording "Arm this as a persistent Monitor task". The corrected default is `persistent: true` (no timeout cap ; runs until operator `TaskStop` OR session end), aligned with the maintain rule (operator instruction is the only authorised stop). The announcement format becomes `WarmPulse armed (task <id>, BEAT every 240s, persistent until operator stop)`, with the ITER counter in every subsequent event line (BEAT-1, BEAT-2, ...) for operator-side cost auditing. The currently-armed WarmPulse in the session (timeout 1h, non-persistent, ~50min remaining) was swapped zero-gap (arm new persistent WarmPulse FIRST, verify INIT BEAT-1, THEN TaskStop the legacy one) per §"Maintain". v1.2.2 codifies the corrected default + format + when-to-deviate clause.

**2026-05-28 per-event anatomy + no-ack discipline + cross-repo annex.** Same session, operator asked to estimate the per-event impact on context window and whether the ITER variation breaks the cache. The analysis: ~95 input tokens per tick (full task-notification wrapper + system-reminder header, not just the raw echo), ITER + timestamp live in trailing suffix so cache prefix hash is invariant across ticks, cumulative context pressure significant on multi-day runs (200h = ~285k tokens no-ack, ~585k tokens with 100-token ack). The no-ack discipline (silent OR minimal `·` single middle-dot) is therefore load-bearing on long WarmPulses ; verbose-ack collapses the break-even and saturates context. v1.2.3 codifies the per-event cost summary, the cache invariant explanation, the cumulative pressure table, and the no-ack discipline as a dedicated section. The full implementation detail (token breakdown, cost tables across all ack-disciplines, cache mechanics walkthrough, audit recipes, edge cases) lives in the cross-repo annex `~/Development/GitHub/Regis-RCR/rcr-plugin-factory-dev/docs/monitor/send-package/04-IMPLEMENTATION-ANNEX.md` (operator-authorised cross-repo write, sibling to the canonical article 02-ARTICLE.md). The annex feeds future article revisions.

**2026-05-28 minimal format + strict-silent no-ack + TUI semantics clarification.** Same session (third hot-fix in one cycle), operator pushed back on three things observed in TUI scroll: (a) the `·` minimal-ack emitted by the agent reads as noise ("c'est pas conforme"), (b) the descriptive Monitor description `"WarmPulse (pure heartbeat, BEAT-N every 240s)"` and the verbose event line `12:50:29 BEAT-1 cache-warm tick (240s)` cost tokens unnecessarily and read as runtime narration the operator did not ask for, (c) the `Sautéed for Xs · 1 monitor still running` idle indicator visually suggests token consumption when it is actually local TUI rendering with zero token cost. v1.2.4 codifies three corrections: (1) Minimal pattern simplified to `echo "BEAT-${ITER}"` only (no timestamp prefix, no suffix), Monitor description literally `"WarmPulse"` (one word). Per-tick cost drops from ~95 to ~70 input tokens (~26% reduction, ~75k tokens saved over 200h ≈ $0.23 Sonnet / $1.15 Opus). (2) The `·` minimal-ack is RETIRED ; strict silent is the only allowed no-ack form. Narration-ack remains only for actionable events (ERR, CHG-). (3) New §"Display behavior in Claude Code TUI" sub-section explicitly states the `Sautéed/Baked/Crunched for Xs` indicator is TUI-rendered locally, ZERO tokens, not sent to the model, just operator-visible runtime activity annotation. The currently-armed WarmPulse was swapped zero-gap to the minimal pattern + `"WarmPulse"` description ; the v1.2.3-armed Monitor was stopped after the new one's BEAT-1 confirmed. Annex 04 Part 1 + Part 5 + command warmpulse.md aligned in lockstep.

**2026-05-28 surface-N ack + empirical CLEAN vs WRAPPED cost split.** Same session, operator observed two things: (a) "il manque l'iteration dans le WarmPulse" ; the TUI renders only the Monitor's static `<summary>` (`Monitor event: "WarmPulse"`), the `<event>` field content (the actual `BEAT-N` counter) is masked from operator view ; the v1.2.4 strict-silent ack (single-space) means N is observable only post-hoc via grep on the session jsonl, not live in the TUI scroll. (b) "verifier les asseertions sur l'ajout dans le contexte" : empirical recount via wc + char/token ratio measurement on the actual incoming task-notification, revealing two cost regimes the v1.2.4 figures did not distinguish: CLEAN form (event as standalone user turn, ~70 tokens, dominant in normal operation) vs WRAPPED form (event interrupting agent mid-turn with `[SYSTEM NOTIFICATION...]` header prepended, ~130 tokens). v1.2.5 codifies (1) surface-N ack as new default (agent emits `BEAT-N` extracted from event content, ~3 to 5 output tokens per tick = $0.18 Sonnet / $0.90 Opus cumulative over 200h, closes the TUI visibility gap), (2) single-space relegated to fallback when output cost dominates over operator-side visibility, (3) middle-dot `·` permanently retired, (4) the v1.2.4 "emit zero output" assertion corrected: the Claude API requires non-empty assistant content, so true zero is impossible ; the technical minimum is one whitespace character, (5) per-event cost table split into CLEAN ~70 vs WRAPPED ~130 with empirical char counts. Annex 04 Part 1 + Part 5 + command warmpulse.md aligned in lockstep.

**2026-05-28 empirical session inspection + tier-conditional ROI + auto-swap discipline.** Operator pushed deeper : "tiens tu compte dans tes calcul de rentabilite que la cache s'invalide progressivement en fenetre roulante ?" Empirical inspection of the highest-density session on disk (`-rcr-plugin-factory-dev/ec1cb12b-9ba7-4c82-9bb4-a209e0d5c354.jsonl`, 1980 BEAT events over ~132h) revealed three v1.2.5 modeling errors : (a) the v1.2.5 cost figure ($0.00027 per BEAT) ignored `cache_read_input_tokens` which dominates the actual cost (~$0.134 per BEAT on a 448k context, ~500x larger than the per-tick wrapper alone) ; (b) the implicit "tier-agnostic benefit" assumption is empirically wrong : on 1h-TTL tier (Max subscription historically, API 1h option) WarmPulse is a NET LOSS for typical scenarios because the 1h cache absorbs operator AFK windows naturally, while on 5min-TTL tier (Pro, API default) WarmPulse wins ~7-9x for contexts over 80k tokens ; (c) the 20-block lookback risk evaluated against the empirical data : every BEAT triggers `cache_creation_input_tokens > 0`, meaning the runtime writes cache on each BEAT turn ; the lookback never has more than 1 turn to look back, the 20-block window is respected by construction. Scenario A (each BEAT triggers cache write) is confirmed reality, NOT Scenario B (only real user interactions trigger writes). The 20-block lookback is NOT a WarmPulse risk. v1.2.6 codifies (1) empirical per-BEAT cost decomposition with `cache_read_input_tokens` ~448k dominating, (2) §"Tier-conditional ROI" section with operational table : ARM on 5min-tier when context > 80k, DO NOT ARM on 1h-tier by default (THIS RECOMMENDATION SUPERSEDED BY v1.2.7 below), (3) auto-swap discipline in the slash command (`/warmpulse` Step 1 Case C : detect stale pre-v1.2.5 format and auto-upgrade via zero-gap swap, replacing the prior v1.2.5 "abort on existing WarmPulse" behavior that left stale verbose-format WarmPulses running for entire session lifetime). Annex 04 Part 8 updated with empirical resolutions of Open Questions 1, 2, 5, 6, 7, 8. NEW annex `05-CACHE-MECHANICS-ANNEX.md` created documenting cache TTL + breakpoints + WarmPulse interaction comprehensively (operator-authorised cross-repo write, sibling to `02-ARTICLE.md` + `04-IMPLEMENTATION-ANNEX.md` in the `docs/monitor/send-package/` directory) ; intent : feed future article revisions and provide audit trail for ROI math.

**2026-05-28 three correction wave : model versions + Max TTL retirement + quota framing.** Operator flagged three errors in v1.2.6 same session : (a) model versions throughout the rule cite "Sonnet 4.5" and "Opus 4.x" which are obsolete labels ; current versions are Opus 4.7 (`claude-opus-4-7`), Sonnet 4.6 (`claude-sonnet-4-6`), Haiku 4.5 (`claude-haiku-4-5-20251001`) per the system prompt context. (b) the v1.2.6 claim that "Max subscription uses 1-hour TTL" is OBSOLETE : Anthropic retired the 1h-TTL Max cache several weeks before 2026-05-28 ; Max is now on the same 5-minute TTL as Pro. This is THE EMPIRICAL TRIGGER for the WarmPulse technique : the 1h-to-5min Max regression caused dramatic quota-burn during AFK on long-context sessions, motivating operator research into heartbeat-based cache continuity. (c) the v1.2.6 ROI analysis used dollars uniformly across all tiers, which is incorrect : Pro and Max are quota-bounded (weekly token allowance, 5h rolling reset for Max) NOT dollar-bounded ; only API key is dollar-billed per token. v1.2.7 codifies (1) current model versions throughout, (2) updated TTL table : Pro 5min, Max 5min (current), API default 5min, API 1h-opt-in 1h paid premium, (3) reframed ROI section : Pro/Max ROI expressed in quota-tokens saved per hour AFK (estimated ~85% reduction on 448k context, the difference between exhausting weekly quota in days vs surviving the week) ; API ROI expressed in dollar savings as before (~8x on 132h empirical session), (4) recommendation INVERTED for Max : v1.2.6 said "DO NOT ARM on Max" assuming 1h TTL, v1.2.7 says "ARM by default on Max" given current 5min TTL ; this matches Pro recommendation and the article's original tier-agnostic spirit (the article was written under the old Max 1h policy ; the underlying reasoning holds, just the recommended action inverts when Max TTL drops to 5min). NEW §"Why operators actually use WarmPulse" sub-section codifies the human side : context-switching between parallel sessions, drafting long prompts/specs externally, AFK for meals/commutes/sleep, defensive against forgotten handoffs to dead sessions. Annex 04 Part 8 + Annex 05 Part 7 + command warmpulse.md all need lockstep correction in v1.2.7. The empirical session data (1980 BEATs on 1h TTL) remains valuable as historical reference but does NOT reflect current Max behavior ; new empirical baselines should be measured on 5min Max post-transition.

∵ RCR Regis ∴

*v1.2.7 - 2026-05-28*
