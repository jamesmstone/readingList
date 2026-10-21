package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
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
	// Origins besides this listener's own that a browser may be sent back to,
	// e.g. "https://read.jamesst.one": the page that submits here is usually
	// served from somewhere else. The first is also where a post with no usable
	// Referer lands.
	origins []string
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
	// The script's own group, killed whole on timeout: killing only the shell
	// releases its lock while the git push or rsync it started carries on
	// against the checkout the next append is about to take.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
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
	// Only a browser form post is sent back; the phone shortcut's JSON caller
	// is reading the response body.
	if isForm(r) {
		http.Redirect(w, r, s.returnTo(r), http.StatusSeeOther)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(addResponse{URL: in.URL, Title: in.Title})
}

func isForm(r *http.Request) bool {
	return r.Header.Get("Content-Type") == "application/x-www-form-urlencoded"
}

// A fragment names an element id on the page; anything else is refused rather
// than escaped, so a form field cannot smuggle in a second URL component.
var fragmentRE = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,100}$`)

// returnTo is where to send the browser after a successful append: the page it
// came from, restored to the position the form asked for.
//
// The Referer is attacker-controlled, so it is only ever matched against the
// known origins and the Location is rebuilt from the matched origin plus
// the Referer's path and query. Whatever else the Referer carries -- userinfo,
// a lookalike host, a "//host" path -- cannot reach the Location.
func (s *server) returnTo(r *http.Request) string {
	loc := "/"
	if len(s.origins) > 0 {
		loc = s.origins[0] + "/"
	}

	if ref, err := url.Parse(r.Referer()); err == nil && ref.Host != "" {
		for _, o := range append([]string{"http://" + r.Host}, s.origins...) {
			if ref.Scheme+"://"+ref.Host == o && strings.HasPrefix(ref.Path, "/") && !strings.HasPrefix(ref.Path, "//") {
				loc = o + ref.EscapedPath()
				if ref.RawQuery != "" {
					loc += "?" + ref.RawQuery
				}
				break
			}
		}
	}

	// Browsers strip the fragment from the Referer, so the only way the
	// position survives the round trip is the form carrying it.
	if f := r.PostForm.Get("fragment"); fragmentRE.MatchString(f) {
		loc += "#" + f
	}
	return loc
}

// Accepts either a JSON body or a form, so the caller can be whichever of the
// two a phone shortcut makes easier.
func decodeInputs(r *http.Request) (*transport.Inputs, error) {
	in := new(transport.Inputs)

	if isForm(r) {
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

	// A backstop, not a budget: it has to outlast the script's own worst case
	// -- half an hour queued behind a republish, then the first clone of a
	// >2GiB archive -- or it kills an append that was about to succeed.
	timeout := 3 * time.Hour
	if v := os.Getenv("RL_TIMEOUT_SECONDS"); v != "" {
		secs, err := strconv.Atoi(v)
		if err != nil {
			return fmt.Errorf("RL_TIMEOUT_SECONDS: %w", err)
		}
		timeout = time.Duration(secs) * time.Second
	}

	var origins []string
	for _, o := range strings.Split(os.Getenv("RL_REDIRECT_ORIGINS"), ",") {
		if o = strings.TrimRight(strings.TrimSpace(o), "/"); o != "" {
			origins = append(origins, o)
		}
	}

	s := &server{append: appendCmd, timeout: timeout, origins: origins}

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
