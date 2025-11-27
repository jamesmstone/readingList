#!/bin/bash
set -e # Exit with nonzero exit code if anything fails
set -o pipefail
set -o errexit

dockerSQLUtil="sqlite-utils"

TZ=UTC

buildDocker() {
  docker build --tag "$dockerSQLUtil" --file sqlite-utils.Dockerfile .
}

sql-utils() {
  docker run \
    -i \
    -u"$(id -u):$(id -g)" \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerSQLUtil" \
    "$@"
}


makeDB() {
  local db="$1"
  rm -rf "$db" || true
  sql-utils insert "$db" read readingList.csv --csv
  sql-utils enable-fts "$db" read title description url
  sql-utils optimize "$db"
}

commitDB() {
  local dbBranch="db"
  local db="$1"
  local tempDB="$(mktemp)"
  git config user.name "Automated"
  git config user.email "actions@users.noreply.github.com"
  git branch -D "$dbBranch" || true
  git checkout --orphan "$dbBranch"
  mv "$db" "$tempDB"
  rm -rf *
  mv "$tempDB" "$db"
  git add -f "$db"
  git commit "$db" -m "push db"
  git push origin "$dbBranch" -f
}


publishDB() {
  set +x
  local dockerDatasette="datasette"
  docker build --tag "$dockerDatasette" --pull --file datasette.Dockerfile .
  if [ -z ${VERCEL_TOKEN+x} ]; then echo "VERCEL_TOKEN is unset"; else echo "VERCEL_TOKEN is set to '$VERCEL_TOKEN'"; fi
  docker run \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerDatasette" \
    publish vercel \
    "$db" \
    "--project=reading-list" \
    --generate-vercel-json > vercel.json
  sed -i 's/@vercel\/python@3\.0\.7/@vercel\/python@4.5.1/g' vercel.json
  docker run \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerDatasette" \
    publish vercel \
    "$db" \
    --token "$VERCEL_TOKEN" \
    "--project=reading-list" \
    --vercel-json=vercel.json \
    --setting sql_time_limit_ms 3500 \
    --install=datasette-vega \
    --install=datasette-cluster-map
}

run() {
  local db="readingList.db"
  makeDB "$db"
  publishDB "$db"
  commitDB "$db"

}

buildDocker
run "$@"
