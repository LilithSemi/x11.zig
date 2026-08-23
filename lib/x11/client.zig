const std = @import("std");
const connection = @import("connection.zig");
const cookie = @import("cookie.zig");
const wire = @import("wire.zig");

pub const Client = struct {
    conn: *connection.Connection,

    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        display_str: ?[]const u8,
        auth: ?@import("xauth.zig").Auth,
        environ: ?*const std.process.Environ.Map,
    ) !Client {
        return .{ .conn = try connection.Connection.connect(gpa, io, display_str, auth, environ) };
    }

    pub fn defaultScreen(self: *Client) ?@import("wire.zig").Screen {
        return self.conn.defaultScreen();
    }

    pub fn close(self: *Client) void {
        self.conn.disconnect();
    }

    pub fn sendCookie(
        self: *Client,
        comptime Reply: type,
        major: u8,
        minor: u8,
        extra: []const u8,
    ) !cookie.Cookie(Reply) {
        const seq = try self.conn.send(major, minor, extra);
        return .{ .sequence = seq };
    }

    pub fn awaitReply(
        self: *Client,
        comptime Reply: type,
        c: cookie.Cookie(Reply),
        out_err: *wire.XError,
    ) !connection.Reply {
        return self.conn.reply(c.sequence, out_err);
    }

    pub fn queryExtension(self: *Client, name: []const u8) !connection.ExtensionInfo {
        var xe: wire.XError = undefined;
        return self.conn.queryExtension(name, &xe);
    }

    pub fn extensionMajor(self: *Client, name: []const u8) ?u8 {
        return self.conn.extensionMajor(name);
    }

    /// Allocate a fresh resource id for a window, pixmap, gc, colormap, or cursor.
    pub fn generateId(self: *Client) u32 {
        return self.conn.generateId();
    }

    /// Block until the next event or unclaimed X error. See Connection.nextEvent
    /// for the await-before-loop boundary.
    pub fn nextEvent(self: *Client) connection.PumpError!connection.Incoming {
        return self.conn.nextEvent();
    }

    /// Non-blocking: the next ready event/error, or null. Pair with connectionFd().
    pub fn pollEvent(self: *Client) connection.PumpError!?connection.Incoming {
        return self.conn.pollEvent();
    }

    /// The socket handle, for an external poll()/select() set.
    pub fn connectionFd(self: *Client) std.posix.fd_t {
        return self.conn.connectionFd();
    }

    pub fn eventExtension(self: *Client, code: u8) ?[]const u8 {
        return self.conn.eventExtension(code);
    }

    pub fn errorExtension(self: *Client, code: u8) ?[]const u8 {
        return self.conn.errorExtension(code);
    }
};

test "Cookie boxes the send sequence and exposes reply type" {
    const R = struct { present: bool };
    const c: cookie.Cookie(R) = .{ .sequence = 7 };
    try std.testing.expectEqual(@as(u64, 7), c.sequence);
    try std.testing.expect(cookie.Cookie(R).ReplyType == R);
}
