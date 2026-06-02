# Changelog

All notable changes to the `warmpulse` skill are documented here.
Format inspired by Keep a Changelog ; SemVer applied.

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
