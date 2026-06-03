---
name: warmpulse
description: Arm a WarmPulse heartbeat Monitor with an adaptive BEAT interval scaled to the requested wait window. Default 3300s (one tick just under the measured ~1h main-thread TTL); scales down on request (e.g. 5 minutes -> 240s). Refuses to double-arm if a WarmPulse is already running in the session.
license: Apache-2.0
allowed-tools: Monitor Bash
metadata:
  version: 1.3.0
---

# /warmpulse

Arms a WarmPulse heartbeat Monitor against the Anthropic prompt-cache TTL (main interactive thread ~1 hour in the measured corpus ; subagent tier ~5 minutes ; WarmPulse runs on the main thread).

The BEAT interval is **adaptive**: it scales to the wait window named in `$ARGUMENTS`. Against the measured ~1h main TTL the default cadence is 3300s (55 min, one tick before the TTL closes), not the legacy 240s. A tighter window is honored when resume-latency on a short wait matters.

## Argument

`$ARGUMENTS` = the expected wait window in natural form (`5 minutes`, `30m`, `1h`, `55 minutes`, `2h`). Bare number = minutes. Empty = open-ended (persistent, default cadence).

## Interval formula

```
W        = requested window in seconds  (empty -> open-ended)
margin   = clamp(W / 12, 60s, 300s)     # ~8%, min 1 min, max 5 min
INTERVAL = clamp(W - margin, 60s, 3300s) # one BEAT before the window closes
```

The 3300s cap sits just under the proven ~1h main-thread TTL: a BEAT every <=55 min resets the 1h cache, so a single cadence keeps the prefix warm for any wait length. Below 1h, the cadence matches the named window so the operator sees the rhythm they asked for, not a fixed 240s.

| `$ARGUMENTS` | Mode | BEAT interval |
|---|---|---|
| (empty) | persistent | 3300s |
| 5 minutes | timeout 300s | 240s |
| 10 minutes | timeout 600s | 540s |
| 30 minutes | timeout 1800s | 1650s |
| 55 minutes | timeout 3300s | 3025s |
| 1h | timeout 3600s | 3300s (cap) |
| 2h | timeout 7200s | 3300s (cap) |

## What it does

1. **Idempotency check**: if a Monitor with `summary="WarmPulse"` is already running, refuse with "WarmPulse already armed (task `<id>`)."

2. **Compute INTERVAL** (and timeout) from `$ARGUMENTS`. Deterministic helper:

   ```sh
   # POSIX sh: portable across bash and zsh (no BASH_REMATCH).
   A="$ARGUMENTS"
   low=$(printf '%s' "$A" | tr 'A-Z' 'a-z' | tr -d ' ')
   num=$(printf '%s' "$low" | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p')
   if [ -z "$num" ]; then
     echo "MODE=persistent INTERVAL=3300"
   else
     case "$low" in
       *h*) W=$((num*3600)) ;;   # hour / h
       *m*) W=$((num*60))   ;;   # minute / min / m
       *s*) W=$((num))      ;;   # second / sec / s
       *)   W=$((num*60))   ;;   # bare number = minutes
     esac
     M=$((W/12)); [ "$M" -lt 60 ] && M=60; [ "$M" -gt 300 ] && M=300
     I=$((W-M)); [ "$I" -gt 3300 ] && I=3300; [ "$I" -lt 60 ] && I=60
     echo "MODE=bounded INTERVAL=$I TIMEOUT_MS=$((W*1000))"
   fi
   ```

3. **Invoke Monitor** with the computed INTERVAL:
   - `command="ITER=0 ; while true ; do ITER=$((ITER+1)) ; echo \"BEAT-${ITER}\" ; sleep <INTERVAL> ; done"`
   - empty `$ARGUMENTS` -> `persistent=true` (no timeout)
   - non-empty `$ARGUMENTS` -> `persistent=false`, `timeout_ms=<TIMEOUT_MS>`
   - `summary="WarmPulse"`
   - `description="WarmPulse heartbeat at <INTERVAL>s interval"`

4. **Announce**: `WarmPulse armed (task <id>, BEAT every <INTERVAL>s, <persistent until operator stop | bounded ~<window>>).`

## When NOT to invoke

- Pure read-only conversation (no wait state).
- One-shot completion wait (use `Bash run_in_background` + `until` instead).
- Very short window (under ~2 min): the ~1h main cache holds it for free, no re-prime at stake.
- WarmPulse already armed in this session (idempotency).

## Cross-references

- Full doctrine and decision rules: `skills/warmpulse/SKILL.md`
- Canonical operator rule (full depth): `references/canonical-rule.md`

∵ Regis RCR ∴

*v1.3.0 - 2026-06-03*
