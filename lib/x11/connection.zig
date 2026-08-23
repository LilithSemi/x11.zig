//! X11 connection: socket transport, setup handshake, reply/event demultiplexer.
const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const wire = @import("wire.zig");
const cookie = @import("cookie.zig");
const display_mod = @import("display.zig");
const xauth = @import("xauth.zig");

/// QueryExtension core opcode (X11 protocol requests table, section 9).
const opcode_query_extension: u8 = 98;

/// Upper bound on a single reply's extra body. A conforming X server never
/// sends a reply larger than this; a length field claiming more is a corrupt or
/// hostile stream, refused with error.ReplyTooLarge rather than turned into a
/// multi-gigabyte allocation. 128 MiB clears every real core/extension reply.
pub const max_reply_bytes: usize = 128 * 1024 * 1024;

/// Convert a reply length (in 4-byte units, straight off an untrusted wire) to
/// a byte count. The multiply is widened to u64 first: on a 32-bit usize
/// `length * 4` overflows for large length values, which would wrap to a small
/// allocation and desync the stream. Bounded against max_reply_bytes.
fn replyExtraLen(length_units: u32) error{ReplyTooLarge}!usize {
    const bytes: u64 = @as(u64, length_units) * 4;
    if (bytes > max_reply_bytes) return error.ReplyTooLarge;
    return @intCast(bytes);
}

/// Faults from reading and routing packets. Note: pumping never returns
/// error.XProtocolError - an X error is data, buffered for its awaiter, not a
/// control-flow fault. Only `reply()` turns a matching buffered error into
/// error.XProtocolError for its caller.
pub const PumpError = error{
    ConnectionClosed,
    ReplyTooLarge,
} || wire.ReplyHeaderError || wire.XErrorParseError || std.mem.Allocator.Error;

/// Sending a request can only fail the way encoding a request can.
pub const SendError = wire.EncodeRequestError;

/// Awaiting a reply pumps packets and may surface a matching X error.
pub const ReplyError = PumpError || error{XProtocolError};

/// queryExtension sends a request, awaits the reply, and caches the result.
pub const QueryExtensionError =
    error{NameTooLong} || SendError || ReplyError || std.mem.Allocator.Error;

/// connect()'s full fault surface: our own setup faults, the display parser,
/// both socket transports, the setup codec, the setup reader, and allocation.
pub const ConnectError = error{
    NoDisplay,
    DisplayPathTooLong,
    InvalidDisplay,
    SetupReplyTooLarge,
    NameTooLong,
    HostnameResolutionUnsupported,
} || display_mod.ParseError ||
    std.Io.net.UnixAddress.ConnectError ||
    std.Io.net.IpAddress.ConnectError ||
    wire.EncodeSetupError ||
    wire.ParseSetupError ||
    std.Io.Reader.StreamError ||
    xauth.LoadError ||
    std.mem.Allocator.Error;

pub const ExtensionInfo = struct {
    present: bool,
    major_opcode: u8,
    first_event: u8,
    first_error: u8,
};

pub fn parseQueryExtensionReply(bytes: []const u8) ExtensionInfo {
    return .{
        .present = bytes.len > 8 and bytes[8] != 0,
        .major_opcode = if (bytes.len > 9) bytes[9] else 0,
        .first_event = if (bytes.len > 10) bytes[10] else 0,
        .first_error = if (bytes.len > 11) bytes[11] else 0,
    };
}

/// A packet delivered to the application event loop: either a spontaneous
/// event or an X error that no awaitReply will ever claim (from a no-reply
/// request). Replies are NOT delivered here - they belong to awaitReply.
pub const Incoming = union(enum) {
    event: Event,
    err: wire.XError,
};

pub const Reply = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Reply) void {
        self.allocator.free(self.bytes);
    }
};

pub const Event = struct { bytes: [32]u8 };

/// Pending X error that arrived while awaiting a different sequence number.
/// Stored so a later reply() call for that sequence can surface the error.
pub const PendingError = struct { seq: u64, err: wire.XError };

/// A reply that arrived before its awaiter called reply(). Owns its heap
/// bytes until reply() hands them to the caller. Buffering (rather than the
/// old discard) is what makes out-of-order awaits safe.
const BufferedReply = struct { seq: u64, bytes: []u8 };

/// Read and route exactly one X11 packet from `r`.
///
/// Events append to `events`; replies buffer into `pending_replies` keyed by
/// widened sequence; errors buffer into `pending_errors`. Nothing is ever
/// discarded, so a caller awaiting one sequence never loses another's reply.
/// When `blocking` is false the packet is processed only if it is ALREADY
/// fully buffered in the reader (header plus any reply body); otherwise the
/// function returns false without touching the socket. Blocking always
/// processes one packet or fails.
fn pumpReader(
    r: *std.Io.Reader,
    gpa: std.mem.Allocator,
    tracker: *cookie.SequenceTracker,
    blocking: bool,
    events: *std.ArrayList(Event),
    pending_errors: *std.ArrayList(PendingError),
    pending_replies: *std.ArrayList(BufferedReply),
) PumpError!bool {
    if (!blocking) {
        // Only consume a packet we already hold in full, so we never block.
        if (r.bufferedLen() < 32) return false;
        const buf = r.buffered();
        if (wire.responseType(buf[0]) == .reply) {
            const hdr = try wire.parseReplyHeader(buf[0..32]);
            const extra_len = try replyExtraLen(hdr.length);
            if (r.bufferedLen() < 32 + extra_len) return false; // body not here yet
        }
    }

    var pkt: [32]u8 = undefined;
    r.readSliceAll(&pkt) catch return error.ConnectionClosed;

    switch (wire.responseType(pkt[0])) {
        .event => try events.append(gpa, .{ .bytes = pkt }),
        .err => {
            const xerr = try wire.parseError(&pkt);
            const seq = tracker.widen(xerr.sequence);
            try pending_errors.append(gpa, .{ .seq = seq, .err = xerr });
        },
        .reply => {
            const hdr = try wire.parseReplyHeader(&pkt);
            const extra_len = try replyExtraLen(hdr.length);
            const seq = tracker.widen(hdr.sequence);
            const total = 32 + extra_len;
            const bytes = try gpa.alloc(u8, total);
            errdefer gpa.free(bytes);
            @memcpy(bytes[0..32], &pkt);
            if (extra_len > 0) r.readSliceAll(bytes[32..]) catch return error.ConnectionClosed;
            try pending_replies.append(gpa, .{ .seq = seq, .bytes = bytes });
        },
    }
    return true;
}

/// Remove and return the buffered reply bytes for `seq`, if present. The
/// caller owns the returned bytes (frees via Reply.deinit). Ownership
/// transfers out; this frees nothing.
fn takeBufferedReply(list: *std.ArrayList(BufferedReply), seq: u64) ?[]u8 {
    for (list.items, 0..) |br, i| {
        if (br.seq == seq) {
            const bytes = br.bytes;
            _ = list.orderedRemove(i);
            return bytes;
        }
    }
    return null;
}

/// Remove and return the buffered X error for `seq`, if present.
fn takeBufferedError(list: *std.ArrayList(PendingError), seq: u64) ?wire.XError {
    for (list.items, 0..) |pe, i| {
        if (pe.seq == seq) {
            const err = pe.err;
            _ = list.orderedRemove(i);
            return err;
        }
    }
    return null;
}

/// Free every buffered reply's bytes and deinit the list. Used by disconnect to
/// reclaim replies the app never awaited (extracted so the free path is
/// unit-testable without a live socket).
fn freePendingReplies(list: *std.ArrayList(BufferedReply), gpa: std.mem.Allocator) void {
    for (list.items) |br| gpa.free(br.bytes);
    list.deinit(gpa);
}

/// Pop the next application-facing item: a queued event if any, otherwise an
/// unclaimed X error. Replies are never returned here - they are awaitReply's.
fn takeIncoming(events: *std.ArrayList(Event), pending_errors: *std.ArrayList(PendingError)) ?Incoming {
    if (events.items.len > 0) return .{ .event = events.orderedRemove(0) };
    if (pending_errors.items.len > 0) return .{ .err = pending_errors.orderedRemove(0).err };
    return null;
}

pub const Connection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    setup: wire.Setup,
    /// Owns the setup reply bytes that `setup`'s vendor()/formats()/screens()/
    /// screenAt() borrow from (`setup.raw`). Freed in disconnect(); must outlive
    /// every use of `setup`.
    setup_bytes: []u8,
    tracker: cookie.SequenceTracker,
    events: std.ArrayList(Event),
    pending_errors: std.ArrayList(PendingError),
    pending_replies: std.ArrayList(BufferedReply) = .empty,
    ext_info: std.StringHashMapUnmanaged(ExtensionInfo) = .{},
    reader_buf: [4096]u8 = undefined,
    net_reader: std.Io.net.Stream.Reader = undefined,
    /// Running counter for generateId(). Holds the last handed-out offset within
    /// the server-granted resource-id range (before base/mask are applied); 0
    /// means "none issued yet", so the first id is one increment in.
    last_xid: u32 = 0,

    pub fn connect(
        gpa: std.mem.Allocator,
        io: std.Io,
        display_str: ?[]const u8,
        auth: ?xauth.Auth,
        environ: ?*const std.process.Environ.Map,
    ) ConnectError!*Connection {
        const ds = display_str orelse return error.NoDisplay;
        const disp = try display_mod.parseDisplay(ds);

        const is_local = disp.host.len == 0 or std.mem.eql(u8, disp.host, "unix");
        const stream: std.Io.net.Stream = if (is_local) blk: {
            var path_buf: [108]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{}", .{disp.display}) catch
                return error.DisplayPathTooLong;
            const ua = try std.Io.net.UnixAddress.init(path);
            break :blk try ua.connect(io);
        } else blk: {
            const port = std.math.cast(u16, 6000 + @as(u32, disp.display)) orelse return error.InvalidDisplay;
            // TCP requires a literal IP address (v4/v6, optionally with an IPv6
            // zone id). Real DNS hostname resolution needs libc getaddrinfo, which
            // this library deliberately does not link, so a DNS name is reported as
            // a clear, named error rather than a confusing parse failure.
            const addr = std.Io.net.IpAddress.resolve(io, disp.host, port) catch
                return error.HostnameResolutionUnsupported;
            break :blk try addr.connect(io, .{ .mode = .stream });
        };
        errdefer stream.close(io);

        // Resolve auth: caller-provided wins; else auto-load from the environment.
        var auto_auth: ?xauth.Auth = null;
        defer if (auto_auth) |a| a.deinit(gpa);
        const eff_auth: ?xauth.Auth = if (auth) |a| a else blk: {
            if (environ) |env| {
                var num_buf: [8]u8 = undefined;
                const num = std.fmt.bufPrint(&num_buf, "{d}", .{disp.display}) catch break :blk null;
                auto_auth = xauth.loadForDisplay(gpa, io, env, num) catch |err| switch (err) {
                    error.MalformedXauth => null, // a corrupt file is not fatal; connect anonymously
                    else => return err,
                };
                break :blk auto_auth;
            }
            break :blk null;
        };
        const auth_name: []const u8 = if (eff_auth) |a| a.name else "";
        const auth_data: []const u8 = if (eff_auth) |a| a.data else "";

        var write_buf: [256]u8 = undefined;
        var sw = stream.writer(io, &write_buf);
        try wire.encodeSetupRequest(&sw.interface, auth_name, auth_data);
        try sw.interface.flush();

        var read_buf: [4096]u8 = undefined;
        var sr = stream.reader(io, &read_buf);

        var reply_writer = std.Io.Writer.Allocating.init(gpa);
        errdefer reply_writer.deinit();

        try (&sr.interface).streamExact(&reply_writer.writer, 8);
        const hdr = reply_writer.writer.buffered();
        const additional_u32s = std.mem.readInt(u16, hdr[6..8], native_endian);
        if (additional_u32s > 1_000_000) return error.SetupReplyTooLarge;
        try (&sr.interface).streamExact(&reply_writer.writer, @as(usize, additional_u32s) * 4);

        // Take ownership of the setup bytes: `setup`'s borrowing accessors
        // (vendor/formats/screens/screenAt) must stay valid for the
        // Connection's whole lifetime, not just this function's.
        const setup_bytes = try reply_writer.toOwnedSlice();
        errdefer gpa.free(setup_bytes);
        var setup = try wire.parseSetupReply(setup_bytes);
        setup.raw = setup_bytes; // re-assign explicitly to the owned slice
        setup.default_screen = disp.screen;

        const c = try gpa.create(Connection);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .setup = setup,
            .setup_bytes = setup_bytes,
            .tracker = cookie.SequenceTracker.init(),
            .events = .empty,
            .pending_errors = .empty,
            .pending_replies = .empty,
            .ext_info = .{},
        };
        c.net_reader = c.stream.reader(io, &c.reader_buf);
        return c;
    }

    /// The DISPLAY-selected screen (the ".screen" suffix), or null if absent.
    pub fn defaultScreen(self: *const Connection) ?wire.Screen {
        return self.setup.screenAt(self.setup.default_screen);
    }

    pub fn disconnect(self: *Connection) void {
        self.gpa.free(self.setup_bytes);
        freePendingReplies(&self.pending_replies, self.gpa);
        self.events.deinit(self.gpa);
        self.pending_errors.deinit(self.gpa);
        var it = self.ext_info.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.ext_info.deinit(self.gpa);
        self.stream.close(self.io);
        self.gpa.destroy(self);
    }

    pub fn send(self: *Connection, major: u8, minor_or_data: u8, extra: []const u8) SendError!u64 {
        var write_buf: [4096]u8 = undefined;
        var sw = self.stream.writer(self.io, &write_buf);
        try wire.encodeRequest(&sw.interface, major, minor_or_data, extra);
        try sw.interface.flush();
        return self.tracker.next();
    }

    pub fn reply(self: *Connection, sequence: u64, out_err: *wire.XError) ReplyError!Reply {
        while (true) {
            // A matching reply or error may already be buffered from an
            // earlier pump (out-of-order await, or an error that raced ahead).
            if (takeBufferedReply(&self.pending_replies, sequence)) |bytes| {
                return Reply{ .bytes = bytes, .allocator = self.gpa };
            }
            if (takeBufferedError(&self.pending_errors, sequence)) |xerr| {
                out_err.* = xerr;
                return error.XProtocolError;
            }
            _ = try pumpReader(
                &self.net_reader.interface,
                self.gpa,
                &self.tracker,
                true,
                &self.events,
                &self.pending_errors,
                &self.pending_replies,
            );
        }
    }

    /// Block until the next event or unclaimed X error arrives, pumping the
    /// socket and buffering any replies for a later awaitReply.
    ///
    /// Boundary: in this single-threaded pull model, fire a reply-bearing
    /// request and await its reply BEFORE re-entering nextEvent. Otherwise an
    /// error for that request could surface here as `.err` instead of at the
    /// awaitReply site (this loop drains unclaimed errors by design). A later
    /// awaitReply for such a request would then block forever, since its reply
    /// or error was already consumed here.
    pub fn nextEvent(self: *Connection) PumpError!Incoming {
        while (true) {
            if (takeIncoming(&self.events, &self.pending_errors)) |item| return item;
            _ = try pumpReader(
                &self.net_reader.interface,
                self.gpa,
                &self.tracker,
                true,
                &self.events,
                &self.pending_errors,
                &self.pending_replies,
            );
        }
    }

    /// Return the next event or unclaimed error WITHOUT blocking: drains the
    /// in-memory queues, then processes only packets already fully buffered in
    /// the reader. Returns null when nothing is ready. Pair with connectionFd()
    /// and an external poll() to know when to call again. If the app ignores
    /// the await-before-loop boundary and an unclaimed reply larger than the
    /// internal read buffer sits at the socket head, pollEvent cannot buffer it
    /// whole and keeps returning null while the fd stays readable, so hold to
    /// the boundary.
    pub fn pollEvent(self: *Connection) PumpError!?Incoming {
        while (true) {
            if (takeIncoming(&self.events, &self.pending_errors)) |item| return item;
            const progressed = try pumpReader(
                &self.net_reader.interface,
                self.gpa,
                &self.tracker,
                false,
                &self.events,
                &self.pending_errors,
                &self.pending_replies,
            );
            if (!progressed) return null;
        }
    }

    /// The underlying socket handle, for folding the X connection into an
    /// external poll()/select() set (Xlib's ConnectionNumber).
    pub fn connectionFd(self: *const Connection) std.posix.fd_t {
        return self.stream.socket.handle;
    }

    pub fn queryExtension(self: *Connection, name: []const u8, out_err: *wire.XError) QueryExtensionError!ExtensionInfo {
        var buf: [256]u8 = undefined;
        if (name.len + 4 > buf.len) return error.NameTooLong;
        std.mem.writeInt(u16, buf[0..2], @intCast(name.len), native_endian);
        buf[2] = 0;
        buf[3] = 0;
        var off: usize = 4;
        @memcpy(buf[off..][0..name.len], name);
        off += name.len;
        while (off % 4 != 0) : (off += 1) buf[off] = 0;
        const seq = try self.send(opcode_query_extension, 0, buf[0..off]);
        var r = try self.reply(seq, out_err);
        defer r.deinit();
        const info = parseQueryExtensionReply(r.bytes);
        if (info.present) {
            if (self.ext_info.getEntry(name)) |e| {
                e.value_ptr.* = info;
            } else {
                const key = try self.gpa.dupe(u8, name);
                errdefer self.gpa.free(key);
                try self.ext_info.put(self.gpa, key, info);
            }
        }
        return info;
    }

    pub fn extensionMajor(self: *Connection, name: []const u8) ?u8 {
        return if (self.ext_info.get(name)) |i| i.major_opcode else null;
    }

    /// Allocate a fresh resource id (window, pixmap, gc, colormap, cursor).
    ///
    /// The server grants each client a contiguous id range as (base, mask): any
    /// value `base | (n & mask)` for n in the mask's range is ours to name. We
    /// hand them out low-to-high, stepping by the mask's lowest set bit (the id
    /// granularity), exactly as Xlib's XAllocID does. Asserts the range is not
    /// exhausted rather than silently reissuing a live id.
    pub fn generateId(self: *Connection) u32 {
        const mask = self.setup.resource_id_mask;
        std.debug.assert(mask != 0); // a conforming setup always grants a range
        const inc: u32 = @as(u32, 1) << @intCast(@ctz(mask));
        const next = self.last_xid + inc;
        std.debug.assert((next & mask) == next); // range not yet exhausted
        self.last_xid = next;
        return self.setup.resource_id_base | next;
    }

    pub fn eventExtension(self: *const Connection, code: u8) ?[]const u8 {
        return classifyByBase(&self.ext_info, code, true);
    }

    pub fn errorExtension(self: *const Connection, code: u8) ?[]const u8 {
        return classifyByBase(&self.ext_info, code, false);
    }
};

fn classifyByBase(map: *const std.StringHashMapUnmanaged(ExtensionInfo), code: u8, is_event: bool) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_base: u8 = 0;
    var it = map.iterator();
    while (it.next()) |e| {
        const base = if (is_event) e.value_ptr.first_event else e.value_ptr.first_error;
        if (base != 0 and code >= base and base >= best_base) {
            best = e.key_ptr.*;
            best_base = base;
        }
    }
    return best;
}

test "parseQueryExtensionReply reads present/major/first_event/first_error" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    buf[8] = 1; // present
    buf[9] = 0x88; // major_opcode
    buf[10] = 0x40; // first_event
    buf[11] = 0x20; // first_error
    const info = parseQueryExtensionReply(&buf);
    try std.testing.expect(info.present);
    try std.testing.expectEqual(@as(u8, 0x88), info.major_opcode);
    try std.testing.expectEqual(@as(u8, 0x40), info.first_event);
    try std.testing.expectEqual(@as(u8, 0x20), info.first_error);
}

test "pumpReader buffers an event then a reply into their queues" {
    var buf: [68]u8 = std.mem.zeroes([68]u8);
    buf[0] = 2; // event
    buf[32] = 1; // reply marker
    std.mem.writeInt(u16, buf[34..36], 1, native_endian); // wire seq 1
    std.mem.writeInt(u32, buf[36..40], 1, native_endian); // length = 1 unit

    var r = std.Io.Reader.fixed(&buf);
    var tracker = cookie.SequenceTracker.init();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    var pending_errors: std.ArrayList(PendingError) = .empty;
    defer pending_errors.deinit(std.testing.allocator);
    var pending_replies: std.ArrayList(BufferedReply) = .empty;
    defer {
        for (pending_replies.items) |br| std.testing.allocator.free(br.bytes);
        pending_replies.deinit(std.testing.allocator);
    }

    try std.testing.expect(try pumpReader(&r, std.testing.allocator, &tracker, true, &events, &pending_errors, &pending_replies));
    try std.testing.expect(try pumpReader(&r, std.testing.allocator, &tracker, true, &events, &pending_errors, &pending_replies));

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(@as(u8, 2), events.items[0].bytes[0]);
    try std.testing.expectEqual(@as(usize, 1), pending_replies.items.len);
    try std.testing.expectEqual(@as(u64, 1), pending_replies.items[0].seq);
    try std.testing.expectEqual(@as(usize, 36), pending_replies.items[0].bytes.len);
}

test "pumpReader buffers a matching X error by sequence" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    buf[0] = 0; // error
    buf[1] = 3; // BadWindow
    std.mem.writeInt(u16, buf[2..4], 1, native_endian); // seq 1
    buf[10] = 98; // major opcode

    var r = std.Io.Reader.fixed(&buf);
    var tracker = cookie.SequenceTracker.init();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    var pending_errors: std.ArrayList(PendingError) = .empty;
    defer pending_errors.deinit(std.testing.allocator);
    var pending_replies: std.ArrayList(BufferedReply) = .empty;
    defer pending_replies.deinit(std.testing.allocator);

    try std.testing.expect(try pumpReader(&r, std.testing.allocator, &tracker, true, &events, &pending_errors, &pending_replies));
    try std.testing.expectEqual(@as(usize, 1), pending_errors.items.len);
    try std.testing.expectEqual(@as(u64, 1), pending_errors.items[0].seq);
    try std.testing.expectEqual(@as(u8, 3), pending_errors.items[0].err.code);
    try std.testing.expectEqual(@as(u8, 98), pending_errors.items[0].err.major_opcode);
}

test "pumpReader non-blocking consumes a whole buffered packet but not a partial one" {
    const gpa = std.testing.allocator;
    // One full event (32 bytes) followed by only 10 bytes of a second packet.
    var buf: [42]u8 = std.mem.zeroes([42]u8);
    buf[0] = 2; // event
    buf[32] = 2; // start of a second event, but truncated

    var r = std.Io.Reader.fixed(&buf);
    var tracker = cookie.SequenceTracker.init();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);
    var pending_errors: std.ArrayList(PendingError) = .empty;
    defer pending_errors.deinit(gpa);
    var pending_replies: std.ArrayList(BufferedReply) = .empty;
    defer {
        for (pending_replies.items) |br| gpa.free(br.bytes);
        pending_replies.deinit(gpa);
    }

    // First call consumes the complete event.
    try std.testing.expect(try pumpReader(&r, gpa, &tracker, false, &events, &pending_errors, &pending_replies));
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    // Second call: only 10 bytes remain (< 32), so it processes nothing.
    try std.testing.expect(!try pumpReader(&r, gpa, &tracker, false, &events, &pending_errors, &pending_replies));
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
}

test "pumpReader non-blocking leaves a reply whose body is not fully buffered" {
    const gpa = std.testing.allocator;
    // Reply header claims 2 length-units (8 extra bytes) but only 4 extra bytes
    // are present: 32 + 4 = 36 < 40, so the non-blocking pump must not consume it.
    var buf: [36]u8 = std.mem.zeroes([36]u8);
    buf[0] = 1; // reply
    std.mem.writeInt(u16, buf[2..4], 5, native_endian); // seq
    std.mem.writeInt(u32, buf[4..8], 2, native_endian); // length = 2 units = 8 extra bytes

    var r = std.Io.Reader.fixed(&buf);
    var tracker = cookie.SequenceTracker.init();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);
    var pending_errors: std.ArrayList(PendingError) = .empty;
    defer pending_errors.deinit(gpa);
    var pending_replies: std.ArrayList(BufferedReply) = .empty;
    defer {
        for (pending_replies.items) |br| gpa.free(br.bytes);
        pending_replies.deinit(gpa);
    }

    try std.testing.expect(!try pumpReader(&r, gpa, &tracker, false, &events, &pending_errors, &pending_replies));
    try std.testing.expectEqual(@as(usize, 0), pending_replies.items.len);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "freePendingReplies frees unclaimed reply bytes without leaking" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(BufferedReply) = .empty;
    // Two heap-allocated buffered replies the app never claimed.
    try list.append(gpa, .{ .seq = 1, .bytes = try gpa.alloc(u8, 36) });
    try list.append(gpa, .{ .seq = 2, .bytes = try gpa.alloc(u8, 40) });
    freePendingReplies(&list, gpa);
    // The testing allocator fails this test if any byte buffer leaked.
}

test "out-of-order replies both buffer; takeBufferedReply returns the right one" {
    // Two replies on the wire: seq 1 (len 0) then seq 2 (len 0). Awaiting seq 2
    // FIRST must find it, and seq 1 must still be retrievable afterwards.
    var buf: [64]u8 = std.mem.zeroes([64]u8);
    buf[0] = 1; // reply seq 1
    std.mem.writeInt(u16, buf[2..4], 1, native_endian);
    std.mem.writeInt(u32, buf[4..8], 0, native_endian);
    buf[32] = 1; // reply seq 2
    std.mem.writeInt(u16, buf[34..36], 2, native_endian);
    std.mem.writeInt(u32, buf[36..40], 0, native_endian);

    var r = std.Io.Reader.fixed(&buf);
    var tracker = cookie.SequenceTracker.init();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    var pending_errors: std.ArrayList(PendingError) = .empty;
    defer pending_errors.deinit(std.testing.allocator);
    var pending_replies: std.ArrayList(BufferedReply) = .empty;
    defer {
        for (pending_replies.items) |br| std.testing.allocator.free(br.bytes);
        pending_replies.deinit(std.testing.allocator);
    }

    try std.testing.expect(try pumpReader(&r, std.testing.allocator, &tracker, true, &events, &pending_errors, &pending_replies));
    try std.testing.expect(try pumpReader(&r, std.testing.allocator, &tracker, true, &events, &pending_errors, &pending_replies));
    try std.testing.expectEqual(@as(usize, 2), pending_replies.items.len);

    const b2 = takeBufferedReply(&pending_replies, 2).?;
    std.testing.allocator.free(b2);
    try std.testing.expectEqual(@as(usize, 1), pending_replies.items.len);
    const b1 = takeBufferedReply(&pending_replies, 1).?;
    std.testing.allocator.free(b1);
    try std.testing.expect(takeBufferedReply(&pending_replies, 1) == null);
}

test "takeIncoming drains events first, then unclaimed errors" {
    const gpa = std.testing.allocator;
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);
    var pending_errors: std.ArrayList(PendingError) = .empty;
    defer pending_errors.deinit(gpa);

    // Nothing buffered -> null.
    try std.testing.expect(takeIncoming(&events, &pending_errors) == null);

    try events.append(gpa, .{ .bytes = [_]u8{7} ** 32 });
    try pending_errors.append(gpa, .{ .seq = 9, .err = .{ .code = 3, .sequence = 9, .bad_value = 0, .minor_opcode = 0, .major_opcode = 12 } });

    // Event comes out first.
    const a = takeIncoming(&events, &pending_errors).?;
    try std.testing.expect(a == .event);
    try std.testing.expectEqual(@as(u8, 7), a.event.bytes[0]);
    // Then the error.
    const b = takeIncoming(&events, &pending_errors).?;
    try std.testing.expect(b == .err);
    try std.testing.expectEqual(@as(u8, 3), b.err.code);
    // Then empty again.
    try std.testing.expect(takeIncoming(&events, &pending_errors) == null);
}

test "generateId walks the granted range low-to-high by the mask granularity" {
    // A typical grant: base 0x04200000, mask 0x001fffff (granularity 1).
    var c: Connection = undefined;
    c.setup = .{
        .protocol_major = 11,
        .protocol_minor = 0,
        .release_number = 0,
        .resource_id_base = 0x04200000,
        .resource_id_mask = 0x001fffff,
        .min_keycode = 8,
        .max_keycode = 255,
        .roots_len = 1,
        .root = 0,
        .root_visual = 0,
    };
    c.last_xid = 0;
    try std.testing.expectEqual(@as(u32, 0x04200001), c.generateId());
    try std.testing.expectEqual(@as(u32, 0x04200002), c.generateId());
    try std.testing.expectEqual(@as(u32, 0x04200003), c.generateId());

    // A coarse mask (granularity 0x20) steps in that stride, still base-OR'd.
    c.setup.resource_id_base = 0x0a00000;
    c.setup.resource_id_mask = 0x1fffe0;
    c.last_xid = 0;
    try std.testing.expectEqual(@as(u32, 0x0a00020), c.generateId());
    try std.testing.expectEqual(@as(u32, 0x0a00040), c.generateId());
}

test "classifyByBase resolves a code to the owning cached extension" {
    const gpa = std.testing.allocator;
    var m: std.StringHashMapUnmanaged(ExtensionInfo) = .{};
    defer m.deinit(gpa);
    try m.put(gpa, "XKEYBOARD", .{ .present = true, .major_opcode = 0x87, .first_event = 0x40, .first_error = 0x20 });
    try std.testing.expectEqualStrings("XKEYBOARD", classifyByBase(&m, 0x40, true).?); // event base
    try std.testing.expectEqualStrings("XKEYBOARD", classifyByBase(&m, 0x20, false).?); // error base
    try std.testing.expect(classifyByBase(&m, 0x02, true) == null); // below base -> none
}
