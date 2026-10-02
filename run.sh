#!/usr/bin/env bash
set -euo pipefail

# Every existing row records UTC; a local offset here would break the
# text-ordering Datasette does on the date column.
export TZ=UTC

db="readingList.db"
dbBranch="db"
siteDir=".site"

# Appends the entry described by RL_URL/RL_TITLE/RL_DESCRIPTION/RL_IMAGE,
# archiving a screenshot and a PDF of it alongside.
append() {
  local json stamp png pdf
  stamp=$(date +%s)
  png="$stamp.png"
  pdf="$stamp.pdf"

  mkdir -p "$siteDir"
  shot-scraper "$RL_URL" --width 400 --height 400 -o "$siteDir/$png"
  shot-scraper pdf "$RL_URL" -o "$siteDir/$pdf"

  json=$(jq -nc \
    --arg url "$RL_URL" \
    --arg title "$RL_TITLE" \
    --arg description "${RL_DESCRIPTION:-}" \
    --arg image "${RL_IMAGE:-}" \
    --arg screenshot "$png" \
    --arg pdf "$pdf" \
    '$ARGS.named')

  RL_INPUT_JSON="$json" readingList add
  readingList generateSite
}

build() {
  rm -f "$db"
  sqlite-utils insert "$db" read readingList.csv --csv
  sqlite-utils enable-fts "$db" read title description url
  sqlite-utils optimize "$db"
}

commitDB() {
  local tempDB
  tempDB="$(mktemp)"
  git config user.name "Automated"
  git config user.email "actions@jamesst.one"
  git branch -D "$dbBranch" || true
  git checkout --orphan "$dbBranch"
  mv "$db" "$tempDB"
  git rm -rqf .
  mv "$tempDB" "$db"
  git add -f "$db"
  git commit -m "push db"
  git push origin "HEAD:$dbBranch" -f
}

case "${1:-build}" in
append) append ;;
build) build ;;
commit-db) commitDB ;;
*)
  echo "usage: $0 {append|build|commit-db}" >&2
  exit 2
  ;;
esac
