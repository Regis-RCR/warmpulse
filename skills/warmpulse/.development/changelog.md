# Changelog

All notable changes to the `warmpulse` skill are documented here.
Format inspired by Keep a Changelog ; SemVer applied.

## [1.3.0] - 2026-06-03

Adaptive BEAT interval. The cadence now scales to the requested wait window
instead of a fixed 240s. `INTERVAL = clamp(W - clamp(W/12, 60s, 300s), 60s,
3300s)` where `W` is the named window in seconds ; empty argument -> persistent
at the 3300s default. The 3300s cap sits just under the proven ~1h main-thread
TTL (a BEAT every <=55 min resets the 1h cache, so one cadence holds any wait
length) ; below 1h the cadence matches the named window (5 min -> 240s, 30 min
-> 1650s). The legacy fixed 240s default over-ticked ~15x against the measured
~1h main TTL (v0.8.0 forensic close-out). `scripts/warmpulse.sh` now takes an
optional `[INTERVAL_SECONDS]` argument (default 3300). The 270s hard ceiling is
retired in favor of the 3300s cap. Mechanics otherwise unchanged
(no-unilateral-TaskStop, surface-N ack, idempotency).

## [1.2.0] - 2026-05-30

TTL premise corrected to the measured two-tier model from the v0.8.0 forensic
close-out (286886 turns, 3 nodes) : the main interactive thread holds a ~1-hour
effective TTL, the subagent/sidechain tier ~5 minutes ; WarmPulse runs on the
main thread. Reframed the activation, decision rules, and tool-selection
rationale around the ~1-hour main TTL. Replaced the optimistic ROI framing with
the honest counterfactual (net-cost on the dollar axis ; value lives on
resume-latency, subscription quota, and zero marginal cash on a subscription).
Mechanics unchanged (no-unilateral-TaskStop, surface-N ack, 270s ceiling).

## [1.0.0] - 2026-05-28

Initial public release. Compact doctrine extract from operator canonical
rule v1.2.7 (`~/.claude/rules/warmpulse.md`, snapshot in
`references/canonical-rule.md`). Covers invariant, when-fires criteria,
skip cases, minimal pattern, tool invocation, surface-N ack discipline,
and maintain rule. Cross-references the canonical rule for full
implementation depth.

∵ Regis RCR ∴
