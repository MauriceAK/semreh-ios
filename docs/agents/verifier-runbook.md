# Semreh Verifier Runbook (Mac mini lane)

Single serial lane. One PR at a time. The verifier NEVER edits code.
Written for a Solo-piloted agent to read cold, mid-task.

## Prerequisites (one-time, human or mini agent)

- Xcode installed. Signed Debug simulator builds work without an Apple
  account sign-in (verified). Bundle `com.maurice.semreh`.
- Repo cloned, `master` builds clean in Xcode.
- One warm simulator: **iPhone Air** (the only iPhone sim on this Mac;
  kept booted between runs).
- `gh` authenticated.

## 0. Claim a PR

- Pick the oldest PR labeled `needs-verify`.
- `gh pr checkout <number>` on top of a clean tree.
- Move label `needs-verify` → `verifying` (signals the lane is busy).

## 1. Doctor (read-only, run first)

- `xcrun simctl list devices | grep "iPhone Air"` — booted, not busy.
- `git status --porcelain` — clean except the PR branch.
- If anything looks off, stop and report; do not force through.

## 2. Launch (signed simulator build)

CI builds with `CODE_SIGNING_ALLOWED=NO`; simulator installs must be signed,
so build locally with the Developer identity:

```
xcodebuild build \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath DerivedData-verify
```

Install + launch:

```
xcrun simctl install booted <path-to>/HermesMobile.app
xcrun simctl launch booted com.maurice.semreh
```

Teardown afterwards: `xcrun simctl terminate booted com.maurice.semreh`.
**Do not unconditionally uninstall the app.** You must preserve installed app data to allow for resume/background/history verification. App reset (uninstall/reinstall) is only permitted if it is an explicit, separately scoped disposable clean-onboarding test. Never kill by process name.

## 3. Drive

Read the PR description's **Acceptance criteria** and **Repro** sections first. Determine if the test is a state-preservation scenario (default) or an explicit fresh-fixture clean-onboarding scenario.
Then:

1. Reproduce the OLD behavior on `master` (stash the branch or use a
   second worktree) — record baseline.
2. Reproduce on the PR branch — record new behavior.
3. Exercise the real user path (real taps/scrolls in the running app),
   not test-only hooks.

## 4. Evidence (posted to the PR as a comment)

- **Exact PR head SHA** tested.
- **Timing:** Dispatch/start/completion timing when available.
- Screen recording (simctl io recordVideo) of before vs after, or
  screenshots when motion isn't the point. **Limitation:** Simulator performance does not prove physical device FPS. Do not claim or promise physical device FPS validation based on the simulator.
- Verdict per acceptance criterion: PASS / FAIL with one line each.
- Logs attached on FAIL. **Do not collect credential-bearing diagnostics.** Label `verifying` → `verified` (all PASS) or
  `needs-fix` (any FAIL, with the failing evidence inline).

## 5. Cleanup

Terminate sim processes you started, restore tree to master. **Do not uninstall the app** unless running a fresh-fixture scenario.
Evidence posted to the PR survives cleanup.
