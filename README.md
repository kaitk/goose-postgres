# goose-postgres

A PostgreSQL client for [Goose](https://github.com/aardappel/goose), in Goose: the
frontend/backend protocol (version 3.0) as bytes in and bytes out, so the program's event
loop owns the sockets and one thread can keep many connections busy. Its first user is
[goose-rest](https://github.com/kaitk/goose-rest), on goose-http's outbound connections.

Nothing is built yet. The plan is in [tasks](tasks/README.md), and the choices so far
are in [decisions](docs/decisions.md).

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Feature | Notes |
|---|---|---|
| 🟡 | Startup and authentication | SCRAM-SHA-256 and cleartext passwords, from a `postgres://` URL. |
| 🟡 | Queries | The extended protocol: parse once, then bind and execute with parameters; rows decoded by column type. |
| 🔴 | A pool | Connections shared by a program's workers, sized by the program. |
| 🔴 | Pipelining | Several queries in flight on one connection. |
| 🔴 | TLS | Through goose-tls's client mode, for servers that ask for it. |

## Pins

The Goose release in `scripts/goose.sh` (`v2026.2`).
