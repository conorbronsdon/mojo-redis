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
