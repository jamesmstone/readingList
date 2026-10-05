#!/usr/bin/env bash
set -euo pipefail

# Every existing row records UTC; a local offset here would break the
# text-ordering Datasette does on the date column.
export TZ=UTC

db="readingList.db"

# The one definition of "CSV to database", called both by nix/append.sh against
# a checkout and by database.nix against the store copy of the CSV.
build() {
  rm -f "$db"
  sqlite-utils insert "$db" read readingList.csv --csv
  sqlite-utils enable-fts "$db" read title description url
  sqlite-utils optimize "$db"
}

case "${1:-build}" in
build) build ;;
*)
  echo "usage: $0 build" >&2
  exit 2
  ;;
esac
