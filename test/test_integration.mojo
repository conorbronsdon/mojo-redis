"""Integration tests against a live Redis server.

These exercise the full stack — libc socket transport, RESP2
serialization, reply parsing, and every typed client method — by talking
to a real server over TCP. They are NOT part of the default `test` task
or CI (no server there); run them explicitly:

    redis-server --port 6399 --daemonize yes --save "" --appendonly no
    REDIS_PORT=6399 mojo run -I src test/test_integration.mojo

Host/port come from the `REDIS_HOST` / `REDIS_PORT` environment
variables (defaults `127.0.0.1:6379`). Each test opens its own
connection and calls `FLUSHDB` first, so tests are order-independent and
leave no shared state. They run against a throwaway server/db — do not
point them at production data.
"""

from std.os import getenv
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from redis import Redis


def _client() raises -> Redis:
    var host = getenv("REDIS_HOST", "127.0.0.1")
    var port = Int(getenv("REDIS_PORT", "6379"))
    var r = Redis(host, port)
    _ = r.flushdb()
    return r^


def test_ping() raises:
    var r = _client()
    assert_equal(r.ping(), "PONG")


def test_set_get() raises:
    var r = _client()
    assert_true(r.set("k", "v"))
    assert_equal(r.get("k").value(), "v")


def test_get_missing_is_none() raises:
    var r = _client()
    var v = r.get("nope")
    assert_false(Bool(v))


def test_set_with_expiry_and_ttl() raises:
    var r = _client()
    _ = r.set("s", "1", ex=100)
    var ttl = r.ttl("s")
    assert_true(ttl > 0 and ttl <= 100)


def test_ttl_no_expiry_and_missing() raises:
    var r = _client()
    _ = r.set("perm", "1")
    assert_equal(r.ttl("perm"), -1)  # exists, no TTL
    assert_equal(r.ttl("ghost"), -2)  # no such key


def test_incr_decr() raises:
    var r = _client()
    assert_equal(r.incr("c"), 1)
    assert_equal(r.incr("c"), 2)
    assert_equal(r.decr("c"), 1)


def test_exists() raises:
    var r = _client()
    assert_equal(r.exists("x"), 0)
    _ = r.set("x", "1")
    assert_equal(r.exists("x"), 1)


def test_delete() raises:
    var r = _client()
    _ = r.set("d", "1")
    assert_equal(r.delete("d"), 1)
    assert_equal(r.delete("d"), 0)


def test_delete_keys() raises:
    var r = _client()
    _ = r.set("a", "1")
    _ = r.set("b", "2")
    assert_equal(r.delete_keys(["a", "b", "missing"]), 2)


def test_expire() raises:
    var r = _client()
    _ = r.set("e", "1")
    assert_true(r.expire("e", 50))
    var ttl = r.ttl("e")
    assert_true(ttl > 0 and ttl <= 50)


def test_keys() raises:
    var r = _client()
    _ = r.set("k1", "1")
    _ = r.set("k2", "2")
    var ks = r.keys("*")
    assert_equal(len(ks), 2)


def test_list_push_range_pop() raises:
    var r = _client()
    assert_equal(r.rpush("L", "a"), 1)
    assert_equal(r.rpush("L", "b"), 2)
    assert_equal(r.lpush("L", "z"), 3)
    var items = r.lrange("L", 0, -1)
    assert_equal(len(items), 3)
    assert_equal(items[0], "z")
    assert_equal(items[1], "a")
    assert_equal(items[2], "b")
    assert_equal(r.lpop("L").value(), "z")
    assert_equal(r.rpop("L").value(), "b")


def test_lpop_empty_is_none() raises:
    var r = _client()
    var v = r.lpop("empty-list")
    assert_false(Bool(v))


def test_hash_ops() raises:
    var r = _client()
    assert_equal(r.hset("h", "f1", "v1"), 1)
    _ = r.hset("h", "f2", "v2")
    assert_equal(r.hget("h", "f1").value(), "v1")
    var all = r.hgetall("h")
    assert_equal(len(all), 2)
    assert_equal(all["f1"], "v1")
    assert_equal(all["f2"], "v2")


def test_hget_missing_is_none() raises:
    var r = _client()
    _ = r.hset("h", "f1", "v1")
    var v = r.hget("h", "nope")
    assert_false(Bool(v))


def test_flushdb() raises:
    var r = _client()
    _ = r.set("k", "1")
    assert_true(r.flushdb())
    assert_equal(r.exists("k"), 0)


def test_execute_escape_hatch() raises:
    var r = _client()
    _ = r.set("k", "hello")
    var reply = r.execute(["STRLEN", "k"])
    assert_equal(reply.as_int(), 5)


def test_error_reply_raises() raises:
    var r = _client()
    _ = r.set("str", "not-a-number")
    var raised = False
    try:
        _ = r.incr("str")  # INCR on a non-integer value -> RESP error
    except e:
        raised = True
    assert_true(raised)


def test_pipeline() raises:
    var r = _client()
    var pipe = Redis.pipeline()
    pipe.set("p", "100")
    pipe.incr("p")
    pipe.incr("p")
    pipe.get("p")
    var replies = r.execute_pipeline(pipe)
    assert_equal(len(replies), 4)
    assert_true(replies[0].as_bool())  # SET -> OK
    assert_equal(replies[1].as_int(), 101)
    assert_equal(replies[2].as_int(), 102)
    assert_equal(replies[3].as_string(), "102")


def test_unicode_roundtrip() raises:
    var r = _client()
    _ = r.set("u", "héllo 🔥")
    assert_equal(r.get("u").value(), "héllo 🔥")


def test_large_value_spanning_recv() raises:
    # A value bigger than the 4096-byte recv chunk forces the reply to
    # arrive across multiple recv calls, exercising incremental parsing
    # over the real socket.
    var r = _client()
    var big = String()
    for _ in range(20000):
        big += "x"
    _ = r.set("big", big)
    assert_equal(r.get("big").value().byte_length(), 20000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
