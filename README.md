# warmpulse

Heartbeat Monitor pattern against the Claude Code 5-minute prompt-cache TTL. Anthropic cut the default prompt-cache TTL from 1 hour to 5 minutes in March 2026 ; this pattern survives the change by emitting one stdout line every 240 seconds, keeping the cache hit-priced across idle waits.

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

5-line summary :

- Anthropic prompt cache has a 5-minute TTL since March 2026.
- Silent idle waits past 5 minutes cost a full re-prime on next interaction (10k to 50k tokens depending on context).
- A 240-second heartbeat Monitor emits one stdout line per tick ; each line counts as session activity.
- The cache stays hit-priced across waits up to several hours.
- Empirical baseline : 45+ distinct sessions, 8000+ BEAT events, ~$0.18 / 200h on Sonnet 4.5.

Full doctrine and empirical anchors in [`references/canonical-rule.md`](references/canonical-rule.md).

## Article

Companion Medium article : [link placeholder once published on AI Software Engineer publication]

## License

Apache-2.0 ; see [LICENSE](LICENSE). Copyright 2025-2026 Regis-RCR.

Author : Regis. AI-assisted translation on prose ; technique, data, and framing are operator-original.
