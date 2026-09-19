# Semreh → Direct Hermes v3 Reference Appendix

**Companion to:** `semreh_tui_gateway_v3_execution_plan.md`

**Purpose:** Technical source references, contracts, mappings, test fixtures, feature disposition, and deletion guidance.

**Hermes pinned release:** `29112bef099274229cadff79cdff7bf7b99c4b77`

**Date:** September 3, 2026

This appendix is not an agent’s default coding prompt. An implementation issue should quote only the relevant section and exact source files.

---

# A. Source authority and current baselines

## A.1 Authority order

For every wire-level implementation:

1. A clean running `hermes serve` at the pinned SHA is the final arbiter.
2. Pinned Hermes source defines the intended contract.
3. Pinned Hermes first-party client code demonstrates supported usage.
4. Release documentation supplies context.
5. Current `main` may reveal future drift, but does not change the pinned contract.
6. Existing Semreh/WebUI behavior is a product reference, not proof of a direct Hermes contract.

Every captured fixture records:

- Hermes SHA;
- request;
- success response;
- relevant event sequence;
- important failure response;
- source path/function;
- profile and deployment mode used.

## A.2 Semreh baseline

Public repository observations on September 3, 2026:

- current `master`: `40e30804b75f40ec5b19891c78e88b82d8b06e01`;
- `chore/consolidated-modernization`: `764ecd317d681e0119d90454cf5788d2e8c35b04`;
- prior audit base: `12bfd017998d0e359e84b55cec88987ba5c86456`;
- the modernization and release lineages have diverged.

The local audit also found a modified Hermes `package-lock.json`. Do not use that checkout for contract verification.

Before implementation, create one reviewed clean Semreh commit and record:

```text
SEMREH_MIGRATION_BASE_SHA=<sha>
HERMES_TESTED_SHA=29112bef099274229cadff79cdff7bf7b99c4b77
```

No protocol rule requires that the Semreh base first land on `master`.

## A.3 Key Semreh source references

Current retained patterns:

- `HermesMobile/Networking/APIClient.swift`
- `HermesMobile/Auth/AuthManager.swift`
- `HermesMobile/Auth/KeychainStore.swift`
- `HermesMobile/Models/ServerAccount.swift`
- `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`
- `HermesMobile/Features/Chat/ChatPendingActionCoordinator.swift`
- `HermesMobile/Features/Chat/OpenChatSessionStore.swift`
- `HermesMobile/Features/Chat/ChatViewModel.swift`
- `HermesMobile/Features/Chat/ChatView.swift`
- `HermesMobile/Features/SessionList/SessionListViewModel.swift`
- `HermesMobile/Networking/Endpoints.swift`
- `scripts/hermes_fixture.py`
- `CONTRACT_TESTS.md`
- `AGENTS.md`

Current direct-continuity/WebUI code is input for deletion and UI reuse, not the new protocol abstraction.

## A.4 Key pinned Hermes source references

Direct permalinks:

- [`hermes_cli/web_server.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/hermes_cli/web_server.py)
- [`hermes_cli/dashboard_auth/routes.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/hermes_cli/dashboard_auth/routes.py)
- [`hermes_cli/dashboard_auth/middleware.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/hermes_cli/dashboard_auth/middleware.py)
- [`hermes_cli/dashboard_auth/cookies.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/hermes_cli/dashboard_auth/cookies.py)
- [`plugins/dashboard_auth/basic/__init__.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/plugins/dashboard_auth/basic/__init__.py)
- [`hermes_cli/config_defaults.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/hermes_cli/config_defaults.py)
- [`tui_gateway/ws.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tui_gateway/ws.py)
- [`tui_gateway/server.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tui_gateway/server.py)
- [`tui_gateway/event_replay.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tui_gateway/event_replay.py)
- [`tui_gateway/methods_session.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tui_gateway/methods_session.py)
- [`tui_gateway/methods_prompt.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tui_gateway/methods_prompt.py)
- [`hermes_cli/web_routers/sessions.py`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/hermes_cli/web_routers/sessions.py)
- [`apps/shared/src/json-rpc-gateway.ts`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/apps/shared/src/json-rpc-gateway.ts)
- [`apps/desktop/src/api/sessions.ts`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/apps/desktop/src/api/sessions.ts)
- [`ui-tui/src/gatewayTypes.ts`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/ui-tui/src/gatewayTypes.ts)
- [`ui-tui/src/app/useInputHandlers.ts`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/ui-tui/src/app/useInputHandlers.ts)
- [`tests/fixtures/session-resume-active-turn.json`](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tests/fixtures/session-resume-active-turn.json)

## A.5 Isolated migration backend

Contract capture and destructive recovery tests run beside, never inside, the personal Hermes deployment:

```text
personal Hermes                 migration test Hermes
ordinary HERMES_HOME            disposable HERMES_HOME
personal state.db/memory        disposable state.db/memory
ordinary gateway/hostname       unique port and hostname/route
ordinary working directories    disposable tool cwd and profile HOME
```

Required controls:

- independent clean clone at the pinned SHA, not a worktree of the personal Hermes installation;
- container, VM, or dedicated restricted OS account with no mount or filesystem access to the personal Hermes home, personal Hermes checkout, or ordinary home directory;
- dedicated `HERMES_HOME` containing only test configuration and state;
- `terminal.cwd` pointed at a disposable workspace;
- `terminal.home_mode: profile`, with the profile home created before launching the server;
- persistent memory, user-profile memory, background memory/skill review, cron, and messaging integrations disabled by default;
- only the minimum provider credential injected for the smoke, never a copy of the full production `.env`;
- distinct backend port and HTTPS hostname/proxy route;
- preflight verification that existing Tailscale Serve and Funnel routes will not be reset or replaced;
- logs and artifacts scanned for passwords, cookies, tickets, and provider secrets.

`HERMES_HOME` isolates Hermes-owned state, but it is not sufficient by itself when local tool subprocesses inherit the OS user's real `HOME`; the explicit tool home and cwd controls close that gap. Any personal-deployment smoke is separately named, bounded, non-destructive by default, and requires Maurice's approval.

---

# B. Authentication contract

## B.1 Deployment assumptions

Supported initial production shape:

- HTTPS;
- one distinct hostname per configured Hermes server;
- root path;
- non-loopback/public authentication gate enabled;
- bundled password provider;
- stable signing secret;
- reverse proxy forwards WebSocket upgrades;
- proxy/uvicorn forwarded-header trust produces the correct public scheme and host.

Unsupported initial shape:

- static `?token=` over remote/public deployment;
- same hostname with multiple Hermes accounts distinguished only by port;
- relying on Host rewriting to keep a public deployment in loopback token mode;
- OAuth/native bearer login;
- arbitrary subpath installations without a captured integration test.

## B.2 Server configuration

Preferred password setup:

```yaml
dashboard:
  public_url: "https://hermes-maurice.example"
  basic_auth:
    username: "maurice"
    password_hash: "scrypt$..."
    secret: "<32+ random bytes; stable across restart>"
```

Generate the hash using the pinned environment:

```bash
python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('PW'))"
```

The signing secret is not the login password. It signs stateless session tokens. When absent, Hermes generates a process-local key and all sessions become invalid after restart.

The v3 integration test should use a non-production password and secret.

## B.3 Provider discovery

Request:

```http
GET /api/auth/providers
```

Verified response shape:

```json
{
  "providers": [
    {
      "name": "basic",
      "display_name": "…",
      "supports_password": true
    }
  ]
}
```

Behavior:

- 503 with no providers is a deployment/configuration failure.
- Semreh chooses a password-capable provider.
- When exactly one exists, choose it automatically.
- Multiple password providers may use a simple picker; no provider plugin framework is needed.

`GET /api/status` remains useful for:

- version/build information;
- `auth_required`;
- advertised provider names;
- deployment diagnostics.

It is not the canonical detailed provider-discovery route.

## B.4 Password login

Request:

```http
POST /auth/password-login
Content-Type: application/json
```

```json
{
  "provider": "basic",
  "username": "maurice",
  "password": "<entered, never persisted>",
  "next": ""
}
```

Success:

```json
{
  "ok": true,
  "next": "/"
}
```

The response sets HttpOnly session cookies.

Important failures:

- 401 invalid credentials;
- 404 unknown/non-password provider;
- 429 rate limited;
- 503 provider unavailable.

Do not store the password after the request completes.

## B.5 Cookies

Hermes session cookies:

- access token;
- refresh token;
- provider routing hint.

Properties:

- HttpOnly;
- SameSite=Lax;
- Secure when Hermes detects HTTPS;
- Path `/` at root, or the forwarded prefix at a subpath deployment;
- host-only because Hermes does not set a Domain attribute;
- access cookie follows access-token TTL;
- refresh cookie supports transparent rotation;
- names may receive `__Host-` or `__Secure-` prefixes based on deployment shape.

### Semreh caveat

Current `APIClient` uses:

```swift
configuration.httpCookieStorage = .shared
configuration.httpCookieAcceptPolicy = .always
configuration.httpShouldSetCookies = true
```

This is app-wide cookie storage. Two configured accounts on the same hostname can collide even when their ports differ.

v3 uses a distinct hostname per server instead of introducing custom per-server cookie persistence.

### Required tests

- Login response stores all expected cookies.
- Cookies are not exposed in logs/errors.
- Relaunch retains the authenticated session.
- Stable server secret preserves authentication across Hermes restart.
- Short test access-token TTL triggers transparent refresh.
- Rotated refresh cookie replaces the old value.
- A provider outage returns transient failure without clearing valid cookies.
- Structured session-expiry 401 clears/demotes auth.
- Logout clears all cookie-name variants at the correct Path.
- Removing one uniquely hosted server does not clear another host’s cookies.
- Secure/HttpOnly/Path are correct through the actual proxy.
- `X-Forwarded-Proto` and trusted proxy configuration are validated.

## B.6 Structured authentication failure

Hermes gated `/api/*` failures can return:

```json
{
  "error": "unauthenticated",
  "detail": "Unauthorized",
  "reason": "no_cookie",
  "login_url": "/login"
}
```

or:

```json
{
  "error": "session_expired",
  "detail": "Unauthorized",
  "reason": "invalid_or_expired_session",
  "login_url": "/login"
}
```

Semreh demotes auth only for:

- HTTP 401;
- recognized `error` value;
- matching active server.

Other cases:

- 403: surface as authorization/proxy/domain failure;
- 429: rate limit;
- 503: transient provider/server failure;
- unrecognized 401: preserve context and surface, unless a protected auth probe confirms expiry.

## B.7 WS ticket

Request, using session cookies:

```http
POST /api/auth/ws-ticket
```

Response:

```json
{
  "ticket": "<opaque>",
  "ttl_seconds": 30
}
```

Connect:

```text
wss://<host>/api/ws?ticket=<percent-encoded ticket>
```

Rules:

- ticket is single-use;
- ticket expires after 30 seconds;
- mint immediately before connection;
- never persist ticket;
- redact the full WebSocket URL;
- reconnect always mints a new ticket;
- a freshly minted ticket rejected as invalid may be retried once with a new ticket;
- ticket-mint 401 follows structured auth-expiry handling;
- ticket-mint 503 remains transient.

## B.8 Logout

Use:

```http
POST /auth/logout
```

Hermes clears plausible access, refresh, provider, and PKCE cookie variants. The route responds with a redirect to login.

Semreh should:

1. attempt server logout;
2. permit Set-Cookie deletion handling;
3. locally delete matching host/path cookies as defense in depth;
4. close the server runtime;
5. clear cached auth state;
6. never clear unrelated unique-host cookies.

---

# C. Runtime architecture and ownership

## C.1 `HermesServerRuntime`

Thin responsibilities:

- active `ServerAccount`;
- cookie-enabled REST client;
- gateway client;
- start/stop;
- connection state;
- one reconnect/recovery orchestration hook;
- server-switch teardown.

Not responsible for:

- credentials database;
- transcript storage;
- session list cache;
- view state;
- generic service lookup;
- secondary-feature caching.

## C.2 Existing `APIClient`

Retain:

- URL/request construction;
- cookie-enabled URLSession;
- tolerant JSON decoding;
- custom tunnel headers;
- cross-origin redirect stripping;
- error mapping;
- upload/download support;
- test injection.

Change:

- remove WebUI routes;
- remove direct-continuity sidecar;
- add official REST routes;
- add auth providers/password login/WS ticket/logout;
- classify structured auth failure;
- apply profile explicitly;
- preserve cookie handling.

A rename to `HermesRESTClient` is optional after cutover and is not a migration task.

## C.3 `HermesGatewayClient`

Use `URLSessionWebSocketTask`.

Own:

- socket generation;
- JSON-RPC request IDs;
- pending request correlation/timeouts;
- structured errors;
- raw event decoding;
- `gateway.ready`;
- heartbeat;
- fresh-ticket connection;
- connection state;
- recovery barrier primitive;
- optional sequence/epoch primitives;
- privacy-safe logging.

Do not own:

- durable session identity selection;
- transcript merge;
- automatic prompt retry;
- independent per-chat reconnect loops;
- WebUI fallback;
- one socket per session.

## C.4 `GatewayConversationController`

Replaces WebUI run orchestration.

Own:

- one `GatewaySessionBinding`;
- create/resume;
- prompt/interrupt/steer;
- attachment staging;
- event filtering;
- mapping gateway events into existing `ChatViewModel` callbacks;
- terminal canonical reconciliation;
- blocking prompt state;
- ambiguous-outcome reconciliation.

It can remain `@MainActor` initially because network read/decode occurs in the gateway actor.

## C.5 One recovery owner

Preferred lean shape:

- `HermesGatewayClient` exposes a barrier and transport primitives.
- `HermesServerRuntime` coordinates one reconnect generation.
- Existing `OpenChatSessionStore` supplies currently active/recoverable conversations.
- Each conversation controller performs its own durable resume and state application under the shared barrier.

Do not add a separate generic RecoveryManager unless this shape proves impossible.

---

# D. JSON-RPC contract

## D.1 Request

```json
{
  "jsonrpc": "2.0",
  "id": "semreh-42",
  "method": "session.resume",
  "params": {
    "session_id": "<durable stored id>",
    "profile": "default",
    "omit_messages": true
  }
}
```

## D.2 Success

```json
{
  "jsonrpc": "2.0",
  "id": "semreh-42",
  "result": {
    "session_id": "<runtime id>",
    "session_key": "<durable id>",
    "running": false,
    "messages": []
  }
}
```

Other paths can use `stored_session_id` for the durable identity.

## D.3 Error

```json
{
  "jsonrpc": "2.0",
  "id": "semreh-42",
  "error": {
    "code": 4007,
    "message": "session not found",
    "data": {}
  }
}
```

The Swift error retains:

- code;
- message;
- tolerant data;
- method name;
- request ID;
- server identity.

It excludes secrets and prompt content from normal logs.

## D.4 Event

```json
{
  "jsonrpc": "2.0",
  "method": "event",
  "params": {
    "type": "message.delta",
    "session_id": "<runtime id>",
    "seq": 17,
    "payload": {
      "text": "partial"
    }
  }
}
```

Unknown event types and unknown payload fields do not close the socket.

## D.5 Core RPC inventory

Required by Slice 1–3:

| RPC | Use |
|---|---|
| `gateway.ping` | JSON-RPC liveness |
| `session.create` | Create unpersisted runtime |
| `session.resume` | Bind durable session to live runtime/transport |
| `session.status` | Verify live state where available |
| `session.active_list` | Process-local overlay only |
| `prompt.submit` | Main turn |
| `session.interrupt` | Stop server-side run |
| `session.steer` | Mid-run steering/queue behavior |
| `approval.respond` | Resolve approval |
| `clarify.respond` | Resolve clarification |
| `sudo.respond` | Submit/cancel sudo password |
| `secret.respond` | Submit/cancel requested secret |
| `session.events.since` | Optional lossless reconnect replay |
| attachment RPCs | Image/file/PDF staging after exact capture |

Later direct features:

- session branch/compress;
- background prompts;
- commands;
- delegation/subagents;
- profiles/Bot Mode;
- groups/rooms.

---

# E. Session identity and lifecycle

## E.1 Fresh create

Pinned `session.create` returns:

```json
{
  "session_id": "<runtime id>",
  "stored_session_id": "<durable id>",
  "message_count": 0,
  "messages": [],
  "info": {
    "model": "…",
    "tools": {},
    "skills": {},
    "cwd": "…",
    "lazy": true
  }
}
```

Hermes intentionally does not create the durable DB row until the first prompt and starts building the agent asynchronously.

Semreh therefore keeps New Chat local until first send.

## E.2 Resume aliases

Resume results may expose:

- runtime `session_id`;
- durable `stored_session_id`;
- durable `session_key`;
- `resumed`;
- running/inflight state;
- messages or an omitted/deferred transcript;
- resolved continuation target.

Normalization:

```text
runtimeID = result.session_id

durable candidates =
  result.stored_session_id
  result.session_key
  result.resumed
  REST resolved session_id
```

Rules:

1. Prefer explicit durable aliases from the same successful response.
2. Permit requested ancestor → returned continuation.
3. Require simultaneous aliases to agree.
4. On alias conflict, stop applying live state and perform canonical REST resolution.
5. Never persist runtime ID.
6. Include profile in all binding/recovery operations.

## E.3 Resume fixture set

Capture from the pinned backend:

- fresh live create reused before persistence;
- live idle session;
- live running session;
- cold persisted session;
- deferred/omit-messages session;
- compression ancestor resolving to tip;
- profile-scoped session;
- stale/unknown stored ID;
- backend restart.

The pinned Hermes test fixture for an active turn includes:

```json
{
  "session_id": "rt-running",
  "session_key": "stored-running",
  "resumed": "stored-running",
  "running": true,
  "status": "working",
  "inflight": {
    "user": "current prompt",
    "assistant": "partial answer",
    "streaming": true
  }
}
```

## E.4 Local draft first send

Recommended state:

```text
LocalDraft
  text
  attachments
  profile/model/provider/reasoning/cwd
  optional live binding after create
```

First send:

1. Validate draft.
2. Ensure gateway ready.
3. `session.create`.
4. Store binding locally.
5. Stage attachments.
6. `prompt.submit`.
7. Convert navigation/cache key to stored ID.
8. Reconcile REST after terminal event.

Failures:

- create fails: retain draft, no session binding;
- attachment fails: retain draft and binding for retry;
- user abandons bound but unpersisted draft: `session.close`;
- app dies: no durable phantom; runtime cleanup policy handles the parked record.

---

# F. REST session and transcript contract

## F.1 Session list

Use official REST, not `session.active_list`, for durable discovery.

Expected route family:

```text
GET /api/sessions
GET /api/profiles/sessions
GET /api/profiles/sessions/sidebar
```

Select the smallest route needed by the retained Semreh session-list product.

Required fields include:

- durable session ID;
- title;
- profile;
- source;
- model;
- timestamps;
- message count;
- archived/pinned/read-only state;
- lineage metadata where available.

`session.active_list` may overlay working state after reconnect but never creates durable rows in the sidebar.

## F.2 Transcript tail

Required request:

```text
GET /api/sessions/<id>/messages
  ?profile=<profile>
  &limit=<bounded>
  &offset=0
  &order=latest
  &include_compacted=true
```

Required response handling:

```json
{
  "session_id": "<resolved current id>",
  "messages": [],
  "pagination": {
    "limit": 120,
    "offset": 0,
    "order": "latest",
    "returned": 0
  }
}
```

Semantics:

- server can resolve an old ID to the current resume/continuation tip;
- latest-page offset is measured backward from newest;
- rows inside the returned page are chronological;
- older page with offset `N` precedes the current newest `N` rows;
- older pages are prepended;
- `include_compacted=true` surfaces compacted display history while still excluding ordinary rewound/deleted rows;
- display projection fields must be honored.

## F.3 Required transcript tests

- fewer than one page;
- exactly one full page;
- multiple older pages;
- duplicate-free prepend;
- compacted rows;
- hidden/projected compaction summary;
- one continuation;
- multiple continuations;
- requested ancestor returns resolved tip;
- profile A and profile B same apparent title;
- read-only/subagent session;
- external message arrives between pages;
- active live tail reconciles with durable completion.

---

# G. Event mapping

## G.1 Core events

| Event | Semreh behavior |
|---|---|
| `gateway.ready` | Record capabilities, epoch, heartbeat/change-event support |
| `session.info` | Update binding/session/model/profile metadata |
| `session.usage` | Update token/cost context |
| `message.start` | Create/reset live assistant row |
| `message.delta` | Existing buffered text append |
| `message.interim` | Existing interim presentation |
| `message.complete` | Flush buffers, finalize, perform one canonical reconciliation |
| `thinking.delta` | Existing thinking/reasoning presentation |
| `reasoning.delta` | Existing reasoning buffer |
| `reasoning.available` | Mark reasoning availability |
| `status.update` | Working/idle/needs-input state |
| `tool.start` | Create/update tool by stable tool ID |
| `tool.progress` | Update existing tool, no duplicate card |
| `tool.complete` | Finalize tool/error/diff/duration |
| `tool.generating` | Optional lightweight status; safe to ignore initially |
| `todo.updated` | Update only if retained UI supports it |
| `background.complete` | Complete background work/Live Activity where applicable |
| `error` | Session-scoped failure |
| `sessions.changed` | Dirty/debounce according to active/idle policy |
| `cron.changed` | Invalidate task data |
| unknown | Privacy-safe log and ignore |

Before applying non-delta control events, flush pending text/reasoning buffers so UI order remains deterministic.

## G.2 Blocking events

### Approval

Event:

```text
approval.request
```

Response:

```text
approval.respond
  session_id
  request_id when supplied
  choice
  all only when explicitly intended
```

Minimum UI reuses current approval presentation.

### Clarification

Event:

```text
clarify.request
```

Response:

```text
clarify.respond
```

Support answer and explicit cancellation/empty response according to verified contract.

### Sudo

Event payload includes `request_id`.

Respond:

```json
{
  "request_id": "<id>",
  "password": "<masked value or empty to cancel>"
}
```

### Secret

Event payload includes:

- `request_id`;
- `prompt`;
- `env_var`.

Respond:

```json
{
  "request_id": "<id>",
  "value": "<masked value or empty to cancel>"
}
```

The first-party TUI uses empty password/value to cancel sensitive prompts. Semreh may use the same verified deterministic cancellation.

### Expiry

Handle `sudo.expire`, `secret.expire`, and relevant prompt expiry/stale responses by clearing matching request UI only.

## G.3 Blocking-event safety

- Key pending state by server + stored session + runtime generation + request ID.
- Never answer by “currently visible prompt” alone.
- Wrong-session/request response must fail.
- Empty-value cancellation must be explicit to the user.
- Never place password/secret values in observable debug descriptions, SwiftData, UserDefaults, crash metadata, or screenshots.
- If a minimal UI is unavailable, show an unsupported prompt and send verified cancellation; do not leave the run waiting.
- Handoff is allowed only after cross-client ownership is tested.

---

# H. Reconnect and recovery

## H.1 Canonical recovery first

Initial behavior:

```text
socket reconnect
→ fresh WS ticket
→ gateway.ready
→ session.resume(storedID, profile, omit_messages/defer_history as verified)
→ apply running/inflight/pending state
→ fetch compacted REST tail
→ reconcile
→ continue live events
```

This is simpler than implementing replay immediately.

## H.2 Ambiguous prompt delivery

A transport failure may occur after Hermes accepted `prompt.submit`.

Semreh must never automatically resend after an ambiguous failure.

State:

```text
submitted locally
→ connection lost before definitive response
→ verifying
→ reconnect/resume/canonical read
```

Resolve:

- durable user row exists or inflight user matches: accepted;
- terminal result exists: completed;
- server proves no accepted/inflight turn: offer manual Retry;
- uncertainty remains: continue verifying or show a non-destructive recovery message.

Use durable row IDs/stable user content only for constrained reconciliation. Never infer acceptance from a local socket error alone.

## H.3 Evidence gate for replay

Test canonical recovery during:

- text delta;
- reasoning delta;
- tool start;
- tool progress;
- tool complete;
- approval waiting;
- clarification waiting;
- sudo/secret waiting;
- just before `message.complete`;
- after server completion but before client receives terminal event;
- app suspension;
- app kill;
- backend restart.

Required outcome:

- correct durable transcript;
- correct working/idle state;
- no duplicate user turn;
- no permanently blocked prompt;
- acceptable visible continuity.

When all agreed requirements pass, replay may be deferred.

## H.4 Required replay transaction

When canonical recovery is insufficient:

1. A reconnect socket generation starts with a session-scoped recovery barrier.
2. Allow `gateway.ready` and sessionless global events.
3. Hold all session-scoped events connection-wide.
4. Compare `replay_epoch`.
5. Resume every active stored session.
6. Learn old/same/new runtime mappings.
7. If epoch and runtime ID are unchanged:
   - call `session.events.since(oldRuntimeID, lastSeenSeq)`;
   - apply missing events in sequence;
   - drop duplicates;
   - drain matching held live events.
8. If epoch changed, runtime changed, replay truncated, or the barrier overflows:
   - discard stale sequence state;
   - canonical REST/resume reconciliation;
   - apply only compatible held events or discard them.
9. Release the barrier.
10. Continue normal dispatch.

One runtime owner orchestrates this. The gateway client provides the primitive hold/replay operations.

## H.5 Barrier boundaries

- in-memory only;
- bounded by count and time;
- overflow fails to canonical reload rather than memory growth;
- unknown runtime IDs remain held until mappings are known;
- sessionless global events do not wait;
- auth failure aborts recovery;
- no nested per-conversation reconnect loops.

## H.6 Orphan-reap policy

Hermes defaults to a 20-second orphan grace, too short for normal iOS suspension.

Select after real testing:

- finite grace long enough for required background jobs is preferred;
- `0` disables reaping and requires verified idle runtime cleanup plus session-cap behavior;
- active runs are never closed merely because the app backgrounds;
- abandoned unpersisted drafts and idle evicted runtimes are explicitly closed when possible.

This is a deployment decision recorded in Slice 3 evidence.

## H.7 Host lifecycle and notification contract

The production host is part of the runtime contract:

- `hermes serve` runs under a reviewed service manager and starts after host reboot/login;
- the service restarts after an unexpected process failure;
- the Tailscale Serve or approved reverse-proxy route persists and forwards WebSocket upgrades;
- the host remains powered, awake, network-connected, and signed into Tailscale while unattended work is promised;
- loss of host or proxy reachability is shown as connectivity loss and never silently converted into logout.

The initial mobile promise is server continuity plus foreground catch-up. Hermes continues an accepted run across ordinary Semreh suspension, termination, and socket loss. When Semreh next becomes active it reconnects, resumes by durable identity, and canonically reconciles the result.

Immediate notification while iOS has suspended or terminated Semreh is not a v3 release requirement. Existing Live Activity updates are best effort under iOS execution limits. APNs or another notification relay remains deferred unless Maurice elevates it before the Slice 3 interface freeze.

---

# I. `sessions.changed` policy

Hermes emits `sessions.changed` with an empty payload. The state DB can change throughout a turn.

State machine:

| Visible state | Action |
|---|---|
| Local run active | Mark sidebar dirty; debounce list refresh; no visible transcript reload |
| Matching terminal event | One canonical transcript reconciliation |
| Visible chat idle | Debounced transcript refresh |
| Composer has draft | Preserve draft; refresh transcript without resetting composer or defer |
| Destructive action armed | Mark dirty; refresh/revalidate target before submit |
| Chat not visible | Refresh when opened or on ordinary list cache policy |
| Socket recovering | Recovery flow owns reconciliation; suppress parallel refresh |

Do not create an origin detector.

---

# J. Attachments and media

## J.1 Principle

An iPhone file path is not a path on the Hermes host.

Remote attachment staging uses bytes or an official upload route verified at the pinned release.

## J.2 Required captures

Capture exact contracts for:

- `image.attach_bytes`;
- generic text/code file;
- PDF;
- filename sanitization;
- supported MIME/extension behavior;
- size limits;
- unsupported file;
- attachment cancellation;
- result reference metadata.

Do not invent one generic attachment DTO before these shapes are captured.

## J.3 Send sequence

```text
local draft
→ session.create when needed
→ encode/prepare off main actor
→ stage every attachment
→ prompt.submit
```

When staging fails:

- do not submit prompt;
- preserve text and remaining attachments;
- show which attachment failed;
- allow retry/remove;
- close unpersisted runtime only if the draft is abandoned.

## J.4 Authenticated media

- same-origin media uses cookie-authenticated REST session;
- external media never receives custom tunnel headers or cookies;
- Range requests remain supported;
- ticket values never appear in media URLs;
- cache keys include server hostname + profile + durable session + resource path.

---

# K. Current feature disposition inventory

This is a decision checklist, not a requirement to reproduce every feature.

| Current Semreh/WebUI area | Direct-Hermes disposition |
|---|---|
| health/auth status | Replace with `/api/status`, providers, password login, auth/me, logout |
| official continuity sidecar | Delete |
| session list/detail/messages | Official REST; core |
| session SSE | Delete; gateway events + canonical REST |
| chat start/stream/status/cancel | Gateway prompt/events/interrupt |
| steering/queue | Gateway |
| approval | Gateway |
| clarification | Gateway |
| sudo/secret | Gateway deterministic handling |
| native-auth components | Re-evaluate; remove/hide when WebUI-specific |
| website-login workflow | Verify direct equivalent; otherwise remove/hide |
| background prompts | Direct RPC/event if retained |
| models/providers/reasoning | Official REST/RPC |
| profiles | Official REST/RPC; core metadata, richer Bot UI later |
| commands/goal/BTW | Verify direct command/RPC; no WebUI route-name preservation |
| workspace/project selection | Direct cwd/project semantics |
| directory/file/media | Official REST |
| Git | Migrate only retained mobile actions |
| cron/tasks | Official REST/RPC; secondary |
| skills | Official REST/RPC; secondary |
| memory | Official REST; secondary |
| Insights/analytics | Official REST if retained |
| Kanban | Plugin/direct APIs if retained; not core |
| transcribe/TTS | Official audio REST |
| updates/admin | Defer/remove unless actively used |
| Teams placeholder | Independent product work; not migration |
| Share extension/App Intents | Rewire only retained actions; no WebUI fallback |
| Live Activities | Gateway-run state + durable deep link; no push promise while suspended |

For each row, Maurice records:

```text
migrate | remove | defer-and-hide
owner
target slice
required direct contract
```

---

# L. Suggested file changes

## L.1 Add, only as needed

```text
HermesMobile/Runtime/HermesServerRuntime.swift
HermesMobile/Networking/Gateway/HermesGatewayClient.swift
HermesMobile/Networking/Gateway/GatewayWire.swift
HermesMobile/Features/Chat/GatewayConversationController.swift

HermesMobileTests/HermesGatewayClientTests.swift
HermesMobileTests/GatewayConversationControllerTests.swift
HermesMobileTests/DirectHermesContractTests.swift
```

Keep payload DTOs together initially. Split only when navigation becomes difficult.

## L.2 Modify

```text
AuthManager.swift
APIClient.swift
Endpoints.swift
ServerAccount.swift
ContentView/AppShell
Session.swift
ChatMessage.swift
ToolCall.swift
ChatViewModel.swift
OpenChatSessionStore.swift
SessionListViewModel.swift
ChatPendingActionCoordinator.swift
Live Activity / App Intent / Share wiring as retained
```

## L.3 Delete by final cutover

```text
OfficialHermesContinuity.swift
OfficialContinuityConfigurationStore
official sidecar URL/API key fields
WebUI chat stream coordinator implementation
WebUI SSE cursor/replay persistence
approval/clarification SSE and polling
WebUI auth endpoints and password body
WebUI fixture/watch/pin logic
unused SSE dependency and tests
WebUI-only endpoint DTOs and setup docs
```

Do not delete useful presentation components merely because their current data source is WebUI.

---

# M. Deletion searches

Before final cutover, search the repository for:

```text
hermes-webui
webui
OfficialHermesContinuity
OfficialContinuityConfigurationStore
officialAPI
official_
/api/chat/
/api/auth/login
/api/approval/
/api/clarify/
chatStream
stream_id
activeStreamID
SSE
EventSource
Last-Event-ID
SessionEventStreamCoordinator
approvalStream
clarifyStream
lostWorkerBookkeeping
```

Each remaining result must be one of:

- a historical migration note;
- an intentionally retained non-chat SSE feature with a direct Hermes contract;
- a test proving absence/deletion.

No unexplained production match is accepted.

Also inspect dependencies for a now-unused SSE/EventSource package.

---

# N. Verification fixtures and scenarios

## N.1 Slice-gate fixture bundle

Store sanitized fixtures under a test resource directory:

```text
auth-providers.json
auth-401-unauthenticated.json
auth-401-session-expired.json
ws-ticket.json
gateway-ready.json
session-create.json
session-resume-live.json
session-resume-cold.json
session-resume-continuation.json
message-delta.json
tool-start.json
tool-complete.json
message-complete.json
approval-request.json
clarify-request.json
sudo-request.json
secret-request.json
sessions-changed.json
transcript-tail-compacted.json
transcript-older-page.json
```

A fixture header or companion manifest records:

```json
{
  "hermes_sha": "29112bef099274229cadff79cdff7bf7b99c4b77",
  "captured_at": "…",
  "source": "real disposable hermes serve",
  "profile": "default",
  "sanitized": true
}
```

## N.2 High-risk scenarios

### Authentication

- invalid provider;
- invalid username/password;
- rate limit;
- successful login;
- relaunch;
- access expiry + refresh;
- server restart with stable secret;
- server restart without stable secret in a negative harness;
- logout;
- proxy 403;
- provider 503;
- ticket reuse;
- ticket expiry;
- reconnect ticket.

### Identity

- fresh create;
- unpersisted live resume;
- live running resume;
- cold resume;
- alias agreement;
- alias conflict;
- compression ancestor;
- profile collision;
- stale runtime.

### Streaming

- text;
- reasoning;
- successful tool;
- failed tool;
- inline diff;
- error completion;
- interrupt;
- steer/queue;
- two interleaved sessions.

### Recovery

- disconnect before write;
- after write/before response;
- during text;
- during reasoning;
- during tool;
- during blocking prompt;
- after terminal persistence/before terminal event;
- app background;
- app kill;
- backend restart;
- optional replay truncation/epoch change.

### Transcript

- compacted history;
- multiple pages;
- continuation;
- external append;
- duplicate prevention;
- canonical live-row replacement.

### Blocking prompts

- answer;
- deny/cancel;
- wrong request;
- wrong session;
- expiry;
- reconnect while waiting;
- sensitive-value log/storage scan.

### Attachments

- image;
- text/code;
- PDF;
- near limit;
- over limit;
- unsupported;
- failure before prompt;
- canonical history reload.

## N.3 Risk-based command cadence

Per focused PR:

- focused tests;
- build when compile surface changed.

Per slice gate:

- all focused tests;
- full XCTest;
- signed Simulator launch;
- real pinned-backend verification;
- independent reviewer rerun;
- actual proxy/device tests where relevant.

Do not rerun expensive clean-room gates for a documentation-only or one-DTO change unless it changes a passed shared contract.

## N.4 Verification report

```markdown
## Verification

Semreh commit:
Hermes commit:
Slice:
Outcome:

Contract source:
Captured fixtures:

Commands and results:
- focused:
- full:
- simulator:
- real backend:
- proxy:
- device:

Security:
- token/password/ticket search:
- secret/sudo persistence search:

Recovery/performance evidence:

Old path removed or disabled:

Reviewer:
Result:

Approved deviations:
```

---

# O. Agent workflow

## O.1 Issue boundaries

One issue should produce one observable outcome.

Good:

- “Password-cookie login and WS ticket reconnect work through the production tunnel.”
- “Compacted latest transcript pages prepend without duplicates.”
- “Ambiguous prompt acceptance never causes automatic resend.”

Bad:

- “Build gateway.”
- “Migrate chat.”
- “Make direct Hermes production ready.”

## O.2 Parallelism

Safe parallel work:

- contract capture;
- auth UI/client;
- isolated gateway wire tests;
- REST transcript mapping;
- secondary-feature disposition.

Serialize:

- shared auth/session interfaces;
- `ChatViewModel`;
- conversation controller;
- runtime/durable identity;
- reconnect/replay;
- destructive edits.

At most one agent owns a central responsibility at once.

## O.3 Reviewer focus

The reviewer actively searches for:

- hardcoded/unverified shapes;
- WebUI fallback;
- shared-cookie host collision;
- token/ticket logging;
- 403 incorrectly treated as logout;
- runtime ID persistence;
- prompt auto-retry;
- duplicate reconnect state machines;
- visible transcript reload loops from `sessions.changed`;
- ignored blocking events;
- destructive ordinal fallback;
- tests that prove local UI state but not server state.

---

# P. Open decisions with explicit deadlines

These are the only meaningful open implementation decisions after v3 approval.

| Decision | Resolve by | Default |
|---|---|---|
| `SEMREH_MIGRATION_BASE_SHA` | Slice 1 start | One clean reviewed retained-product commit |
| Password-provider selection UI when multiple exist | Slice 1 | Auto-select exactly one; simple picker only when needed |
| Cookie topology beyond unique hostname | After real need | Unsupported; no custom cookie store |
| Mobile orphan grace | Slice 3 | Finite measured grace preferred |
| Is sequence replay required? | Slice 3 recovery matrix | Canonical recovery first |
| Which secondary features survive? | Before Slice 4 | Maurice migrate/remove/defer-and-hide |
| First-send prewarming | After Slice 2 metrics | Local draft; create on first send |
| OAuth/native bearer | Post-migration | Deferred |
| Guaranteed completion notification while Semreh is suspended/terminated | Before Slice 3 interface freeze if elevated | Deferred; foreground canonical catch-up is required |
| Friends/teams/Bot Mode | Post-migration | Deferred |

Any additional “open architecture question” should be challenged as possible scope growth.

---

# Q. Final direct-Hermes definition

The migration is complete when:

```text
Hermes owns
- durable sessions and transcripts
- agent execution and runtime state
- models, profiles, tools, prompts
- blocking approval/clarification/sudo/secret state
- files, cron, memory, skills, Git, and configuration

Semreh owns
- native iOS presentation
- local drafts
- cached read-only projections
- scroll/read state
- appearance/preferences
- server registry
- native lifecycle and integrations

REST owns
- canonical durable reads and resource mutations

The gateway socket owns
- live RPC and events
```

The release candidate must work with `hermes-webui` entirely absent.
