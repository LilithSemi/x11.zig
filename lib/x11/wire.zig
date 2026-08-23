//! X11 connection-setup wire codec. encodeSetupRequest serialises the client
//! hello (byte order, version, auth). parseSetupReply decodes the server's
//! success or fail response into a Setup.
const std = @import("std");
const builtin = @import("builtin");

/// The X11 protocol carries multi-byte integers in the *client's* byte order:
/// the client declares it in the SetupRequest byte_order field (0x6c little,
/// 0x42 big) and the server encodes every reply and event to match. So the
/// correct order for both encode and decode is always the host's native order,
/// never a fixed network order. This is not an endianness assumption; it is the
/// protocol contract.
const native_endian = builtin.cpu.arch.endian();

/// Serialising the client SetupRequest: our own auth strings are the only
/// fault, plus whatever the destination writer reports.
pub const EncodeSetupError = error{AuthTooLong} || std.Io.Writer.Error;

/// Decoding the server SetupReply. SetupFailed/SetupAuthenticate are the
/// server's two non-success statuses; MalformedSetup covers any short or
/// structurally invalid buffer.
pub const ParseSetupError = error{ SetupFailed, SetupAuthenticate, MalformedSetup };

/// Serialising a request header + body.
pub const EncodeRequestError = error{RequestTooLong} || std.Io.Writer.Error;

/// Round n up to the next multiple of 4.
pub fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// The useful subset of the X11 connection-setup success reply.
pub const Setup = struct {
    protocol_major: u16,
    protocol_minor: u16,
    release_number: u32,
    resource_id_base: u32,
    resource_id_mask: u32,
    min_keycode: u8,
    max_keycode: u8,
    roots_len: u8,
    root: u32,
    root_visual: u32,
    /// Borrowed backing bytes for the vendor/formats/screens accessors below.
    /// Defaults to empty so existing constructions (that only use the scalar
    /// fields above) stay valid without providing it.
    raw: []const u8 = &.{},
    vendor_len: u16 = 0,
    pixmap_formats_len: u8 = 0,
    default_screen: u16 = 0,

    pub fn vendor(self: Setup) []const u8 {
        const end = @min(40 + @as(usize, self.vendor_len), self.raw.len);
        return self.raw[@min(40, self.raw.len)..end];
    }
    pub fn formats(self: Setup) FixedIter(Format) {
        const off = 40 + pad4(@as(usize, self.vendor_len));
        return .{ .bytes = self.raw[@min(off, self.raw.len)..], .count = self.pixmap_formats_len };
    }
    pub fn screens(self: Setup) ScreenIter {
        const off = 40 + pad4(@as(usize, self.vendor_len)) + @as(usize, self.pixmap_formats_len) * Format.wire_size;
        return .{ .bytes = self.raw[@min(off, self.raw.len)..], .count = self.roots_len };
    }
    pub fn screenAt(self: Setup, index: usize) ?Screen {
        var it = self.screens();
        var k: usize = 0;
        while (it.next()) |s| : (k += 1) if (k == index) return s;
        return null;
    }
};

pub const Format = struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    pub const wire_size: usize = 8;
    pub fn decode(b: []const u8) Format {
        return .{ .depth = b[0], .bits_per_pixel = b[1], .scanline_pad = b[2] };
    }
};

pub const VisualType = struct {
    visual_id: u32,
    class: u8,
    bits_per_rgb_value: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    pub const wire_size: usize = 24;
    pub fn decode(b: []const u8) VisualType {
        return .{
            .visual_id = std.mem.readInt(u32, b[0..4], native_endian),
            .class = b[4],
            .bits_per_rgb_value = b[5],
            .colormap_entries = std.mem.readInt(u16, b[6..8], native_endian),
            .red_mask = std.mem.readInt(u32, b[8..12], native_endian),
            .green_mask = std.mem.readInt(u32, b[12..16], native_endian),
            .blue_mask = std.mem.readInt(u32, b[16..20], native_endian),
        };
    }
};

/// Fixed-stride, zero-alloc iterator over a byte range holding `count` T records.
pub fn FixedIter(comptime T: type) type {
    return struct {
        bytes: []const u8,
        count: usize,
        i: usize = 0,
        pub fn next(self: *@This()) ?T {
            if (self.i >= self.count) return null;
            const off = self.i * T.wire_size;
            if (off + T.wire_size > self.bytes.len) return null;
            const v = T.decode(self.bytes[off..]);
            self.i += 1;
            return v;
        }
        pub fn len(self: @This()) usize {
            return self.count;
        }
    };
}

pub const Depth = struct {
    depth: u8,
    visuals_len: u16,
    visuals_raw: []const u8,
    pub fn visuals(self: Depth) FixedIter(VisualType) {
        return .{ .bytes = self.visuals_raw, .count = self.visuals_len };
    }
    /// Wire length of one DEPTH record: 8-byte header + its VISUALTYPE array.
    fn byteLen(b: []const u8) usize {
        const vlen = std.mem.readInt(u16, b[2..4], native_endian);
        return 8 + @as(usize, vlen) * VisualType.wire_size;
    }
    fn decode(b: []const u8) Depth {
        const vlen = std.mem.readInt(u16, b[2..4], native_endian);
        const total = byteLen(b);
        return .{ .depth = b[0], .visuals_len = vlen, .visuals_raw = b[8..@min(total, b.len)] };
    }
};

pub const DepthIter = struct {
    bytes: []const u8,
    count: usize,
    i: usize = 0,
    off: usize = 0,
    pub fn next(self: *DepthIter) ?Depth {
        if (self.i >= self.count or self.off + 8 > self.bytes.len) return null;
        const d = Depth.decode(self.bytes[self.off..]);
        self.off += Depth.byteLen(self.bytes[self.off..]);
        self.i += 1;
        return d;
    }
    pub fn len(self: DepthIter) usize {
        return self.count;
    }
};

pub const Screen = struct {
    root: u32,
    default_colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    current_input_masks: u32,
    width_px: u16,
    height_px: u16,
    width_mm: u16,
    height_mm: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: u32,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depths_len: u8,
    depths_raw: []const u8,
    pub fn depths(self: Screen) DepthIter {
        return .{ .bytes = self.depths_raw, .count = self.allowed_depths_len };
    }
    /// Wire length of one SCREEN: 40-byte header + each DEPTH record.
    fn byteLen(b: []const u8) usize {
        const ndepths = b[39];
        var off: usize = 40;
        var k: usize = 0;
        while (k < ndepths) : (k += 1) {
            if (off + 8 > b.len) break;
            off += Depth.byteLen(b[off..]);
        }
        return off;
    }
    fn decode(b: []const u8) Screen {
        const total = byteLen(b);
        return .{
            .root = std.mem.readInt(u32, b[0..4], native_endian),
            .default_colormap = std.mem.readInt(u32, b[4..8], native_endian),
            .white_pixel = std.mem.readInt(u32, b[8..12], native_endian),
            .black_pixel = std.mem.readInt(u32, b[12..16], native_endian),
            .current_input_masks = std.mem.readInt(u32, b[16..20], native_endian),
            .width_px = std.mem.readInt(u16, b[20..22], native_endian),
            .height_px = std.mem.readInt(u16, b[22..24], native_endian),
            .width_mm = std.mem.readInt(u16, b[24..26], native_endian),
            .height_mm = std.mem.readInt(u16, b[26..28], native_endian),
            .min_installed_maps = std.mem.readInt(u16, b[28..30], native_endian),
            .max_installed_maps = std.mem.readInt(u16, b[30..32], native_endian),
            .root_visual = std.mem.readInt(u32, b[32..36], native_endian),
            .backing_stores = b[36],
            .save_unders = b[37],
            .root_depth = b[38],
            .allowed_depths_len = b[39],
            .depths_raw = b[40..@min(total, b.len)],
        };
    }
};

pub const ScreenIter = struct {
    bytes: []const u8,
    count: usize,
    i: usize = 0,
    off: usize = 0,
    pub fn next(self: *ScreenIter) ?Screen {
        if (self.i >= self.count or self.off + 40 > self.bytes.len) return null;
        const s = Screen.decode(self.bytes[self.off..]);
        self.off += Screen.byteLen(self.bytes[self.off..]);
        self.i += 1;
        return s;
    }
    pub fn len(self: ScreenIter) usize {
        return self.count;
    }
};

/// Write the X11 SetupRequest to w using the host's native byte order.
///
/// Wire layout (all multi-byte fields in native byte order):
///   u8  byte_order   0x6c = little, 0x42 = big
///   u8  pad          0
///   u16 protocol_major  11
///   u16 protocol_minor  0
///   u16 auth_name_len
///   u16 auth_data_len
///   u16 pad2         0
///   [auth_name_len]u8  auth_name, zero-padded to 4-byte boundary
///   [auth_data_len]u8  auth_data, zero-padded to 4-byte boundary
pub fn encodeSetupRequest(
    w: *std.Io.Writer,
    auth_name: []const u8,
    auth_data: []const u8,
) EncodeSetupError!void {
    if (auth_name.len > std.math.maxInt(u16) or auth_data.len > std.math.maxInt(u16)) {
        return error.AuthTooLong;
    }

    const byte_order: u8 = if (native_endian == .little) 0x6c else 0x42;
    const zeros = [3]u8{ 0, 0, 0 };

    var u16buf: [2]u8 = undefined;

    try w.writeAll(&[_]u8{ byte_order, 0 });

    std.mem.writeInt(u16, &u16buf, 11, native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, 0, native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, @intCast(auth_name.len), native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, @intCast(auth_data.len), native_endian);
    try w.writeAll(&u16buf);

    std.mem.writeInt(u16, &u16buf, 0, native_endian);
    try w.writeAll(&u16buf);

    try w.writeAll(auth_name);
    const name_pad = pad4(auth_name.len) - auth_name.len;
    try w.writeAll(zeros[0..name_pad]);

    try w.writeAll(auth_data);
    const data_pad = pad4(auth_data.len) - auth_data.len;
    try w.writeAll(zeros[0..data_pad]);
}

/// Parse a server SetupReply from the raw bytes.
///
/// Returns error.SetupFailed on status 0, error.SetupAuthenticate on status 2.
/// Parses only the first SCREEN for root and root_visual.
/// Returns error.MalformedSetup on any short or structurally invalid buffer.
/// The scalar convenience fields (protocol_major, root, root_visual, etc.) are
/// copied out, but the returned Setup's `raw` field BORROWS `bytes` for the
/// vendor()/formats()/screens()/screenAt() accessors. `bytes` must outlive the
/// returned Setup if those accessors are used. (A later task makes the
/// Connection own the buffer so this holds for the lifetime of the setup.)
pub fn parseSetupReply(bytes: []const u8) ParseSetupError!Setup {
    if (bytes.len < 1) return error.MalformedSetup;

    switch (bytes[0]) {
        0 => return error.SetupFailed,
        2 => return error.SetupAuthenticate,
        1 => {
            // Fixed header occupies bytes 0-39 (40 bytes).
            if (bytes.len < 40) return error.MalformedSetup;

            const protocol_major = std.mem.readInt(u16, bytes[2..4], native_endian);
            const protocol_minor = std.mem.readInt(u16, bytes[4..6], native_endian);
            const release_number = std.mem.readInt(u32, bytes[8..12], native_endian);
            const resource_id_base = std.mem.readInt(u32, bytes[12..16], native_endian);
            const resource_id_mask = std.mem.readInt(u32, bytes[16..20], native_endian);
            const vendor_len = std.mem.readInt(u16, bytes[24..26], native_endian);
            const roots_len = bytes[28];
            const pixmap_formats_len = bytes[29];
            const min_keycode = bytes[34];
            const max_keycode = bytes[35];

            // Skip vendor string (padded to 4) and FORMAT records (8 bytes each).
            const vendor_skip = pad4(@as(usize, vendor_len));
            const formats_skip = @as(usize, pixmap_formats_len) * 8;
            const screen_offset = 40 + vendor_skip + formats_skip;

            if (roots_len == 0) return error.MalformedSetup;

            // First SCREEN layout (offsets from screen start):
            //   0  root: u32
            //   4  default_colormap: u32
            //   8  white_pixel: u32
            //  12  black_pixel: u32
            //  16  current_input_masks: u32
            //  20  width_px: u16
            //  22  height_px: u16
            //  24  width_mm: u16
            //  26  height_mm: u16
            //  28  min_installed_maps: u16
            //  30  max_installed_maps: u16
            //  32  root_visual: u32     <- last field we need
            //  36  ...
            if (bytes.len < screen_offset + 36) return error.MalformedSetup;

            const root = std.mem.readInt(u32, bytes[screen_offset..][0..4], native_endian);
            const root_visual = std.mem.readInt(u32, bytes[screen_offset + 32 ..][0..4], native_endian);

            return Setup{
                .protocol_major = protocol_major,
                .protocol_minor = protocol_minor,
                .release_number = release_number,
                .resource_id_base = resource_id_base,
                .resource_id_mask = resource_id_mask,
                .min_keycode = min_keycode,
                .max_keycode = max_keycode,
                .roots_len = roots_len,
                .root = root,
                .root_visual = root_visual,
                .raw = bytes,
                .vendor_len = vendor_len,
                .pixmap_formats_len = pixmap_formats_len,
                .default_screen = 0,
            };
        },
        else => return error.MalformedSetup,
    }
}

pub const SetupRequest = struct {
    byte_order: u8,
    protocol_major: u16,
    protocol_minor: u16,
    auth_name: []const u8, // borrows `bytes`
    auth_data: []const u8, // borrows `bytes`
};

pub const ParseSetupRequestError = error{MalformedSetupRequest};

/// Parse a client SetupRequest (the inverse of encodeSetupRequest). The auth
/// slices borrow `bytes`, which must outlive the returned struct.
pub fn parseSetupRequest(bytes: []const u8) ParseSetupRequestError!SetupRequest {
    if (bytes.len < 12) return error.MalformedSetupRequest;
    const order = bytes[0];
    if (order != 0x6c and order != 0x42) return error.MalformedSetupRequest;
    const req_endian: std.builtin.Endian = if (order == 0x42) .big else .little;
    const major = std.mem.readInt(u16, bytes[2..4], req_endian);
    const minor = std.mem.readInt(u16, bytes[4..6], req_endian);
    const name_len = std.mem.readInt(u16, bytes[6..8], req_endian);
    const data_len = std.mem.readInt(u16, bytes[8..10], req_endian);
    var off: usize = 12;
    const name_end = off + name_len;
    if (name_end > bytes.len) return error.MalformedSetupRequest;
    const name = bytes[off..name_end];
    off = name_end + (pad4(name_len) - name_len);
    const data_end = off + data_len;
    if (data_end > bytes.len) return error.MalformedSetupRequest;
    const data = bytes[off..data_end];
    return .{ .byte_order = order, .protocol_major = major, .protocol_minor = minor, .auth_name = name, .auth_data = data };
}

pub const SetupReplyParams = struct {
    resource_id_base: u32,
    resource_id_mask: u32,
    vendor: []const u8,
    min_keycode: u8,
    max_keycode: u8,
    root: u32,
    root_visual: u32,
    width_px: u16,
    height_px: u16,
    root_depth: u8,
    visual_id: u32,
    /// The colormap id this screen's setup advertises (SP-Server-4s: the
    /// server pre-registers a real resource under this id at Display init, so
    /// the wire value here must match, e.g. server_state.Display.default_colormap).
    default_colormap: u32 = 0,
    white_pixel: u32 = 0xffffff,
    black_pixel: u32 = 0,
    visual_class: u8 = 4, // TrueColor
    bits_per_rgb: u8 = 8,
    red_mask: u32 = 0xff0000,
    green_mask: u32 = 0x00ff00,
    blue_mask: u32 = 0x0000ff,
    format_bpp: u8 = 32,
    format_scanline_pad: u8 = 32,
    protocol_major: u16 = 11,
    protocol_minor: u16 = 0,
    release_number: u32 = 0,
    max_request_length: u16 = 65535,
};

pub const EncodeSetupReplyError = error{WriteFailed};

/// Encode a status-success connection SetupReply advertising ONE screen with
/// ONE depth holding ONE visual, plus ONE pixmap format. Byte layout matches
/// exactly what the client's parseSetupReply + setup iterators expect.
pub fn encodeSetupReply(w: *std.Io.Writer, endian: std.builtin.Endian, p: SetupReplyParams) EncodeSetupReplyError!void {
    const vendor_pad = pad4(p.vendor.len) - p.vendor.len;
    // additional data = everything after byte 8: bytes 8..40 (=32) + vendor(padded) + 1 format(8) + 1 screen(40 fixed + 1 depth(8) + 1 visual(24) = 72).
    const additional = 32 + pad4(p.vendor.len) + 8 + 72;
    var hdr: [40]u8 = std.mem.zeroes([40]u8);
    hdr[0] = 1; // success
    std.mem.writeInt(u16, hdr[2..4], p.protocol_major, endian);
    std.mem.writeInt(u16, hdr[4..6], p.protocol_minor, endian);
    std.mem.writeInt(u16, hdr[6..8], @intCast(additional / 4), endian);
    std.mem.writeInt(u32, hdr[8..12], p.release_number, endian);
    std.mem.writeInt(u32, hdr[12..16], p.resource_id_base, endian);
    std.mem.writeInt(u32, hdr[16..20], p.resource_id_mask, endian);
    // 20..24 motion buffer = 0
    std.mem.writeInt(u16, hdr[24..26], @intCast(p.vendor.len), endian);
    std.mem.writeInt(u16, hdr[26..28], p.max_request_length, endian);
    hdr[28] = 1; // roots_len
    hdr[29] = 1; // pixmap_formats_len
    // 30 image_byte_order, 31 bitmap bit order, 32 scanline unit, 33 scanline pad = 0/defaults
    hdr[34] = p.min_keycode;
    hdr[35] = p.max_keycode;
    w.writeAll(&hdr) catch return error.WriteFailed;
    const zeros = [4]u8{ 0, 0, 0, 0 };
    w.writeAll(p.vendor) catch return error.WriteFailed;
    w.writeAll(zeros[0..vendor_pad]) catch return error.WriteFailed;
    // FORMAT (8 bytes)
    var fmt: [8]u8 = std.mem.zeroes([8]u8);
    fmt[0] = p.root_depth;
    fmt[1] = p.format_bpp;
    fmt[2] = p.format_scanline_pad;
    w.writeAll(&fmt) catch return error.WriteFailed;
    // SCREEN (40 bytes)
    var scr: [40]u8 = std.mem.zeroes([40]u8);
    std.mem.writeInt(u32, scr[0..4], p.root, endian);
    std.mem.writeInt(u32, scr[4..8], p.default_colormap, endian);
    std.mem.writeInt(u32, scr[8..12], p.white_pixel, endian);
    std.mem.writeInt(u32, scr[12..16], p.black_pixel, endian);
    // 16..20 current_input_masks = 0
    std.mem.writeInt(u16, scr[20..22], p.width_px, endian);
    std.mem.writeInt(u16, scr[22..24], p.height_px, endian);
    // 24..28 width_mm/height_mm = 0
    std.mem.writeInt(u16, scr[28..30], 1, endian); // min_installed_maps
    std.mem.writeInt(u16, scr[30..32], 1, endian); // max_installed_maps
    std.mem.writeInt(u32, scr[32..36], p.root_visual, endian);
    // 36 backing_stores, 37 save_unders = 0
    scr[38] = p.root_depth;
    scr[39] = 1; // allowed_depths_len
    w.writeAll(&scr) catch return error.WriteFailed;
    // DEPTH (8 bytes)
    var dep: [8]u8 = std.mem.zeroes([8]u8);
    dep[0] = p.root_depth;
    std.mem.writeInt(u16, dep[2..4], 1, endian); // visuals_len
    w.writeAll(&dep) catch return error.WriteFailed;
    // VISUALTYPE (24 bytes)
    var vis: [24]u8 = std.mem.zeroes([24]u8);
    std.mem.writeInt(u32, vis[0..4], p.visual_id, endian);
    vis[4] = p.visual_class;
    vis[5] = p.bits_per_rgb;
    std.mem.writeInt(u16, vis[6..8], 256, endian); // colormap_entries
    std.mem.writeInt(u32, vis[8..12], p.red_mask, endian);
    std.mem.writeInt(u32, vis[12..16], p.green_mask, endian);
    std.mem.writeInt(u32, vis[16..20], p.blue_mask, endian);
    w.writeAll(&vis) catch return error.WriteFailed;
}

test "encodeSetupRequest byte layout and padding" {
    const auth_name = "MIT-MAGIC-COOKIE-1"; // 18 bytes -> padded to 20
    const auth_data = [_]u8{0xde} ** 16; // 16 bytes -> no extra pad

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try encodeSetupRequest(&aw.writer, auth_name, &auth_data);
    const buf = aw.writer.buffered();

    // Fixed header: 12 bytes; auth_name padded: 20; auth_data padded: 16 -> total 48.
    try std.testing.expectEqual(@as(usize, 48), buf.len);
    // Total length must be a multiple of 4.
    try std.testing.expectEqual(@as(usize, 0), buf.len % 4);

    // byte_order sentinel.
    const expected_order: u8 = if (native_endian == .little) 0x6c else 0x42;
    try std.testing.expectEqual(expected_order, buf[0]);
    // pad byte is 0.
    try std.testing.expectEqual(@as(u8, 0), buf[1]);

    // protocol_major = 11 in native endian.
    const major = std.mem.readInt(u16, buf[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 11), major);

    // auth_name_len = 18.
    const name_len = std.mem.readInt(u16, buf[6..8], native_endian);
    try std.testing.expectEqual(@as(u16, 18), name_len);

    // auth_data_len = 16.
    const data_len = std.mem.readInt(u16, buf[8..10], native_endian);
    try std.testing.expectEqual(@as(u16, 16), data_len);

    // auth_name bytes start at offset 12.
    try std.testing.expectEqualSlices(u8, auth_name, buf[12..30]);
    // Padding bytes at 30-31 must be zero.
    try std.testing.expectEqual(@as(u8, 0), buf[30]);
    try std.testing.expectEqual(@as(u8, 0), buf[31]);

    // auth_data at offset 32 (12 + 20).
    try std.testing.expectEqualSlices(u8, &auth_data, buf[32..48]);
}

test "parseSetupReply success extracts fields" {
    // Build a minimal but structurally valid Success reply in native byte order.
    // Fixed header: 40 bytes, vendor: 0, pixmap_formats: 0, one SCREEN: 36+ bytes.
    var buf = std.mem.zeroes([80]u8);

    buf[0] = 1; // status = Success
    buf[1] = 0; // unused
    std.mem.writeInt(u16, buf[2..4], 11, native_endian); // protocol_major
    std.mem.writeInt(u16, buf[4..6], 0, native_endian); // protocol_minor
    std.mem.writeInt(u16, buf[6..8], 18, native_endian); // length (4-byte units)
    std.mem.writeInt(u32, buf[8..12], 12007000, native_endian); // release_number
    std.mem.writeInt(u32, buf[12..16], 0x04200000, native_endian); // resource_id_base
    std.mem.writeInt(u32, buf[16..20], 0x001fffff, native_endian); // resource_id_mask
    std.mem.writeInt(u32, buf[20..24], 256, native_endian); // motion_buffer_size
    std.mem.writeInt(u16, buf[24..26], 0, native_endian); // vendor_len = 0
    std.mem.writeInt(u16, buf[26..28], 65535, native_endian); // max_request_length
    buf[28] = 1; // roots_len = 1
    buf[29] = 0; // pixmap_formats_len = 0
    buf[30] = if (native_endian == .little) 0 else 1; // image_byte_order
    buf[31] = 0; // bitmap_format_bit_order
    buf[32] = 32; // bitmap_format_scanline_unit
    buf[33] = 32; // bitmap_format_scanline_pad
    buf[34] = 8; // min_keycode
    buf[35] = 255; // max_keycode
    // buf[36..40] = pad (already zero)

    // SCREEN at offset 40 (vendor_skip=0, formats_skip=0).
    std.mem.writeInt(u32, buf[40..44], 0x0000012a, native_endian); // root
    std.mem.writeInt(u32, buf[44..48], 0x00000025, native_endian); // default_colormap
    std.mem.writeInt(u32, buf[48..52], 0x00ffffff, native_endian); // white_pixel
    // black_pixel, current_input_masks: already zero
    std.mem.writeInt(u16, buf[60..62], 1920, native_endian); // width_px
    std.mem.writeInt(u16, buf[62..64], 1080, native_endian); // height_px
    std.mem.writeInt(u16, buf[64..66], 527, native_endian); // width_mm
    std.mem.writeInt(u16, buf[66..68], 296, native_endian); // height_mm
    std.mem.writeInt(u16, buf[68..70], 1, native_endian); // min_installed_maps
    std.mem.writeInt(u16, buf[70..72], 1, native_endian); // max_installed_maps
    std.mem.writeInt(u32, buf[72..76], 0x00000021, native_endian); // root_visual
    buf[78] = 24; // root_depth

    const setup = try parseSetupReply(&buf);

    try std.testing.expectEqual(@as(u16, 11), setup.protocol_major);
    try std.testing.expectEqual(@as(u32, 0x04200000), setup.resource_id_base);
    try std.testing.expectEqual(@as(u32, 0x001fffff), setup.resource_id_mask);
    try std.testing.expectEqual(@as(u8, 8), setup.min_keycode);
    try std.testing.expectEqual(@as(u8, 255), setup.max_keycode);
    try std.testing.expectEqual(@as(u8, 1), setup.roots_len);
    try std.testing.expectEqual(@as(u32, 0x0000012a), setup.root);
    try std.testing.expectEqual(@as(u32, 0x00000021), setup.root_visual);
}

test "parseSetupReply exposes screens, depths, visuals, and formats" {
    // std.ArrayList(u8) has no `.writer` in this Zig 0.16 snapshot, and
    // std.Io.Writer has no writeInt, so build the bytes with
    // std.Io.Writer.Allocating (as the encodeSetupRequest test above does)
    // plus a tiny local int-writing helper.
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const writeInt = struct {
        fn call(ww: *std.Io.Writer, comptime T: type, value: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, value, native_endian);
            try ww.writeAll(&b);
        }
    }.call;

    // Fixed 40-byte header.
    try w.writeByte(1); // success
    try w.writeByte(0); // pad
    try writeInt(w, u16, 11); // proto major
    try writeInt(w, u16, 0); // proto minor
    try writeInt(w, u16, 0); // additional-data length (unused here)
    try writeInt(w, u32, 0); // release
    try writeInt(w, u32, 0x04200000); // rid base
    try writeInt(w, u32, 0x001fffff); // rid mask
    try writeInt(w, u32, 0); // motion buffer
    try writeInt(w, u16, 3); // vendor_len = 3
    try writeInt(w, u16, 0); // max request len
    try w.writeByte(1); // roots_len = 1
    try w.writeByte(1); // pixmap_formats_len = 1
    try w.writeByte(0); // image byte order
    try w.writeByte(0); // bitmap bit order
    try w.writeByte(0); // scanline unit
    try w.writeByte(0); // scanline pad
    try w.writeByte(8); // min keycode
    try w.writeByte(255); // max keycode
    try writeInt(w, u32, 0); // pad to 40

    // vendor "Zig" padded to 4.
    try w.writeAll("Zig\x00");

    // 1 FORMAT (8 bytes): depth=24, bpp=32, scanline_pad=32, +5 pad.
    try w.writeByte(24);
    try w.writeByte(32);
    try w.writeByte(32);
    try w.writeAll(&[_]u8{ 0, 0, 0, 0, 0 });

    // 1 SCREEN (40 bytes fixed) with allowed_depths_len=1.
    try writeInt(w, u32, 0x111); // root
    try writeInt(w, u32, 0); // default_colormap
    try writeInt(w, u32, 0xffffff); // white
    try writeInt(w, u32, 0); // black
    try writeInt(w, u32, 0); // current_input_masks
    try writeInt(w, u16, 640); // width_px
    try writeInt(w, u16, 480); // height_px
    try writeInt(w, u16, 0); // width_mm
    try writeInt(w, u16, 0); // height_mm
    try writeInt(w, u16, 1); // min_maps
    try writeInt(w, u16, 1); // max_maps
    try writeInt(w, u32, 0x21); // root_visual
    try w.writeByte(0); // backing_stores
    try w.writeByte(0); // save_unders
    try w.writeByte(24); // root_depth
    try w.writeByte(1); // allowed_depths_len = 1

    // 1 DEPTH (8 bytes) with visuals_len=2.
    try w.writeByte(24); // depth
    try w.writeByte(0); // pad
    try writeInt(w, u16, 2); // visuals_len = 2
    try writeInt(w, u32, 0); // pad

    // 2 VISUALTYPE (24 bytes each).
    inline for ([_]u32{ 0x21, 0x22 }) |vid| {
        try writeInt(w, u32, vid); // visual_id
        try w.writeByte(4); // class = TrueColor
        try w.writeByte(8); // bits_per_rgb
        try writeInt(w, u16, 256); // colormap_entries
        try writeInt(w, u32, 0xff0000); // red_mask
        try writeInt(w, u32, 0x00ff00); // green_mask
        try writeInt(w, u32, 0x0000ff); // blue_mask
        try writeInt(w, u32, 0); // pad
    }

    const setup = try parseSetupReply(w.buffered());
    try std.testing.expectEqualStrings("Zig", setup.vendor());

    var fmts = setup.formats();
    try std.testing.expectEqual(@as(usize, 1), fmts.len());
    const f0 = fmts.next().?;
    try std.testing.expectEqual(@as(u8, 24), f0.depth);
    try std.testing.expectEqual(@as(u8, 32), f0.bits_per_pixel);

    var screens = setup.screens();
    try std.testing.expectEqual(@as(usize, 1), screens.len());
    const s0 = screens.next().?;
    try std.testing.expectEqual(@as(u32, 0x111), s0.root);
    try std.testing.expectEqual(@as(u32, 0x21), s0.root_visual);
    try std.testing.expectEqual(@as(u8, 1), s0.allowed_depths_len);

    var depths = s0.depths();
    try std.testing.expectEqual(@as(usize, 1), depths.len());
    const d0 = depths.next().?;
    try std.testing.expectEqual(@as(u8, 24), d0.depth);
    try std.testing.expectEqual(@as(u16, 2), d0.visuals_len);

    var visuals = d0.visuals();
    try std.testing.expectEqual(@as(usize, 2), visuals.len());
    const v0 = visuals.next().?;
    try std.testing.expectEqual(@as(u32, 0x21), v0.visual_id);
    try std.testing.expectEqual(@as(u8, 4), v0.class);
    try std.testing.expectEqual(@as(u32, 0xff0000), v0.red_mask);
    const v1 = visuals.next().?;
    try std.testing.expectEqual(@as(u32, 0x22), v1.visual_id);
    try std.testing.expect(visuals.next() == null);
}

/// Encode an X11 request to w.
///
/// Wire layout:
///   u8  major_opcode
///   u8  minor_or_data
///   u16 length  (total request size in 4-byte units, including this 4-byte header)
///   [extra.len]u8  extra data
///   [pad]u8  zero-padding to next 4-byte boundary
pub fn encodeRequest(
    w: *std.Io.Writer,
    major: u8,
    minor_or_data: u8,
    extra: []const u8,
) EncodeRequestError!void {
    const total = 4 + pad4(extra.len);
    if (total / 4 > std.math.maxInt(u16)) return error.RequestTooLong;
    const length: u16 = @intCast(total / 4);

    var u16buf: [2]u8 = undefined;
    try w.writeAll(&[_]u8{ major, minor_or_data });
    std.mem.writeInt(u16, &u16buf, length, native_endian);
    try w.writeAll(&u16buf);
    try w.writeAll(extra);
    const pad_len = pad4(extra.len) - extra.len;
    const zeros = [3]u8{ 0, 0, 0 };
    try w.writeAll(zeros[0..pad_len]);
}

pub const ResponseType = enum { err, reply, event };

pub fn responseType(first: u8) ResponseType {
    return switch (first) {
        0 => .err,
        1 => .reply,
        else => .event,
    };
}

pub const ReplyHeader = struct { sequence: u16, length: u32 };

pub const ReplyHeaderError = error{ShortReply};

pub fn parseReplyHeader(bytes: []const u8) ReplyHeaderError!ReplyHeader {
    if (bytes.len < 8) return error.ShortReply;
    const sequence = std.mem.readInt(u16, bytes[2..4], native_endian);
    const length = std.mem.readInt(u32, bytes[4..8], native_endian);
    return ReplyHeader{ .sequence = sequence, .length = length };
}

pub const XError = struct {
    code: u8,
    sequence: u16,
    bad_value: u32,
    minor_opcode: u16,
    major_opcode: u8,
};

pub const XErrorParseError = error{ShortError};

pub fn parseError(bytes: []const u8) XErrorParseError!XError {
    if (bytes.len < 32) return error.ShortError;
    return XError{
        .code = bytes[1],
        .sequence = std.mem.readInt(u16, bytes[2..4], native_endian),
        .bad_value = std.mem.readInt(u32, bytes[4..8], native_endian),
        .minor_opcode = std.mem.readInt(u16, bytes[8..10], native_endian),
        .major_opcode = bytes[10],
    };
}

pub fn eventCode(bytes: []const u8) u8 {
    return bytes[0] & 0x7f;
}

test "encodeRequest aligned extra" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const extra = [_]u8{0xAA} ** 8;
    try encodeRequest(&aw.writer, 98, 0, &extra);
    const buf = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 12), buf.len);
    try std.testing.expectEqual(@as(usize, 0), buf.len % 4);
    try std.testing.expectEqual(@as(u8, 98), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1]);
    const length = std.mem.readInt(u16, buf[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 3), length);
}

test "encodeRequest unaligned extra gets padded" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const extra = [_]u8{0xBB} ** 5;
    try encodeRequest(&aw.writer, 98, 0, &extra);
    const buf = aw.writer.buffered();
    // 5 bytes padded to 8, plus 4-byte header = 12.
    try std.testing.expectEqual(@as(usize, 12), buf.len);
    try std.testing.expectEqual(@as(usize, 0), buf.len % 4);
    const length = std.mem.readInt(u16, buf[2..4], native_endian);
    try std.testing.expectEqual(@as(u16, 3), length);
    // Pad bytes at positions 9, 10, 11 must be zero.
    try std.testing.expectEqual(@as(u8, 0), buf[9]);
    try std.testing.expectEqual(@as(u8, 0), buf[10]);
    try std.testing.expectEqual(@as(u8, 0), buf[11]);
}

test "parseReplyHeader canned bytes" {
    var buf = std.mem.zeroes([32]u8);
    buf[0] = 1; // reply marker
    std.mem.writeInt(u16, buf[2..4], 0x0042, native_endian);
    std.mem.writeInt(u32, buf[4..8], 2, native_endian);
    const hdr = try parseReplyHeader(&buf);
    try std.testing.expectEqual(@as(u16, 0x0042), hdr.sequence);
    try std.testing.expectEqual(@as(u32, 2), hdr.length);
}

test "parseReplyHeader short buffer" {
    const buf = [_]u8{1} ** 7;
    try std.testing.expectError(error.ShortReply, parseReplyHeader(&buf));
}

test "parseError canned bytes" {
    var buf = std.mem.zeroes([32]u8);
    buf[0] = 0; // error marker
    buf[1] = 3; // code = BadWindow
    std.mem.writeInt(u16, buf[2..4], 5, native_endian); // sequence
    std.mem.writeInt(u32, buf[4..8], 0xdeadbeef, native_endian); // bad_value
    std.mem.writeInt(u16, buf[8..10], 0, native_endian); // minor_opcode
    buf[10] = 98; // major_opcode
    const err = try parseError(&buf);
    try std.testing.expectEqual(@as(u8, 3), err.code);
    try std.testing.expectEqual(@as(u16, 5), err.sequence);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), err.bad_value);
    try std.testing.expectEqual(@as(u8, 98), err.major_opcode);
}

test "parseError short buffer" {
    const buf = [_]u8{0} ** 31;
    try std.testing.expectError(error.ShortError, parseError(&buf));
}

test "responseType classification" {
    try std.testing.expectEqual(ResponseType.err, responseType(0));
    try std.testing.expectEqual(ResponseType.reply, responseType(1));
    try std.testing.expectEqual(ResponseType.event, responseType(2));
    try std.testing.expectEqual(ResponseType.event, responseType(255));
}

test "eventCode masks high bit" {
    try std.testing.expectEqual(@as(u8, 0x02), eventCode(&[_]u8{0x82}));
    try std.testing.expectEqual(@as(u8, 0x15), eventCode(&[_]u8{0x95}));
    try std.testing.expectEqual(@as(u8, 0x00), eventCode(&[_]u8{0x80}));
}

test "parseSetupReply failed status" {
    var buf = std.mem.zeroes([16]u8);
    buf[0] = 0; // status = Failed
    buf[1] = 5; // reason_len = 5
    std.mem.writeInt(u16, buf[2..4], 11, native_endian); // protocol_major
    std.mem.writeInt(u16, buf[4..6], 0, native_endian); // protocol_minor
    std.mem.writeInt(u16, buf[6..8], 1, native_endian); // length (4-byte units)
    buf[8] = 'S';
    buf[9] = 'o';
    buf[10] = 'r';
    buf[11] = 'r';
    buf[12] = 'y';

    try std.testing.expectError(error.SetupFailed, parseSetupReply(&buf));
}

test "encodeRequest then read back length" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const extra = [_]u8{0xCC} ** 3; // 3 -> padded to 4, +4 header = 8 bytes = 2 units
    try encodeRequest(&aw.writer, 1, 7, &extra);
    const buf = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 8), buf.len);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
    try std.testing.expectEqual(@as(u8, 7), buf[1]);
    const len = std.mem.readInt(u16, buf[2..4], builtin.cpu.arch.endian());
    try std.testing.expectEqual(@as(u16, 2), len);
}

test "setup request round-trips: client encode -> server parse" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try encodeSetupRequest(&aw.writer, "MIT-MAGIC-COOKIE-1", &[_]u8{ 1, 2, 3, 4 });
    const buf = aw.writer.buffered();
    const req = try parseSetupRequest(buf);
    const expect_order: u8 = if (native_endian == .little) 0x6c else 0x42;
    try std.testing.expectEqual(expect_order, req.byte_order);
    try std.testing.expectEqual(@as(u16, 11), req.protocol_major);
    try std.testing.expectEqualStrings("MIT-MAGIC-COOKIE-1", req.auth_name);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, req.auth_data);
}

test "parseSetupRequest reads a big-endian client's lengths" {
    // byte_order 0x42 = big; major/minor/name_len/data_len are big-endian.
    var buf: [12 + 8]u8 = std.mem.zeroes([12 + 8]u8);
    buf[0] = 0x42; // big
    std.mem.writeInt(u16, buf[2..4], 11, .big); // major
    std.mem.writeInt(u16, buf[6..8], 4, .big); // name_len = 4
    std.mem.writeInt(u16, buf[8..10], 0, .big); // data_len = 0
    @memcpy(buf[12..16], "AUTH");
    const req = try parseSetupRequest(&buf);
    try std.testing.expectEqual(@as(u8, 0x42), req.byte_order);
    try std.testing.expectEqual(@as(u16, 11), req.protocol_major);
    try std.testing.expectEqualStrings("AUTH", req.auth_name);
}

test "encodeSetupReply writes header fields in the given endian" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeSetupReply(&w, .big, .{
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
    });
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 1), bytes[0]); // success
    try std.testing.expectEqual(@as(u32, 0x00400000), std.mem.readInt(u32, bytes[12..16], .big)); // rid base big-endian
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, bytes[2..4], .big)); // proto major big-endian
}

test "setup reply round-trips: server encode -> client parse + iterators" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try encodeSetupReply(&aw.writer, native_endian, .{
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
    });
    const buf = aw.writer.buffered();
    const setup = try parseSetupReply(buf);
    try std.testing.expectEqual(@as(u32, 0x00400000), setup.resource_id_base);
    try std.testing.expectEqual(@as(u32, 0x12a), setup.root);
    try std.testing.expectEqual(@as(u32, 0x21), setup.root_visual);
    try std.testing.expectEqualStrings("x11.zig", setup.vendor());
    try std.testing.expectEqual(@as(usize, 1), setup.screens().len());
    var screens = setup.screens();
    const s0 = screens.next().?;
    try std.testing.expectEqual(@as(u8, 24), s0.root_depth);
    var depths = s0.depths();
    const d0 = depths.next().?;
    try std.testing.expectEqual(@as(u16, 1), d0.visuals_len);
    var visuals = d0.visuals();
    const v0 = visuals.next().?;
    try std.testing.expectEqual(@as(u32, 0x21), v0.visual_id);
    try std.testing.expectEqual(@as(u8, 4), v0.class);
    var fmts = setup.formats();
    try std.testing.expectEqual(@as(usize, 1), fmts.len());
    const f0 = fmts.next().?;
    try std.testing.expectEqual(@as(u8, 24), f0.depth);
    try std.testing.expectEqual(@as(u8, 32), f0.bits_per_pixel);
}
