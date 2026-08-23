const std = @import("std");
const xcbproto = @import("xcbproto.zig");

/// Resolved holds slices that borrow from data stored inside Registry.
/// Registry must outlive any Resolved value derived from it.
pub const Resolved = union(enum) {
    builtin: []const u8,
    /// bare name as registered; is_xid=true means it is a u32 alias (declared raw),
    /// is_xid=false means it is an aggregate (struct/enum/..., declared PascalCase).
    local: struct { name: []const u8, is_xid: bool },
    imported: struct { module: []const u8, name: []const u8, is_xid: bool },
};

/// Per-protocol entry stored by the registry.
const ProtocolEntry = struct {
    /// owned copies of imported header names (in order)
    imports: [][]const u8,
    /// map of type names defined in this protocol (owned copies of names)
    /// value is true when the type is an XID (u32 alias), false for aggregates (struct/enum/etc.)
    type_names: std.StringHashMapUnmanaged(bool),
    /// Set of names that are true XID types (from <xidtype>/<xidunion> elements only).
    /// Unlike type_names which also marks typedefs as is_xid=true, this set only holds
    /// the genuine 4-byte u32 XID aliases.
    true_xids: std.StringHashMapUnmanaged(void),
    /// Map of typedef newname -> oldname (owned copies of both key and value).
    /// Used by scalarBuiltin to follow typedef chains.
    typedefs: std.StringHashMapUnmanaged([]const u8),
    /// BORROWED slice of struct defs from the Protocol that was registered.
    /// Do NOT free this in deinit - it is owned by the Protocol, which must outlive
    /// the registry (ensured by callers: main.zig keeps protocols alive until generate()).
    structs: []const xcbproto.StructDef = &.{},
    /// BORROWED slice of union defs (same lifetime contract as `structs`).
    unions: []const xcbproto.UnionDef = &.{},
};

const builtin_map = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "CARD8", "u8" },
    .{ "CARD16", "u16" },
    .{ "CARD32", "u32" },
    .{ "CARD64", "u64" },
    .{ "INT8", "i8" },
    .{ "INT16", "i16" },
    .{ "INT32", "i32" },
    .{ "INT64", "i64" },
    .{ "BYTE", "u8" },
    .{ "BOOL", "bool" },
    .{ "CHAR", "u8" },
    .{ "char", "u8" },
    .{ "void", "u8" },
    .{ "float", "f32" },
    .{ "double", "f64" },
});

pub const Registry = struct {
    gpa: std.mem.Allocator,
    /// keyed by owned header name -> ProtocolEntry
    protocols: std.StringHashMapUnmanaged(ProtocolEntry),

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{
            .gpa = gpa,
            .protocols = .{},
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.protocols.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            const pe = entry.value_ptr;
            for (pe.imports) |imp| self.gpa.free(imp);
            self.gpa.free(pe.imports);
            var name_it = pe.type_names.keyIterator();
            while (name_it.next()) |k| self.gpa.free(k.*);
            pe.type_names.deinit(self.gpa);
            var xid_it = pe.true_xids.keyIterator();
            while (xid_it.next()) |k| self.gpa.free(k.*);
            pe.true_xids.deinit(self.gpa);
            var td_it = pe.typedefs.iterator();
            while (td_it.next()) |td| {
                self.gpa.free(td.key_ptr.*);
                self.gpa.free(td.value_ptr.*);
            }
            pe.typedefs.deinit(self.gpa);
        }
        self.protocols.deinit(self.gpa);
    }

    pub fn addProtocol(self: *Registry, p: *const xcbproto.Protocol) std.mem.Allocator.Error!void {
        const header_key = try self.gpa.dupe(u8, p.header);
        errdefer self.gpa.free(header_key);

        var imports = try self.gpa.alloc([]const u8, p.imports.len);
        var imported_count: usize = 0;
        errdefer {
            for (imports[0..imported_count]) |imp| self.gpa.free(imp);
            self.gpa.free(imports);
        }
        for (p.imports, 0..) |imp, i| {
            imports[i] = try self.gpa.dupe(u8, imp);
            imported_count += 1;
        }

        var type_names: std.StringHashMapUnmanaged(bool) = .{};
        errdefer {
            var kit = type_names.keyIterator();
            while (kit.next()) |k| self.gpa.free(k.*);
            type_names.deinit(self.gpa);
        }

        var true_xids: std.StringHashMapUnmanaged(void) = .{};
        errdefer {
            var kit = true_xids.keyIterator();
            while (kit.next()) |k| self.gpa.free(k.*);
            true_xids.deinit(self.gpa);
        }

        var typedefs_map: std.StringHashMapUnmanaged([]const u8) = .{};
        errdefer {
            var kit = typedefs_map.iterator();
            while (kit.next()) |td| {
                self.gpa.free(td.key_ptr.*);
                self.gpa.free(td.value_ptr.*);
            }
            typedefs_map.deinit(self.gpa);
        }

        for (p.enums) |e| {
            const name = try self.gpa.dupe(u8, e.name);
            errdefer self.gpa.free(name);
            try type_names.put(self.gpa, name, false);
        }
        for (p.xids) |x| {
            const name = try self.gpa.dupe(u8, x.name);
            errdefer self.gpa.free(name);
            try type_names.put(self.gpa, name, true);
            // Also record in true_xids for width-resolution (distinct from typedefs).
            const xid_key = try self.gpa.dupe(u8, x.name);
            errdefer self.gpa.free(xid_key);
            try true_xids.put(self.gpa, xid_key, {});
        }
        for (p.structs) |s| {
            const name = try self.gpa.dupe(u8, s.name);
            errdefer self.gpa.free(name);
            try type_names.put(self.gpa, name, false);
        }
        for (p.unions) |u| {
            const name = try self.gpa.dupe(u8, u.name);
            errdefer self.gpa.free(name);
            try type_names.put(self.gpa, name, false);
        }
        // Typedef newnames are emitted raw (as `pub const New = <Old>;`), so
        // treat them like xid aliases (raw name reference, not PascalCase).
        for (p.typedefs) |t| {
            const name = try self.gpa.dupe(u8, t.newname);
            errdefer self.gpa.free(name);
            // put may overwrite a colliding key; free the incoming dup in that case.
            const gop = try type_names.getOrPut(self.gpa, name);
            if (gop.found_existing) self.gpa.free(name);
            gop.value_ptr.* = true;
            // Also store in typedefs_map for scalar-width resolution.
            const td_key = try self.gpa.dupe(u8, t.newname);
            errdefer self.gpa.free(td_key);
            const td_val = try self.gpa.dupe(u8, t.oldname);
            errdefer self.gpa.free(td_val);
            const td_gop = try typedefs_map.getOrPut(self.gpa, td_key);
            if (td_gop.found_existing) {
                self.gpa.free(td_key);
                self.gpa.free(td_val);
            } else {
                td_gop.value_ptr.* = td_val;
            }
        }
        for (p.requests) |r| {
            const name = try self.gpa.dupe(u8, r.name);
            errdefer self.gpa.free(name);
            try type_names.put(self.gpa, name, false);
        }
        for (p.events) |e| {
            const name = try self.gpa.dupe(u8, e.name);
            errdefer self.gpa.free(name);
            try type_names.put(self.gpa, name, false);
        }
        for (p.errors) |e| {
            const name = try self.gpa.dupe(u8, e.name);
            errdefer self.gpa.free(name);
            try type_names.put(self.gpa, name, false);
        }

        const pe: ProtocolEntry = .{
            .imports = imports,
            .type_names = type_names,
            .true_xids = true_xids,
            .typedefs = typedefs_map,
            // Borrow the struct slice from the Protocol; do not free it here.
            .structs = p.structs,
            .unions = p.unions,
        };
        try self.protocols.put(self.gpa, header_key, pe);
    }

    /// True if `type_name` is a genuine XID type (from <xidtype>/<xidunion>) in the target
    /// protocol or any of its imports. This is distinct from is_xid in the Resolved value,
    /// which also marks typedef newnames as xid-like. True XIDs are always 4 bytes (u32).
    pub fn isTrueXid(self: *const Registry, target_header: []const u8, type_name: []const u8) bool {
        // Handle qualified names like "xproto:WINDOW"
        if (std.mem.indexOfScalar(u8, type_name, ':')) |colon| {
            const qual_header = type_name[0..colon];
            const bare_name = type_name[colon + 1 ..];
            if (self.protocols.get(qual_header)) |pe| {
                return pe.true_xids.contains(bare_name);
            }
            return false;
        }
        if (self.protocols.get(target_header)) |pe| {
            if (pe.true_xids.contains(type_name)) return true;
            for (pe.imports) |imp_header| {
                if (self.protocols.get(imp_header)) |imp_pe| {
                    if (imp_pe.true_xids.contains(type_name)) return true;
                }
            }
        }
        return false;
    }

    /// Underlying builtin Zig primitive for a scalar-decodable type, following
    /// typedef chains and mapping true XIDs to u32. null for aggregates/unknown.
    pub fn scalarBuiltin(self: *const Registry, target_header: []const u8, type_name: []const u8) ?[]const u8 {
        return self.scalarBuiltinDepth(target_header, type_name, 0);
    }

    fn scalarBuiltinDepth(self: *const Registry, target_header: []const u8, type_name: []const u8, depth: u8) ?[]const u8 {
        if (depth > 16) return null; // cycle guard
        if (builtin_map.get(type_name)) |zt| return zt;
        if (self.isTrueXid(target_header, type_name)) return "u32";
        // Handle qualified "mod:Name"
        var header = target_header;
        var bare = type_name;
        if (std.mem.indexOfScalar(u8, type_name, ':')) |colon| {
            header = type_name[0..colon];
            bare = type_name[colon + 1 ..];
            if (builtin_map.get(bare)) |zt| return zt;
        }
        // Typedef in the target header or any import.
        if (self.protocols.get(header)) |pe| {
            if (pe.typedefs.get(bare)) |old| return self.scalarBuiltinDepth(header, old, depth + 1);
            for (pe.imports) |imp_header| {
                if (self.protocols.get(imp_header)) |imp_pe| {
                    if (imp_pe.typedefs.get(bare)) |old| return self.scalarBuiltinDepth(imp_header, old, depth + 1);
                }
            }
        }
        return null;
    }

    /// Returns the byte size of a fixed-layout struct, or null if any field is
    /// variable-width (list, fd, switch, exprfield, align-style pad, or an unresolved type).
    pub fn fixedSizeOf(self: *const Registry, header: []const u8, struct_name: []const u8) ?usize {
        return self.fixedSizeOfDepth(header, struct_name, 0);
    }

    fn fixedSizeOfDepth(self: *const Registry, header: []const u8, struct_name: []const u8, depth: u8) ?usize {
        if (depth > 16) return null;
        const fields = self.structFields(header, struct_name) orelse return null;
        var total: usize = 0;
        for (fields) |f| {
            switch (f.kind) {
                .pad => {
                    if (f.pad_align) return null; // align-pad: variable, bail
                    total += f.pad_bytes;
                },
                .scalar => {
                    if (self.scalarBuiltin(header, f.type_ref)) |zt| {
                        total += zigWidth(zt) orelse return null;
                    } else if (self.fixedSizeOfDepth(header, f.type_ref, depth + 1)) |sz| {
                        total += sz; // nested fixed struct
                    } else if (self.unionSizeOfDepth(header, f.type_ref, depth + 1)) |usz| {
                        total += usz; // nested fixed union (e.g. SetBehavior's Behavior)
                    } else return null;
                },
                .list => {
                    // A list with a compile-time-known (literal) length and a
                    // fixed-size element is itself fixed-size (e.g. xkb SIAction's
                    // data[7]). Any non-literal length keeps the struct variable.
                    const ll = f.list_len orelse return null;
                    const n: usize = switch (ll.*) {
                        .value => |v| if (v >= 0) @intCast(v) else return null,
                        else => return null,
                    };
                    const elem_sz: usize = if (self.scalarBuiltin(header, f.type_ref)) |zt|
                        (zigWidth(zt) orelse return null)
                    else
                        (self.fixedSizeOfDepth(header, f.type_ref, depth + 1) orelse return null);
                    total += n * elem_sz;
                },
                else => return null, // fd/switch/exprfield -> variable
            }
        }
        return total;
    }

    /// Look up the fields of a struct by name in the given protocol or its imports.
    /// Handles qualified "mod:Name" names by splitting on colon, and follows a
    /// typedef whose target is a struct (e.g. xkb SALatchMods -> SASetMods).
    pub fn structFields(self: *const Registry, header: []const u8, name: []const u8) ?[]const xcbproto.Field {
        return self.structFieldsDepth(header, name, 0);
    }

    fn structFieldsDepth(self: *const Registry, header: []const u8, name: []const u8, depth: u8) ?[]const xcbproto.Field {
        if (depth > 16) return null; // typedef-cycle guard
        var hdr = header;
        var bare = name;
        if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            hdr = name[0..colon];
            bare = name[colon + 1 ..];
        }
        if (self.protocols.get(hdr)) |pe| {
            for (pe.structs) |s| {
                if (std.mem.eql(u8, s.name, bare)) return s.fields;
            }
            // Follow a typedef to its target (which may itself be a struct).
            if (pe.typedefs.get(bare)) |old| {
                if (!std.mem.eql(u8, old, bare)) {
                    if (self.structFieldsDepth(hdr, old, depth + 1)) |f| return f;
                }
            }
            for (pe.imports) |imp_header| {
                if (self.protocols.get(imp_header)) |imp_pe| {
                    for (imp_pe.structs) |s| {
                        if (std.mem.eql(u8, s.name, bare)) return s.fields;
                    }
                }
            }
        }
        return null;
    }

    /// Size of a fixed-size union (max variant), or null if any variant is not a
    /// fixed scalar or fixed struct. Mirrors codegen's unionWireSize.
    fn unionSizeOfDepth(self: *const Registry, header: []const u8, name: []const u8, depth: u8) ?usize {
        if (depth > 16) return null;
        const fields = self.unionFields(header, name) orelse return null;
        var max_sz: usize = 0;
        for (fields) |f| {
            if (f.kind != .scalar) return null;
            const sz: usize = if (self.scalarBuiltin(header, f.type_ref)) |zt|
                (zigWidth(zt) orelse return null)
            else if (self.fixedSizeOfDepth(header, f.type_ref, depth + 1)) |ssz|
                ssz
            else
                return null;
            if (sz > max_sz) max_sz = sz;
        }
        if (max_sz == 0) return null;
        return max_sz;
    }

    /// Look up a union's variant fields by name (target protocol or imports).
    /// Handles qualified "mod:Name" names. Used to size a fixed-size union that
    /// appears as a list element (e.g. xkb Action).
    pub fn unionFields(self: *const Registry, header: []const u8, name: []const u8) ?[]const xcbproto.Field {
        var hdr = header;
        var bare = name;
        if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            hdr = name[0..colon];
            bare = name[colon + 1 ..];
        }
        if (self.protocols.get(hdr)) |pe| {
            for (pe.unions) |u| {
                if (std.mem.eql(u8, u.name, bare)) return u.fields;
            }
            for (pe.imports) |imp_header| {
                if (self.protocols.get(imp_header)) |imp_pe| {
                    for (imp_pe.unions) |u| {
                        if (std.mem.eql(u8, u.name, bare)) return u.fields;
                    }
                }
            }
        }
        return null;
    }

    /// Byte width of a Zig primitive type string returned by scalarBuiltin.
    fn zigWidth(zt: []const u8) ?usize {
        if (std.mem.eql(u8, zt, "u8") or std.mem.eql(u8, zt, "i8") or std.mem.eql(u8, zt, "bool")) return 1;
        if (std.mem.eql(u8, zt, "u16") or std.mem.eql(u8, zt, "i16")) return 2;
        if (std.mem.eql(u8, zt, "u32") or std.mem.eql(u8, zt, "i32") or std.mem.eql(u8, zt, "f32")) return 4;
        if (std.mem.eql(u8, zt, "u64") or std.mem.eql(u8, zt, "i64") or std.mem.eql(u8, zt, "f64")) return 8;
        return null;
    }

    /// True if `type_name` resolves to a known builtin or a declared type
    /// (locally or via an imported protocol). Unknown names return false so
    /// codegen can emit a safe fallback rather than a dangling reference.
    pub fn isKnown(self: *const Registry, target_header: []const u8, type_name: []const u8) bool {
        if (std.mem.indexOfScalar(u8, type_name, ':')) |colon| {
            const qual_header = type_name[0..colon];
            const bare_name = type_name[colon + 1 ..];
            if (self.protocols.get(qual_header)) |pe| {
                return pe.type_names.get(bare_name) != null;
            }
            return false;
        }
        if (builtin_map.get(type_name) != null) return true;
        if (self.protocols.get(target_header)) |pe| {
            if (pe.type_names.get(type_name) != null) return true;
            for (pe.imports) |imp_header| {
                if (self.protocols.get(imp_header)) |imp_pe| {
                    if (imp_pe.type_names.get(type_name) != null) return true;
                }
            }
        }
        return false;
    }

    pub fn resolve(self: *const Registry, target_header: []const u8, type_name: []const u8) Resolved {
        // Step 1: handle qualified names like "xproto:WINDOW"
        if (std.mem.indexOfScalar(u8, type_name, ':')) |colon| {
            const qual_header = type_name[0..colon];
            const bare_name = type_name[colon + 1 ..];
            if (std.mem.eql(u8, qual_header, target_header)) {
                const is_xid = blk: {
                    if (self.protocols.get(target_header)) |pe| {
                        if (pe.type_names.get(bare_name)) |v| break :blk v;
                    }
                    break :blk false;
                };
                return .{ .local = .{ .name = bare_name, .is_xid = is_xid } };
            }
            const is_xid = blk: {
                if (self.protocols.get(qual_header)) |pe| {
                    if (pe.type_names.get(bare_name)) |v| break :blk v;
                }
                break :blk false;
            };
            return .{ .imported = .{ .module = qual_header, .name = bare_name, .is_xid = is_xid } };
        }

        // Step 2: builtin check
        if (builtin_map.get(type_name)) |zig_type| {
            return .{ .builtin = zig_type };
        }

        // Step 3: local check
        if (self.protocols.get(target_header)) |pe| {
            if (pe.type_names.get(type_name)) |is_xid| {
                return .{ .local = .{ .name = type_name, .is_xid = is_xid } };
            }

            // Step 4: search imported protocols in order
            for (pe.imports) |imp_header| {
                if (self.protocols.get(imp_header)) |imp_pe| {
                    if (imp_pe.type_names.get(type_name)) |is_xid| {
                        return .{ .imported = .{ .module = imp_header, .name = type_name, .is_xid = is_xid } };
                    }
                }
            }
        }

        // Step 5: fall through to local (unknown -> local so codegen gets a compile error)
        return .{ .local = .{ .name = type_name, .is_xid = false } };
    }
};

test "scalarBuiltin resolves typedef chains, xids, builtins" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <typedef oldname="CARD8" newname="KEYCODE" />
        \\  <typedef oldname="CARD32" newname="KEYSYM" />
        \\  <typedef oldname="KEYCODE" newname="KEYCODE32" />
        \\  <struct name="POINT"><field type="INT16" name="x"/></struct>
        \\</xcb>
    ;
    var p = try xcbproto.parse(std.testing.allocator, doc);
    defer p.deinit(std.testing.allocator);
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.addProtocol(&p);

    try std.testing.expectEqualStrings("u8", reg.scalarBuiltin("xproto", "KEYCODE").?);
    try std.testing.expectEqualStrings("u32", reg.scalarBuiltin("xproto", "KEYSYM").?);
    try std.testing.expectEqualStrings("u8", reg.scalarBuiltin("xproto", "KEYCODE32").?); // chained
    try std.testing.expectEqualStrings("u32", reg.scalarBuiltin("xproto", "WINDOW").?); // true xid
    try std.testing.expectEqualStrings("u16", reg.scalarBuiltin("xproto", "CARD16").?); // builtin
    try std.testing.expect(reg.scalarBuiltin("xproto", "POINT") == null); // aggregate
    try std.testing.expect(reg.scalarBuiltin("xproto", "Nonexist") == null); // unknown
}

test "fixedSizeOf sums fixed fields, null on variable" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <typedef oldname="CARD8" newname="KEYCODE" />
        \\  <struct name="POINT"><field type="INT16" name="x"/><field type="INT16" name="y"/></struct>
        \\  <struct name="CHARINFO">
        \\    <field type="INT16" name="left_side_bearing"/><field type="INT16" name="right_side_bearing"/>
        \\    <field type="INT16" name="character_width"/><field type="CARD16" name="ascent"/>
        \\    <field type="CARD16" name="descent"/><field type="CARD16" name="attributes"/>
        \\  </struct>
        \\  <struct name="MIXED"><field type="WINDOW" name="w"/><field type="KEYCODE" name="k"/><pad bytes="3"/></struct>
        \\  <struct name="VARI"><field type="CARD8" name="n"/><list type="CARD8" name="data"><fieldref>n</fieldref></list></struct>
        \\</xcb>
    ;
    var p = try xcbproto.parse(std.testing.allocator, doc);
    defer p.deinit(std.testing.allocator);
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.addProtocol(&p);

    try std.testing.expectEqual(@as(?usize, 4), reg.fixedSizeOf("xproto", "POINT")); // 2+2
    try std.testing.expectEqual(@as(?usize, 12), reg.fixedSizeOf("xproto", "CHARINFO")); // 6*2
    try std.testing.expectEqual(@as(?usize, 8), reg.fixedSizeOf("xproto", "MIXED")); // 4+1+3
    try std.testing.expectEqual(@as(?usize, null), reg.fixedSizeOf("xproto", "VARI")); // has a list
}

test "resolve builtin, local, and imported types" {
    const xproto_doc =
        \\<xcb header="xproto"><xidtype name="WINDOW" /><struct name="POINT"><field type="INT16" name="x"/></struct></xcb>
    ;
    const xkb_doc =
        \\<xcb header="xkb" extension-name="XKB"><import>xproto</import>
        \\<request name="UseExtension" opcode="0"><field type="CARD16" name="wantedMajor"/>
        \\<reply><field type="WINDOW" name="win"/></reply></request></xcb>
    ;
    var xp = try xcbproto.parse(std.testing.allocator, xproto_doc);
    defer xp.deinit(std.testing.allocator);
    var xk = try xcbproto.parse(std.testing.allocator, xkb_doc);
    defer xk.deinit(std.testing.allocator);

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.addProtocol(&xp);
    try reg.addProtocol(&xk);

    switch (reg.resolve("xkb", "CARD16")) {
        .builtin => |z| try std.testing.expectEqualStrings("u16", z),
        else => return error.TestUnexpected,
    }
    switch (reg.resolve("xkb", "WINDOW")) {
        .imported => |m| {
            try std.testing.expectEqualStrings("xproto", m.module);
            try std.testing.expectEqualStrings("WINDOW", m.name);
            try std.testing.expect(m.is_xid);
        },
        else => return error.TestUnexpected,
    }
    switch (reg.resolve("xproto", "POINT")) {
        .local => |n| {
            try std.testing.expectEqualStrings("POINT", n.name);
            try std.testing.expect(!n.is_xid);
        },
        else => return error.TestUnexpected,
    }
}
