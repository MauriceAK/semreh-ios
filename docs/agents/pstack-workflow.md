# Semreh PStack workflow

All assigned workers start at [PStack for Semreh](pstack/README.md). The portable subset contains worker playbooks, orchestration responsibilities, current model roles, and upstream attribution. Workers do not need the Mac's local skill installation.

[Issue #15](https://github.com/MauriceAK/semreh-ios/issues/15) indexes shared work. Each active assignment has an issue with its owner, branch, allowed files, acceptance criteria, PR, and evidence. The coordinator assigns disjoint scopes. Codex Cloud is the default implementation provider; Muse follows the same contract.

Worker implementation and CI repair → trusted green macOS CI → registered PR → Sol-medium native verification → coordinator evidence review and integration. Failures return to the originating worker or an explicit replacement repair assignment. A new commit invalidates the old verdict.

The [verifier runbook](verifier-runbook.md) governs native checks. Green CI alone is not acceptance. A PR comment delivers feedback but does not prove an app-based worker resumed. TestFlight availability is checked separately after integration.
