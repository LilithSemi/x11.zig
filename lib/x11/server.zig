//! X11 server transport: a unix-socket listener (`Server`), the per-client
//! connection state (`ServerConn`) with an incremental handshake + request
//! framing state machine, and a single-threaded poll() `Multiplexer` that
//! serves many clients concurrently. The typed request decoding/dispatch lives
//! in the executable (server_main.zig) behind the xproto wall; this module owns
//! transport, framing, the client registry, and the raw socket syscalls only.
const std = @import("std");

const wire = @import("wire.zig");
const server_state = @import("server_state.zig");
const server_loop = @import("server_loop.zig");

/// Hard ceiling on one request's total wire length (the 4-byte header plus
/// body), in bytes. This is the heap-backed `request_buf`'s cap, not the
/// core-protocol setup-advertised max (that stays 65535 units == 262140
/// bytes, unchanged, in wire.zig's SetupReplyParams): raised to 4 MiB so
/// BigReqEnable can advertise a real extended max (bigger than the setup
/// max, per spec) without the buffer being the bottleneck. A length field
/// claiming more than this ceiling is refused as malformed rather than
/// turned into an unbounded allocation. Reused (not re-literaled) from
/// server_loop.zig so frameRequest's own oversized-length check stays in
/// lockstep with this buffer's cap.
const max_request_bytes: usize = server_loop.max_request_bytes;

/// The SetupReply advertised to every accepted connection. SP-Server-1 has no
/// real framebuffer or window tree yet, so every client is handed the same
/// synthetic single-screen, single-visual setup (matches the canned setup
/// used in wire.zig's own round-trip test): a 640x480 24-bit TrueColor root
/// screen, a fixed root window/visual id, and a generous resource-id range.
const synthetic_setup = wire.SetupReplyParams{
    .resource_id_base = 0x00400000,
    .resource_id_mask = 0x001fffff,
    .vendor = "x11.zig",
    .min_keycode = 8,
    .max_keycode = 255,
    .root = 0x12a,
    .root_visual = 0x21,
    .width_px = 640,
    .height_px = 480,
    .root_depth = 24,
    .visual_id = 0x21,
    // Must match server_state.Display.default_colormap: the Display
    // pre-registers a real colormap resource under this id at init, so the
    // wire-advertised value has to agree or AllocColor(default) sees BadColor.
    .default_colormap = server_state.Display.default_colormap,
};

/// Faults from binding and listening on the well-known X11 unix-socket path.
/// Includes Allocator.Error because listen() also builds the initial
/// server_state.Display (which pre-creates the root window).
pub const ListenError = std.Io.net.UnixAddress.InitError ||
    std.Io.net.UnixAddress.ListenError ||
    error{DisplayPathTooLong} ||
    std.mem.Allocator.Error;

/// Faults from accepting one client connection. Includes Allocator.Error
/// because accept() now heap-allocates the ServerConn (mirroring
/// Connection.connect, so the reader/writer buffer pointers stay stable).
pub const AcceptError = std.Io.net.Server.AcceptError || std.mem.Allocator.Error;

/// Faults from reading and validating the client's SetupRequest and sending
/// back the SetupReply.
pub const HandshakeError = error{ConnectionClosed} ||
    wire.ParseSetupRequestError ||
    wire.EncodeSetupReplyError;

/// A connection is `.handshaking` until its SetupRequest is fully read and
/// answered, then `.established` for the request stream.
pub const ConnState = enum { handshaking, established };

/// Listens on the well-known X11 unix-socket path for one display number.
/// One `Server` accepts many `ServerConn`s; each connection is independent
/// after accept() returns.
pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    srv: std.Io.net.Server,
    /// Copy of the bound socket path (sockaddr_un's 108-byte cap), kept so
    /// deinit() can unlink it; the UnixAddress itself only borrows a caller
    /// slice, which does not outlive listen().
    path_buf: [108]u8 = undefined,
    path_len: usize = 0,
    /// The window-state resource table and tree every accepted connection's
    /// typed dispatch (server_main.zig) reads and mutates. One Display per
    /// listening Server, shared across all its concurrently-served connections;
    /// the single-threaded Multiplexer means no locking is needed.
    display: server_state.Display = undefined,
    /// Monotonic index of the next accepted client, used to hand each client a
    /// distinct resource-id range (see server_loop.resourceRangeForIndex).
    next_client_index: u32 = 0,
    /// Accept indices freed by disconnected clients, available for reuse. An
    /// index == a client's id == its resource-id-range selector; reusing one is
    /// safe only after that client's windows are destroyed and masks scrubbed
    /// (server_main gates releaseIndex on a successful cleanupClient).
    free_indices: std.ArrayListUnmanaged(u32) = .empty,

    /// Bind `/tmp/.X11-unix/X{display_num}`, unlinking any stale socket left
    /// behind by a previous crashed server first (ignoring the unlink
    /// error - most commonly FileNotFound, i.e. nothing to clean up; any
    /// other cause surfaces naturally as AddressInUse from listen() below).
    pub fn listen(gpa: std.mem.Allocator, io: std.Io, display_num: u16) ListenError!Server {
        var path_buf: [108]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{display_num}) catch
            return error.DisplayPathTooLong;
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const ua = try std.Io.net.UnixAddress.init(path);
        var srv = try ua.listen(io, .{});
        errdefer srv.deinit(io);

        var self: Server = .{ .gpa = gpa, .io = io, .srv = srv };
        @memcpy(self.path_buf[0..path.len], path);
        self.path_len = path.len;
        self.display = try server_state.Display.init(gpa, synthetic_setup.root, synthetic_setup.root_depth, synthetic_setup.visual_id);
        return self;
    }

    /// Accept one client socket and wrap it as a fresh, heap-allocated
    /// ServerConn: sequence counter at 0 (the first nextSeq() call bumps it
    /// to 1, matching the X11 wire's 1-based sequencing), atom allocation
    /// starting at 1000 (below the predefined atoms but comfortably clear of
    /// them), and the shared synthetic setup this server advertises to every
    /// client.
    ///
    /// Heap-allocated (mirroring Connection.connect) so the connection's
    /// address is stable for its whole lifetime: the Multiplexer keeps a
    /// pointer to it across many poll() passes, and `request_buf`/`out` are
    /// read and written in place rather than through a per-call reader/writer.
    /// The next accept index: recycle a freed one if available, else extend the
    /// monotonic counter.
    fn acquireIndex(self: *Server) u32 {
        if (self.free_indices.pop()) |idx| return idx;
        const idx = self.next_client_index;
        self.next_client_index +%= 1;
        return idx;
    }

    /// Return a disconnected client's index for reuse. Best-effort: if the
    /// free-list append can't allocate, the index is simply not recycled
    /// (monotonic allocation still works), never a leak or a double-use.
    pub fn releaseIndex(self: *Server, idx: u32) void {
        self.free_indices.append(self.gpa, idx) catch {};
    }

    pub fn accept(self: *Server) AcceptError!*ServerConn {
        const stream = try self.srv.accept(self.io);
        errdefer stream.close(self.io);
        const conn = try self.gpa.create(ServerConn);
        // Hand this client a distinct resource-id range so its ids never collide
        // with another client's in the shared Display.
        const idx = self.acquireIndex();
        var sp = synthetic_setup;
        const range = server_loop.resourceRangeForIndex(idx);
        sp.resource_id_base = range.base;
        sp.resource_id_mask = range.mask;
        conn.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .stream = stream,
            .seq = 0,
            .setup_params = sp,
        };
        conn.out = std.Io.Writer.Allocating.init(self.gpa);
        conn.client_id = idx;
        return conn;
    }

    /// Close the listening socket and unlink its path so a future listen() on
    /// the same display does not see a stale AddressInUse.
    pub fn deinit(self: *Server) void {
        self.display.deinit();
        self.srv.deinit(self.io);
        std.Io.Dir.cwd().deleteFile(self.io, self.path_buf[0..self.path_len]) catch {};
        self.free_indices.deinit(self.gpa);
    }
};

/// One accepted client connection: its socket plus the per-connection state
/// a typed dispatch loop needs (sequence counter, the advertised setup, the
/// client's declared byte order). The typed decoding
/// and dispatching itself lives in the executable layer (server_main.zig),
/// not here, since this module cannot import the generated `xproto` module
/// (xproto depends on x11, so the reverse import would be circular).
pub const ServerConn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    /// Last sequence number consumed by a request. 0 before the first
    /// request; nextSeq() bumps it (wrapping) once per request, so the first
    /// reply carries sequence 1, matching real X servers.
    seq: u16,
    setup_params: wire.SetupReplyParams,
    /// The byte order the client declared in its SetupRequest (0x6c -> little,
    /// 0x42 -> big), set once by handshake(). Callers outside this module
    /// (server_main.zig's typed dispatch) need this to interpret request
    /// bodies, since this module stays generic and never decodes them itself.
    client_endian: std.builtin.Endian = .little,
    /// Multiplexed-loop state: incremental input buffer cursor + in-memory
    /// outbound buffer. `state` gates handshake vs request framing.
    state: ConnState = .handshaking,
    /// Set by the multiplexer when this connection must be torn down; scans skip
    /// it and next() yields its single `.disconnected` before it is freed.
    dead: bool = false,
    /// Outbound reply+event bytes, built in memory by the typed dispatch and
    /// flushed to the socket by the Multiplexer (never blocks the encoder).
    out: std.Io.Writer.Allocating = undefined,
    /// Stable per-client identity (the Multiplexer's accept index). The Display
    /// stores this opaquely against selected event masks; deliverPending routes
    /// each fanned-out event back to the conn whose client_id matches.
    client_id: u32 = 0,
    /// SetCloseDownMode (op 112): 0 = DestroyAll (default), 1 = RetainPermanent,
    /// 2 = RetainTemporary. Read by the executable's `.disconnected` handler to
    /// decide between the normal destroy-everything teardown and retaining this
    /// client's resources (Display.retainClient). Values are validated (>2 ->
    /// BadValue) at the request arm, so only 0/1/2 ever land here.
    close_down_mode: u8 = 0,
    /// How many bytes at the head of `out` have already been written to the
    /// socket. Bytes `[out_sent .. out.writer.end]` are queued-but-unsent; the
    /// Multiplexer drains them across POLLOUT wakeups.
    out_sent: usize = 0,
    /// Persistent per-request scratch buffer that the incremental framing
    /// (`appendIn`/`takeRequest`) reads and borrows its returned slices from.
    /// Heap-grown on demand (starts empty, so an idle connection costs
    /// nothing) rather than a fixed inline array, since the cap is now 4MiB
    /// and most connections' requests never come close to that; capacity is
    /// retained across requests (see `consume`) so a busy connection doesn't
    /// thrash allocations. `request_buf.items.len` is the buffered byte
    /// count (there is no separate cursor field).
    request_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Set by BigReqEnable (BIG-REQUESTS major 128, minor 0): once true,
    /// frameRequest accepts the extended (units==0 + real u32 length) request
    /// form from this conn. False for every conn until it opts in.
    big_requests_enabled: bool = false,
    /// The full framed size (header + body, including the extended form's 4
    /// inserted-then-stripped big-length bytes) of the request `takeRequest`
    /// most recently returned. `consumeRequest`/the Multiplexer's staged
    /// consume drop this many bytes, NOT the decode slice's length -- the two
    /// differ by 4 on the extended path, where the decode slice has already
    /// had the big-length shifted out.
    frame_len: usize = 0,

    /// This connection's raw socket fd, for the Multiplexer's poll/read/write.
    pub fn fd(self: *ServerConn) std.posix.fd_t {
        return self.stream.socket.handle;
    }

    /// Append freshly-read bytes to the head-buffer. Overflow (a client whose
    /// unframed bytes exceed the max_request_bytes ceiling) is malformed
    /// input; OutOfMemory is a real but rare allocation failure growing the
    /// heap buffer. Either way the caller disconnects that client rather than
    /// growing without bound or limping along with a half-grown buffer.
    pub fn appendIn(self: *ServerConn, data: []const u8) (error{Overflow} || std.mem.Allocator.Error)!void {
        if (self.request_buf.items.len + data.len > max_request_bytes) return error.Overflow;
        try self.request_buf.appendSlice(self.gpa, data);
    }

    /// Drop `n` head bytes, shifting the remainder down. Retains capacity
    /// (shrinkRetainingCapacity, not a fresh alloc) so a busy connection's
    /// buffer settles at its working size instead of reallocating every
    /// request.
    fn consume(self: *ServerConn, n: usize) void {
        const len = self.request_buf.items.len;
        std.mem.copyForwards(u8, self.request_buf.items[0 .. len - n], self.request_buf.items[n..len]);
        self.request_buf.shrinkRetainingCapacity(len - n);
    }

    /// If a full SetupRequest is buffered, parse it, queue the SetupReply into
    /// `out`, consume the request bytes, flip to `.established`, and return
    /// true. Return false if more bytes are still needed. A malformed/oversized
    /// SetupRequest is a fault (caller disconnects). Pure: touches only the
    /// in-memory buffers, never the socket.
    pub fn tryHandshake(self: *ServerConn) HandshakeError!bool {
        const in_len = self.request_buf.items.len;
        if (in_len < 12) return false;
        const buf = self.request_buf.items[0..in_len];
        // Multi-byte fields are in the client's declared order (byte 0).
        const req_endian: std.builtin.Endian = if (buf[0] == 0x42) .big else .little;
        const name_len = std.mem.readInt(u16, buf[6..8], req_endian);
        const data_len = std.mem.readInt(u16, buf[8..10], req_endian);
        const total = 12 + wire.pad4(name_len) + wire.pad4(data_len);
        if (total > max_request_bytes) return error.MalformedSetupRequest;
        if (in_len < total) return false; // wait for the rest
        _ = try wire.parseSetupRequest(buf[0..total]);
        self.client_endian = req_endian;
        try wire.encodeSetupReply(&self.out.writer, self.client_endian, self.setup_params);
        self.consume(total);
        self.state = .established;
        return true;
    }

    /// Frame the next complete request (established state). Returns the bytes
    /// (borrowed from request_buf, valid until consumeRequest) or null if more
    /// bytes are needed. Malformed framing (zero length, or an oversized/zero
    /// extended length) is a fault. On the BIG-REQUESTS extended form, the
    /// body is NORMALIZED in place (the inserted 4-byte big-length shifted
    /// out) before the slice is returned, so every decoder downstream keeps
    /// seeing plain core-request framing -- generated variable decoders size
    /// trailing lists from the slice length, not the (now-stale, still-0)
    /// length field at bytes[2..4], so this is safe.
    pub fn takeRequest(self: *ServerConn) error{MalformedRequest}!?[]const u8 {
        switch (server_loop.frameRequest(self.request_buf.items, self.client_endian, self.big_requests_enabled)) {
            .incomplete => return null,
            .malformed => return error.MalformedRequest,
            .complete => |c| {
                self.frame_len = c.total;
                if (c.extended) {
                    // Shift the body down over the 4 big-length bytes at
                    // [4..8]: dest [4..total-4] <- src [8..total], same
                    // length (total-8), dest strictly before src, so the
                    // forward copy never reads bytes it hasn't copied yet.
                    std.mem.copyForwards(u8, self.request_buf.items[4 .. c.total - 4], self.request_buf.items[8..c.total]);
                    return self.request_buf.items[0 .. c.total - 4];
                }
                return self.request_buf.items[0..c.total];
            },
        }
    }

    /// Consume the request `takeRequest` returned. Uses `frame_len` (the full
    /// framed size), not `bytes.len` -- on the extended path the decode slice
    /// is 4 bytes shorter than the frame, having already had the big-length
    /// stripped out by takeRequest, so consuming bytes.len would leave 4
    /// stray bytes at the head of the next request.
    pub fn consumeRequest(self: *ServerConn, bytes: []const u8) void {
        std.debug.assert(bytes.len == self.frame_len or bytes.len + 4 == self.frame_len);
        self.consume(self.frame_len);
    }

    /// Cap on per-connection queued-but-unsent bytes (~16 max-size replies). A
    /// client that never drains would grow this without bound, so one that
    /// exceeds the cap is disconnected rather than exhausting server memory.
    pub const max_out_backlog: usize = 4 * 1024 * 1024;

    /// The Io.Writer the typed dispatch encodes replies/events into.
    pub fn outWriter(self: *ServerConn) *std.Io.Writer {
        return &self.out.writer;
    }

    /// The queued-but-unsent bytes (`[out_sent .. end]`).
    pub fn pendingOut(self: *ServerConn) []const u8 {
        return self.out.written()[self.out_sent..];
    }

    /// Count of queued-but-unsent bytes.
    pub fn queuedLen(self: *ServerConn) usize {
        return self.out.writer.end - self.out_sent;
    }

    /// Record that the socket accepted `n` more bytes from the head of the queue.
    pub fn advanceSent(self: *ServerConn, n: usize) void {
        self.out_sent += n;
    }

    /// Shift the unsent tail to the front so the buffer stays sized to the
    /// current backlog rather than cumulative traffic. Amortized: only reclaim
    /// the drained prefix once it is at least half the buffer, so a stalled
    /// (out_sent==0) or trickle-draining client cannot drive an O(end) memmove
    /// every request cycle (a CPU-amplification DoS). The backlog is still
    /// bounded by the queuedLen cap in flushConn; total buffer size stays ~2x
    /// the backlog.
    pub fn compactOut(self: *ServerConn) void {
        if (self.out_sent * 2 < self.out.writer.end) return; // not worth a memmove yet
        const w = &self.out.writer;
        const rem = w.end - self.out_sent;
        std.mem.copyForwards(u8, w.buffer[0..rem], w.buffer[self.out_sent..w.end]);
        w.end = rem;
        self.out_sent = 0;
    }

    /// Reset the queue after everything has been sent (retains capacity).
    pub fn clearOut(self: *ServerConn) void {
        self.out.writer.end = 0;
        self.out_sent = 0;
    }

    /// Advance and return the next request sequence number. X11 sequence
    /// numbers start at 1, so the first call after a fresh connection returns
    /// 1; wraps on overflow like a real server's.
    pub fn nextSeq(self: *ServerConn) u16 {
        self.seq +%= 1;
        return self.seq;
    }

    /// Close the client socket and free this heap-allocated ServerConn. Does
    /// not touch the listening Server.
    pub fn close(self: *ServerConn) void {
        self.out.deinit();
        self.request_buf.deinit(self.gpa);
        self.stream.close(self.io);
        self.gpa.destroy(self);
    }
};

test "ServerConn incremental handshake then framing (no sockets)" {
    const gpa = std.testing.allocator;
    // Heap-allocate: mirrors real accept() (a pointer the Multiplexer holds
    // across poll passes). Only the buffer/state fields are touched here (no
    // stream I/O).
    const conn = try gpa.create(ServerConn);
    defer gpa.destroy(conn);
    conn.gpa = gpa;
    conn.state = .handshaking;
    conn.request_buf = .empty;
    defer conn.request_buf.deinit(gpa);
    conn.client_endian = .little;
    conn.setup_params = synthetic_setup;
    conn.out = std.Io.Writer.Allocating.init(gpa);
    conn.out_sent = 0;
    defer conn.out.deinit();

    // A minimal 12-byte little-endian SetupRequest: byte0=0x6c, proto 11.0, no auth.
    var setup = [_]u8{0} ** 12;
    setup[0] = 0x6c;
    std.mem.writeInt(u16, setup[2..4], 11, .little); // protocol-major-version
    // name_len (6..8) and data_len (8..10) stay 0.
    try conn.appendIn(&setup);
    try std.testing.expect(try conn.tryHandshake());
    try std.testing.expectEqual(ConnState.established, conn.state);
    try std.testing.expect(conn.pendingOut().len > 0); // a SetupReply was queued
    try std.testing.expectEqual(@as(usize, 0), conn.request_buf.items.len); // setup bytes consumed

    // Now feed a 1-unit GetInputFocus request (opcode 43, length 1).
    try conn.appendIn(&[_]u8{ 43, 0, 1, 0 });
    const r = (try conn.takeRequest()).?;
    try std.testing.expectEqual(@as(usize, 4), r.len);
    conn.consumeRequest(r);
    try std.testing.expectEqual(@as(usize, 0), conn.request_buf.items.len);
    // A partial next request is not framed.
    try conn.appendIn(&[_]u8{ 43, 0, 2, 0 }); // declares 2 units, only 4 bytes present
    try std.testing.expectEqual(@as(?[]const u8, null), try conn.takeRequest());
}

test "ServerConn request_buf grows past the old 256KB fixed bound, up to the 4MiB cap; Overflow only beyond it" {
    const gpa = std.testing.allocator;
    const conn = try gpa.create(ServerConn);
    defer gpa.destroy(conn);
    conn.gpa = gpa;
    conn.request_buf = .empty;
    defer conn.request_buf.deinit(gpa);

    // Feed data in many small pieces (like the multiplexer's read_chunk-sized
    // reads), not one giant appendIn, to prove incremental growth works.
    const chunk = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(chunk);
    @memset(chunk, 0xab);

    const old_fixed_cap: usize = 256 * 1024;
    while (conn.request_buf.items.len <= old_fixed_cap) {
        try conn.appendIn(chunk); // no premature Overflow well past the old 256KB array size
    }
    try std.testing.expect(conn.request_buf.items.len > old_fixed_cap);

    // Keep accumulating right up to (but not past) the 4MiB ceiling.
    while (conn.request_buf.items.len + chunk.len <= max_request_bytes) {
        try conn.appendIn(chunk);
    }
    const at_cap = conn.request_buf.items.len;
    try std.testing.expect(at_cap <= max_request_bytes);
    try std.testing.expect(at_cap + chunk.len > max_request_bytes);

    // One more append that would cross the 4MiB ceiling is refused, and the
    // buffer is left unchanged (no partial append on Overflow).
    try std.testing.expectError(error.Overflow, conn.appendIn(chunk));
    try std.testing.expectEqual(at_cap, conn.request_buf.items.len);
}

test "ServerConn consume leaves the tail intact for back-to-back requests" {
    const gpa = std.testing.allocator;
    const conn = try gpa.create(ServerConn);
    defer gpa.destroy(conn);
    conn.gpa = gpa;
    conn.request_buf = .empty;
    defer conn.request_buf.deinit(gpa); // testing.allocator catches any leak here
    conn.state = .established;
    conn.client_endian = .little;

    // Two back-to-back 1-unit requests (opcodes 43 then 44) arrive together.
    try conn.appendIn(&[_]u8{ 43, 0, 1, 0, 44, 0, 1, 0 });
    const r1 = (try conn.takeRequest()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 43, 0, 1, 0 }, r1);
    conn.consumeRequest(r1);
    // The second request shifted down to the head, untouched.
    try std.testing.expectEqual(@as(usize, 4), conn.request_buf.items.len);
    const r2 = (try conn.takeRequest()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 44, 0, 1, 0 }, r2);
    conn.consumeRequest(r2);
    try std.testing.expectEqual(@as(usize, 0), conn.request_buf.items.len);
}

test "ServerConn takeRequest normalizes an extended (BIG-REQUESTS) request in place" {
    const gpa = std.testing.allocator;
    const conn = try gpa.create(ServerConn);
    defer gpa.destroy(conn);
    conn.gpa = gpa;
    conn.request_buf = .empty;
    defer conn.request_buf.deinit(gpa);
    conn.state = .established;
    conn.client_endian = .little;
    conn.big_requests_enabled = true; // as if BigReqEnable already ran

    // An extended-form request: opcode 30, pad byte, units==0 (extended
    // marker), then a u32 big-length of 4 (total 16 bytes: 8-byte extended
    // header + 8 bytes of body), immediately followed by a normal 1-unit
    // (4-byte) request -- proves back-to-back framing survives normalization.
    try conn.appendIn(&[_]u8{
        30, 0, 0, 0, // opcode, pad, units==0
        4, 0, 0, 0, // big-length: 4 units == 16 bytes total
        0xAA, 0xBB, 0xCC, 0xDD, // body word 1
        0xEE, 0xFF, 0x11, 0x22, // body word 2
        43, 0, 1, 0, // next request: plain 1-unit GetInputFocus
    });

    const r = (try conn.takeRequest()).?;
    // Decode slice == the original 4-byte header (opcode/pad/still-0 length)
    // followed by the body, with the 4 inserted big-length bytes gone: 12
    // bytes, not 16.
    try std.testing.expectEqualSlices(u8, &[_]u8{
        30,   0,    0,    0,
        0xAA, 0xBB, 0xCC, 0xDD,
        0xEE, 0xFF, 0x11, 0x22,
    }, r);
    // frame_len tracks the FULL framed size (16), not the 12-byte decode slice.
    try std.testing.expectEqual(@as(usize, 16), conn.frame_len);

    conn.consumeRequest(r);
    // Consuming removed the full 16-byte frame, leaving the next request's 4
    // bytes intact at the head -- consuming only r.len (12) would have left 4
    // stray body bytes in front of it.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 43, 0, 1, 0 }, conn.request_buf.items);

    const r2 = (try conn.takeRequest()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 43, 0, 1, 0 }, r2);
    try std.testing.expectEqual(@as(usize, 4), conn.frame_len);
    conn.consumeRequest(r2);
    try std.testing.expectEqual(@as(usize, 0), conn.request_buf.items.len);
}

test "BigReqEnable's advertised max_request_length exceeds the connection-setup max" {
    // server_main.zig's BigReqEnable arm advertises max_request_bytes/4 units;
    // the BIG-REQUESTS spec requires this to always exceed the connection
    // setup's advertised max_request_length (wire.SetupReplyParams' default,
    // 65535 units, unchanged by this work). Checked here as a pure invariant
    // on the constants, since server_main.zig's executable carries no tests
    // of its own (see build.zig).
    const advertised_units = max_request_bytes / 4;
    try std.testing.expectEqual(@as(usize, 1048576), advertised_units);
    // 65535 == wire.SetupReplyParams.max_request_length's default (the
    // core-protocol setup max every connection is handed, unchanged by this
    // work); hand-checked rather than instantiated to avoid dragging in
    // SetupReplyParams' many unrelated required fields just for this one.
    try std.testing.expect(advertised_units > 65535);
}

/// What the multiplexed serve loop hands the executable each `next()`.
/// `request.bytes` is borrowed from the conn's input buffer, valid only until
/// the following `next()` call. `disconnected` is delivered once, then the
/// conn is freed on the next `next()`.
pub const ServerEvent = union(enum) {
    connected: *ServerConn,
    request: struct { conn: *ServerConn, bytes: []const u8 },
    disconnected: *ServerConn,
};

/// Faults from the serve loop. A poll() failure is fatal (server exits); every
/// per-client fault is handled by disconnecting that client, never surfaced
/// here.
pub const ServeError = error{PollFailed} || std.mem.Allocator.Error;

/// Bytes read from a client socket per wakeup chunk before re-checking.
const read_chunk: usize = 16 * 1024;

/// Single-threaded poll() multiplexer over the listener + all client fds. Owns
/// the client registry and every raw socket syscall; the executable pulls
/// framed requests via next() and dispatches them behind the xproto wall.
pub const Multiplexer = struct {
    server: *Server,
    gpa: std.mem.Allocator,
    clients: std.ArrayListUnmanaged(*ServerConn) = .empty,
    pollfds: std.ArrayListUnmanaged(std.posix.pollfd) = .empty,
    /// Conns matching pollfds[1..] one-to-one for the current poll pass (the
    /// listener is pollfds[0]). Rebuilt with pollfds so the poll->conn mapping
    /// never depends on `clients` indices - letting `clients` shrink safely at
    /// the top of next() without disturbing an in-flight scan.
    polled: std.ArrayListUnmanaged(*ServerConn) = .empty,
    /// Clients that just finished their handshake, awaiting a `.connected`.
    connected_q: std.ArrayListUnmanaged(*ServerConn) = .empty,
    /// A conn whose `.disconnected` was delivered last call, freed this call.
    /// It is STILL in `clients` until then, so deinit must not close it twice.
    pending_free: ?*ServerConn = null,
    /// The request delivered last call: its bytes are consumed + its `out` is
    /// flushed at the top of this call (kept valid across the dispatch).
    pending_consume: ?struct { conn: *ServerConn, len: usize } = null,
    /// Round-robin start index for request fairness across clients.
    rr_cursor: usize = 0,
    /// GrabServer (op 36) holder's client_id, or null if no grab is held.
    /// While set, takeBufferedRequest dispatches ONLY this client's requests;
    /// every other client's already-buffered bytes stay frozen until
    /// UngrabServer (or the holder disconnecting, which auto-releases it in
    /// queueDisconnect -- otherwise every other client would freeze forever
    /// with nobody left to Ungrab).
    server_grab: ?u32 = null,

    pub fn init(server: *Server) Multiplexer {
        return .{ .server = server, .gpa = server.gpa };
    }

    /// The live connection with this client id, or null if none (disconnected).
    pub fn clientById(self: *Multiplexer, id: u32) ?*ServerConn {
        for (self.clients.items) |c| {
            if (!c.dead and c.client_id == id) return c;
        }
        return null;
    }

    /// Mark a connection for teardown (used by the executable when a fan-out
    /// encode into that client's queue fails). Wraps the internal dead-flag path.
    pub fn disconnect(self: *Multiplexer, conn: *ServerConn) void {
        self.queueDisconnect(conn);
    }

    /// Return a disconnected client's id (== accept index == id-range selector)
    /// for reuse by a future client. Called by the executable only AFTER a
    /// successful cleanupClient, so the reused range holds no live windows.
    pub fn releaseClientId(self: *Multiplexer, id: u32) void {
        self.server.releaseIndex(id);
    }

    /// GrabServer (op 36): freeze request dispatch to only `client` until
    /// clearServerGrab or `client` disconnects. Re-grabbing (already holding
    /// or another client stealing it) simply overwrites the holder -- real X
    /// servers block a second GrabServer instead, but nothing in this server
    /// currently blocks a request mid-flight, so there is no queue to stall on.
    pub fn setServerGrab(self: *Multiplexer, client: u32) void {
        self.server_grab = client;
    }

    /// UngrabServer (op 37): release the grab, but ONLY if `client` is the
    /// current holder -- a non-holder's UngrabServer is a no-op (it never had
    /// the grab to release).
    pub fn clearServerGrab(self: *Multiplexer, client: u32) void {
        if (self.server_grab) |g| if (g == client) {
            self.server_grab = null;
        };
    }

    pub fn deinit(self: *Multiplexer) void {
        // Every live conn - including one parked in pending_free, which is ALSO
        // still in `clients` - is reachable from `clients`; close each once.
        for (self.clients.items) |c| c.close();
        self.clients.deinit(self.gpa);
        self.pollfds.deinit(self.gpa);
        self.polled.deinit(self.gpa);
        self.connected_q.deinit(self.gpa);
    }

    /// Remove a client from the registry and every other structure that could
    /// still name it, then free it. The SINGLE point where a conn leaves
    /// `clients`; only called at the top of next() (never mid-scan), so no
    /// active pollfds/request scan is indexing `clients` when it shrinks.
    fn dropClient(self: *Multiplexer, conn: *ServerConn) void {
        for (self.clients.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.clients.orderedRemove(i);
                break;
            }
        }
        for (self.connected_q.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.connected_q.orderedRemove(i);
                break;
            }
        }
        if (self.pending_consume) |pc| {
            if (pc.conn == conn) self.pending_consume = null;
        }
        conn.close();
    }

    /// Flag a client dead so scans skip it and next() yields its single
    /// `.disconnected`. Infallible (a flag, no allocation), so the fault paths
    /// that call it can neither fail nor mutate `clients` mid-scan.
    fn queueDisconnect(self: *Multiplexer, conn: *ServerConn) void {
        conn.dead = true;
        // The grab holder disconnecting must release the grab itself -- there
        // is no one else left who could ever send an UngrabServer for it, so
        // every other client would otherwise stay frozen forever.
        if (self.server_grab) |g| if (g == conn.client_id) {
            self.server_grab = null;
        };
    }

    /// Yield the next already-buffered request round-robin, staging its consume.
    /// Skips dead and non-established clients, and -- while GrabServer is held
    /// -- every client but the holder (frozen dispatch; their bytes stay
    /// buffered until UngrabServer). `clients` is never mutated during this
    /// scan (drops happen only at the top of next()), so `n` stays valid.
    fn takeBufferedRequest(self: *Multiplexer) ?ServerEvent {
        const n = self.clients.items.len;
        if (n == 0) return null;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = (self.rr_cursor + k) % n;
            const conn = self.clients.items[idx];
            if (conn.dead or conn.state != .established) continue;
            if (self.server_grab) |g| {
                if (conn.client_id != g) continue;
            }
            const bytes = conn.takeRequest() catch {
                self.queueDisconnect(conn);
                continue;
            };
            if (bytes) |b| {
                self.rr_cursor = (idx + 1) % n;
                // frame_len (not b.len): on the extended BIG-REQUESTS path b
                // is the normalized decode slice, 4 bytes shorter than the
                // full framed request takeRequest just consumed the length
                // header of -- see ServerConn.consumeRequest's doc comment.
                self.pending_consume = .{ .conn = conn, .len = conn.frame_len };
                return .{ .request = .{ .conn = conn, .bytes = b } };
            }
        }
        return null;
    }

    /// The first dead client, if any (for a `.disconnected` delivery).
    fn firstDead(self: *Multiplexer) ?*ServerConn {
        for (self.clients.items) |c| if (c.dead) return c;
        return null;
    }

    pub fn next(self: *Multiplexer) ServeError!?ServerEvent {
        // Reclaim the previously-disconnected client (still in `clients` until
        // now). This is the ONE place `clients` shrinks - never mid-scan.
        if (self.pending_free) |c| {
            self.dropClient(c);
            self.pending_free = null;
        }
        // Consume the previous request's bytes, then flush every conn that got
        // output (its own reply plus any events fanned into other clients).
        if (self.pending_consume) |pc| {
            self.pending_consume = null;
            pc.conn.consume(pc.len);
        }
        self.flushAllDirty();
        while (true) {
            // Disconnects first: yield one dead client's `.disconnected`, parked
            // in pending_free so it is dropped (and scrubbed everywhere) at the
            // top of the next call, staying valid for the caller meanwhile.
            if (self.firstDead()) |c| {
                self.pending_free = c;
                return .{ .disconnected = c };
            }
            if (self.connected_q.items.len > 0) {
                return .{ .connected = self.connected_q.orderedRemove(0) };
            }
            if (self.takeBufferedRequest()) |ev| return ev;
            try self.pollOnce();
        }
    }

    /// Rebuild the poll set: pollfds[0] = listener, then one entry per live
    /// (non-dead) client, with `polled` holding the matching conn pointers so
    /// pollfds[1+i] <-> polled[i]. Dead clients are excluded (being torn down).
    fn rebuildPollfds(self: *Multiplexer) std.mem.Allocator.Error!void {
        self.pollfds.clearRetainingCapacity();
        self.polled.clearRetainingCapacity();
        try self.pollfds.append(self.gpa, .{ .fd = self.server.srv.socket.handle, .events = std.posix.POLL.IN, .revents = 0 });
        for (self.clients.items) |c| {
            if (c.dead) continue;
            var events: i16 = std.posix.POLL.IN;
            if (c.queuedLen() > 0) events |= std.posix.POLL.OUT;
            try self.pollfds.append(self.gpa, .{ .fd = c.fd(), .events = events, .revents = 0 });
            try self.polled.append(self.gpa, c);
        }
    }

    fn pollOnce(self: *Multiplexer) ServeError!void {
        try self.rebuildPollfds();
        const ready = std.posix.poll(self.pollfds.items, -1) catch return error.PollFailed;
        if (ready == 0) return;
        if (self.pollfds.items[0].revents & std.posix.POLL.IN != 0) try self.acceptOne();
        // pollfds[1+i] <-> polled[i]. acceptOne only appends to `clients` (not to
        // this pass's `polled`), and nothing is dropped here, so the mapping is
        // stable for the whole loop.
        for (self.polled.items, 0..) |conn, i| {
            const pfd = self.pollfds.items[i + 1];
            if (pfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
                self.serviceClient(conn);
            }
            // serviceClient may have flagged it dead; only flush a live conn.
            if (!conn.dead and pfd.revents & std.posix.POLL.OUT != 0) {
                self.flushConn(conn) catch self.queueDisconnect(conn);
            }
        }
    }

    fn acceptOne(self: *Multiplexer) std.mem.Allocator.Error!void {
        // A transient accept fault (peer aborted between poll and here) is
        // non-fatal: skip it and keep serving.
        const conn = self.server.accept() catch return;
        setNonblocking(conn.fd());
        self.clients.append(self.gpa, conn) catch {
            conn.close(); // no room to register it; drop rather than leak.
            return;
        };
    }

    /// Read whatever is available from a client and advance its state machine.
    /// Any fault flags only this client dead.
    fn serviceClient(self: *Multiplexer, conn: *ServerConn) void {
        if (conn.dead) return; // already torn down this pass
        while (true) {
            // Read only as much as the input buffer can still hold (against the
            // max_request_bytes ceiling, not any fixed array length now that
            // request_buf is heap-grown), so a client pipelining more than one
            // buffer-worth of valid requests fills the buffer and pauses here
            // rather than overflowing appendIn: framing (takeBufferedRequest)
            // drains complete requests across later next() cycles, freeing space
            // the next poll pass reads into. A single core request is <= 262140
            // bytes and always fits under the 4MiB ceiling, so a full buffer
            // always holds at least one complete request - no deadlock.
            const space = max_request_bytes - conn.request_buf.items.len;
            if (space == 0) break; // buffer full; framing will drain it before we read more
            const want = @min(space, read_chunk);
            var tmp: [read_chunk]u8 = undefined;
            const n = std.posix.read(conn.fd(), tmp[0..want]) catch |e| switch (e) {
                error.WouldBlock => break, // drained for now
                else => {
                    self.queueDisconnect(conn);
                    return;
                },
            };
            if (n == 0) { // clean EOF: client hung up
                self.queueDisconnect(conn);
                return;
            }
            conn.appendIn(tmp[0..n]) catch |e| switch (e) {
                // Overflow is unreachable now that reads are bounded to `space`,
                // but kept as a defensive guard. OutOfMemory is a real fault now
                // that request_buf grows on the heap: treat it the same as
                // Overflow (fatal to this client alone), not a server-wide abort.
                error.Overflow, error.OutOfMemory => {
                    self.queueDisconnect(conn);
                    return;
                },
            };
            if (n < want) break; // socket drained (short read)
        }
        if (conn.state == .handshaking) {
            const done = conn.tryHandshake() catch {
                self.queueDisconnect(conn);
                return;
            };
            if (done) {
                self.flushConn(conn) catch {
                    self.queueDisconnect(conn);
                    return;
                };
                self.connected_q.append(self.gpa, conn) catch self.queueDisconnect(conn);
            }
        }
        // Established requests are pulled lazily by takeBufferedRequest.
    }

    /// Drain a client's queued output as far as the socket will take it. On
    /// EAGAIN (socket full) it stops and leaves the remainder queued - POLLOUT
    /// will retry; it does NOT disconnect. Fully drained -> reset; partial ->
    /// compact. A backlog past the cap (a client that never reads) or a real
    /// write error disconnects that client.
    fn flushConn(_: *Multiplexer, conn: *ServerConn) error{Disconnect}!void {
        while (conn.queuedLen() > 0) {
            const data = conn.pendingOut();
            const rc = std.os.linux.write(conn.fd(), data.ptr, data.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {
                    const w: usize = rc;
                    if (w == 0) return error.Disconnect;
                    conn.advanceSent(w);
                },
                .INTR => continue,
                .AGAIN => break, // socket full; POLLOUT will resume the drain
                else => return error.Disconnect,
            }
        }
        if (conn.queuedLen() == 0) conn.clearOut() else conn.compactOut();
        if (conn.queuedLen() > ServerConn.max_out_backlog) return error.Disconnect;
    }

    /// Flush every connection that has queued output (a request can fan events
    /// into several clients' queues, not just the serviced one).
    fn flushAllDirty(self: *Multiplexer) void {
        for (self.clients.items) |c| {
            if (c.dead or c.queuedLen() == 0) continue;
            self.flushConn(c) catch self.queueDisconnect(c);
        }
    }
};

/// Set a socket fd non-blocking. std.posix in 0.16 exposes neither fcntl nor
/// write, so the multiplexer uses the raw linux syscalls directly (Linux-only,
/// which the whole unix-socket server already is).
fn setNonblocking(handle: std.posix.fd_t) void {
    const linux = std.os.linux;
    const flags = linux.fcntl(handle, linux.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(handle, linux.F.SETFL, flags | nonblock);
}

test "Multiplexer.takeBufferedRequest yields buffered requests round-robin" {
    const gpa = std.testing.allocator;
    // Two established clients, each with one buffered 1-unit request. Build
    // them directly (no accept/socket); only buffer/state fields are read.
    var a = try gpa.create(ServerConn);
    defer gpa.destroy(a);
    var b = try gpa.create(ServerConn);
    defer gpa.destroy(b);
    for ([_]*ServerConn{ a, b }) |c| {
        c.gpa = gpa;
        c.state = .established;
        c.client_endian = .little;
        c.request_buf = .empty;
        c.out = std.Io.Writer.Allocating.init(gpa);
        try c.appendIn(&[_]u8{ 43, 0, 1, 0 });
    }
    defer a.out.deinit();
    defer b.out.deinit();
    defer a.request_buf.deinit(gpa);
    defer b.request_buf.deinit(gpa);

    var mux: Multiplexer = .{ .server = undefined, .gpa = gpa };
    defer mux.clients.deinit(gpa);
    defer mux.pollfds.deinit(gpa);
    defer mux.connected_q.deinit(gpa);
    defer mux.polled.deinit(gpa);
    try mux.clients.append(gpa, a);
    try mux.clients.append(gpa, b);

    // First pull -> a's request; second -> b's request (round-robin), each
    // staging its consume.
    const e1 = mux.takeBufferedRequest().?;
    try std.testing.expectEqual(a, e1.request.conn);
    a.consume(mux.pending_consume.?.len); // simulate the top-of-next consume
    mux.pending_consume = null;
    const e2 = mux.takeBufferedRequest().?;
    try std.testing.expectEqual(b, e2.request.conn);
    b.consume(mux.pending_consume.?.len);
    mux.pending_consume = null;
    // Both drained now.
    try std.testing.expectEqual(@as(?ServerEvent, null), mux.takeBufferedRequest());
}

test "Multiplexer server_grab: freezes dispatch to only the holder; clear resumes others; holder disconnect releases it" {
    const gpa = std.testing.allocator;
    var a = try gpa.create(ServerConn);
    defer gpa.destroy(a);
    var b = try gpa.create(ServerConn);
    defer gpa.destroy(b);
    for ([_]*ServerConn{ a, b }) |c| {
        c.gpa = gpa;
        c.state = .established;
        c.client_endian = .little;
        c.request_buf = .empty;
        c.dead = false;
        c.out = std.Io.Writer.Allocating.init(gpa);
        try c.appendIn(&[_]u8{ 43, 0, 1, 0 });
    }
    defer a.out.deinit();
    defer b.out.deinit();
    defer a.request_buf.deinit(gpa);
    defer b.request_buf.deinit(gpa);
    a.client_id = 1;
    b.client_id = 2;

    var mux: Multiplexer = .{ .server = undefined, .gpa = gpa };
    defer mux.clients.deinit(gpa);
    defer mux.pollfds.deinit(gpa);
    defer mux.connected_q.deinit(gpa);
    defer mux.polled.deinit(gpa);
    try mux.clients.append(gpa, a);
    try mux.clients.append(gpa, b);

    // Client 1 grabs the server: only its requests are dispatched, b's stays
    // buffered even though it is next in round-robin order.
    mux.setServerGrab(1);
    const e1 = mux.takeBufferedRequest().?;
    try std.testing.expectEqual(a, e1.request.conn);
    a.consume(mux.pending_consume.?.len);
    mux.pending_consume = null;
    try std.testing.expectEqual(@as(?ServerEvent, null), mux.takeBufferedRequest()); // b frozen

    // A non-holder's UngrabServer is a no-op.
    mux.clearServerGrab(2);
    try std.testing.expect(mux.server_grab != null);
    try std.testing.expectEqual(@as(?ServerEvent, null), mux.takeBufferedRequest()); // still frozen

    // The holder's UngrabServer releases it; b's buffered request resumes.
    mux.clearServerGrab(1);
    try std.testing.expect(mux.server_grab == null);
    const e2 = mux.takeBufferedRequest().?;
    try std.testing.expectEqual(b, e2.request.conn);
    b.consume(mux.pending_consume.?.len);
    mux.pending_consume = null;

    // Re-grab, then the holder disconnects (queueDisconnect) -- the grab is
    // auto-released rather than freezing every other client forever.
    try b.appendIn(&[_]u8{ 43, 0, 1, 0 });
    mux.setServerGrab(1);
    mux.queueDisconnect(a);
    try std.testing.expect(mux.server_grab == null);
    const e3 = mux.takeBufferedRequest().?; // b dispatches again (a is dead+skipped)
    try std.testing.expectEqual(b, e3.request.conn);
}

test "ServerConn out-queue: pendingOut/advanceSent/compactOut/clearOut" {
    const gpa = std.testing.allocator;
    const conn = try gpa.create(ServerConn);
    defer gpa.destroy(conn);
    conn.out = std.Io.Writer.Allocating.init(gpa);
    defer conn.out.deinit();
    conn.out_sent = 0;
    // Queue 10 bytes.
    try conn.out.writer.writeAll(&[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    try std.testing.expectEqual(@as(usize, 10), conn.queuedLen());
    try std.testing.expectEqual(@as(usize, 10), conn.pendingOut().len);
    // Send 4 of 10: unsent slice starts at byte 4.
    conn.advanceSent(4);
    try std.testing.expectEqual(@as(usize, 6), conn.queuedLen());
    try std.testing.expectEqual(@as(u8, 4), conn.pendingOut()[0]);
    // Below half drained (4*2 < 10): compactOut is an amortized no-op.
    conn.compactOut();
    try std.testing.expectEqual(@as(usize, 4), conn.out_sent);
    try std.testing.expectEqual(@as(usize, 6), conn.queuedLen());
    // Send more (8 of 10 total): now >= half -> compactOut shifts [8..10] to front.
    conn.advanceSent(4);
    conn.compactOut();
    try std.testing.expectEqual(@as(usize, 0), conn.out_sent);
    try std.testing.expectEqual(@as(usize, 2), conn.queuedLen());
    try std.testing.expectEqual(@as(u8, 8), conn.pendingOut()[0]);
    // Fully drain, then clearOut resets both.
    conn.advanceSent(2);
    try std.testing.expectEqual(@as(usize, 0), conn.queuedLen());
    conn.clearOut();
    try std.testing.expectEqual(@as(usize, 0), conn.out_sent);
    try std.testing.expectEqual(@as(usize, 0), conn.out.writer.end);
}

test "Multiplexer.clientById resolves by client_id and skips dead" {
    const gpa = std.testing.allocator;
    const a = try gpa.create(ServerConn);
    defer gpa.destroy(a);
    const b = try gpa.create(ServerConn);
    defer gpa.destroy(b);
    a.client_id = 5;
    a.dead = false;
    b.client_id = 7;
    b.dead = false;
    var mux: Multiplexer = .{ .server = undefined, .gpa = gpa };
    defer mux.clients.deinit(gpa);
    defer mux.polled.deinit(gpa);
    try mux.clients.append(gpa, a);
    try mux.clients.append(gpa, b);
    try std.testing.expectEqual(a, mux.clientById(5).?);
    try std.testing.expectEqual(b, mux.clientById(7).?);
    try std.testing.expectEqual(@as(?*ServerConn, null), mux.clientById(9));
    b.dead = true;
    try std.testing.expectEqual(@as(?*ServerConn, null), mux.clientById(7)); // dead skipped
}

test "Server acquireIndex/releaseIndex recycles freed indices" {
    const gpa = std.testing.allocator;
    // Only next_client_index + free_indices are touched by acquire/release; the
    // socket/display/io fields are never read here.
    var s: Server = .{ .gpa = gpa, .io = undefined, .srv = undefined, .display = undefined };
    defer s.free_indices.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), s.acquireIndex());
    try std.testing.expectEqual(@as(u32, 1), s.acquireIndex());
    try std.testing.expectEqual(@as(u32, 2), s.acquireIndex());
    s.releaseIndex(1);
    try std.testing.expectEqual(@as(u32, 1), s.acquireIndex()); // reused
    try std.testing.expectEqual(@as(u32, 3), s.acquireIndex()); // then monotonic
}
