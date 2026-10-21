# One append, or one republish: refresh the checkout, optionally record an
# article in it, then rebuild the database and the page from whatever the
# checkout now holds and hand both to the servers that serve them.
#
# Runs unattended from a systemd unit, so every network call is bounded and
# nothing may ever wait on a prompt: an unbounded git call in a unit stalls
# `nixos-rebuild switch` behind it.
set -euo pipefail

mode=${1:-append}

# Every existing row records UTC; a local offset here would break the
# text-ordering Datasette does on the date column.
export TZ=UTC

: "${RL_REMOTE:?set RL_REMOTE}"
: "${RL_STATE:?set RL_STATE}"
publishDB=${RL_PUBLISH_DB:-}
publishSite=${RL_PUBLISH_SITE:-}
shotScraper=${RL_SHOT_SCRAPER:-shot-scraper}

repo=$RL_STATE/repo
siteDir=$repo/.site

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
# HOME is inherited only so ssh finds the key that pushes. Everything else this
# repo needs is configured below, so the unit does not pick up whatever is in
# the running user's ~/.gitconfig.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# Every `timeout` below is --foreground. Without it timeout moves its command
# into a process group of its own, out of reach of the server killing this
# script's group, and a killed append would leave a git push running.

mkdir -p "$RL_STATE"

# The HTTP server and the reconcile timer are separate processes sharing one
# checkout, so the server's own serialisation is not enough.
exec {lock}>"$RL_STATE/.lock"
flock -w 1800 "$lock"

# A HEAD, not a .git: git clone creates .git before it has fetched anything, so
# a run killed mid-clone would otherwise leave a checkout that fails forever.
if ! git --git-dir="$repo/.git" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  rm -rf "$repo" "$repo.tmp"
  # The archive carries a PDF of every article ever read, so this is >2GiB and
  # only ever paid once. Cloned aside and renamed so that $repo only ever
  # exists complete.
  timeout --foreground 60m git clone "$RL_REMOTE" "$repo.tmp"
  mv "$repo.tmp" "$repo"
fi

cd "$repo"

git config user.name "Automated"
git config user.email "actions@jamesst.one"

timeout --foreground 10m git fetch --prune origin

# Never rebase and never discard: the CSV row and the screenshot are the only
# copies of that article, and nothing else writes this archive, so a real
# divergence means something is wrong. Park it where a human can find it rather
# than throwing appends away.
if ! git merge --ff-only origin/main >/dev/null 2>&1; then
  parked="diverged/$(date -u +%Y%m%dT%H%M%SZ)"
  echo "WARNING: diverged from origin/main; parking local work on $parked" >&2
  git branch "$parked"
  timeout --foreground 5m git push origin "$parked" || true
  git reset --hard origin/main
fi
# Scoped away from .site: a run killed between the fetch and the commit leaves
# a new screenshot untracked there, and an unscoped clean would delete it.
git clean -fdq -- ':!.site'

if [ "$mode" = append ]; then
  : "${RL_URL:?set RL_URL}"
  : "${RL_TITLE:?set RL_TITLE}"

  stamp=$(date +%s)
  png="$stamp.png"
  pdf="$stamp.pdf"
  mkdir -p "$siteDir"

  # An article whose shot fails is still worth recording, so neither of these
  # aborts the append -- the row goes in with an empty screenshot column and
  # the warning names what to re-shoot. They are bounded because a page that
  # never finishes loading would otherwise hold the lock until the HTTP
  # caller's own timeout.
  if ! timeout --foreground 4m "$shotScraper" "$RL_URL" --width 400 --height 400 -o "$siteDir/$png"; then
    echo "WARNING: no screenshot for $RL_URL" >&2
    png=""
  fi
  if ! timeout --foreground 4m "$shotScraper" pdf "$RL_URL" -o "$siteDir/$pdf"; then
    echo "WARNING: no PDF for $RL_URL" >&2
    pdf=""
  fi

  RL_INPUT_JSON=$(jq -nc \
    --arg url "$RL_URL" \
    --arg title "$RL_TITLE" \
    --arg description "${RL_DESCRIPTION:-}" \
    --arg image "${RL_IMAGE:-}" \
    --arg screenshot "$png" \
    --arg pdf "$pdf" \
    '$ARGS.named')
  export RL_INPUT_JSON

  readingList add
fi

# Always, not only after an append: the page is a pure function of the CSV, so
# regenerating it is what guarantees there is an index.html to publish at all.
# The archive predates it being committed, and a republish has to be able to
# produce one for a checkout that has never had it.
readingList generateSite

if [ -n "$(git status --porcelain -- readingList.csv .site)" ]; then
  git add readingList.csv .site
  git commit -q -m "Automated reading list update on $(date -u)"
fi

# Unconditional, and outside the branch above: a run whose push failed leaves a
# commit behind that the next one has to carry, and by then its working tree is
# clean again.
timeout --foreground 30m git push origin HEAD:main

# The checkout's own recipe, so the data and the schema built from it always
# version together.
bash ./run.sh build

if [ -n "$publishDB" ]; then
  # Rename rather than write in place: Datasette holds the database open, and
  # install(1) truncates, so a reader can see a torn file mid-write.
  staged="$(dirname "$publishDB")/.$(basename "$publishDB").new"
  install -Dm644 readingList.db "$staged"
  mv -f "$staged" "$publishDB"
fi

if [ -n "$publishSite" ]; then
  mkdir -p "$publishSite"
  # --ignore-existing: a name carries the timestamp it was made at, so a
  # screenshot or PDF is never rewritten once published and there are 1700-odd
  # of each. The PDFs must go too, since the index links every one; index.html
  # is the only file that ever changes.
  rsync -a --ignore-existing --include='*.png' --include='*.pdf' --exclude='*' "$siteDir/" "$publishSite/"
  rsync -a --delete "$siteDir/css/" "$publishSite/css/"
  rsync -a "$siteDir/index.html" "$publishSite/index.html"
fi
