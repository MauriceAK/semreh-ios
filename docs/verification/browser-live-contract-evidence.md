# Browser live-contract evidence — issue #45 (B02)

Companion to `docs/agents/assignments/browser-live-contract.md`. Records
exact versions, source anchors, and the fixture recipe. Runtime checks were
**not run** — this file exists so an independent reviewer can reproduce the
reasoning from the pinned code.

## 1. Recorded versions (verified, not assumed)

| Component | Recorded value | How verified |
| --- | --- | --- |
| Semreh app base | `master` @ `4ff83558f5566da2b14e1187518a75a4edc9b21e` | `git rev-parse HEAD` on the worker checkout, 2026-09-19 |
| Documented Hermes pin | `29112bef099274229cadff79cdff7bf7b99c4b77` | Approved independent clone `/Users/maurice/workspace/semreh-slice1-backend-source` is clean, detached at the exact SHA, and tagged `v2026.8.31`; canonical source is `NousResearch/hermes-agent` (the MauriceAK fork contains the same pinned object) |
| Hermes mirror `main` HEAD (drift, not contract) | `d177b119e9c56c9ddc0b7379ffce52341ec06584` (2026-09-18) | `MauriceAK/hermes-agent` mirror; all contract anchors remain at the pinned SHA |
| hermes-agent package | 0.21.0 | `pyproject.toml` at the pin |
| Agent browser backends | local Chromium via `agent-browser` CLI (npx-managed binary); cloud `browser-use` → `browserbase` preference; Camofox / Lightpanda variants | `tools/browser_tool.py` docstring + `_get_cloud_provider` + `agent/browser_registry.py` |
| Broker protocol | `BROWSER_CONTROL_PROTOCOL_VERSION` (int, exact-match) | `gateway/browser_control_broker.py:87` (constant), `:143-145` (validator) |
| Semreh gateway transport | `/api/ws` WebSocket + single-use `ticket` query param; JSON-RPC | `HermesMobile/Networking/HermesGatewayClient.swift` |

Dependency versions beyond the above were not enumerated: they do not
affect the contract verdict. Maurice's *running* backend version was not
observable from here — the pin is the contract base, not a claim about his
machine.

## 2. Source anchors (all at pin `29112bef099274229cadff79cdff7bf7b99c4b77`)

- Agent browser sessions: `tools/browser_tool.py:1976`
  `_navigation_session_key`, `:2039` `_last_session_key`, `:2015`
  `_bare_task_id_for_session_key`, `:2022` `_session_info_owned_by_task`
  (fail-closed stale-binding drop).
- Per-task CDP supervisor: `tools/browser_tool.py:656`
  `_ensure_cdp_supervisor`; host-local CDP lookup `:1571`
  `_agent_browser_get_cdp`.
- Gateway session identity: `tui_gateway/methods_session.py:14-18,130-135`
  distinguishes short `session_id` from durable `stored_session_id`; prompt
  execution passes the durable key as browser `task_id`
  (`tui_gateway/server.py:13055-13074`), while short-id resolution is
  internal (`tui_gateway/server.py:8356-8367`).
- Screenshot storage (host-local): `tools/browser_tool.py:5442`
  (`cache/screenshots/browser_screenshots/browser_screenshot_<uuid>.png`,
  24h cleanup at `:5744`).
- One-shot browser vision: `tools/browser_tool.py:5412-5434,5590-5636`
  returns a screenshot-capable tool result; gateway tool completion emits the
  result (`tui_gateway/server.py:7923-7944`) and the Semreh event projection
  retains it (`HermesMobile/Networking/GatewayConversationController+Events.swift:7-16,107-118`).
- Control broker: `gateway/browser_control_broker.py:92` capability
  allowlist, `:113` developer capabilities, `:234` `ControllerScope`,
  `:399` ticket mint, `:438` attach, `:646` dispatch, single-shot
  `complete`.
- Gateway methods: `tui_gateway/methods_browser_control.py:128`
  (`browser.controller.register`), `:242` (result), `:311` (heartbeat),
  `:346` (detach); `tui_gateway/methods_tools.py:1456`
  (`browser.manage` → `_resolve_browser_cdp_url` at
  `tui_gateway/server.py:17605`).
- Local API routes: `POST /v1/browser-control/register`,
  `GET /v1/browser-control/ws` (ticket ≤30s)
  — `tests/gateway/test_browser_control_api.py:64`; local API principal and
  transport family are derived at `gateway/platforms/api_server.py:3751-3785`.
- Dashboard controller identity is distinct: `tui_gateway/methods_browser_control.py:65-89`
  derives `principal:dashboard:*` from the authenticated `/api/ws` identity.
- Turn lease (NOT a browser lease): `gateway/turn_lease.py` docstring —
  serializes transcript load/run/flush per `session_id`.
- Semreh client surface: `HermesMobile/Networking/HermesGatewayClient.swift`
  (`/api/ws` ticket auth); gateway methods used: `session.*`, `prompt.*`,
  `config.*` — zero `browser.*` methods.

## 3. Minimal sanitized exchange (from source/tests, not a live run)

Controller registration round-trip shape (test fixture, no live backend):

```json
// POST /v1/browser-control/register
{"protocol_version": 1, "controller_id": "controller-fixture",
 "browser_profile_id": "browser-profile-fixture",
 "session_id": "session-fixture",
 "capabilities": ["controller.noop", "browser_navigate"],
 "principal_id": "spoofed-client-principal"}
// → 201: {"protocol_version": 1, "ticket": "<single-use, ≤30s>",
//         "ws_path": "/v1/browser-control/ws",
//         "scope": {"principal_id": "principal:<profile>:<server digest, NOT the spoofed value>",
//                    "transport_family": "local-api",
//                    "capabilities": ["browser_navigate", "controller.noop"]}}
```

The HTTP controller ticket is presented in the WebSocket subprotocol, not a
query parameter; query-string tickets are rejected
(`gateway/platforms/api_server.py:3595-3631`). This local-API exchange is only
evidence of the ticket/scope pattern, not of a watch capability. A future
`browser.task.watch` over Semreh's `/api/ws` must use that authenticated
transport identity and must not copy the local-API principal shape (or vice
versa).

## 4. Fixture recipe (approved, bounded, disposable)

For the verifier / #46 owner, once the §6 backend extension exists:

1. Launch the approved disposable Hermes backend at (or newer than) the
   recorded pin with a throwaway profile; no personal home, credentials,
   or Tailscale.
2. From Semreh (simulator), start two disposable chat tasks that each open
   a browser; assert the watch surface shows two distinct task-bound
   browser tokens through navigation and conversation switching.
3. Close/reopen the viewer; assert the agent task keeps running and the
   current page returns (no second browser spawned).
4. Assert watch interactions dispatch zero remote input (adapter counter).
5. Change server/profile/conversation mid-watch; assert stale frames are
   masked and no cross-origin ticket/frame leaks.

Until the extension exists, no executable *watch* check exists. Ordinary browser
tools remain turn-scoped; `browser_vision` may produce a one-shot screenshot
tool result, but that is NOT live-browser watch evidence and must not be
presented as such.

## 5. What was NOT done

- No live backend was contacted; no browser was launched; no CDP session
  was opened. Every runtime cell is NOT RUN by construction.
- No personal Hermes home/service, browser profile, credential, Tailscale
  route, or external account was accessed.
- Cloud provider internals (Browser Use / Browserbase session identity)
  were not audited beyond the shared routing path.
- `docs/verification/` did not exist; it is created by this docs-only PR.
