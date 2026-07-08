"""Offline throughput benchmark for the RESP2 serializer and parser.

Network-free: serializes commands with `encode_command` and decodes canned
replies with `parse_reply` over in-memory byte buffers — the same pure
protocol path `test/test_resp.mojo` exercises, so no Redis server is
required. Run compiled for meaningful numbers:
`mojo build -I src bench/bench_resp.mojo -o .bench_resp && ./.bench_resp`
(or `pixi run bench`).
"""
from std.time import perf_counter_ns

from redis.resp import encode_command, parse_reply


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _report(name: String, bytes_per_op: Int, iterations: Int, elapsed_ns: UInt):
    var ns_per_op = Float64(elapsed_ns) / Float64(iterations)
    var mb_per_s = (
        Float64(bytes_per_op)
        * Float64(iterations)
        / (1024.0 * 1024.0)
        / (Float64(elapsed_ns) / 1e9)
    )
    print(name)
    print(t"  {bytes_per_op} bytes/op, {ns_per_op} ns/op, {mb_per_s} MB/s")


def bench_encode(name: String, args: List[String], iterations: Int) raises:
    # Warmup + correctness anchor: the encoded size must be stable.
    var warm = encode_command(args)
    var size = len(warm)
    var start = perf_counter_ns()
    for _ in range(iterations):
        var buf = encode_command(args)
        if len(buf) != size:
            raise Error("inconsistent encode")
    var elapsed_ns = perf_counter_ns() - start
    _report(name, size, iterations, elapsed_ns)


def bench_parse(name: String, payload: String, iterations: Int) raises:
    var data = _bytes(payload)
    # Warmup + correctness anchor: the reply must decode completely.
    var warm = parse_reply(Span(data))
    if not warm.ok or warm.consumed != len(data):
        raise Error("canned reply did not decode as one complete reply")
    var start = perf_counter_ns()
    for _ in range(iterations):
        var result = parse_reply(Span(data))
        if result.consumed != len(data):
            raise Error("inconsistent parse")
    var elapsed_ns = perf_counter_ns() - start
    _report(name, len(data), iterations, elapsed_ns)


def _array_of_bulk(count: Int, item: String) -> String:
    """A RESP2 array of `count` bulk strings (an LRANGE-shaped reply)."""
    var out = String("*") + String(count) + "\r\n"
    for _ in range(count):
        out += "$" + String(item.byte_length()) + "\r\n" + item + "\r\n"
    return out^


def main() raises:
    bench_encode("encode PING", ["PING"], 200_000)
    bench_encode(
        "encode SET key value",
        ["SET", "session:12345", "value-abcdef"],
        200_000,
    )
    var payload = String("x") * 512
    bench_encode("encode SET 512B payload", ["SET", "blob:1", payload], 100_000)

    bench_parse("parse simple string (+OK)", "+OK\r\n", 200_000)
    bench_parse("parse integer (:1000)", ":1000\r\n", 200_000)
    bench_parse(
        "parse 512B bulk string", "$512\r\n" + payload + "\r\n", 100_000
    )
    bench_parse(
        "parse 100-element array of bulk strings",
        _array_of_bulk(100, "list-item-payload"),
        20_000,
    )
