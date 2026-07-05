# Security Policy

mojo-redis is a Redis client library. It opens a TCP connection to a
Redis server you configure and speaks the RESP2 protocol; it holds no
secrets of its own and does no authentication beyond what you send via
commands (e.g. `AUTH` through `execute`). The main risk surfaces are the
libc socket FFI in `connection.mojo` (raw pointers, manual allocation)
and the RESP reply parser in `resp.mojo` (untrusted server bytes).

If you find an input from a Redis server — or a malformed reply — that
crashes, hangs, or causes out-of-bounds access or unbounded memory
growth in the parser or transport, please report it via a
[GitHub issue](https://github.com/conorbronsdon/mojo-redis/issues) with a
minimal reproduction.

v0.1 caveats: connections are plaintext (no TLS) and blocking (no
timeouts). Do not point it at an untrusted network without transport
security in front of it.

This is a personal open-source project maintained on a best-effort
basis — no formal SLA, but reports are welcome and taken seriously.
