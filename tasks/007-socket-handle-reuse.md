# 007: Copies of a socket that outlive its close

Status: todo. Waits on goose-http.

`pg::Socket` holds goose-http's `http::Socket`, a fixed-size handle `{ fd }`, and
`pg::Db` holds the `Socket` by value, so a program may copy either. Once one copy
closes, the others keep the same fd number, and the OS may hand that number to the
next socket or file the process opens. A later `pg::send` or `pg::receive` through a
stale copy then reads or writes another connection's bytes: a query sent to the wrong
server, or rows from another connection's session. `pg::close` sets nothing the other
copies can see.

The fix belongs in goose-http, which owns the sockets: generation-checked handles,
where a handle carries the generation of the slot it was opened in and every call
checks it, so a stale copy fails rather than reach a reused fd. goose-sqlite v0.0.3
got generation-checked handles for the same class of bug, its connection handles
after close; goose-http's socket handles need the same. Until then, a program keeps
one `Db` per connection and doesn't copy it.

## Acceptance criteria

- [ ] goose-http's `http::Socket` checks a generation on each call, so a copy made
      before `http::hangup` fails after it, even once the fd number is reused
- [ ] `socket.goose` takes it, with the goose-http pin moved
- [ ] A test: a `Db` copied, the original closed, a new connection opened, and a call
      through the copy fails without touching the new connection
- [x] Until then, `docs/architecture.md` ("goose-http's socket") says not to copy a
      `Db` or `Socket`
- [ ] `scripts/test.sh` and `scripts/live.sh` pass
