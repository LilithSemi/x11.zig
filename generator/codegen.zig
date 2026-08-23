const std = @import("std");
const xcbproto = @import("xcbproto.zig");
const registry = @import("registry.zig");

/// The only faults the code emitters raise: allocation (scratch containers and
/// name-dedup key dupes) and writer failure. Matches the set emitLenExpr already
/// declares, made explicit per IronStyle rather than inferred.
pub const EmitError = error{ OutOfMemory, WriteFailed };

// Zig keywords that must be escaped with @"..." when used as identifiers.
const zig_keywords = [_][]const u8{
    "addrspace", "align",   "allowzero",   "and",            "anyframe",    "anytype",
    "asm",       "async",   "await",       "break",          "callconv",    "catch",
    "comptime",  "const",   "continue",    "defer",          "else",        "enum",
    "errdefer",  "error",   "export",      "extern",         "fn",          "for",
    "if",        "inline",  "noalias",     "noinline",       "nosuspend",   "opaque",
    "or",        "orelse",  "packed",      "pub",            "resume",      "return",
    "struct",    "suspend", "switch",      "test",           "threadlocal", "try",
    "type",      "union",   "unreachable", "usingnamespace", "var",         "volatile",
    "while",
};

fn isZigKeyword(name: []const u8) bool {
    for (zig_keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

// True if `name` is a legal bare Zig identifier (starts with letter/_, rest are
// alphanumeric/_). Names that aren't (empty, digit-leading, punctuation) must be
// wrapped in @"..." syntax.
fn isValidBareIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

// Write an identifier, escaping it if it's a Zig keyword or not a valid bare
// identifier (e.g. an enum item literally named "1").
fn writeIdent(w: *std.Io.Writer, name: []const u8) EmitError!void {
    if (isZigKeyword(name) or !isValidBareIdent(name)) {
        try w.print("@\"{s}\"", .{name});
    } else {
        try w.writeAll(name);
    }
}

// Convert name to PascalCase.
// - snake_case -> PascalCase (capitalize each word)
// - ALLCAPS -> Allcaps (first letter upper, rest lower)
// - CamelCase / PascalCase -> preserved as-is (already has mixed case)
fn toPascal(name: []const u8, buf: []u8) []const u8 {
    // Detect if name has underscores (snake_case or UPPER_SNAKE)
    const has_underscore = std.mem.indexOfScalar(u8, name, '_') != null;

    // Detect if name is all-uppercase (like GX, WINDOW, CARD8)
    var all_upper = true;
    for (name) |c| {
        if (std.ascii.isAlphabetic(c)) {
            if (std.ascii.isLower(c)) {
                all_upper = false;
            }
        }
    }

    var out_len: usize = 0;

    if (has_underscore) {
        // snake_case or UPPER_SNAKE: capitalize each segment
        var capitalize_next = true;
        for (name) |c| {
            if (c == '_') {
                capitalize_next = true;
                continue;
            }
            if (out_len >= buf.len) break;
            if (capitalize_next) {
                buf[out_len] = std.ascii.toUpper(c);
                capitalize_next = false;
            } else {
                buf[out_len] = std.ascii.toLower(c);
            }
            out_len += 1;
        }
    } else if (all_upper) {
        // ALLCAPS: first letter upper, rest lower
        for (name, 0..) |c, i| {
            if (out_len >= buf.len) break;
            if (i == 0) {
                buf[out_len] = std.ascii.toUpper(c);
            } else {
                buf[out_len] = std.ascii.toLower(c);
            }
            out_len += 1;
        }
    } else {
        // CamelCase or mixed: preserve but ensure first letter is upper
        for (name, 0..) |c, i| {
            if (out_len >= buf.len) break;
            if (i == 0) {
                buf[out_len] = std.ascii.toUpper(c);
            } else {
                buf[out_len] = c;
            }
            out_len += 1;
        }
    }

    return buf[0..out_len];
}

// Convert name to snake_case. Handles CamelCase and UPPER_CASE.
fn toSnake(name: []const u8, buf: []u8) []const u8 {
    var out_len: usize = 0;
    var prev_upper = false;
    var first = true;

    for (name) |c| {
        if (std.ascii.isUpper(c)) {
            if (!first and !prev_upper and out_len + 1 < buf.len) {
                buf[out_len] = '_';
                out_len += 1;
            }
            if (out_len < buf.len) {
                buf[out_len] = std.ascii.toLower(c);
                out_len += 1;
            }
            prev_upper = true;
        } else if (c == '_') {
            if (!first and out_len < buf.len) {
                buf[out_len] = '_';
                out_len += 1;
            }
            prev_upper = false;
        } else {
            if (out_len < buf.len) {
                buf[out_len] = c;
                out_len += 1;
            }
            prev_upper = false;
        }
        first = false;
    }
    return buf[0..out_len];
}

// Return the byte width for a Zig primitive type string (from scalarBuiltin).
// Returns null for float/double (not readInt-capable) and for unknown strings.
fn zigWidthFromBuiltin(zig_type: []const u8) ?usize {
    if (std.mem.eql(u8, zig_type, "u8") or
        std.mem.eql(u8, zig_type, "i8") or
        std.mem.eql(u8, zig_type, "bool")) return 1;
    if (std.mem.eql(u8, zig_type, "u16") or std.mem.eql(u8, zig_type, "i16")) return 2;
    if (std.mem.eql(u8, zig_type, "u32") or std.mem.eql(u8, zig_type, "i32")) return 4;
    if (std.mem.eql(u8, zig_type, "u64") or std.mem.eql(u8, zig_type, "i64")) return 8;
    return null; // float/double: not integer-readable via readInt
}

// Return the byte width (1, 2, 4, or 8) of a builtin or true-XID scalar type.
// Returns 0 if the type is not a fixed-width scalar (aggregate, typedef, unknown, etc.).
// Uses scalarBuiltin to follow typedef chains, so typedef fields now have real widths.
fn scalarByteWidth(reg: *const registry.Registry, header: []const u8, type_ref: []const u8) usize {
    const zig_type = reg.scalarBuiltin(header, type_ref) orelse return 0;
    return zigWidthFromBuiltin(zig_type) orelse 0;
}

// Largest fixed variant size of a union, or null if any variant is not a
// fixed-size scalar or fixed-size struct (a list or unresolved type means the
// union cannot be sized, so the caller keeps the field-listing placeholder).
fn unionWireSize(
    reg: *const registry.Registry,
    header: []const u8,
    fields: []const xcbproto.Field,
) ?usize {
    var max_sz: usize = 0;
    for (fields) |f| {
        if (f.kind != .scalar) return null;
        const scalar_sz = scalarByteWidth(reg, header, f.type_ref);
        const sz = if (scalar_sz != 0)
            scalar_sz
        else
            (reg.fixedSizeOf(header, f.type_ref) orelse return null);
        if (sz > max_sz) max_sz = sz;
    }
    if (max_sz == 0) return null;
    return max_sz;
}

// Which kind of wire container is being decoded. Determines cursor start conventions.
const DecodeKind = enum { reply, event, error_, struct_elem };

// Emit result.<field> = ... decode statements for all leading fixed scalar/xid/typedef/pad
// fields, using a runtime byte cursor per the kind convention. Writes directly to w.
// Returns the byte offset just past the last fixed field decoded (the list base).
// Stops at the first non-fixed field (list/switch/exprfield/fd/unknown/float) and returns.
// Assumes var result: T = std.mem.zeroes(T); already emitted by caller.
// native_endian const must have been emitted by caller if any multi-byte reads exist.
fn emitFixedFieldDecodes(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    header: []const u8,
    fields: []const xcbproto.Field,
    kind: DecodeKind,
) EmitError!usize {
    var dedup: std.StringHashMapUnmanaged(void) = .{};
    defer dedup.deinit(gpa);

    // Determine initial cursor position per kind convention.
    // For reply and event, the first field may decode at offset 1 (if it is a 1-byte scalar).
    // field_idx tracks whether we are at the first field position.
    var off: usize = switch (kind) {
        .reply => 1, // first 1-byte scalar goes @1, then jumps to 8
        .event => 1, // first 1-byte scalar goes @1, then jumps to 4
        .error_ => 4, // no offset-1 slot; cursor starts at 4
        .struct_elem => 0, // all fields sequential from 0
    };
    var first_slot_consumed = false; // true once offset-1 slot has been used or skipped

    for (fields) |f| {
        switch (f.kind) {
            .pad => {
                if (f.pad_align) {
                    // Align-style pad: variable runtime size, cannot track. STOP.
                    break;
                }
                // Handle first-slot convention for reply/event pads.
                if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                    // A leading pad consumes the offset-1 slot; jump cursor to post-gap.
                    first_slot_consumed = true;
                    off = if (kind == .reply) 8 else 4;
                    // The pad itself occupies byte 1 (implicit). Remaining pad bytes
                    // beyond the first: advance cursor. (f.pad_bytes == 1 means just byte 1.)
                    if (f.pad_bytes > 1) off += f.pad_bytes - 1;
                } else {
                    off += f.pad_bytes;
                }
            },
            .scalar => {
                // Check for a nested fixed-size struct (has decodeElement + wire_size).
                if (nestedFixedStructSize(reg, header, f)) |wsz| {
                    // Nested fixed struct: decode inline via decodeElement.
                    if ((try dedup.getOrPut(gpa, f.name)).found_existing) {
                        // Duplicate: advance cursor but don't re-emit.
                        if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                            first_slot_consumed = true;
                            off = if (kind == .reply) 8 else 4;
                        } else {
                            off += wsz;
                        }
                        continue;
                    }

                    // Nested structs are never 1 byte, so always consume first slot
                    // by jumping to post-gap if not yet consumed.
                    const field_off: usize = blk: {
                        if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                            first_slot_consumed = true;
                            off = if (kind == .reply) 8 else 4;
                            break :blk off;
                        } else {
                            break :blk off;
                        }
                    };

                    // Emit bounds-guarded decodeElement call.
                    try w.print("    if (bytes.len >= {d}) {{\n", .{field_off + wsz});
                    try w.writeAll("        result.");
                    try writeIdent(w, f.name);
                    try w.writeAll(" = ");
                    try emitZigType(w, reg, header, f.type_ref);
                    try w.print(".decodeElement(bytes[{d}..], native_endian);\n", .{field_off});
                    try w.writeAll("    }\n");

                    // Advance cursor.
                    off = field_off + wsz;
                    continue;
                }

                // Resolve via scalarBuiltin to follow typedef chains.
                const zig_type = reg.scalarBuiltin(header, f.type_ref) orelse {
                    // Aggregate or unknown: safe-fallback, STOP.
                    break;
                };
                const width = zigWidthFromBuiltin(zig_type) orelse {
                    // Float: not readInt-capable, STOP.
                    break;
                };

                if ((try dedup.getOrPut(gpa, f.name)).found_existing) {
                    // Duplicate field name: advance cursor but don't re-emit.
                    if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                        first_slot_consumed = true;
                        off = if (kind == .reply) 8 else 4;
                    } else {
                        off += width;
                    }
                    continue;
                }

                // Determine actual offset for this field.
                const field_off: usize = blk: {
                    if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                        // First slot: only 1-byte scalars decode at offset 1.
                        if (width == 1) {
                            first_slot_consumed = true;
                            break :blk 1;
                        } else {
                            // Width != 1: skip offset-1, jump to post-gap.
                            first_slot_consumed = true;
                            off = if (kind == .reply) 8 else 4;
                            break :blk off;
                        }
                    } else {
                        break :blk off;
                    }
                };

                // Emit the bounds-guarded read.
                if (width == 1) {
                    try w.print("    if (bytes.len > {d}) {{\n", .{field_off});
                    try w.writeAll("        result.");
                    try writeIdent(w, f.name);
                    if (std.mem.eql(u8, zig_type, "bool")) {
                        try w.print(" = bytes[{d}] != 0;\n", .{field_off});
                    } else if (std.mem.eql(u8, zig_type, "i8")) {
                        try w.print(" = @bitCast(bytes[{d}]);\n", .{field_off});
                    } else {
                        try w.print(" = bytes[{d}];\n", .{field_off});
                    }
                    try w.writeAll("    }\n");
                } else {
                    try w.print("    if (bytes.len >= {d}) {{\n", .{field_off + width});
                    try w.writeAll("        result.");
                    try writeIdent(w, f.name);
                    try w.print(" = std.mem.readInt({s}, bytes[{d}..][0..{d}], native_endian);\n", .{ zig_type, field_off, width });
                    try w.writeAll("    }\n");
                }

                // Advance cursor after emission.
                if (field_off == 1 and (kind == .reply or kind == .event)) {
                    // Post-first-byte gap: jump to 8 (reply) or 4 (event).
                    off = if (kind == .reply) 8 else 4;
                } else {
                    off = field_off + width;
                }
            },
            .list => {
                // Inside a fixed-size struct element, a literal-length list with a
                // fixed-scalar element is part of the fixed layout and decodes as a
                // borrowed slice. Every other context/shape stops (reply/event
                // lists are handled by emitListDecodes).
                if (kind != .struct_elem) break;
                const ll = f.list_len orelse break;
                const n: usize = switch (ll.*) {
                    .value => |v| if (v >= 0) @intCast(v) else break,
                    else => break,
                };
                const bt = reg.scalarBuiltin(header, f.type_ref) orelse break;
                const ew = zigWidthFromBuiltin(bt) orelse break;
                const nbytes = n * ew;
                if ((try dedup.getOrPut(gpa, f.name)).found_existing) {
                    off += nbytes;
                    continue;
                }
                try w.print("    if (bytes.len >= {d}) {{\n", .{off + nbytes});
                try w.writeAll("        result.");
                try writeIdent(w, f.name);
                try w.writeAll(" = std.mem.bytesAsSlice(");
                try emitZigType(w, reg, header, f.type_ref);
                try w.print(", bytes[{d}..][0..{d}]);\n", .{ off, nbytes });
                try w.writeAll("    }\n");
                off += nbytes;
            },
            // Non-fixed: fd, exprfield, switch_ - all are STOP.
            else => break,
        }
    }

    return off;
}

// Pre-scan fields to determine (a) whether any reads will be emitted,
// (b) whether any multi-byte read is needed (native_endian required).
// Returns .{ has_reads, needs_endian }.
// Uses the same dedup and first-slot logic as emitFixedFieldDecodes so the
// two passes are guaranteed to agree on (has_reads, needs_endian).
fn prescanFixedFields(
    gpa: std.mem.Allocator,
    reg: *const registry.Registry,
    header: []const u8,
    fields: []const xcbproto.Field,
    kind: DecodeKind,
) EmitError!struct { bool, bool } {
    var dedup: std.StringHashMapUnmanaged(void) = .{};
    defer dedup.deinit(gpa);

    var has_reads = false;
    var needs_endian = false;
    var first_slot_consumed = false;

    for (fields) |f| {
        switch (f.kind) {
            .pad => {
                if (f.pad_align) break;
                if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                    first_slot_consumed = true;
                }
                continue;
            },
            .scalar => {
                // Check for a nested fixed-size struct first.
                if (nestedFixedStructSize(reg, header, f) != null) {
                    if ((try dedup.getOrPut(gpa, f.name)).found_existing) {
                        // Duplicate: mirror cursor-advance, no read emitted.
                        if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                            first_slot_consumed = true;
                        }
                        continue;
                    }
                    // Not a duplicate: this nested struct will be emitted by emit pass.
                    if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                        first_slot_consumed = true;
                    }
                    has_reads = true;
                    // The caller now threads `native_endian` into this nested
                    // struct's decodeElement (it no longer declares its own), so
                    // the enclosing decoder MUST have `const native_endian` in
                    // scope. Force it regardless of the nested struct's own width.
                    needs_endian = true;
                    continue;
                }

                const zig_type = reg.scalarBuiltin(header, f.type_ref) orelse break;
                const width = zigWidthFromBuiltin(zig_type) orelse break;

                if ((try dedup.getOrPut(gpa, f.name)).found_existing) {
                    // Duplicate: mirrors emit pass cursor-advance, but no read emitted.
                    if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                        first_slot_consumed = true;
                    }
                    continue;
                }

                // Not a duplicate: this field will be emitted by the emit pass.
                if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                    first_slot_consumed = true;
                }
                has_reads = true;
                if (width > 1) needs_endian = true;
            },
            .list => {
                // Mirror emitFixedFieldDecodes: a literal-length fixed-scalar list
                // inside a struct element is a borrowed-slice read (no endian); any
                // other context/shape stops the fixed pass.
                if (kind != .struct_elem) break;
                const ll = f.list_len orelse break;
                switch (ll.*) {
                    .value => |v| if (v < 0) break,
                    else => break,
                }
                const bt = reg.scalarBuiltin(header, f.type_ref) orelse break;
                _ = zigWidthFromBuiltin(bt) orelse break;
                if ((try dedup.getOrPut(gpa, f.name)).found_existing) continue;
                has_reads = true;
            },
            else => break,
        }
    }

    return .{ has_reads, needs_endian };
}

// Emit r.<field> = ... style WRITE statements into `buf[<off>...]` for all
// leading fixed scalar/xid/typedef/pad fields - the write-side mirror of
// emitFixedFieldDecodes. Uses the IDENTICAL offset/first-slot bookkeeping as
// the decoder (same initial cursor per kind, same offset-1 first-scalar
// convention, same dedup-by-name advance-without-emit) so the two can never
// drift apart; the round-trip tests are the guarantee. Multi-byte scalars are
// written via std.mem.writeInt(T, buf[off..][0..N], r.<field>, endian)
// (honoring the caller's endian param); single-byte scalars/bools/i8 are
// written directly into buf[off]. A nested fixed struct/union scalar field is
// written inline via `r.<field>.encodeElement(buf[<off>..], endian)` at the
// SAME offset emitFixedFieldDecodes would decodeElement it from - mirroring
// the decoder exactly, so the two can never disagree. Stops at the first
// non-fixed field (list/switch/exprfield/fd/variable-aggregate/unknown/float)
// exactly like the decoder halts - for a reply with a trailing scalar- or
// fixed-struct-element list, this simply omits the list (the reply encoder's
// own caller appends it; see the reply-encoder emission below).
// Returns the byte offset just past the last field written, together with
// how many leading `fields` entries were consumed before the walk halted
// (== fields.len when nothing halted it). Called once with a Discarding
// writer to size the caller's stack buffer, then again with the real writer
// to emit the body. `fields_consumed` is the single source of truth for
// where a trailing field run (e.g. a reply's scalar-element list run) picks
// up - callers must never re-derive the halt point with an independent scan.
const FixedEncodeResult = struct {
    bytes_written: usize,
    fields_consumed: usize,
};

fn emitFixedFieldEncodes(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    header: []const u8,
    fields: []const xcbproto.Field,
    kind: DecodeKind,
) EmitError!FixedEncodeResult {
    var dedup: std.StringHashMapUnmanaged(void) = .{};
    defer dedup.deinit(gpa);

    var off: usize = switch (kind) {
        .reply => 1, // first 1-byte scalar goes @1, then jumps to 8
        .event => 1, // first 1-byte scalar goes @1, then jumps to 4
        .error_ => 4, // no offset-1 slot; cursor starts at 4
        .struct_elem => 0, // all fields sequential from 0
    };
    var first_slot_consumed = false;
    var fields_consumed: usize = fields.len;

    for (fields, 0..) |f, i| {
        switch (f.kind) {
            .pad => {
                if (f.pad_align) {
                    fields_consumed = i; // variable runtime size, cannot track. STOP.
                    break;
                }
                if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                    first_slot_consumed = true;
                    off = if (kind == .reply) 8 else 4;
                    if (f.pad_bytes > 1) off += f.pad_bytes - 1;
                } else {
                    off += f.pad_bytes;
                }
            },
            .scalar => {
                if (nestedFixedStructSize(reg, header, f)) |wsz| {
                    // Nested fixed struct/union: write inline via its own
                    // encodeElement, mirroring emitFixedFieldDecodes's
                    // decodeElement call above so the two never disagree on
                    // an offset.
                    if ((try dedup.getOrPut(gpa, f.name)).found_existing) {
                        if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                            first_slot_consumed = true;
                            off = if (kind == .reply) 8 else 4;
                        } else {
                            off += wsz;
                        }
                        continue;
                    }

                    // Nested structs are never 1 byte, so always consume the
                    // first slot by jumping to post-gap if not yet consumed.
                    const field_off: usize = blk: {
                        if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                            first_slot_consumed = true;
                            off = if (kind == .reply) 8 else 4;
                            break :blk off;
                        } else {
                            break :blk off;
                        }
                    };

                    try w.writeAll("    r.");
                    try writeIdent(w, f.name);
                    try w.print(".encodeElement(buf[{d}..], endian);\n", .{field_off});

                    off = field_off + wsz;
                    continue;
                }

                const zig_type = reg.scalarBuiltin(header, f.type_ref) orelse {
                    fields_consumed = i;
                    break;
                };
                const width = zigWidthFromBuiltin(zig_type) orelse {
                    fields_consumed = i;
                    break;
                };

                if ((try dedup.getOrPut(gpa, f.name)).found_existing) {
                    // Duplicate field name: advance cursor but don't re-emit.
                    if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                        first_slot_consumed = true;
                        off = if (kind == .reply) 8 else 4;
                    } else {
                        off += width;
                    }
                    continue;
                }

                const field_off: usize = blk: {
                    if (!first_slot_consumed and (kind == .reply or kind == .event)) {
                        if (width == 1) {
                            first_slot_consumed = true;
                            break :blk 1;
                        } else {
                            first_slot_consumed = true;
                            off = if (kind == .reply) 8 else 4;
                            break :blk off;
                        }
                    } else {
                        break :blk off;
                    }
                };

                if (width == 1) {
                    try w.print("    buf[{d}] = ", .{field_off});
                    if (std.mem.eql(u8, zig_type, "bool")) {
                        try w.writeAll("@intFromBool(r.");
                        try writeIdent(w, f.name);
                        try w.writeAll(");\n");
                    } else if (std.mem.eql(u8, zig_type, "i8")) {
                        try w.writeAll("@bitCast(r.");
                        try writeIdent(w, f.name);
                        try w.writeAll(");\n");
                    } else {
                        try w.writeAll("r.");
                        try writeIdent(w, f.name);
                        try w.writeAll(";\n");
                    }
                } else {
                    try w.print("    std.mem.writeInt({s}, buf[{d}..][0..{d}], r.", .{ zig_type, field_off, width });
                    try writeIdent(w, f.name);
                    try w.writeAll(", endian);\n");
                }

                // Advance cursor after emission.
                if (field_off == 1 and (kind == .reply or kind == .event)) {
                    off = if (kind == .reply) 8 else 4;
                } else {
                    off = field_off + width;
                }
            },
            // Non-fixed: list/fd/exprfield/switch - all are STOP. A trailing
            // scalar-element list is picked back up by the reply encoder via
            // the returned fields_consumed; everything else stays
            // fixed-part-only.
            else => {
                fields_consumed = i;
                break;
            },
        }
    }

    return .{ .bytes_written = off, .fields_consumed = fields_consumed };
}

// Look up an event by name within a protocol (used by <eventcopy> encoders to
// reach the referenced event's field layout while writing the COPY's own
// number). Returns null if the ref name is not a known event (should not
// happen for well-formed xcbproto XML).
fn findEventByName(p: *const xcbproto.Protocol, name: []const u8) ?xcbproto.Event {
    for (p.events) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

// Look up an error by name within a protocol (used by <errorcopy> encoders,
// mirroring findEventByName above).
fn findErrorByName(p: *const xcbproto.Protocol, name: []const u8) ?xcbproto.ErrorDef {
    for (p.errors) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

// Emit `pub fn encode<Pascal>Event(...)`: the write-side mirror of the event
// decoders emitted above. All events are fixed 32-byte wire objects: byte0 is
// the event's number (the COPY's own number when called for an <eventcopy> -
// see findEventByName above), seq goes @2-3, and the body (including any
// first-1-byte-scalar "detail" field at byte1) is walked by the SAME
// emitFixedFieldEncodes offset bookkeeping (kind .event) the decoder uses, so
// the two can never disagree on an offset. KeymapNotify has no standard
// header (no sequence number; its `keys` list starts at byte 1 instead) and
// is encoded directly, mirroring its decoder.
fn emitEventEncoder(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    header: []const u8,
    pascal_name: []const u8,
    number: u8,
    fields: []const xcbproto.Field,
    is_keymap: bool,
) EmitError!void {
    try w.print(
        "pub fn encode{s}Event(w: *std.Io.Writer, endian: std.builtin.Endian, seq: u16, r: {s}Event) error{{WriteFailed}}!void {{\n",
        .{ pascal_name, pascal_name },
    );
    try w.writeAll("    var buf: [32]u8 = std.mem.zeroes([32]u8);\n");
    try w.print("    buf[0] = {d};\n", .{number});

    if (is_keymap) {
        var keys_name: []const u8 = "";
        var keys_len: u64 = 0;
        for (fields) |f| {
            if (f.kind == .list) {
                keys_name = f.name;
                switch (exprToSimpleLen(f.list_len)) {
                    .literal => |v| keys_len = v,
                    else => {},
                }
                break;
            }
        }
        try w.writeAll("    _ = seq; // KeymapNotify has no sequence number\n");
        try w.writeAll("    _ = endian;\n");
        try w.writeAll("    const n_ = @min(r.");
        try writeIdent(w, keys_name);
        try w.print(".len, {d});\n", .{keys_len});
        try w.writeAll("    @memcpy(buf[1..][0..n_], r.");
        try writeIdent(w, keys_name);
        try w.writeAll("[0..n_]);\n");
    } else {
        try w.writeAll("    std.mem.writeInt(u16, buf[2..4], seq, endian);\n");

        // Dry run (discarded text) purely to learn whether any field write was
        // emitted - a parameterless-body event would otherwise leave `r` unused.
        var discard_buf: [64]u8 = undefined;
        var discarding = std.Io.Writer.Discarding.init(&discard_buf);
        _ = try emitFixedFieldEncodes(gpa, &discarding.writer, reg, header, fields, .event);
        const wrote_any_field = discarding.fullCount() > 0;
        if (!wrote_any_field) try w.writeAll("    _ = r;\n");
        _ = try emitFixedFieldEncodes(gpa, w, reg, header, fields, .event);
    }
    try w.writeAll("    w.writeAll(&buf) catch return error.WriteFailed;\n");
    try w.writeAll("}\n\n");
}

// Emit `pub fn encode<Pascal>Error(...)`: the write-side mirror of the error
// decoders emitted above. All errors are fixed 32-byte wire objects: byte0 is
// always 0 (the error marker), byte1 is the error's number (the COPY's own
// number when called for an <errorcopy>), seq goes @2-3, and the body starts
// at byte 4 - walked by the SAME emitFixedFieldEncodes offset bookkeeping
// (kind .error_) the decoder uses.
fn emitErrorEncoder(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    header: []const u8,
    pascal_name: []const u8,
    number: u8,
    fields: []const xcbproto.Field,
) EmitError!void {
    try w.print(
        "pub fn encode{s}Error(w: *std.Io.Writer, endian: std.builtin.Endian, seq: u16, r: {s}Error) error{{WriteFailed}}!void {{\n",
        .{ pascal_name, pascal_name },
    );
    try w.writeAll("    var buf: [32]u8 = std.mem.zeroes([32]u8);\n");
    try w.writeAll("    buf[0] = 0;\n");
    try w.print("    buf[1] = {d};\n", .{number});
    try w.writeAll("    std.mem.writeInt(u16, buf[2..4], seq, endian);\n");

    var discard_buf: [64]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buf);
    _ = try emitFixedFieldEncodes(gpa, &discarding.writer, reg, header, fields, .error_);
    const wrote_any_field = discarding.fullCount() > 0;
    if (!wrote_any_field) try w.writeAll("    _ = r;\n");
    _ = try emitFixedFieldEncodes(gpa, w, reg, header, fields, .error_);

    try w.writeAll("    w.writeAll(&buf) catch return error.WriteFailed;\n");
    try w.writeAll("}\n\n");
}

// Emit the Zig type string for a field's type_ref, given the protocol header and registry.
// XIDs are emitted raw (WINDOW, xproto.WINDOW); aggregates (struct/enum) are PascalCase.
fn emitZigType(
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    header: []const u8,
    type_ref: []const u8,
) EmitError!void {
    var pb: [256]u8 = undefined;
    // Unresolved type (missing import seed or unmodelled construct): emit u8 as an
    // explicit, visible escape hatch so generation still produces compilable code.
    // Not a silent default — the u8 is the marker that resolution did not succeed.
    if (!reg.isKnown(header, type_ref)) {
        try w.writeAll("u8");
        return;
    }
    const resolved = reg.resolve(header, type_ref);
    switch (resolved) {
        .builtin => |zig_type| try w.writeAll(zig_type),
        .local => |loc| {
            if (loc.is_xid) {
                try w.writeAll(loc.name);
            } else {
                try w.writeAll(toPascal(loc.name, &pb));
            }
        },
        .imported => |imp| {
            if (imp.is_xid) {
                try w.print("{s}.{s}", .{ imp.module, imp.name });
            } else {
                try w.print("{s}.{s}", .{ imp.module, toPascal(imp.name, &pb) });
            }
        },
    }
}

// True if a list field's element type is a fixed-size struct (not a scalar, not a union).
// Returns the struct's wire size if yes, null otherwise.
fn fixedStructElemSize(reg: *const registry.Registry, header: []const u8, type_ref: []const u8) ?usize {
    // Must NOT be a scalar/builtin (those are handled by the scalar path).
    if (reg.scalarBuiltin(header, type_ref) != null) return null;
    // A fixed-size struct.
    if (reg.fixedSizeOf(header, type_ref)) |sz| return sz;
    // A fixed-size union (all variants fixed): decodes via its raw wire_size,
    // so a list of them is a ListView element (e.g. xkb Action).
    if (reg.unionFields(header, type_ref)) |uf| return unionWireSize(reg, header, uf);
    return null;
}

// A .scalar field whose type is a fixed-size struct (has decodeElement + wire_size).
// Returns its wire size, or null if it is not a decodable nested fixed struct.
fn nestedFixedStructSize(reg: *const registry.Registry, header: []const u8, f: xcbproto.Field) ?usize {
    if (f.kind != .scalar) return null;
    if (reg.scalarBuiltin(header, f.type_ref) != null) return null; // it's a scalar/builtin
    return reg.fixedSizeOf(header, f.type_ref); // null for variable/unknown aggregates
}

/// Emit the body lines (fields) of an aggregate struct for the given field
/// list. Deduplicates field names within the container (real XML occasionally
/// repeats a name, or a switch/exprfield both want a `values` field) since Zig
/// rejects duplicate struct fields. Pads become `_padN: u8 = 0`.
// Is `type_ref` a variable-size struct the generator can fully decode: a fixed
// header, then only lists (and pads) whose elements have a known or
// self-delimiting size (fixed scalar, fixed struct, or a nested
// variable-decodable struct)? Such structs get a decodeSized method (see
// emitVariableStructDecode) and can be walked by StructIterator. The nesting is
// resolved recursively (e.g. xproto SCREEN holds a list of DEPTH, each DEPTH a
// list of VISUALTYPE), depth-guarded against cyclic type graphs.
fn variableDecodableStruct(
    reg: *const registry.Registry,
    header: []const u8,
    type_ref: []const u8,
) bool {
    return variableDecodableStructDepth(reg, header, type_ref, 0);
}

fn variableDecodableStructDepth(
    reg: *const registry.Registry,
    header: []const u8,
    type_ref: []const u8,
    depth: u8,
) bool {
    if (depth > 8) return false; // cycle / too-deep guard
    if (reg.fixedSizeOf(header, type_ref) != null) return false; // fixed -> ListView
    const fields = reg.structFields(header, type_ref) orelse return false;
    var stop: usize = fields.len;
    for (fields, 0..) |sf, i| {
        if (fixedDecodeHalts(reg, header, sf, true)) {
            stop = i;
            break;
        }
    }
    if (!(stop < fields.len and fields[stop].kind == .list)) return false;
    for (fields[stop..]) |sf| {
        switch (sf.kind) {
            .pad => {},
            .list => {
                const bt = reg.scalarBuiltin(header, sf.type_ref);
                const fixed_scalar = bt != null and
                    !(std.mem.eql(u8, bt.?, "f32") or std.mem.eql(u8, bt.?, "f64"));
                if (fixed_scalar) continue;
                if (fixedStructElemSize(reg, header, sf.type_ref) != null) continue;
                if (variableDecodableStructDepth(reg, header, sf.type_ref, depth + 1)) continue;
                return false;
            },
            else => return false,
        }
    }
    return true;
}

fn emitStructFields(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    header: []const u8,
    fields: []const xcbproto.Field,
    // When non-null, a `.switch_` field is emitted as a typed `<sw_field_name>: <T> = .{}`
    // (the decodable-switch value struct) instead of the opaque placeholder.
    sw_values_type: ?[]const u8,
    // Wire name for the emitted `.switch_` field (e.g. "values" for a reply/
    // struct switch, "value_list" for a request value-list switch).
    sw_field_name: []const u8,
) EmitError!void {
    var pad_idx: usize = 0;
    var value_field_emitted = false;
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(gpa);
    for (fields) |field| {
        switch (field.kind) {
            .pad => {
                try w.print("    _pad{d}: u8 = 0,\n", .{pad_idx});
                pad_idx += 1;
            },
            .scalar => {
                if ((try seen.getOrPut(gpa, field.name)).found_existing) continue;
                try w.writeAll("    ");
                try writeIdent(w, field.name);
                try w.writeAll(": ");
                try emitZigType(w, reg, header, field.type_ref);
                try w.writeAll(",\n");
            },
            .list => {
                if ((try seen.getOrPut(gpa, field.name)).found_existing) continue;
                // For fixed-scalar/xid/typedef element types (non-float), emit a
                // borrowed zero-copy aligned slice with a safe &.{} default.
                // For fixed-size struct element types, emit a ListView(T).
                // Float element lists and truly-variable elements fall back to the
                // safe placeholder.
                const maybe_builtin = reg.scalarBuiltin(header, field.type_ref);
                const is_fixed_scalar = blk: {
                    const bt = maybe_builtin orelse break :blk false;
                    if (std.mem.eql(u8, bt, "f32") or std.mem.eql(u8, bt, "f64")) break :blk false;
                    break :blk true;
                };
                if (is_fixed_scalar) {
                    try w.writeAll("    ");
                    try writeIdent(w, field.name);
                    try w.writeAll(": []align(1) const ");
                    try emitZigType(w, reg, header, field.type_ref);
                    try w.writeAll(" = &.{},\n");
                } else if (fixedStructElemSize(reg, header, field.type_ref) != null) {
                    // Fixed-size struct element: emit ListView(ElemType).
                    try w.writeAll("    ");
                    try writeIdent(w, field.name);
                    try w.writeAll(": ListView(");
                    try emitZigType(w, reg, header, field.type_ref);
                    try w.writeAll(") = .{},\n");
                } else if (variableDecodableStruct(reg, header, field.type_ref)) {
                    // Variable-size struct element: emit a StructIterator(ElemType).
                    try w.writeAll("    ");
                    try writeIdent(w, field.name);
                    try w.writeAll(": StructIterator(");
                    try emitZigType(w, reg, header, field.type_ref);
                    try w.writeAll(") = .{},\n");
                } else {
                    // Non-decodable element (nested-variable, unknown, float): safe fallback.
                    try w.writeAll("    ");
                    try writeIdent(w, field.name);
                    try w.writeAll(": []const u8 = &.{}, // TODO(slice3+): aggregate/float element\n");
                }
            },
            .fd => {
                if ((try seen.getOrPut(gpa, field.name)).found_existing) continue;
                try w.writeAll("    ");
                try writeIdent(w, field.name);
                try w.writeAll(": i32,\n");
            },
            .exprfield, .switch_ => {
                // Only emit once per container.
                if (value_field_emitted) continue;
                value_field_emitted = true;
                if (field.kind == .switch_ and sw_values_type != null) {
                    try w.writeAll("    ");
                    try writeIdent(w, sw_field_name);
                    try w.print(": {s} = .{{}},\n", .{sw_values_type.?});
                } else {
                    try w.writeAll("    ");
                    try writeIdent(w, sw_field_name);
                    try w.writeAll(": []const u8 = &.{}, // TODO(slice2)\n");
                }
            },
        }
    }
}

// Emit the decode side of a VARIABLE-size struct into its still-open body.
// When the struct qualifies (fixed header, then a decodable list) it gets a
// `decodeSized(bytes) struct { value, size }` method so a StructIterator can
// walk a list of these elements, plus a standalone `decode<Pascal>` that
// delegates. Always closes the struct body (`};`). Caller has already emitted
// the struct opening and its fields, and confirmed fixedSizeOf == null.
fn emitVariableStructDecode(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    s: xcbproto.StructDef,
    pascal_name: []const u8,
) EmitError!void {
    var stop_index: usize = s.fields.len;
    for (s.fields, 0..) |sf, i| {
        if (fixedDecodeHalts(reg, p.header, sf, true)) {
            stop_index = i;
            break;
        }
    }
    const lists_decodable = stop_index < s.fields.len and s.fields[stop_index].kind == .list;
    if (!lists_decodable) {
        try w.writeAll("};\n\n");
        return;
    }

    // Scalars decoded in the fixed prefix (up to the first HALTING field) are
    // available as list-length sources. Literal-length lists in the prefix do not
    // halt, so scalars after them (e.g. KeySymMap's nSyms) are still collected.
    var avail_fields_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer avail_fields_list.deinit(gpa);
    for (s.fields) |sf| {
        if (fixedDecodeHalts(reg, p.header, sf, true)) break;
        if (sf.kind == .scalar) try avail_fields_list.append(gpa, sf.name);
    }
    const scan = try prescanFixedFields(gpa, reg, p.header, s.fields, .struct_elem);
    const scan_reads = scan[0];
    const any_list_decoded = willDecodeAnyList(reg, p, p.header, s.fields, false, avail_fields_list.items, false, false);
    // A struct-element list builds a ListView/StructIterator VALUE that now
    // carries `.endian = native_endian`, so such a decodeSized must declare
    // `const native_endian` even when its fixed prefix is all 1-byte fields
    // (unlike the reply decoder, decodeSized has no length-header read to anchor
    // native_endian). Scalar-element lists use bytesAsSlice and never reference it.
    const view_list = try listDecodeConstructsView(gpa, reg, p, p.header, s.fields, false, avail_fields_list.items, false, false);
    const needs_endian = scan[1] or view_list;

    // Name the outer struct explicitly: @This() in the return-type position
    // would bind to the anonymous result struct, not the element type. `endian`
    // is the byte order the elements are decoded in (native for a client, the
    // client's order for a server).
    try w.print("    pub fn decodeSized(bytes: []const u8, endian: std.builtin.Endian) struct {{ value: {s}, size: usize }} {{\n", .{pascal_name});
    if (needs_endian) {
        try w.writeAll("        const native_endian = endian;\n");
    } else {
        try w.writeAll("        _ = endian;\n");
    }
    try w.writeAll("        var result: @This() = std.mem.zeroes(@This());\n");
    const fixed_end_ = try emitFixedFieldDecodes(gpa, w, reg, p.header, s.fields, .struct_elem);
    if (any_list_decoded) {
        try w.print("        var list_off_: usize = {d};\n", .{fixed_end_});
        try emitListDecodes(gpa, w, reg, p, p.header, s.fields, false, avail_fields_list.items, "bytes.len", false, false);
        try w.writeAll("        return .{ .value = result, .size = list_off_ };\n");
    } else {
        if (!scan_reads) try w.writeAll("        _ = bytes;\n");
        try w.print("        return .{{ .value = result, .size = {d} }};\n", .{fixed_end_});
    }
    try w.writeAll("    }\n");
    try w.writeAll("};\n\n");

    // Client-facing standalone decoder: always native byte order.
    try w.print("pub fn decode{s}(bytes: []const u8) {s} {{\n", .{ pascal_name, pascal_name });
    try w.print("    return {s}.decodeSized(bytes, @import(\"builtin\").cpu.arch.endian()).value;\n", .{pascal_name});
    try w.writeAll("}\n\n");
}

// Returns true if the given field would halt `emitFixedFieldDecodes` BEFORE
// emitting it. This is the single authoritative halt predicate shared by
// both `emitFixedFieldDecodes` and the list-decodability gate below, so that
// the two passes can never drift apart.
fn fixedDecodeHalts(reg: *const registry.Registry, header: []const u8, f: xcbproto.Field, struct_elem: bool) bool {
    switch (f.kind) {
        .list => {
            // Inside a struct element, a literal-length fixed-scalar list is part
            // of the fixed prefix (emitFixedFieldDecodes decodes it inline) and does
            // NOT halt. Everywhere else (and any other list), it halts.
            if (!struct_elem) return true;
            const ll = f.list_len orelse return true;
            const is_literal = switch (ll.*) {
                .value => |v| v >= 0,
                else => false,
            };
            if (!is_literal) return true;
            const bt = reg.scalarBuiltin(header, f.type_ref) orelse return true;
            return zigWidthFromBuiltin(bt) == null; // float element halts; integer literal list does not
        },
        .fd, .exprfield, .switch_ => return true,
        .pad => return f.pad_align, // align-pad halts; byte-pad does not
        .scalar => {
            // A nested fixed struct decodes inline and does NOT halt.
            if (nestedFixedStructSize(reg, header, f) != null) return false;
            const zig_type = reg.scalarBuiltin(header, f.type_ref) orelse return true; // aggregate/unknown
            _ = zigWidthFromBuiltin(zig_type) orelse return true; // float
            return false;
        },
    }
}

// List length expression discriminant (kept for backward compat but no longer used
// in the reply-list-emission path; kept because it is cheap and harmless).
const ListLen = union(enum) { none, literal: u64, fieldref: []const u8 };

fn exprToSimpleLen(e: ?*const xcbproto.Expr) ListLen {
    const ex = e orelse return .none;
    return switch (ex.*) {
        .value => |v| .{ .literal = @intCast(v) },
        .fieldref => |f| .{ .fieldref = f },
        else => .none,
    };
}

// Same-protocol enum item value (is_bit aware). Returns the numeric mask/value
// for cond.item within cond.enum_name, or null if the enum/item is not found in p.
fn enumCondValue(p: *const xcbproto.Protocol, cond: xcbproto.EnumCond) ?i64 {
    for (p.enums) |en| {
        if (!std.mem.eql(u8, en.name, cond.enum_name)) continue;
        for (en.items) |item| {
            if (std.mem.eql(u8, item.name, cond.item))
                return if (item.is_bit) (@as(i64, 1) << @intCast(item.value)) else item.value;
        }
    }
    return null;
}

// A switch is TYPABLE by this task iff every bitcase has EXACTLY ONE field, that
// field is a fixed scalar (scalarBuiltin non-null, not float), and every cond
// resolves same-protocol. (Task 3 adds multi-field + imported.) Conservative:
// any deviation (multi-field bitcase, aggregate field, unresolved cond) -> false,
// which keeps the safe `values_` fallback and always compiles.
fn switchTypable(
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    header: []const u8,
    sw: *const xcbproto.Switch,
) bool {
    if (sw.bitcases.len == 0) return false;
    for (sw.bitcases) |bc| {
        if (bc.fields.len != 1) return false;
        const f = bc.fields[0];
        if (f.kind != .scalar) return false;
        const zt = reg.scalarBuiltin(header, f.type_ref) orelse return false;
        if (std.mem.eql(u8, zt, "f32") or std.mem.eql(u8, zt, "f64")) return false;
        // Value-list entries are packed as 4-byte words; a field wider than 4
        // bytes cannot fit the slot, so such a switch stays non-typable.
        if ((zigWidthFromBuiltin(zt) orelse 0) > 4) return false;
        if (bc.conds.len == 0) return false;
        for (bc.conds) |c| if (enumCondValue(p, c) == null) return false;
    }
    return true;
}

// Number of value fields (non-pad) a bitcase carries.
fn bitcaseValueFieldCount(bc: xcbproto.Bitcase) usize {
    var n: usize = 0;
    for (bc.fields) |f| {
        if (f.kind != .pad) n += 1;
    }
    return n;
}

// How a bitcase field maps into a structured ValueList and its packing.
//   scalar      -> a fixed scalar, packed as its native bytes
//   scalar_list -> a list of a fixed scalar element, `[]const T`, sliceAsBytes
//   raw_list    -> a list whose element is not a plain scalar (a struct, whose
//                  Zig layout is not wire-identical), taken as raw `[]const u8`
//   pad         -> an alignment/byte pad, advances the cursor only
const VlFieldKind = enum { scalar, scalar_list, raw_list, pad };

fn vlFieldKind(reg: *const registry.Registry, header: []const u8, f: xcbproto.Field) VlFieldKind {
    if (f.kind == .pad) return .pad;
    if (f.kind == .list) {
        const bt = reg.scalarBuiltin(header, f.type_ref);
        const fixed_scalar = bt != null and
            !(std.mem.eql(u8, bt.?, "f32") or std.mem.eql(u8, bt.?, "f64"));
        return if (fixed_scalar) .scalar_list else .raw_list;
    }
    return .scalar;
}

// Emit the ValueList type for one bitcase field: T | []const ElemT | []const u8.
fn emitVlFieldType(w: *std.Io.Writer, reg: *const registry.Registry, header: []const u8, f: xcbproto.Field) EmitError!void {
    switch (vlFieldKind(reg, header, f)) {
        .scalar => try emitZigType(w, reg, header, f.type_ref),
        .scalar_list => {
            try w.writeAll("[]const ");
            try emitZigType(w, reg, header, f.type_ref);
        },
        .raw_list => try w.writeAll("[]const u8"),
        .pad => {},
    }
}

fn bitcaseHasList(bc: xcbproto.Bitcase) bool {
    for (bc.fields) |f| {
        if (f.kind == .list) return true;
    }
    return false;
}

// Emit the access to one bitcase field from the captured optional `v_`: the
// value itself when the bitcase is single-field, else `v_.<name>`.
fn emitVlAccess(w: *std.Io.Writer, f: xcbproto.Field, single: bool) EmitError!void {
    if (single) {
        try w.writeAll("v_");
    } else {
        try w.writeAll("v_.");
        try writeIdent(w, f.name);
    }
}

// A switch is STRUCTURED-encodable when it is not a plain 4-byte value-list
// (that is switchTypable's job) but every bitcase is fixed scalars with
// resolvable conds, and at least one bitcase carries more than one value field.
// Packed at natural size, one optional per bitcase (single field -> ?T, multi
// field -> ?struct). Used for switches like xkb SelectEvents. Lists inside
// bitcases are a later increment and disqualify the switch here.
fn switchStructured(
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    header: []const u8,
    sw: *const xcbproto.Switch,
) bool {
    if (sw.bitcases.len == 0) return false;
    var has_list_or_multi = false;
    for (sw.bitcases) |bc| {
        if (bc.conds.len == 0) return false;
        for (bc.conds) |c| if (enumCondValue(p, c) == null) return false;
        var vcount: usize = 0;
        for (bc.fields) |f| {
            switch (f.kind) {
                .scalar => {
                    const zt = reg.scalarBuiltin(header, f.type_ref) orelse return false;
                    if (std.mem.eql(u8, zt, "f32") or std.mem.eql(u8, zt, "f64")) return false;
                    vcount += 1;
                },
                // Lists are packable: a fixed-scalar element becomes a typed
                // []const T; anything else is taken as raw []const u8.
                .list => vcount += 1,
                .pad => {},
                else => return false, // nested switch/exprfield inside a bitcase: not yet
            }
        }
        if (vcount == 0) return false;
        if (vcount > 1 or bitcaseHasList(bc)) has_list_or_multi = true;
    }
    // Only genuinely structured switches (multi-field or list bitcases) take this
    // path. An all-single-scalar switch is the value-list shape: switchTypable
    // handles the <=4-byte case and wider ones stay passthrough, unchanged.
    return has_list_or_multi;
}

// Write the ValueList optional name for a structured bitcase into w: the single
// value field's own name, or the first cond item (snake) when multi-field.
fn emitStructuredOptName(w: *std.Io.Writer, bc: xcbproto.Bitcase, buf: []u8) EmitError!void {
    if (bitcaseValueFieldCount(bc) == 1) {
        for (bc.fields) |f| {
            if (f.kind != .pad) {
                try writeIdent(w, f.name);
                return;
            }
        }
    }
    try writeIdent(w, toSnake(bc.conds[0].item, buf));
}

// --- Reply/struct-side switch DECODE (the read counterpart of the structured
// encode switch). A switch is decodable when its mask is an already-decoded
// field and every bitcase field is a fixed scalar or a fixed-scalar-element list
// whose length is resolvable: a literal, a fieldref to a decoded field, or a
// sumof of a list decoded earlier in the same bitcase. ---

fn isFieldAvail(name: []const u8, avail_fields: []const []const u8) bool {
    for (avail_fields) |af| {
        if (std.mem.eql(u8, af, name)) return true;
    }
    return false;
}

// Is a switch list-length expression resolvable at decode time? `prior` are the
// list fields decoded earlier in the same bitcase (targets for sumof).
fn switchLenAvailable(p: *const xcbproto.Protocol, e: *const xcbproto.Expr, avail_fields: []const []const u8, prior: []const xcbproto.Field) bool {
    return switch (e.*) {
        .value, .bit => true,
        .fieldref => |name| blk: {
            if (isFieldAvail(name, avail_fields)) break :blk true;
            // A scalar decoded earlier in this bitcase (e.g. nSIRtrn before si_rtrn).
            for (prior) |pf| {
                if (pf.kind == .scalar and std.mem.eql(u8, pf.name, name)) break :blk true;
            }
            break :blk false;
        },
        .sumof => |s| blk: {
            for (prior) |pf| {
                if (pf.kind == .list and std.mem.eql(u8, pf.name, s.list_ref)) break :blk (s.inner == null);
            }
            break :blk false;
        },
        .op => |o| switchLenAvailable(p, o.lhs, avail_fields, prior) and switchLenAvailable(p, o.rhs, avail_fields, prior),
        .unop => |o| switchLenAvailable(p, o.operand, avail_fields, prior),
        .popcount => |c| switchLenAvailable(p, c, avail_fields, prior),
        else => false,
    };
}

fn switchDecodable(reg: *const registry.Registry, p: *const xcbproto.Protocol, header: []const u8, sw: *const xcbproto.Switch, avail_fields: []const []const u8) bool {
    if (sw.bitcases.len == 0) return false;
    if (!isFieldAvail(sw.mask_fieldref, avail_fields)) return false;
    for (sw.bitcases) |bc| {
        if (bc.conds.len == 0) return false;
        for (bc.conds) |c| if (enumCondValue(p, c) == null) return false;
        var vcount: usize = 0;
        for (bc.fields, 0..) |f, fi| {
            switch (f.kind) {
                .scalar => {
                    if (reg.scalarBuiltin(header, f.type_ref)) |zt| {
                        if (zigWidthFromBuiltin(zt) == null) return false; // float
                    } else if (fixedStructElemSize(reg, header, f.type_ref) == null and
                        !variableDecodableStruct(reg, header, f.type_ref))
                    {
                        return false; // a nested field that is neither fixed nor variable-decodable
                    }
                    vcount += 1;
                },
                .list => {
                    const bt = reg.scalarBuiltin(header, f.type_ref);
                    const scalar_ok = if (bt) |z| (zigWidthFromBuiltin(z) != null) else false;
                    const fixed_struct_ok = !scalar_ok and fixedStructElemSize(reg, header, f.type_ref) != null;
                    const var_struct_ok = !scalar_ok and !fixed_struct_ok and variableDecodableStruct(reg, header, f.type_ref);
                    if (!scalar_ok and !fixed_struct_ok and !var_struct_ok) return false;
                    const ll = f.list_len orelse return false;
                    if (!switchLenAvailable(p, ll, avail_fields, bc.fields[0..fi])) return false;
                    vcount += 1;
                },
                .pad => {},
                else => return false,
            }
        }
        if (vcount == 0) return false;
    }
    return true;
}

// Decode-side value-list field type: scalar -> T, scalar-list -> []align(1) const
// T, fixed-struct/union list -> ListView(T).
fn emitDecodeVlType(w: *std.Io.Writer, reg: *const registry.Registry, header: []const u8, f: xcbproto.Field) EmitError!void {
    if (f.kind == .list) {
        const bt = reg.scalarBuiltin(header, f.type_ref);
        const scalar = if (bt) |z| (zigWidthFromBuiltin(z) != null) else false;
        if (scalar) {
            try w.writeAll("[]align(1) const ");
            try emitZigType(w, reg, header, f.type_ref);
        } else if (fixedStructElemSize(reg, header, f.type_ref) != null) {
            try w.writeAll("ListView(");
            try emitZigType(w, reg, header, f.type_ref);
            try w.writeAll(")");
        } else {
            try w.writeAll("StructIterator(");
            try emitZigType(w, reg, header, f.type_ref);
            try w.writeAll(")");
        }
    } else {
        try emitZigType(w, reg, header, f.type_ref);
    }
}

fn emitDecodeSwitchValues(w: *std.Io.Writer, reg: *const registry.Registry, header: []const u8, sw: *const xcbproto.Switch, pascal_name: []const u8) EmitError!void {
    try w.print("pub const {s}Values = struct {{\n", .{pascal_name});
    var nm_buf: [300]u8 = undefined;
    for (sw.bitcases) |bc| {
        try w.writeAll("    ");
        try emitStructuredOptName(w, bc, &nm_buf);
        if (bitcaseValueFieldCount(bc) == 1) {
            for (bc.fields) |f| {
                if (f.kind == .pad) continue;
                try w.writeAll(": ?");
                try emitDecodeVlType(w, reg, header, f);
                break;
            }
            try w.writeAll(" = null,\n");
        } else {
            try w.writeAll(": ?struct {\n");
            for (bc.fields) |f| {
                if (f.kind == .pad) continue;
                try w.writeAll("        ");
                try writeIdent(w, f.name);
                try w.writeAll(": ");
                try emitDecodeVlType(w, reg, header, f);
                try w.writeAll(",\n");
            }
            try w.writeAll("    } = null,\n");
        }
    }
    try w.writeAll("};\n\n");
}

// Emit a decode-time switch list-length expression (usize). fieldrefs read the
// decoded reply field; sumof sums a bitcase-local list var `l_<name>_`.
fn emitSwitchLen(w: *std.Io.Writer, e: *const xcbproto.Expr, avail_fields: []const []const u8) EmitError!void {
    switch (e.*) {
        .value => |v| try w.print("@as(usize, {d})", .{v}),
        .bit => |n| try w.print("(@as(usize, 1) << {d})", .{n}),
        .fieldref => |name| {
            // A reply field reads result.<name>; a bitcase-local scalar reads its
            // local `l_<name>_`.
            try w.writeAll("@as(usize, @intCast(");
            if (isFieldAvail(name, avail_fields)) {
                try w.writeAll("result.");
                try writeIdent(w, name);
            } else {
                try w.writeAll("l_");
                try writeIdent(w, name);
                try w.writeAll("_");
            }
            try w.writeAll("))");
        },
        .sumof => |s| {
            try w.writeAll("blk_so_: { var s_: usize = 0; for (l_");
            try writeIdent(w, s.list_ref);
            try w.writeAll("_) |e_| { s_ += @as(usize, @intCast(e_)); } break :blk_so_ s_; }");
        },
        .op => |o| {
            const zig_op: []const u8 = if (std.mem.eql(u8, o.operator, "+")) "+" else if (std.mem.eql(u8, o.operator, "-")) "-" else if (std.mem.eql(u8, o.operator, "*")) "*" else if (std.mem.eql(u8, o.operator, "/")) "/" else if (std.mem.eql(u8, o.operator, "&")) "&" else if (std.mem.eql(u8, o.operator, "|")) "|" else if (std.mem.eql(u8, o.operator, "<<")) "<<" else if (std.mem.eql(u8, o.operator, ">>")) ">>" else "+";
            try w.writeAll("(");
            try emitSwitchLen(w, o.lhs, avail_fields);
            try w.print(" {s} ", .{zig_op});
            try emitSwitchLen(w, o.rhs, avail_fields);
            try w.writeAll(")");
        },
        .unop => |o| {
            if (std.mem.eql(u8, o.operator, "~")) try w.writeAll("~");
            try w.writeAll("(");
            try emitSwitchLen(w, o.operand, avail_fields);
            try w.writeAll(")");
        },
        .popcount => |c| {
            try w.writeAll("@popCount(");
            try emitSwitchLen(w, c, avail_fields);
            try w.writeAll(")");
        },
        else => try w.writeAll("@as(usize, 0)"),
    }
}

// Emit the decode of a switch into result.values, driven by the decoded mask
// field. Assumes `list_off_`, `bytes`, `native_endian`, and `result` are in scope.
fn emitDecodeSwitch(w: *std.Io.Writer, reg: *const registry.Registry, p: *const xcbproto.Protocol, header: []const u8, sw: *const xcbproto.Switch, avail_fields: []const []const u8) EmitError!void {
    var nm_buf: [300]u8 = undefined;
    for (sw.bitcases) |bc| {
        var mask_or: i64 = 0;
        for (bc.conds) |c| mask_or |= enumCondValue(p, c).?;
        try w.writeAll("    if ((result.");
        try writeIdent(w, sw.mask_fieldref);
        try w.print(" & {d}) != 0) {{\n", .{mask_or});
        for (bc.fields) |f| {
            switch (f.kind) {
                .scalar => {
                    if (reg.scalarBuiltin(header, f.type_ref)) |zt| {
                        // plain scalar
                        const wdt = zigWidthFromBuiltin(zt).?;
                        try w.writeAll("        const l_");
                        try writeIdent(w, f.name);
                        try w.print("_: {s} = ", .{zt});
                        if (wdt == 1) {
                            if (std.mem.eql(u8, zt, "bool")) {
                                try w.writeAll("if (list_off_ < bytes.len) (bytes[list_off_] != 0) else false;\n");
                            } else {
                                try w.print("if (list_off_ < bytes.len) @bitCast(bytes[list_off_]) else 0;\n", .{});
                            }
                        } else {
                            try w.print("if (list_off_ + {d} <= bytes.len) std.mem.readInt({s}, bytes[list_off_..][0..{d}], native_endian) else 0;\n", .{ wdt, zt, wdt });
                        }
                        try w.print("        list_off_ += {d};\n", .{wdt});
                    } else if (fixedStructElemSize(reg, header, f.type_ref)) |sz| {
                        // nested fixed struct field: decode inline via decodeElement
                        try w.writeAll("        const l_");
                        try writeIdent(w, f.name);
                        try w.writeAll("_: ");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.print(" = if (list_off_ + {d} <= bytes.len) ", .{sz});
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(".decodeElement(bytes[list_off_..], native_endian) else std.mem.zeroes(");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(");\n");
                        try w.print("        list_off_ += {d};\n", .{sz});
                    } else {
                        // nested variable struct field: decode inline via decodeSized
                        try w.writeAll("        var l_");
                        try writeIdent(w, f.name);
                        try w.writeAll("_: ");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(" = std.mem.zeroes(");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(");\n");
                        try w.writeAll("        if (list_off_ <= bytes.len) {\n");
                        try w.writeAll("            const ds_ = ");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(".decodeSized(bytes[list_off_..], native_endian);\n");
                        try w.writeAll("            l_");
                        try writeIdent(w, f.name);
                        try w.writeAll("_ = ds_.value;\n");
                        try w.writeAll("            list_off_ += ds_.size;\n");
                        try w.writeAll("        }\n");
                    }
                },
                .list => {
                    const bt = reg.scalarBuiltin(header, f.type_ref);
                    const scalar = if (bt) |z| (zigWidthFromBuiltin(z) != null) else false;
                    // fixed_sz null => a variable-size struct element (StructIterator).
                    const fixed_sz: ?usize = if (scalar) zigWidthFromBuiltin(bt.?).? else fixedStructElemSize(reg, header, f.type_ref);
                    // `l_<name>_` is declared outside the sizing block so it stays in
                    // scope for the value assignment and for any later sumof.
                    try w.writeAll("        var l_");
                    try writeIdent(w, f.name);
                    if (scalar) {
                        try w.writeAll("_: []align(1) const ");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(" = &.{};\n");
                    } else if (fixed_sz != null) {
                        try w.writeAll("_: ListView(");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(") = .{};\n");
                    } else {
                        try w.writeAll("_: StructIterator(");
                        try emitZigType(w, reg, header, f.type_ref);
                        try w.writeAll(") = .{};\n");
                    }
                    try w.writeAll("        {\n");
                    try w.writeAll("            const n_ = ");
                    try emitSwitchLen(w, f.list_len.?, avail_fields);
                    try w.writeAll(";\n");
                    if (fixed_sz) |es| {
                        try w.print("            const need_ = std.math.mul(usize, n_, {d}) catch 0;\n", .{es});
                        try w.writeAll("            if (list_off_ + need_ <= bytes.len) l_");
                        try writeIdent(w, f.name);
                        if (scalar) {
                            try w.writeAll("_ = std.mem.bytesAsSlice(");
                            try emitZigType(w, reg, header, f.type_ref);
                            try w.writeAll(", bytes[list_off_..][0..need_]);\n");
                        } else {
                            try w.writeAll("_ = .{ .bytes = bytes[list_off_..][0..need_], .count = n_, .endian = native_endian };\n");
                        }
                        try w.writeAll("            list_off_ += need_;\n");
                    } else {
                        // Variable-size struct elements: walk by each element's size.
                        try w.writeAll("            if (list_off_ <= bytes.len) l_");
                        try writeIdent(w, f.name);
                        try w.writeAll("_ = .{ .bytes = bytes[list_off_..], .count = n_, .endian = native_endian };\n");
                        try w.writeAll("            list_off_ += l_");
                        try writeIdent(w, f.name);
                        try w.writeAll("_.byteLen();\n");
                    }
                    try w.writeAll("        }\n");
                },
                .pad => {
                    if (f.pad_align) {
                        try w.writeAll("        list_off_ = (list_off_ + 3) & ~@as(usize, 3);\n");
                    } else if (f.pad_bytes > 0) {
                        try w.print("        list_off_ += {d};\n", .{f.pad_bytes});
                    }
                },
                else => {},
            }
        }
        try w.writeAll("        result.values.");
        try emitStructuredOptName(w, bc, &nm_buf);
        try w.writeAll(" = ");
        if (bitcaseValueFieldCount(bc) == 1) {
            for (bc.fields) |f| {
                if (f.kind == .pad) continue;
                try w.writeAll("l_");
                try writeIdent(w, f.name);
                try w.writeAll("_");
                break;
            }
            try w.writeAll(";\n");
        } else {
            try w.writeAll(".{ ");
            for (bc.fields) |f| {
                if (f.kind == .pad) continue;
                try w.writeAll(".");
                try writeIdent(w, f.name);
                try w.writeAll(" = l_");
                try writeIdent(w, f.name);
                try w.writeAll("_, ");
            }
            try w.writeAll("};\n");
        }
        try w.writeAll("    }\n");
    }
}

// True if any bitcase field of a typable value-list switch (see switchTypable)
// is wider than 1 byte, i.e. its decode needs a `readInt(..., native_endian)`.
// All-1-byte switches (rare) let the caller skip declaring `native_endian` and
// avoid an unused-constant error.
fn switchValueListNeedsEndian(reg: *const registry.Registry, header: []const u8, sw: *const xcbproto.Switch) bool {
    for (sw.bitcases) |bc| {
        const zt = reg.scalarBuiltin(header, bc.fields[0].type_ref) orelse continue;
        if ((zigWidthFromBuiltin(zt) orelse 1) > 1) return true;
    }
    return false;
}

// Emit the decode of a request's typed value-list switch (the read
// counterpart of the request ENCODER's `mask_ |= N` / 4-byte-word packing
// above): read the already-decoded mask field, then for each bitcase in bit
// order, if its bit is set, read a 4-byte value-list slot into the matching
// `<vl_field_name>` optional. Every slot is a full CARD32 regardless of the
// value's own width (the encoder always writes 4 bytes per entry), so the
// cursor always advances by 4 even when only the low bytes hold the value.
// Assumes `bytes`, `result`, and (if needed) `native_endian` are in scope;
// `fixed_end` is the byte offset right after the fixed fields (== the
// value-list base, since the switch is always the request's trailing field).
fn emitDecodeRequestValueList(
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    header: []const u8,
    sw: *const xcbproto.Switch,
    vl_field_name: []const u8,
    fixed_end: usize,
) EmitError!void {
    try w.print("    var vl_off_: usize = {d};\n", .{fixed_end});
    for (sw.bitcases) |bc| {
        const f = bc.fields[0];
        var mask_or: i64 = 0;
        for (bc.conds) |c| mask_or |= enumCondValue(p, c).?;
        const zt = reg.scalarBuiltin(header, f.type_ref).?; // guaranteed by switchTypable
        const width = zigWidthFromBuiltin(zt).?; // guaranteed by switchTypable (<=4, non-float)
        try w.print("    if ((result.{s} & {d}) != 0 and vl_off_ + 4 <= bytes.len) {{\n", .{ sw.mask_fieldref, mask_or });
        try w.writeAll("        result.");
        try writeIdent(w, vl_field_name);
        try w.writeAll(".");
        try writeIdent(w, f.name);
        try w.writeAll(" = ");
        if (width == 1) {
            if (std.mem.eql(u8, zt, "bool")) {
                try w.writeAll("bytes[vl_off_] != 0");
            } else if (std.mem.eql(u8, zt, "i8")) {
                try w.writeAll("@bitCast(bytes[vl_off_])");
            } else {
                try w.writeAll("bytes[vl_off_]");
            }
        } else {
            try w.print("std.mem.readInt({s}, bytes[vl_off_..][0..{d}], native_endian)", .{ zt, width });
        }
        try w.writeAll(";\n");
        try w.writeAll("        vl_off_ += 4;\n");
        try w.writeAll("    }\n");
    }
}

// Context for the expression evaluator / availability predicate.
const ExprCtx = struct {
    // True when decoding a reply (the `length` word at bytes[4..8] is valid).
    has_length_header: bool,
    // Declared scalar field names that have been decoded before the current list.
    avail_fields: []const []const u8,
    // Names of prior decodable lists (for sumof).
    avail_lists: []const []const u8,
    // True when we are inside a sumof inner expression (listelement_ref is valid).
    in_sumof: bool,
};

// Returns true if every input to expression `e` is available at decode time.
// Caller should pass a non-null expr; returns false for null (shouldn't happen
// but avoids a crash if the AST is malformed).
fn exprAvailable(
    p: *const xcbproto.Protocol,
    ctx: ExprCtx,
    e: *const xcbproto.Expr,
) bool {
    return switch (e.*) {
        .value, .bit => true,
        .fieldref => |name| blk: {
            if (std.mem.eql(u8, name, "length") and ctx.has_length_header) break :blk true;
            for (ctx.avail_fields) |af| {
                if (std.mem.eql(u8, af, name)) break :blk true;
            }
            break :blk false;
        },
        .enumref => |er| blk: {
            for (p.enums) |en| {
                if (!std.mem.eql(u8, en.name, er.enum_name)) continue;
                for (en.items) |item| {
                    if (std.mem.eql(u8, item.name, er.item)) break :blk true;
                }
            }
            break :blk false;
        },
        .op => |o| blk: {
            // Only support known Zig operators.
            const known = std.mem.eql(u8, o.operator, "+") or
                std.mem.eql(u8, o.operator, "-") or
                std.mem.eql(u8, o.operator, "*") or
                std.mem.eql(u8, o.operator, "/") or
                std.mem.eql(u8, o.operator, "&") or
                std.mem.eql(u8, o.operator, "|") or
                std.mem.eql(u8, o.operator, "<<") or
                std.mem.eql(u8, o.operator, ">>");
            if (!known) break :blk false;
            break :blk exprAvailable(p, ctx, o.lhs) and exprAvailable(p, ctx, o.rhs);
        },
        .unop => |o| std.mem.eql(u8, o.operator, "~") and exprAvailable(p, ctx, o.operand),
        .popcount => |c| exprAvailable(p, ctx, c),
        // sumof: treat as unavailable to avoid complex per-list branching at emit time.
        // No real xproto/xkb reply list length uses sumof.
        .sumof => false,
        .listelement_ref => ctx.in_sumof,
    };
}

// Emit a Zig `usize` expression for the length of a list. Caller MUST call
// exprAvailable first and only call this when it returns true.
fn emitLenExpr(
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    header: []const u8,
    ctx: ExprCtx,
    e: *const xcbproto.Expr,
) error{ OutOfMemory, WriteFailed }!void {
    switch (e.*) {
        .value => |v| try w.print("@as(usize, {d})", .{v}),
        .bit => |n| try w.print("(@as(usize, 1) << {d})", .{n}),
        .fieldref => |name| {
            if (std.mem.eql(u8, name, "length") and ctx.has_length_header) {
                // Reply context: the X11 reply length word lives at bytes[4..8].
                try w.writeAll("@as(usize, std.mem.readInt(u32, bytes[4..8], native_endian))");
            } else {
                // Struct context, OR any field other than the reply-header "length":
                // read from the already-decoded result field. Use a comptime-if to
                // handle bool fields (e.g. BOOL in xcbproto) which require
                // @intFromBool instead of @intCast.
                try w.writeAll("@as(usize, if (@TypeOf(result.");
                try writeIdent(w, name);
                try w.writeAll(") == bool) @intFromBool(result.");
                try writeIdent(w, name);
                try w.writeAll(") else @intCast(result.");
                try writeIdent(w, name);
                try w.writeAll("))");
            }
        },
        .enumref => |er| blk: {
            for (p.enums) |en| {
                if (!std.mem.eql(u8, en.name, er.enum_name)) continue;
                for (en.items) |item| {
                    if (std.mem.eql(u8, item.name, er.item)) {
                        const numeric: i64 = if (item.is_bit)
                            (@as(i64, 1) << @intCast(item.value))
                        else
                            item.value;
                        try w.print("@as(usize, {d})", .{numeric});
                        break :blk;
                    }
                }
            }
        },
        .op => |o| {
            const zig_op: []const u8 = if (std.mem.eql(u8, o.operator, "+")) "+" else if (std.mem.eql(u8, o.operator, "-")) "-" else if (std.mem.eql(u8, o.operator, "*")) "*" else if (std.mem.eql(u8, o.operator, "/")) "/" else if (std.mem.eql(u8, o.operator, "&")) "&" else if (std.mem.eql(u8, o.operator, "|")) "|" else if (std.mem.eql(u8, o.operator, "<<")) "<<" else if (std.mem.eql(u8, o.operator, ">>")) ">>" else "+"; // fallback (exprAvailable guards this)
            try w.writeAll("(");
            try emitLenExpr(w, reg, p, header, ctx, o.lhs);
            try w.print(" {s} ", .{zig_op});
            try emitLenExpr(w, reg, p, header, ctx, o.rhs);
            try w.writeAll(")");
        },
        .unop => |o| {
            if (std.mem.eql(u8, o.operator, "~")) {
                try w.writeAll("(~");
                try emitLenExpr(w, reg, p, header, ctx, o.operand);
                try w.writeAll(")");
            }
        },
        .popcount => |c| {
            try w.writeAll("@popCount(");
            try emitLenExpr(w, reg, p, header, ctx, c);
            try w.writeAll(")");
        },
        // sumof and listelement_ref: guarded by exprAvailable (sumof -> false).
        .sumof, .listelement_ref => {},
    }
}

// Emit an ENCODE-time expression for an exprfield's computed value. A
// `<list>_len` fieldref maps to that list's runtime `.len`; any other fieldref is
// a request parameter of the same name; operators mirror emitLenExpr. Produces a
// `usize` expression the caller casts to the field's width.
fn emitEncodeExpr(
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    header: []const u8,
    fields: []const xcbproto.Field,
    e: *const xcbproto.Expr,
) EmitError!void {
    switch (e.*) {
        .value => |v| try w.print("@as(usize, {d})", .{v}),
        .bit => |n| try w.print("(@as(usize, 1) << {d})", .{n}),
        .fieldref => |name| {
            if (std.mem.endsWith(u8, name, "_len")) {
                const base = name[0 .. name.len - 4];
                for (fields) |f| {
                    if (f.kind == .list and std.mem.eql(u8, f.name, base)) {
                        // A `<list>_len` is the ELEMENT count. A scalar-element list
                        // is passed as `[]const T`, so its .len is the count. A
                        // struct/multi-byte-element list is passed as raw `[]const u8`,
                        // so the count is .len / element-wire-size.
                        const bt = reg.scalarBuiltin(header, f.type_ref);
                        const scalar_elem = bt != null and
                            !(std.mem.eql(u8, bt.?, "f32") or std.mem.eql(u8, bt.?, "f64"));
                        try writeIdent(w, base);
                        if (scalar_elem) {
                            try w.writeAll(".len");
                        } else {
                            const sz = fixedStructElemSize(reg, header, f.type_ref) orelse 1;
                            try w.print(".len / {d}", .{sz});
                        }
                        return;
                    }
                }
            }
            try writeIdent(w, name);
        },
        .op => |o| {
            const zig_op: []const u8 = if (std.mem.eql(u8, o.operator, "+")) "+" else if (std.mem.eql(u8, o.operator, "-")) "-" else if (std.mem.eql(u8, o.operator, "*")) "*" else if (std.mem.eql(u8, o.operator, "/")) "/" else if (std.mem.eql(u8, o.operator, "&")) "&" else if (std.mem.eql(u8, o.operator, "|")) "|" else if (std.mem.eql(u8, o.operator, "<<")) "<<" else if (std.mem.eql(u8, o.operator, ">>")) ">>" else "+";
            try w.writeAll("(");
            try emitEncodeExpr(w, reg, header, fields, o.lhs);
            try w.print(" {s} ", .{zig_op});
            try emitEncodeExpr(w, reg, header, fields, o.rhs);
            try w.writeAll(")");
        },
        .unop => |o| {
            if (std.mem.eql(u8, o.operator, "~")) try w.writeAll("~");
            try w.writeAll("(");
            try emitEncodeExpr(w, reg, header, fields, o.operand);
            try w.writeAll(")");
        },
        .popcount => |c| {
            try w.writeAll("@popCount(");
            try emitEncodeExpr(w, reg, header, fields, c);
            try w.writeAll(")");
        },
        else => try w.writeAll("@as(usize, 0)"),
    }
}

// Returns true if the expression (or any sub-expression) references the `length`
// header field. Used to decide whether to force emission of `const native_endian`.
fn exprUsesLength(e: *const xcbproto.Expr) bool {
    return switch (e.*) {
        .fieldref => |name| std.mem.eql(u8, name, "length"),
        .op => |o| exprUsesLength(o.lhs) or exprUsesLength(o.rhs),
        .unop => |o| exprUsesLength(o.operand),
        .popcount => |c| exprUsesLength(c),
        .sumof => |s| if (s.inner) |i| exprUsesLength(i) else false,
        else => false,
    };
}

/// Register `name` as an emitted top-level decl. Returns true if it was already
/// present (caller should skip re-emitting). Stores an owned dupe of the key.
fn markEmitted(
    gpa: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) EmitError!bool {
    if (set.contains(name)) return true;
    const owned = try gpa.dupe(u8, name);
    errdefer gpa.free(owned);
    try set.put(gpa, owned, {});
    return false;
}

// Returns true if emitListDecodes would emit at least one actual list decode block
// (i.e. at least one list has a decodable element type AND an available length
// expression). Used by callers to decide whether `var list_off_` is needed.
//
// allow_implicit_len: some requests (PolyPoint, PolyLine, PolySegment, ... - the
// core "Poly*" drawing family) declare their trailing list with NO length child
// at all: the wire count is implied by the request's own total byte length,
// not by any sibling field. When true, a list with `list_len == null` that is
// the LAST field (so every remaining byte unambiguously belongs to it) and
// whose element has a fixed stride (scalar or fixed-size struct - a variable
// struct element has no stride to derive a count from) is still decodable;
// emitListDecodes then computes its count from `limit_ - list_off_` instead of
// an XML expr. Reply/struct-element callers pass false: every list they
// support carries a real XML length (an explicit count field), so this path
// never triggers for them.
fn willDecodeAnyList(
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    header: []const u8,
    fields: []const xcbproto.Field,
    ctx_has_length_header: bool,
    avail_fields: []const []const u8,
    scalar_only: bool,
    allow_implicit_len: bool,
) bool {
    for (fields, 0..) |rf, i| {
        if (rf.kind != .list) continue;
        const maybe_bt = reg.scalarBuiltin(header, rf.type_ref);
        const is_fixed_scalar_elem = blk: {
            const bt = maybe_bt orelse break :blk false;
            if (std.mem.eql(u8, bt, "f32") or std.mem.eql(u8, bt, "f64")) break :blk false;
            break :blk true;
        };
        if (scalar_only and !is_fixed_scalar_elem) return false; // struct element: caller defers, stop
        const maybe_struct_size = if (!is_fixed_scalar_elem)
            fixedStructElemSize(reg, header, rf.type_ref)
        else
            null;
        const is_var_struct_elem = !is_fixed_scalar_elem and maybe_struct_size == null and
            variableDecodableStruct(reg, header, rf.type_ref);
        if (!is_fixed_scalar_elem and maybe_struct_size == null and !is_var_struct_elem) return false; // stop
        if (is_fixed_scalar_elem) {
            const bt = maybe_bt.?;
            _ = zigWidthFromBuiltin(bt) orelse return false; // float-like stride, stop
        }
        if (rf.list_len) |expr| {
            const ectx = ExprCtx{
                .has_length_header = ctx_has_length_header,
                .avail_fields = avail_fields,
                .avail_lists = &.{},
                .in_sumof = false,
            };
            if (!exprAvailable(p, ectx, expr)) return false;
            return true; // at least the first list is decodable
        }
        if (allow_implicit_len and i == fields.len - 1 and !is_var_struct_elem) return true;
        return false;
    }
    return false;
}

// Returns true iff emitListDecodes (given the same args) would emit at least one
// ListView/StructIterator VALUE construction, i.e. a struct-element list. Those
// literals now carry `.endian = native_endian`, so any decoder that emits one
// must have `const native_endian` in scope. Mirrors emitListDecodes' per-list
// gating exactly (same halt/skip/stop conditions and order) so the two agree.
// Scalar-element lists decode via bytesAsSlice and never reference native_endian,
// so they do not count here.
fn listDecodeConstructsView(
    gpa: std.mem.Allocator,
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    header: []const u8,
    fields: []const xcbproto.Field,
    ctx_has_length_header: bool,
    avail_fields: []const []const u8,
    scalar_only: bool,
    allow_implicit_len: bool,
) EmitError!bool {
    var avail_lists_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer avail_lists_list.deinit(gpa);
    for (fields, 0..) |rf, i| {
        if (rf.kind != .list) continue;
        // Mirror emitListDecodes: a struct-element literal-length fixed-scalar list
        // is part of the fixed prefix (already decoded); skip it here.
        if (!ctx_has_length_header and !fixedDecodeHalts(reg, header, rf, true)) continue;
        const maybe_bt = reg.scalarBuiltin(header, rf.type_ref);
        const is_fixed_scalar_elem = blk: {
            const bt = maybe_bt orelse break :blk false;
            if (std.mem.eql(u8, bt, "f32") or std.mem.eql(u8, bt, "f64")) break :blk false;
            break :blk true;
        };
        const maybe_struct_size = if (!is_fixed_scalar_elem)
            fixedStructElemSize(reg, header, rf.type_ref)
        else
            null;
        const is_var_struct_elem = !is_fixed_scalar_elem and maybe_struct_size == null and
            variableDecodableStruct(reg, header, rf.type_ref);
        if (!is_fixed_scalar_elem and maybe_struct_size == null and !is_var_struct_elem) return false; // unknown: stop
        if (scalar_only and !is_fixed_scalar_elem) return false; // deferred: stop
        if (rf.list_len) |expr| {
            const ectx = ExprCtx{
                .has_length_header = ctx_has_length_header,
                .avail_fields = avail_fields,
                .avail_lists = avail_lists_list.items,
                .in_sumof = false,
            };
            if (!exprAvailable(p, ectx, expr)) return false;
            if (!is_fixed_scalar_elem) return true; // a ListView/StructIterator is constructed
            try avail_lists_list.append(gpa, rf.name);
            continue;
        }
        // No explicit length expr: see willDecodeAnyList's allow_implicit_len doc.
        if (allow_implicit_len and i == fields.len - 1 and !is_var_struct_elem) {
            if (!is_fixed_scalar_elem) return true; // a ListView is constructed
            continue; // scalar element, nothing follows: no view, no avail_lists entry needed
        }
        return false;
    }
    return false;
}

// Emit per-list decode blocks for a slice of fields. Caller must have already
// emitted `var list_off_: usize = <base>;` and (for reply) `const reply_total_ = ...;`.
// ctx_has_length_header: true for reply decoders, false for struct decoders.
// avail_fields: scalar field names decoded before this point (for exprAvailable).
// limit_expr: the expression used as the limit bound ("reply_total_" or "bytes.len").
// scalar_only: when true, a struct-element list (fixed ListView or variable
// StructIterator) is left unfilled (safe-fallback TODO, same as an unknown
// element type) instead of being decoded. All current callers (reply, struct,
// and request decoders) pass false; scalar_only exists so a future caller can
// still defer struct-element lists if it needs to.
// allow_implicit_len: see willDecodeAnyList's doc comment. When the trailing
// list has no XML length expr, is the last field, and has a fixed per-element
// stride, its count is computed from `limit_ - list_off_` instead of an expr.
fn emitListDecodes(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    reg: *const registry.Registry,
    p: *const xcbproto.Protocol,
    header: []const u8,
    fields: []const xcbproto.Field,
    ctx_has_length_header: bool,
    avail_fields: []const []const u8,
    limit_expr: []const u8,
    scalar_only: bool,
    allow_implicit_len: bool,
) EmitError!void {
    var avail_lists_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer avail_lists_list.deinit(gpa);

    var seen_list_ = false;
    for (fields, 0..) |rf, field_i| {
        if (rf.kind == .pad) {
            // Pads in the list region (after the first list) advance the cursor.
            // Fixed-header pads before any list were already consumed by the
            // fixed pass, so skip those. xcbproto align-pads in the core
            // protocols align to 4 bytes.
            if (seen_list_) {
                if (rf.pad_align) {
                    try w.writeAll("        list_off_ = (list_off_ + 3) & ~@as(usize, 3);\n");
                } else if (rf.pad_bytes > 0) {
                    try w.print("        list_off_ += {d};\n", .{rf.pad_bytes});
                }
            }
            continue;
        }
        if (rf.kind != .list) continue;
        // In a struct element, a literal-length fixed-scalar list is part of the
        // fixed prefix (already decoded and counted in fixed_end_); skip it here so
        // it is not decoded twice at the wrong offset.
        if (!ctx_has_length_header and !fixedDecodeHalts(reg, header, rf, true)) continue;
        seen_list_ = true;
        // Determine element kind: fixed scalar, fixed struct, or variable struct.
        const maybe_bt = reg.scalarBuiltin(header, rf.type_ref);
        const is_fixed_scalar_elem = blk: {
            const bt = maybe_bt orelse break :blk false;
            if (std.mem.eql(u8, bt, "f32") or std.mem.eql(u8, bt, "f64")) break :blk false;
            break :blk true;
        };
        const maybe_struct_size = if (!is_fixed_scalar_elem)
            fixedStructElemSize(reg, header, rf.type_ref)
        else
            null;
        const is_var_struct_elem = !is_fixed_scalar_elem and maybe_struct_size == null and
            variableDecodableStruct(reg, header, rf.type_ref);
        if (!is_fixed_scalar_elem and maybe_struct_size == null and !is_var_struct_elem) {
            // Unknown element type: safe-fallback, stop.
            try w.writeAll("    // TODO(slice4+): unavailable list length for ");
            try writeIdent(w, rf.name);
            try w.writeAll("\n");
            break;
        }
        if (scalar_only and !is_fixed_scalar_elem) {
            // Struct-element list (fixed ListView or variable StructIterator):
            // deferred for this caller, safe-fallback, stop.
            try w.writeAll("    // TODO(slice4+): struct-element list deferred for ");
            try writeIdent(w, rf.name);
            try w.writeAll("\n");
            break;
        }

        // The element-count expression is required for every element kind,
        // unless this is a trailing implicit-length list (see doc comment).
        const implicit_ok = rf.list_len == null and allow_implicit_len and
            field_i == fields.len - 1 and !is_var_struct_elem;
        if (rf.list_len == null and !implicit_ok) {
            try w.writeAll("    // TODO(slice4+): unavailable list length for ");
            try writeIdent(w, rf.name);
            try w.writeAll("\n");
            break;
        }
        const ectx = ExprCtx{
            .has_length_header = ctx_has_length_header,
            .avail_fields = avail_fields,
            .avail_lists = avail_lists_list.items,
            .in_sumof = false,
        };
        if (rf.list_len) |expr| {
            if (!exprAvailable(p, ectx, expr)) {
                try w.writeAll("    // TODO(slice4+): unavailable list length for ");
                try writeIdent(w, rf.name);
                try w.writeAll("\n");
                break;
            }
        }

        try w.writeAll("    {\n");
        if (implicit_ok) {
            // No XML length expr: this is the sole trailing list (the last
            // field), so every remaining byte belongs to it. Derive the count
            // from the fixed per-element stride instead of an expr.
            const elem_stride: usize = if (is_fixed_scalar_elem)
                (zigWidthFromBuiltin(maybe_bt.?) orelse 0)
            else
                maybe_struct_size.?;
            try w.print("        const stride_: usize = {d};\n", .{elem_stride});
            if (std.mem.eql(u8, limit_expr, "bytes.len")) {
                try w.writeAll("        const limit_ = bytes.len;\n");
            } else {
                try w.print("        const limit_ = @min(bytes.len, {s});\n", .{limit_expr});
            }
            try w.writeAll("        const n_: usize = if (limit_ > list_off_) (limit_ - list_off_) / stride_ else 0;\n");
        } else {
            try w.writeAll("        const n_: usize = ");
            try emitLenExpr(w, reg, p, header, ectx, rf.list_len.?);
            try w.writeAll(";\n");
            if (std.mem.eql(u8, limit_expr, "bytes.len")) {
                try w.writeAll("        const limit_ = bytes.len;\n");
            } else {
                try w.print("        const limit_ = @min(bytes.len, {s});\n", .{limit_expr});
            }
        }

        if (is_var_struct_elem) {
            // Variable-size struct elements have no fixed stride: bind a
            // StructIterator over the remaining bytes and advance list_off_ by
            // the bytes the count elements actually occupy (via byteLen).
            try w.writeAll("        if (list_off_ <= limit_) {\n");
            try w.writeAll("            result.");
            try writeIdent(w, rf.name);
            try w.writeAll(" = .{ .bytes = bytes[list_off_..limit_], .count = n_, .endian = native_endian };\n");
            try w.writeAll("            list_off_ += result.");
            try writeIdent(w, rf.name);
            try w.writeAll(".byteLen();\n");
            try w.writeAll("        }\n");
        } else {
            // Fixed-stride element: a zero-copy slice (scalar) or ListView (struct)
            // over exactly n_ * stride bytes.
            if (!implicit_ok) {
                const elem_stride: usize = if (is_fixed_scalar_elem)
                    (zigWidthFromBuiltin(maybe_bt.?) orelse 0)
                else
                    maybe_struct_size.?;
                try w.print("        const stride_: usize = {d};\n", .{elem_stride});
            }
            try w.writeAll("        const need_ = std.math.mul(usize, n_, stride_) catch 0;\n");
            try w.writeAll("        if (need_ > 0 and list_off_ + need_ <= limit_) {\n");
            try w.writeAll("            result.");
            try writeIdent(w, rf.name);
            if (is_fixed_scalar_elem) {
                try w.writeAll(" = std.mem.bytesAsSlice(");
                try emitZigType(w, reg, header, rf.type_ref);
                try w.writeAll(", bytes[list_off_..][0..need_]);\n");
            } else {
                try w.writeAll(" = .{ .bytes = bytes[list_off_..][0..need_], .count = n_, .endian = native_endian };\n");
            }
            try w.writeAll("        }\n");
            try w.writeAll("        list_off_ += need_;\n");
        }
        try w.writeAll("    }\n");

        // Mark this list as available for subsequent sumof.
        try avail_lists_list.append(gpa, rf.name);
    }
}

const ListElemKind = enum { scalar, char, structure, raw };

const RequestListInfo = struct {
    name: []const u8,
    elem_kind: ListElemKind,
    elem_zig: []const u8,
    stride: usize,
    count_field: ?[]const u8,
};

fn requestListPlan(
    gpa: std.mem.Allocator,
    reg: *const registry.Registry,
    header: []const u8,
    req: xcbproto.Request,
    out_lists: *std.ArrayListUnmanaged(RequestListInfo),
    out_derived: *std.StringHashMapUnmanaged(void),
) EmitError!void {
    for (req.fields) |field| {
        if (field.kind != .list) continue;

        const type_ref = field.type_ref;

        // Classify element kind.
        const is_char_type = std.mem.eql(u8, type_ref, "char") or
            std.mem.eql(u8, type_ref, "CHAR") or
            std.mem.eql(u8, type_ref, "STRING8");

        const elem_kind: ListElemKind = blk: {
            if (is_char_type) break :blk .char;

            if (reg.scalarBuiltin(header, type_ref)) |bt| {
                if (!std.mem.eql(u8, bt, "f32") and !std.mem.eql(u8, bt, "f64")) {
                    break :blk .scalar;
                }
            }

            if (fixedStructElemSize(reg, header, type_ref) != null) {
                break :blk .structure;
            }

            break :blk .raw;
        };

        const stride: usize = switch (elem_kind) {
            .char => 1,
            .scalar => blk: {
                const bt = reg.scalarBuiltin(header, type_ref).?;
                break :blk zigWidthFromBuiltin(bt) orelse 1;
            },
            .structure => fixedStructElemSize(reg, header, type_ref).?,
            .raw => 1,
        };

        // Determine count_field: only when list_len is exactly Expr{.fieldref = C}
        // AND C names a declared .scalar field in req.fields.
        var count_field: ?[]const u8 = null;
        if (field.list_len) |len_expr| {
            if (len_expr.* == .fieldref) {
                const cname = len_expr.fieldref;
                // Check if cname names a declared .scalar field.
                for (req.fields) |rf| {
                    if (rf.kind == .scalar and std.mem.eql(u8, rf.name, cname)) {
                        count_field = rf.name; // borrow from Protocol
                        break;
                    }
                }
                // Add to out_derived only for .scalar and .char lists.
                if (count_field != null and (elem_kind == .scalar or elem_kind == .char)) {
                    try out_derived.put(gpa, count_field.?, {});
                }
            }
        }

        try out_lists.append(gpa, .{
            .name = field.name,
            .elem_kind = elem_kind,
            .elem_zig = "",
            .stride = stride,
            .count_field = count_field,
        });
    }
}

pub fn generate(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    p: *const xcbproto.Protocol,
    reg: *const registry.Registry,
) EmitError!void {
    // 1. Preamble
    try w.print("const std = @import(\"std\");\n", .{});
    try w.print("const x11 = @import(\"x11\");\n", .{});
    for (p.imports) |imp| {
        try w.print("const {s} = @import(\"{s}\");\n", .{ imp, imp });
    }
    try w.print("\n", .{});

    if (p.extension_xname) |xname| {
        try w.print("pub const extension_xname = \"{s}\";\n\n", .{xname});
    }

    // ListView generic: zero-copy decode-on-access accessor for fixed-size struct element lists.
    // Emitted unconditionally (pub decls are never unused-errors in Zig).
    try w.writeAll("pub fn ListView(comptime T: type) type {\n");
    try w.writeAll("    return struct {\n");
    try w.writeAll("        bytes: []const u8 = &.{},\n");
    try w.writeAll("        count: usize = 0,\n");
    try w.writeAll("        endian: std.builtin.Endian = @import(\"builtin\").cpu.arch.endian(),\n");
    try w.writeAll("        pub fn len(self: @This()) usize { return self.count; }\n");
    try w.writeAll("        pub fn at(self: @This(), i: usize) T {\n");
    try w.writeAll("            return T.decodeElement(self.bytes[i * T.wire_size ..], self.endian);\n");
    try w.writeAll("        }\n");
    try w.writeAll("    };\n");
    try w.writeAll("}\n\n");

    // StructIterator generic: zero-copy decode-and-advance accessor for
    // variable-size struct element lists. Unlike ListView, elements have no
    // fixed stride, so each reports its own consumed byte count via
    // T.decodeSized; the iterator walks the borrowed buffer element by element.
    // No allocation. Consumers loop with next() rather than indexing.
    try w.writeAll("pub fn StructIterator(comptime T: type) type {\n");
    try w.writeAll("    return struct {\n");
    try w.writeAll("        bytes: []const u8 = &.{},\n");
    try w.writeAll("        count: usize = 0,\n");
    try w.writeAll("        offset: usize = 0,\n");
    try w.writeAll("        index: usize = 0,\n");
    try w.writeAll("        endian: std.builtin.Endian = @import(\"builtin\").cpu.arch.endian(),\n");
    try w.writeAll("        pub fn len(self: @This()) usize {\n");
    try w.writeAll("            return self.count;\n");
    try w.writeAll("        }\n");
    try w.writeAll("        pub fn next(self: *@This()) ?T {\n");
    try w.writeAll("            if (self.index >= self.count) return null;\n");
    try w.writeAll("            const r_ = T.decodeSized(self.bytes[self.offset..], self.endian);\n");
    try w.writeAll("            self.offset += r_.size;\n");
    try w.writeAll("            self.index += 1;\n");
    try w.writeAll("            return r_.value;\n");
    try w.writeAll("        }\n");
    // Total bytes the count elements occupy, without mutating the iterator.
    // The enclosing decoder uses this to advance past a variable-element list.
    try w.writeAll("        pub fn byteLen(self: @This()) usize {\n");
    try w.writeAll("            var off_: usize = 0;\n");
    try w.writeAll("            var i_: usize = 0;\n");
    try w.writeAll("            while (i_ < self.count) : (i_ += 1) {\n");
    try w.writeAll("                off_ += T.decodeSized(self.bytes[off_..], self.endian).size;\n");
    try w.writeAll("            }\n");
    try w.writeAll("            return off_;\n");
    try w.writeAll("        }\n");
    try w.writeAll("    };\n");
    try w.writeAll("}\n\n");

    // Track every top-level decl name we emit so real-XML name collisions
    // (an xid, enum, struct, union or typedef sharing a name) never produce a
    // duplicate `pub const`. Keys borrow from the arena/pascal buffers below;
    // callers dupe when needed. We store owned dupes to stay valid across
    // buffer reuse.
    var emitted_names: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = emitted_names.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        emitted_names.deinit(gpa);
    }
    var pascal_buf: [256]u8 = undefined;

    // 2. XID types
    for (p.xids) |xid| {
        if (try markEmitted(gpa, &emitted_names, xid.name)) continue;
        try w.print("pub const {s} = u32;\n", .{xid.name});
    }
    if (p.xids.len > 0) try w.print("\n", .{});

    // 2b. Typedefs: `pub const New = <Old zig type>;`. Emitted raw (their own
    // name), resolving Old through the registry (unknown -> u8 fallback).
    for (p.typedefs) |td| {
        if (try markEmitted(gpa, &emitted_names, td.newname)) continue;
        try w.print("pub const {s} = ", .{td.newname});
        try emitZigType(w, reg, p.header, td.oldname);
        try w.writeAll(";\n");
    }
    if (p.typedefs.len > 0) try w.print("\n", .{});

    // 3. Enums
    for (p.enums) |en| {
        const pascal_name = toPascal(en.name, &pascal_buf);
        if (try markEmitted(gpa, &emitted_names, pascal_name)) continue;
        try w.print("pub const {s} = enum(u32) {{\n", .{pascal_name});

        // Track seen values to avoid duplicate enum tags (Zig rejects them).
        // Maps numeric value -> first item name with that value.
        var seen_values: std.AutoHashMapUnmanaged(i64, []const u8) = .{};
        defer seen_values.deinit(gpa);

        // Collect aliases to emit after the closing brace.
        const Alias = struct { item_name: []const u8, first_name: []const u8 };
        var aliases: std.ArrayListUnmanaged(Alias) = .empty;
        defer aliases.deinit(gpa);

        for (en.items) |item| {
            const numeric: i64 = if (item.is_bit) (@as(i64, 1) << @intCast(item.value)) else item.value;
            if (seen_values.get(numeric)) |first_name| {
                // Duplicate value; schedule an alias.
                try aliases.append(gpa, .{ .item_name = item.name, .first_name = first_name });
            } else {
                try seen_values.put(gpa, numeric, item.name);
                try w.writeAll("    ");
                try writeIdent(w, item.name);
                if (item.is_bit) {
                    try w.print(" = 1 << {d},\n", .{item.value});
                } else {
                    try w.print(" = {d},\n", .{item.value});
                }
            }
        }
        try w.writeAll("};\n");

        // Emit const aliases for duplicate values. The alias decl name lives at
        // module scope, so it must be collision-checked like any other decl.
        for (aliases.items) |al| {
            var item_pb: [256]u8 = undefined;
            var first_pb: [256]u8 = undefined;
            const item_pascal = toPascal(al.item_name, &item_pb);
            const first_pascal = toPascal(al.first_name, &first_pb);
            if (try markEmitted(gpa, &emitted_names, item_pascal)) continue;
            try w.print("pub const {s} = {s}.{s};\n", .{ item_pascal, pascal_name, first_pascal });
        }
        try w.writeAll("\n");
    }

    // 4. Structs
    for (p.structs) |s| {
        const pascal_name = toPascal(s.name, &pascal_buf);
        if (try markEmitted(gpa, &emitted_names, pascal_name)) continue;
        try w.print("pub const {s} = struct {{\n", .{pascal_name});
        try emitStructFields(gpa, w, reg, p.header, s.fields, null, "values");
        // Fixed structs get wire_size + decodeElement in the body. Variable
        // structs get decodeSized in the body when they qualify (see
        // emitVariableStructDecode).
        if (reg.fixedSizeOf(p.header, s.name)) |wire_sz| {
            try w.print("    pub const wire_size: usize = {d};\n", .{wire_sz});
            const scan = try prescanFixedFields(gpa, reg, p.header, s.fields, .struct_elem);
            const needs_endian = scan[1];
            // `endian` is the byte order the element is decoded in (native for a
            // client, the client's order for a server).
            try w.writeAll("    pub fn decodeElement(bytes: []const u8, endian: std.builtin.Endian) @This() {\n");
            if (needs_endian) {
                try w.writeAll("        const native_endian = endian;\n");
            } else {
                try w.writeAll("        _ = endian;\n");
            }
            try w.writeAll("        var result: @This() = std.mem.zeroes(@This());\n");
            _ = try emitFixedFieldDecodes(gpa, w, reg, p.header, s.fields, .struct_elem);
            try w.writeAll("        return result;\n");
            try w.writeAll("    }\n");
            // encodeElement is decodeElement's write-side mirror: reuses the
            // SAME emitFixedFieldEncodes write-walker (kind .struct_elem) so
            // the field/offset layout can never drift from decodeElement's.
            // The walker writes `r.<field>`, so alias self to `r` up front
            // rather than threading a second parameter-name convention
            // through emitFixedFieldEncodes. `scan` (the decode-side prescan)
            // is NOT reused for has_reads/needs_endian here: a struct_elem's
            // literal-length fixed-scalar list field decodes on the read side
            // but halts emitFixedFieldEncodes entirely (no write-side
            // counterpart exists yet), so whether `r`/`buf`/`endian` end up
            // referenced must be learned from the actual encode text, captured
            // via a real (non-discarding) dry-run buffer.
            var dry_buf: [4096]u8 = undefined;
            var dry_w = std.Io.Writer.fixed(&dry_buf);
            _ = try emitFixedFieldEncodes(gpa, &dry_w, reg, p.header, s.fields, .struct_elem);
            const dry_text = dry_w.buffered();
            const wrote_any_field = dry_text.len > 0;
            const enc_needs_endian = std.mem.indexOf(u8, dry_text, "endian") != null;
            try w.writeAll("    pub fn encodeElement(self: @This(), buf: []u8, endian: std.builtin.Endian) void {\n");
            try w.writeAll("        const r = self;\n");
            if (!wrote_any_field) {
                try w.writeAll("        _ = r;\n");
                try w.writeAll("        _ = buf;\n");
            }
            if (!enc_needs_endian) try w.writeAll("        _ = endian;\n");
            _ = try emitFixedFieldEncodes(gpa, w, reg, p.header, s.fields, .struct_elem);
            try w.writeAll("    }\n");
            try w.writeAll("};\n\n");
        } else {
            try emitVariableStructDecode(gpa, w, reg, p, s, pascal_name);
        }
    }

    // 4b. Unions overlay several typed views of the same bytes. When every variant
    // is fixed-size, emit a struct holding wire_size raw bytes (the largest
    // variant) plus decodeElement and integer-scalar accessors. Fall back to the
    // field-listing placeholder when a variant is not fixed-size (list/unresolved).
    for (p.unions) |u| {
        const pascal_name = toPascal(u.name, &pascal_buf);
        if (try markEmitted(gpa, &emitted_names, pascal_name)) continue;
        if (unionWireSize(reg, p.header, u.fields)) |wire_sz| {
            try w.print("pub const {s} = struct {{\n", .{pascal_name});
            try w.print("    raw: [{d}]u8 = std.mem.zeroes([{d}]u8),\n", .{ wire_sz, wire_sz });
            try w.print("    pub const wire_size: usize = {d};\n", .{wire_sz});
            // A union decodes as a raw byte copy; its typed accessors apply byte
            // order on read, so the element decode itself ignores `endian`.
            try w.writeAll("    pub fn decodeElement(bytes: []const u8, endian: std.builtin.Endian) @This() {\n");
            try w.writeAll("        _ = endian;\n");
            try w.writeAll("        var result: @This() = std.mem.zeroes(@This());\n");
            try w.print("        @memcpy(result.raw[0..], bytes[0..{d}]);\n", .{wire_sz});
            try w.writeAll("        return result;\n");
            try w.writeAll("    }\n");
            // encodeElement mirrors decodeElement: a union is just a raw byte
            // copy in either direction; byte order is applied by the typed
            // accessors, not by the element read/write itself.
            try w.writeAll("    pub fn encodeElement(self: @This(), buf: []u8, endian: std.builtin.Endian) void {\n");
            try w.print("        @memcpy(buf[0..{d}], self.raw[0..]);\n", .{wire_sz});
            try w.writeAll("        _ = endian;\n");
            try w.writeAll("    }\n");
            // One readInt accessor per integer-scalar variant. Struct/bool/float
            // variant accessors are deferred (a later slice).
            var acc_buf: [256]u8 = undefined;
            for (u.fields) |f| {
                const zt = reg.scalarBuiltin(p.header, f.type_ref) orelse continue;
                if (std.mem.eql(u8, zt, "bool")) continue;
                const wdt = zigWidthFromBuiltin(zt) orelse continue; // skip float
                const acc = toPascal(f.name, &acc_buf);
                try w.print("    pub fn as{s}(self: @This()) {s} {{\n", .{ acc, zt });
                try w.print(
                    "        return std.mem.readInt({s}, self.raw[0..{d}], @import(\"builtin\").cpu.arch.endian());\n",
                    .{ zt, wdt },
                );
                try w.writeAll("    }\n");
            }
            try w.writeAll("};\n\n");
        } else {
            try w.print("pub const {s} = struct {{\n", .{pascal_name});
            try emitStructFields(gpa, w, reg, p.header, u.fields, null, "values");
            try w.writeAll("};\n\n");
        }
    }

    // 5. Requests
    var snake_buf: [256]u8 = undefined;
    for (p.requests) |req| {
        const pascal_name = toPascal(req.name, &pascal_buf);
        const snake_name = toSnake(req.name, &snake_buf);

        // A duplicate request name would redeclare the opcode const, reply
        // struct, decoder and encoder. Skip the whole request if seen.
        if (try markEmitted(gpa, &emitted_names, snake_name)) continue;

        // Opcode constant
        try w.print("pub const {s}_opcode: u8 = {d};\n", .{ snake_name, req.opcode });

        // Reply struct (if present)
        if (req.reply) |reply_fields| {
            // Detect a decodable reply switch: its <switch> field, and the scalar
            // fields decoded before it (the mask + list-length sources).
            var reply_switch: ?*const xcbproto.Switch = null;
            var sw_avail: std.ArrayListUnmanaged([]const u8) = .empty;
            defer sw_avail.deinit(gpa);
            for (reply_fields) |rf| {
                if (rf.kind == .switch_ and rf.switch_data != null) {
                    reply_switch = rf.switch_data;
                    break;
                }
                if (rf.kind == .scalar) try sw_avail.append(gpa, rf.name);
            }
            const sw_decodable = if (reply_switch) |rsw|
                switchDecodable(reg, p, p.header, rsw, sw_avail.items)
            else
                false;
            var vt_buf: [300]u8 = undefined;
            const values_type: ?[]const u8 = if (sw_decodable)
                (std.fmt.bufPrint(&vt_buf, "{s}Values", .{pascal_name}) catch null)
            else
                null;
            if (sw_decodable) try emitDecodeSwitchValues(w, reg, p.header, reply_switch.?, pascal_name);

            // Doc comment: list/ListView fields alias the source `bytes` slice and
            // require it to outlive the decoded struct.
            try w.print("/// Borrowed list fields alias the `bytes` passed to decode{s}Reply.\n", .{pascal_name});
            try w.print("/// The source slice must outlive any use of those fields.\n", .{});
            try w.print("pub const {s}Reply = struct {{\n", .{pascal_name});
            try emitStructFields(gpa, w, reg, p.header, reply_fields, values_type, "values");
            try w.writeAll("};\n\n");

            // Decoder: emit zeroed result then decode leading fixed scalar fields.
            // X11 reply wire layout:
            //   offset 0: response indicator (1, not a declared field)
            //   offset 1: first declared field IF it is a 1-byte scalar, else pad
            //   offsets 2-7: implicit seq(2) + len(4) gap
            //   offsets 8+: remaining declared fields
            //   offset fixed_end_+: list data (4-byte aligned between lists)
            //
            // Pre-scan to decide (a) whether any reads will be emitted,
            // (b) whether any multi-byte read exists (needs native_endian).
            const scan = try prescanFixedFields(gpa, reg, p.header, reply_fields, .reply);
            const has_any_reads = scan[0];
            const needs_endian_fixed = scan[1];

            // Compute stop_index: the index of the first field that halts fixed decoding.
            // Lists are decodable ONLY IF the halt field is a .list (meaning all
            // count fields before it were decoded by the fixed pass, and fixed_end_
            // is the correct list base). If any other kind of field (nested struct,
            // fd, switch, etc.) halts first, the count fields may not have been
            // decoded and we must safe-fallback ALL lists.
            var stop_index: usize = reply_fields.len; // default: no halt
            for (reply_fields, 0..) |rf, i| {
                if (fixedDecodeHalts(reg, p.header, rf, false)) {
                    stop_index = i;
                    break;
                }
            }
            const lists_decodable = stop_index < reply_fields.len and
                reply_fields[stop_index].kind == .list;

            // Build the list of available scalar field names (fields decoded before the
            // first list). These are used by exprAvailable to determine if a list length
            // expression can be evaluated at decode time.
            var avail_fields_list: std.ArrayListUnmanaged([]const u8) = .empty;
            defer avail_fields_list.deinit(gpa);
            if (lists_decodable) {
                for (reply_fields) |rf| {
                    if (rf.kind == .list) break;
                    if (rf.kind == .scalar) {
                        try avail_fields_list.append(gpa, rf.name);
                    }
                }
            }

            // Pre-scan: does the FIRST decodable list (in emission order) have an
            // available length expression? The pre-scan mirrors the emission loop's
            // break-on-unknown-elem behavior exactly: it stops (breaks) at any list
            // with an unknown element type, just as the emission loop does.
            // When has_lists is true, native_endian is always needed because
            // reply_total_ reads bytes[4..8] unconditionally.
            var has_lists = false;
            var has_any_list_fields = false;
            for (reply_fields) |rf| {
                if (rf.kind == .list) {
                    has_any_list_fields = true;
                    break;
                }
            }
            if (lists_decodable) {
                for (reply_fields) |rf| {
                    if (rf.kind != .list) continue;
                    // Check element type: unknown-elem -> break (same as emission loop).
                    const maybe_bt = reg.scalarBuiltin(p.header, rf.type_ref);
                    const is_fixed_scalar_elem: bool = blk: {
                        const bt = maybe_bt orelse break :blk false;
                        if (std.mem.eql(u8, bt, "f32") or std.mem.eql(u8, bt, "f64")) break :blk false;
                        break :blk true;
                    };
                    const is_fixed_struct_elem = !is_fixed_scalar_elem and
                        (fixedStructElemSize(reg, p.header, rf.type_ref) != null);
                    const is_var_struct_elem = !is_fixed_scalar_elem and !is_fixed_struct_elem and
                        variableDecodableStruct(reg, p.header, rf.type_ref);
                    if (!is_fixed_scalar_elem and !is_fixed_struct_elem and !is_var_struct_elem) break; // unknown elem: stop
                    // Check scalar element stride: if not an integer type -> break.
                    if (is_fixed_scalar_elem) {
                        _ = zigWidthFromBuiltin(maybe_bt.?) orelse break;
                    }
                    // Check length expression availability via the full evaluator.
                    const expr = rf.list_len orelse break;
                    const ectx = ExprCtx{
                        .has_length_header = true,
                        .avail_fields = avail_fields_list.items,
                        .avail_lists = &.{},
                        .in_sumof = false,
                    };
                    if (!exprAvailable(p, ectx, expr)) break; // unavailable: stop
                    has_lists = true;
                    break; // found the first decodable list; preamble will be emitted
                }
            }

            // reply_total_ always uses native_endian (reads bytes[4..8]); a
            // decodable switch reads multi-byte fields too.
            const needs_endian = needs_endian_fixed or has_lists or sw_decodable;

            try w.print("pub fn decode{s}Reply(bytes: []const u8) {s}Reply {{\n", .{ pascal_name, pascal_name });
            if (!has_any_reads and !has_lists and !sw_decodable) {
                // No decodable scalar fields and no decodable lists: bytes unused.
                // Still emit the pre-list-stop TODO if lists exist, so callers know
                // decoding is incomplete (not silently wrong).
                if (has_any_list_fields and !lists_decodable) {
                    try w.writeAll("    // TODO(slice3+): fixed header has a pre-list stop (e.g. nested struct); lists not yet decodable\n");
                }
                try w.writeAll("    _ = bytes;\n");
                try w.print("    return std.mem.zeroes({s}Reply);\n", .{pascal_name});
            } else {
                if (needs_endian) {
                    try w.writeAll("    const native_endian = @import(\"builtin\").cpu.arch.endian();\n");
                }
                try w.print("    var result: {s}Reply = std.mem.zeroes({s}Reply);\n", .{ pascal_name, pascal_name });
                const fixed_end_ = try emitFixedFieldDecodes(gpa, w, reg, p.header, reply_fields, .reply);
                // Emit borrowed-slice assignments for fixed-scalar-element lists.
                // The list base is fixed_end_ (the byte cursor after all leading fixed
                // fields), NOT a hardcoded 32.
                if (has_lists) {
                    // Emit the header-length bound used as the limit for all list reads.
                    // native_endian must be in scope here (guaranteed because has_lists and
                    // needs_endian already covers list_needs_endian).
                    try w.writeAll("    const reply_total_: usize = blk_rt: {\n");
                    try w.writeAll("        if (bytes.len < 8) break :blk_rt bytes.len;\n");
                    try w.writeAll("        const len_words_ = std.mem.readInt(u32, bytes[4..8], native_endian);\n");
                    try w.writeAll("        break :blk_rt @min(bytes.len, 32 + 4 * @as(usize, len_words_));\n");
                    try w.writeAll("    };\n");
                    try w.print("    var list_off_: usize = {d};\n", .{fixed_end_});

                    try emitListDecodes(
                        gpa,
                        w,
                        reg,
                        p,
                        p.header,
                        reply_fields,
                        true,
                        avail_fields_list.items,
                        "reply_total_",
                        false,
                        false,
                    );
                } else {
                    // The fixed pass halted at a non-list field (nested struct, fd,
                    // switch, etc.) before reaching the lists, OR no list length
                    // expression is resolvable. Safe-fallback.
                    var any_list = false;
                    for (reply_fields) |rf| {
                        if (rf.kind == .list) {
                            any_list = true;
                            break;
                        }
                    }
                    if (any_list) {
                        try w.writeAll("    // TODO(slice3+): fixed header has a pre-list stop (e.g. nested struct); lists not yet decodable\n");
                    }
                }
                if (sw_decodable) {
                    // The <switch> follows the fixed fields; decode it into
                    // result.values, driven by the decoded mask field.
                    if (!has_lists) try w.print("    var list_off_: usize = {d};\n", .{fixed_end_});
                    try emitDecodeSwitch(w, reg, p, p.header, reply_switch.?, sw_avail.items);
                }
                try w.writeAll("    return result;\n");
            }
            try w.writeAll("}\n\n");
        }

        // Encoder function.
        // Parameter and local names are suffixed with '_' so they can never
        // collide with a request field (fields keep their raw XML name).
        const has_reply = req.reply != null;

        // Task 3: plan lists + derived counts for this request.
        var enc_lists: std.ArrayListUnmanaged(RequestListInfo) = .empty;
        defer enc_lists.deinit(gpa);
        var enc_derived: std.StringHashMapUnmanaged(void) = .{};
        defer enc_derived.deinit(gpa); // keys borrowed from Protocol; do NOT free keys
        try requestListPlan(gpa, reg, p.header, req, &enc_lists, &enc_derived);
        const has_list = enc_lists.items.len > 0;

        // Task 2: find the request's single `.switch_` field (if any) and decide
        // whether it is typable (single-field bitcases, resolvable conds). A
        // typable switch replaces the value_mask param + `values_` passthrough
        // with a typed `<Pascal>ValueList` struct-of-optionals; the mask is
        // derived and values are packed in bit order. A NON-typable / multi-field
        // switch keeps the existing `values_` fallback (Task 3 handles multi-field).
        var switch_field: ?xcbproto.Field = null;
        for (req.fields) |field| {
            if (field.kind == .switch_ and field.switch_data != null) {
                switch_field = field;
                break;
            }
        }
        const typed_switch = if (switch_field) |sf|
            switchTypable(reg, p, p.header, sf.switch_data.?)
        else
            false;
        // A structured (multi-field, natural-size) switch, used when the plain
        // value-list form does not apply.
        const structured_switch = if (switch_field) |sf|
            (!typed_switch and switchStructured(reg, p, p.header, sf.switch_data.?))
        else
            false;

        // The mask fieldref name (value_mask). Meaningful for typed or structured.
        const mask_field_name: []const u8 = if (typed_switch or structured_switch)
            switch_field.?.switch_data.?.mask_fieldref
        else
            "";

        // Emit the ValueList struct BEFORE the encoder fn (collision-checked).
        if (typed_switch) {
            const sw = switch_field.?.switch_data.?;
            // pascal_name is stable across this iteration (pascal_buf not reused
            // until the next request), so the struct decl name stays valid.
            var vl_name_buf: [300]u8 = undefined;
            const vl_name = std.fmt.bufPrint(&vl_name_buf, "{s}ValueList", .{pascal_name}) catch pascal_name;
            if (!try markEmitted(gpa, &emitted_names, vl_name)) {
                try w.print("pub const {s}ValueList = struct {{\n", .{pascal_name});
                for (sw.bitcases) |bc| {
                    const f = bc.fields[0];
                    try w.writeAll("    ");
                    try writeIdent(w, f.name);
                    try w.writeAll(": ?");
                    try emitZigType(w, reg, p.header, f.type_ref);
                    try w.writeAll(" = null,\n");
                }
                try w.writeAll("};\n\n");
            }
        }

        // Structured ValueList: one optional per bitcase (single value field ->
        // ?T, multi-field -> ?struct of those fields). Packed at natural size.
        if (structured_switch) {
            const sw = switch_field.?.switch_data.?;
            var vl_name_buf: [300]u8 = undefined;
            const vl_name = std.fmt.bufPrint(&vl_name_buf, "{s}ValueList", .{pascal_name}) catch pascal_name;
            if (!try markEmitted(gpa, &emitted_names, vl_name)) {
                try w.print("pub const {s}ValueList = struct {{\n", .{pascal_name});
                var nm_buf: [300]u8 = undefined;
                for (sw.bitcases) |bc| {
                    try w.writeAll("    ");
                    try emitStructuredOptName(w, bc, &nm_buf);
                    if (bitcaseValueFieldCount(bc) == 1) {
                        for (bc.fields) |f| {
                            if (f.kind == .pad) continue;
                            try w.writeAll(": ?");
                            try emitVlFieldType(w, reg, p.header, f);
                            break;
                        }
                        try w.writeAll(" = null,\n");
                    } else {
                        try w.writeAll(": ?struct {\n");
                        for (bc.fields) |f| {
                            if (f.kind == .pad) continue;
                            try w.writeAll("        ");
                            try writeIdent(w, f.name);
                            try w.writeAll(": ");
                            try emitVlFieldType(w, reg, p.header, f);
                            try w.writeAll(",\n");
                        }
                        try w.writeAll("    } = null,\n");
                    }
                }
                try w.writeAll("};\n\n");
            }
        }

        // Extension modules use a different wire form: major = runtime ext major,
        // minor = request opcode, first field packs into body (no data-byte routing).
        const is_ext = p.extension_xname != null;

        // Pre-scan: detect the data-byte field (wire byte 1, the "minor" arg).
        // Rules (symmetric to reply/event decode):
        //   - fields[0] is a .scalar with width == 1  -> it IS the data byte
        //   - fields[0] is a .pad (any size)           -> data byte = 0, pad consumed
        //   - otherwise                                -> data byte = 0
        // The consumed field is NOT packed into the body.
        // A leading pad > 1 byte: first byte is consumed (data byte slot), remaining
        // go into the body as a body pad. In practice leading pads are always 1 byte.
        // For extension requests (is_ext), data-byte routing is suppressed entirely:
        // the first field packs into the body and byte 1 holds the minor opcode.
        const DataByteKind = enum { none, scalar_field, leading_pad, exprfield };
        var data_byte_kind: DataByteKind = .none;
        var data_byte_field_idx: usize = 0; // index into req.fields of the data-byte scalar
        var data_byte_field_name: []const u8 = "";
        var data_byte_field_type: []const u8 = "";
        if (!is_ext) {
            if (req.fields.len > 0) {
                const f0 = req.fields[0];
                switch (f0.kind) {
                    .scalar => {
                        const width = scalarByteWidth(reg, p.header, f0.type_ref);
                        if (width == 1) {
                            data_byte_kind = .scalar_field;
                            data_byte_field_idx = 0;
                            data_byte_field_name = f0.name;
                            data_byte_field_type = f0.type_ref;
                        }
                    },
                    .pad => {
                        // Leading request pad is the 1-byte data-byte slot; consumed as minor=0.
                        data_byte_kind = .leading_pad;
                    },
                    .exprfield => {
                        // A leading 1-byte exprfield is the computed data byte (e.g.
                        // QueryTextExtents odd_length = string_len & 1). Needs a
                        // captured value expression.
                        if (f0.list_len != null and scalarByteWidth(reg, p.header, f0.type_ref) == 1) {
                            data_byte_kind = .exprfield;
                            data_byte_field_idx = 0;
                        }
                    },
                    else => {},
                }
            }
        }

        // Function signature
        try w.writeAll("pub fn ");
        try writeIdent(w, snake_name);
        try w.writeAll("(client_: *x11.Client");

        // Requests with lists OR a typed switch use the allocated body path and
        // therefore take a gpa_ allocator right after client_.
        const use_body = has_list or typed_switch or structured_switch;
        if (use_body) {
            try w.writeAll(", gpa_: std.mem.Allocator");
        }

        // Emit scalar/list request fields as parameters. Track names already
        // used so a duplicate field name does not produce two same-named params.
        var param_seen: std.StringHashMapUnmanaged(void) = .{};
        defer param_seen.deinit(gpa);
        var has_switch_or_expr = false;
        for (req.fields) |field| {
            switch (field.kind) {
                .scalar => {
                    // Drop derived-count params (they are written from list.len).
                    if (has_list and enc_derived.contains(field.name)) continue;
                    // Drop the value_mask param for a typed switch: it is derived
                    // from which value_list_ optionals are set.
                    if ((typed_switch or structured_switch) and std.mem.eql(u8, field.name, mask_field_name)) continue;
                    if ((try param_seen.getOrPut(gpa, field.name)).found_existing) continue;
                    try w.writeAll(", ");
                    try writeIdent(w, field.name);
                    try w.writeAll(": ");
                    try emitZigType(w, reg, p.header, field.type_ref);
                },
                .list => {
                    if ((try param_seen.getOrPut(gpa, field.name)).found_existing) continue;
                    // Find the RequestListInfo for this list to choose the param type.
                    var list_info: ?RequestListInfo = null;
                    for (enc_lists.items) |li| {
                        if (std.mem.eql(u8, li.name, field.name)) {
                            list_info = li;
                            break;
                        }
                    }
                    try w.writeAll(", ");
                    try writeIdent(w, field.name);
                    try w.writeAll(": ");
                    if (list_info) |li| {
                        switch (li.elem_kind) {
                            .scalar => {
                                // []const <ElemType>
                                try w.writeAll("[]const ");
                                try emitZigType(w, reg, p.header, field.type_ref);
                            },
                            .char, .structure, .raw => {
                                try w.writeAll("[]const u8");
                            },
                        }
                    } else {
                        try w.writeAll("[]const u8");
                    }
                },
                .exprfield => {
                    // A data-byte exprfield is computed and routed to wire byte 1,
                    // so it is neither a parameter nor a values_ passthrough.
                    if (data_byte_kind == .exprfield) continue;
                    has_switch_or_expr = true;
                },
                .switch_ => {
                    has_switch_or_expr = true;
                },
                .pad, .fd => {},
            }
        }
        if (typed_switch or structured_switch) {
            // A struct-of-optionals value list replaces the raw `values_`
            // passthrough AND the derived value_mask param.
            try w.print(", value_list_: {s}ValueList", .{pascal_name});
        } else if (has_switch_or_expr) {
            try w.writeAll(", values_: []const u8"); // TODO(slice8+): non-typable switch / exprfield
        }
        if (has_reply) {
            try w.print(") !x11.cookie.Cookie({s}Reply) {{\n", .{pascal_name});
        } else {
            try w.print(") !x11.cookie.Cookie(void) {{\n", .{});
        }

        // Compute the data-byte argument expression once.
        // Special case: if the data-byte field is itself a derived count (e.g. SetPointerMapping
        // where map_len is the data byte AND derived from map.len), compute from list.len.
        var data_byte_out: std.Io.Writer.Allocating = .init(gpa);
        defer data_byte_out.deinit();
        if (data_byte_kind == .scalar_field) {
            const is_derived_data_byte = has_list and enc_derived.contains(data_byte_field_name);
            if (is_derived_data_byte) {
                // Compute from the corresponding list's .len (truncated to u8).
                var list_for_db: []const u8 = "";
                for (enc_lists.items) |li| {
                    if (li.count_field) |cf| {
                        if (std.mem.eql(u8, cf, data_byte_field_name)) {
                            list_for_db = li.name;
                            break;
                        }
                    }
                }
                try data_byte_out.writer.writeAll("@intCast(");
                try writeIdent(&data_byte_out.writer, list_for_db);
                try data_byte_out.writer.writeAll(".len)");
            } else {
                const zig_type = reg.scalarBuiltin(p.header, data_byte_field_type) orelse "";
                if (std.mem.eql(u8, zig_type, "bool")) {
                    try data_byte_out.writer.writeAll("@intFromBool(");
                    try writeIdent(&data_byte_out.writer, data_byte_field_name);
                    try data_byte_out.writer.writeAll(")");
                } else if (std.mem.eql(u8, zig_type, "u8")) {
                    try writeIdent(&data_byte_out.writer, data_byte_field_name);
                } else {
                    // i8 or other 1-byte type: bitcast to u8.
                    try data_byte_out.writer.writeAll("@as(u8, @bitCast(");
                    try writeIdent(&data_byte_out.writer, data_byte_field_name);
                    try data_byte_out.writer.writeAll("))");
                }
            }
        } else if (data_byte_kind == .exprfield) {
            // Computed data byte (e.g. QueryTextExtents odd_length = string_len & 1).
            try data_byte_out.writer.writeAll("@intCast(");
            try emitEncodeExpr(&data_byte_out.writer, reg, p.header, req.fields, req.fields[data_byte_field_idx].list_len.?);
            try data_byte_out.writer.writeAll(")");
        } else {
            try data_byte_out.writer.writeAll("0");
        }
        const data_byte_expr = try data_byte_out.toOwnedSlice();
        defer gpa.free(data_byte_expr);

        if (use_body) {
            // --- ALLOCATED BODY PATH (Task 3 lists + Task 2 typed switch) ---
            // Note: body packing uses std.mem.asBytes which yields native-endian bytes
            // directly. native_endian is NOT referenced in the emitted body code, so
            // we never emit it (emitting an unused const is a compile error in Zig).

            // For extension requests, look up the runtime major opcode before any
            // allocation so an early return frees nothing.
            if (is_ext) {
                try w.writeAll("    const ext_major_ = client_.extensionMajor(extension_xname) orelse return error.ExtensionNotAvailable;\n");
            }

            // Emit total_ size computation: fixed scalars/pads/derived counts, then lists.
            try w.writeAll("    var total_: usize = 0;\n");
            {
                var sz_seen: std.StringHashMapUnmanaged(void) = .{};
                defer sz_seen.deinit(gpa);
                for (req.fields, 0..) |field, fi| {
                    if (data_byte_kind == .scalar_field and fi == data_byte_field_idx) continue;
                    if (data_byte_kind == .leading_pad and fi == 0) continue;
                    switch (field.kind) {
                        .scalar => {
                            if ((try sz_seen.getOrPut(gpa, field.name)).found_existing) continue;
                            const width = scalarByteWidth(reg, p.header, field.type_ref);
                            if (width > 0) {
                                try w.print("    total_ += {d};\n", .{width});
                            }
                        },
                        .pad => {
                            try w.print("    total_ += {d};\n", .{field.pad_bytes});
                        },
                        .list => {
                            if ((try sz_seen.getOrPut(gpa, field.name)).found_existing) continue;
                            // Find stride for this list.
                            // For .scalar lists the param is []const T so .len = element count;
                            // multiply by the element width (stride) to get byte count.
                            // For .char/.structure/.raw the param is []const u8 so .len IS
                            // the byte count already; use multiplier 1 to avoid over-allocation.
                            var size_stride: usize = 1;
                            for (enc_lists.items) |li| {
                                if (std.mem.eql(u8, li.name, field.name)) {
                                    size_stride = switch (li.elem_kind) {
                                        .scalar => li.stride,
                                        .char, .structure, .raw => 1,
                                    };
                                    break;
                                }
                            }
                            if (size_stride == 1) {
                                try w.writeAll("    total_ += ");
                                try writeIdent(w, field.name);
                                try w.writeAll(".len;\n");
                            } else {
                                try w.writeAll("    total_ += ");
                                try writeIdent(w, field.name);
                                try w.print(".len * {d};\n", .{size_stride});
                            }
                            // Pad list to 4-byte boundary.
                            try w.writeAll("    total_ = (total_ + 3) & ~@as(usize, 3);\n");
                        },
                        else => {},
                    }
                }
            }

            // Typed switch: over-allocate the value-list part by 4 bytes per bitcase
            // (each set optional packs one 4-byte word; the actual count is derived
            // at runtime from which optionals are set). Bounded and small.
            if (typed_switch) {
                const sw = switch_field.?.switch_data.?;
                try w.print("    total_ += {d};\n", .{4 * sw.bitcases.len});
            }
            // Structured switch: reserve the value bytes. Scalar-only bitcases
            // have a static upper bound; bitcases with lists are sized at runtime
            // from the provided slices, gated by which optionals are set. Pads are
            // over-reserved by 3 (worst-case align). body_ is truncated to off_.
            if (structured_switch) {
                const sw = switch_field.?.switch_data.?;
                var nm_buf: [300]u8 = undefined;
                for (sw.bitcases) |bc| {
                    const single = bitcaseValueFieldCount(bc) == 1;
                    if (!bitcaseHasList(bc)) {
                        var sz: usize = 0;
                        for (bc.fields) |f| {
                            if (f.kind == .pad) sz += 3 else sz += scalarByteWidth(reg, p.header, f.type_ref);
                        }
                        try w.print("    total_ += {d};\n", .{sz});
                        continue;
                    }
                    try w.writeAll("    if (value_list_.");
                    try emitStructuredOptName(w, bc, &nm_buf);
                    try w.writeAll(") |v_| {\n");
                    for (bc.fields) |f| {
                        switch (vlFieldKind(reg, p.header, f)) {
                            .scalar => try w.print("        total_ += {d};\n", .{scalarByteWidth(reg, p.header, f.type_ref)}),
                            .scalar_list => {
                                try w.writeAll("        total_ += ");
                                try emitVlAccess(w, f, single);
                                try w.print(".len * {d};\n", .{scalarByteWidth(reg, p.header, f.type_ref)});
                            },
                            .raw_list => {
                                try w.writeAll("        total_ += ");
                                try emitVlAccess(w, f, single);
                                try w.writeAll(".len;\n");
                            },
                            .pad => try w.writeAll("        total_ += 3;\n"),
                        }
                    }
                    try w.writeAll("    }\n");
                }
            }

            // Allocate and zero body.
            try w.writeAll("    const body_ = try gpa_.alloc(u8, total_);\n");
            try w.writeAll("    defer gpa_.free(body_);\n");
            try w.writeAll("    @memset(body_, 0);\n");
            try w.writeAll("    var off_: usize = 0;\n");

            // Pack body fields in order.
            var body_seen2: std.StringHashMapUnmanaged(void) = .{};
            defer body_seen2.deinit(gpa);
            for (req.fields, 0..) |field, fi| {
                if (data_byte_kind == .scalar_field and fi == data_byte_field_idx) continue;
                if (data_byte_kind == .leading_pad and fi == 0) continue;
                switch (field.kind) {
                    .scalar => {
                        if ((try body_seen2.getOrPut(gpa, field.name)).found_existing) continue;
                        // Typed-switch value_mask: derive the mask from set optionals
                        // and write it at this field's body slot (in field order).
                        if (typed_switch and std.mem.eql(u8, field.name, mask_field_name)) {
                            const sw = switch_field.?.switch_data.?;
                            const mask_zig = reg.scalarBuiltin(p.header, field.type_ref) orelse "u32";
                            try w.print("    var mask_: {s} = 0;\n", .{mask_zig});
                            for (sw.bitcases) |bc| {
                                const bf = bc.fields[0];
                                // OR of every cond's resolved value for this bitcase.
                                try w.writeAll("    if (value_list_.");
                                try writeIdent(w, bf.name);
                                try w.writeAll(") |_| mask_ |= ");
                                var mask_or: i64 = 0;
                                for (bc.conds) |c| mask_or |= enumCondValue(p, c).?;
                                try w.print("{d};\n", .{mask_or});
                            }
                            try w.writeAll("    { const mb_ = std.mem.asBytes(&mask_);\n");
                            try w.writeAll("    @memcpy(body_[off_..][0..mb_.len], mb_);\n");
                            try w.writeAll("    off_ += mb_.len; }\n");
                            continue;
                        }
                        // Structured-switch value_mask: same mask derivation, but
                        // the optionals are named per bitcase (single field name or
                        // the cond group).
                        if (structured_switch and std.mem.eql(u8, field.name, mask_field_name)) {
                            const sw = switch_field.?.switch_data.?;
                            const mask_zig = reg.scalarBuiltin(p.header, field.type_ref) orelse "u32";
                            try w.print("    var mask_: {s} = 0;\n", .{mask_zig});
                            var nm_buf: [300]u8 = undefined;
                            for (sw.bitcases) |bc| {
                                try w.writeAll("    if (value_list_.");
                                try emitStructuredOptName(w, bc, &nm_buf);
                                try w.writeAll(") |_| mask_ |= ");
                                var mask_or: i64 = 0;
                                for (bc.conds) |c| mask_or |= enumCondValue(p, c).?;
                                try w.print("{d};\n", .{mask_or});
                            }
                            try w.writeAll("    { const mb_ = std.mem.asBytes(&mask_);\n");
                            try w.writeAll("    @memcpy(body_[off_..][0..mb_.len], mb_);\n");
                            try w.writeAll("    off_ += mb_.len; }\n");
                            continue;
                        }
                        // Is this field a derived count?
                        if (enc_derived.contains(field.name)) {
                            // Write derived count from the corresponding list's .len.
                            // Find which list this count belongs to.
                            var list_name_for_count: []const u8 = "";
                            for (enc_lists.items) |li| {
                                if (li.count_field) |cf| {
                                    if (std.mem.eql(u8, cf, field.name)) {
                                        list_name_for_count = li.name;
                                        break;
                                    }
                                }
                            }
                            // Emit the count write using the list's elem type for the count type.
                            const count_zig_type = reg.scalarBuiltin(p.header, field.type_ref) orelse "u16";
                            try w.print("    {{ const c_: {s} = @intCast(", .{count_zig_type});
                            try writeIdent(w, list_name_for_count);
                            try w.writeAll(".len);\n");
                            try w.writeAll("    const b_ = std.mem.asBytes(&c_);\n");
                            try w.writeAll("    @memcpy(body_[off_..][0..b_.len], b_);\n");
                            try w.writeAll("    off_ += b_.len; }\n");
                        } else {
                            // Regular scalar: write from param.
                            try w.writeAll("    { const b_ = std.mem.asBytes(&");
                            try writeIdent(w, field.name);
                            try w.writeAll(");\n");
                            try w.writeAll("    @memcpy(body_[off_..][0..b_.len], b_);\n");
                            try w.writeAll("    off_ += b_.len; }\n");
                        }
                    },
                    .pad => {
                        // Already zeroed by @memset; just advance offset.
                        try w.print("    off_ += {d};\n", .{field.pad_bytes});
                    },
                    .list => {
                        if ((try body_seen2.getOrPut(gpa, field.name)).found_existing) continue;
                        // Pack list bytes and pad to 4-byte boundary.
                        try w.writeAll("    { const lb_ = std.mem.sliceAsBytes(");
                        try writeIdent(w, field.name);
                        try w.writeAll(");\n");
                        try w.writeAll("    @memcpy(body_[off_..][0..lb_.len], lb_);\n");
                        try w.writeAll("    off_ += lb_.len;\n");
                        try w.writeAll("    off_ = (off_ + 3) & ~@as(usize, 3); }\n");
                    },
                    .fd, .exprfield, .switch_ => {},
                }
            }
            if (typed_switch) {
                // Pack each present value-list entry as a 4-byte little-endian-in-
                // native-order word, in bitcase (bit) order, right after the fixed
                // fields. The <switch> is the request's trailing field in xcbproto,
                // so off_ is already at the value-list base here. The mask was
                // derived and written earlier at the value_mask field position.
                const sw = switch_field.?.switch_data.?;
                for (sw.bitcases) |bc| {
                    const f = bc.fields[0];
                    try w.writeAll("    if (value_list_.");
                    try writeIdent(w, f.name);
                    try w.writeAll(") |v_| {\n");
                    try w.writeAll("        var w4_: [4]u8 = .{ 0, 0, 0, 0 };\n");
                    try w.writeAll("        const vb_ = std.mem.asBytes(&v_);\n");
                    try w.writeAll("        @memcpy(w4_[0..vb_.len], vb_);\n");
                    try w.writeAll("        @memcpy(body_[off_..][0..4], &w4_);\n");
                    try w.writeAll("        off_ += 4;\n");
                    try w.writeAll("    }\n");
                }
            } else if (structured_switch) {
                // Pack each present bitcase's value fields at natural size, in bit
                // order, right after the fixed fields (the switch is trailing).
                // Scalars pack as native bytes, scalar lists via sliceAsBytes, raw
                // (struct-element) lists as the caller's bytes, and pads align.
                const sw = switch_field.?.switch_data.?;
                var nm_buf: [300]u8 = undefined;
                for (sw.bitcases) |bc| {
                    const single = bitcaseValueFieldCount(bc) == 1;
                    try w.writeAll("    if (value_list_.");
                    try emitStructuredOptName(w, bc, &nm_buf);
                    try w.writeAll(") |v_| {\n");
                    for (bc.fields) |f| {
                        switch (vlFieldKind(reg, p.header, f)) {
                            .scalar => {
                                try w.writeAll("        { const b_ = std.mem.asBytes(&");
                                try emitVlAccess(w, f, single);
                                try w.writeAll(");\n");
                                try w.writeAll("        @memcpy(body_[off_..][0..b_.len], b_);\n");
                                try w.writeAll("        off_ += b_.len; }\n");
                            },
                            .scalar_list => {
                                try w.writeAll("        { const lb_ = std.mem.sliceAsBytes(");
                                try emitVlAccess(w, f, single);
                                try w.writeAll(");\n");
                                try w.writeAll("        @memcpy(body_[off_..][0..lb_.len], lb_);\n");
                                try w.writeAll("        off_ += lb_.len; }\n");
                            },
                            .raw_list => {
                                try w.writeAll("        { const lb_ = ");
                                try emitVlAccess(w, f, single);
                                try w.writeAll(";\n");
                                try w.writeAll("        @memcpy(body_[off_..][0..lb_.len], lb_);\n");
                                try w.writeAll("        off_ += lb_.len; }\n");
                            },
                            .pad => {
                                if (f.pad_align) {
                                    try w.writeAll("        off_ = (off_ + 3) & ~@as(usize, 3);\n");
                                } else if (f.pad_bytes > 0) {
                                    try w.print("        off_ += {d};\n", .{f.pad_bytes});
                                }
                            },
                        }
                    }
                    try w.writeAll("    }\n");
                }
            } else if (has_switch_or_expr) {
                // Non-typable switch / exprfield: the caller-supplied raw passthrough
                // is not yet encoded (slice8/SP4). It compiles because the param is
                // declared as `values_: []const u8`.
                try w.writeAll("    _ = values_; // TODO(slice8): non-typable switch/exprfield passthrough\n");
            }

            if (is_ext) {
                if (has_reply) {
                    try w.print("    return client_.sendCookie({s}Reply, ext_major_, {s}_opcode, body_[0..off_]);\n", .{ pascal_name, snake_name });
                } else {
                    try w.print("    return client_.sendCookie(void, ext_major_, {s}_opcode, body_[0..off_]);\n", .{snake_name});
                }
            } else {
                if (has_reply) {
                    try w.print("    return client_.sendCookie({s}Reply, {s}_opcode, {s}, body_[0..off_]);\n", .{ pascal_name, snake_name, data_byte_expr });
                } else {
                    try w.print("    return client_.sendCookie(void, {s}_opcode, {s}, body_[0..off_]);\n", .{ snake_name, data_byte_expr });
                }
            }
        } else {
            // --- STACK PATH (Task 1, scalar-only requests) ---

            // For extension requests, look up the runtime major opcode first.
            // This is a pure lookup (no allocation), so an early return is clean.
            if (is_ext) {
                try w.writeAll("    const ext_major_ = client_.extensionMajor(extension_xname) orelse return error.ExtensionNotAvailable;\n");
            }

            // Pre-scan: determine if the body packs anything (body scalar OR body pad).
            var body_has_content = false;
            {
                var scan_seen: std.StringHashMapUnmanaged(void) = .{};
                defer scan_seen.deinit(gpa);
                for (req.fields, 0..) |field, fi| {
                    // Skip the consumed data-byte field.
                    if (data_byte_kind == .scalar_field and fi == data_byte_field_idx) continue;
                    // Skip a fully-consumed leading pad.
                    if (data_byte_kind == .leading_pad and fi == 0) continue;
                    switch (field.kind) {
                        .scalar => {
                            if ((try scan_seen.getOrPut(gpa, field.name)).found_existing) continue;
                            body_has_content = true;
                        },
                        .pad => {
                            body_has_content = true;
                        },
                        else => {},
                    }
                }
            }

            if (body_has_content) {
                try w.writeAll("    var extra_: [4096]u8 = undefined;\n");
                try w.writeAll("    var extra_len_: usize = 0;\n");
            } else {
                try w.writeAll("    const extra_: [0]u8 = .{};\n");
                try w.writeAll("    const extra_len_: usize = 0;\n");
            }
            var body_seen: std.StringHashMapUnmanaged(void) = .{};
            defer body_seen.deinit(gpa);
            for (req.fields, 0..) |field, fi| {
                // Skip the consumed data-byte field (routed to minor arg, not packed into body).
                if (data_byte_kind == .scalar_field and fi == data_byte_field_idx) continue;
                // Skip the consumed leading pad (data byte slot = 0, nothing emitted into body).
                if (data_byte_kind == .leading_pad and fi == 0) continue;
                switch (field.kind) {
                    .scalar => {
                        if ((try body_seen.getOrPut(gpa, field.name)).found_existing) continue;
                        // Copy the value's native bytes into extra_ at extra_len_.
                        try w.writeAll("    {\n");
                        try w.writeAll("        const bytes_ = std.mem.asBytes(&");
                        try writeIdent(w, field.name);
                        try w.writeAll(");\n");
                        try w.writeAll("        @memcpy(extra_[extra_len_..][0..bytes_.len], bytes_);\n");
                        try w.writeAll("        extra_len_ += bytes_.len;\n");
                        try w.writeAll("    }\n");
                    },
                    .pad => {
                        // Body pads MUST be zeroed: extra_ is undefined, leaking garbage is wrong.
                        try w.print("    @memset(extra_[extra_len_..][0..{d}], 0);\n", .{field.pad_bytes});
                        try w.print("    extra_len_ += {d};\n", .{field.pad_bytes});
                    },
                    .fd, .exprfield, .switch_ => {},
                    .list => unreachable, // has_list is false, no lists reach here
                }
            }
            if (has_switch_or_expr) {
                try w.writeAll("    _ = values_; // TODO(slice8): non-typable switch/exprfield passthrough\n");
            }

            if (is_ext) {
                if (has_reply) {
                    try w.print("    return client_.sendCookie({s}Reply, ext_major_, {s}_opcode, extra_[0..extra_len_]);\n", .{ pascal_name, snake_name });
                } else {
                    try w.print("    return client_.sendCookie(void, ext_major_, {s}_opcode, extra_[0..extra_len_]);\n", .{snake_name});
                }
            } else {
                if (has_reply) {
                    try w.print("    return client_.sendCookie({s}Reply, {s}_opcode, {s}, extra_[0..extra_len_]);\n", .{ pascal_name, snake_name, data_byte_expr });
                } else {
                    try w.print("    return client_.sendCookie(void, {s}_opcode, {s}, extra_[0..extra_len_]);\n", .{ snake_name, data_byte_expr });
                }
            }
        }
        try w.writeAll("}\n\n");
    }

    // 5b. Request decoders (the inverse of the request builders). A request's
    // wire layout matches an event's (byte-1 data field, body from byte 4), so
    // this reuses the .event fixed-field decode. The decoder takes the client's
    // byte order as `endian`; emitting `const native_endian = endian;` lets the
    // reused emitters (which write the literal native_endian) thread it through.
    // A trailing list (a scalar-element list like InternAtom's `name`, or a
    // struct-element list like PolyPoint's `points`) is filled by reusing the
    // exact same willDecodeAnyList/emitListDecodes core the reply and
    // struct-element decoders use, with `bytes.len` as the limit (there is no
    // reply-style length-header word to bound against). A struct-element list
    // decodes into a ListView(T)/StructIterator(T) carrying `.endian =
    // native_endian` (the client's order), same as the reply/struct paths. A
    // list gated behind a switch/fd/nested-aggregate, or whose element type is
    // genuinely unsupported (e.g. a variable union), stays deferred (TODO
    // fallback).
    for (p.requests) |req| {
        const pascal_name = toPascal(req.name, &pascal_buf);
        var rname_buf: [300]u8 = undefined;
        const rdecl = std.fmt.bufPrint(&rname_buf, "{s}Request", .{pascal_name}) catch pascal_name;
        if (try markEmitted(gpa, &emitted_names, rdecl)) continue;

        // Find the request's single `.switch_` field (if any) and decide whether
        // it is a typable value-list (same predicate/shape the request ENCODER
        // above uses for `<Name>ValueList`): every bitcase is exactly one fixed
        // scalar field <=4 bytes with resolvable conds. When typable, the
        // request struct's switch field is typed as `<Name>ValueList` (already
        // emitted by the encoder loop above) instead of the opaque placeholder,
        // and the decoder below fills it from the mask + value-list bytes.
        var switch_field: ?xcbproto.Field = null;
        for (req.fields) |field| {
            if (field.kind == .switch_ and field.switch_data != null) {
                switch_field = field;
                break;
            }
        }
        const typed_switch = if (switch_field) |sf|
            switchTypable(reg, p, p.header, sf.switch_data.?)
        else
            false;
        // The switch field's own wire name (e.g. "value_list"); every xproto/xkb
        // request switch uses this name, but derive it rather than hardcode it.
        const vl_field_name: []const u8 = if (switch_field) |sf| sf.name else "values";
        var vl_type_buf: [300]u8 = undefined;
        const vl_type_name: ?[]const u8 = if (typed_switch)
            (std.fmt.bufPrint(&vl_type_buf, "{s}ValueList", .{pascal_name}) catch null)
        else
            null;

        try w.print("pub const {s}Request = struct {{\n", .{pascal_name});
        try emitStructFields(gpa, w, reg, p.header, req.fields, vl_type_name, vl_field_name);
        try w.writeAll("};\n\n");

        // A trailing list is decodable only if the fixed pass halts AT a list
        // field (not at a switch/fd/nested-aggregate first); otherwise fixed_end_
        // does not point at the list base and every list must safe-fallback.
        // Mirrors the same gate the reply decoder uses (ctx_has_length_header
        // is passed as `true`, matching reply/event: neither fixed pass
        // pre-consumes a list the way .struct_elem does, so the struct-element
        // literal-length skip in emitListDecodes must not fire here).
        var req_stop_index: usize = req.fields.len;
        for (req.fields, 0..) |rf, i| {
            if (fixedDecodeHalts(reg, p.header, rf, false)) {
                req_stop_index = i;
                break;
            }
        }
        const req_lists_decodable = req_stop_index < req.fields.len and
            req.fields[req_stop_index].kind == .list;
        var req_avail_fields: std.ArrayListUnmanaged([]const u8) = .empty;
        defer req_avail_fields.deinit(gpa);
        if (req_lists_decodable) {
            for (req.fields) |rf| {
                if (rf.kind == .list) break;
                if (rf.kind == .scalar) try req_avail_fields.append(gpa, rf.name);
            }
        }
        // allow_implicit_len = true: a request's trailing list (the core
        // "Poly*" drawing family - PolyPoint, PolyLine, ...) commonly has no
        // XML length child at all; its count is implied by the request's own
        // total byte length rather than a sibling field. See
        // willDecodeAnyList's doc comment.
        const req_has_lists = req_lists_decodable and
            willDecodeAnyList(reg, p, p.header, req.fields, true, req_avail_fields.items, false, true);
        // A struct-element list builds a ListView/StructIterator VALUE that
        // carries `.endian = native_endian` (same as decodeSized/reply decode);
        // the request decoder must declare `const native_endian` even when its
        // fixed prefix has no multi-byte reads.
        const req_view_list = req_lists_decodable and
            try listDecodeConstructsView(gpa, reg, p, p.header, req.fields, true, req_avail_fields.items, false, true);
        var req_has_any_list = false;
        for (req.fields) |rf| {
            if (rf.kind == .list) {
                req_has_any_list = true;
                break;
            }
        }

        try w.print("pub fn decode{s}Request(bytes: []const u8, endian: std.builtin.Endian) {s}Request {{\n", .{ pascal_name, pascal_name });
        const scan = try prescanFixedFields(gpa, reg, p.header, req.fields, .event);
        const has_reads = scan[0] or typed_switch;
        const needs_endian = scan[1] or req_view_list or (typed_switch and switchValueListNeedsEndian(reg, p.header, switch_field.?.switch_data.?));
        if (!has_reads and !req_has_lists) {
            try w.writeAll("    _ = bytes;\n");
            try w.writeAll("    _ = endian;\n");
            if (req_has_any_list) {
                try w.writeAll("    // TODO(slice4+): fixed header has a pre-list stop (e.g. switch/nested struct); list args not yet decodable\n");
            }
            try w.print("    return std.mem.zeroes({s}Request);\n", .{pascal_name});
        } else {
            if (needs_endian) {
                try w.writeAll("    const native_endian = endian;\n");
            } else {
                try w.writeAll("    _ = endian;\n");
            }
            try w.print("    var result: {s}Request = std.mem.zeroes({s}Request);\n", .{ pascal_name, pascal_name });
            const fixed_end_ = try emitFixedFieldDecodes(gpa, w, reg, p.header, req.fields, .event);
            if (typed_switch) {
                try emitDecodeRequestValueList(
                    w,
                    reg,
                    p,
                    p.header,
                    switch_field.?.switch_data.?,
                    vl_field_name,
                    fixed_end_,
                );
            }
            if (req_has_lists) {
                try w.print("    var list_off_: usize = {d};\n", .{fixed_end_});
                try emitListDecodes(gpa, w, reg, p, p.header, req.fields, true, req_avail_fields.items, "bytes.len", false, true);
            } else if (req_has_any_list) {
                try w.writeAll("    // TODO(slice4+): fixed header has a pre-list stop (e.g. switch/nested struct); list args not yet decodable\n");
            }
            try w.writeAll("    return result;\n");
        }
        try w.writeAll("}\n\n");
    }

    // 5c. Reply encoders: the write-side mirror of the reply decoders above (the
    // outgoing half - a server producing reply bytes rather than a client
    // parsing them). Layout is byte0=1 (reply indicator), the data byte @1,
    // seq @2-3, the length word @4-7, then the fixed body from byte 8, walked
    // by the SAME emitFixedFieldEncodes offset bookkeeping the decoder's own
    // emitFixedFieldDecodes uses - so the two can never disagree on an offset.
    //
    // A run of trailing element-list fields starting right where the fixed
    // walk above halted (emitFixedFieldEncodes's returned fields_consumed -
    // the SAME halt point the walker itself computed, no second scanner)
    // gets its bytes appended immediately after the fixed body: the decoder
    // starts reading its first list at `list_off_ = fixed_end_` with NO
    // rounding (see emitListDecodes), so the encoder must start writing there
    // too. With no trailing list, the fixed part IS the whole reply and gets
    // rounded up to a 4-byte multiple and floored to the 32-byte reply
    // minimum right away, same as before. With a trailing list, that
    // rounding/flooring must NOT happen to the fixed part alone (that would
    // leave a gap before the list, corrupting the layout for any reply whose
    // fixed part is under 32 bytes) - instead every list's bytes are
    // appended back to back with NO inter-list padding either (the decoder's
    // list_off_ += need_ between lists is likewise unrounded), and the 4-byte
    // /32-byte-minimum rounding is applied exactly once, to the grand total.
    // length_units = (total - 32) / 4.
    //
    // A SCALAR-element list's bytes come from sliceAsBytes(r.<field>) (the
    // field is a raw `[]const T` slice). A fixed-size STRUCT-element list's
    // field is a ListView(T) (see emitStructFields); its bytes come directly
    // from r.<field>.bytes - the CONTRACT is that the server populates that
    // ListView's `.bytes` with element bytes it built itself via each
    // element's `T.encodeElement(endian)`, matching the endian this reply is
    // encoded in. The scan stops - leaving the remainder fixed-part-only,
    // per the interim policy above - at the first non-list field or the
    // first VARIABLE-size struct-element list (StructIterator: no fixed
    // stride, not yet a blittable byte run).
    for (p.requests) |req| {
        const reply_fields = req.reply orelse continue;
        const pascal_name = toPascal(req.name, &pascal_buf);
        var edecl_buf: [300]u8 = undefined;
        const edecl = std.fmt.bufPrint(&edecl_buf, "encode{s}Reply", .{pascal_name}) catch pascal_name;
        if (try markEmitted(gpa, &emitted_names, edecl)) continue;

        // Dry run (discarded text) to learn the final fixed-field offset (and
        // how many fields were consumed before halting) before the stack
        // buffer's size must be printed into the generated source.
        var discard_buf: [64]u8 = undefined;
        var discarding = std.Io.Writer.Discarding.init(&discard_buf);
        const fixed_ = try emitFixedFieldEncodes(gpa, &discarding.writer, reg, p.header, reply_fields, .reply);
        const fixed_end_ = fixed_.bytes_written;
        // The dry run wrote no text at all when the field walk halts on its
        // very first field (e.g. a leading pad immediately followed by a
        // list/nested-struct): `r` then goes wholly unused below.
        const wrote_any_field = discarding.fullCount() > 0;

        var list_field_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer list_field_names.deinit(gpa);
        // Parallel to list_field_names: true when the field at the same
        // index is a fixed-size struct-element ListView(T) (blit r.<f>.bytes
        // directly) rather than a scalar-element slice (sliceAsBytes it).
        var list_field_is_struct: std.ArrayListUnmanaged(bool) = .empty;
        defer list_field_is_struct.deinit(gpa);
        {
            var i = fixed_.fields_consumed;
            while (i < reply_fields.len) : (i += 1) {
                const f = reply_fields[i];
                if (f.kind != .list) break; // only a contiguous trailing run of lists
                const vk = vlFieldKind(reg, p.header, f);
                if (vk == .scalar_list) {
                    try list_field_names.append(gpa, f.name);
                    try list_field_is_struct.append(gpa, false);
                } else if (fixedStructElemSize(reg, p.header, f.type_ref) != null) {
                    // Fixed-size struct/union element: a ListView(T) field.
                    try list_field_names.append(gpa, f.name);
                    try list_field_is_struct.append(gpa, true);
                } else {
                    break; // variable-size struct-element list (StructIterator): deferred
                }
            }
        }
        const has_enc_lists = list_field_names.items.len > 0;

        // Fixed buffer size: with no trailing list this IS the final reply
        // size (rounded/floored). With a trailing list it must be the RAW
        // fixed_end_ so the list starts immediately after it, matching the
        // decoder's list_off_ = fixed_end_ exactly - the 32-byte floor and
        // 4-byte rounding get applied only to the grand total further below.
        const fixed_buf_size = if (has_enc_lists) fixed_end_ else @max(((fixed_end_ + 3) / 4) * 4, 32);
        const length_units = (fixed_buf_size -| 32) / 4; // meaningful only when !has_enc_lists

        try w.print(
            "pub fn encode{s}Reply(w: *std.Io.Writer, endian: std.builtin.Endian, seq: u16, r: {s}Reply) error{{WriteFailed}}!void {{\n",
            .{ pascal_name, pascal_name },
        );
        try w.print("    var buf: [{d}]u8 = std.mem.zeroes([{d}]u8);\n", .{ fixed_buf_size, fixed_buf_size });
        try w.writeAll("    buf[0] = 1;\n");
        try w.writeAll("    std.mem.writeInt(u16, buf[2..4], seq, endian);\n");
        if (!has_enc_lists) {
            try w.print("    std.mem.writeInt(u32, buf[4..8], {d}, endian);\n", .{length_units});
        } else {
            // Borrow each list's bytes once, up front, so the same slice is
            // available both for the length word below and for the trailing
            // writeAll calls after the fixed body. Lists are appended back to
            // back with NO inter-list padding (mirrors the decoder's
            // unrounded list_off_ += need_ between lists); only the grand
            // total (fixed part + every list, contiguous) is rounded up to a
            // 4-byte multiple and floored to the 32-byte reply minimum.
            for (list_field_names.items, 0..) |name, li| {
                if (list_field_is_struct.items[li]) {
                    try w.print("    const lb{d}_ = r.", .{li});
                    try writeIdent(w, name);
                    try w.writeAll(".bytes;\n");
                } else {
                    try w.print("    const lb{d}_ = std.mem.sliceAsBytes(r.", .{li});
                    try writeIdent(w, name);
                    try w.writeAll(");\n");
                }
            }
            try w.print("    const body_end_: usize = {d}", .{fixed_buf_size});
            for (0..list_field_names.items.len) |li| {
                try w.print(" + lb{d}_.len", .{li});
            }
            try w.writeAll(";\n");
            try w.writeAll("    const total_: usize = @max(32, (body_end_ + 3) / 4 * 4);\n");
            try w.writeAll("    const pad_: usize = total_ - body_end_;\n");
            try w.writeAll("    std.mem.writeInt(u32, buf[4..8], @intCast((total_ - 32) / 4), endian);\n");
        }
        if (!wrote_any_field and !has_enc_lists) try w.writeAll("    _ = r;\n");
        _ = try emitFixedFieldEncodes(gpa, w, reg, p.header, reply_fields, .reply);
        try w.writeAll("    w.writeAll(&buf) catch return error.WriteFailed;\n");
        if (has_enc_lists) {
            for (0..list_field_names.items.len) |li| {
                try w.print("    w.writeAll(lb{d}_) catch return error.WriteFailed;\n", .{li});
            }
            try w.writeAll("    const zero_pad_: [32]u8 = std.mem.zeroes([32]u8);\n");
            try w.writeAll("    if (pad_ > 0) w.writeAll(zero_pad_[0..pad_]) catch return error.WriteFailed;\n");
        }
        try w.writeAll("}\n\n");
    }

    // Request union + dispatcher (core xproto). Mirrors the Event union.
    if (p.requests.len > 0 and p.extension_xname == null) {
        if (!try markEmitted(gpa, &emitted_names, "Request")) {
            var rbuf: [256]u8 = undefined;
            try w.writeAll("\npub const Request = union(enum) {\n");
            {
                var seen: std.StringHashMapUnmanaged(void) = .{};
                defer {
                    var it = seen.keyIterator();
                    while (it.next()) |k| gpa.free(k.*);
                    seen.deinit(gpa);
                }
                for (p.requests) |req| {
                    const sn = toSnake(req.name, &rbuf);
                    const gop = try seen.getOrPut(gpa, sn);
                    if (gop.found_existing) continue;
                    gop.key_ptr.* = try gpa.dupe(u8, sn);
                    const pn = toPascal(req.name, &pascal_buf);
                    try w.print("    {s}: {s}Request,\n", .{ sn, pn });
                }
            }
            try w.writeAll("    unknown: void,\n};\n\n");
            try w.writeAll("pub fn decodeRequest(opcode: u8, bytes: []const u8, endian: std.builtin.Endian) Request {\n");
            try w.writeAll("    return switch (opcode) {\n");
            {
                var seen_op: std.AutoHashMapUnmanaged(u8, void) = .{};
                defer seen_op.deinit(gpa);
                for (p.requests) |req| {
                    if ((try seen_op.getOrPut(gpa, req.opcode)).found_existing) continue;
                    const sn = toSnake(req.name, &rbuf);
                    const pn = toPascal(req.name, &pascal_buf);
                    try w.print("        {d} => .{{ .{s} = decode{s}Request(bytes, endian) }},\n", .{ req.opcode, sn, pn });
                }
            }
            try w.writeAll("        else => .unknown,\n    };\n}\n\n");

            try w.writeAll("pub fn requestHasReply(opcode: u8) bool {\n");
            try w.writeAll("    return switch (opcode) {\n");
            {
                var seen_reply_op: std.AutoHashMapUnmanaged(u8, void) = .{};
                defer seen_reply_op.deinit(gpa);
                for (p.requests) |req| {
                    if (req.reply == null) continue;
                    if ((try seen_reply_op.getOrPut(gpa, req.opcode)).found_existing) continue;
                    try w.print("        {d},\n", .{req.opcode});
                }
            }
            try w.writeAll("        => true,\n        else => false,\n    };\n}\n\n");
        }
    }

    // 6. Events
    for (p.events) |ev| {
        const pascal_name = toPascal(ev.name, &pascal_buf);
        var name_buf: [300]u8 = undefined;
        const decl_name = std.fmt.bufPrint(&name_buf, "{s}Event", .{pascal_name}) catch pascal_name;
        if (try markEmitted(gpa, &emitted_names, decl_name)) continue;
        try w.print("pub const {s}Event = struct {{\n", .{pascal_name});
        try emitStructFields(gpa, w, reg, p.header, ev.fields, null, "values");
        try w.writeAll("};\n\n");

        // KeymapNotify has no standard event header (no-sequence-number): byte 0
        // is the event code and a fixed-length CARD8 `keys` list starts at byte 1.
        // Decoded directly below rather than falling back.
        const is_keymap = std.mem.eql(u8, ev.name, "KeymapNotify");
        // Otherwise fall back when the first decodable scalar has width != 1
        // (xge/generic-style event where byte-1 is not a detail byte).
        var is_event_fallback = false;
        var event_fallback_reason: []const u8 = "non-1-byte first field layout";
        if (!is_keymap) {
            var saw_leading_pad = false;
            for (ev.fields) |f| {
                switch (f.kind) {
                    .pad => {
                        saw_leading_pad = true;
                        continue;
                    },
                    .scalar => {
                        // Only fall back for width!=1 when NO leading pad consumed
                        // the offset-1 slot. If a pad preceded this scalar, it sits
                        // at offset 4 and decodes fine regardless of width.
                        if (!saw_leading_pad) {
                            const zig_type = reg.scalarBuiltin(p.header, f.type_ref) orelse break;
                            const width = zigWidthFromBuiltin(zig_type) orelse break;
                            if (width != 1) {
                                is_event_fallback = true;
                                event_fallback_reason = "non-1-byte first field layout";
                            }
                        }
                        break;
                    },
                    else => break,
                }
            }
        }

        try w.print("pub fn decode{s}Event(bytes: []const u8) {s}Event {{\n", .{ pascal_name, pascal_name });
        if (is_keymap) {
            // Byte 0 is the event code; the keys list is a fixed literal length
            // starting at byte 1 (no sequence-number header).
            try w.print("    var result: {s}Event = std.mem.zeroes({s}Event);\n", .{ pascal_name, pascal_name });
            var keys_name: []const u8 = "";
            var keys_len: u64 = 0;
            for (ev.fields) |f| {
                if (f.kind == .list) {
                    keys_name = f.name;
                    switch (exprToSimpleLen(f.list_len)) {
                        .literal => |v| keys_len = v,
                        else => {},
                    }
                    break;
                }
            }
            try w.print("    if (bytes.len >= {d}) result.", .{keys_len + 1});
            try writeIdent(w, keys_name);
            try w.print(" = bytes[1..][0..{d}];\n", .{keys_len});
            try w.writeAll("    return result;\n");
        } else if (is_event_fallback) {
            try w.print("    // TODO(slice3+): {s}\n", .{event_fallback_reason});
            try w.writeAll("    _ = bytes;\n");
            try w.print("    return std.mem.zeroes({s}Event);\n", .{pascal_name});
        } else {
            const scan = try prescanFixedFields(gpa, reg, p.header, ev.fields, .event);
            const has_reads = scan[0];
            const needs_endian = scan[1];
            if (!has_reads) {
                try w.writeAll("    _ = bytes;\n");
                try w.print("    return std.mem.zeroes({s}Event);\n", .{pascal_name});
            } else {
                if (needs_endian) {
                    try w.writeAll("    const native_endian = @import(\"builtin\").cpu.arch.endian();\n");
                }
                try w.print("    var result: {s}Event = std.mem.zeroes({s}Event);\n", .{ pascal_name, pascal_name });
                _ = try emitFixedFieldDecodes(gpa, w, reg, p.header, ev.fields, .event);
                try w.writeAll("    return result;\n");
            }
        }
        try w.writeAll("}\n\n");
    }

    // 6b. Event encoders: see emitEventEncoder above for the wire-layout notes.
    for (p.events) |ev| {
        const pascal_name = toPascal(ev.name, &pascal_buf);
        var edecl_buf: [300]u8 = undefined;
        const edecl = std.fmt.bufPrint(&edecl_buf, "encode{s}Event", .{pascal_name}) catch pascal_name;
        if (try markEmitted(gpa, &emitted_names, edecl)) continue;
        const is_keymap = std.mem.eql(u8, ev.name, "KeymapNotify");
        try emitEventEncoder(gpa, w, reg, p.header, pascal_name, ev.number, ev.fields, is_keymap);
    }

    // Event copies (<eventcopy>): identical wire layout to their referenced
    // event, just a different event number. Emit a type + decoder alias so they
    // decode like the original.
    for (p.event_copies) |c| {
        const cp_pascal = toPascal(c.name, &pascal_buf);
        var ref_buf: [256]u8 = undefined;
        const ref_pascal = toPascal(c.ref, &ref_buf);
        var name_buf: [300]u8 = undefined;
        const decl_name = std.fmt.bufPrint(&name_buf, "{s}Event", .{cp_pascal}) catch cp_pascal;
        if (try markEmitted(gpa, &emitted_names, decl_name)) continue;
        try w.print("pub const {s}Event = {s}Event;\n", .{ cp_pascal, ref_pascal });
        try w.print("pub fn decode{s}Event(bytes: []const u8) {s}Event {{ return decode{s}Event(bytes); }}\n\n", .{ cp_pascal, cp_pascal, ref_pascal });
    }

    // Event copy encoders (<eventcopy>): CRITICAL - a copy writes the COPY's
    // OWN number (c.number), NOT the referenced event's number, so this can
    // never be an alias to the ref's encoder. The ref's field layout is looked
    // up via findEventByName purely to walk the (identical) body.
    for (p.event_copies) |c| {
        const cp_pascal = toPascal(c.name, &pascal_buf);
        var edecl_buf: [300]u8 = undefined;
        const edecl = std.fmt.bufPrint(&edecl_buf, "encode{s}Event", .{cp_pascal}) catch cp_pascal;
        if (try markEmitted(gpa, &emitted_names, edecl)) continue;
        // A <eventcopy>'s ref must name a real event in the parsed protocol; a
        // miss is a malformed-protocol/parser invariant violation, not a
        // recoverable case. Fail loudly rather than silently drop the encoder.
        const ref_ev = findEventByName(p, c.ref) orelse
            std.debug.panic("eventcopy '{s}' references unknown event '{s}'", .{ c.name, c.ref });
        const is_keymap = std.mem.eql(u8, c.ref, "KeymapNotify");
        try emitEventEncoder(gpa, w, reg, p.header, cp_pascal, c.number, ref_ev.fields, is_keymap);
    }

    // 7. Errors
    for (p.errors) |err| {
        const pascal_name = toPascal(err.name, &pascal_buf);
        var name_buf: [300]u8 = undefined;
        const decl_name = std.fmt.bufPrint(&name_buf, "{s}Error", .{pascal_name}) catch pascal_name;
        if (try markEmitted(gpa, &emitted_names, decl_name)) continue;
        try w.print("pub const {s}Error = struct {{\n", .{pascal_name});
        try emitStructFields(gpa, w, reg, p.header, err.fields, null, "values");
        try w.writeAll("};\n\n");

        const scan = try prescanFixedFields(gpa, reg, p.header, err.fields, .error_);
        const has_reads = scan[0];
        const needs_endian = scan[1];
        try w.print("pub fn decode{s}Error(bytes: []const u8) {s}Error {{\n", .{ pascal_name, pascal_name });
        if (!has_reads) {
            try w.writeAll("    _ = bytes;\n");
            try w.print("    return std.mem.zeroes({s}Error);\n", .{pascal_name});
        } else {
            if (needs_endian) {
                try w.writeAll("    const native_endian = @import(\"builtin\").cpu.arch.endian();\n");
            }
            try w.print("    var result: {s}Error = std.mem.zeroes({s}Error);\n", .{ pascal_name, pascal_name });
            _ = try emitFixedFieldDecodes(gpa, w, reg, p.header, err.fields, .error_);
            try w.writeAll("    return result;\n");
        }
        try w.writeAll("}\n\n");
    }

    // 7b. Error encoders: see emitErrorEncoder above for the wire-layout notes.
    for (p.errors) |err| {
        const pascal_name = toPascal(err.name, &pascal_buf);
        var edecl_buf: [300]u8 = undefined;
        const edecl = std.fmt.bufPrint(&edecl_buf, "encode{s}Error", .{pascal_name}) catch pascal_name;
        if (try markEmitted(gpa, &emitted_names, edecl)) continue;
        try emitErrorEncoder(gpa, w, reg, p.header, pascal_name, err.number, err.fields);
    }

    // Error copies (<errorcopy>): same as event copies but for errors.
    for (p.error_copies) |c| {
        const cp_pascal = toPascal(c.name, &pascal_buf);
        var ref_buf: [256]u8 = undefined;
        const ref_pascal = toPascal(c.ref, &ref_buf);
        var name_buf: [300]u8 = undefined;
        const decl_name = std.fmt.bufPrint(&name_buf, "{s}Error", .{cp_pascal}) catch cp_pascal;
        if (try markEmitted(gpa, &emitted_names, decl_name)) continue;
        try w.print("pub const {s}Error = {s}Error;\n", .{ cp_pascal, ref_pascal });
        try w.print("pub fn decode{s}Error(bytes: []const u8) {s}Error {{ return decode{s}Error(bytes); }}\n\n", .{ cp_pascal, cp_pascal, ref_pascal });
    }

    // Error copy encoders (<errorcopy>): CRITICAL - a copy writes the COPY's
    // OWN number (c.number), NOT the referenced error's number (e.g.
    // Implementation = 17, referencing Request = 1), so this can never be an
    // alias to the ref's encoder. The ref's field layout is looked up via
    // findErrorByName purely to walk the (identical) body.
    for (p.error_copies) |c| {
        const cp_pascal = toPascal(c.name, &pascal_buf);
        var edecl_buf: [300]u8 = undefined;
        const edecl = std.fmt.bufPrint(&edecl_buf, "encode{s}Error", .{cp_pascal}) catch cp_pascal;
        if (try markEmitted(gpa, &emitted_names, edecl)) continue;
        // A <errorcopy>'s ref must name a real error in the parsed protocol; a
        // miss is a malformed-protocol/parser invariant violation. Fail loudly.
        const ref_err = findErrorByName(p, c.ref) orelse
            std.debug.panic("errorcopy '{s}' references unknown error '{s}'", .{ c.name, c.ref });
        try emitErrorEncoder(gpa, w, reg, p.header, cp_pascal, c.number, ref_err.fields);
    }

    // 8. Event/error number consts (extension-only), Event union + decodeEvent
    // dispatcher (all protocols, including core xproto).
    var snake_buf2: [256]u8 = undefined;

    if (p.extension_xname != null) {
        // 8a. Per-event number consts: pub const {snake}_event_number: u8 = N;
        {
            var seen_ev_names: std.StringHashMapUnmanaged(void) = .{};
            defer {
                var it = seen_ev_names.keyIterator();
                while (it.next()) |k| gpa.free(k.*);
                seen_ev_names.deinit(gpa);
            }
            for (p.events) |ev| {
                const sn = toSnake(ev.name, &snake_buf2);
                const gop = try seen_ev_names.getOrPut(gpa, sn);
                if (gop.found_existing) continue;
                gop.key_ptr.* = try gpa.dupe(u8, sn);
                try w.print("pub const {s}_event_number: u8 = {d};\n", .{ sn, ev.number });
            }
            for (p.event_copies) |c| {
                const sn = toSnake(c.name, &snake_buf2);
                const gop = try seen_ev_names.getOrPut(gpa, sn);
                if (gop.found_existing) continue;
                gop.key_ptr.* = try gpa.dupe(u8, sn);
                try w.print("pub const {s}_event_number: u8 = {d};\n", .{ sn, c.number });
            }
        }

        // 8b. Per-error number consts: pub const {snake}_error_number: u8 = N;
        {
            var seen_err_names: std.StringHashMapUnmanaged(void) = .{};
            defer {
                var it = seen_err_names.keyIterator();
                while (it.next()) |k| gpa.free(k.*);
                seen_err_names.deinit(gpa);
            }
            for (p.errors) |err| {
                const sn = toSnake(err.name, &snake_buf2);
                const gop = try seen_err_names.getOrPut(gpa, sn);
                if (gop.found_existing) continue;
                gop.key_ptr.* = try gpa.dupe(u8, sn);
                try w.print("pub const {s}_error_number: u8 = {d};\n", .{ sn, err.number });
            }
            for (p.error_copies) |c| {
                const sn = toSnake(c.name, &snake_buf2);
                const gop = try seen_err_names.getOrPut(gpa, sn);
                if (gop.found_existing) continue;
                gop.key_ptr.* = try gpa.dupe(u8, sn);
                try w.print("pub const {s}_error_number: u8 = {d};\n", .{ sn, c.number });
            }
        }
    }

    if (p.events.len > 0) {
        // 8c. Event union (skip if name already emitted as some other decl).
        const event_union_already_emitted = try markEmitted(gpa, &emitted_names, "Event");
        if (!event_union_already_emitted) {
            try w.writeAll("\npub const Event = union(enum) {\n");
            {
                // Dedup by snake name; keys must be duped because snake_buf2 is reused.
                var seen_union_fields: std.StringHashMapUnmanaged(void) = .{};
                defer {
                    var it = seen_union_fields.keyIterator();
                    while (it.next()) |k| gpa.free(k.*);
                    seen_union_fields.deinit(gpa);
                }
                for (p.events) |ev| {
                    const sn = toSnake(ev.name, &snake_buf2);
                    const gop = try seen_union_fields.getOrPut(gpa, sn);
                    if (gop.found_existing) continue;
                    gop.key_ptr.* = try gpa.dupe(u8, sn);
                    const pn = toPascal(ev.name, &pascal_buf);
                    try w.print("    {s}: {s}Event,\n", .{ sn, pn });
                }
                for (p.event_copies) |c| {
                    const sn = toSnake(c.name, &snake_buf2);
                    const gop = try seen_union_fields.getOrPut(gpa, sn);
                    if (gop.found_existing) continue;
                    gop.key_ptr.* = try gpa.dupe(u8, sn);
                    const pn = toPascal(c.name, &pascal_buf);
                    try w.print("    {s}: {s}Event,\n", .{ sn, pn });
                }
            }
            try w.writeAll("    unknown: void,\n");
            try w.writeAll("};\n\n");

            // 8d. Dispatcher function.
            const xkb_style = isXkbStyle(reg, p.header, p.events);
            if (xkb_style) {
                try w.writeAll("pub fn decodeEvent(bytes: []const u8) Event {\n");
                try w.writeAll("    if (bytes.len < 2) return .unknown;\n");
                try w.writeAll("    return switch (bytes[1]) {\n");
                var seen_numbers: std.AutoHashMapUnmanaged(u8, void) = .{};
                defer seen_numbers.deinit(gpa);
                for (p.events) |ev| {
                    if ((try seen_numbers.getOrPut(gpa, ev.number)).found_existing) continue;
                    const sn = toSnake(ev.name, &snake_buf2);
                    const pn = toPascal(ev.name, &pascal_buf);
                    try w.print("        {d} => .{{ .{s} = decode{s}Event(bytes) }},\n", .{ ev.number, sn, pn });
                }
                for (p.event_copies) |c| {
                    if ((try seen_numbers.getOrPut(gpa, c.number)).found_existing) continue;
                    const sn = toSnake(c.name, &snake_buf2);
                    const pn = toPascal(c.name, &pascal_buf);
                    try w.print("        {d} => .{{ .{s} = decode{s}Event(bytes) }},\n", .{ c.number, sn, pn });
                }
                try w.writeAll("        else => .unknown,\n");
                try w.writeAll("    };\n");
                try w.writeAll("}\n");
            } else if (p.extension_xname != null) {
                try w.writeAll("pub fn decodeEvent(first_event: u8, bytes: []const u8) Event {\n");
                try w.writeAll("    if (bytes.len < 1 or bytes[0] < first_event) return .unknown;\n");
                try w.writeAll("    return switch (bytes[0] -% first_event) {\n");
                var seen_numbers: std.AutoHashMapUnmanaged(u8, void) = .{};
                defer seen_numbers.deinit(gpa);
                for (p.events) |ev| {
                    if ((try seen_numbers.getOrPut(gpa, ev.number)).found_existing) continue;
                    const sn = toSnake(ev.name, &snake_buf2);
                    const pn = toPascal(ev.name, &pascal_buf);
                    try w.print("        {d} => .{{ .{s} = decode{s}Event(bytes) }},\n", .{ ev.number, sn, pn });
                }
                for (p.event_copies) |c| {
                    if ((try seen_numbers.getOrPut(gpa, c.number)).found_existing) continue;
                    const sn = toSnake(c.name, &snake_buf2);
                    const pn = toPascal(c.name, &pascal_buf);
                    try w.print("        {d} => .{{ .{s} = decode{s}Event(bytes) }},\n", .{ c.number, sn, pn });
                }
                try w.writeAll("        else => .unknown,\n");
                try w.writeAll("    };\n");
                try w.writeAll("}\n");
            } else {
                // Core protocol: absolute event code in bytes[0]; mask the 0x80
                // SendEvent bit so synthetic events dispatch to the same variant.
                try w.writeAll("pub fn decodeEvent(bytes: []const u8) Event {\n");
                try w.writeAll("    if (bytes.len < 1) return .unknown;\n");
                try w.writeAll("    return switch (bytes[0] & 0x7f) {\n");
                var seen_numbers: std.AutoHashMapUnmanaged(u8, void) = .{};
                defer seen_numbers.deinit(gpa);
                for (p.events) |ev| {
                    if ((try seen_numbers.getOrPut(gpa, ev.number)).found_existing) continue;
                    const sn = toSnake(ev.name, &snake_buf2);
                    const pn = toPascal(ev.name, &pascal_buf);
                    try w.print("        {d} => .{{ .{s} = decode{s}Event(bytes) }},\n", .{ ev.number, sn, pn });
                }
                for (p.event_copies) |c| {
                    if ((try seen_numbers.getOrPut(gpa, c.number)).found_existing) continue;
                    const sn = toSnake(c.name, &snake_buf2);
                    const pn = toPascal(c.name, &pascal_buf);
                    try w.print("        {d} => .{{ .{s} = decode{s}Event(bytes) }},\n", .{ c.number, sn, pn });
                }
                try w.writeAll("        else => .unknown,\n");
                try w.writeAll("    };\n");
                try w.writeAll("}\n");
            }
        }
    }
}

// xkb-style: all events share a 1-byte scalar first field with the same name (the discriminator).
fn isXkbStyle(reg: *const registry.Registry, header: []const u8, events: []const xcbproto.Event) bool {
    if (events.len == 0) return false;
    const disc = blk: {
        const e0 = events[0];
        if (e0.fields.len == 0) break :blk null;
        const f0 = e0.fields[0];
        if (f0.kind != .scalar) break :blk null;
        const zt = reg.scalarBuiltin(header, f0.type_ref) orelse break :blk null;
        if ((zigWidthFromBuiltin(zt) orelse 0) != 1) break :blk null;
        break :blk f0.name;
    } orelse return false;
    for (events) |e| {
        if (e.fields.len == 0) return false;
        const f0 = e.fields[0];
        if (f0.kind != .scalar) return false;
        const zt = reg.scalarBuiltin(header, f0.type_ref) orelse return false;
        if ((zigWidthFromBuiltin(zt) orelse 0) != 1) return false;
        if (!std.mem.eql(u8, f0.name, disc)) return false;
    }
    return true;
}

fn genToString(doc_list: []const []const u8, target: usize) (xcbproto.ParseError || EmitError)![]u8 {
    const a = std.testing.allocator;
    var protos = std.ArrayList(xcbproto.Protocol).empty;
    defer {
        for (protos.items) |*p| p.deinit(a);
        protos.deinit(a);
    }
    var reg = registry.Registry.init(a);
    defer reg.deinit();
    for (doc_list) |d| {
        const p = try xcbproto.parse(a, d);
        try protos.append(a, p);
    }
    for (protos.items) |*p| try reg.addProtocol(p);

    var out = std.Io.Writer.Allocating.init(a);
    errdefer out.deinit();
    try generate(a, &out.writer, &protos.items[target], &reg);
    return out.toOwnedSlice();
}

fn expectContains(haystack: []const u8, needle: []const u8) error{NotFound}!void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}

test "emits xid, enum, struct, and reply decoder" {
    const xproto_doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <enum name="GX"><item name="clear"><value>0</value></item><item name="and"><value>1</value></item></enum>
        \\  <struct name="POINT"><field type="INT16" name="x"/><field type="INT16" name="y"/></struct>
        \\  <request name="GetInputFocus" opcode="43"><reply><field type="CARD8" name="revert_to"/><field type="WINDOW" name="focus"/></reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{xproto_doc}, 0);
    defer std.testing.allocator.free(src);

    try expectContains(src, "pub const WINDOW = u32;");
    try expectContains(src, "pub const Gx = enum(u32) {");
    try expectContains(src, "@\"and\" = 1,");
    try expectContains(src, "pub const Point = struct {");
    try expectContains(src, "x: i16,");
    try expectContains(src, "pub const get_input_focus_opcode");
    try expectContains(src, "pub const GetInputFocusReply = struct {");
    try expectContains(src, "focus: WINDOW,");
    try expectContains(src, "pub fn encodeGetInputFocusReply(w: *std.Io.Writer, endian: std.builtin.Endian, seq: u16, r: GetInputFocusReply) error{WriteFailed}!void {");
    try expectContains(src, "buf[1] = r.revert_to;");
    try expectContains(src, "std.mem.writeInt(u32, buf[8..][0..4], r.focus, endian);");
}

test "imported type is module-qualified" {
    const xproto_doc = "<xcb header=\"xproto\"><xidtype name=\"WINDOW\" /></xcb>";
    const xkb_doc =
        \\<xcb header="xkb" extension-name="XKB"><import>xproto</import>
        \\<request name="Foo" opcode="1"><reply><field type="WINDOW" name="w"/></reply></request></xcb>
    ;
    const src = try genToString(&.{ xproto_doc, xkb_doc }, 1);
    defer std.testing.allocator.free(src);
    try expectContains(src, "const xproto = @import(\"xproto\");");
    try expectContains(src, "w: xproto.WINDOW,");
}

// Finding 2: local struct-typed field emits PascalCase; xid stays raw.
test "local struct-typed field uses PascalCase" {
    const doc =
        \\<xcb header="xproto">
        \\  <struct name="POINT"><field type="INT16" name="x"/><field type="INT16" name="y"/></struct>
        \\  <struct name="RECTANGLE"><field type="POINT" name="p"/></struct>
        \\  <xidtype name="WINDOW" />
        \\  <request name="Foo" opcode="1"><reply><field type="WINDOW" name="focus"/></reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);

    // struct declaration is PascalCase
    try expectContains(src, "pub const Rectangle = struct {");
    // field referencing a local struct is also PascalCase
    try expectContains(src, "p: Point,");
    // xid field stays raw
    try expectContains(src, "focus: WINDOW,");
}

// Finding 2: imported struct-typed field emits module.Pascal; xid stays raw.
test "imported struct-typed field uses module.PascalCase" {
    const xproto_doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <struct name="POINT"><field type="INT16" name="x"/><field type="INT16" name="y"/></struct>
        \\</xcb>
    ;
    const xkb_doc =
        \\<xcb header="xkb" extension-name="XKB"><import>xproto</import>
        \\<request name="Bar" opcode="2"><reply>
        \\  <field type="POINT" name="origin"/>
        \\  <field type="WINDOW" name="w"/>
        \\</reply></request></xcb>
    ;
    const src = try genToString(&.{ xproto_doc, xkb_doc }, 1);
    defer std.testing.allocator.free(src);

    // imported struct ref is module.Pascal
    try expectContains(src, "origin: xproto.Point,");
    // imported xid ref stays raw
    try expectContains(src, "w: xproto.WINDOW,");
}

// Finding 1: duplicate enum values -> second item becomes a const alias.
test "duplicate enum value emits const alias" {
    const doc =
        \\<xcb header="xproto">
        \\  <enum name="GX">
        \\    <item name="zero_a"><value>0</value></item>
        \\    <item name="zero_b"><value>0</value></item>
        \\    <item name="one"><value>1</value></item>
        \\  </enum>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);

    // First item with value 0 is in the enum body
    try expectContains(src, "zero_a = 0,");
    // Enum body must NOT contain zero_b as a tag (would be a duplicate)
    // Instead zero_b must appear as a const alias
    try expectContains(src, "pub const ZeroB = Gx.ZeroA;");
    // The unique value 1 is still in the body
    try expectContains(src, "one = 1,");
}

// Finding 3: request whose snake name is a Zig keyword gets @"..." escaping.
test "keyword request name is escaped in fn signature" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="Test" opcode="5"></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);

    try expectContains(src, "pub fn @\"test\"(client_: *x11.Client");
}

// Step 5b: request encoders pack fixed scalar fields into `extra_` in order.
test "request encoder packs scalar fields in declaration order" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="Foo" opcode="7"><field type="CARD16" name="a"/><field type="CARD32" name="b"/></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);

    // Both fields are copied into the extra buffer, a before b.
    const a_idx = std.mem.indexOf(u8, src, "std.mem.asBytes(&a)") orelse return error.NotFound;
    const b_idx = std.mem.indexOf(u8, src, "std.mem.asBytes(&b)") orelse return error.NotFound;
    try std.testing.expect(a_idx < b_idx);
    // No leftover `_ = a;` discard for a packed scalar field.
    try expectContains(src, "@memcpy(extra_[extra_len_..][0..bytes_.len], bytes_);");
}

test "reply with fixed-element list emits borrowed align(1) slice" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <request name="QueryTree" opcode="15"><reply>
        \\    <pad bytes="1"/>
        \\    <field type="WINDOW" name="root"/>
        \\    <field type="WINDOW" name="parent"/>
        \\    <field type="CARD16" name="children_len"/>
        \\    <pad bytes="14"/>
        \\    <list type="WINDOW" name="children"><fieldref>children_len</fieldref></list>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "children: []align(1) const WINDOW = &.{},");
    try expectContains(src, "result.children_len"); // length sourced from decoded field
    try expectContains(src, "bytesAsSlice(WINDOW,");
}

test "reply decoder decodes typedef scalar and following fields" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <typedef oldname="CARD8" newname="KEYCODE" />
        \\  <request name="Foo" opcode="9"><reply>
        \\    <field type="KEYCODE" name="first"/>
        \\    <field type="WINDOW" name="win"/>
        \\    <field type="CARD32" name="tail"/>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "result.first = bytes[1];"); // KEYCODE u8 @1
    try expectContains(src, "std.mem.readInt(u32, bytes[8..][0..4], native_endian)"); // win @8
    try expectContains(src, "bytes[12..][0..4]"); // tail @12
}

test "fixed struct list emits ListView + decodeElement + wire_size" {
    const doc =
        \\<xcb header="xproto">
        \\  <struct name="CharInfo">
        \\    <field type="INT16" name="left"/><field type="INT16" name="right"/>
        \\    <field type="CARD16" name="width"/>
        \\  </struct>
        \\  <request name="QueryFont" opcode="47"><reply>
        \\    <pad bytes="1"/>
        \\    <field type="CARD32" name="char_infos_len"/>
        \\    <pad bytes="20"/>
        \\    <list type="CharInfo" name="char_infos"><fieldref>char_infos_len</fieldref></list>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub fn ListView(comptime T: type) type {");
    try expectContains(src, "pub const wire_size: usize = 6;");
    try expectContains(src, "pub fn decodeElement(bytes: []const u8, endian: std.builtin.Endian)");
    try expectContains(src, "char_infos: ListView(CharInfo) = .{},");
}

test "event decoder decodes detail@1 and body@4" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW"/><typedef oldname="CARD8" newname="KEYCODE"/><typedef oldname="CARD32" newname="TIMESTAMP"/>
        \\  <event name="KeyPress" number="2">
        \\    <field type="KEYCODE" name="detail"/><field type="TIMESTAMP" name="time"/><field type="WINDOW" name="root"/>
        \\  </event>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "result.detail = bytes[1];");
    try expectContains(src, "bytes[4..][0..4]"); // time@4
    try expectContains(src, "bytes[8..][0..4]"); // root@8
}

test "error decoder decodes fields from offset 4" {
    const doc =
        \\<xcb header="xproto">
        \\  <error name="Value" number="2">
        \\    <field type="CARD32" name="bad_value"/><field type="CARD16" name="minor_opcode"/><field type="CARD8" name="major_opcode"/>
        \\  </error>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "bytes[4..][0..4]"); // bad_value@4
    try expectContains(src, "bytes[8..][0..2]"); // minor_opcode@8
    try expectContains(src, "result.major_opcode = bytes[10];"); // @10
}

test "KeymapNotify event decodes its keys list from byte 1" {
    const doc =
        \\<xcb header="xproto">
        \\  <event name="KeymapNotify" number="11">
        \\    <list type="CARD8" name="keys"><value>31</value></list>
        \\  </event>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // No standard header: the 31-byte keys list is borrowed from byte 1 onward,
    // guarded on the full 32-byte event length.
    const idx = std.mem.indexOf(u8, src, "decodeKeymapNotifyEvent").?;
    const tail = src[idx..];
    try expectContains(tail, "if (bytes.len >= 32) result.keys = bytes[1..][0..31];");
}

test "event with leading pad decodes first field at offset 4" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW"/>
        \\  <event name="Expose" number="12">
        \\    <pad bytes="1"/>
        \\    <field type="WINDOW" name="window"/>
        \\    <field type="CARD16" name="x"/>
        \\  </event>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // window (WINDOW u32) decodes at offset 4 (pad consumed offset 1)
    try expectContains(src, "std.mem.readInt(u32, bytes[4..][0..4], native_endian)");
    // x (CARD16) decodes at offset 8
    try expectContains(src, "bytes[8..][0..2]");
}

test "event with wide first field (no pad) falls back" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW"/>
        \\  <event name="Weird" number="35">
        \\    <field type="WINDOW" name="w"/>
        \\    <field type="CARD16" name="x"/>
        \\  </event>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // First field is WINDOW (u32, width 4) AT offset 1 -> xge-style -> fallback to zeroes.
    const idx = std.mem.indexOf(u8, src, "decodeWeirdEvent").?;
    const tail = src[idx..];
    try expectContains(tail, "std.mem.zeroes");
    // Must NOT emit a field read for w (it fell back).
    if (std.mem.indexOf(u8, tail, "result.w = ") != null) return error.ShouldHaveFallenBack;
}

test "reply decodes a nested fixed struct field inline" {
    const doc =
        \\<xcb header="xproto">
        \\  <struct name="Charinfo">
        \\    <field type="INT16" name="left"/><field type="INT16" name="right"/><field type="CARD16" name="width"/>
        \\  </struct>
        \\  <request name="QueryFont" opcode="47"><reply>
        \\    <field type="Charinfo" name="min_bounds"/>
        \\    <field type="CARD16" name="props_len"/>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // min_bounds decodes inline via decodeElement. First reply field is not 1-byte,
    // so the offset-1 slot is skipped and it lands at offset 8.
    try expectContains(src, "result.min_bounds = Charinfo.decodeElement(bytes[8..], native_endian);");
    // props_len (CARD16) decodes AFTER the 6-byte nested struct: 8 + 6 = 14.
    try expectContains(src, "bytes[14..][0..2]");
}

// Nested fixed-struct field BEFORE the list-length field: the struct decodes inline,
// then items_len decodes, then the list is fully decodable. Replaces the slice-2
// safe-fallback test now that nested-struct inline decoding is implemented.
test "reply with nested-struct before list: struct decodes inline and list follows" {
    const doc =
        \\<xcb header="xproto">
        \\  <struct name="Info">
        \\    <field type="INT16" name="a"/><field type="INT16" name="b"/>
        \\  </struct>
        \\  <request name="QueryStuff" opcode="99"><reply>
        \\    <field type="Info" name="min_info"/>
        \\    <field type="CARD32" name="items_len"/>
        \\    <list type="CARD32" name="items"><fieldref>items_len</fieldref></list>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // min_info (Info, wire_size=4) decodes inline at offset 8 (first slot skipped).
    try expectContains(src, "result.min_info = Info.decodeElement(bytes[8..], native_endian);");
    // items_len (CARD32) decodes at offset 8+4=12.
    try expectContains(src, "bytes[12..][0..4]");
    // The list IS decodable: bytesAsSlice must be emitted.
    const idx = std.mem.indexOf(u8, src, "decodeQueryStuffReply").?;
    const tail = src[idx..];
    try expectContains(tail, "bytesAsSlice");
    // items field uses the align(1) slice declaration.
    try expectContains(src, "items: []align(1) const u32 = &.{},");
}

test "popcount length expression emits" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="Foo" opcode="5"><reply>
        \\    <field type="CARD32" name="mask"/>
        \\    <list type="CARD8" name="items"><popcount><fieldref>mask</fieldref></popcount></list>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "@popCount(");
    try expectContains(src, "result.mask");
}

test "op length expression emits via evaluator" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="GetModifierMapping" opcode="119"><reply>
        \\    <field type="CARD8" name="keycodes_per_modifier"/>
        \\    <list type="CARD8" name="keycodes"><op op="*"><fieldref>keycodes_per_modifier</fieldref><value>8</value></op></list>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "result.keycodes_per_modifier");
    try expectContains(src, "* @as(usize, 8)");
}

test "length header fieldref emits readInt bytes[4..8]" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="GetKeyboardMapping" opcode="101"><reply>
        \\    <field type="CARD8" name="keysyms_per_keycode"/>
        \\    <list type="CARD32" name="keysyms"><fieldref>length</fieldref></list>
        \\  </reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "bytes[4..8]");
    try expectContains(src, "native_endian");
    try expectContains(src, "reply_total_");
}

test "variable struct with trailing list gets a decoder" {
    const doc =
        \\<xcb header="xproto">
        \\  <struct name="Str"><field type="CARD8" name="name_len"/><list type="char" name="name"><fieldref>name_len</fieldref></list></struct>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub fn decodeStr(bytes: []const u8) Str {");
    try expectContains(src, "result.name_len = bytes[0];");
    try expectContains(src, "bytesAsSlice(u8,");
}

test "struct-context length field is a real field, not the reply header" {
    const doc =
        \\<xcb header="xproto">
        \\  <struct name="Foo"><field type="CARD16" name="length"/><list type="CARD8" name="data"><fieldref>length</fieldref></list></struct>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // The decode logic lives in the struct's decodeSized method (decodeFoo
    // delegates to it). It must read result.length, NOT the reply header bytes[4..8].
    const idx = std.mem.indexOf(u8, src, "decodeSized").?;
    const tail = src[idx..];
    try expectContains(tail, "result.length");
    if (std.mem.indexOf(u8, tail, "bytes[4..8]") != null) return error.WrongLengthSource;
}

test "encoder routes first 1-byte field to data byte and emits body pads" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="Foo" opcode="7">
        \\    <field type="CARD8" name="mode"/>
        \\    <field type="CARD16" name="a"/>
        \\    <pad bytes="2"/>
        \\    <field type="CARD32" name="b"/>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // `mode` (first 1-byte scalar) is the data byte, passed as the minor arg - NOT packed into extra.
    try expectContains(src, "foo_opcode, mode,");
    if (std.mem.indexOf(u8, src, "asBytes(&mode)") != null) return error.ModeShouldBeDataByte;
    // `a` and `b` ARE packed into the body; the pad advances 2 zero bytes.
    try expectContains(src, "std.mem.asBytes(&a)");
    try expectContains(src, "std.mem.asBytes(&b)");
    try expectContains(src, "extra_len_ += 2;"); // the pad advance
}

test "InternAtom encoder types name, drops name_len, packs allocated body" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="InternAtom" opcode="16"><reply><pad bytes="1"/><field type="CARD32" name="atom"/></reply>
        \\    <field type="BOOL" name="only_if_exists"/>
        \\    <field type="CARD16" name="name_len"/>
        \\    <pad bytes="2"/>
        \\    <list type="char" name="name"><fieldref>name_len</fieldref></list>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "gpa_: std.mem.Allocator");
    try expectContains(src, "name: []const u8");
    // The encoder itself must not take name_len as a param (it is derived from
    // name.len); scope the check to before the request decoder's Request
    // struct, which legitimately re-declares name_len as a real decoded field.
    const encoder_end = std.mem.indexOf(u8, src, "InternAtomRequest = struct") orelse src.len;
    if (std.mem.indexOf(u8, src[0..encoder_end], "name_len: ") != null) return error.NameLenShouldBeDropped;
    try expectContains(src, "@intCast(name.len)"); // name_len written from name.len
    try expectContains(src, "sliceAsBytes(name)"); // name bytes appended
    try expectContains(src, "gpa_.alloc(u8,");
    try expectContains(src, "gpa_.free(");
    try expectContains(src, "intern_atom_opcode, @intFromBool(only_if_exists),"); // data byte routed
}

test "requestListPlan maps InternAtom name list to a derived count" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="InternAtom" opcode="16">
        \\    <field type="BOOL" name="only_if_exists"/>
        \\    <field type="CARD16" name="name_len"/>
        \\    <pad bytes="2"/>
        \\    <list type="char" name="name"><fieldref>name_len</fieldref></list>
        \\  </request>
        \\</xcb>
    ;
    var protos = std.ArrayList(xcbproto.Protocol).empty;
    defer {
        for (protos.items) |*p| p.deinit(std.testing.allocator);
        protos.deinit(std.testing.allocator);
    }
    var reg = registry.Registry.init(std.testing.allocator);
    defer reg.deinit();
    const p = try xcbproto.parse(std.testing.allocator, doc);
    try protos.append(std.testing.allocator, p);
    for (protos.items) |*pp| try reg.addProtocol(pp);

    var lists: std.ArrayListUnmanaged(RequestListInfo) = .empty;
    defer lists.deinit(std.testing.allocator);
    var derived: std.StringHashMapUnmanaged(void) = .{};
    defer derived.deinit(std.testing.allocator);
    try requestListPlan(std.testing.allocator, &reg, "xproto", protos.items[0].requests[0], &lists, &derived);

    try std.testing.expectEqual(@as(usize, 1), lists.items.len);
    try std.testing.expectEqualStrings("name", lists.items[0].name);
    try std.testing.expect(lists.items[0].elem_kind == .char);
    try std.testing.expectEqual(@as(usize, 1), lists.items[0].stride);
    try std.testing.expectEqualStrings("name_len", lists.items[0].count_field.?);
    try std.testing.expect(derived.contains("name_len"));
}

test "extension module emits extension_xname const" {
    const doc = "<xcb header=\"xkb\" extension-xname=\"XKEYBOARD\"><request name=\"Foo\" opcode=\"1\"></request></xcb>";
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub const extension_xname = \"XKEYBOARD\";");
}

test "core module emits no extension_xname" {
    const doc = "<xcb header=\"xproto\"><request name=\"Foo\" opcode=\"1\"></request></xcb>";
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "extension_xname") == null);
}

test "extension encoder uses runtime major, opcode minor, no data byte" {
    const doc =
        \\<xcb header="xkb" extension-xname="XKEYBOARD">
        \\  <request name="Foo" opcode="9">
        \\    <field type="CARD8" name="mode"/>
        \\    <field type="CARD16" name="a"/>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "client_.extensionMajor(extension_xname) orelse return error.ExtensionNotAvailable");
    try expectContains(src, ", foo_opcode, extra_[0..extra_len_])"); // minor = foo_opcode
    try expectContains(src, "std.mem.asBytes(&mode)"); // mode packed into body (not a data byte)
    if (std.mem.indexOf(u8, src, "foo_opcode, mode,") != null) return error.ShouldNotRouteDataByte;
}

test "xkb-style extension emits Event union + decodeEvent on bytes[1]" {
    const doc =
        \\<xcb header="xkb" extension-xname="XKEYBOARD">
        \\  <event name="StateNotify" number="2"><field type="CARD8" name="xkbType"/><field type="CARD8" name="deviceID"/></event>
        \\  <event name="MapNotify" number="1"><field type="CARD8" name="xkbType"/><field type="CARD8" name="deviceID"/></event>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub const state_notify_event_number: u8 = 2;");
    try expectContains(src, "pub const Event = union(enum) {");
    try expectContains(src, "state_notify: StateNotifyEvent,");
    try expectContains(src, "unknown: void,");
    try expectContains(src, "pub fn decodeEvent(bytes: []const u8) Event {");
    try expectContains(src, "switch (bytes[1])");
    try expectContains(src, "2 => .{ .state_notify = decodeStateNotifyEvent(bytes) }");
}

test "classic extension emits decodeEvent(first_event, bytes) on bytes[0]" {
    const doc =
        \\<xcb header="shape" extension-xname="SHAPE">
        \\  <event name="Notify" number="0"><field type="BOOL" name="shape_kind"/><field type="WINDOW" name="affected"/></event>
        \\  <event name="Other" number="1"><field type="CARD16" name="seq"/></event>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // Mixed first fields (BOOL 1-byte vs CARD16 2-byte) -> NOT xkb-style -> classic dispatcher.
    try expectContains(src, "pub fn decodeEvent(first_event: u8, bytes: []const u8) Event {");
    try expectContains(src, "switch (bytes[0] -% first_event)");
}

test "core module emits no per-event number consts" {
    const doc = "<xcb header=\"xproto\"><event name=\"KeyPress\" number=\"2\"><field type=\"CARD8\" name=\"detail\"/></event></xcb>";
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "_event_number") == null);
}

test "core module emits Event union + masked decodeEvent on bytes[0]" {
    const doc =
        \\<xcb header="xproto">
        \\  <event name="KeyPress" number="2"><field type="CARD8" name="detail"/></event>
        \\  <event name="MotionNotify" number="6"><field type="CARD8" name="is_hint"/></event>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub const Event = union(enum) {");
    try expectContains(src, "key_press: KeyPressEvent,");
    try expectContains(src, "unknown: void,");
    try expectContains(src, "pub fn decodeEvent(bytes: []const u8) Event {");
    try expectContains(src, "switch (bytes[0] & 0x7f)");
    try expectContains(src, "2 => .{ .key_press = decodeKeyPressEvent(bytes) }");
}

test "core module emits Request union + decodeRequest dispatcher" {
    const doc =
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <xidtype name="DRAWABLE" />
        \\  <request name="MapWindow" opcode="8"><field type="WINDOW" name="window"/></request>
        \\  <request name="GetGeometry" opcode="14"><field type="DRAWABLE" name="drawable"/></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub const Request = union(enum) {");
    try expectContains(src, "map_window: MapWindowRequest,");
    try expectContains(src, "unknown: void,");
    try expectContains(src, "pub fn decodeRequest(opcode: u8, bytes: []const u8, endian: std.builtin.Endian) Request {");
    try expectContains(src, "8 => .{ .map_window = decodeMapWindowRequest(bytes, endian) }");
    try expectContains(src, "pub fn requestHasReply(opcode: u8) bool {");
}

test "single-field switch emits value-list struct + derived mask" {
    const doc =
        \\<xcb header="xproto">
        \\  <enum name="CW"><item name="BackPixmap"><bit>0</bit></item><item name="BackPixel"><bit>1</bit></item></enum>
        \\  <xidtype name="PIXMAP"/>
        \\  <request name="CreateWindow" opcode="1">
        \\    <field type="CARD32" name="value_mask" mask="CW"/>
        \\    <switch name="value_list"><fieldref>value_mask</fieldref>
        \\      <bitcase><enumref ref="CW">BackPixmap</enumref><field type="PIXMAP" name="background_pixmap"/></bitcase>
        \\      <bitcase><enumref ref="CW">BackPixel</enumref><field type="CARD32" name="background_pixel"/></bitcase>
        \\    </switch>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub const CreateWindowValueList = struct {");
    try expectContains(src, "background_pixmap: ?PIXMAP = null,");
    try expectContains(src, "background_pixel: ?u32 = null,");
    try expectContains(src, "value_list_: CreateWindowValueList");
    if (std.mem.indexOf(u8, src, "background_pixmap: PIXMAP,") != null) return error.LeakedBitcaseParam;
    // The encoder itself must not take value_mask as a param (it is derived
    // from which value_list_ optionals are set); scope the check to before the
    // request decoder's Request struct, which legitimately re-declares
    // value_mask as a real decoded field.
    const encoder_end = std.mem.indexOf(u8, src, "CreateWindowRequest = struct") orelse src.len;
    if (std.mem.indexOf(u8, src[0..encoder_end], "value_mask: u32,") != null) return error.MaskShouldBeDerived;
    if (std.mem.indexOf(u8, src, "values_: []const u8") != null) return error.LeakedValuesPassthrough;
    try expectContains(src, "if (value_list_.background_pixel) |_| mask_ |= 2;"); // bit 1 -> 2
    try expectContains(src, "if (value_list_.background_pixmap) |_| mask_ |= 1;"); // bit 0 -> 1
    try expectContains(src, "var mask_: u32 = 0;");
}

test "typed switch appends set value-list entries as 4-byte words in bit order" {
    const doc =
        \\<xcb header="xproto">
        \\  <enum name="CW"><item name="BackPixmap"><bit>0</bit></item><item name="BackPixel"><bit>1</bit></item></enum>
        \\  <xidtype name="PIXMAP"/>
        \\  <request name="CreateWindow" opcode="1">
        \\    <field type="CARD32" name="value_mask" mask="CW"/>
        \\    <switch name="value_list"><fieldref>value_mask</fieldref>
        \\      <bitcase><enumref ref="CW">BackPixmap</enumref><field type="PIXMAP" name="background_pixmap"/></bitcase>
        \\      <bitcase><enumref ref="CW">BackPixel</enumref><field type="CARD32" name="background_pixel"/></bitcase>
        \\    </switch>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // Two append blocks, one per bitcase field, in bit order (background_pixmap before background_pixel).
    try expectContains(src, "if (value_list_.background_pixmap) |v_| {");
    try expectContains(src, "if (value_list_.background_pixel) |v_| {");
    try expectContains(src, "var w4_: [4]u8 = .{ 0, 0, 0, 0 };");
    try expectContains(src, "@memcpy(body_[off_..][0..4], &w4_);");
    const i_pixmap = std.mem.indexOf(u8, src, "if (value_list_.background_pixmap) |v_| {").?;
    const i_pixel = std.mem.indexOf(u8, src, "if (value_list_.background_pixel) |v_| {").?;
    try std.testing.expect(i_pixmap < i_pixel); // bit order
}

test "switch with a wide (8-byte) bitcase field is not typed" {
    // A CARD64 value-list entry cannot fit the 4-byte word slot, so the whole
    // switch must stay non-typable and fall back to the raw passthrough.
    const doc =
        \\<xcb header="xproto">
        \\  <enum name="CW"><item name="A"><bit>0</bit></item></enum>
        \\  <request name="Wide" opcode="1">
        \\    <field type="CARD32" name="value_mask" mask="CW"/>
        \\    <switch name="value_list"><fieldref>value_mask</fieldref>
        \\      <bitcase><enumref ref="CW">A</enumref><field type="CARD64" name="big"/></bitcase>
        \\    </switch>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "values_: []const u8");
    try std.testing.expect(std.mem.indexOf(u8, src, "WideValueList") == null);
}

test "union emits wire-sized raw storage and a scalar accessor" {
    const doc =
        \\<xcb header="xproto">
        \\  <union name="ClientData"><field type="CARD16" name="short"/><field type="CARD32" name="word"/></union>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "pub const ClientData = struct {");
    try expectContains(src, "raw: [4]u8"); // max(2, 4) = 4
    try expectContains(src, "pub const wire_size: usize = 4;");
    try expectContains(src, "pub fn asWord(self: @This()) u32 {");
}

test "variable-struct element list emits a StructIterator field" {
    const doc =
        \\<xcb header="xproto">
        \\  <struct name="STR"><field type="CARD8" name="name_len"/><list type="char" name="name"><fieldref>name_len</fieldref></list></struct>
        \\  <request name="ListFonts" opcode="49"><reply><pad bytes="1"/><field type="CARD16" name="names_len"/><pad bytes="22"/><list type="STR" name="names"><fieldref>names_len</fieldref></list></reply></request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    try expectContains(src, "names: StructIterator(Str)");
}

test "structured switch: multi-field bitcases with derived mask and natural packing" {
    const doc =
        \\<xcb header="test">
        \\  <enum name="ET"><item name="A"><bit>0</bit></item><item name="B"><bit>1</bit></item></enum>
        \\  <request name="Foo" opcode="1">
        \\    <field type="CARD16" name="affect" mask="ET"/>
        \\    <switch name="details"><fieldref>affect</fieldref>
        \\      <bitcase><enumref ref="ET">A</enumref><field type="CARD16" name="affectA"/><field type="CARD16" name="detailsA"/></bitcase>
        \\      <bitcase><enumref ref="ET">B</enumref><field type="CARD16" name="affectB"/><field type="CARD16" name="detailsB"/></bitcase>
        \\    </switch>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // Typed value list with a per-bitcase sub-struct (multi-field).
    try expectContains(src, "pub const FooValueList = struct {");
    try expectContains(src, "a: ?struct {");
    try expectContains(src, "affectA: u16,");
    try expectContains(src, "b: ?struct {");
    // The simple-fieldref mask is derived and the mask param dropped.
    try expectContains(src, "value_list_: FooValueList");
    try expectContains(src, "var mask_: u16 = 0;");
    try expectContains(src, "if (value_list_.a) |_| mask_ |= 1;");
    try expectContains(src, "if (value_list_.b) |_| mask_ |= 2;");
    if (std.mem.indexOf(u8, src, ", affect: u16") != null) return error.MaskShouldBeDerived;
    // Natural-size packing of each present bitcase's fields (no 4-byte word).
    try expectContains(src, "if (value_list_.a) |v_| {");
    try expectContains(src, "std.mem.asBytes(&v_.affectA)");
    try expectContains(src, "std.mem.asBytes(&v_.detailsA)");
    if (std.mem.indexOf(u8, src, "w4_") != null) return error.ShouldNotPad4;
}

test "structured switch: list bitcases, multi-list group with pad, derived mask" {
    const doc =
        \\<xcb header="test">
        \\  <enum name="D"><item name="A"><bit>0</bit></item><item name="B"><bit>1</bit></item></enum>
        \\  <request name="Foo" opcode="1">
        \\    <field type="CARD32" name="which" mask="D"/>
        \\    <switch name="values"><fieldref>which</fieldref>
        \\      <bitcase><enumref ref="D">A</enumref><list type="CARD32" name="alist"><fieldref>n</fieldref></list></bitcase>
        \\      <bitcase><enumref ref="D">B</enumref><list type="CARD8" name="counts"><fieldref>n</fieldref></list><pad align="4"/><list type="CARD32" name="names"><fieldref>n</fieldref></list></bitcase>
        \\    </switch>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // Single scalar-list bitcase -> typed ?[]const T named by the field.
    try expectContains(src, "alist: ?[]const u32 = null,");
    // Multi-list bitcase -> a sub-struct named by the cond (B -> b).
    try expectContains(src, "b: ?struct {");
    try expectContains(src, "counts: []const u8,");
    try expectContains(src, "names: []const u32,");
    // Mask derived, `which` param dropped.
    try expectContains(src, "if (value_list_.alist) |_| mask_ |= 1;");
    try expectContains(src, "if (value_list_.b) |_| mask_ |= 2;");
    if (std.mem.indexOf(u8, src, ", which: u32") != null) return error.MaskShouldBeDerived;
    // Packing: scalar lists via sliceAsBytes, with the inter-list align pad.
    try expectContains(src, "std.mem.sliceAsBytes(v_.counts)");
    try expectContains(src, "off_ = (off_ + 3) & ~@as(usize, 3);");
    try expectContains(src, "std.mem.sliceAsBytes(v_.names)");
}

test "exprfield data byte: computed value, escaped operator, element-count division" {
    const doc =
        \\<xcb header="test">
        \\  <struct name="Char2b"><field type="CARD8" name="a"/><field type="CARD8" name="b"/></struct>
        \\  <request name="Foo" opcode="1">
        \\    <exprfield type="BOOL" name="odd"><op op="&amp;"><fieldref>data_len</fieldref><value>1</value></op></exprfield>
        \\    <field type="CARD32" name="thing"/>
        \\    <list type="Char2b" name="data"/>
        \\  </request>
        \\</xcb>
    ;
    const src = try genToString(&.{doc}, 0);
    defer std.testing.allocator.free(src);
    // The exprfield is neither a param nor a values_ passthrough.
    if (std.mem.indexOf(u8, src, "odd: ") != null) return error.ExprfieldShouldNotBeParam;
    if (std.mem.indexOf(u8, src, "values_: []const u8") != null) return error.ShouldNotPassthrough;
    // Data byte = (element-count) & 1, element count = data.len / 2 (2-byte struct).
    // The `&` came through XML-escaped and must map to & (not the + fallback).
    try expectContains(src, "foo_opcode, @intCast((data.len / 2 & @as(usize, 1)))");
}
