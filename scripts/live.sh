#!/bin/sh
# Runs the session tests (test/session/) against a Postgres in Docker, through
# scripts/relay.py, and checks each one's output against its golden file in
# test/expected/, the same file its replay under test/run_tests.py checks.
# The test `socket` (test/live/socket.goose) runs the facade over goose-http's
# socket instead, once over TCP and once over a Unix socket, which
# scripts/unix-forward.py serves, and checks both against socket.out.
#
# The server is HttpArena's: the postgres:18 image with user bench, password
# bench, and database benchmark, seeded from HttpArena's data/pgdb-seed.sql at
# the commit below, which the script fetches into build/arena/ and checks;
# scripts/live-init.sh adds a user that logs in with a cleartext password.
#
#   scripts/live.sh [--record] [TEST ...]
#
# Without TESTs it runs them all. --record writes each test's capture to
# test/data/ and its output to test/expected/ (socket's output only), for a
# new test or a new server version; review the diff.
# PG_PORT picks the host port (default 55432), PG_IMAGE the image (default
# postgres:18). GOOSE or GOOSE_COMMIT names the compiler (default: the pinned
# release, scripts/goose.sh). Needs Docker, Python 3, and curl.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
port=${PG_PORT:-55432}
image=${PG_IMAGE:-postgres:18}
record=
if [ "${1:-}" = --record ]; then
    record=1
    shift
fi
tests=${*:-arena pipeline cleartext cleartext_refused bad_password facade facade_login socket}

arena_commit=2d85137
seed_sum=f020c2c6851ea1c53cd1b90c94baadd5645b2fc3e4caed5b0daf71a61bff9e21
seed=$root/build/arena/pgdb-seed.sql
if [ ! -f "$seed" ]; then
    mkdir -p "$root/build/arena"
    echo "fetching HttpArena's pgdb-seed.sql at $arena_commit" >&2
    curl -fsSL -o "$seed.tmp" \
        "https://raw.githubusercontent.com/MDA2AV/HttpArena/$arena_commit/data/pgdb-seed.sql"
    mv "$seed.tmp" "$seed"
fi
if command -v sha256sum >/dev/null; then got=$(sha256sum "$seed"); else got=$(shasum -a 256 "$seed"); fi
if [ "${got%% *}" != "$seed_sum" ]; then
    echo "$seed: SHA-256 ${got%% *}, expected $seed_sum" >&2
    exit 1
fi

name=goose-postgres-live-$port
# The Unix socket's directory: short, since a socket's path has a limit of
# about 100 bytes.
sockdir=$(mktemp -d /tmp/goose-pg.XXXXXX)
forward=
cleanup() {
    [ -z "$forward" ] || kill "$forward" 2>/dev/null || :
    rm -rf "$sockdir"
    docker rm -f -v "$name" >/dev/null 2>&1 || :
}
docker rm -f -v "$name" >/dev/null 2>&1 || :
trap cleanup EXIT
trap 'exit 1' INT TERM
docker run -d --rm --name "$name" -p "127.0.0.1:$port:5432" \
    --tmpfs /var/lib/postgresql:rw,size=1g \
    -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=benchmark \
    -v "$seed:/docker-entrypoint-initdb.d/1-seed.sql:ro" \
    -v "$root/scripts/live-init.sh:/docker-entrypoint-initdb.d/2-plain.sh:ro" \
    "$image" -c max_connections=256 >/dev/null

# The entrypoint restarts the server after its init scripts, so wait for the
# seed and for a TCP connection from outside.
ready=
for i in $(seq 1 120); do
    if docker exec "$name" psql -h 127.0.0.1 -U bench -d benchmark -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname = 'plain'" 2>/dev/null | grep -q 1 &&
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1)" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" ] || { echo "Postgres didn't become ready" >&2; docker logs "$name" >&2; exit 1; }
echo "$(docker exec "$name" postgres --version) on port $port"

mkdir -p "$root/build/live"
failed=0

# Runs test/live/socket.goose with ARGS into build/live/LABEL.out, and checks
# it against test/expected/socket.out.
socket_run() {
    label=$1
    shift
    out=$root/build/live/$label.out
    if ! "$root/build/live/socket" "$@" >"$out"; then
        echo "FAIL $label: exit"
        cat "$out"
        failed=1
    elif [ "$record" ] && [ "$label" = socket ]; then
        cp "$out" "$root/test/expected/socket.out"
        echo "recorded socket"
    elif diff -u "$root/test/expected/socket.out" "$out"; then
        echo "ok   $label"
    else
        echo "FAIL $label: output differs"
        failed=1
    fi
}

for t in $tests; do
    if [ "$t" = socket ]; then
        "$GOOSE" build -o "$root/build/live/socket" "$root/test/live/socket.goose" >/dev/null
        url=postgres://bench:bench@127.0.0.1:$port/benchmark
        socket_run socket "$url"
        python3 "$root/scripts/unix-forward.py" "$sockdir/.s.PGSQL.$port" "$port" &
        forward=$!
        for i in $(seq 1 50); do
            [ -S "$sockdir/.s.PGSQL.$port" ] && break
            sleep 0.1
        done
        socket_run socket-unix "$url" "$sockdir"
        continue
    fi
    exe=$root/build/live/$t
    "$GOOSE" build -o "$exe" "$root/test/session/$t.goose" >/dev/null
    cap=$root/build/live/$t.cap
    if ! python3 "$root/scripts/relay.py" --port "$port" --record "$cap" -- "$exe" \
        >"$root/build/live/$t.out"; then
        echo "FAIL $t: exit $?"
        cat "$root/build/live/$t.out"
        failed=1
        continue
    fi
    if [ "$record" ]; then
        cp "$cap" "$root/test/data/$t.cap"
        cp "$root/build/live/$t.out" "$root/test/expected/$t.out"
        echo "recorded $t"
    elif diff -u "$root/test/expected/$t.out" "$root/build/live/$t.out"; then
        echo "ok   $t"
    else
        echo "FAIL $t: output differs"
        failed=1
    fi
done
exit $failed
