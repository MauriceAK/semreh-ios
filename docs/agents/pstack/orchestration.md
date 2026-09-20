# Orchestration

Adapted from PStack's Orchestrate playbook. Ceremony scales with risk. The coordinator owns briefs, assignments, evidence review, and integration; workers own implementation.

1. Reconcile the issue with current source and evidence. Distinguish existing work awaiting verification from a new implementation task.
2. Supply a complete brief: goal, base commit/branch, allowed paths, context, dependencies, acceptance checks, verification commands, timebox, report format, and standing constraints.
3. Record ownership before dispatch. Run a rolling window of independent scopes. Separate cloud machines do not remove file conflicts.
4. Record provider/task identity and PR. Trusted green macOS CI admits the registered current commit to one native verifier. A label alone is not a task contract.
5. The verifier reviews the change and tests acceptance on the approved fixture. Require screenshots for appearance, recordings for motion/lifecycle, and measurements for performance when those claims apply.
6. Return failed criteria and evidence to the originating worker. If the provider cannot resume it, explicitly create a bounded repair assignment carrying prior context.
7. Passing evidence wakes the coordinator for diff and evidence review. Integrate only the verified commit. A changed commit requires renewed checks.
8. Update the issue and backlog index. Keep local execution receipts separate from the shared human-facing status.

Use the existing scheduler and callbacks. Busy-thread callbacks remain queued. Missing evidence, failed delivery, or a stopped scheduler is a visible blocker. Do not claim automatic provider resumption or reboot persistence without testing it.

Swarm and arena are optional tools for contested designs or uncertain causes, not a required review tree for small tasks. Keep one warm native verifier and one final integrator.

This documentation does not dispatch work. The next cloud and Muse assignments await Maurice's greenlight.
