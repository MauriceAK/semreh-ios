# Semreh execution map

Prepared for Maurice's greenlight. No new workers launched. This replaces the earlier eleven-report preparation wave.

## Engineering owners

| Owner | Assignment | Model | Release |
| --- | --- | --- | --- |
| [C01](C01.md) | [#17 Transcript correctness, paging, send and navigation](https://github.com/MauriceAK/semreh-ios/issues/17) | Terra | After greenlight and routine source reconciliation |
| [C02](C02.md) | [#18 Thinking/actions presentation](https://github.com/MauriceAK/semreh-ios/issues/18) | Luna | Same; shared producer edits route through C01 |
| [C03](C03.md) | [#19 Performance instrumentation/coverage](https://github.com/MauriceAK/semreh-ios/issues/19) | Luna | Same; device measurements remain local |
| [M01](M01.md) | [#20 Settings](https://github.com/MauriceAK/semreh-ios/issues/20) | Muse records actual model | Same; excludes C03 StreamingLab files |
| [M02](M02.md) | [#21 Onboarding](https://github.com/MauriceAK/semreh-ios/issues/21) | Muse records actual model | Same; approved fixture only |
| [M03](M03.md) | [#22 Session previews](https://github.com/MauriceAK/semreh-ios/issues/22) | Muse | After #10/#14 scope disposition |
| [M04](M04.md) | [#23 Bird/header/icons](https://github.com/MauriceAK/semreh-ios/issues/23) | Astra design; Muse implementation | After reference handoff and shared header ownership |
| [M05](M05.md) | [#24 Bots/Tasks](https://github.com/MauriceAK/semreh-ios/issues/24) | Muse | After #12/#13 scope disposition |

Five engineering owners can work concurrently with disjoint listed writes. Each owns investigation, confirmed in-scope fixes, focused tests, PR CI and returned verifier findings. A no-change outcome requires evidence; a planning report alone does not complete an engineering assignment. Three held owners join as dependencies clear. There is no fixed numerical concurrency cap.

Two separate read-only contract tasks (#30 groups and #41 Live Activity delivery) can also run concurrently if included in the greenlight. These have real authority/contract questions; they do not authorize backend deployment or speculative implementation.

## Verification and integration

Sol medium owns the one warm native simulator and starts with transcript issue #4. Source investigations can proceed while the native scenario is reproduced. CI is an admission gate, not acceptance. The original failure and meaningful regressions must be checked on the exact candidate. Appearance requires named-state screenshots, motion/lifecycle recordings, and performance measured traces with workload/device/build identity. Test errors, skips and limitations remain explicit. No physical-device claims from simulator evidence.

Failed findings return to the same issue owner. Unsupported provider resumption uses an explicit replacement assignment carrying the branch and evidence. Root reviews passing evidence and integrates. This preserves Maurice's requested coordinator-only merge policy rather than importing Full Autopilot's owner-merge authority.

## Dispatch checklist owned by coordinator

Before each launch, pin the current integrated SHA, inspect open overlapping PRs, reconcile relevant local dirty work, and give the worker all relevant evidence and standing constraints. Confirm the requested provider model is supported. Make the repository playbooks reachable by merging PR #16 after review or explicitly supplying that documentation revision. Register task identity and repair route. These are launch operations, not reasons to ask Maurice to re-plan the backlog.

The writable source list in each owner brief is exclusive. Shared project.pbxproj, network contracts and unassigned shared tests require an ownership transfer. Do not split one transcript state machine among competing writers to inflate parallelism.

## All 24 acceptance units

These are checklists nested under owners, not 24 obligatory workers. Existing issue numbers remain stable for visibility and history.

| Unit | Issue | Owning task |
| --- | --- | --- |
| [U00](units/U00.md) | #5 | Done |
| [U01](units/U01.md) | #4 | C01 |
| [U02](units/U02.md) | #25 | C01 |
| [U03](units/U03.md) | #26 | C02 |
| [U04](units/U04.md) | #27 | C01 |
| [U05](units/U05.md) | #28 | C01 |
| [U06](units/U06.md) | #22 | M03 |
| [U07](units/U07.md) | #29 | C01 |
| [U08](units/U08.md) | #23 | M04 |
| [U09](units/U09.md) | #20 | M01 |
| [U10](units/U10.md) | #24 | M05 |
| [U11](units/U11.md) | #21 | M02 |
| [U12](units/U12.md) | #30 | Contract task #30 |
| [U13](units/U13.md) | #31 | C03 |
| [U14](units/U14.md) | #32 | C03 |
| [U15](units/U15.md) | #33 | Coordinator |
| [U16](units/U16.md) | #34 | Native device gate |
| [U17](units/U17.md) | #35 | C03 |
| [U18](units/U18.md) | #36 | C03 |
| [U19](units/U19.md) | #37 | C03 |
| [U20](units/U20.md) | #38 | C01 |
| [U21](units/U21.md) | #39 | C03 |
| [U22](units/U22.md) | #40 | C02 |
| [U23](units/U23.md) | #41 | Contract task #41 |

U00 is complete. U12 and U23 retain fixture/authority gates. U14/U16/U17 require physical-device verification. U15 records pipeline evidence and remaining limitations. Other seed dependencies govern native acceptance; they do not impose a global barrier on independent engineering.

## Muse handoff

> Read issue #15, this execution map and the PStack guidance in PR #16. Own #20 and #21 independently through investigation, confirmed in-scope repair, focused tests, linked PRs and macOS CI. Follow each issue's file ownership. Keep #22–#24 reserved until their release conditions clear. Report actual model and branch/head/PR. Return native-only checks to the shared Sol verifier; respond to its findings. Do not merge. Product redesign goes through Astra. Continue within scope without stopping for another planning approval.

See [research and adaptation](research-and-adaptation.md) for the source rationale. The runtime scheduler and provider repair limitations remain recorded in local CURRENT.md; this map does not claim new automation was tested.
