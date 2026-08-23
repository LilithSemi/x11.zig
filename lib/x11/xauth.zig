//! Xauthority parser for MIT-MAGIC-COOKIE-1.
//!
//! Binary format (all multi-byte integers big-endian u16 length prefixes):
//!   family:     u16
//!   address:    u16 len + [len]u8
//!   number:     u16 len + [len]u8   (display number as ASCII, empty = wildcard)
//!   name:       u16 len + [len]u8   (e.g. "MIT-MAGIC-COOKIE-1")
//!   data:       u16 len + [len]u8   (the cookie bytes)
//!
//! Unlike the connection wire, the Xauthority file is fixed big-endian on disk
//! regardless of host byte order, so the length prefixes are read as `.big`.
const std = @import("std");

/// A truncated or structurally invalid Xauthority buffer. The file is untrusted
/// input, so a malformed entry is a recoverable fault, not a programmer error.
pub const ParseError = error{MalformedXauth};

/// parseXauth's full fault surface: a malformed buffer, or OOM from duping the
/// matched entry's owned copy.
pub const Error = ParseError || std.mem.Allocator.Error;

/// An X11 auth token. Both slices are owned (alloc.dupe'd); free with deinit.
pub const Auth = struct {
    name: []u8,
    data: []u8,

    pub fn deinit(self: Auth, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.data);
    }
};

/// Parse a raw ~/.Xauthority byte buffer.
///
/// Returns the FIRST entry whose number field matches display_num (or is empty,
/// which is a wildcard) AND whose name is "MIT-MAGIC-COOKIE-1".
/// Returns null when no matching entry exists.
/// Returns error.MalformedXauth on any truncated or structurally invalid input.
/// The returned Auth is owned: caller must call Auth.deinit(alloc).
pub fn parseXauth(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    display_num: []const u8,
) Error!?Auth {
    var pos: usize = 0;

    while (pos < bytes.len) {
        // family (u16 big-endian), any value accepted
        if (pos + 2 > bytes.len) return error.MalformedXauth;
        pos += 2;

        // address (u16 len + bytes)
        if (pos + 2 > bytes.len) return error.MalformedXauth;
        const addr_len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        pos += 2;
        if (pos + addr_len > bytes.len) return error.MalformedXauth;
        pos += addr_len;

        // number (u16 len + bytes), the display number as ASCII
        if (pos + 2 > bytes.len) return error.MalformedXauth;
        const num_len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        pos += 2;
        if (pos + num_len > bytes.len) return error.MalformedXauth;
        const number = bytes[pos .. pos + num_len];
        pos += num_len;

        // name (u16 len + bytes)
        if (pos + 2 > bytes.len) return error.MalformedXauth;
        const name_len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        pos += 2;
        if (pos + name_len > bytes.len) return error.MalformedXauth;
        const name = bytes[pos .. pos + name_len];
        pos += name_len;

        // data (u16 len + bytes)
        if (pos + 2 > bytes.len) return error.MalformedXauth;
        const data_len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        pos += 2;
        if (pos + data_len > bytes.len) return error.MalformedXauth;
        const data = bytes[pos .. pos + data_len];
        pos += data_len;

        // Match: number must equal display_num OR be empty (wildcard).
        // Name must be "MIT-MAGIC-COOKIE-1".
        const number_ok = number.len == 0 or std.mem.eql(u8, number, display_num);
        const name_ok = std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1");

        if (number_ok and name_ok) {
            const owned_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_name);
            const owned_data = try alloc.dupe(u8, data);
            return Auth{ .name = owned_name, .data = owned_data };
        }
    }

    return null;
}

/// Read the file at path and return the first matching auth entry, or null.
/// Thin hosted shim over `parseXauth`: the error set is inferred because it is
/// dominated by the filesystem faults `readFileAlloc` surfaces, which vary by
/// target. The pure parser `parseXauth` carries the explicit set instead.
pub fn readXauthFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    display_num: []const u8,
) !?Auth {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(bytes);
    return parseXauth(alloc, bytes, display_num);
}

/// loadFromPath / loadForDisplay fault surface: reading the file, or parsing it.
pub const LoadError = std.Io.Dir.ReadFileAllocError || Error;

/// Read an Xauthority file and return the MIT-MAGIC-COOKIE-1 entry matching
/// display_num, or null. A MISSING file is anonymous (null), not a fault:
/// connecting without auth is legitimate (e.g. an -ac server).
pub fn loadFromPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    display_num: []const u8,
) LoadError!?Auth {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.unlimited) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer gpa.free(bytes);
    return parseXauth(gpa, bytes, display_num);
}

/// Resolve the Xauthority path (XAUTHORITY, else $HOME/.Xauthority) from the
/// process environment, then loadFromPath. Returns null when neither var is set.
pub fn loadForDisplay(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    display_num: []const u8,
) LoadError!?Auth {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = if (environ.get("XAUTHORITY")) |xa|
        xa
    else if (environ.get("HOME")) |home|
        (std.fmt.bufPrint(&path_buf, "{s}/.Xauthority", .{home}) catch return null)
    else
        return null;
    return loadFromPath(gpa, io, path, display_num);
}

// Write one Xauthority entry into buf starting at pos; return the new position.
fn writeXauthEntry(
    buf: []u8,
    pos: usize,
    family: u16,
    address: []const u8,
    number: []const u8,
    name: []const u8,
    data: []const u8,
) usize {
    var p = pos;
    std.mem.writeInt(u16, buf[p..][0..2], family, .big);
    p += 2;
    std.mem.writeInt(u16, buf[p..][0..2], @intCast(address.len), .big);
    p += 2;
    @memcpy(buf[p .. p + address.len], address);
    p += address.len;
    std.mem.writeInt(u16, buf[p..][0..2], @intCast(number.len), .big);
    p += 2;
    @memcpy(buf[p .. p + number.len], number);
    p += number.len;
    std.mem.writeInt(u16, buf[p..][0..2], @intCast(name.len), .big);
    p += 2;
    @memcpy(buf[p .. p + name.len], name);
    p += name.len;
    std.mem.writeInt(u16, buf[p..][0..2], @intCast(data.len), .big);
    p += 2;
    @memcpy(buf[p .. p + data.len], data);
    p += data.len;
    return p;
}

test "parseXauth matches display 0, ignores display 1" {
    const alloc = std.testing.allocator;

    // Two entries: display "0" with 0xAA cookie, display "1" with 0xBB cookie.
    var buf: [256]u8 = undefined;
    const cookie0 = [_]u8{0xAA} ** 16;
    const cookie1 = [_]u8{0xBB} ** 16;
    var p: usize = 0;
    p = writeXauthEntry(&buf, p, 0x0101, "localhost", "0", "MIT-MAGIC-COOKIE-1", &cookie0);
    p = writeXauthEntry(&buf, p, 0x0101, "localhost", "1", "MIT-MAGIC-COOKIE-1", &cookie1);

    const result = try parseXauth(alloc, buf[0..p], "0");
    try std.testing.expect(result != null);
    const auth = result.?;
    defer auth.deinit(alloc);
    try std.testing.expectEqualStrings("MIT-MAGIC-COOKIE-1", auth.name);
    try std.testing.expectEqualSlices(u8, &cookie0, auth.data);
}

test "parseXauth returns null when no match" {
    const alloc = std.testing.allocator;

    var buf: [256]u8 = undefined;
    const cookie = [_]u8{0xCC} ** 16;
    var p: usize = 0;
    p = writeXauthEntry(&buf, p, 0x0101, "localhost", "1", "MIT-MAGIC-COOKIE-1", &cookie);

    const result = try parseXauth(alloc, buf[0..p], "0");
    try std.testing.expect(result == null);
}

test "parseXauth wildcard number matches any display" {
    const alloc = std.testing.allocator;

    var buf: [256]u8 = undefined;
    const cookie = [_]u8{0xDD} ** 16;
    var p: usize = 0;
    // number="" -> wildcard
    p = writeXauthEntry(&buf, p, 0x0100, "", "", "MIT-MAGIC-COOKIE-1", &cookie);

    const result = try parseXauth(alloc, buf[0..p], "99");
    try std.testing.expect(result != null);
    const auth = result.?;
    defer auth.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &cookie, auth.data);
}

test "parseXauth returns error on truncated buffer" {
    const alloc = std.testing.allocator;

    // A buffer that starts a valid entry header but is cut off mid-address.
    var buf: [6]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 0x0101, .big); // family
    std.mem.writeInt(u16, buf[2..4], 20, .big); // address_len = 20 (but only 2 bytes follow)
    std.mem.writeInt(u16, buf[4..6], 0, .big); // (truncated: no address bytes)

    try std.testing.expectError(error.MalformedXauth, parseXauth(alloc, &buf, "0"));
}

test "parseXauth skips wrong-name entries" {
    const alloc = std.testing.allocator;

    var buf: [256]u8 = undefined;
    const cookie = [_]u8{0xEE} ** 16;
    var p: usize = 0;
    // Entry with a different name, should not match
    p = writeXauthEntry(&buf, p, 0x0100, "", "0", "XDM-AUTHORIZATION-1", &cookie);
    // Entry with the right name
    p = writeXauthEntry(&buf, p, 0x0100, "", "0", "MIT-MAGIC-COOKIE-1", &cookie);

    const result = try parseXauth(alloc, buf[0..p], "0");
    try std.testing.expect(result != null);
    const auth = result.?;
    defer auth.deinit(alloc);
    try std.testing.expectEqualStrings("MIT-MAGIC-COOKIE-1", auth.name);
}

test "loadFromPath reads and matches a cookie for the display" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One entry: family=256(local), addr="host", number="0",
    // name="MIT-MAGIC-COOKIE-1", data=16 bytes 0xAB. Reuse the existing
    // writeXauthEntry helper (below) rather than hand-rolling the encoding
    // again; std.ArrayList(u8) has no `.writer` in this Zig, so an
    // Io.Writer-based builder is not the natural fit here anyway.
    var buf: [256]u8 = undefined;
    const cookie = [_]u8{0xAB} ** 16;
    const blob_len = writeXauthEntry(&buf, 0, 256, "host", "0", "MIT-MAGIC-COOKIE-1", &cookie);
    const blob = buf[0..blob_len];

    const io = std.testing.io; // test IO (std.Io.Threaded, per std/testing.zig)
    try tmp.dir.writeFile(io, .{ .sub_path = "xauth", .data = blob });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Io.Dir has no `realpath`; the 0.16 equivalent is `realPathFile`, which
    // returns the written length rather than a slice.
    const path_len = try tmp.dir.realPathFile(io, "xauth", &path_buf);
    const path = path_buf[0..path_len];

    const got = try loadFromPath(gpa, io, path, "0");
    try std.testing.expect(got != null);
    var auth = got.?;
    defer auth.deinit(gpa);
    try std.testing.expectEqualStrings("MIT-MAGIC-COOKIE-1", auth.name);
    try std.testing.expectEqual(@as(usize, 16), auth.data.len);
    try std.testing.expectEqual(@as(u8, 0xAB), auth.data[0]);

    // A missing file is anonymous, not an error.
    try std.testing.expect((try loadFromPath(gpa, io, "/nonexistent/xauth", "0")) == null);
}
