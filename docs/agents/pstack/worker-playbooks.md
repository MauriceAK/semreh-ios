# Worker playbooks

Adapted from Poteto Mode's Bug fix, Refactoring, Perf issue, and Opening a PR playbooks. Feature guidance is the Semreh task contract.

## Common contract

Confirm the assigned issue, base commit, branch, allowed paths, dependencies, acceptance checks, and timebox before editing. Preserve unrelated edits and personal data. Never use personal Hermes services, credentials, or Tailscale routes. Missing context is a blocker to report, not permission to invent behavior.

Keep the smallest change that meets the task. Test behavior through real callers. Do not weaken assertions or count skipped checks as passes. Workers never merge or approve their own native acceptance.

## Bug fix

1. Obtain a reproducible failing case and exact environment. For native-only failures, use a verifier reproduction or request one through the coordinator. Never fabricate simulator evidence from cloud execution.
2. Trace the mechanism with focused tests or instrumentation. Remove changes motivated by disproven hypotheses.
3. Implement the bounded correction and rerun the regression. Preserve failing-then-passing evidence where practical.
4. The native verifier repeats the original interaction on the candidate. Report cause, fix, commands, evidence, and limitations.

## Refactoring

1. Pin existing behavior through characterization tests, equivalence comparison, or a recorded baseline.
2. Name the simpler target structure and move code in small behavior-preserving steps.
3. Preserve file-local private access. Justify every widening required across files. Check callers, resource references, and project membership.
4. Prove equivalence with relevant tests and native checks. Compilation alone is insufficient. Keep newly discovered feature work separate.

## Performance

1. Capture a baseline with workload size, rich Markdown/code/tools/media, device/runtime, and build configuration.
2. Derive a causal hypothesis from the trace and make a bounded correction.
3. Compare the same workload before and after while retaining correctness and lifecycle checks.
4. Report metrics, units, artifacts, and limitations. Simulator callback timing, test waits, and recordings alone do not establish physical-device FPS or zero lag.

## Feature

Implement only approved behavior. Verify Hermes contracts against approved sources and fixtures before changing requests or models. UI design routes to Astra. New ideas return to the backlog; independent native verification still applies.

## PR and CI ownership

Use the assigned branch and a small PR linked to the issue. Review the diff for accidental edits, scope expansion, leaked data, and unnecessary comments. Describe the concrete problem, resulting behavior, checks, and limitations.

Run available focused checks. The repository's macOS PR CI provides native compilation/tests. Own CI failures until green or report a concrete blocker. Green CI admits a registered current commit to verification; it is not acceptance.

On a failed verdict, repair the named criterion on the assigned branch. Retain evidence and push a new commit through CI and fresh verification. A PR comment delivers feedback; it does not prove a stopped worker resumed. Use the provider's supported continuation or a coordinator-issued replacement assignment.

Return PASS, ISSUES, or BLOCKED with issue/PR, branch/head commit, changed scope, actual commands, evidence, and unverified criteria. Worker PASS means its checks passed, not permission to merge.
