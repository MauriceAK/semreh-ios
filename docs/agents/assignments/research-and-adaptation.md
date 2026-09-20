# Research and adaptation

Inspected 2026-09-19. These sources correct the earlier report-only launch plan.

## Lauren's own account

[Lauren Tan's cloud-agent post](https://www.linkedin.com/posts/laurenelizabethtan_cloud-agents-and-cursor-harness-improvements-activity-7495972438262853632-bLQ5) describes PStack as her engineering/verification skills, Grok Bot routines as context gathering, and Full Autopilot as task ownership through shipping. Her PR volume is self-reported, not our performance target. The useful adoption is sustained task ownership and feedback.

[Her Maven workshop](https://maven.com/p/e23d9c/how-cursor-turned-ai-agents-into-better-engineers) lists verification skills and feature maps at 08:35, verification at cloud scale at 26:34, work/PR structure at 38:38, and strict CI at 41:00. The published page and chapter list were inspected; the complete video was not watched. The [MTS interview](https://www.youtube.com/watch?v=A63sedG-p5Q) was located, but video retrieval was throttled, so no claim here relies on having watched it.

[The first-party engineering guide](https://x.ai/bot/guides/grok-bot-for-engineering), written by Lingxi Li rather than Lauren, describes domain owners managing cloud agents, checking artifacts, returning feedback, and maintaining a shared progress database. It also explicitly describes private Mac workers for iOS Simulator use. This supports Semreh's existing local native verifier boundary.

## PStack source

[Orchestrate](https://github.com/cursor/plugins/blob/main/pstack/skills/poteto-mode/playbooks/orchestrate.md) supplies program ownership, complete briefs, rolling dispatch, and a verification ledger. [Autopilot-full](https://github.com/cursor/plugins/blob/main/pstack/skills/poteto-mode/playbooks/autopilot-full.md) gives each PR a lifecycle owner and requires independent verification of the merge candidate. The local full playbooks and Shipping were read, not only search summaries.

Semreh combines lifecycle ownership with the user's explicit coordinator-only integration policy. The native verifier stays serial because one simulator is shared. Workers can investigate, repair, push, handle CI, and process returned findings within their assignment; they do not need another user approval after every report. No Cursor-specific Task type, /goal, /loop, Graphite, or auto-merge behavior is assumed to exist on another provider.

## Concrete correction

The earlier eleven read-only report tasks overlapped and stopped before implementation. C01/C02/C03 and M01/M02 now own bounded engineering outcomes and explicit disjoint source scopes. Existing unit issues remain acceptance checklists under those owners. M03/M04/M05 release when real dependencies clear. Contract/authority questions remain separate because code cannot resolve missing access authorization.

Laziness Protocol removed redundant investigation dispatches. Separate Before Serializing Shared State gave each active owner explicit files and excluded shared project/network surfaces. CI failures and failed native verdicts stay in the same task lifecycle. Screenshots, recordings, and measurements are required according to the user-visible claim, with skipped coverage explicit.

Cloud provider continuation and requested model support must still be checked at launch. A local scheduler test does not establish a provider's ability to resume an ended task. The coordinator supplies a bounded replacement assignment when needed.
