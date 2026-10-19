#!/bin/sh
# Runs every test that needs no server, and fails on the first step that
# fails: the typecheck of pg.goose, of socket.goose with goose-http, of each
# root file under test/, and of the programs under test/live/, then the tests
# under test/<area>/ (test/run_tests.py, which reports all of its failures),
# the session tests among them replaying their captures. scripts/live.sh runs
# the session tests and test/live/ against a Postgres in Docker.
#
# GOOSE or GOOSE_COMMIT names the compiler (default: the pinned release,
# scripts/goose.sh), and CC the C compiler for goose build (default: the one
# goose build finds).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
goose=$GOOSE

step() {
    echo
    echo "== $*"
}

for f in "$root"/pg.goose "$root"/socket.goose "$root"/test/*.goose "$root"/test/live/*.goose; do
    step "check ${f#"$root"/}"
    "$goose" check "$f"
done

step "test/run_tests.py"
python3 "$root/test/run_tests.py"
