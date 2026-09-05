# Slice 1 verification — in progress

Slice 1 has **not passed**. This is a contract/authentication spike, not the
production UI cutover. The retained app still uses WebUI until later authorized
slices replace those owners. No direct-to-WebUI fallback was added.

## Scope and provenance

- Product base: `40e30804b75f40ec5b19891c78e88b82d8b06e01`.
- Independent clean Hermes source: `29112bef099274229cadff79cdff7bf7b99c4b77`.
  Sparse checkout excludes only case-colliding contributor files on macOS.
- Approved same-user separate-folder deviation applies; this is not an OS sandbox.
- Runtime root: `workspace/semreh-slice1-runtime`; explicit home, tools, logs,
  configuration, virtual environment and loopback port 18791. No personal Hermes
  files, credentials, services or Tailscale routes were used.
- Only the `clarify` toolset is exposed. The local deterministic model on 18792
  returns a fixture response, never tool calls. This does not test an external LLM.
- `configured_source_pin` in captures is launcher/source provenance, not a SHA
  independently returned by HTTP. Root checked process 42915's command, executable,
  loopback listener, cwd and open state DB/logs on September 4; all were test paths.
- Backend restart was operator-observed: owned process 41796 stopped (143), followed
  by owned process 42915 with the same private signing secret; restored cookies
  authenticated. The restart script alone proves client recreation/refresh, not
  the process replacement. A reviewer must repeat the restart themselves.

## Recorded local checks

- Signed baseline: 1,878 passed, zero failed/skipped on a newly created iPhone 17e
  iOS 26.5 simulator, UUID `D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263`.
- Final signed regression: 1,899 passed, zero failed, one intentional opt-in live
  smoke skip. Latest result bundle: `slice1-text-frame-regression.xcresult`. Earlier smoke
  test build attempts failed on closure capture and a missing getter return; both
  corrected before this successful run. Existing baseline warnings remain.
- Python auth capture: canonical provider discovery, wrong/right password,
  protected REST, ticket use, ticket-reuse HTTP 403, fresh ticket reconnect,
  ready/ping and logout/protected rejection.
- Python turn capture: terminal completion plus exactly one durable user and one
  assistant row; interrupt terminal event plus server `Agent Running: No`.
- Python refresh capture: private cookie restoration, real 60-second token expiry,
  access and refresh rotation. Temporary private cookie jar removed after success.
- First real iOS smoke authenticated and received ready, then failed at ping:
  client sent binary JSON while pinned `tui_gateway/ws.py` reads text frames.
  Client now sends text; fake socket rejects binary to prevent regression.
  `slice1-live-ios.xcresult` retains this failed run; it is not passing evidence.
- Corrected real iOS smoke passed 1/1, no skip: `slice1-live-ios-text.xcresult`.
  It exercised native APIClient/URLSession and HermesGatewayClient against the real
  pinned backend: auth, protected REST, ready/ping, create/submit, exactly one durable
  user+assistant pair, matching interrupted terminal event, server non-running,
  session close, logout and protected rejection. No external LLM was used.
- Artifact scan passed for 17,926 files including exported console diagnostics from
  both live runs and the final full suite. No known test secrets or obvious bearer
  formats found; this heuristic cannot prove absence of every arbitrary secret.
- Owned backend/model-fixture processes were stopped after local verification.
  Test source/state and result artifacts remain for resumption; personal services
  were not touched. The temporary private restart-cookie jar was removed and can
  be recreated by signing into the disposable test backend.
- Fixtures are local HTTP with an explicit public Host header. They do **not**
  verify Secure cookies, production proxy handling, or iOS persistence.

## Reproduction

The scripts deliberately use fixed disposable paths. Read the launcher and approved
deviation before running; do not substitute personal deployment paths. Provision
the independent clone/venv first, then use `direct_hermes_probe.py init` only for a
new runtime. Run `validate`, the model fixture and `serve` in owned foreground
processes. Never use the broad Hermes stop command. Restart only the exact test
PID after verifying its command and listener.

With the dedicated venv Python, from the migration repository:

```sh
python scripts/direct_hermes_probe.py validate
python scripts/direct_hermes_capture.py
python scripts/direct_hermes_turn_capture.py
python scripts/direct_hermes_restart_capture.py prepare
# Operator: restart the exact owned backend with stable secret and test TTL 60.
python scripts/direct_hermes_restart_capture.py verify
```

Signed simulator command (never use a personal/reused simulator):

```sh
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263' \
  -derivedDataPath /Users/maurice/workspace/semreh-slice1-build \
  -parallel-testing-enabled NO -jobs 2 -resultBundlePath <new-result-path>
```

Result bundles are local under `workspace/semreh-slice1-evidence`, not committed.
Do not log credential bodies, tickets, cookie values, or raw live network errors.

For the opt-in live smoke, after the signed build above:

```sh
python scripts/direct_hermes_ios_smoke.py
xcodebuild test-without-building \
  -xctestrun /Users/maurice/workspace/semreh-slice1-build/Build/Products/SemrehSlice1Live.xctestrun \
  -destination 'platform=iOS Simulator,id=D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263' \
  -parallel-testing-enabled NO -resultBundlePath <new-live-result-path>
python scripts/direct_hermes_audit_artifacts.py
```

The generated run file contains only opt-in flags and the fixed private credentials
file path, not credential values. The smoke uses ephemeral cookies deliberately;
it does not prove production cookie persistence across app relaunches.

## HTTPS route verification — September 4

The separate enrolled node is `semreh-slice1-test.tailda8427.ts.net`. Only the
disposable runtime's public URL changed. No personal route or Hermes state changed.
Initial TLS connection timed out during setup; subsequent certificate verification
passed without bypass flags. With backend stopped the proxy returned bounded HTTP
502; after starting the backend, the real HTTPS/WSS probes passed.

- `slice1-https-auth.json`: discovery, wrong/right credentials, protected REST,
  `__Host-` cookies with Secure/HttpOnly/Path=/ and no Domain attribute, logout
  clearing the jar, ticket reuse HTTP403, fresh ticket reconnect, ready and ping.
  The first HTTPS assertion incorrectly expected bare localhost cookie names;
  corrected against pinned `dashboard_auth/cookies.py`, then reran successfully.
- `slice1-https-turn.json`: actual proxy/WSS transport, exact durable turn counts,
  matching interrupted terminal event and server non-running state. Model remains
  the local deterministic fixture, not an external provider.
- `slice1-https-restart.json`: operator stopped exact owned backend PID37072
  (exit143), relaunched PID37774 with the same signing secret, then the restored
  jar passed protected REST. Actual 60-second expiry rotated both access and
  refresh cookies over HTTPS. The private temporary jar was removed afterward.
- A disposable listener on localhost18793 was reachable locally but a connection
  to test-node port18793 was refused. No personal service was probed.
- Three Go proxy tests passed, including additional spoofed Forwarded/XFF inputs.
  Standard reverse proxy strips these before constructing canonical forwarding.
- The restart preflight initially rejected TIME_WAIT sockets after backend exit.
  Added SO_REUSEADDR to match server bind behavior; a disposable live-listener
  check still failed bind as required. No listener was evicted.
- Signed regression `slice1-https-regression.xcresult`: 1899 passed, zero failures,
  four explicit opt-in skips (full smoke and three cookie-process phases).
- Native HTTPS/WSS smoke `slice1-live-ios-https.xcresult`: one passed, zero skipped
  or failed. The native client completed the real-route direct turn and interrupt.
- Hosted cookie login `slice1-cookie-login.xcresult` and restore
  `slice1-cookie-restore.xcresult`: one passed each, zero skipped or failed.
  Login host PID41841 exited; restore host PID42528 successfully made the protected
  request without reading credentials or calling password login. Exported console
  diagnostics record both PIDs. This proves the default production transport's
  shared cookies survive actual hosted app-process termination and relaunch.
- Hosted cookie logout `slice1-cookie-logout.xcresult`: one passed, zero skipped or
  failed, including protected request rejection after logout. Exported diagnostics
  for all native HTTPS/cookie runs are included in the artifact scan.

Run HTTPS Python probes with `SEMREH_SLICE1_HTTPS=1`. Local mode is retained for a
runtime configured with the original HTTP public URL; auth capture refuses a mode
that does not match the deployment. The fixed HTTPS origin must match the enrolled
node's private endpoint record; arbitrary origins are not accepted.

For native HTTPS smoke, generate the run file with
`python scripts/direct_hermes_ios_smoke.py --https`, then use the existing signed
`test-without-building` command above. For cookie process tests, use
`--https --cookie-phase login`, then `restore`, then `logout`, each followed by a
separate `test-without-building` invocation and unique result bundle. Restore has
no credentials environment entry and never reads a password or calls login. It
requires a different host process ID than login and uses APIClient's production
default cookie-enabled session. These are hosted app-process transport tests,
not a production login UI cutover or proof of the later AuthManager migration.

Same-host/different-port account separation remains explicitly unsupported:
cookies are host-scoped; every logical server must have its own hostname.

## Still required before declaring Slice 1 passed

- Independent reviewer rerun from a clean checkout, including secret/artifact scan.

No Slice 2 work, push, PR, release, or personal-route changes are authorized.
