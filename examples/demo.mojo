"""A quick tour of the mojo-redis client against a live server.

Run a Redis server first (default `127.0.0.1:6379`), then:

    mojo run -I src examples/demo.mojo [host] [port]
"""

from std.sys import argv

from redis import Redis


def main() raises:
    var args = argv()
    var host = String("127.0.0.1")
    var port = 6379
    if len(args) > 1:
        host = String(args[1])
    if len(args) > 2:
        port = Int(args[2])

    var r = Redis(host, port)
    print("PING ->", r.ping())

    _ = r.flushdb()
    _ = r.set("greeting", "hello from mojo")
    print("GET greeting ->", r.get("greeting").value())

    _ = r.set("session", "abc", ex=60)
    print("TTL session ->", r.ttl("session"))

    _ = r.set("counter", "10")
    print("INCR counter ->", r.incr("counter"))
    print("DECR counter ->", r.decr("counter"))

    _ = r.rpush("tasks", "a")
    _ = r.rpush("tasks", "b")
    _ = r.lpush("tasks", "z")
    var items = r.lrange("tasks", 0, -1)
    print("LRANGE tasks ->", end=" ")
    for it in items:
        print(it, end=" ")
    print()

    _ = r.hset("user:1", "name", "Conor")
    _ = r.hset("user:1", "city", "Tumwater")
    var fields = r.hgetall("user:1")
    print("HGETALL user:1 ->", end=" ")
    for entry in fields.items():
        print(entry.key + "=" + entry.value, end=" ")
    print()

    var missing = r.get("does-not-exist")
    print("GET missing is None ->", not Bool(missing))

    r.close()
    print("done")
