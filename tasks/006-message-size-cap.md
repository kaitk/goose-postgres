# 006: A per-connection cap on a message's size

Status: todo

`pg::step` accepts any message up to `MAX_MESSAGE`, 1 GB, Postgres's own limit on a
field, and the facade grows `Db.input` until the whole message has arrived. A hostile
server, or anyone between the client and a server reached without TLS, can announce a
message of nearly 1 GB on every connection and make the client hold that much memory
per connection: with goose-rest's lanes or task 005's pool of 256 connections, far
more than the host has. Most programs never receive a row near that size.

A cap per `Db`, lower than 1 GB by default and set by the program, makes such a
message break the connection with a reason before the facade allocates for it. The
protocol layer already reports the size it waits for in `c.need`, so the check can sit
in `step` (a field of `Conn`) or in the facade's `next` (a field of `Db`); pick one,
and record it in `docs/decisions.md`.

## Acceptance criteria

- [ ] A configurable cap on a message's size, with a default well below 1 GB (such as
      64 MB), recorded in `docs/decisions.md` with the reason for the default
- [ ] A message announced above the cap breaks the connection with a reason, before
      any buffer grows to its size, in the protocol layer and the facade
- [ ] Tests: a crafted message length just above the cap fails, one at the cap reads
- [ ] `docs/architecture.md` ("Limits") and `README.md` name the cap and how to set it
- [ ] `scripts/test.sh` and `scripts/live.sh` pass
