# Decisions

The record of goose-postgres's design decisions, for contributors and agents: each
dated, with its reason and the trade-off that matters.

## Settled

- **After goose-sqlite.** SQLite needs no network code; this package waits on outbound
  connections in goose-http (2026-10-19).

## Proposed

- **The protocol in Goose, not libpq.** The wire protocol is message framing and type
  decoding, the byte work Goose is measured on. libpq does its own socket I/O, and in
  the Goose packages sockets are goose-http's. HttpArena's `async-db` rules also ask for
  an async driver with a pool of `DATABASE_MAX_CONN` connections (256 at `2d85137`,
  2026-10-18), which blocking calls on a lane can't give without a thread per
  connection.
- **No I/O in the package.** As in goose-tls, a connection's state takes the bytes the
  program read and returns the bytes to send. goose-http's loop owns the socket, so the
  same code serves epoll, io_uring, kqueue, and IOCP.

## Open

- Where SHA-256, HMAC, and PBKDF2 for SCRAM-SHA-256 come from. WebSocket's handshake
  (SHA-1) and a JWT verifier (HMAC-SHA-256) need the same family, so a small hash
  package may hold all of them (goose-rest's task 047, "Open").
- How goose-rest hands a query to the loop that owns the connection and resumes the
  request with the rows: on the worker that serves the request, or on a lane that owns
  the pool.
- Whether the API follows goose-sqlite's where the two databases allow it.
