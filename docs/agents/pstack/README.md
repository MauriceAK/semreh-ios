# PStack for Semreh

Portable adaptations of Lauren Tan's [PStack Poteto Mode](https://github.com/cursor/plugins/tree/main/pstack), inspected on 2026-09-19. This is a focused subset, not the full upstream suite or a Cursor plugin. See [LICENSE](LICENSE).

Assigned workers read repository AGENTS.md, their task issue, and [worker playbooks](worker-playbooks.md). Coordinators read [orchestration](orchestration.md). Native verification follows the [verifier runbook](../verifier-runbook.md). Cloud briefs include standing constraints because local coordinator files are inaccessible there.

## Workspace adaptation

Use supported provider tools instead of Cursor Task, /loop, and agent types. Use ordinary Git branches and GitHub PRs without Graphite, rebase, reset, or force-push. Use approved native iOS fixtures instead of browser control skills. Missing tools are reported explicitly.

Semreh assigns workers CI repair ownership, adapting upstream's separate babysit phase. If a worker cannot remain active, report its task identity and continuation limitation. The coordinator handles the next repair assignment. No worker or verifier merges.

Luna handles bounded implementation; Terra or Sol handles hard repairs; Astra handles user-facing UI design; Sol medium performs native verification. Record the actual provider model. A preferred model name does not establish provider availability. Provider choice does not change acceptance.

Apply PStack's Laziness Protocol through the smallest evidence-backed change. Apply Separate Before Serializing Shared State through one writer per branch and assigned responsibility. Use swarm or arena only when competing hypotheses or designs justify the added work.

## Shared tracking

[Issue #15](https://github.com/MauriceAK/semreh-ios/issues/15) indexes the backlog. Each active assignment links its issue, owner, base commit, branch, file scope, acceptance criteria, PR, and current verdict. The coordinator owns assignment changes. Local PStack records retain receipts and execution state.

The model roles above supersede historical model fields in the backlog seed. Muse intake reserves U06/U08/U09/U10/U11, subject to existing dependencies. Reservations do not launch workers. The next cloud and Muse assignments await Maurice's greenlight.
