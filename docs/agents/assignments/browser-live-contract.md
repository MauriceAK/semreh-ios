# Browser live contract — issue #45 (B02)

**Owner:** Muse Spark 1.3 via the Astra runtime (task identity `astra-runtime`; no external task URL exists).
**Status:** contract delivered; WATCH BLOCKED / CONTROL BLOCKED at the pinned backend (see §5).
**App base:** `master` @ `4ff83558f5566da2b14e1187518a75a4edc9b21e`.
**Backend contract pin:** `MauriceAK/hermes-agent` @ `29112bef099274229cadff79cdff7bf7b99c4b77`
(release v0.21.0, 2026-08-31; SHA verified to exist — it is NOT in
`nesquena/hermes-webui`, which 404s for this SHA). `main` HEAD has since moved
to `d177b119e9c56c9ddc0b7379ffce52341ec06584` (2026-09-18); all anchors below
are against the documented pin.
**Runtime evidence:** NOT RUN for every live check (no Mac, no live backend;
no personal Hermes home/service, credentials, browser profiles, Tailscale
routes, or external accounts were touched).

## 1. Identity chain (inspected, not assumed)

Semreh conversation → gateway session → agent task → browser session → tab/surface:

| Link | What the pin actually provides | Anchor |
| --- | --- | --- |
| Semreh ↔ gateway | iOS `HermesGatewayClient` opens `/api/ws` WebSocket, single-use `ticket` query param, JSON-RPC request/response with per-request continuations | `HermesMobile/Networking/HermesGatewayClient.swift` (`ticketURL`, `pending`); gateway methods `session.*`, `prompt.*`, `config.*` |
| Gateway session → agent task | Agent turns run under a gateway `session_id`; browser tool calls resolve the agent-side `task_id` from the turn context | `tools/browser_tool.py` `_navigation_session_key(task_id, url)` (line 1976), `_last_session_key(task_id)` (line 2039) |
| Agent task → browser session | In-process `_active_sessions[session_key]`; `session_key` is the bare `task_id`, or `{task_id}::local` for the hybrid local sidecar. Ownership metadata (`owner_task_id`, `session_key`) checked per call; stale/mismatched bindings are dropped fail-closed | `tools/browser_tool.py` lines 2015–2066 (`_bare_task_id_for_session_key`, `_session_info_owned_by_task`) |
| Browser session → tab | Tabs live inside the agent-browser CLI subprocess / CDP target list; a per-task CDP supervisor exists (`_ensure_cdp_supervisor(task_id)`, line 656) and `_agent_browser_get_cdp(session_name)` (line 1571) can return the **host-local** CDP URL | `tools/browser_tool.py` lines 656, 1571 |
| Conversation → browser session for a *remote client* | **No link.** Nothing maps a gateway `session_id` to an agent `task_id`'s browser `session_key` for anyone except the agent process itself | — (absent; this is the missing discovery link) |

A URL or "the globally active browser" is not an identity. The only
client-visible browser evidence today is the browser tool's **text results**
(aria snapshots) inside the conversation transcript — there is no image,
tab, or session handle on the wire.

## 2. Two browser planes — do not conflate them

1. **Agent task browser** (`tools/browser_tool.py`, ~6500 lines): the Hermes
   agent drives its own Chromium (default local via `agent-browser` CLI;
   cloud via Browser Use / Browserbase plugins; Camofox/Lightpanda variants).
   This is the browser #46 wants to watch.
2. **Dashboard extension control** (`gateway/browser_control_broker.py`,
   `tui_gateway/methods_browser_control.py`): lets the *agent* command a
   browser driven by a *user's dashboard extension*. This is agent→user-browser,
   the opposite direction from #46.

The broker's capability vocabulary (`browser_screenshot`, `browser_snapshot`,
`browser_tabs`, `browser_tab_activate`, `browser_click`, `browser_type`,
`browser_navigate`, `browser_back`, `browser_scroll`, `browser_press`,
`controller.noop`; developer-gated `browser_cdp`, `browser_evaluate`;
artifact `browser_artifact_download/upload`) is bound to **extension
controllers**, not to agent task browsers. Reusing the vocabulary is fine;
assuming the wiring transfers is not.

## 3. Contract matrix

`implementation contract`: **supported** / **extension needed** / **unsupported** / **unknown**.
`runtime evidence`: **passed** / **failed** / **not run**. Unrun checks are
NOT RUN, never passed.

| Capability | Implementation contract | Runtime evidence | Source anchor (pin `29112bef`) | Notes |
| --- | --- | --- | --- | --- |
| Discovery: list a task's browser session(s) remotely | **unsupported** | not run | absent from all 5 browser gateway methods (§4) | Session keys are in-process; `_active_sessions` has no remote reader |
| Watch: screenshot of the agent's live browser | **extension needed** | not run | `tools/browser_tool.py:5442` writes PNGs host-local (`cache/screenshots/browser_screenshots/`, UUID names, 24h cleanup); broker `browser_screenshot` exists but targets extension controllers (`gateway/browser_control_broker.py:92`) | No gateway method returns a task-browser screenshot |
| Watch: live/periodic frame stream | **unsupported** | not run | no stream primitive anywhere in the browser path | Would need a new bounded frame channel; #44's client ceilings (4 MiB, 4096px, ~8.4M decoded px) are the client-side budget to design against |
| Tab metadata (tabs, active tab, URL) | **extension needed** | not run | Broker vocab has `browser_tabs`/`browser_tab_activate` for controllers; agent CLI tracks tabs internally | Same missing remote link as discovery |
| Auth for a new watch method | **supported** (pattern) | not run | `tui_gateway/methods_browser_control.py:40` — server-minted identity, spoofed `principal_id` ignored, digest `principal:dashboard:<sha256[:32]>`; Semreh already does ticket auth on `/api/ws` | Reuse, don't invent |
| Frame geometry | **unknown** | not run | No remote frame exists, so no geometry contract to inspect | Part of the extension proposal (§6) |
| Input: remote click/type (for #47) | **extension needed** | not run | Broker vocab has the actions for controllers; agent's own browser accepts tool calls only in-process | #46 is read-only regardless; input is #47's contract |
| Stop: halt an in-flight browser action remotely | **unsupported** | not run | Broker has `cancel`/`detach` for *controller commands*, not for agent tool calls; agent-side stop is the turn interrupt path | Not the same primitive |
| Resume: resume Hermes / rebind after client disconnect | **unsupported** | not run | No rebind primitive; `_last_session_key` re-resolves within the agent process only | Client reconnect must re-discover (see proposal) |
| Takeover: exclusive human ownership | **extension needed** | not run | Broker has exact-scope identity, owner-transport checks, single-shot `complete`, tickets, heartbeat, hard `detach` (`gateway/browser_control_broker.py:234–720`) — but all govern *controller attachment*, not human takeover of the agent's browser | Closest existing pattern; needs a new scope kind |
| Lease expiry | **unsupported** | not run | `gateway/turn_lease.py` serializes *turns* per `session_id` (transcript ordering) — it is NOT a browser ownership lease | Do not cite turn_lease as browser exclusivity |
| Competing controllers / shared subagents | **extension needed** | not run | Broker rejects cross-scope completion (`complete` is exact-scope); agent side has no multi-client arbitration | Proposal must define who wins |
| Bypass paths (unmediated CDP/shell) | **unsupported** (as a *guarantee*) | not run | `_get_cdp_override` / `BROWSER_CDP_URL` lets the operator point the agent at an arbitrary CDP endpoint (`tools/browser_tool.py:496`); raw CDP is outside the broker allowlist and fail-closed without Developer Mode | Any watch design must assume the operator's CDP override exists and scope to the task session key |

## 4. Gateway browser surface at the pin (complete)

Exactly five JSON-RPC methods; no more, no fewer:

- `browser.controller.register` / `.result` / `.heartbeat` / `.detach`
  (`tui_gateway/methods_browser_control.py:128,242,311,346`) — dashboard
  extension controller lifecycle. Fail-closed (4403) unless the
  `browser.extension_control.enabled` flag is on, the transport holds a
  server-authenticated non-internal identity, and the session's transport is
  exactly the calling transport. Transport families isolate dashboard
  (`cloud-ticket-ws`) from local API (`local-api`).
- `browser.manage` (`tui_gateway/methods_tools.py:1456`) — operator tooling:
  `status` returns the *configured* CDP override URL
  (`BROWSER_CDP_URL` env / `browser.cdp_url`), `connect`/`disconnect` manage
  that attachment. This is the operator's browser, not a task browser, and
  the URL is host-local.

HTTP API adapter additionally exposes `POST /v1/browser-control/register`
→ single-use ticket (≤30s) → `GET /v1/browser-control/ws`
(`tests/gateway/test_browser_control_api.py:64`). Semreh's client surface
(`session.*`, `prompt.*`, `config.*`, …) contains **zero** browser methods.

## 5. Verdicts

**WATCH: WATCH BLOCKED.** The agent's task browser has no supported remote
discovery, screenshot, tab, or stream interface at the pin. The broker's
watch vocabulary exists but is wired to dashboard extension controllers.
A source-backed coding path becomes possible only with the §6 extension;
until then #46 cannot be implemented against a real backend. This verdict
does NOT block #44's native workspace/lab, which is backend-independent.

**CONTROL: CONTROL BLOCKED.** No remote takeover, lease, stop, or resume
primitive exists for clients. The broker's ownership machinery (exact scope,
owner transport, single-shot completion, tickets, heartbeat, hard detach)
is the pattern to extend, but it currently governs controller attachment
only. Per the issue, the missing control interface must not hold up an
independently viable read-only viewer.

## 6. Smallest extension proposal (backend-owned; NOT authorized here)

Missing link: gateway session → agent task browser session, plus one
bounded read primitive. Proposed (naming owned by the backend author):

- New read-only gateway method, e.g. `browser.task.watch`, params
  `{session_id}` (the *gateway* session id Semreh already holds).
- Server resolves gateway session → agent `task_id` → `_last_session_key(task_id)`
  (reuse `tools/browser_tool.py:2039`, do not duplicate the logic).
- Returns `{browser_active: bool, current_url_sanitized, tabs: [{id, url, active}], screenshot_png_base64_bounded, generation}`. Generation counters
  follow #44's stale-frame discipline; screenshot bound matches #44's 4 MiB
  client ceiling. Never return the raw session key or the CDP URL.
- Auth/identity: existing `/api/ws` ticket auth; identity pattern copied from
  `methods_browser_control.py` (server-minted digest, spoofed params ignored).
- Candidate repo/files: `MauriceAK/hermes-agent` (Maurice's fork; needs his
  explicit write authorization — #45 cannot create it), new
  `tui_gateway/methods_browser_view.py` calling a small accessor on
  `tools/browser_tool` (read `_active_sessions` under its lock; no new
  subprocesses).
- Test boundary: `tests/gateway/test_browser_view_api.py` mirroring
  `tests/gateway/test_browser_control_api.py` (ticket round-trip, exact-scope
  rejection, spoofed-identity filtering, oversized-screenshot rejection).
- For #47 later: `browser.task.takeover` / `.release` modeled on the broker's
  `attach`/`detach` + heartbeat, with a human-principal scope kind distinct
  from `principal:dashboard:*`.

Do not pretend these wire fields exist today. Backend write ownership must
be established (Maurice/coordinator) before any edit; no implicit private
fork or personal deployment.

## 7. #46 file mapping against #44's exported API

#44's specified export (`Packages/SemrehRemoteBrowser`): internal Swift
abstractions — remote surface descriptor, capabilities, adapter
events/actions, ownership state, geometry; a read-only default adapter;
fixtures injected only from BrowserLab/tests. These are **internal package
types, not the wire schema** (per #44 §"Implementation sequence").

| #46 named file | Role vs #44's API |
| --- | --- |
| `HermesMobile/Networking/RemoteBrowserLiveAdapter.swift` | Implements #44's adapter protocol; the ONLY file that speaks the §6 gateway method. Asserts subscription/target ids, zero input dispatch, generation-checked frame delivery |
| `HermesMobile/Features/RemoteBrowser/ConversationBrowserPresentation.swift` | Presentation state machine over #44's ownership-state/geometry types; maps gateway generation → #44 frame generations |
| `HermesMobile/Features/RemoteBrowser/ConversationBrowserCard.swift` | The compact chat card (`conversation.browser.open`); binds to the conversation's current surface |
| `HermesMobileTests/RemoteBrowserLiveAdapterTests.swift` + `ConversationBrowserPresentationTests.swift` | Contract tests from §6's inspected source / sanitized exchanges; tolerate added optional fields, reject missing identity/auth/version fields |
| `HermesMobileTests/Fixtures/RemoteBrowser/target.html` + `HermesMobileUITests/RemoteBrowserLiveViewerUITests.swift` | Bounded synthetic page + repeatable recipe |
| `docs/agents/assignments/browser-live-viewer.md`, `docs/verification/browser-live-viewer.md` | #46's own docs (not this worker's) |
| Shared (reserved for the #46 owner after owner check): `ChatView.swift` card hook, `ChatViewModel.swift` surface plumbing, `HermesServerRuntime.swift` + `GatewayConversationController+Events.swift` typed hookup (no second runtime), `project.pbxproj` membership only | Must check active owners (especially C01/network/project) before touching; omit unused |

## 8. Registered integration handoff (#46 → #47)

- **#46 prerequisites (all must clear):** (1) #44's tested package baseline
  integrated or explicitly selected by the coordinator — **not yet**
  (`issue/44-browser-workspace` unclaimed, no PR as of 2026-09-19 ~22:40 PDT);
  (2) #45 reports WATCH IMPLEMENTATION READY — **not yet** (this doc reports
  WATCH BLOCKED pending the §6 backend extension); (3) shared-file ownership
  reconciled. **#46 stays HELD. Do not start it.**
- **#47 prerequisites:** #46 integrated + #45 identifies an implementable
  control contract + host/app write responsibilities established. **HELD.**
- **Agreed adapter boundary with #44:** #46 adapts to #44's
  `Packages/SemrehRemoteBrowser` internal adapter/ownership/geometry
  interfaces; the gateway wire schema (§6) is mapped inside
  `RemoteBrowserLiveAdapter.swift` only. If #44's export surface drifts,
  reconcile via the issues — no silent rewrites of #44's package.
- **Genuine conflicting writes:** none today (#44 unclaimed; no overlapping
  PRs on the #46 named files; open PRs are #10/#14/#42/#43 on unrelated
  slices). Re-check at #46 dispatch.
- **To resume:** this worker (Muse Spark 1.3 via Astra runtime) is retained
  as the B-LIVE owner. Needed: (a) coordinator decision on the §6 backend
  extension (authorize + name the method), or an explicit
  fixture-only/downgraded #46 scope; (b) #44's package baseline selection;
  (c) a fresh claim check (issues/PRs/branches) at dispatch. The worker
  session persists for follow-up relaying reviewer feedback.

## 9. Limitations

- No runtime execution: every `runtime evidence` cell is NOT RUN. This
  docs-only PR must never be labeled as live-browser verification.
- Contract is pinned to `29112bef`; `main` has drifted (`d177b119`).
  Re-verify anchors if the backend moves before #46 starts.
- Cloud browser backends (Browser Use / Browserbase) were inspected only
  for session-key routing; their session-identity exposure was not audited
  beyond the shared `_active_sessions` path.
- Takeover races were analyzed statically; no live reproduction.
