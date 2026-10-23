# 006: A per-connection cap on a message's size

Status: done (2026-10-23)

`pg::step` accepted any message up to `MAX_MESSAGE`, 1 GB, Postgres's own limit on a
field, and the facade grew `Db.input` until the whole message had arrived. A hostile
server, or anyone between the client and a server reached without TLS, could announce a
message of nearly 1 GB on every connection and make the client hold that much memory
per connection: with Plod's lanes or task 005's pool of 256 connections, far more
than the host has. Most programs never receive a row near that size.

`Config.max_message`, 64 MB by default, is copied into `Conn` at `start`, and `step`
checks each message's length against it as soon as the 5-byte head has arrived, so the
facade fails the call with `"08006"` and "a message is longer than Config.max_message"
before its input grows for the rest ([decisions](../docs/decisions.md)).

## Acceptance criteria

- [x] A configurable cap on a message's size, with a default well below 1 GB (such as
      64 MB), recorded in `docs/decisions.md` with the reason for the default
- [x] A message announced above the cap breaks the connection with a reason, before
      any buffer grows to its size, in the protocol layer and the facade
- [x] Tests: a crafted message length just above the cap fails, one at the cap reads
      (`test/messages/backend.goose`, `test/facade/failures.goose`)
- [x] `docs/architecture.md` ("Limits") and `README.md` name the cap and how to set it
- [x] `scripts/test.sh` and `scripts/live.sh` pass (macOS, 2026-10-23)
