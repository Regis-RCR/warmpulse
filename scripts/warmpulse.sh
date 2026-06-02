#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 Regis-RCR
# ∵ Regis RCR ∴
#
# WarmPulse : heartbeat against the Anthropic prompt-cache TTL.
# The main interactive thread holds a ~1-hour effective TTL (the 5-minute
# default is the subagent/sidechain tier). Emits one BEAT-N stdout line
# every 240 seconds. Each line counts as session activity for the Claude
# Code runtime, keeping the prompt cache warm across idle waits.
#
# Usage : bash warmpulse.sh &
# Stop  : kill the background job (e.g. `jobs -l` then `kill %1`).

set -uo pipefail
ITER=0
while true ; do
    ITER=$((ITER+1))
    echo "BEAT-${ITER}"
    sleep 240
done
