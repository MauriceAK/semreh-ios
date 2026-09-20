# Batch Intake Playbook (Semreh)

Run this whenever Maurice says "batch:" followed by bugs. Works for any
orchestrator: Muse (this chat), Hermes, or Codex CLI. The orchestrator
scopes; implementers execute. No implementer starts from a raw bug report.

## Phase 1 — Collect (one message)

Maurice provides: text descriptions + screenshots/videos, one bug per item.
If a bug is ambiguous, ask ONE round of clarifying questions for the whole
batch — then proceed with best interpretation and mark assumptions in the
spec. Never stall the batch on one unclear item; park it and continue.

## Phase 2 — Scope (per bug)

For each bug, check open issues for duplicates first (`gh issue list`).
Then write a task spec with ALL of:

- **Symptom:** what the user sees, in one line.
- **Repro:** steps, device/sim, plus attached media as evidence.
- **Suspected area:** file/subsystem pointer, not a diagnosis.
- **Constraints:** what must not change (e.g. pacing behavior, 60fps).
- **Acceptance criteria:** measurable, verifier-checkable
  (e.g. "p95 flush <8ms on 10k-char stream", "no hitch in 30s scroll
  recording"). No vague criteria — "smooth" is not a criterion.
- **Assumptions:** anything guessed, flagged for the verifier.

Merge duplicates. Split bugs that touch unrelated areas into separate specs
(implementers work branches in parallel; overlapping files = conflicts).

## Phase 3 — Publish

- One GitHub issue per spec: title, body = the spec, labels
  `ready-for-agent` + priority. Media attached to the issue.
- If the batch is small (<3) and Maurice wants speed, skip issues: hand
  specs directly to implementers and let the PR description be the record.

## Phase 4 — Fan out

- Pick implementers per task (Flash = mechanical, Pro/Codex/Solo = hard).
- One branch per task. Non-overlapping file areas only.
- Handoff includes: the spec + "open a PR, babysit CI to green, never
  merge, evidence in the PR description."
- Jules: point at the labeled issue. Codex: paste the spec into a cloud
  task. Muse: spawn subagent with the spec.

## Phase 5 — Supervise

- Watch CI via `gh pr checks`. Green → label `needs-verify`.
- Verifier lane (watcher + runbook) takes it serially.
- `verified` → orchestrator second pass → merge. `needs-fix` → same
  implementer with evidence.
- Report to Maurice: per-task table (spec → implementer → PR → status).

## First-run rule

The first batch runs supervised: Maurice watches the scoping output and
corrects before fan-out. After one clean run, intake goes autonomous.
