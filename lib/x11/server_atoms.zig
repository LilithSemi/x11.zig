//! The server's global atom table: a shared name<->id map. Atoms are global
//! across all clients (interning the same name always yields the same id), with
//! ids 1..68 reserved for the X predefined atoms. Pure + xproto-free so it
//! unit-tests without a socket and does not import the generated xproto module.
const std = @import("std");

/// The 68 X predefined atoms in id order (id == index + 1). Stable protocol
/// constants; hardcoded here because this module is xproto-free (it cannot read
/// the generated Atom enum).
const predefined = [_][]const u8{
    "PRIMARY",          "SECONDARY",         "ARC",                "ATOM",
    "BITMAP",           "CARDINAL",          "COLORMAP",           "CURSOR",
    "CUT_BUFFER0",      "CUT_BUFFER1",       "CUT_BUFFER2",        "CUT_BUFFER3",
    "CUT_BUFFER4",      "CUT_BUFFER5",       "CUT_BUFFER6",        "CUT_BUFFER7",
    "DRAWABLE",         "FONT",              "INTEGER",            "PIXMAP",
    "POINT",            "RECTANGLE",         "RESOURCE_MANAGER",   "RGB_COLOR_MAP",
    "RGB_BEST_MAP",     "RGB_BLUE_MAP",      "RGB_DEFAULT_MAP",    "RGB_GRAY_MAP",
    "RGB_GREEN_MAP",    "RGB_RED_MAP",       "STRING",             "VISUALID",
    "WINDOW",           "WM_COMMAND",        "WM_HINTS",           "WM_CLIENT_MACHINE",
    "WM_ICON_NAME",     "WM_ICON_SIZE",      "WM_NAME",            "WM_NORMAL_HINTS",
    "WM_SIZE_HINTS",    "WM_ZOOM_HINTS",     "MIN_SPACE",          "NORM_SPACE",
    "MAX_SPACE",        "END_SPACE",         "SUPERSCRIPT_X",      "SUPERSCRIPT_Y",
    "SUBSCRIPT_X",      "SUBSCRIPT_Y",       "UNDERLINE_POSITION", "UNDERLINE_THICKNESS",
    "STRIKEOUT_ASCENT", "STRIKEOUT_DESCENT", "ITALIC_ANGLE",       "X_HEIGHT",
    "QUAD_WIDTH",       "WEIGHT",            "POINT_SIZE",         "RESOLUTION",
    "COPYRIGHT",        "NOTICE",            "FONT_NAME",          "FAMILY_NAME",
    "FULL_NAME",        "CAP_HEIGHT",        "WM_CLASS",           "WM_TRANSIENT_FOR",
};

pub const predefined_count: u32 = predefined.len;

pub const AtomTable = struct {
    /// name -> id. Keys are owned (duped) so deinit frees uniformly.
    by_name: std.StringHashMapUnmanaged(u32) = .{},
    /// id -> name; index is id-1. Owns the duped name strings.
    by_id: std.ArrayListUnmanaged([]u8) = .empty,
    /// Cap on total interned atoms (bounds memory against a client that interns
    /// unbounded distinct names). A field so tests can lower it.
    max_atoms: u32 = 1 << 20,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!AtomTable {
        var self: AtomTable = .{};
        errdefer self.deinit(gpa);
        for (predefined) |name| _ = self.add(gpa, name) catch |e| switch (e) {
            error.TooManyAtoms => unreachable, // 68 predefined atoms is far under any max_atoms
            error.OutOfMemory => return error.OutOfMemory,
        };
        return self;
    }

    pub fn deinit(self: *AtomTable, gpa: std.mem.Allocator) void {
        for (self.by_id.items) |n| gpa.free(n);
        self.by_id.deinit(gpa);
        self.by_name.deinit(gpa);
        self.* = undefined;
    }

    /// Dup `name`, assign it the next id, and record both directions. The duped
    /// slice is owned by by_id; by_name keys borrow it (same lifetime).
    fn add(self: *AtomTable, gpa: std.mem.Allocator, name: []const u8) (error{TooManyAtoms} || std.mem.Allocator.Error)!u32 {
        if (self.by_id.items.len >= self.max_atoms) return error.TooManyAtoms;
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.by_id.append(gpa, owned);
        errdefer _ = self.by_id.pop();
        const id: u32 = @intCast(self.by_id.items.len); // 1-based
        try self.by_name.put(gpa, owned, id);
        return id;
    }

    /// Intern `name`: existing -> its id; missing + only_if_exists -> 0 (None);
    /// missing otherwise -> a fresh id.
    pub fn intern(self: *AtomTable, gpa: std.mem.Allocator, name: []const u8, only_if_exists: bool) (error{TooManyAtoms} || std.mem.Allocator.Error)!u32 {
        if (self.by_name.get(name)) |id| return id;
        if (only_if_exists) return 0;
        return self.add(gpa, name);
    }

    /// The name for a valid atom id (1..count), else null.
    pub fn nameOf(self: *const AtomTable, id: u32) ?[]const u8 {
        if (id == 0 or id > self.by_id.items.len) return null;
        return self.by_id.items[id - 1];
    }
};

test "predefined atoms, interning, only_if_exists, nameOf" {
    const gpa = std.testing.allocator;
    var t = try AtomTable.init(gpa);
    defer t.deinit(gpa);
    // Predefined ids are fixed.
    try std.testing.expectEqual(@as(u32, 39), try t.intern(gpa, "WM_NAME", false));
    try std.testing.expectEqual(@as(u32, 1), try t.intern(gpa, "PRIMARY", false));
    try std.testing.expectEqualStrings("WM_NAME", t.nameOf(39).?);
    try std.testing.expectEqualStrings("STRING", t.nameOf(31).?);
    // A new name gets the next dynamic id (69), and re-interning is stable.
    const a = try t.intern(gpa, "MY_ATOM", false);
    try std.testing.expectEqual(@as(u32, 69), a);
    try std.testing.expectEqual(a, try t.intern(gpa, "MY_ATOM", false));
    // only_if_exists on a missing name returns None (0), and does NOT create it.
    try std.testing.expectEqual(@as(u32, 0), try t.intern(gpa, "NOPE", true));
    try std.testing.expectEqual(@as(?[]const u8, null), t.nameOf(70)); // not created
    // nameOf out of range -> null.
    try std.testing.expectEqual(@as(?[]const u8, null), t.nameOf(0));
    try std.testing.expectEqual(@as(?[]const u8, null), t.nameOf(9999));
}

test "intern caps the atom table" {
    const gpa = std.testing.allocator;
    var t = try AtomTable.init(gpa);
    defer t.deinit(gpa);
    // Lower the cap to just above the predefined count so one more fits, then not.
    t.max_atoms = predefined_count + 1;
    _ = try t.intern(gpa, "ONE_MORE", false); // ok, reaches the cap
    try std.testing.expectError(error.TooManyAtoms, t.intern(gpa, "TOO_MANY", false));
    // An existing name still interns fine (no new allocation).
    try std.testing.expectEqual(@as(u32, 39), try t.intern(gpa, "WM_NAME", false));
    // only_if_exists on a missing name returns None, not the cap error.
    try std.testing.expectEqual(@as(u32, 0), try t.intern(gpa, "MISSING", true));
}
