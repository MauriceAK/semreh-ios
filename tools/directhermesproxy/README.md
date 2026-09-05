# Disposable Slice 1 HTTPS proxy

Test infrastructure only; not an iOS dependency or a new Hermes transport layer.
Uses Tailscale `tsnet` v1.102.2 and the Go standard reverse proxy. It registers a
separate `semreh-slice1-test` node, stores state beneath the disposable runtime,
listens only on tailnet TCP 443, and forwards only to `http://127.0.0.1:18791`.
It does not open host TCP 443, a TUN device, a shared control socket, or Funnel.

Why not a second plain userspace `tailscaled`? In the installed 1.102.2 source,
`wgengine/netstack/netstack.go` forwards unhandled node-IP connections to the same
localhost port. That could expose unrelated local services. `tsnet/tsnet.go`
instead rejects unregistered TCP/UDP flows; we install no fallback handler.
No personal Tailscale configuration or tailnet-wide policy edits are required.

Sources:

- [tsnet API](https://tailscale.com/docs/reference/tsnet-server-api)
- [Pinned tsnet source](https://github.com/tailscale/tailscale/blob/eb67e5dcbe145d63e1128b9b4b630f8a82da101f/tsnet/tsnet.go)
- [Pinned plain-daemon forwarding](https://github.com/tailscale/tailscale/blob/eb67e5dcbe145d63e1128b9b4b630f8a82da101f/wgengine/netstack/netstack.go)

## Local build

Dedicated toolchain: `workspace/semreh-slice1-go/go/bin/go` (1.26.5).
Official `go1.26.5.darwin-arm64.tar.gz` SHA256:
`efb87ff28af9a188d0536ef5d42e63dd52ba8263cd7344a993cc48dd11dedb6a`.
No global Go installation or shell-profile change was made.

From this directory, use the dedicated Go binary with `GOENV=off`,
`GOTOOLCHAIN=local`, `GOPROXY=https://proxy.golang.org`, `GOMAXPROCS=2`, and
GOCACHE/GOPATH/GOMODCACHE under `workspace/semreh-slice1-go`. Run:

```sh
go test ./...
go build -o /Users/maurice/workspace/semreh-slice1-tools/bin/direct-hermes-https .
```

Start from the main repository using the dedicated Python venv:

```sh
python scripts/direct_hermes_https.py
```

The launcher validates the disposable backend configuration, then uses an explicit
environment without Tailscale auth keys or other inherited credentials. Tailscale
telemetry is disabled. Enrollment uses a human-operated browser link; do not copy
personal Tailscale state. Private node keys/certificates stay in
`workspace/semreh-slice1-runtime/tailscale-proxy`, never the repository.

HTTPS certificates must be enabled for the selected tailnet. If that needs a
tailnet-wide setting change, pause for Maurice rather than changing it silently.
Certificates use a `*.ts.net` name; certificate transparency can disclose that
hostname. The generic test name is deliberate.

## Verification boundary

Unit tests cover fixed backend targeting, canonical forwarding headers, rejection
of wrong Host values, and bounded errors. They do not prove remote connectivity,
TLS issuance, cookie attributes, WebSocket upgrades, or iOS relaunch persistence.
Enrollment/listener readiness is not an HTTPS gate pass.

After enrollment, inspect only this node's runtime `endpoint.json`; update the
disposable Hermes public origin deliberately and adapt its validation marker and
HTTPS probes together. Never bypass certificate verification with `-k`.
Confirm an unrelated port is rejected using a disposable canary listener—not by
probing a personal service. Stop only this foreground test process when done.
