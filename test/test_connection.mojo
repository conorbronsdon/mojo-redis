"""Transport-layer regression tests for `Connection`.

Unlike `test_integration.mojo`, these need **no** Redis server: each test
stands up its own throwaway loopback TCP peer via libc FFI, so the suite is
self-contained and safe to run in CI.

The headline test is `test_send_on_dead_connection_raises`, which pins the
SIGPIPE fix: writing to a socket whose peer has closed must surface a
*catchable* `Error`, not deliver SIGPIPE and kill the whole process. Before
the fix this test does not merely fail — it terminates the test binary with
signal 13 (exit 141), taking every other test down with it. That crash *is*
the regression signal.
"""

from std.ffi import external_call
from std.memory import UnsafePointer, alloc
from std.time import sleep
from std.testing import assert_true, assert_false, TestSuite

from redis.connection import Connection

comptime _AF_INET = Int32(2)
comptime _SOCK_STREAM = Int32(1)
comptime _SOL_SOCKET = Int32(0xFFFF)
comptime _SO_REUSEADDR = Int32(0x0004)


@fieldwise_init
struct _Listener(Copyable, Movable):
    var fd: Int32
    var port: Int


def _spawn_loopback_listener() raises -> _Listener:
    """Bind+listen on an ephemeral 127.0.0.1 port. Returns fd + chosen port.

    Nothing is accepted yet: a client `connect()` completes against the
    kernel's accept queue, and the caller accepts+closes it afterwards.
    """
    var fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
    if fd < 0:
        raise Error("test listener: socket() failed")

    var one = alloc[Int32](1)
    one.init_pointee_copy(Int32(1))
    _ = external_call["setsockopt", Int32](
        fd, _SOL_SOCKET, _SO_REUSEADDR, one, UInt32(4)
    )
    one.free()

    # sockaddr_in with port 0 -> kernel picks a free ephemeral port.
    var sa = alloc[UInt8](16)
    for k in range(16):
        (sa + k).init_pointee_copy(UInt8(0))
    (sa + 0).init_pointee_copy(UInt8(2))  # AF_INET
    (sa + 4).init_pointee_copy(UInt8(127))  # 127.0.0.1
    (sa + 7).init_pointee_copy(UInt8(1))
    var brc = external_call["bind", Int32](fd, sa, UInt32(16))
    if brc < 0:
        sa.free()
        _ = external_call["close", Int32](fd)
        raise Error("test listener: bind() failed")

    # Read back the assigned port via getsockname (BE bytes 2..3).
    var alen = alloc[UInt32](1)
    alen.init_pointee_copy(UInt32(16))
    var grc = external_call["getsockname", Int32](fd, sa, alen)
    alen.free()
    if grc < 0:
        sa.free()
        _ = external_call["close", Int32](fd)
        raise Error("test listener: getsockname() failed")
    var port = (Int((sa + 2).load()) << 8) | Int((sa + 3).load())
    sa.free()

    if external_call["listen", Int32](fd, Int32(1)) < 0:
        _ = external_call["close", Int32](fd)
        raise Error("test listener: listen() failed")
    return _Listener(fd, port)


def _accept_then_close_cleanly(listen_fd: Int32) raises:
    """Accept the queued connection and close it with no unread data, so the
    peer sees a clean FIN (the case that yields EPIPE, hence SIGPIPE)."""
    var addr = alloc[UInt8](16)
    var alen = alloc[UInt32](1)
    alen.init_pointee_copy(UInt32(16))
    var cfd = external_call["accept", Int32](listen_fd, addr, alen)
    addr.free()
    alen.free()
    if cfd >= 0:
        _ = external_call["close", Int32](cfd)
    _ = external_call["close", Int32](listen_fd)


def _accept(listen_fd: Int32) raises -> Int32:
    """Accept the queued connection and return its fd (kept open)."""
    var addr = alloc[UInt8](16)
    var alen = alloc[UInt32](1)
    alen.init_pointee_copy(UInt32(16))
    var cfd = external_call["accept", Int32](listen_fd, addr, alen)
    addr.free()
    alen.free()
    if cfd < 0:
        raise Error("test peer: accept() failed")
    return cfd


def _server_send(fd: Int32, s: String) raises:
    """Write raw bytes from the server side of the connection."""
    var b = s.as_bytes()
    var n = external_call["send", Int](fd, b.unsafe_ptr(), len(b), Int32(0))
    if n < 0:
        raise Error("test peer: send() failed")


def test_poisoned_connection_is_closed() raises:
    """A protocol/parse error must close the connection, not leave it reusable.

    Regression guard for the poisoned-connection fix. The server sends one
    corrupt reply (an unknown RESP type byte); `read_reply` must raise *and*
    close the socket, so a later command fails fast rather than misframing
    every subsequent reply. redis-py likewise disconnects on InvalidResponse.
    """
    var listener = _spawn_loopback_listener()

    var conn = Connection(String("127.0.0.1"), listener.port)
    conn.connect()
    var cfd = _accept(listener.fd)

    # `!` is not a valid RESP2 type byte -> the parser must reject it.
    _server_send(cfd, "!bogus\r\n")
    sleep(0.2)

    var raised = False
    try:
        _ = conn.read_reply()
    except:
        raised = True
    assert_true(raised, "a corrupt reply should raise")

    # The poisoned connection must now be closed, not left open for reuse.
    assert_false(
        conn.is_open(),
        "connection must be closed after a protocol error",
    )

    # A subsequent command must fail fast (closed) rather than misbehave.
    var raised_after = False
    try:
        conn.send_command(["PING"])
    except:
        raised_after = True
    assert_true(
        raised_after, "a command on a poisoned/closed connection must raise"
    )

    _ = external_call["close", Int32](cfd)
    _ = external_call["close", Int32](listener.fd)


def test_send_on_dead_connection_raises() raises:
    """A write to a server-closed socket must raise, not kill the process.

    Regression guard for the SIGPIPE fix (SO_NOSIGPIPE on macOS/BSD,
    MSG_NOSIGNAL on Linux). Reaching the assertion at all proves the signal
    was suppressed; the assertion proves the EPIPE surfaced as an `Error`.
    """
    var listener = _spawn_loopback_listener()

    var conn = Connection(String("127.0.0.1"), listener.port)
    conn.connect()
    _accept_then_close_cleanly(listener.fd)

    # Let the peer's FIN arrive before the first write.
    sleep(0.3)

    var raised = False
    try:
        # First write usually succeeds (buffered), peer replies RST; a
        # subsequent write hits the broken pipe. Loop to cross that edge.
        for _ in range(50):
            conn.send_command(["PING"])
            sleep(0.02)
    except:
        raised = True
    assert_true(
        raised, "send() on a dead connection should raise a catchable Error"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
