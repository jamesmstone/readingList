package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T, origins ...string) *server {
	t.Helper()
	script := filepath.Join(t.TempDir(), "append.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return &server{append: script, timeout: time.Minute, origins: origins}
}

func postForm(t *testing.T, s *server, referer string, extra url.Values) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{"url": {"https://example.com/a"}, "title": {"A"}}
	for k, v := range extra {
		form[k] = v
	}
	req := httptest.NewRequest(http.MethodPost, "http://hermanii:8108/add", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	w := httptest.NewRecorder()
	s.add(w, req)
	return w
}

func TestAddRedirectsBack(t *testing.T) {
	const site = "https://read.jamesst.one"

	tests := []struct {
		name     string
		origins  []string
		referer  string
		extra    url.Values
		wantLoc  string
		wantCode int
	}{
		{"referer from a known origin", []string{site}, site + "/some/page?x=1", nil, site + "/some/page?x=1", 303},
		{"referer from the listener itself", nil, "http://hermanii:8108/form", nil, "http://hermanii:8108/form", 303},
		{"no referer lands on the first origin", []string{site}, "", nil, site + "/", 303},
		{"no referer and no origins lands on root", nil, "", nil, "/", 303},
		{"foreign referer is ignored", []string{site}, "https://evil.example/page", nil, site + "/", 303},
		{"lookalike host is ignored", []string{site}, "https://read.jamesst.one.evil.example/p", nil, site + "/", 303},
		{"userinfo cannot smuggle a host", []string{site}, "https://read.jamesst.one@evil.example/p", nil, site + "/", 303},
		{"scheme mismatch is ignored", []string{site}, "http://read.jamesst.one/p", nil, site + "/", 303},
		{"protocol-relative path is ignored", []string{site}, site + "//evil.example/p", nil, site + "/", 303},
		{"fragment from the form restores position", []string{site}, site + "/", url.Values{"fragment": {"october-2026"}}, site + "/#october-2026", 303},
		{"fragment survives with no referer", []string{site}, "", url.Values{"fragment": {"october-2026"}}, site + "/#october-2026", 303},
		{"unsafe fragment is dropped", []string{site}, site + "/", url.Values{"fragment": {"x\r\nSet-Cookie: a=b"}}, site + "/", 303},
		{"fragment cannot carry a URL", []string{site}, site + "/", url.Values{"fragment": {"//evil.example"}}, site + "/", 303},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w := postForm(t, newTestServer(t, tt.origins...), tt.referer, tt.extra)
			if w.Code != tt.wantCode {
				t.Fatalf("status = %d, want %d: %s", w.Code, tt.wantCode, w.Body)
			}
			if got := w.Header().Get("Location"); got != tt.wantLoc {
				t.Fatalf("Location = %q, want %q", got, tt.wantLoc)
			}
		})
	}
}

func TestAddDoesNotRedirectOnFailure(t *testing.T) {
	s := newTestServer(t)
	if err := os.WriteFile(s.append, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	w := postForm(t, s, "http://hermanii:8108/form", nil)
	if w.Code != http.StatusInternalServerError || w.Header().Get("Location") != "" {
		t.Fatalf("got %d with Location %q", w.Code, w.Header().Get("Location"))
	}
}

func TestAddJSONStillAnswersWithBody(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/add", strings.NewReader(`{"url":"https://example.com/a","title":"A"}`))
	req.Header.Set("Referer", "http://example.com/")
	w := httptest.NewRecorder()
	s.add(w, req)
	if w.Code != http.StatusOK || w.Header().Get("Location") != "" {
		t.Fatalf("got %d with Location %q", w.Code, w.Header().Get("Location"))
	}
	if !strings.Contains(w.Body.String(), "example.com/a") {
		t.Fatalf("body = %q", w.Body)
	}
}
