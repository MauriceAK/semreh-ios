// Test infrastructure only. This module is never linked into the iOS app.
package main

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"tailscale.com/tsnet"
)

const stateDir = "/Users/maurice/workspace/semreh-slice1-runtime/tailscale-proxy"
const hostname = "semreh-slice1-test"
const upstream = "http://127.0.0.1:18791"

func testProxy(host string, transport http.RoundTripper) http.Handler {
	target, _ := url.Parse(upstream)
	if transport == nil {
		transport = &http.Transport{Proxy: nil, ResponseHeaderTimeout: 30 * time.Second}
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			r.Out.Host = host
			r.SetXForwarded()
			r.Out.Header.Set("X-Forwarded-Proto", "https")
			r.Out.Header.Set("X-Forwarded-Host", host)
			for name := range r.Out.Header {
				if strings.HasPrefix(strings.ToLower(name), "tailscale-") {
					r.Out.Header.Del(name)
				}
			}
		},
		Transport: transport,
		ErrorLog:  log.New(io.Discard, "", 0),
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, "Disposable test backend unavailable", http.StatusBadGateway)
		},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != host && r.Host != host+":443" {
			http.Error(w, "Unexpected test hostname", http.StatusMisdirectedRequest)
			return
		}
		proxy.ServeHTTP(w, r)
	})
}

func run() error {
	// No shared Tailscale socket, personal state, auth key or system route setup.
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return err
	}
	resolved, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		return err
	}
	if resolved != stateDir {
		return os.ErrPermission
	}
	if err := os.Chmod(stateDir, 0700); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	s := &tsnet.Server{Dir: stateDir, Hostname: hostname}
	defer s.Close()
	status, err := s.Up(ctx)
	if err != nil {
		return err
	}
	if status.Self == nil {
		return os.ErrInvalid
	}
	host := strings.TrimSuffix(status.Self.DNSName, ".")
	if !strings.HasPrefix(host, hostname+".") || !strings.HasSuffix(host, ".ts.net") {
		return os.ErrInvalid
	}
	// tsnet rejects unregistered TCP/UDP ports; no fallback handler is installed.
	// ListenTLS is tailnet-only: no public Funnel, kernel TUN, or host 443 listener.
	ln, err := s.ListenTLS("tcp", ":443")
	if err != nil {
		return err
	}
	defer ln.Close()
	endpoint, _ := json.MarshalIndent(map[string]string{"origin": "https://" + host, "upstream": upstream}, "", "  ")
	if err := os.WriteFile(filepath.Join(stateDir, "endpoint.json"), endpoint, 0600); err != nil {
		return err
	}
	log.Printf("Test-only HTTPS listener ready: https://%s", host)
	server := &http.Server{Handler: testProxy(host, nil), ReadHeaderTimeout: 15 * time.Second,
		ErrorLog: log.New(io.Discard, "", 0)}
	go func() { <-ctx.Done(); _ = server.Close() }()
	err = server.Serve(ln)
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}

func main() {
	if err := run(); err != nil {
		// No request URL, cookie, password or provider credential in application logs.
		log.Print("Test HTTPS proxy stopped before readiness or failed; inspect setup status.")
		os.Exit(1)
	}
}
