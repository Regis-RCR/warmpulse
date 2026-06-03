#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 Regis-RCR
# ∵ Regis RCR ∴
#
# WarmPulse : heartbeat against the Anthropic prompt-cache TTL.
# The main interactive thread holds a ~1-hour effective TTL (the 5-minute
# default is the subagent/sidechain tier). The BEAT interval is adaptive:
# pass it in seconds; default 3300 (55 min, one tick just under the ~1h
# main TTL). Each BEAT-N stdout line counts as session activity for the
# Claude Code runtime, keeping the prompt cache warm across idle waits.
#
# Usage : bash warmpulse.sh [INTERVAL_SECONDS]   # default 3300
#         bash warmpulse.sh 240 &                # tight cadence for a short window
# Stop  : kill the background job (e.g. `jobs -l` then `kill %1`).

set -uo pipefail
INTERVAL="${1:-3300}"
ITER=0
while true ; do
    ITER=$((ITER+1))
    echo "BEAT-${ITER}"
    sleep "$INTERVAL"
done
