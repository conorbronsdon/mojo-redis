"""TCP transport for mojo-redis, over direct libc FFI.

## Transport choice

v0.1 talks to Redis over a blocking IPv4 TCP socket opened with direct
`external_call`s into libc — `socket(2)`, `connect(2)`, `send(2)`,
`recv(2)`, `close(2)` — rather than depending on a networking library.
Rationale: the Mojo networking option (ehsanmok/flare) is distributed as
a pixi *git* dependency built with `pixi-build`, but this project (like
its siblings) uses a plain `uv` + `mojo` toolchain with no pixi-build
machinery, so pulling flare in cleanly was the painful path. Direct FFI
to the POSIX socket API is ~80 lines, has no third-party dependency, and
is a well-trodden pattern. The libc call signatures and the Linux
`sockaddr_in` byte layout below follow ehsanmok/flare's `flare/net`
socket module (MIT-licensed) for reference; no flare source is vendored.

The whole backend is isolated behind this one `Connection` struct: swap
it for a flare-backed or io_uring-backed implementation later and the
protocol layer and client are untouched.

## Scope (v0.1)

IPv4 only. `host` is either a dotted-quad address (`127.0.0.1`) or the
literal `localhost` (mapped to `127.0.0.1`); DNS resolution is not wired
up yet. Sockets are blocking; there is no connect/read timeout.
"""

from std.ffi import external_call
from std.memory import UnsafePointer, alloc

from .resp import RespValue, ParseResult, parse_reply, encode_command

comptime _AF_INET = Int32(2)
comptime _SOCK_STREAM = Int32(1)
comptime _SOCKADDR_IN_SIZE = 16
comptime _RECV_CHUNK = 4096


def _parse_ipv4(host: String) raises -> InlineArray[UInt8, 4]:
    """Parse a dotted-quad IPv4 address into 4 network-order bytes.

    `localhost` is accepted as a convenience alias for `127.0.0.1`. Any
    other non-numeric host raises — DNS is out of scope for v0.1.
    """
    var h = host
    if h == "localhost":
        h = String("127.0.0.1")
    var octets = InlineArray[UInt8, 4](fill=0)
    var bytes = h.as_bytes()
    var n = len(bytes)
    var idx = 0
    var value = 0
    var digits = 0
    var i = 0
    while i <= n:
        if i == n or bytes[i] == UInt8(ord(".")):
            if digits == 0 or idx > 3:
                raise Error("redis: invalid IPv4 host '" + host + "'")
            if value > 255:
                raise Error("redis: invalid IPv4 host '" + host + "'")
            octets[idx] = UInt8(value)
            idx += 1
            value = 0
            digits = 0
        elif bytes[i] >= UInt8(ord("0")) and bytes[i] <= UInt8(ord("9")):
            value = value * 10 + Int(bytes[i]) - ord("0")
            digits += 1
        else:
            raise Error("redis: invalid IPv4 host '" + host + "'")
        i += 1
    if idx != 4:
        raise Error("redis: invalid IPv4 host '" + host + "'")
    return octets


struct Connection(Movable):
    """A single blocking TCP connection to a Redis server.

    Owns the socket file descriptor and an internal read buffer holding
    bytes received but not yet parsed. `read_reply` drives the
    incremental parser, calling `recv` until one complete reply is
    available, so a reply split across packets is handled transparently.
    """

    var fd: Int32
    var host: String
    var port: Int
    var _buf: List[UInt8]  # received-but-unparsed bytes

    def __init__(out self, var host: String, port: Int):
        self.fd = -1
        self.host = host^
        self.port = port
        self._buf = List[UInt8]()

    def __del__(deinit self):
        if self.fd >= 0:
            _ = external_call["close", Int32](self.fd)

    def is_open(self) -> Bool:
        return self.fd >= 0

    def connect(mut self) raises:
        """Open the socket and connect to `host:port`."""
        if self.fd >= 0:
            return
        var octets = _parse_ipv4(self.host)
        var fd = external_call["socket", Int32](
            _AF_INET, _SOCK_STREAM, Int32(0)
        )
        if fd < 0:
            raise Error("redis: socket() failed (rc=" + String(fd) + ")")

        # Build a Linux sockaddr_in (16 bytes): family(2) port(2, BE)
        # addr(4, BE) then 8 zero padding bytes.
        var sa = alloc[UInt8](_SOCKADDR_IN_SIZE)
        for k in range(_SOCKADDR_IN_SIZE):
            (sa + k).init_pointee_copy(UInt8(0))
        (sa + 0).init_pointee_copy(UInt8(2))  # AF_INET low byte
        (sa + 1).init_pointee_copy(UInt8(0))  # AF_INET high byte
        (sa + 2).init_pointee_copy(UInt8((self.port >> 8) & 0xFF))
        (sa + 3).init_pointee_copy(UInt8(self.port & 0xFF))
        for k in range(4):
            (sa + 4 + k).init_pointee_copy(octets[k])

        var rc = external_call["connect", Int32](
            fd, sa, UInt32(_SOCKADDR_IN_SIZE)
        )
        sa.free()
        if rc < 0:
            _ = external_call["close", Int32](fd)
            raise Error(
                "redis: connect() to "
                + self.host
                + ":"
                + String(self.port)
                + " failed (rc="
                + String(rc)
                + "). Is a Redis server listening there?"
            )
        self.fd = fd

    def _send_all(mut self, data: List[UInt8]) raises:
        """Write every byte of `data`, looping over short writes."""
        if self.fd < 0:
            raise Error("redis: send on a closed connection")
        var total = len(data)
        var sent = 0
        var ptr = data.unsafe_ptr()
        while sent < total:
            var n = external_call["send", Int](
                self.fd, ptr + sent, total - sent, Int32(0)
            )
            if n <= 0:
                raise Error("redis: send() failed (rc=" + String(n) + ")")
            sent += n

    def send_command(mut self, args: List[String]) raises:
        """Serialize `args` as a RESP2 command and write it to the socket."""
        self._send_all(encode_command(args))

    def _fill_more(mut self) raises:
        """Block on one `recv`, appending received bytes to the buffer."""
        var chunk = alloc[UInt8](_RECV_CHUNK)
        var n = external_call["recv", Int](
            self.fd, chunk, _RECV_CHUNK, Int32(0)
        )
        if n == 0:
            chunk.free()
            raise Error("redis: connection closed by server")
        if n < 0:
            chunk.free()
            raise Error("redis: recv() failed (rc=" + String(n) + ")")
        for k in range(n):
            self._buf.append((chunk + k).load())
        chunk.free()

    def read_reply(mut self) raises -> RespValue:
        """Read and decode exactly one reply, blocking until it is complete.

        Any bytes received past the end of this reply stay in the buffer
        for the next call — which is what makes pipelining work.
        """
        if self.fd < 0:
            raise Error("redis: read on a closed connection")
        while True:
            var result = parse_reply(Span(self._buf))
            if result.ok:
                # Drop the consumed prefix, keep any trailing bytes.
                var remainder = List[UInt8]()
                for i in range(result.consumed, len(self._buf)):
                    remainder.append(self._buf[i])
                self._buf = remainder^
                return result^.take_value()
            self._fill_more()

    def close(mut self):
        """Close the socket if open. Idempotent."""
        if self.fd >= 0:
            _ = external_call["close", Int32](self.fd)
            self.fd = -1
        self._buf = List[UInt8]()
