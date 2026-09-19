# Semreh Verifier Runbook (Mac mini lane)

Single serial lane. One PR at a time. The verifier NEVER edits code.
Written for a Solo-piloted agent to read cold, mid-task.

## Prerequisites (one-time, human or mini agent)

- Xcode installed, signed in with the Apple Developer account; automatic
  signing working (bundle `com.mauricekenon.semreh`).
- Repo cloned, `master` builds clean in Xcode.
- One warm simulator: **iPhone 17** (kept booted between runs).
- `gh` authenticated.

## 0. Claim a PR

- Pick the oldest PR labeled `needs-verify`.
- `gh pr checkout <number>` on top of a clean tree.
- Move label `needs-verify` → `verifying` (signals the lane is busy).

## 1. Doctor (read-only, run first)

- `xcrun simctl list devices | grep "iPhone 17"` — booted, not busy.
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
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath DerivedData-verify
```

Install + launch:

```
xcrun simctl install booted <path-to>/HermesMobile.app
xcrun simctl launch booted com.mauricekenon.semreh
```

Teardown afterwards: `xcrun simctl terminate booted com.jacobmoore.semreh`
and uninstall the app. Never kill by process name.

## 3. Drive

Read the PR description's **Acceptance criteria** and **Repro** sections first.
Then:

1. Reproduce the OLD behavior on `master` (stash the branch or use a
   second worktree) — record baseline.
2. Reproduce on the PR branch — record new behavior.
3. Exercise the real user path (real taps/scrolls in the running app),
   not test-only hooks.

## 4. Evidence (posted to the PR as a comment)

- Screen recording (simctl io recordVideo) of before vs after, or
  screenshots when motion isn't the point.
- Verdict per acceptance criterion: PASS / FAIL with one line each.
- Logs attached on FAIL. Label `verifying` → `verified` (all PASS) or
  `needs-fix` (any FAIL, with the failing evidence inline).

## 5. Cleanup

Uninstall app, terminate sim processes you started, restore tree to master.
Evidence posted to the PR survives cleanup.
