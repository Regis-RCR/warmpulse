# warmpulse

Heartbeat Monitor pattern against the Claude Code prompt-cache TTL. The main interactive thread holds a **~1-hour** effective TTL in the measured corpus ; the 5-minute default applies to the subagent/sidechain tier and the API default, not the main thread. This pattern keeps the cache warm across long idle waits by emitting one stdout line every 240 seconds, buying resume-latency readiness against the ~1-hour TTL (the dollar payoff lands only on AFKs approaching ~1 hour with large context).

## 30-second copy-paste (no Claude Code required)

Run this in a terminal next to your active Claude Code session :

```bash
#!/usr/bin/env bash
set -uo pipefail
ITER=0
while true ; do
    ITER=$((ITER+1))
    echo "BEAT-${ITER}"
    sleep 240
done
```

Or `curl` + run :

```bash
curl -sSL https://raw.githubusercontent.com/Regis-RCR/warmpulse/main/scripts/warmpulse.sh | bash
```

Each `BEAT-N` line counts as session activity for the Claude Code runtime ; the prompt cache stays warm.

## Claude Code plugin install (for /warmpulse + opt-in hook)

```bash
/plugin install github:Regis-RCR/warmpulse
```

After install :

- `/warmpulse` arms a WarmPulse with canonical defaults (idempotency-checked).
- Opt-in auto-arm : create `~/.claude/warmpulse.config.json` with `{"auto_arm": true}` to make the SessionStart hook suggest arming on each new session.

## What this does

Summary :

- The Anthropic prompt cache is two-tier in the measured corpus : the main interactive thread holds a ~1-hour effective TTL, the subagent/sidechain tier ~5 minutes. WarmPulse runs on the main thread.
- A silent idle wait past the main TTL (~1 hour) costs a full re-prime on the next interaction (10k to 50k tokens depending on context).
- A 240-second heartbeat Monitor emits one stdout line per tick ; each line counts as session activity and resets the TTL clock, so the prefix stays warm across the wait.
- Honest economics (v0.8.0 forensic close-out, 286886 turns) : per-tick cost is ~$0.13 (dominated by the `cache_read` of the full prefix, not the ~200-token emit). On the pay-as-you-go dollar axis the heartbeat **net-costs**, because 96% of beats bridge sub-5-minute gaps the 1-hour cache holds for free.
- Where the value lives : resume-latency, subscription quota (`cache_read` is ~10% of base), and zero marginal CASH on a subscription. Arm for those on long AFKs, not for a dollar saving.

Full doctrine and the honest cost counterfactual in [`references/canonical-rule.md`](references/canonical-rule.md).

## Article

Companion Medium article : [link placeholder once published on AI Software Engineer publication]

## License

Apache-2.0 ; see [LICENSE](LICENSE). Copyright 2025-2026 Regis-RCR.

Author : Regis. AI-assisted translation on prose ; technique, data, and framing are operator-original.
