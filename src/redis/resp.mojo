"""RESP2 wire-protocol serializer and parser for mojo-redis.

This module is pure and network-free: it turns command argument lists
into RESP2 request bytes and turns raw reply bytes back into
`RespValue` trees. It is the value core of the client — the transport
(`connection.mojo`) only moves bytes; all protocol meaning lives here.

RESP2 reply types and how they map to `RespValue`:

- Simple string  `+OK\r\n`              -> kind `RESP_STRING`
- Error          `-ERR msg\r\n`         -> kind `RESP_ERROR`
- Integer        `:1000\r\n`            -> kind `RESP_INT`
- Bulk string    `$5\r\nhello\r\n`      -> kind `RESP_BULK`
- Null bulk      `$-1\r\n`              -> kind `RESP_NIL`
- Array          `*2\r\n...`            -> kind `RESP_ARRAY` (may nest)
- Null array     `*-1\r\n`              -> kind `RESP_NIL`

The parser is **incremental-safe**: `parse_reply` is handed the bytes
accumulated so far and, if the buffer does not yet hold one complete
reply, returns a result with `ok == False` and `consumed == 0` so the
caller can `recv` more and try again. It never partially consumes a
buffer — a reply is either fully decoded or not decoded at all. This is
what lets a reply split across several `recv` calls parse correctly.
"""

from std.memory import ArcPointer

comptime RESP_STRING = 0  # simple string   (+)
comptime RESP_ERROR = 1  # error            (-)
comptime RESP_INT = 2  # integer            (:)
comptime RESP_BULK = 3  # bulk string       ($)
comptime RESP_ARRAY = 4  # array            (*)
comptime RESP_NIL = 5  # null bulk / null array

comptime _CR = UInt8(0x0D)
comptime _LF = UInt8(0x0A)
comptime _MINUS = UInt8(ord("-"))
comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))

# Cap on RESP array nesting. `_parse` recurses one level per array, so an
# adversarial reply of many stacked `*1\r\n` headers would otherwise blow
# the native stack. Real RESP2 replies nest only a handful of levels; the
# sibling libraries cap analogous recursion at 256, and 128 is ample here.
comptime _MAX_DEPTH = 128


struct RespValue(Copyable, Movable, Writable):
    """A decoded RESP2 reply value.

    A single struct models all five reply types (plus the null niche)
    so arrays can nest heterogeneously. Only the field(s) relevant to
    `kind` are meaningful; the others carry zero/empty defaults.
    """

    var kind: Int
    var text: String  # simple string, error message, or bulk payload
    var number: Int  # integer replies
    # Array elements. Boxed in `ArcPointer` to break the type recursion —
    # a struct cannot contain a `List` of itself by value. Kept private;
    # callers reach elements through `count()` / `at()`.
    var _items: List[ArcPointer[RespValue]]

    def __init__(out self, kind: Int, var text: String, number: Int):
        self.kind = kind
        self.text = text^
        self.number = number
        self._items = List[ArcPointer[RespValue]]()

    def __init__(out self, var items: List[ArcPointer[RespValue]]):
        self.kind = RESP_ARRAY
        self.text = String()
        self.number = 0
        self._items = items^

    @staticmethod
    def simple(var s: String) -> Self:
        return Self(RESP_STRING, s^, 0)

    @staticmethod
    def error(var s: String) -> Self:
        return Self(RESP_ERROR, s^, 0)

    @staticmethod
    def integer(n: Int) -> Self:
        return Self(RESP_INT, String(), n)

    @staticmethod
    def bulk(var s: String) -> Self:
        return Self(RESP_BULK, s^, 0)

    @staticmethod
    def nil() -> Self:
        return Self(RESP_NIL, String(), 0)

    @staticmethod
    def array(var items: List[ArcPointer[RespValue]]) -> Self:
        return Self(items^)

    def count(self) -> Int:
        """Number of elements (0 for any non-array reply)."""
        return len(self._items)

    def at(self, i: Int) -> RespValue:
        """Copy of array element `i`. Caller must ensure `i < count()`."""
        return self._items[i][].copy()

    def is_nil(self) -> Bool:
        return self.kind == RESP_NIL

    def is_error(self) -> Bool:
        return self.kind == RESP_ERROR

    def check(self) raises:
        """Raise if this reply is a RESP error, otherwise do nothing."""
        if self.kind == RESP_ERROR:
            raise Error("redis error: " + self.text)

    def as_string(self) raises -> String:
        """String payload of a simple or bulk reply (raises otherwise)."""
        self.check()
        if self.kind == RESP_STRING or self.kind == RESP_BULK:
            return self.text.copy()
        if self.kind == RESP_INT:
            return String(self.number)
        if self.kind == RESP_NIL:
            raise Error("redis: expected a string, got nil")
        raise Error("redis: reply is not a string")

    def as_string_opt(self) raises -> Optional[String]:
        """`None` for a nil reply, else the string payload."""
        self.check()
        if self.kind == RESP_NIL:
            return None
        return self.as_string()

    def as_int(self) raises -> Int:
        """Integer value of an integer reply (or a numeric bulk string)."""
        self.check()
        if self.kind == RESP_INT:
            return self.number
        if self.kind == RESP_BULK or self.kind == RESP_STRING:
            return _atoi(self.text)
        raise Error("redis: reply is not an integer")

    def as_bool(self) raises -> Bool:
        """Truthiness: integer != 0, or the simple string `OK`."""
        self.check()
        if self.kind == RESP_INT:
            return self.number != 0
        if self.kind == RESP_STRING:
            return self.text == "OK"
        if self.kind == RESP_NIL:
            return False
        return True

    def as_string_list(self) raises -> List[String]:
        """Flatten an array reply to a list of strings (nil -> empty)."""
        self.check()
        var out = List[String]()
        if self.kind == RESP_NIL:
            return out^
        if self.kind != RESP_ARRAY:
            raise Error("redis: reply is not an array")
        for item in self._items:
            if item[].is_nil():
                out.append(String())
            else:
                out.append(item[].as_string())
        return out^

    def write_to(self, mut writer: Some[Writer]):
        if self.kind == RESP_STRING:
            writer.write("+", self.text)
        elif self.kind == RESP_ERROR:
            writer.write("-", self.text)
        elif self.kind == RESP_INT:
            writer.write(":", self.number)
        elif self.kind == RESP_BULK:
            writer.write("$", self.text)
        elif self.kind == RESP_NIL:
            writer.write("(nil)")
        else:
            writer.write("[")
            for i in range(len(self._items)):
                if i > 0:
                    writer.write(", ")
                self._items[i][].write_to(writer)
            writer.write("]")


def _atoi(s: String) raises -> Int:
    """Parse a (possibly negative) base-10 integer. Non-digits stop scan.

    Raises on overflow. A hostile server can send a header with far more
    digits than fit in a 64-bit Int (e.g. a 20-digit bulk length that
    wraps `Int` negative and defeats the incomplete-guard bounds check),
    so the scan is capped at 18 significant digits — the widest value
    that can never overflow `Int` — and also rejects any multiply/add
    that wraps the accumulator negative.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = 0
    var neg = False
    if n > 0 and bytes[0] == _MINUS:
        neg = True
        i = 1
    var value = 0
    var digits = 0
    while i < n and bytes[i] >= _ZERO and bytes[i] <= _NINE:
        digits += 1
        if digits > 18:
            raise Error("redis: integer literal too large")
        value = value * 10 + Int(bytes[i]) - ord("0")
        if value < 0:
            raise Error("redis: integer literal overflow")
        i += 1
    return -value if neg else value


# ──────────────────────────────────────────────────────────────────────────────
# Serialization
# ──────────────────────────────────────────────────────────────────────────────


def _append_str(mut buf: List[UInt8], s: String):
    for b in s.as_bytes():
        buf.append(b)


def _append_crlf(mut buf: List[UInt8]):
    buf.append(_CR)
    buf.append(_LF)


def encode_command(args: List[String]) -> List[UInt8]:
    """Serialize a command as a RESP2 array of bulk strings.

    Produces `*<N>\\r\\n` followed by `$<len>\\r\\n<arg>\\r\\n` per
    argument. `<len>` is the argument's **byte** length, so non-ASCII
    values are framed correctly.
    """
    var out = List[UInt8]()
    _append_str(out, "*")
    _append_str(out, String(len(args)))
    _append_crlf(out)
    for arg in args:
        _append_str(out, "$")
        _append_str(out, String(arg.byte_length()))
        _append_crlf(out)
        _append_str(out, arg)
        _append_crlf(out)
    return out^


# ──────────────────────────────────────────────────────────────────────────────
# Parsing (incremental-safe)
# ──────────────────────────────────────────────────────────────────────────────


struct ParseResult(Copyable, Movable):
    """Outcome of one parse attempt over an accumulating byte buffer.

    `ok == False` means the buffer does not yet contain a complete
    reply (need more bytes); `consumed` is then 0. On success `consumed`
    is the number of bytes the one decoded reply occupied.
    """

    var ok: Bool
    var consumed: Int
    var value: RespValue

    def __init__(out self, ok: Bool, consumed: Int, var value: RespValue):
        self.ok = ok
        self.consumed = consumed
        self.value = value^

    @staticmethod
    def incomplete() -> Self:
        return Self(False, 0, RespValue.nil())

    def take_value(deinit self) -> RespValue:
        """Move the decoded value out, consuming the result."""
        return self.value^


def _find_crlf(data: Span[UInt8, _], start: Int) -> Int:
    """Index of the `\\r` in the next `\\r\\n`, or -1 if none from `start`."""
    var i = start
    var n = len(data)
    while i + 1 < n:
        if data[i] == _CR and data[i + 1] == _LF:
            return i
        i += 1
    return -1


def _parse(
    data: Span[UInt8, _], offset: Int, depth: Int = 0
) raises -> ParseResult:
    """Parse one reply starting at `offset`. `consumed` is relative to
    `offset`. Returns an incomplete result if the buffer is too short.

    `depth` tracks array-nesting recursion and is bounded by `_MAX_DEPTH`
    so a hostile deeply-nested reply cannot overflow the stack."""
    var n = len(data)
    if offset >= n:
        return ParseResult.incomplete()
    var kind_byte = data[offset]
    var cr = _find_crlf(data, offset + 1)
    if cr == -1:
        return ParseResult.incomplete()
    var header = String(StringSlice(unsafe_from_utf8=data[offset + 1 : cr]))
    var after = cr + 2  # first byte past the header line's CRLF

    if kind_byte == UInt8(ord("+")):
        return ParseResult(True, after - offset, RespValue.simple(header^))
    if kind_byte == UInt8(ord("-")):
        return ParseResult(True, after - offset, RespValue.error(header^))
    if kind_byte == UInt8(ord(":")):
        return ParseResult(
            True, after - offset, RespValue.integer(_atoi(header))
        )
    if kind_byte == UInt8(ord("$")):
        var length = _atoi(header)
        if length == -1:
            return ParseResult(True, after - offset, RespValue.nil())
        if length < -1:
            # Only `-1` (null bulk) is a legal negative length.
            raise Error("redis: invalid bulk-string length")
        # A complete bulk string's body plus its trailing CRLF must already
        # fit in the buffer window past the header. If `length` is larger,
        # the reply is either not yet fully received (incomplete) or hostile
        # — never materialize a span past the buffer. The comparison is in
        # subtractive form so a large `length` cannot overflow the addition
        # and wrap negative (which would defeat the guard).
        if length > n - after - 2:
            return ParseResult.incomplete()
        var payload = String(
            StringSlice(unsafe_from_utf8=data[after : after + length])
        )
        return ParseResult(
            True, after + length + 2 - offset, RespValue.bulk(payload^)
        )
    if kind_byte == UInt8(ord("*")):
        if depth >= _MAX_DEPTH:
            raise Error("redis: array nesting too deep")
        var count = _atoi(header)
        if count < 0:
            return ParseResult(True, after - offset, RespValue.nil())
        var items = List[ArcPointer[RespValue]]()
        var pos = after
        for _ in range(count):
            var element = _parse(data, pos, depth + 1)
            if not element.ok:
                return ParseResult.incomplete()
            pos += element.consumed
            items.append(ArcPointer(element^.take_value()))
        return ParseResult(True, pos - offset, RespValue.array(items^))

    raise Error(
        "redis: unknown RESP type byte " + String(Int(kind_byte))
    )


def parse_reply(data: Span[UInt8, _]) raises -> ParseResult:
    """Attempt to decode one complete reply from the front of `data`.

    Incremental-safe: if `data` does not yet hold a full reply this
    returns `ParseResult.incomplete()` (nothing consumed). Raises only
    on a genuine protocol violation (an unknown leading type byte).
    """
    return _parse(data, 0)
