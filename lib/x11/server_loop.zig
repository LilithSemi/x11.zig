//! Pure, socket-free, xproto-free helpers for the server's multiplexed serve
//! loop: request framing off a raw input buffer, and per-client resource-id
//! range allocation. Kept separate from server.zig so the framing logic is
//! unit-testable without any I/O.
const std = @import("std");

/// Hard ceiling on one request's total wire length (header + body), in bytes.
/// A plain core request's length field is a u16 count of 4-byte units, so it
/// naturally tops out at 65535*4 (262140) well under this; this ceiling is
/// what actually bounds two things raised together by BIG-REQUESTS: the
/// heap-grown per-conn request buffer (server.zig's request_buf cap) and the
/// largest extended-form (units==0, real u32 length) request frameRequest
/// will accept. BigReqEnable advertises max_request_bytes/4 as its
/// maximum_request_length, so it must stay in lockstep with the buffer cap --
/// single source of truth, not duplicated as a literal in server.zig.
pub const max_request_bytes: usize = 4 * 1024 * 1024;

/// Outcome of trying to frame the request at the head of an input buffer.
/// `complete` carries that request's total byte length (header + body,
/// INCLUDING the extended-form's 4 big-length bytes if `extended`) and
/// whether it used BIG-REQUESTS' extended (units==0 + u32 length) form.
pub const Frame = union(enum) {
    incomplete,
    malformed,
    complete: struct { total: usize, extended: bool },
};

/// Frame the first request at the head of `buf`, reading its 4-byte-unit length
/// in the client's byte order. Pure: inspects bytes, consumes nothing. A plain
/// (units != 0) request's total is exactly units*4; a zero unit count is only
/// legal once the client has enabled BIG-REQUESTS (`big_enabled`), in which
/// case a real 32-bit 4-byte-unit length follows the header at buf[4..8]. Any
/// total exceeding max_request_bytes is refused as malformed rather than
/// framed into an oversized allocation.
pub fn frameRequest(buf: []const u8, endian: std.builtin.Endian, big_enabled: bool) Frame {
    if (buf.len < 4) return .incomplete;
    const units = std.mem.readInt(u16, buf[2..4], endian);
    if (units == 0) {
        // Extended form (BIG-REQUESTS): illegal unless BigReqEnable already
        // ran on this conn -- a plain client sending units==0 is malformed,
        // same as before this extension existed.
        if (!big_enabled) return .malformed;
        if (buf.len < 8) return .incomplete;
        const big = std.mem.readInt(u32, buf[4..8], endian);
        if (big == 0) return .malformed;
        const total: usize = @as(usize, big) * 4;
        if (total > max_request_bytes) return .malformed;
        if (buf.len < total) return .incomplete;
        return .{ .complete = .{ .total = total, .extended = true } };
    }
    const total: usize = @as(usize, units) * 4;
    if (buf.len < total) return .incomplete;
    return .{ .complete = .{ .total = total, .extended = false } };
}

/// The (base, mask) resource-id range for the Nth accepted client. A fixed
/// 21-bit mask; base steps by mask+1 (0x200000) per client so no two clients'
/// id spaces overlap and base carries none of the mask bits. Wrapping mul keeps
/// this panic-free at absurd client counts (range reuse for dropped clients is
/// a later sub-project); root id 0x12a sits below every range.
pub const ResourceRange = struct { base: u32, mask: u32 };
pub fn resourceRangeForIndex(index: u32) ResourceRange {
    const mask: u32 = 0x001fffff;
    const base: u32 = 0x00400000 +% index *% (mask + 1);
    return .{ .base = base, .mask = mask };
}

test "frameRequest: incomplete, complete, malformed, back-to-back" {
    // Fewer than 4 bytes: cannot even read the length field.
    try std.testing.expectEqual(Frame.incomplete, frameRequest(&[_]u8{ 43, 0 }, .little, false));
    // A 1-unit (4-byte) GetInputFocus: complete, total 4, not extended.
    try std.testing.expectEqual(Frame{ .complete = .{ .total = 4, .extended = false } }, frameRequest(&[_]u8{ 43, 0, 1, 0 }, .little, false));
    // length units == 0 is illegal for a core request when BIG-REQUESTS isn't enabled.
    try std.testing.expectEqual(Frame.malformed, frameRequest(&[_]u8{ 43, 0, 0, 0 }, .little, false));
    // Declares 2 units (8 bytes) but only 4 present: incomplete.
    try std.testing.expectEqual(Frame.incomplete, frameRequest(&[_]u8{ 43, 0, 2, 0 }, .little, false));
    // Two back-to-back 1-unit requests: frame only the first.
    try std.testing.expectEqual(Frame{ .complete = .{ .total = 4, .extended = false } }, frameRequest(&[_]u8{ 43, 0, 1, 0, 43, 0, 1, 0 }, .little, false));
    // Big-endian length is read in the client's order.
    try std.testing.expectEqual(Frame{ .complete = .{ .total = 4, .extended = false } }, frameRequest(&[_]u8{ 43, 0, 0, 1 }, .big, false));
}

test "frameRequest: BIG-REQUESTS extended form (units==0, u32 length)" {
    // units==0 is still malformed with big_enabled=false, unchanged from the
    // plain-client behavior above.
    try std.testing.expectEqual(Frame.malformed, frameRequest(&[_]u8{ 43, 0, 0, 0 }, .little, false));

    // units==0 but too short to even carry the u32 length: incomplete.
    try std.testing.expectEqual(Frame.incomplete, frameRequest(&[_]u8{ 43, 0, 0, 0, 1, 0 }, .little, true));

    // A minimal extended-form request: 3 units (12 bytes) declared via the
    // u32 length field, header + a single 4-byte body word present.
    var buf3 = [_]u8{ 43, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(Frame{ .complete = .{ .total = 12, .extended = true } }, frameRequest(&buf3, .little, true));

    // The declared total exceeds what's buffered so far: incomplete.
    var buf3_short = [_]u8{ 43, 0, 0, 0, 3, 0, 0, 0 };
    try std.testing.expectEqual(Frame.incomplete, frameRequest(&buf3_short, .little, true));

    // u32 length of 0 is malformed (extended form still needs a real length).
    try std.testing.expectEqual(Frame.malformed, frameRequest(&[_]u8{ 43, 0, 0, 0, 0, 0, 0, 0 }, .little, true));

    // A declared total beyond max_request_bytes is refused rather than framed
    // into an oversized allocation.
    const over_units: u32 = @intCast(max_request_bytes / 4 + 1);
    var buf_over = [_]u8{ 43, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, buf_over[4..8], over_units, .little);
    try std.testing.expectEqual(Frame.malformed, frameRequest(&buf_over, .little, true));

    // Big-endian u32 length is read in the client's order too.
    var buf3_big = [_]u8{ 43, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0 };
    try std.testing.expectEqual(Frame{ .complete = .{ .total = 12, .extended = true } }, frameRequest(&buf3_big, .big, true));
}

test "resourceRangeForIndex: distinct, non-overlapping, base & mask == 0" {
    const r0 = resourceRangeForIndex(0);
    const r1 = resourceRangeForIndex(1);
    const r2 = resourceRangeForIndex(2);
    try std.testing.expectEqual(@as(u32, 0x00400000), r0.base);
    try std.testing.expectEqual(@as(u32, 0x00600000), r1.base);
    try std.testing.expectEqual(@as(u32, 0x00800000), r2.base);
    try std.testing.expectEqual(@as(u32, 0x001fffff), r0.mask);
    // base carries none of the mask bits, so base | offset never collides across clients.
    try std.testing.expectEqual(@as(u32, 0), r0.base & r0.mask);
    try std.testing.expectEqual(@as(u32, 0), r1.base & r1.mask);
    try std.testing.expectEqual(@as(u32, 0), r2.base & r2.mask);
}
