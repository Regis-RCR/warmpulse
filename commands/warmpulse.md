---
name: warmpulse
description: Arm a WarmPulse heartbeat Monitor with canonical defaults (persistent true, 240s interval, BEAT-N pattern). Refuses to double-arm if a WarmPulse is already running in the session.
license: Apache-2.0
allowed-tools: Monitor Bash
metadata:
  version: 1.2.0
---

# /warmpulse

Arms a WarmPulse heartbeat Monitor against the Anthropic prompt-cache TTL (main interactive thread ~1 hour in the measured corpus ; subagent tier ~5 minutes ; WarmPulse runs on the main thread).

## What it does

1. Idempotency check: if a Monitor with `summary="WarmPulse"` is already running, refuse with "WarmPulse already armed (task `<id>`)."
2. Invoke `Monitor` with canonical defaults:
   - `command="ITER=0 ; while true ; do ITER=$((ITER+1)) ; echo \"BEAT-${ITER}\" ; sleep 240 ; done"`
   - `persistent=true`
   - `summary="WarmPulse"`
   - `description="WarmPulse heartbeat at 240s interval"`
3. Announce: `WarmPulse armed (task <id>, BEAT every 240s, persistent until operator stop).`

## When NOT to invoke

- Pure read-only conversation (no wait state).
- One-shot completion wait (use `Bash run_in_background` + `until` instead).
- Short, dollar-neutral wait the ~1-hour main cache already holds (no re-prime at stake).
- WarmPulse already armed in this session (idempotency).

## Cross-references

- Full doctrine and decision rules: `skills/warmpulse/SKILL.md`
- Canonical operator rule (full depth): `references/canonical-rule.md`

∵ Regis RCR ∴

*v1.2.0 - 2026-05-30*
