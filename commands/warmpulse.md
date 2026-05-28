---
name: warmpulse
description: Arm a WarmPulse heartbeat Monitor with canonical defaults (persistent true, 240s interval, BEAT-N pattern). Refuses to double-arm if a WarmPulse is already running in the session.
license: Apache-2.0
allowed-tools: Monitor Bash
metadata:
  version: 1.0.0
---

# /warmpulse

Arms a WarmPulse heartbeat Monitor against the Anthropic 5-minute prompt-cache TTL.

## What it does

1. Idempotency check : if a Monitor with summary `WarmPulse` is already running in the session, refuse with a one-line note ("WarmPulse already armed ; task-id $X").
2. Invokes `Monitor` with the canonical defaults :
   - `command="ITER=0 ; while true ; do ITER=$((ITER+1)) ; echo \"BEAT-${ITER}\" ; sleep 240 ; done"`
   - `persistent=true`
   - `summary="WarmPulse"`
   - `description="WarmPulse heartbeat at 240s interval"`
3. Announces the task-id to the operator with a one-line confirmation.

## When NOT to invoke

- Pure read-only conversation (no wait state).
- One-shot completion wait under 5 minutes.
- When a WarmPulse is already armed in this session (idempotency).

## Cross-references

- Skill body and full doctrine extract : `skills/warmpulse/SKILL.md`.
- Canonical operator rule (full depth) : `references/canonical-rule.md`.

∵ Regis RCR ∴

*v1.0.0 - 2026-05-28*
