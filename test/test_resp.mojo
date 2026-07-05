"""Protocol unit tests for the RESP2 serializer and parser.

Pure and network-free: every test here exercises `encode_command` /
`parse_reply` over in-memory byte buffers, including the split-buffer
(incremental) path that a real socket would produce. No Redis server is
required to run this suite.
"""

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)

from redis.resp import (
    RespValue,
    ParseResult,
    parse_reply,
    encode_command,
    RESP_STRING,
    RESP_ERROR,
    RESP_INT,
    RESP_BULK,
    RESP_ARRAY,
    RESP_NIL,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _encoded_str(args: List[String]) -> String:
    var buf = encode_command(args)
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


# ── Serialization ─────────────────────────────────────────────────────────────


def test_encode_single_command() raises:
    assert_equal(_encoded_str(["PING"]), "*1\r\n$4\r\nPING\r\n")


def test_encode_set_command() raises:
    assert_equal(
        _encoded_str(["SET", "key", "value"]),
        "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n",
    )


def test_encode_empty_arg() raises:
    assert_equal(
        _encoded_str(["SET", "k", ""]),
        "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n",
    )


def test_encode_uses_byte_length() raises:
    # "é" is two UTF-8 bytes, so the bulk length must be 2, not 1.
    assert_equal(_encoded_str(["é"]), "*1\r\n$2\r\né\r\n")


def test_encode_value_with_crlf() raises:
    # Embedded CRLF is length-framed, not a delimiter.
    assert_equal(
        _encoded_str(["SET", "k", "a\r\nb"]),
        "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$4\r\na\r\nb\r\n",
    )


# ── Parsing: the five reply types ────────────────────────────────────────────


def test_parse_simple_string() raises:
    var r = parse_reply(Span(_bytes("+OK\r\n")))
    assert_true(r.ok)
    assert_equal(r.consumed, 5)
    assert_equal(r.value.kind, RESP_STRING)
    assert_equal(r.value.text, "OK")


def test_parse_error() raises:
    var r = parse_reply(Span(_bytes("-ERR unknown command\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.kind, RESP_ERROR)
    assert_true(r.value.is_error())
    assert_equal(r.value.text, "ERR unknown command")


def test_parse_integer() raises:
    var r = parse_reply(Span(_bytes(":1000\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.kind, RESP_INT)
    assert_equal(r.value.number, 1000)


def test_parse_negative_integer() raises:
    var r = parse_reply(Span(_bytes(":-42\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.as_int(), -42)


def test_parse_bulk_string() raises:
    var r = parse_reply(Span(_bytes("$5\r\nhello\r\n")))
    assert_true(r.ok)
    assert_equal(r.consumed, 11)
    assert_equal(r.value.kind, RESP_BULK)
    assert_equal(r.value.text, "hello")


def test_parse_bulk_with_embedded_crlf() raises:
    var r = parse_reply(Span(_bytes("$4\r\na\r\nb\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.text, "a\r\nb")


def test_parse_empty_bulk_string() raises:
    var r = parse_reply(Span(_bytes("$0\r\n\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.kind, RESP_BULK)
    assert_equal(r.value.text, "")


def test_parse_nil_bulk() raises:
    var r = parse_reply(Span(_bytes("$-1\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.kind, RESP_NIL)
    assert_true(r.value.is_nil())


def test_parse_nil_array() raises:
    var r = parse_reply(Span(_bytes("*-1\r\n")))
    assert_true(r.ok)
    assert_true(r.value.is_nil())


def test_parse_array_of_bulk() raises:
    var r = parse_reply(Span(_bytes("*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.kind, RESP_ARRAY)
    assert_equal(r.value.count(), 2)
    assert_equal(r.value.at(0).text, "foo")
    assert_equal(r.value.at(1).text, "bar")


def test_parse_empty_array() raises:
    var r = parse_reply(Span(_bytes("*0\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.kind, RESP_ARRAY)
    assert_equal(r.value.count(), 0)


def test_parse_mixed_array() raises:
    var r = parse_reply(Span(_bytes("*3\r\n:1\r\n$3\r\ntwo\r\n:3\r\n")))
    assert_true(r.ok)
    assert_equal(r.value.at(0).number, 1)
    assert_equal(r.value.at(1).text, "two")
    assert_equal(r.value.at(2).number, 3)


def test_parse_nested_array() raises:
    # *2 [ *2 [:1 :2] , $5 hello ]
    var r = parse_reply(
        Span(_bytes("*2\r\n*2\r\n:1\r\n:2\r\n$5\r\nhello\r\n"))
    )
    assert_true(r.ok)
    assert_equal(r.value.kind, RESP_ARRAY)
    assert_equal(r.value.count(), 2)
    assert_equal(r.value.at(0).kind, RESP_ARRAY)
    assert_equal(r.value.at(0).at(0).number, 1)
    assert_equal(r.value.at(0).at(1).number, 2)
    assert_equal(r.value.at(1).text, "hello")


def test_parse_array_with_nil_element() raises:
    var r = parse_reply(Span(_bytes("*2\r\n$3\r\nfoo\r\n$-1\r\n")))
    assert_true(r.ok)
    assert_true(r.value.at(1).is_nil())
    var flat = r.value.as_string_list()
    assert_equal(len(flat), 2)
    assert_equal(flat[0], "foo")
    assert_equal(flat[1], "")


# ── Incremental (split-buffer) parsing ───────────────────────────────────────


def test_incomplete_no_crlf() raises:
    var r = parse_reply(Span(_bytes("+OK")))
    assert_false(r.ok)
    assert_equal(r.consumed, 0)


def test_incomplete_bulk_header_only() raises:
    var r = parse_reply(Span(_bytes("$5\r\n")))
    assert_false(r.ok)


def test_incomplete_bulk_body_short() raises:
    var r = parse_reply(Span(_bytes("$5\r\nhel")))
    assert_false(r.ok)


def test_incomplete_bulk_missing_trailing_crlf() raises:
    var r = parse_reply(Span(_bytes("$5\r\nhello")))
    assert_false(r.ok)


def test_incomplete_array_partial() raises:
    var r = parse_reply(Span(_bytes("*2\r\n$3\r\nfoo\r\n")))
    assert_false(r.ok)


def test_split_buffer_completes() raises:
    # Simulate a reply arriving across two recv calls: parse fails on the
    # first chunk, succeeds once the rest is appended.
    var buf = _bytes("$5\r\nhel")
    var first = parse_reply(Span(buf))
    assert_false(first.ok)
    for b in _bytes("lo\r\n"):
        buf.append(b)
    var second = parse_reply(Span(buf))
    assert_true(second.ok)
    assert_equal(second.value.text, "hello")


def test_consumed_leaves_pipeline_remainder() raises:
    # Two replies back-to-back: parsing the first reports exactly its own
    # length, so the caller can advance and parse the second.
    var buf = _bytes("+OK\r\n:7\r\n")
    var first = parse_reply(Span(buf))
    assert_true(first.ok)
    assert_equal(first.consumed, 5)
    var rest = List[UInt8]()
    for i in range(first.consumed, len(buf)):
        rest.append(buf[i])
    var second = parse_reply(Span(rest))
    assert_true(second.ok)
    assert_equal(second.value.number, 7)


# ── Accessors / error handling ───────────────────────────────────────────────


def test_as_string_opt_nil() raises:
    var r = parse_reply(Span(_bytes("$-1\r\n")))
    var opt = r.value.as_string_opt()
    assert_false(Bool(opt))


def test_as_string_opt_present() raises:
    var r = parse_reply(Span(_bytes("$3\r\nfoo\r\n")))
    var opt = r.value.as_string_opt()
    assert_true(Bool(opt))
    assert_equal(opt.value(), "foo")


def test_check_raises_on_error() raises:
    var r = parse_reply(Span(_bytes("-WRONGTYPE nope\r\n")))
    var raised = False
    try:
        r.value.check()
    except e:
        raised = True
    assert_true(raised)


# ── Adversarial / hostile-input hardening ────────────────────────────────────


def test_bulk_length_overflow_raises() raises:
    # A >19-digit bulk length would wrap `Int` negative and defeat the
    # incomplete-guard bounds check, yielding a negative-length OOB span.
    # It must now raise cleanly instead.
    with assert_raises():
        _ = parse_reply(Span(_bytes("$18446744073709551615\r\n")))


def test_bulk_length_huge_digits_raises() raises:
    with assert_raises():
        _ = parse_reply(Span(_bytes("$99999999999999999999\r\n")))


def test_bulk_length_invalid_negative_raises() raises:
    # Only `-1` is a legal negative bulk length; anything more negative is
    # a protocol violation, not a null.
    with assert_raises():
        _ = parse_reply(Span(_bytes("$-5\r\nhello\r\n")))


def test_integer_reply_overflow_raises() raises:
    # A 26-digit integer reply must raise rather than silently wrapping.
    with assert_raises():
        _ = parse_reply(Span(_bytes(":99999999999999999999999999\r\n")))


def test_deep_nesting_raises() raises:
    # 500 stacked `*1\r\n` headers would recurse 500 deep and overflow the
    # native stack; the depth cap must reject it with a clean error.
    var s = String()
    for _ in range(500):
        s += "*1\r\n"
    with assert_raises():
        _ = parse_reply(Span(_bytes(s)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
