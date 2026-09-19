# Prepared parallel batch

Prepared 2026-09-19. No workers launched. Maurice's greenlight is pending.

## Ready investigations

| Lane | Issue | Model | Scope |
| --- | --- | --- | --- |
| Codex C01 | [#17](https://github.com/MauriceAK/semreh-ios/issues/17) | Terra | Transcript recovery, paging, navigation and send causality |
| Codex C02 | [#18](https://github.com/MauriceAK/semreh-ios/issues/18) | Luna | Thinking/tool chronology |
| Codex C03 | [#19](https://github.com/MauriceAK/semreh-ios/issues/19) | Luna | Performance measurement and fixture coverage |
| Muse M01 | [#20](https://github.com/MauriceAK/semreh-ios/issues/20) | Record provider model | Settings |
| Muse M02 | [#21](https://github.com/MauriceAK/semreh-ios/issues/21) | Record provider model | Onboarding routes |

These five may run concurrently because they read source and publish separate issue reports. They do not edit shared product files. Their deliverable is concrete repair candidates, not a claim the app passes acceptance. No arbitrary worker cap is imposed; these are the ready work products justified by the present backlog.

## Reserved Muse work

- M03 / [#22](https://github.com/MauriceAK/semreh-ios/issues/22): session previews; wait for PR #10/#14 disposition.
- M04 / [#23](https://github.com/MauriceAK/semreh-ios/issues/23): bird/header/icons; wait for shared scope and visual reference handoff.
- M05 / [#24](https://github.com/MauriceAK/semreh-ios/issues/24): Bots/Tasks reentry; wait for PR #12/#13 disposition.

Muse may use subagents for M01/M02 only after greenlight. The reservations are visible ownership, not five running jobs. No new product features were added to fill worker slots.

## Native verification and implementation gates

Issue #4 remains the first native task: rich persisted conversations, initial entry, repeated Back/chat switching, send/stop, background return, and actual prepend anchor preservation. Before running, the coordinator pins the then-current integrated product commit and disposable fixture in a trusted verifier brief. The old seed SHA is historical, not an instruction to test stale source. One warm simulator is shared serially. Cloud findings inform reproduction; they do not replace it.

Confirmed failures become implementation briefs with exclusive writable paths, original reproduction, acceptance checks, and provider task identity. When no same-task repair API exists, create an explicit correction task. Refill independent implementation slots as scopes become ready. Maintain actual model and task identity rather than assuming the provider honors the desired model.

## Reconciliation of all 24 seed units

| Units | Disposition |
| --- | --- |
| U00 | Completed through PR #7; no redispatch |
| U01 | Native issue #4; cloud C01 investigation supports it |
| U02/U04/U05/U07/U20 | Native acceptance follows U01; C01 identifies source/test gaps |
| U03/U22 | C02 investigation; native chronology acceptance follows U01/U03 |
| U06/U08/U09/U10/U11 | Muse M03/M04/M01/M05/M02 respectively |
| U12 | Blocked on approved multi-profile fixture and contracts |
| U13 | C03 inventories committed probe; coordinator preserves/reconciles local dirty probe before any implementation |
| U14/U16/U17 | Physical-device work; U14/U17 share one measurement session where possible |
| U15 | Observed repair/reverification/callback proof exists; provider continuation and reboot persistence are separate unproven claims |
| U18/U19 | Measurement diagnosis follows physical baseline; no speculative optimization |
| U21 | Native motion acceptance follows send correctness; C03 prepares measurement gaps |
| U23 | Relay/team/fixture decision precedes implementation |

The source worktree has substantial uncommitted changes unavailable in cloud. Workers inspect the pinned committed baseline; the coordinator must reconcile relevant local changes before assigning any repair to avoid overwriting or duplicating them.

## Research and choices

[Upstream Orchestrate](https://github.com/cursor/plugins/blob/main/pstack/skills/poteto-mode/playbooks/orchestrate.md) assigns briefs and queue management to one coordinator, favors cloud work except local-runtime tasks, and refills a rolling window. The [PStack README](https://github.com/cursor/plugins/blob/main/pstack/README.md) emphasizes verifiable quality over code volume. Semreh retains those choices with the existing single Mac verifier.

[How I use the PStack plugin](https://www.grokbot.sh/blog/how-i-use-the-pstack-plugin) is Steffen Dybvik's account of using Lauren Tan's toolkit, not Lauren Tan's own Grok Bot documentation. Its coordinator/worker/skill separation supports repository-visible worker guidance. The normative source here is upstream PStack plus Semreh's explicit model and native-testing requirements.

PStack's Laziness Protocol keeps this batch to existing backlog goals and issue reports. Separate Before Serializing Shared State gives each report its own issue and later each implementation its own owned files. This is a portable adaptation; Cursor Task types and loops are not claimed to exist in Codex or Muse.
