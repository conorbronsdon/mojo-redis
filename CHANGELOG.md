# Changelog

## Unreleased

### Fixed
- **Transport: suppress SIGPIPE on a dead connection.** Writing to a
  socket whose peer has closed delivered `SIGPIPE`, terminating the whole
  process (exit 141) before `send()` could return `EPIPE` — so the
  existing error path never ran. CPython avoids this by installing
  `SIG_IGN` for `SIGPIPE`; a Mojo process does not. Fixed at the syscall
  boundary, platform-gated: `MSG_NOSIGNAL` on the `send()` flags on Linux,
  `SO_NOSIGPIPE` via `setsockopt(2)` after `socket()` on macOS/BSD. A dead
  peer now raises a catchable `Error`. Regression covered by
  `test/test_connection.mojo` (self-contained, no server; runs in CI).
- **Transport: close a poisoned connection instead of reusing it.** After a
  raised protocol/parse or transport error, `is_open()` still returned
  `True`, so the byte stream stayed out of sync and every later command
  misframed its reply. `read_reply` (and a failed `_send_all`) now close the
  connection before propagating, so a subsequent command fails fast —
  matching redis-py, which disconnects on `InvalidResponse`. Regression
  covered by `test_poisoned_connection_is_closed`.
- **Parser: bound reply size against memory-exhaustion DoS.** A hostile
  bulk-string length (e.g. `$999999999999999999`) or array element count
  had no ceiling, so the transport would `recv`/allocate unbounded. Added
  caps — 512 MiB per bulk string (matching Redis `proto-max-bulk-len`),
  1,048,576 elements per array, and a 528 MiB total unparsed-buffer
  ceiling — each raising on exceed. Regression covered by
  `test_bulk_length_exceeds_cap_raises` / `test_array_count_exceeds_cap_raises`.
- **Build: `pixi install` failed to resolve.** The `mojo = ">=1.0.0b3"`
  pin sorts *after* the dev nightlies (`1.0.0b3.dev…`), so the solver
  found no candidates. Pinned to `>=1.0.0b3.dev0,<2`.

## 0.1.0 — 2026-07-05

Initial release. A synchronous Redis client in pure Mojo speaking RESP2
over a direct libc TCP socket (no third-party networking dependency).

- **Protocol core** (`resp.mojo`): RESP2 command serializer and a parser
  for all five reply types (simple string, error, integer, bulk string
  incl. nil, array incl. nested and nil). The parser is incremental-safe
  — a reply split across multiple `recv` calls is decoded correctly.
- **Transport** (`connection.mojo`): blocking IPv4 TCP via `external_call`
  into `socket`/`connect`/`send`/`recv`/`close`, isolated behind a
  `Connection` struct so the backend is swappable.
- **Client** (`client.mojo`): redis-py-shaped API — `get`, `set` (with
  `ex=` expiry), `delete`/`delete_keys`, `exists`, `incr`, `decr`,
  `expire`, `ttl`, `keys`, `ping`, `lpush`/`rpush`/`lpop`/`rpop`/`lrange`,
  `hset`/`hget`/`hgetall`, `flushdb`, an `execute` escape hatch, and
  `pipeline`/`execute_pipeline`.
- **Tests**: 34 protocol unit tests (no network) and 21 integration tests
  against a live server, all passing. CI runs the protocol suite only.
