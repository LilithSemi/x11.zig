//! An X-agnostic, injectable font backend seam (mirrors render.zig's Renderer
//! seam). x11.zig ships Font8x8Provider (wraps the built-in font8x8 table) as
//! the default; a consumer such as PhantomUI may implement FontProvider to
//! supply real fonts without x11.zig depending on it. Imports only std +
//! font8x8 -- no xproto, no server_state.
const std = @import("std");
const font8x8 = @import("font8x8.zig");

/// An opaque per-open-font handle, defined by the provider.
pub const FontRef = *anyopaque;
/// A glyph's bitmap + layout. bits: 1-bpp, row 0 top, LSB=leftmost column
/// (the render.drawGlyph convention). advance = pen step after the glyph.
pub const Glyph = struct { bits: []const u8, width: u8, height: u8, advance: i16 };
pub const FontMetrics = struct {
    ascent: i16,
    descent: i16,
    min_char: u16,
    max_char: u16,
    default_char: u16,
    min_width: i16,
    max_width: i16,
};

/// Injectable font backend (allocator-style ptr+vtable). X-agnostic: names,
/// metrics, glyph bitmaps. A consumer (e.g. PhantomUI) implements this to supply
/// real fonts; x11.zig ships Font8x8Provider as the default.
pub const FontProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        openFont: *const fn (*anyopaque, name: []const u8) ?FontRef,
        closeFont: *const fn (*anyopaque, FontRef) void,
        metrics: *const fn (*anyopaque, FontRef) FontMetrics,
        glyph: *const fn (*anyopaque, FontRef, char: u32) Glyph,
        listNames: *const fn (*anyopaque, pattern: []const u8) []const []const u8,
    };
    pub fn openFont(self: FontProvider, name: []const u8) ?FontRef {
        return self.vtable.openFont(self.ptr, name);
    }
    pub fn closeFont(self: FontProvider, ref: FontRef) void {
        self.vtable.closeFont(self.ptr, ref);
    }
    pub fn metrics(self: FontProvider, ref: FontRef) FontMetrics {
        return self.vtable.metrics(self.ptr, ref);
    }
    pub fn glyph(self: FontProvider, ref: FontRef, char: u32) Glyph {
        return self.vtable.glyph(self.ptr, ref, char);
    }
    pub fn listNames(self: FontProvider, pattern: []const u8) []const []const u8 {
        return self.vtable.listNames(self.ptr, pattern);
    }
};

/// The default provider: the one built-in 8x8 monospace font (font8x8).
/// Preserves 4i behavior exactly. Lenient name matching (any name -> the font).
pub const Font8x8Provider = struct {
    marker: u8 = 0, // gives openFont a stable non-null FontRef to return

    const names_list = [_][]const u8{"fixed"};

    pub fn provider(self: *Font8x8Provider) FontProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: FontProvider.VTable = .{
        .openFont = openFont,
        .closeFont = closeFont,
        .metrics = metrics,
        .glyph = glyph,
        .listNames = listNames,
    };
    fn openFont(ptr: *anyopaque, name: []const u8) ?FontRef {
        _ = name; // lenient: every name maps to the one built-in font
        const self: *Font8x8Provider = @ptrCast(@alignCast(ptr));
        return &self.marker;
    }
    fn closeFont(ptr: *anyopaque, ref: FontRef) void {
        _ = ptr;
        _ = ref; // the built-in font is static; nothing to free
    }
    fn metrics(ptr: *anyopaque, ref: FontRef) FontMetrics {
        _ = ptr;
        _ = ref;
        return .{ .ascent = font8x8.ascent, .descent = font8x8.descent, .min_char = font8x8.first_char, .max_char = font8x8.last_char, .default_char = font8x8.first_char, .min_width = font8x8.width, .max_width = font8x8.width };
    }
    fn glyph(ptr: *anyopaque, ref: FontRef, char: u32) Glyph {
        _ = ptr;
        _ = ref;
        return .{ .bits = font8x8.glyphBits(char), .width = font8x8.width, .height = font8x8.height, .advance = font8x8.width };
    }
    fn listNames(ptr: *anyopaque, pattern: []const u8) []const []const u8 {
        _ = ptr;
        _ = pattern; // one built-in; ignore the pattern
        return &names_list;
    }
};

test "Font8x8Provider.openFont accepts any name and returns a stable non-null ref" {
    var impl: Font8x8Provider = .{};
    const fp = impl.provider();
    const ref = fp.openFont("anything");
    try std.testing.expect(ref != null);
}

test "Font8x8Provider.metrics reports the fixed 8x8 font metrics" {
    var impl: Font8x8Provider = .{};
    const fp = impl.provider();
    const ref = fp.openFont("fixed").?;
    const m = fp.metrics(ref);
    try std.testing.expectEqual(@as(i16, 8), m.ascent);
    try std.testing.expectEqual(@as(i16, 8), m.max_width);
    try std.testing.expectEqual(@as(u16, 32), m.min_char);
    try std.testing.expectEqual(@as(u16, 126), m.max_char);
}

test "Font8x8Provider.glyph points into font8x8's stable storage" {
    var impl: Font8x8Provider = .{};
    const fp = impl.provider();
    const ref = fp.openFont("fixed").?;
    const g = fp.glyph(ref, 'A');
    try std.testing.expectEqual(font8x8.glyphBits('A').ptr, g.bits.ptr);
    try std.testing.expectEqual(@as(i16, 8), g.advance);
    try std.testing.expectEqual(@as(u8, 8), g.width);
}

test "Font8x8Provider.glyph out-of-range is all-zero blank" {
    var impl: Font8x8Provider = .{};
    const fp = impl.provider();
    const ref = fp.openFont("fixed").?;
    const g = fp.glyph(ref, 0x2000);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, g.bits);
}

test "Font8x8Provider.listNames returns exactly one name: fixed" {
    var impl: Font8x8Provider = .{};
    const fp = impl.provider();
    const names = fp.listNames("*");
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("fixed", names[0]);
}

test "Font8x8Provider.closeFont does not crash" {
    var impl: Font8x8Provider = .{};
    const fp = impl.provider();
    const ref = fp.openFont("fixed").?;
    fp.closeFont(ref);
}
