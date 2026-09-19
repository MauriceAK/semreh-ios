# Semreh Verifier Runbook (Mac mini lane)

Single serial lane. One PR at a time. The verifier NEVER edits code.
Written for a Solo-piloted agent to read cold, mid-task.

## Prerequisites (one-time, human or mini agent)

- Xcode installed. Signed Debug simulator builds work without an Apple
  account sign-in (verified). Bundle `com.maurice.semreh`.
- Repo cloned, `master` builds clean in Xcode.
- The Mac may have multiple booted simulators. Select and record one explicit available simulator UDID (`$UDID`) to use.
- `gh` authenticated.

## 0. Claim a PR

- Pick the oldest PR labeled `needs-verify`.
- `gh pr checkout <number>` on top of a clean tree.
- Move label `needs-verify` → `verifying` (signals the lane is busy).

## 1. Doctor (read-only, run first)

- `xcrun simctl list devices | grep "$UDID"` — booted, not busy.
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
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath DerivedData-verify
```

Install + launch:

```
xcrun simctl install $UDID <path-to>/HermesMobile.app
xcrun simctl launch $UDID com.maurice.semreh
```

Teardown afterwards: `xcrun simctl terminate $UDID com.maurice.semreh`.
Preserve app data by default. Never kill by process name.

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
- Exact-SHA evidence is required.
- No credential diagnostics.
- No physical-device FPS inference.

## 5. Cleanup

Preserve app data by default, terminate sim processes you started, restore tree to master.
Evidence posted to the PR survives cleanup.
