# Semreh P-Stack Workflow

Adapted from Lauren Tan's pstack (poteto-mode playbooks) for the
Astra / Luna / Solo / verifier-lane setup.

## Roles (pstack setup-pstack: map models to roles)

- **Astra (orchestrator, this chat):** breaks symptoms into task specs with
  measurable acceptance criteria, fans out implementers, watches CI, runs
  the verify queue, does the final second pass, merges. Only Astra/Maurice
  merge — pstack babysit rule.
- **Luna (implementers, parallel, cloud):** Jules (3.6 Flash = mechanical,
  3.1 Pro = harder), Codex cloud, or Muse. One branch per task.
- **Solo (judgment):** verifier lane pilot, escalation implementer for
  retried/hard tasks, adversarial reviewer (pstack interrogate).
- **Verifier lane (Mac mini, serial):** follows verifier-runbook.md.
  Never edits code.

## Decisions (locked 2026-09-19)

- **Backlog = GitHub issues.** Labeled (`ready-for-agent`, priority). Jules
  can start tasks straight from issues; Codex and Muse pull specs from them.
- **pstack: yes.** The playbooks above are the implementation. Skills live at
  `~/workspace/skills/pstack`; orchestrator embeds the relevant playbook in
  each handoff (no plugin install needed for Jules/Codex).
- **Commit attribution:** Jules/Codex commit as their bot identities. Muse
  pushes use author `Astra` so agent work is distinguishable in history.
  (Token owner remains Maurice; author string is the signal.)
- **Model delegation:** orchestrator assigns per task. Mechanical/parallel →
  Jules 3.6 Flash (or Luna). Hard/retry → Jules 3.1 Pro, Codex, or Solo.
  Judgment/verify → Solo. Maurice fires Jules/Codex tasks from their UIs
  with the orchestrator's spec (or points Jules at a labeled issue).
- **Verifier bounce:** `needs-fix` label + evidence comment on the PR →
  same implementer, evidence attached → fix → CI → re-queue. Verifier
  never edits code.
- **Integrator:** only Astra (second pass: diff + acceptance + evidence) or
  Maurice merges. Implementers never merge.
- **Evidence location:** PR comments (screen recordings, screenshots, logs).
  The PR is the record; linked from the issue when closed.

## The loop

1. Maurice → Astra: symptom. Astra investigates (`how`), writes a task
   spec (symptom + repro + suspected area + constraints + acceptance
   criteria), NOT the solution.
2. Astra → implementer: direct handoff, no per-task GitHub issue. The PR
   description is the record (pstack show-me-your-work): what changed,
   why, acceptance evidence, test notes. Issues are backlog only.
3. Implementer opens PR, then **babysits** it: watches CI, reads failures,
   fixes, pushes until green. Same agent owns the red loop. Verifier
   never sees red PRs.
4. CI green → Astra labels `needs-verify` → serial verify queue on the mini.
5. Verifier drives old-vs-new on the simulator, posts video/logs/
   screenshots. All PASS → `verified`. Any FAIL → `needs-fix` + evidence
   comment → back to the SAME implementer with evidence attached.
   Fix → CI → re-queue.
6. `verified` → Astra second pass: diff + acceptance criteria + verifier
   evidence → merge → TestFlight internal build auto-fires.

## Labels

`ready-for-agent` (backlog, unclaimed) · `needs-verify` (CI green, queued)
· `verifying` (lane busy) · `verified` (evidence posted, mergeable)
· `needs-fix` (bounced to implementer)

## Implementer handoff must include

Goal, scope, exact files/areas, acceptance criteria, how to verify,
"babysit your PR until CI is green; never merge; evidence in the PR
description." Reports end PASS / ISSUES / BLOCKED.
