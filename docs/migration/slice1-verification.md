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

## Still required before declaring Slice 1 passed

- Separate test HTTPS hostname and proxy route; Secure/HttpOnly/Path verification
  through that actual route, with same-host/different-port explicitly unsupported.
- Real app termination/relaunch without password re-entry; HTTP client recreation
  is not a substitute.
- Remote direct turn/interrupt and reconnect through the deployed route.
- Independent reviewer rerun from a clean checkout, including secret/artifact scan.

No Slice 2 work, push, PR, release, or personal-route changes are authorized.
