package main

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestProxyOnlyUsesFixedBackendAndCanonicalForwarding(t *testing.T) {
	const host = "semreh-slice1-test.example.ts.net"
	called := false
	handler := testProxy(host, roundTripFunc(func(r *http.Request) (*http.Response, error) {
		called = true
		if r.URL.Scheme != "http" || r.URL.Host != "127.0.0.1:18791" || r.Host != host {
			t.Fatal("proxy destination escaped the disposable backend")
		}
		if r.URL.Path != "/api/auth/ws-ticket" || r.Method != "POST" {
			t.Fatal("request changed")
		}
		if r.Header.Get("X-Forwarded-Proto") != "https" || r.Header.Get("X-Forwarded-Host") != host {
			t.Fatal("untrusted forwarding headers survived")
		}
		if r.Header.Get("Tailscale-User-Login") != "" {
			t.Fatal("spoofed identity survived")
		}
		if r.Header.Get("Forwarded") != "" || r.Header.Get("X-Forwarded-For") != "192.0.2.1" {
			t.Fatal("spoofed forwarding chain survived")
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("ok"))}, nil
	}))
	r := httptest.NewRequest("POST", "https://"+host+"/api/auth/ws-ticket", nil)
	r.Header.Set("X-Forwarded-Proto", "http")
	r.Header.Set("X-Forwarded-Host", "other.test")
	r.Header.Set("Tailscale-User-Login", "spoofed")
	r.Header.Set("Forwarded", "for=198.51.100.10")
	r.Header.Set("X-Forwarded-For", "198.51.100.10")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if !called || w.Code != 200 {
		t.Fatal("expected fixed-backend forwarding")
	}
}

func TestUnexpectedHostNeverReachesBackend(t *testing.T) {
	handler := testProxy("semreh-slice1-test.example.ts.net", roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("unexpected hostname reached backend")
		return nil, errors.New("unexpected")
	}))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "https://other.test/", nil))
	if w.Code != 421 {
		t.Fatal("unexpected hostname was not rejected")
	}
}

func TestBackendErrorsDoNotEchoRequestSecrets(t *testing.T) {
	const host = "semreh-slice1-test.example.ts.net"
	handler := testProxy(host, roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("test-only-secret-must-not-appear")
	}))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "https://"+host+"/api/ws?ticket=test-only-secret-must-not-appear", nil))
	if w.Code != 502 || strings.Contains(w.Body.String(), "test-only-secret-must-not-appear") {
		t.Fatal("backend error was not bounded")
	}
}
