# Changelog

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
