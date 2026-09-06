# Semreh → Direct Hermes v3 Execution Plan

**Status:** Binding migration plan

**Date:** September 3, 2026

**Supersedes:** `semreh_tui_gateway_migration_plan_v2_reviewed.md`

**Hermes contract target:** `v2026.8.31` / `v0.21.0` at `29112bef099274229cadff79cdff7bf7b99c4b77`

**Semreh migration base:** `SEMREH_MIGRATION_BASE_SHA` — selected and recorded in Slice 1

**Technical reference:** `semreh_tui_gateway_v3_reference_appendix.md`

## Approved Slice 1 isolation deviation — September 4, 2026

Maurice explicitly approved a guarded separate-folder backend instead of a VM,
container, or restricted OS account for Slice 1. This supersedes the OS-isolation
requirements below and in the appendix for this slice only. The independent pinned
clone, dedicated state/config/tool directories and port, disabled memory/cron/
messaging, minimal test-only credentials, and untouched personal Hermes remain
required. A launcher must validate explicit paths and identify only its own process
for stop/restart. Run only disposable bounded test tools. This arrangement does not
prevent same-user access to personal files; that residual risk was accepted.
Reassess isolation before unrestricted tool execution or expanding test scope.
Do not assume the reported personal backup is verified or use it as a safety gate.

## Current release compatibility and orchestration decision — September 5, 2026

Maurice clarified that the App Store app must support the official pinned Hermes
release without requiring a private backend fork. The reasoning extension below
is development-only evidence, not a release prerequisite. Stock TUI already
supports per-session reasoning; audit its targeting, busy-turn and cold-resume
behavior before selecting the minimal safe app implementation. Do not blindly
remove fail-closed guards or replace per-session settings with global writes.
Any unresolved contract limitation must be reported, not silently shipped.

Maurice subsequently accepted guarded stock per-session reasoning changes despite
the upstream missing-runtime fallback-to-global race during concurrent close or
teardown. Use same-socket status/binding checks, idle writes, confirmed readback
and no automatic retry of an ambiguous write. Selections made while answering
remain local pending intent until idle; they must not mutate the active inference.
Normal attached sessions are protected from ordinary eviction; this does not
eliminate the concurrent-close race. Do not claim atomic targeting guarantees.

Maurice subsequently accepted the reproduced stock compacted-history chronology
bug as a documented temporary limitation of the tested Hermes version, not a
Slice 2 blocker. Retain the failing chronology evidence and assertions; do not
claim that gate passed. Other identity, paging and duplicate-prevention gates
remain required. The app must not bundle or require the private fix.

Maurice authorized an upstream contribution for this bug: check the existing PR
first and contribute original reproduction/tests there if it already covers the
fix, otherwise submit the focused fix after independent review. This does not
authorize personal deployment, unrelated publication or private-fork adoption.
App work continues independently. Long-chat scrolling and stale/misplaced thinking
cards are Slice 2 correctness/performance concerns; cosmetic redesign stays out.

Maurice authorized up to five bounded workers plus the integrator, superseding
the three-worker ceiling in Section 6. Actual session capacity may be lower.
Keep one writer per responsibility and one Simulator/DerivedData owner; worker
handoffs do not replace independent integration verification.

## Approved performance deferral and continued migration — September 6, 2026

After testing Semreh Dev build8, Maurice confirmed the bottom arrow now works
during scrolling. Large jumps and chat switching still lag. He explicitly accepted
that residual responsiveness as manageable for now and authorized continuing the
migration, including preparation/implementation of later slices, rather than
prolonging the performance pass. Track deferred work in
`performance-followups.md`; no renderer redesign or animation-polish pass now.
An optimized-build comparison is also deferred, not silently recorded as passed.
This is not a waiver of missing messages, broken controls, lost reading position,
unsafe targeting, or the remaining functional/device verification requirements.
Slice 2 residual checks remain visible while independent Slice 3 work proceeds.

Maurice permits additional bounded workers when useful. Actual harness capacity
and independent file/runtime ownership still constrain concurrency; increasing a
configuration value is not evidence that a running session's capacity changed.
Personal Hermes/backend/routes, publication, and test-tool boundaries are unchanged.

## Historical Slice 2 reasoning experiment — September 5, 2026

Maurice requires per-session reasoning changes, including selecting the next
turn's effort while a response is running. He approved a focused backend fix in
a separate development branch/runtime when upstream inspection found no safe
applicable fix. This does not authorize upgrading or modifying personal Hermes.

The independent clean pin remains the baseline. The development branch
`fix/semreh-session-reasoning` adds a feature-level `session_reasoning_contract: 1`
handshake, fail-closed session/profile targeting, durable per-chat choices, and
next-turn application without mutating the active inference. The verified
backend checkpoint is `8c50f84522a755d40346e73701a6847fbdde20ec`, descended from
the unchanged pin. Exact tests and evidence are in `slice2-verification.md`.

The experimental implementation requires that handshake; older backends remain
read-only for this operation, with no global or WebUI fallback. Draft choices
still use `session.create`. This is a bounded contract extension, not a general
backend upgrade or new adapter layer. Deployment of the patch to any personal
service remains outside the current test scope.

---

## 1. Decision

Semreh will stop depending on `hermes-webui` and become a native client of the first-party `hermes serve` backend.

This is a replatform inside the existing app, not a new iOS application.

Semreh will retain its current:

- SwiftUI product shell and navigation;
- transcript and composer;
- Markdown, code, tools, media, and audio presentation;
- SwiftData cache and cache-first opening;
- session-list presentation;
- Live Activities, Share extension, App Intents, and native interaction polish.

Semreh will replace:

- WebUI chat start/SSE/status/cancel;
- WebUI approval and clarification streams/polling;
- WebUI authentication;
- the separate official-continuity sidecar;
- WebUI-specific session/run recovery;
- any visible WebUI-only feature that is not deliberately migrated.

### Target runtime architecture

```text
Existing Semreh UI, view models, cache, and native features
                         │
                 HermesServerRuntime
                    /             \
                   /               \
      existing APIClient        HermesGatewayClient
      official REST             one JSON-RPC WebSocket
                   \               /
                    \             /
              GatewayConversationController
                 + GatewaySessionBinding
```

Only four ownership concepts are introduced:

1. **`HermesServerRuntime`** — thin lifecycle/composition owner for the active server.
2. **Existing `APIClient`** — narrowed to official `hermes serve` REST.
3. **`HermesGatewayClient`** — one shared JSON-RPC WebSocket client.
4. **`GatewayConversationController`** — replaces WebUI stream/run orchestration for one conversation.

`GatewaySessionBinding` is a value type, not a service.

No new database, state framework, networking dependency, event-sourcing layer, permanent backend adapter system, or transcript rewrite is part of this migration.

---

## 2. Binding invariants

These are implementation constraints. An exception requires explicit approval from Maurice and the technical integrator.

### 2.1 Source and branch

- Implementation starts from one clean, reviewed Semreh commit containing exactly the product work being retained.
- That commit is recorded as `SEMREH_MIGRATION_BASE_SHA`.
- It may be produced by merge, rebase, or selective porting. It does not need to land on `master` first.
- Hermes protocol research and verification use an independent clean clone at `29112bef099274229cadff79cdff7bf7b99c4b77`, not a worktree of the personal Hermes installation.
- The independent clone runs inside a container, VM, or dedicated restricted OS account with no mount or filesystem access to the personal Hermes home or checkout.
- A dirty or differently checked-out Hermes tree is never treated as the contract source.

### 2.2 Backend boundary

- Semreh connects to one `hermes serve` origin per configured server.
- Official REST owns durable resources and transcript pages.
- The TUI Gateway WebSocket owns live execution and blocking interaction.
- There is one WebSocket for the active server, not one per chat.
- One user turn has one transport owner. Semreh never submits the same turn through two paths.
- No production fallback to WebUI is permitted after a feature moves to direct Hermes.

### 2.3 Production authentication

Production remote authentication is:

```text
GET  /api/status
GET  /api/auth/providers
POST /auth/password-login
       { provider, username, password, next: "" }
cookie-authenticated REST
POST /api/auth/ws-ticket
GET  /api/ws?ticket=<single-use ticket>
```

Rules:

- `/api/auth/providers` is the canonical provider-discovery route.
- Slice 1 supports password-capable providers; OAuth/native bearer is later.
- The bundled `basic` provider is the expected two-developer setup.
- `dashboard.basic_auth.secret` must be explicit and stable so sessions survive Hermes restarts.
- The password is not persisted by Semreh.
- Session cookies are retained by the cookie-enabled `URLSession`.
- Every socket connection and reconnect mints a fresh WS ticket.
- Static `?token=` authentication is test-harness-only and is not a production topology.
- Only a structured Hermes `401` indicating `unauthenticated` or `session_expired` demotes the account to signed out.
- A generic `403`, proxy denial, domain-level error, or transient `503` must not be treated as expired authentication.

### 2.4 Cookie topology

The current client uses `HTTPCookieStorage.shared`. Cookies are scoped by host and path, not by Semreh’s server-account ID, and ports do not isolate them.

For v3:

- each configured Hermes server must use a distinct HTTPS hostname;
- root-path deployment is the supported initial shape;
- same-hostname/different-port accounts are unsupported;
- per-server cookie storage is added only if a real required topology cannot satisfy the hostname rule.

Slice 1 must verify cookie persistence, refresh, restart behavior, logout clearing, and proxy attributes through the actual deployment path.

### 2.5 Session identity

Semreh distinguishes:

```swift
struct GatewaySessionBinding {
    var storedID: String
    var runtimeID: String
    var profile: String?
}
```

- `storedID` is durable and powers cache keys, navigation, deep links, and cross-client continuity.
- `runtimeID` is process-local and powers live gateway RPCs/events.
- `session.create` may return the durable ID as `stored_session_id`.
- `session.resume` may return it as `stored_session_id`, `session_key`, or both.
- The decoder accepts both aliases.
- When both aliases occur and disagree, Semreh stops that attachment/recovery operation and performs canonical resolution; it never silently chooses one.
- A returned durable ID may legitimately differ from the requested ancestor because Hermes can resolve a compression continuation.
- Runtime IDs are not persisted across app launches.

### 2.6 New Chat

New Chat begins as a local Semreh draft.

On first send:

1. Create the runtime session.
2. Record durable/runtime binding.
3. Stage attachments.
4. Submit the prompt.
5. Reconcile the new durable row after Hermes persists it.

If creation or attachment staging fails, the draft remains. An unpersisted runtime is explicitly closed when the draft is abandoned. Prewarming is considered only after first-send latency is measured.

### 2.7 Transcript REST contract

Every normal transcript read uses:

- explicit profile scope;
- `include_compacted=true`;
- `order=latest`;
- bounded `limit`;
- offsets measured backward from the newest row;
- returned pages treated as chronological;
- the resolved `session_id` returned by REST adopted as canonical.

Compression/continuation lineage is a required test case, not an edge-case follow-up.

### 2.8 Change invalidation

`sessions.changed` has no origin or session identity. Semreh never tries to infer who caused it.

Policy:

- **Local run active:** dirty/debounce the sidebar only; no visible transcript reload on each tick.
- **Matching terminal event:** perform one canonical transcript reconciliation.
- **Visible chat idle:** debounce and refresh the transcript.
- **User typing or destructive action pending:** defer disruptive refresh, mark dirty, and revalidate before mutation.

### 2.9 Recovery

The first direct daily driver uses:

```text
reconnect
→ authenticate and open socket
→ session.resume by stored ID
→ canonical REST transcript/state reconciliation
```

Lossless sequence replay is evidence-driven:

- Slice 3 tests canonical recovery at every required interruption point.
- If canonical recovery loses required live state, ordering, or blocking prompts, replay becomes required in Slice 3.
- If required, one owner coordinates recovery.
- A reconnect generation uses a connection-wide barrier for session-scoped events while active conversations resume.
- Once runtime mappings are known, replay or canonical reload is selected.
- The gateway client supplies correlation, sequence, epoch, and buffering primitives; it does not run a second independent recovery state machine.

### 2.10 Blocking events

Every blocking gateway event has deterministic terminal behavior before WebUI removal:

| Event | Minimum v3 behavior |
|---|---|
| `approval.request` | Render existing approval UI; allow or deny |
| `clarify.request` | Render existing clarification UI; answer or cancel |
| `sudo.request` | Secure input or explicit cancellation via verified response contract |
| `secret.request` | Secure input or explicit cancellation via verified response contract |
| corresponding `*.expire` | Clear stale UI and unblock local presentation |

Silently ignoring a blocking event is forbidden. A handoff to another client is acceptable only after a real test proves the other client can take ownership and answer it.

### 2.11 Host availability and closed-app behavior

- The supported deployment keeps `hermes serve` under a reviewed managed-service configuration that starts after host reboot/login and restarts after an unexpected process failure.
- The Tailscale Serve or approved reverse-proxy route must persist across host restart and must continue forwarding WebSocket upgrades.
- The host must remain powered on, awake, connected to its network, and connected to Tailscale while unattended Hermes execution is expected.
- After Hermes accepts a run, ordinary Semreh backgrounding, suspension, termination, or socket loss must not stop that run.
- Semreh guarantees canonical catch-up when it next becomes active; it does not initially guarantee an immediate completion notification while iOS has suspended or terminated the app.
- Existing Live Activity behavior remains best effort under iOS execution limits. APNs or a notification relay is deferred unless Maurice elevates closed-app notification delivery to a release requirement before the Slice 3 interface freezes.
- Host unavailability and Tailscale/proxy failure are connectivity states, not authentication expiry.

### 2.12 Isolated test environment

Automated and destructive migration verification never targets Maurice's personal Hermes home or ordinary Hermes gateway.

- Run the pinned independent Hermes clone inside a container, VM, or dedicated restricted OS account with a dedicated disposable `HERMES_HOME`, state database, configuration, logs, memory, credentials, port, and hostname/proxy route.
- Do not mount or expose Maurice's personal Hermes home, personal Hermes checkout, or ordinary home directory to that environment.
- Use a disposable tool working directory and set `terminal.home_mode: profile` so Hermes-launched tools do not inherit the real user home.
- Disable persistent memory, user-profile memory, background memory/skill review, cron, and messaging integrations unless a test explicitly supplies isolated fixtures for one of them.
- Never copy the full production `.env`; inject only the minimum test provider credential required for the selected smoke.
- Preserve all existing Tailscale Serve/Funnel routes and fail closed on a hostname, port, or route conflict.
- A test against the personal Hermes deployment requires Maurice's explicit approval and a named, bounded smoke procedure.

---

## 3. Scope control

### Core release scope

The direct-Hermes release must provide:

- production authentication;
- session list and compacted transcript paging;
- local-draft New Chat and first-send creation;
- create/resume identity handling;
- text, reasoning, tool, completion, and error events;
- stop and steer/queue;
- canonical reconnect and background recovery;
- all blocking prompt dispositions;
- common image/file/PDF attachments;
- cross-client continuity;
- safe edit/regenerate and retained high-value session actions;
- current cache-first and performance behavior;
- complete WebUI removal.

### Not migration blockers

- friends and teams;
- group-agent rooms;
- polished Bot Mode UI;
- OAuth/native bearer login;
- push notification infrastructure;
- a new transcript renderer;
- same-host multi-account cookie isolation;
- rebuilding every historical WebUI convenience feature.

Every non-core current feature receives one decision in Slice 4:

- **migrate**;
- **remove**;
- **defer and hide**.

“Leave a WebUI fallback” is not a disposition.

---

# 4. Four execution slices

## Slice 1 — Contract, clean base, and real authentication spike

### Outcome

A clean Semreh branch connects through the actual remote deployment, authenticates, opens the TUI Gateway, and completes one disposable direct turn without WebUI.

### Scope

- Select and record `SEMREH_MIGRATION_BASE_SHA`.
- Create an independent clean Hermes clone at `29112bef099274229cadff79cdff7bf7b99c4b77` inside the isolated runtime.
- Create the isolated migration backend described in Section 2.12; do not reuse the personal Hermes state or gateway.
- Configure the Hermes `basic` provider with:
  - username;
  - scrypt password hash;
  - stable 32+ byte signing secret.
- Use a distinct HTTPS hostname and root path.
- Implement provider discovery.
- Implement password login with `next: ""`.
- Reuse cookie-capable `URLSession`.
- Implement structured auth-failure classification.
- Implement WS ticket minting.
- Implement the minimum JSON-RPC client:
  - connect/close;
  - request correlation;
  - errors;
  - event dispatch;
  - `gateway.ready`;
  - `gateway.ping`.
- Build a disposable real-backend smoke:
  - `session.create`;
  - `prompt.submit`;
  - terminal completion;
  - `session.interrupt`.

Read-only contract auditing and feature disposition may proceed in parallel. No production code depending on unfinished shared auth/gateway/session interfaces proceeds before this slice passes.

### Gate

Slice 1 passes only when recorded evidence shows:

- the Semreh base is clean and builds/tests;
- the test backend proves its `HERMES_HOME`, state DB, tool home/cwd, port, hostname, and proxy route are isolated from the personal deployment;
- provider discovery returns the password-capable provider;
- invalid credentials fail without creating a usable session;
- valid login sets cookie-authenticated state;
- a protected REST request succeeds;
- app termination/relaunch succeeds without password re-entry;
- Hermes restart with the stable secret preserves authentication;
- expired access-token behavior transparently refreshes/rotates cookies;
- logout clears the applicable cookies;
- Secure, HttpOnly, and Path behavior is correct through the real proxy;
- same-host/different-port configuration is rejected or clearly unsupported;
- one WS ticket opens one socket;
- reusing the ticket fails;
- reconnect mints a fresh ticket;
- `gateway.ready` and `gateway.ping` succeed;
- one disposable prompt produces exactly one durable user turn and one terminal assistant turn;
- interrupt is confirmed by server-side non-running state;
- the test runs with WebUI absent;
- tokens, passwords, cookies, and tickets are absent from logs and verification artifacts;
- a reviewer reruns the slice gate from a clean checkout.

### Re-estimate

After Slice 1, update planning ranges using observed auth, proxy, build, and gateway behavior.

---

## Slice 2 — Core daily-driver chat

### Outcome

Semreh is usable for ordinary direct Hermes conversations while preserving its current native UI.

### Scope

- Local New Chat draft; create on first send.
- Official REST session list.
- Latest transcript tail and older-page loading.
- Explicit profile scoping.
- Compaction/continuation handling.
- Durable/runtime identity normalization.
- `session.create` and `session.resume`.
- Text, interim, reasoning, tools, completion, and error mapping.
- `session.interrupt`.
- `session.steer` and existing queue behavior.
- One shared socket.
- Canonical resume/reload on reconnect.
- Existing transcript, composer, cache, and Live Activity wiring.

Search, rename, pin, archive, delete, and low-use secondary screens do not block the first direct daily driver.

### Gate

- A TUI/Desktop-created session opens in Semreh.
- A Semreh-created session opens in TUI/Desktop.
- An old compression ancestor resolves to the current durable tip.
- Initial and older transcript pages include compacted rows, remain chronological, and prepend without duplicates. The reproduced stock compacted-row chronology failure is an explicitly accepted temporary exception (see September 5 decision above), not a passing result; other assertions remain required.
- Returned resolved session IDs are adopted.
- Fresh create, live resume, cold resume, lazy resume, and continuation resume identity fixtures pass.
- If `stored_session_id` and `session_key` disagree, the operation fails safely and canonically reloads.
- Two interleaved active chats never cross-route events.
- Ten deterministic direct turns produce exact durable user/assistant turn counts after reload.
- Stop is confirmed server-side.
- Accepted, queued, and rejected steer outcomes are handled.
- Reconnect does not duplicate a prompt.
- There is one active-server socket regardless of open chat count.
- No direct-chat code falls back to WebUI.
- Focused tests, full XCTest, pinned-backend smoke, and physical-device responsiveness check pass.

### Re-estimate

After the direct chat skeleton works, update remaining scope and timeline again.

---

## Slice 3 — Mobile reliability, blocking interaction, and attachments

### Outcome

The direct daily driver survives real mobile lifecycle and cannot leave Hermes silently blocked.

### Scope

- Ambiguous prompt-delivery recovery.
- Foreground/background and process relaunch.
- Hermes restart.
- Actual network interruption.
- Approval, clarification, sudo, secret, and expiry behavior.
- Common image, text/code file, and PDF attachment contracts.
- Generated media/authenticated resource loading.
- Canonical recovery test matrix.
- Sequence replay only if the matrix demonstrates it is required.
- Mobile-safe orphan-reap policy selected from evidence:
  - the default 20 seconds is not acceptable;
  - prefer a finite grace that meets required background runs;
  - use `0` only if parked-session cleanup/cap behavior is verified.

### Gate

- Socket loss before write, after server acceptance, during text, during a tool, and before completion creates no duplicate durable user turn.
- Ambiguous outcomes are reconciled before Retry is offered.
- Physical iPhone background tests at agreed short and long intervals preserve the required server run.
- App kill/relaunch and Hermes restart recover the durable conversation.
- A run completed while Semreh is suspended or terminated appears after foreground reconciliation; immediate closed-app push delivery is not required for v3.
- Every blocking prompt can be answered or deterministically cancelled.
- Wrong-session/request responses cannot unblock another run.
- Expiry events clear stale UI.
- Secret and sudo values do not enter logs, SwiftData, UserDefaults, diagnostics, or screenshots.
- Supported attachments round-trip into canonical history.
- Unsupported/oversize attachment failure preserves the draft and does not submit the prompt.
- Canonical recovery results are documented.
- When canonical recovery is insufficient, the connection-wide rebind/replay barrier is implemented and passes ordering/truncation/epoch tests before the slice can pass.
- Full XCTest, real backend, actual proxy, and physical-device gates pass.

---

## Slice 4 — Destructive actions, feature disposition, and WebUI removal

### Outcome

The release candidate is entirely direct Hermes and contains no hidden WebUI dependency.

### Scope

- Durable row IDs.
- Edit/regenerate with fail-closed truncation targeting.
- Branch and compress.
- Search and retained session-management conveniences.
- Migrate/remove/defer-and-hide every secondary feature.
- Remove:
  - WebUI chat/SSE/status;
  - WebUI auth;
  - WebUI approvals/clarifications;
  - direct-continuity sidecar;
  - WebUI contract fixture/watch code;
  - unused SSE dependency;
  - legacy endpoints and DTOs.

### Gate

- Stale or mismatched destructive targets leave history unchanged.
- External mutation cannot redirect edit/regenerate at the wrong row.
- Branch/compress preserve correct lineage and canonical IDs.
- Every visible network action has a direct first-party contract.
- Every blocking event retains deterministic handling.
- Every old feature is marked migrated, removed, or deferred-and-hidden.
- Repository deletion searches find no active WebUI execution/auth/stream fallback.
- The release candidate works with WebUI absent.
- Cache-first opening, typing, streaming, and scrolling remain acceptable on a physical device.
- Full XCTest, direct pinned-backend suite, independent technical review, and Maurice’s product acceptance pass.

---

## 5. Verification model for agent development

Strict verification is required at slice gates, not as ceremony on every trivial change.

### Risk-based levels

| Risk | Examples | Required evidence |
|---|---|---|
| High | auth, request correlation, session identity, ambiguous send, blocking prompts, recovery/replay, destructive history | Exact source/fixture, focused failure tests, real pinned backend, independent review, physical device where applicable |
| Medium | transcript paging, attachments, cross-client sync, mutations | Exact contract, focused integration test, real smoke, slice-level full suite |
| Low | read-only secondary resource/DTO | Exact route/fixture and focused decoding/UI test; final slice integration suite |

### Every agent issue contains

```markdown
Outcome:
Slice:
Entry gate already passed:
Hermes commit:
Semreh base:
Allowed files:
Files not to touch:
Exact source/contract:
Captured request/response/event/error:
Tests to add:
Real-backend check:
Objective acceptance assertions:
Old code/responsibility replaced:
Known non-goals:
```

### Every slice gate records

- exact Semreh and Hermes commits;
- commands run;
- focused-test result;
- full-suite result;
- signed Simulator result when UI changed;
- real-backend result;
- actual-proxy result where applicable;
- physical-device result where applicable;
- security/log search;
- independent reviewer and rerun result;
- known approved deviations.

### No-bypass rules

Agents may not:

- invent endpoint or event shapes;
- update a fixture without recapturing it from the pinned backend;
- weaken, skip, or disable tests to obtain a pass;
- add a hidden WebUI fallback;
- automatically resend an ambiguous prompt;
- claim server interruption from a local UI state change;
- claim physical-device behavior from Simulator;
- create a new dependency/state layer without approval;
- let two implementations own the same reconnect or session state.

---

## 6. Team operating model

### Maurice

Owns:

- core-versus-secondary product scope;
- migrate/remove/defer decisions;
- complexity exceptions;
- physical-device product acceptance;
- rapid UX decisions at slice boundaries.

Maurice reviews demonstrated outcomes and gate evidence, not every line of transport code.

### Technical integrator

Preferably jmogainz or one designated trusted developer.

Owns:

- shared interfaces;
- central-file merge order;
- auth/session/recovery correctness;
- resolution of agent conflicts;
- acceptance of high-risk technical gates;
- preventing temporary dual paths from becoming permanent.

### Agents

Use at most:

- one core gateway/chat implementation agent;
- one independent REST/secondary implementation agent;
- one contract/reviewer agent.

Only one agent modifies the central chat/session/recovery responsibility at a time.

The full appendix is not pasted into every agent prompt. Each issue links only the relevant source section, files, fixture, and gate.

---

## 7. Planning ranges

These are directional planning ranges, not commitments.

| Milestone | Initial range |
|---|---:|
| Slice 1 auth/contract spike | several working days |
| Slice 2 direct daily driver | roughly 1–2 additional weeks |
| Slice 3 reliable mobile core | roughly 1–2 additional weeks |
| Slice 4 parity decisions and deletion | roughly 1–3 additional weeks |

Initial full range: **approximately 4–8 weeks**, primarily determined by retained secondary-feature scope and whether sequence replay is required.

Re-estimate:

1. after Slice 1;
2. after the first Slice 2 direct-chat skeleton.

Agent concurrency should reduce coding latency, but the high-risk identity/recovery path and physical-device gates remain mostly serial.

---

## 8. Immediate next action

Create only the Slice 1 issue set:

1. Select `SEMREH_MIGRATION_BASE_SHA`.
2. Create the independent pinned Hermes clone inside the isolated runtime.
3. Configure real basic-auth deployment with stable secret and unique hostname.
4. Capture auth/WS/session fixtures.
5. Implement provider/login/cookie/ticket probe.
6. Implement minimum gateway client and disposable create/prompt/interrupt smoke.
7. Run and record the Slice 1 gate.
8. Re-estimate before opening dependent production work.

This is the point at which implementation should begin.
