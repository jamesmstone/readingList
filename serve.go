package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"

	"github.com/jamesmstone/readingList/transport"
)

// There is no authentication here, by design. The listener is reachable only
// over the tailnet, which is what let this replace a Forgejo
// `workflow_dispatch` and the API token that came with it.
type server struct {
	// Appends mutate a git checkout, so only one may run at a time. Held for
	// the whole request rather than queued: the caller is a button that wants
	// to be told whether its article was recorded.
	mu      sync.Mutex
	append  string
	timeout time.Duration
}

type addResponse struct {
	URL   string `json:"url"`
	Title string `json:"title"`
}

func (s *server) add(w http.ResponseWriter, r *http.Request) {
	// POST only: a GET would let a link prefetcher or a chat client's preview
	// fetcher append an article by looking at the URL.
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, fmt.Errorf("use POST"))
		return
	}

	in, err := decodeInputs(r)
	if err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	if err := in.Validate(); err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Deliberately not r.Context(): a phone that gives up waiting must not
	// cancel the append it asked for, which could be anywhere between the
	// screenshot and the push by then.
	ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
	defer cancel()

	log.Printf("appending %s (%s)", in.URL, in.Title)
	cmd := exec.CommandContext(ctx, s.append)
	cmd.Env = append(os.Environ(),
		"RL_URL="+in.URL,
		"RL_TITLE="+in.Title,
		"RL_DESCRIPTION="+in.Description,
		"RL_IMAGE="+in.Image,
	)
	// Straight to the journal, so a failed append is diagnosed where every
	// other unit's failures are.
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		httpError(w, http.StatusInternalServerError, fmt.Errorf("append failed: %w", err))
		return
	}

	log.Printf("appended %s", in.URL)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(addResponse{URL: in.URL, Title: in.Title})
}

// Accepts either a JSON body or a form, so the caller can be whichever of the
// two a phone shortcut makes easier.
func decodeInputs(r *http.Request) (*transport.Inputs, error) {
	in := new(transport.Inputs)

	if ct := r.Header.Get("Content-Type"); ct == "application/x-www-form-urlencoded" {
		if err := r.ParseForm(); err != nil {
			return nil, err
		}
		in.URL = r.PostForm.Get("url")
		in.Title = r.PostForm.Get("title")
		in.Description = r.PostForm.Get("description")
		in.Image = r.PostForm.Get("image")
		return in, nil
	}

	if err := json.NewDecoder(r.Body).Decode(in); err != nil {
		return nil, fmt.Errorf("body is neither a form nor JSON: %w", err)
	}
	return in, nil
}

func httpError(w http.ResponseWriter, code int, err error) {
	log.Printf("%d: %v", code, err)
	http.Error(w, err.Error(), code)
}

func Serve() error {
	addr := os.Getenv("RL_LISTEN")
	if addr == "" {
		addr = "127.0.0.1:8108"
	}

	appendCmd := os.Getenv("RL_APPEND_CMD")
	if appendCmd == "" {
		return fmt.Errorf("set RL_APPEND_CMD to the append script")
	}

	// Generous, and deliberately so: an append shoots a screenshot and a PDF of
	// a page that may be slow, then pushes and rebuilds the database.
	timeout := 10 * time.Minute
	if v := os.Getenv("RL_TIMEOUT_SECONDS"); v != "" {
		secs, err := strconv.Atoi(v)
		if err != nil {
			return fmt.Errorf("RL_TIMEOUT_SECONDS: %w", err)
		}
		timeout = time.Duration(secs) * time.Second
	}

	s := &server{append: appendCmd, timeout: timeout}

	mux := http.NewServeMux()
	mux.HandleFunc("/add", s.add)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	srv := &http.Server{
		Handler: mux,
		// No write timeout: the response is only sent once the append is done.
		ReadHeaderTimeout: 10 * time.Second,
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	log.Printf("listening on %s", addr)
	return srv.Serve(ln)
}
