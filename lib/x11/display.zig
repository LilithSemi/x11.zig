//! DISPLAY-string parsing: turns "[protocol/][host]:display[.screen]" into a
//! borrowed Display. The whole surface is untrusted text, so every conversion
//! is a recoverable fault, never an assert.
const std = @import("std");

/// Display connection info parsed from a DISPLAY string.
/// All slices borrow from the input; the input must outlive this struct.
pub const Display = struct {
    host: []const u8,
    protocol: []const u8,
    display: u16,
    screen: u16,
};

pub const ParseError = error{InvalidDisplay};

/// Parse a DISPLAY string of the form "[protocol/][host]:display[.screen]".
/// All slices in the returned Display borrow from `s`; `s` must outlive the result.
pub fn parseDisplay(s: []const u8) ParseError!Display {
    // Find the last ':' that is not inside square brackets (to handle IPv6 like [::1]:0).
    var colon: ?usize = null;
    var depth: usize = 0;
    for (s, 0..) |c, i| {
        switch (c) {
            '[' => depth += 1,
            ']' => if (depth > 0) {
                depth -= 1;
            },
            ':' => if (depth == 0) {
                colon = i;
            },
            else => {},
        }
    }
    const col = colon orelse return error.InvalidDisplay;

    const host_part = s[0..col];
    const num_part = s[col + 1 ..];

    const dot = std.mem.indexOfScalar(u8, num_part, '.');
    const display_str = if (dot) |d| num_part[0..d] else num_part;
    const screen_str = if (dot) |d| num_part[d + 1 ..] else "";

    const disp_num = std.fmt.parseInt(u16, display_str, 10) catch return error.InvalidDisplay;
    const scr_num = if (screen_str.len > 0)
        std.fmt.parseInt(u16, screen_str, 10) catch return error.InvalidDisplay
    else
        0;

    const slash = std.mem.indexOfScalar(u8, host_part, '/');
    const protocol: []const u8 = if (slash) |sl| host_part[0..sl] else "";
    const host: []const u8 = if (slash) |sl| host_part[sl + 1 ..] else host_part;

    return Display{
        .host = host,
        .protocol = protocol,
        .display = disp_num,
        .screen = scr_num,
    };
}

test "parseDisplay basic" {
    const a = try parseDisplay(":0");
    try std.testing.expectEqualStrings("", a.host);
    try std.testing.expectEqual(@as(u16, 0), a.display);
    try std.testing.expectEqual(@as(u16, 0), a.screen);
    const b = try parseDisplay(":1.2");
    try std.testing.expectEqual(@as(u16, 1), b.display);
    try std.testing.expectEqual(@as(u16, 2), b.screen);
    const c = try parseDisplay("myhost:0");
    try std.testing.expectEqualStrings("myhost", c.host);
    const d = try parseDisplay("unix:0");
    try std.testing.expectEqualStrings("unix", d.host);
    try std.testing.expectError(error.InvalidDisplay, parseDisplay("nope"));
}

test "parseDisplay ipv6 bracket host" {
    const d = try parseDisplay("[::1]:1.0");
    try std.testing.expectEqualStrings("[::1]", d.host);
    try std.testing.expectEqual(@as(u16, 1), d.display);
    try std.testing.expectEqual(@as(u16, 0), d.screen);
}
