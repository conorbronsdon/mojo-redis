"""The `Redis` client — a redis-py-shaped surface over the RESP2 core.

`Redis` owns one `Connection` and exposes the common command set as
typed methods (`get`, `set`, `incr`, `lpush`, `hgetall`, ...). Each
method builds a `List[String]` command, sends it, reads one reply, and
converts that reply to a natural Mojo return type — `Optional[String]`
for values that may be nil, `Int` for counters, `List[String]` for list
replies, `Dict[String, String]` for hashes. Anything not wrapped is
reachable through `execute`, and multiple commands can be batched with
`pipeline()` / `execute_pipeline()`.

RESP error replies (`-ERR ...`) are raised as Mojo `Error`s, so a failed
command surfaces as an exception rather than a silently wrong value.
"""

from .connection import Connection
from .resp import RespValue


struct Pipeline(Copyable, Movable):
    """A queued batch of commands, sent and read back in one round trip.

    Build it with `Redis.pipeline()`, queue commands with the typed
    helpers (or the generic `add`), then hand it to
    `Redis.execute_pipeline` to flush and collect the replies in order.
    """

    var commands: List[List[String]]

    def __init__(out self):
        self.commands = List[List[String]]()

    def add(mut self, var command: List[String]):
        """Queue an arbitrary command (the pipeline escape hatch)."""
        self.commands.append(command^)

    def set(mut self, key: String, value: String):
        self.add(["SET", key, value])

    def get(mut self, key: String):
        self.add(["GET", key])

    def incr(mut self, key: String):
        self.add(["INCR", key])

    def rpush(mut self, key: String, value: String):
        self.add(["RPUSH", key, value])

    def __len__(self) -> Int:
        return len(self.commands)


struct Redis(Movable):
    """A synchronous Redis client bound to one server connection."""

    var conn: Connection

    def __init__(
        out self, var host: String = String("127.0.0.1"), port: Int = 6379
    ) raises:
        """Open a connection to `host:port` (defaults to `127.0.0.1:6379`)."""
        self.conn = Connection(host^, port)
        self.conn.connect()

    @staticmethod
    def connect(
        var host: String = String("127.0.0.1"), port: Int = 6379
    ) raises -> Self:
        """Alternate constructor mirroring redis-py's factory style."""
        return Self(host^, port)

    def close(mut self):
        """Close the underlying socket."""
        self.conn.close()

    # ── Core ──────────────────────────────────────────────────────────────────

    def execute(mut self, command: List[String]) raises -> RespValue:
        """Send an arbitrary command and return its raw reply.

        The escape hatch for any command without a typed wrapper, e.g.
        `execute(["CONFIG", "GET", "maxmemory"])`.
        """
        self.conn.send_command(command)
        return self.conn.read_reply()

    def execute_pipeline(mut self, pipe: Pipeline) raises -> List[RespValue]:
        """Flush all queued commands, then read the replies in order."""
        for cmd in pipe.commands:
            self.conn.send_command(cmd)
        var replies = List[RespValue]()
        for _ in range(len(pipe.commands)):
            replies.append(self.conn.read_reply())
        return replies^

    @staticmethod
    def pipeline() -> Pipeline:
        """Create an empty pipeline to queue commands into."""
        return Pipeline()

    # ── Connection / server ──────────────────────────────────────────────────

    def ping(mut self) raises -> String:
        return self.execute(["PING"]).as_string()

    def flushdb(mut self) raises -> Bool:
        return self.execute(["FLUSHDB"]).as_bool()

    # ── Strings / generic keys ───────────────────────────────────────────────

    def get(mut self, key: String) raises -> Optional[String]:
        """Value at `key`, or `None` if the key does not exist."""
        return self.execute(["GET", key]).as_string_opt()

    def set(
        mut self, key: String, value: String, ex: Optional[Int] = None
    ) raises -> Bool:
        """Set `key` to `value`. `ex=` sets an expiry in seconds."""
        var cmd = List[String]()
        cmd.append("SET")
        cmd.append(key)
        cmd.append(value)
        if ex:
            cmd.append("EX")
            cmd.append(String(ex.value()))
        return self.execute(cmd).as_bool()

    def delete(mut self, key: String) raises -> Int:
        """Delete `key`; returns the number of keys removed (0 or 1)."""
        return self.execute(["DEL", key]).as_int()

    def delete_keys(mut self, keys: List[String]) raises -> Int:
        """Delete several keys at once; returns the number removed."""
        var cmd = List[String]()
        cmd.append("DEL")
        for k in keys:
            cmd.append(k)
        return self.execute(cmd).as_int()

    def exists(mut self, key: String) raises -> Int:
        """1 if `key` exists, 0 otherwise."""
        return self.execute(["EXISTS", key]).as_int()

    def incr(mut self, key: String) raises -> Int:
        return self.execute(["INCR", key]).as_int()

    def decr(mut self, key: String) raises -> Int:
        return self.execute(["DECR", key]).as_int()

    def expire(mut self, key: String, seconds: Int) raises -> Bool:
        """Set a TTL on `key`; True if the timeout was set."""
        return self.execute(["EXPIRE", key, String(seconds)]).as_bool()

    def ttl(mut self, key: String) raises -> Int:
        """Remaining TTL in seconds (-1 no expiry, -2 no such key)."""
        return self.execute(["TTL", key]).as_int()

    def keys(mut self, pattern: String = String("*")) raises -> List[String]:
        """Keys matching `pattern` (defaults to all keys)."""
        return self.execute(["KEYS", pattern]).as_string_list()

    # ── Lists ────────────────────────────────────────────────────────────────

    def lpush(mut self, key: String, value: String) raises -> Int:
        """Prepend `value`; returns the list length after the push."""
        return self.execute(["LPUSH", key, value]).as_int()

    def rpush(mut self, key: String, value: String) raises -> Int:
        """Append `value`; returns the list length after the push."""
        return self.execute(["RPUSH", key, value]).as_int()

    def lpop(mut self, key: String) raises -> Optional[String]:
        return self.execute(["LPOP", key]).as_string_opt()

    def rpop(mut self, key: String) raises -> Optional[String]:
        return self.execute(["RPOP", key]).as_string_opt()

    def lrange(
        mut self, key: String, start: Int, stop: Int
    ) raises -> List[String]:
        """Elements of the list in `[start, stop]` (inclusive, may be negative).
        """
        return self.execute(
            ["LRANGE", key, String(start), String(stop)]
        ).as_string_list()

    # ── Hashes ───────────────────────────────────────────────────────────────

    def hset(mut self, key: String, field: String, value: String) raises -> Int:
        """Set `field` to `value`; returns 1 if the field was new, else 0."""
        return self.execute(["HSET", key, field, value]).as_int()

    def hget(mut self, key: String, field: String) raises -> Optional[String]:
        return self.execute(["HGET", key, field]).as_string_opt()

    def hgetall(mut self, key: String) raises -> Dict[String, String]:
        """All field/value pairs of the hash at `key` as a `Dict`."""
        var flat = self.execute(["HGETALL", key]).as_string_list()
        var out = Dict[String, String]()
        var i = 0
        while i + 1 < len(flat):
            out[flat[i]] = flat[i + 1]
            i += 2
        return out^
