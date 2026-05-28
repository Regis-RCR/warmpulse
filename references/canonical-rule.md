# WarmPulse: heartbeat against the prompt-cache TTL

> **Hard rule (activation):** when a session is in an idle-wait state (operator AFK, parallel session output, PR convergence, CI run, deploy, or any external trigger that may exceed ~5 minutes), the agent MUST arm a WarmPulse: a Monitor with intervals under 270 seconds whose stdout keeps the prompt cache warm. Going silent past the TTL costs the full re-prime on resume.
>
> **Hard rule (maintain):** once armed, the agent MUST NOT stop the WarmPulse. It runs until `timeout_ms` OR explicit operator instruction. No other condition authorises `TaskStop`.

## Vocabulary

- **WarmPulse**: a Monitor task whose primary purpose is to emit periodic heartbeat events keeping the Anthropic prompt cache warm. Poll target is incidental; heartbeat is load-bearing.
- **Domain monitor**: a Monitor whose primary purpose is tracking domain state. TERMINAL self-exit on convergence is legitimate for domain monitors, NOT for WarmPulses.
- **Prompt cache**: Anthropic 5-minute TTL cache holding eager-loaded context (CLAUDE.md, rules, project memory). Cache miss costs 10k to 50k re-prime tokens.
- **Heartbeat**: any stdout line emitted by the poll loop. Each line resets the TTL clock.

## Invariant

Prompt cache TTL: **5 minutes**. After that interval without activity, the cache expires and the next turn re-primes the full context at base token rate.

## ARM triggers

Arm a WarmPulse in any of:

- **Operator AFK**: stepped away or "I'll come back later" with open question or pending decision.
- **Parallel session**: another session running a cycle whose result the current session needs.
- **External job**: CI run, deploy, background script, remote queue job.
- **PR convergence**: bot pyramid reviewing, merge gate waiting for approvals or CI green.
- **Cron trigger**: anything on a wall-clock schedule outside the agent's control.

## SKIP triggers

- **Pure read-only response**: question answered, turn ends, no wait state.
- **One-shot completion wait**: single notification on a finite job (use `Bash run_in_background` + `until` loop instead).
- **Sub-5-minute work**: expected wait reliably under 4 minutes.

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

**Authorised stop**: explicit operator instruction ("stop the WarmPulse", "kill task `<id>`"). Only.

**Zero-gap swap**: arm replacement FIRST, verify INIT, then stop old WarmPulse.

## Proactive activation

After idempotency check (verify no WarmPulse already running in session):

1. End of `/goal` block assembly destined for a later session.
2. End of "surface in final message" per `session-handoff-discipline.md` §2.1.
3. After AskUserQuestion when the answer is plausibly >5 min away.

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

## Surface-N ack

Default: emit `BEAT-N` from the incoming event. ~3 to 5 output tokens per tick. Fallback (200h+ unattended): single space. Narration only for ERR or CHG- events.

## Filter discipline

Emit only on state change. Use `grep --line-buffered` in pipes. Add `ERR` on transient failure. No TERMINAL self-exit for WarmPulses.

## Common AFK patterns

| Pattern | Interval | Terminal exit |
|---|---|---|
| PR merge watch | 120 s | state == MERGED |
| CI run watch | 60 s | conclusion != null |
| Parallel session commit | 90 s | new SHA |
| **WarmPulse** | 240 s | **NONE** |

## Cross-references

- ROI analysis, cost math, break-even: `send-package/05-CACHE-MECHANICS-ANNEX.md` + `04-IMPLEMENTATION-ANNEX.md`
- Full procedure, composable variant, filter examples: `Skill(warmpulse)` or `skills/warmpulse/SKILL.md`
- Monitor invocation command: `/warmpulse` or `commands/warmpulse.md`
- Sibling rules: `goal-prompt-4000-char-limit.md`, `autonomous-mode-invariants.md`, `session-handoff-discipline.md §2.1`, `goal-subagent-orchestration.md`
- Codification history (v1.0.0 through v1.3.0): `doctrine-snapshots/warmpulse-empirical-anchors.md`

∵ RCR Regis ∴

*v2.0.0 - 2026-05-28*
