const std = @import("std");
const xml = @import("xml");

/// Parsing faults: the xml reader can report a malformed document or an
/// unreadable stream, and any reader call or node dup can run out of memory.
/// This is parse()'s public contract.
pub const ParseError = error{ OutOfMemory, MalformedXml, ReadFailed };

/// Expression parsing additionally uses UnsupportedExpr as an internal control
/// signal: an unknown element yields a null list length rather than a wrong
/// tree. Callers inside parse() peel it off, so it is not part of ParseError.
const ExprError = ParseError || error{UnsupportedExpr};

pub const FieldType = enum { scalar, list, pad, fd, exprfield, switch_ };

pub const Expr = union(enum) {
    value: i64,
    fieldref: []const u8, // owned
    enumref: struct { enum_name: []const u8, item: []const u8 }, // both owned
    op: struct { operator: []const u8, lhs: *Expr, rhs: *Expr }, // operator owned
    unop: struct { operator: []const u8, operand: *Expr }, // operator owned
    popcount: *Expr,
    sumof: struct { list_ref: []const u8, inner: ?*Expr }, // list_ref owned
    listelement_ref,
    bit: u6,
};

pub fn freeExpr(gpa: std.mem.Allocator, e: *Expr) void {
    switch (e.*) {
        .fieldref => |s| gpa.free(s),
        .enumref => |r| {
            gpa.free(r.enum_name);
            gpa.free(r.item);
        },
        .op => |o| {
            gpa.free(o.operator);
            freeExpr(gpa, o.lhs);
            freeExpr(gpa, o.rhs);
        },
        .unop => |o| {
            gpa.free(o.operator);
            freeExpr(gpa, o.operand);
        },
        .popcount => |c| freeExpr(gpa, c),
        .sumof => |s| {
            gpa.free(s.list_ref);
            if (s.inner) |i| freeExpr(gpa, i);
        },
        .value, .listelement_ref, .bit => {},
    }
    gpa.destroy(e);
}

pub const EnumCond = struct { enum_name: []const u8, item: []const u8 };
pub const Bitcase = struct { conds: []EnumCond, fields: []Field };
pub const Switch = struct { mask_fieldref: []const u8, bitcases: []Bitcase };

pub fn freeSwitch(gpa: std.mem.Allocator, s: *Switch) void {
    gpa.free(s.mask_fieldref);
    for (s.bitcases) |*bc| {
        for (bc.conds) |c| {
            gpa.free(c.enum_name);
            gpa.free(c.item);
        }
        gpa.free(bc.conds);
        freeFields(gpa, bc.fields);
    }
    gpa.free(s.bitcases);
    gpa.destroy(s);
}

pub const Field = struct {
    kind: FieldType,
    name: []const u8,
    type_ref: []const u8,
    list_len: ?*Expr = null,
    /// Captured <switch> subtree (only meaningful when kind == .switch_).
    switch_data: ?*Switch = null,
    /// Number of pad bytes (only meaningful when kind == .pad and pad_align == false).
    /// Defaults to 1 when <pad> has no attributes.
    pad_bytes: usize = 1,
    /// True when this pad is an align-style pad (<pad align="N"/>), meaning
    /// the byte count is variable at runtime and fixedSizeOf must return null.
    pad_align: bool = false,
};

pub const EnumItem = struct { name: []const u8, value: i64, is_bit: bool };

pub const Enum = struct { name: []const u8, items: []EnumItem };

pub const XidType = struct { name: []const u8 };

pub const StructDef = struct { name: []const u8, fields: []Field };

pub const UnionDef = struct { name: []const u8, fields: []Field };

pub const Typedef = struct { oldname: []const u8, newname: []const u8 };

pub const Request = struct { name: []const u8, opcode: u8, fields: []Field, reply: ?[]Field };

pub const Event = struct { name: []const u8, number: u8, fields: []Field };

pub const ErrorDef = struct { name: []const u8, number: u8, fields: []Field };

pub const Copy = struct { name: []const u8, number: u8, ref: []const u8 };

pub const Protocol = struct {
    header: []const u8,
    extension_xname: ?[]const u8 = null,
    imports: [][]const u8,
    enums: []Enum,
    xids: []XidType,
    structs: []StructDef,
    unions: []UnionDef,
    typedefs: []Typedef,
    requests: []Request,
    events: []Event,
    errors: []ErrorDef,
    event_copies: []Copy,
    error_copies: []Copy,

    pub fn deinit(self: *Protocol, gpa: std.mem.Allocator) void {
        gpa.free(self.header);
        if (self.extension_xname) |x| gpa.free(x);

        for (self.imports) |imp| gpa.free(imp);
        gpa.free(self.imports);

        for (self.enums) |*e| {
            gpa.free(e.name);
            for (e.items) |item| gpa.free(item.name);
            gpa.free(e.items);
        }
        gpa.free(self.enums);

        for (self.xids) |x| gpa.free(x.name);
        gpa.free(self.xids);

        for (self.structs) |*s| {
            gpa.free(s.name);
            for (s.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |sw| freeSwitch(gpa, sw);
            }
            gpa.free(s.fields);
        }
        gpa.free(self.structs);

        for (self.unions) |*u| {
            gpa.free(u.name);
            for (u.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(u.fields);
        }
        gpa.free(self.unions);

        for (self.typedefs) |t| {
            gpa.free(t.oldname);
            gpa.free(t.newname);
        }
        gpa.free(self.typedefs);

        for (self.requests) |*r| {
            gpa.free(r.name);
            for (r.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(r.fields);
            if (r.reply) |reply_fields| {
                for (reply_fields) |f| {
                    gpa.free(f.name);
                    gpa.free(f.type_ref);
                    if (f.list_len) |le| freeExpr(gpa, le);
                    if (f.switch_data) |s| freeSwitch(gpa, s);
                }
                gpa.free(reply_fields);
            }
        }
        gpa.free(self.requests);

        for (self.events) |*e| {
            gpa.free(e.name);
            for (e.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(e.fields);
        }
        gpa.free(self.events);

        for (self.errors) |*e| {
            gpa.free(e.name);
            for (e.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(e.fields);
        }
        gpa.free(self.errors);

        for (self.event_copies) |c| {
            gpa.free(c.name);
            gpa.free(c.ref);
        }
        gpa.free(self.event_copies);

        for (self.error_copies) |c| {
            gpa.free(c.name);
            gpa.free(c.ref);
        }
        gpa.free(self.error_copies);
    }
};

fn attr(reader: *xml.Reader, name: []const u8) ?[]const u8 {
    const n = reader.attributeCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, reader.attributeName(i), name))
            return reader.attributeValueRaw(i);
    }
    return null;
}

// --- Recursive expression parser ---------------------------------------------
// These helpers drive the same `reader.read()` stream as the main parser. They
// build an `*Expr` tree for a list-length expression subtree and leave the
// reader positioned just after the parsed element's matching close tag.

// Consume nodes until the matching `element_end` of the currently-open element
// `el`, discarding any nested content. Used to safely skip unsupported elements.
fn skipElement(reader: *xml.Reader, el: []const u8) ParseError!void {
    var depth: usize = 1;
    while (true) {
        const node = try reader.read();
        switch (node) {
            .eof => return,
            .element_start => depth += 1,
            .element_end => {
                depth -= 1;
                if (depth == 0) {
                    _ = el;
                    return;
                }
            },
            else => {},
        }
    }
}

// The current element `el` is a text-only leaf. Accumulate its text children
// until its matching `element_end`, returning the trimmed text (borrowed from
// the caller-provided buffer). Any nested elements are skipped.
fn readLeafText(gpa: std.mem.Allocator, reader: *xml.Reader, buf: *std.ArrayList(u8)) ParseError![]const u8 {
    buf.clearRetainingCapacity();
    var depth: usize = 1;
    while (true) {
        const node = try reader.read();
        switch (node) {
            .eof => break,
            .text => if (depth == 1) try buf.appendSlice(gpa, reader.textRaw()),
            .element_start => depth += 1,
            .element_end => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    return std.mem.trim(u8, buf.items, " \t\r\n");
}

// Read forward until the next child `element_start`, then parse that element as
// an expression. Returns `error.UnsupportedExpr` if the parent closes before any
// supported child element is found. Loops past unsupported children so the reader
// stays in sync (sumof close tag is not consumed on an unsupported-inner path).
fn parseNextChildExpr(gpa: std.mem.Allocator, reader: *xml.Reader) ExprError!*Expr {
    while (true) {
        const node = try reader.read();
        switch (node) {
            .eof => return error.UnsupportedExpr,
            .element_start => {
                const child = reader.elementName();
                return parseExprElement(gpa, reader, child) catch |err| switch (err) {
                    error.UnsupportedExpr => continue, // skip this child, try the next
                    else => return err,
                };
            },
            .element_end => return error.UnsupportedExpr,
            else => {},
        }
    }
}

// Parse ONE expression element. The reader has just returned this element's
// `element_start` and `el` is its name. On success returns an owned `*Expr` and
// leaves the reader positioned after the element's matching close tag. On an
// unknown element, consumes it and returns `error.UnsupportedExpr`. Every
// allocation is guarded so a partial tree is fully freed on any error.
// The `op`/`unop` operator attribute is read raw, so XML-escaped operators
// arrive unexpanded (op="&amp;" -> "&amp;"). Map the escaped forms back to the
// real operator so downstream comparisons ("&", "<<", ">>") match.
fn normalizeOp(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "&amp;")) return "&";
    if (std.mem.eql(u8, raw, "&lt;&lt;")) return "<<";
    if (std.mem.eql(u8, raw, "&gt;&gt;")) return ">>";
    if (std.mem.eql(u8, raw, "&lt;")) return "<";
    if (std.mem.eql(u8, raw, "&gt;")) return ">";
    return raw;
}

fn parseExprElement(gpa: std.mem.Allocator, reader: *xml.Reader, el: []const u8) ExprError!*Expr {
    const eql = std.mem.eql;

    if (eql(u8, el, "value")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const text = try readLeafText(gpa, reader, &buf);
        const v = std.fmt.parseInt(i64, text, 10) catch return error.MalformedXml;
        node.* = .{ .value = v };
        return node;
    } else if (eql(u8, el, "bit")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const text = try readLeafText(gpa, reader, &buf);
        const v = std.fmt.parseInt(u6, text, 10) catch return error.MalformedXml;
        node.* = .{ .bit = v };
        return node;
    } else if (eql(u8, el, "fieldref")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const text = try readLeafText(gpa, reader, &buf);
        const owned = try gpa.dupe(u8, text);
        node.* = .{ .fieldref = owned };
        return node;
    } else if (eql(u8, el, "enumref")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        const ref = attr(reader, "ref") orelse "";
        const enum_name = try gpa.dupe(u8, ref);
        errdefer gpa.free(enum_name);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const text = try readLeafText(gpa, reader, &buf);
        const item = try gpa.dupe(u8, text);
        node.* = .{ .enumref = .{ .enum_name = enum_name, .item = item } };
        return node;
    } else if (eql(u8, el, "op")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        const operator = try gpa.dupe(u8, normalizeOp(attr(reader, "op") orelse ""));
        errdefer gpa.free(operator);
        const lhs = try parseNextChildExpr(gpa, reader);
        errdefer freeExpr(gpa, lhs);
        const rhs = try parseNextChildExpr(gpa, reader);
        errdefer freeExpr(gpa, rhs);
        try consumeElementClose(reader, el);
        node.* = .{ .op = .{ .operator = operator, .lhs = lhs, .rhs = rhs } };
        return node;
    } else if (eql(u8, el, "unop")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        const operator = try gpa.dupe(u8, normalizeOp(attr(reader, "op") orelse ""));
        errdefer gpa.free(operator);
        const operand = try parseNextChildExpr(gpa, reader);
        errdefer freeExpr(gpa, operand);
        try consumeElementClose(reader, el);
        node.* = .{ .unop = .{ .operator = operator, .operand = operand } };
        return node;
    } else if (eql(u8, el, "popcount")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        const inner = try parseNextChildExpr(gpa, reader);
        errdefer freeExpr(gpa, inner);
        try consumeElementClose(reader, el);
        node.* = .{ .popcount = inner };
        return node;
    } else if (eql(u8, el, "sumof")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        const list_ref = try gpa.dupe(u8, attr(reader, "ref") orelse "");
        errdefer gpa.free(list_ref);
        // sumof may optionally contain a nested expression child.
        const inner = parseNextChildExpr(gpa, reader) catch |err| switch (err) {
            error.UnsupportedExpr => {
                // No child expression (parent closed already): inner is null.
                node.* = .{ .sumof = .{ .list_ref = list_ref, .inner = null } };
                return node;
            },
            else => return err,
        };
        errdefer freeExpr(gpa, inner);
        try consumeElementClose(reader, el);
        node.* = .{ .sumof = .{ .list_ref = list_ref, .inner = inner } };
        return node;
    } else if (eql(u8, el, "listelement-ref")) {
        const node = try gpa.create(Expr);
        errdefer gpa.destroy(node);
        try skipElement(reader, el);
        node.* = .listelement_ref;
        return node;
    } else {
        // Unknown expression element (e.g. <paramref>). Prefer a null length
        // over a wrong tree: consume it and signal unsupported.
        try skipElement(reader, el);
        return error.UnsupportedExpr;
    }
}

// After a container element's children have been parsed, consume the reader up
// to and including that element's matching `element_end`.
fn consumeElementClose(reader: *xml.Reader, el: []const u8) ParseError!void {
    var depth: usize = 1;
    while (true) {
        const node = try reader.read();
        switch (node) {
            .eof => return,
            .element_start => depth += 1,
            .element_end => {
                depth -= 1;
                if (depth == 0) {
                    _ = el;
                    return;
                }
            },
            else => {},
        }
    }
}

fn freeFields(gpa: std.mem.Allocator, fields: []Field) void {
    for (fields) |f| {
        gpa.free(f.name);
        gpa.free(f.type_ref);
        if (f.list_len) |le| freeExpr(gpa, le);
        if (f.switch_data) |s| freeSwitch(gpa, s);
    }
    gpa.free(fields);
}

const SwitchError = ParseError;

// Parse a single <bitcase>. The reader has just returned the <bitcase>
// element_start. Collects <enumref> conds and plain scalar <field>s until the
// matching </bitcase>. Any nested <switch>/<list>/<pad>/other element is fully
// consumed (via skipElement) but dropped - the bitcase is captured with only
// its plain scalar fields (codegen detects non-typability later). The reader is
// left positioned after </bitcase>. On any error every partial allocation is
// freed.
fn parseBitcase(gpa: std.mem.Allocator, reader: *xml.Reader) SwitchError!Bitcase {
    var conds: std.ArrayList(EnumCond) = .empty;
    errdefer {
        for (conds.items) |c| {
            gpa.free(c.enum_name);
            gpa.free(c.item);
        }
        conds.deinit(gpa);
    }
    var fields: std.ArrayList(Field) = .empty;
    errdefer {
        for (fields.items) |f| {
            gpa.free(f.name);
            gpa.free(f.type_ref);
            if (f.list_len) |le| freeExpr(gpa, le);
            if (f.switch_data) |s| freeSwitch(gpa, s);
        }
        fields.deinit(gpa);
    }

    while (true) {
        const node = try reader.read();
        switch (node) {
            .eof => break,
            .element_start => {
                const el = reader.elementName();
                if (std.mem.eql(u8, el, "enumref")) {
                    const ref = attr(reader, "ref") orelse "";
                    const enum_name = try gpa.dupe(u8, ref);
                    errdefer gpa.free(enum_name);
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(gpa);
                    const text = try readLeafText(gpa, reader, &buf);
                    const item = try gpa.dupe(u8, text);
                    errdefer gpa.free(item);
                    try conds.append(gpa, .{ .enum_name = enum_name, .item = item });
                } else if (std.mem.eql(u8, el, "field")) {
                    const f_name = attr(reader, "name") orelse "";
                    const f_type = attr(reader, "type") orelse "";
                    const name = try gpa.dupe(u8, f_name);
                    errdefer gpa.free(name);
                    const type_ref = try gpa.dupe(u8, f_type);
                    errdefer gpa.free(type_ref);
                    try fields.append(gpa, .{
                        .kind = .scalar,
                        .name = name,
                        .type_ref = type_ref,
                        .list_len = null,
                        .switch_data = null,
                    });
                    // <field> may be self-closing or have children; consume to close.
                    try skipElement(reader, el);
                } else if (std.mem.eql(u8, el, "list")) {
                    const l_name = attr(reader, "name") orelse "";
                    const l_type = attr(reader, "type") orelse "";
                    const name = try gpa.dupe(u8, l_name);
                    errdefer gpa.free(name);
                    const type_ref = try gpa.dupe(u8, l_type);
                    errdefer gpa.free(type_ref);
                    // Parse the list's length expression (first child). On an
                    // absent/unsupported child, parseNextChildExpr has already
                    // consumed </list>; otherwise we consume it below.
                    const len_expr = parseNextChildExpr(gpa, reader) catch |err| switch (err) {
                        error.UnsupportedExpr => null,
                        else => |e| return e,
                    };
                    errdefer if (len_expr) |le| freeExpr(gpa, le);
                    try fields.append(gpa, .{
                        .kind = .list,
                        .name = name,
                        .type_ref = type_ref,
                        .list_len = len_expr,
                        .switch_data = null,
                    });
                    if (len_expr != null) try consumeElementClose(reader, el);
                } else if (std.mem.eql(u8, el, "pad")) {
                    const is_align = attr(reader, "align") != null;
                    const pb: usize = if (!is_align) blk: {
                        const bstr = attr(reader, "bytes") orelse "1";
                        break :blk std.fmt.parseInt(usize, bstr, 10) catch return error.MalformedXml;
                    } else 0;
                    try fields.append(gpa, .{
                        .kind = .pad,
                        .name = try gpa.dupe(u8, ""),
                        .type_ref = try gpa.dupe(u8, ""),
                        .list_len = null,
                        .pad_bytes = pb,
                        .pad_align = is_align,
                    });
                    try skipElement(reader, el);
                } else {
                    // Other nested content (e.g. a nested <switch>): drop for now.
                    try skipElement(reader, el);
                }
            },
            .element_end => {
                // Matching </bitcase> (any other close would be a nested close
                // already swallowed by skipElement / readLeafText).
                break;
            },
            else => {},
        }
    }

    const conds_owned = try conds.toOwnedSlice(gpa);
    errdefer {
        for (conds_owned) |c| {
            gpa.free(c.enum_name);
            gpa.free(c.item);
        }
        gpa.free(conds_owned);
    }
    const fields_owned = try fields.toOwnedSlice(gpa);
    return .{ .conds = conds_owned, .fields = fields_owned };
}

// Parse a <switch> subtree. The reader has just returned the <switch>
// element_start. Consumes the whole subtree (fieldref + every bitcase, incl any
// nested switch/list inside a bitcase) so bitcase <field>s never reach the flat
// field handler and the reader never desyncs. Leaves the reader positioned after
// </switch>. Returns an owned *Switch; on any error the partial tree is freed.
fn parseSwitch(gpa: std.mem.Allocator, reader: *xml.Reader) SwitchError!*Switch {
    var mask_fieldref: []const u8 = try gpa.dupe(u8, "");
    errdefer gpa.free(mask_fieldref);

    var bitcases: std.ArrayList(Bitcase) = .empty;
    errdefer {
        for (bitcases.items) |*bc| {
            for (bc.conds) |c| {
                gpa.free(c.enum_name);
                gpa.free(c.item);
            }
            gpa.free(bc.conds);
            freeFields(gpa, bc.fields);
        }
        bitcases.deinit(gpa);
    }

    while (true) {
        const node = try reader.read();
        switch (node) {
            .eof => break,
            .element_start => {
                const el = reader.elementName();
                if (std.mem.eql(u8, el, "fieldref")) {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(gpa);
                    const text = try readLeafText(gpa, reader, &buf);
                    const owned = try gpa.dupe(u8, text);
                    gpa.free(mask_fieldref);
                    mask_fieldref = owned;
                } else if (std.mem.eql(u8, el, "bitcase")) {
                    const bc = try parseBitcase(gpa, reader);
                    errdefer {
                        for (bc.conds) |c| {
                            gpa.free(c.enum_name);
                            gpa.free(c.item);
                        }
                        gpa.free(bc.conds);
                        freeFields(gpa, bc.fields);
                    }
                    try bitcases.append(gpa, bc);
                } else {
                    // Unexpected element (e.g. a nested <switch> directly under
                    // <switch>, or <pad>). Consume it fully and drop it.
                    try skipElement(reader, el);
                }
            },
            .element_end => {
                // Matching </switch>.
                break;
            },
            else => {},
        }
    }

    const bitcases_owned = try bitcases.toOwnedSlice(gpa);
    errdefer {
        for (bitcases_owned) |*bc| {
            for (bc.conds) |c| {
                gpa.free(c.enum_name);
                gpa.free(c.item);
            }
            gpa.free(bc.conds);
            freeFields(gpa, bc.fields);
        }
        gpa.free(bitcases_owned);
    }

    const s = try gpa.create(Switch);
    s.* = .{ .mask_fieldref = mask_fieldref, .bitcases = bitcases_owned };
    return s;
}

pub fn parse(gpa: std.mem.Allocator, xml_bytes: []const u8) ParseError!Protocol {
    var static_reader: xml.Reader.Static = .init(gpa, xml_bytes, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader: *xml.Reader = &static_reader.interface;

    var header: []const u8 = try gpa.dupe(u8, "");
    errdefer gpa.free(header);

    var extension_xname: ?[]const u8 = null;
    errdefer if (extension_xname) |x| gpa.free(x);

    var imports: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (imports.items) |imp| gpa.free(imp);
        imports.deinit(gpa);
    }

    var enums: std.ArrayList(Enum) = .empty;
    errdefer {
        for (enums.items) |*e| {
            gpa.free(e.name);
            for (e.items) |item| gpa.free(item.name);
            gpa.free(e.items);
        }
        enums.deinit(gpa);
    }

    var xids: std.ArrayList(XidType) = .empty;
    errdefer {
        for (xids.items) |x| gpa.free(x.name);
        xids.deinit(gpa);
    }

    var structs: std.ArrayList(StructDef) = .empty;
    errdefer {
        for (structs.items) |*s| {
            gpa.free(s.name);
            for (s.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |sw| freeSwitch(gpa, sw);
            }
            gpa.free(s.fields);
        }
        structs.deinit(gpa);
    }

    var unions: std.ArrayList(UnionDef) = .empty;
    errdefer {
        for (unions.items) |*u| {
            gpa.free(u.name);
            for (u.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(u.fields);
        }
        unions.deinit(gpa);
    }

    var typedefs: std.ArrayList(Typedef) = .empty;
    errdefer {
        for (typedefs.items) |t| {
            gpa.free(t.oldname);
            gpa.free(t.newname);
        }
        typedefs.deinit(gpa);
    }

    var requests: std.ArrayList(Request) = .empty;
    errdefer {
        for (requests.items) |*r| {
            gpa.free(r.name);
            for (r.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(r.fields);
            if (r.reply) |reply_fields| {
                for (reply_fields) |f| {
                    gpa.free(f.name);
                    gpa.free(f.type_ref);
                    if (f.list_len) |le| freeExpr(gpa, le);
                    if (f.switch_data) |s| freeSwitch(gpa, s);
                }
                gpa.free(reply_fields);
            }
        }
        requests.deinit(gpa);
    }

    var events: std.ArrayList(Event) = .empty;
    errdefer {
        for (events.items) |*e| {
            gpa.free(e.name);
            for (e.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(e.fields);
        }
        events.deinit(gpa);
    }

    var errors: std.ArrayList(ErrorDef) = .empty;
    errdefer {
        for (errors.items) |*e| {
            gpa.free(e.name);
            for (e.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.type_ref);
                if (f.list_len) |le| freeExpr(gpa, le);
                if (f.switch_data) |s| freeSwitch(gpa, s);
            }
            gpa.free(e.fields);
        }
        errors.deinit(gpa);
    }

    var event_copies: std.ArrayList(Copy) = .empty;
    errdefer {
        for (event_copies.items) |c| {
            gpa.free(c.name);
            gpa.free(c.ref);
        }
        event_copies.deinit(gpa);
    }

    var error_copies: std.ArrayList(Copy) = .empty;
    errdefer {
        for (error_copies.items) |c| {
            gpa.free(c.name);
            gpa.free(c.ref);
        }
        error_copies.deinit(gpa);
    }

    // Scope stack - which container we are in
    const Scope = enum {
        root,
        xcb,
        import,
        enum_,
        enum_item,
        enum_item_value,
        enum_item_bit,
        struct_,
        struct_field,
        struct_list,
        union_,
        union_field,
        union_list,
        union_pad,
        pad,
        // New scopes for request/event/error
        request,
        request_field,
        request_pad,
        request_list,
        reply,
        reply_field,
        reply_pad,
        reply_list,
        event_,
        event_field,
        event_pad,
        event_list,
        error_,
        error_field,
        error_pad,
        error_list,
    };
    var scope: Scope = .root;

    var cur_enum_name: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_enum_name);

    var cur_enum_items: std.ArrayList(EnumItem) = .empty;
    defer {
        for (cur_enum_items.items) |item| gpa.free(item.name);
        cur_enum_items.deinit(gpa);
    }

    var cur_item_name: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_item_name);

    var cur_item_text: std.ArrayList(u8) = .empty;
    defer cur_item_text.deinit(gpa);

    var cur_struct_name: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_struct_name);

    var cur_struct_fields: std.ArrayList(Field) = .empty;
    defer {
        for (cur_struct_fields.items) |f| {
            gpa.free(f.name);
            gpa.free(f.type_ref);
            if (f.list_len) |le| freeExpr(gpa, le);
            if (f.switch_data) |s| freeSwitch(gpa, s);
        }
        cur_struct_fields.deinit(gpa);
    }

    var cur_list_name: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_list_name);

    var cur_list_type: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_list_type);

    var cur_list_len: ?*Expr = null;
    defer if (cur_list_len) |e| freeExpr(gpa, e);

    var import_buf: std.ArrayList(u8) = .empty;
    defer import_buf.deinit(gpa);

    // Request/event/error state
    var cur_req_name: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_req_name);
    var cur_req_opcode: u8 = 0;
    var cur_req_fields: std.ArrayList(Field) = .empty;
    defer {
        for (cur_req_fields.items) |f| {
            gpa.free(f.name);
            gpa.free(f.type_ref);
            if (f.list_len) |le| freeExpr(gpa, le);
            if (f.switch_data) |s| freeSwitch(gpa, s);
        }
        cur_req_fields.deinit(gpa);
    }
    var cur_reply_fields: std.ArrayList(Field) = .empty;
    defer {
        for (cur_reply_fields.items) |f| {
            gpa.free(f.name);
            gpa.free(f.type_ref);
            if (f.list_len) |le| freeExpr(gpa, le);
            if (f.switch_data) |s| freeSwitch(gpa, s);
        }
        cur_reply_fields.deinit(gpa);
    }
    var cur_req_has_reply: bool = false;

    var cur_event_name: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_event_name);
    var cur_event_number: u8 = 0;
    var cur_event_fields: std.ArrayList(Field) = .empty;
    defer {
        for (cur_event_fields.items) |f| {
            gpa.free(f.name);
            gpa.free(f.type_ref);
            if (f.list_len) |le| freeExpr(gpa, le);
            if (f.switch_data) |s| freeSwitch(gpa, s);
        }
        cur_event_fields.deinit(gpa);
    }

    var cur_error_name: []const u8 = try gpa.dupe(u8, "");
    defer gpa.free(cur_error_name);
    var cur_error_number: u8 = 0;
    var cur_error_fields: std.ArrayList(Field) = .empty;
    defer {
        for (cur_error_fields.items) |f| {
            gpa.free(f.name);
            gpa.free(f.type_ref);
            if (f.list_len) |le| freeExpr(gpa, le);
            if (f.switch_data) |s| freeSwitch(gpa, s);
        }
        cur_error_fields.deinit(gpa);
    }

    while (true) {
        const node = try reader.read();
        switch (node) {
            .eof => break,
            .element_start => {
                const el = reader.elementName();
                switch (scope) {
                    .root => {
                        if (std.mem.eql(u8, el, "xcb")) {
                            if (attr(reader, "header")) |h| {
                                gpa.free(header);
                                header = try gpa.dupe(u8, h);
                            }
                            if (attr(reader, "extension-xname")) |xname| {
                                if (extension_xname) |old| gpa.free(old);
                                extension_xname = try gpa.dupe(u8, xname);
                            }
                            scope = .xcb;
                        }
                    },
                    .xcb => {
                        if (std.mem.eql(u8, el, "import")) {
                            import_buf.clearRetainingCapacity();
                            scope = .import;
                        } else if (std.mem.eql(u8, el, "xidtype") or std.mem.eql(u8, el, "xidunion")) {
                            if (attr(reader, "name")) |n| {
                                try xids.append(gpa, .{ .name = try gpa.dupe(u8, n) });
                            }
                        } else if (std.mem.eql(u8, el, "enum")) {
                            if (attr(reader, "name")) |n| {
                                gpa.free(cur_enum_name);
                                cur_enum_name = try gpa.dupe(u8, n);
                            }
                            scope = .enum_;
                        } else if (std.mem.eql(u8, el, "struct")) {
                            if (attr(reader, "name")) |n| {
                                gpa.free(cur_struct_name);
                                cur_struct_name = try gpa.dupe(u8, n);
                            }
                            scope = .struct_;
                        } else if (std.mem.eql(u8, el, "union")) {
                            if (attr(reader, "name")) |n| {
                                gpa.free(cur_struct_name);
                                cur_struct_name = try gpa.dupe(u8, n);
                            }
                            scope = .union_;
                        } else if (std.mem.eql(u8, el, "typedef")) {
                            const oldname = attr(reader, "oldname") orelse "";
                            const newname = attr(reader, "newname") orelse "";
                            try typedefs.append(gpa, .{
                                .oldname = try gpa.dupe(u8, oldname),
                                .newname = try gpa.dupe(u8, newname),
                            });
                        } else if (std.mem.eql(u8, el, "request")) {
                            if (attr(reader, "name")) |n| {
                                gpa.free(cur_req_name);
                                cur_req_name = try gpa.dupe(u8, n);
                            }
                            if (attr(reader, "opcode")) |op| {
                                cur_req_opcode = std.fmt.parseInt(u8, op, 10) catch return error.MalformedXml;
                            }
                            cur_req_has_reply = false;
                            scope = .request;
                        } else if (std.mem.eql(u8, el, "event")) {
                            if (attr(reader, "name")) |n| {
                                gpa.free(cur_event_name);
                                cur_event_name = try gpa.dupe(u8, n);
                            }
                            if (attr(reader, "number")) |num| {
                                cur_event_number = std.fmt.parseInt(u8, num, 10) catch return error.MalformedXml;
                            }
                            scope = .event_;
                        } else if (std.mem.eql(u8, el, "error")) {
                            if (attr(reader, "name")) |n| {
                                gpa.free(cur_error_name);
                                cur_error_name = try gpa.dupe(u8, n);
                            }
                            if (attr(reader, "number")) |num| {
                                cur_error_number = std.fmt.parseInt(u8, num, 10) catch return error.MalformedXml;
                            }
                            scope = .error_;
                        } else if (std.mem.eql(u8, el, "eventcopy")) {
                            const c_name = attr(reader, "name") orelse "";
                            const c_num = attr(reader, "number") orelse "0";
                            const c_ref = attr(reader, "ref") orelse "";
                            try event_copies.append(gpa, .{
                                .name = try gpa.dupe(u8, c_name),
                                .number = std.fmt.parseInt(u8, c_num, 10) catch return error.MalformedXml,
                                .ref = try gpa.dupe(u8, c_ref),
                            });
                        } else if (std.mem.eql(u8, el, "errorcopy")) {
                            const c_name = attr(reader, "name") orelse "";
                            const c_num = attr(reader, "number") orelse "0";
                            const c_ref = attr(reader, "ref") orelse "";
                            try error_copies.append(gpa, .{
                                .name = try gpa.dupe(u8, c_name),
                                .number = std.fmt.parseInt(u8, c_num, 10) catch return error.MalformedXml,
                                .ref = try gpa.dupe(u8, c_ref),
                            });
                        }
                    },
                    .enum_ => {
                        if (std.mem.eql(u8, el, "doc")) {
                            try skipElement(reader, el);
                        } else if (std.mem.eql(u8, el, "item")) {
                            if (attr(reader, "name")) |n| {
                                gpa.free(cur_item_name);
                                cur_item_name = try gpa.dupe(u8, n);
                            }
                            cur_item_text.clearRetainingCapacity();
                            scope = .enum_item;
                        }
                    },
                    .enum_item => {
                        if (std.mem.eql(u8, el, "value")) {
                            cur_item_text.clearRetainingCapacity();
                            scope = .enum_item_value;
                        } else if (std.mem.eql(u8, el, "bit")) {
                            cur_item_text.clearRetainingCapacity();
                            scope = .enum_item_bit;
                        }
                    },
                    .struct_ => {
                        if (std.mem.eql(u8, el, "doc")) {
                            try skipElement(reader, el);
                        } else if (std.mem.eql(u8, el, "field")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_struct_fields.append(gpa, .{
                                .kind = .scalar,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                            scope = .struct_field;
                        } else if (std.mem.eql(u8, el, "pad")) {
                            const is_align = attr(reader, "align") != null;
                            const pb: usize = if (!is_align) blk: {
                                const bstr = attr(reader, "bytes") orelse "1";
                                break :blk std.fmt.parseInt(usize, bstr, 10) catch return error.MalformedXml;
                            } else 0;
                            try cur_struct_fields.append(gpa, .{
                                .kind = .pad,
                                .name = try gpa.dupe(u8, ""),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                                .pad_bytes = pb,
                                .pad_align = is_align,
                            });
                            scope = .pad;
                        } else if (std.mem.eql(u8, el, "list")) {
                            const l_name = attr(reader, "name") orelse "";
                            const l_type = attr(reader, "type") orelse "";
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, l_name);
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, l_type);
                            if (cur_list_len) |old| freeExpr(gpa, old);
                            cur_list_len = null;
                            scope = .struct_list;
                        } else if (std.mem.eql(u8, el, "fd")) {
                            const f_name = attr(reader, "name") orelse "";
                            try cur_struct_fields.append(gpa, .{
                                .kind = .fd,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "exprfield")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_struct_fields.append(gpa, .{
                                .kind = .exprfield,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "switch")) {
                            const sw_name = attr(reader, "name") orelse "";
                            const sw_name_owned = try gpa.dupe(u8, sw_name);
                            errdefer gpa.free(sw_name_owned);
                            const empty_type = try gpa.dupe(u8, "");
                            errdefer gpa.free(empty_type);
                            const built = try parseSwitch(gpa, reader);
                            errdefer freeSwitch(gpa, built);
                            try cur_struct_fields.append(gpa, .{
                                .kind = .switch_,
                                .name = sw_name_owned,
                                .type_ref = empty_type,
                                .list_len = null,
                                .switch_data = built,
                            });
                        }
                    },
                    .struct_list => {
                        const built = parseExprElement(gpa, reader, el) catch |err| switch (err) {
                            error.UnsupportedExpr => null,
                            else => |e| return e,
                        };
                        if (cur_list_len) |old| freeExpr(gpa, old);
                        cur_list_len = built;
                    },
                    .union_ => {
                        if (std.mem.eql(u8, el, "doc")) {
                            try skipElement(reader, el);
                        } else if (std.mem.eql(u8, el, "field")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_struct_fields.append(gpa, .{
                                .kind = .scalar,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                            scope = .union_field;
                        } else if (std.mem.eql(u8, el, "pad")) {
                            const is_align = attr(reader, "align") != null;
                            const pb: usize = if (!is_align) blk: {
                                const bstr = attr(reader, "bytes") orelse "1";
                                break :blk std.fmt.parseInt(usize, bstr, 10) catch return error.MalformedXml;
                            } else 0;
                            try cur_struct_fields.append(gpa, .{
                                .kind = .pad,
                                .name = try gpa.dupe(u8, ""),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                                .pad_bytes = pb,
                                .pad_align = is_align,
                            });
                            scope = .union_pad;
                        } else if (std.mem.eql(u8, el, "list")) {
                            const l_name = attr(reader, "name") orelse "";
                            const l_type = attr(reader, "type") orelse "";
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, l_name);
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, l_type);
                            if (cur_list_len) |old| freeExpr(gpa, old);
                            cur_list_len = null;
                            scope = .union_list;
                        } else if (std.mem.eql(u8, el, "switch")) {
                            const sw_name = attr(reader, "name") orelse "";
                            const sw_name_owned = try gpa.dupe(u8, sw_name);
                            errdefer gpa.free(sw_name_owned);
                            const empty_type = try gpa.dupe(u8, "");
                            errdefer gpa.free(empty_type);
                            const built = try parseSwitch(gpa, reader);
                            errdefer freeSwitch(gpa, built);
                            try cur_struct_fields.append(gpa, .{
                                .kind = .switch_,
                                .name = sw_name_owned,
                                .type_ref = empty_type,
                                .list_len = null,
                                .switch_data = built,
                            });
                        }
                    },
                    .union_list => {
                        const built = parseExprElement(gpa, reader, el) catch |err| switch (err) {
                            error.UnsupportedExpr => null,
                            else => |e| return e,
                        };
                        if (cur_list_len) |old| freeExpr(gpa, old);
                        cur_list_len = built;
                    },
                    // Request scope
                    .request => {
                        if (std.mem.eql(u8, el, "doc")) {
                            try skipElement(reader, el);
                        } else if (std.mem.eql(u8, el, "field")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_req_fields.append(gpa, .{
                                .kind = .scalar,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                            scope = .request_field;
                        } else if (std.mem.eql(u8, el, "pad")) {
                            const is_align = attr(reader, "align") != null;
                            const pb: usize = if (!is_align) blk: {
                                const bstr = attr(reader, "bytes") orelse "1";
                                break :blk std.fmt.parseInt(usize, bstr, 10) catch return error.MalformedXml;
                            } else 0;
                            try cur_req_fields.append(gpa, .{
                                .kind = .pad,
                                .name = try gpa.dupe(u8, ""),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                                .pad_bytes = pb,
                                .pad_align = is_align,
                            });
                            scope = .request_pad;
                        } else if (std.mem.eql(u8, el, "list")) {
                            const l_name = attr(reader, "name") orelse "";
                            const l_type = attr(reader, "type") orelse "";
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, l_name);
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, l_type);
                            if (cur_list_len) |old| freeExpr(gpa, old);
                            cur_list_len = null;
                            scope = .request_list;
                        } else if (std.mem.eql(u8, el, "fd")) {
                            const f_name = attr(reader, "name") orelse "";
                            try cur_req_fields.append(gpa, .{
                                .kind = .fd,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "exprfield")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            const ef_name = try gpa.dupe(u8, f_name);
                            errdefer gpa.free(ef_name);
                            const ef_type = try gpa.dupe(u8, f_type);
                            errdefer gpa.free(ef_type);
                            // Capture the computed-value expression (reused in the
                            // list_len slot). On an absent/unsupported child,
                            // parseNextChildExpr has already consumed </exprfield>.
                            const ef_expr = parseNextChildExpr(gpa, reader) catch |err| switch (err) {
                                error.UnsupportedExpr => null,
                                else => |e| return e,
                            };
                            errdefer if (ef_expr) |le| freeExpr(gpa, le);
                            try cur_req_fields.append(gpa, .{
                                .kind = .exprfield,
                                .name = ef_name,
                                .type_ref = ef_type,
                                .list_len = ef_expr,
                            });
                            if (ef_expr != null) try consumeElementClose(reader, el);
                        } else if (std.mem.eql(u8, el, "switch")) {
                            const sw_name = attr(reader, "name") orelse "";
                            const sw_name_owned = try gpa.dupe(u8, sw_name);
                            errdefer gpa.free(sw_name_owned);
                            const empty_type = try gpa.dupe(u8, "");
                            errdefer gpa.free(empty_type);
                            const built = try parseSwitch(gpa, reader);
                            errdefer freeSwitch(gpa, built);
                            try cur_req_fields.append(gpa, .{
                                .kind = .switch_,
                                .name = sw_name_owned,
                                .type_ref = empty_type,
                                .list_len = null,
                                .switch_data = built,
                            });
                        } else if (std.mem.eql(u8, el, "reply")) {
                            cur_req_has_reply = true;
                            scope = .reply;
                        }
                    },
                    // Reply scope
                    .reply => {
                        if (std.mem.eql(u8, el, "doc")) {
                            try skipElement(reader, el);
                        } else if (std.mem.eql(u8, el, "field")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_reply_fields.append(gpa, .{
                                .kind = .scalar,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                            scope = .reply_field;
                        } else if (std.mem.eql(u8, el, "pad")) {
                            const is_align = attr(reader, "align") != null;
                            const pb: usize = if (!is_align) blk: {
                                const bstr = attr(reader, "bytes") orelse "1";
                                break :blk std.fmt.parseInt(usize, bstr, 10) catch return error.MalformedXml;
                            } else 0;
                            try cur_reply_fields.append(gpa, .{
                                .kind = .pad,
                                .name = try gpa.dupe(u8, ""),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                                .pad_bytes = pb,
                                .pad_align = is_align,
                            });
                            scope = .reply_pad;
                        } else if (std.mem.eql(u8, el, "list")) {
                            const l_name = attr(reader, "name") orelse "";
                            const l_type = attr(reader, "type") orelse "";
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, l_name);
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, l_type);
                            if (cur_list_len) |old| freeExpr(gpa, old);
                            cur_list_len = null;
                            scope = .reply_list;
                        } else if (std.mem.eql(u8, el, "fd")) {
                            const f_name = attr(reader, "name") orelse "";
                            try cur_reply_fields.append(gpa, .{
                                .kind = .fd,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "exprfield")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_reply_fields.append(gpa, .{
                                .kind = .exprfield,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "switch")) {
                            const sw_name = attr(reader, "name") orelse "";
                            const sw_name_owned = try gpa.dupe(u8, sw_name);
                            errdefer gpa.free(sw_name_owned);
                            const empty_type = try gpa.dupe(u8, "");
                            errdefer gpa.free(empty_type);
                            const built = try parseSwitch(gpa, reader);
                            errdefer freeSwitch(gpa, built);
                            try cur_reply_fields.append(gpa, .{
                                .kind = .switch_,
                                .name = sw_name_owned,
                                .type_ref = empty_type,
                                .list_len = null,
                                .switch_data = built,
                            });
                        }
                    },
                    // Event scope
                    .event_ => {
                        if (std.mem.eql(u8, el, "doc")) {
                            try skipElement(reader, el);
                        } else if (std.mem.eql(u8, el, "field")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_event_fields.append(gpa, .{
                                .kind = .scalar,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                            scope = .event_field;
                        } else if (std.mem.eql(u8, el, "pad")) {
                            const is_align = attr(reader, "align") != null;
                            const pb: usize = if (!is_align) blk: {
                                const bstr = attr(reader, "bytes") orelse "1";
                                break :blk std.fmt.parseInt(usize, bstr, 10) catch return error.MalformedXml;
                            } else 0;
                            try cur_event_fields.append(gpa, .{
                                .kind = .pad,
                                .name = try gpa.dupe(u8, ""),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                                .pad_bytes = pb,
                                .pad_align = is_align,
                            });
                            scope = .event_pad;
                        } else if (std.mem.eql(u8, el, "list")) {
                            const l_name = attr(reader, "name") orelse "";
                            const l_type = attr(reader, "type") orelse "";
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, l_name);
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, l_type);
                            if (cur_list_len) |old| freeExpr(gpa, old);
                            cur_list_len = null;
                            scope = .event_list;
                        } else if (std.mem.eql(u8, el, "fd")) {
                            const f_name = attr(reader, "name") orelse "";
                            try cur_event_fields.append(gpa, .{
                                .kind = .fd,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "exprfield")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_event_fields.append(gpa, .{
                                .kind = .exprfield,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "switch")) {
                            const sw_name = attr(reader, "name") orelse "";
                            const sw_name_owned = try gpa.dupe(u8, sw_name);
                            errdefer gpa.free(sw_name_owned);
                            const empty_type = try gpa.dupe(u8, "");
                            errdefer gpa.free(empty_type);
                            const built = try parseSwitch(gpa, reader);
                            errdefer freeSwitch(gpa, built);
                            try cur_event_fields.append(gpa, .{
                                .kind = .switch_,
                                .name = sw_name_owned,
                                .type_ref = empty_type,
                                .list_len = null,
                                .switch_data = built,
                            });
                        }
                    },
                    // Error scope
                    .error_ => {
                        if (std.mem.eql(u8, el, "doc")) {
                            try skipElement(reader, el);
                        } else if (std.mem.eql(u8, el, "field")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_error_fields.append(gpa, .{
                                .kind = .scalar,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                            scope = .error_field;
                        } else if (std.mem.eql(u8, el, "pad")) {
                            const is_align = attr(reader, "align") != null;
                            const pb: usize = if (!is_align) blk: {
                                const bstr = attr(reader, "bytes") orelse "1";
                                break :blk std.fmt.parseInt(usize, bstr, 10) catch return error.MalformedXml;
                            } else 0;
                            try cur_error_fields.append(gpa, .{
                                .kind = .pad,
                                .name = try gpa.dupe(u8, ""),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                                .pad_bytes = pb,
                                .pad_align = is_align,
                            });
                            scope = .error_pad;
                        } else if (std.mem.eql(u8, el, "list")) {
                            const l_name = attr(reader, "name") orelse "";
                            const l_type = attr(reader, "type") orelse "";
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, l_name);
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, l_type);
                            if (cur_list_len) |old| freeExpr(gpa, old);
                            cur_list_len = null;
                            scope = .error_list;
                        } else if (std.mem.eql(u8, el, "fd")) {
                            const f_name = attr(reader, "name") orelse "";
                            try cur_error_fields.append(gpa, .{
                                .kind = .fd,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, ""),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "exprfield")) {
                            const f_name = attr(reader, "name") orelse "";
                            const f_type = attr(reader, "type") orelse "";
                            try cur_error_fields.append(gpa, .{
                                .kind = .exprfield,
                                .name = try gpa.dupe(u8, f_name),
                                .type_ref = try gpa.dupe(u8, f_type),
                                .list_len = null,
                            });
                        } else if (std.mem.eql(u8, el, "switch")) {
                            const sw_name = attr(reader, "name") orelse "";
                            const sw_name_owned = try gpa.dupe(u8, sw_name);
                            errdefer gpa.free(sw_name_owned);
                            const empty_type = try gpa.dupe(u8, "");
                            errdefer gpa.free(empty_type);
                            const built = try parseSwitch(gpa, reader);
                            errdefer freeSwitch(gpa, built);
                            try cur_error_fields.append(gpa, .{
                                .kind = .switch_,
                                .name = sw_name_owned,
                                .type_ref = empty_type,
                                .list_len = null,
                                .switch_data = built,
                            });
                        }
                    },
                    // list sub-scopes: build the length expression tree
                    .request_list, .reply_list, .event_list, .error_list => {
                        const built = parseExprElement(gpa, reader, el) catch |err| switch (err) {
                            error.UnsupportedExpr => null,
                            else => |e| return e,
                        };
                        if (cur_list_len) |old| freeExpr(gpa, old);
                        cur_list_len = built;
                    },
                    else => {},
                }
            },
            .element_end => {
                const el = reader.elementName();
                switch (scope) {
                    .import => {
                        if (std.mem.eql(u8, el, "import")) {
                            try imports.append(gpa, try gpa.dupe(u8, import_buf.items));
                            scope = .xcb;
                        }
                    },
                    .enum_ => {
                        if (std.mem.eql(u8, el, "enum")) {
                            const items = try cur_enum_items.toOwnedSlice(gpa);
                            try enums.append(gpa, .{
                                .name = try gpa.dupe(u8, cur_enum_name),
                                .items = items,
                            });
                            gpa.free(cur_enum_name);
                            cur_enum_name = try gpa.dupe(u8, "");
                            scope = .xcb;
                        }
                    },
                    .enum_item => {
                        if (std.mem.eql(u8, el, "item")) {
                            scope = .enum_;
                        }
                    },
                    .enum_item_value => {
                        if (std.mem.eql(u8, el, "value")) {
                            const val = std.fmt.parseInt(i64, std.mem.trim(u8, cur_item_text.items, " \t\n\r"), 10) catch 0;
                            try cur_enum_items.append(gpa, .{
                                .name = try gpa.dupe(u8, cur_item_name),
                                .value = val,
                                .is_bit = false,
                            });
                            gpa.free(cur_item_name);
                            cur_item_name = try gpa.dupe(u8, "");
                            scope = .enum_item;
                        }
                    },
                    .enum_item_bit => {
                        if (std.mem.eql(u8, el, "bit")) {
                            const bit = std.fmt.parseInt(i64, std.mem.trim(u8, cur_item_text.items, " \t\n\r"), 10) catch 0;
                            try cur_enum_items.append(gpa, .{
                                .name = try gpa.dupe(u8, cur_item_name),
                                .value = bit,
                                .is_bit = true,
                            });
                            gpa.free(cur_item_name);
                            cur_item_name = try gpa.dupe(u8, "");
                            scope = .enum_item;
                        }
                    },
                    .struct_ => {
                        if (std.mem.eql(u8, el, "struct")) {
                            const fields = try cur_struct_fields.toOwnedSlice(gpa);
                            try structs.append(gpa, .{
                                .name = try gpa.dupe(u8, cur_struct_name),
                                .fields = fields,
                            });
                            gpa.free(cur_struct_name);
                            cur_struct_name = try gpa.dupe(u8, "");
                            scope = .xcb;
                        }
                    },
                    .struct_field => {
                        if (std.mem.eql(u8, el, "field")) {
                            scope = .struct_;
                        }
                    },
                    .pad => {
                        if (std.mem.eql(u8, el, "pad")) {
                            scope = .struct_;
                        }
                    },
                    .struct_list => {
                        if (std.mem.eql(u8, el, "list")) {
                            const l_name = try gpa.dupe(u8, cur_list_name);
                            errdefer gpa.free(l_name);
                            const l_type = try gpa.dupe(u8, cur_list_type);
                            errdefer gpa.free(l_type);
                            try cur_struct_fields.append(gpa, .{
                                .kind = .list,
                                .name = l_name,
                                .type_ref = l_type,
                                .list_len = cur_list_len,
                            });
                            cur_list_len = null;
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, "");
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, "");
                            scope = .struct_;
                        }
                    },
                    .union_ => {
                        if (std.mem.eql(u8, el, "union")) {
                            const fields = try cur_struct_fields.toOwnedSlice(gpa);
                            try unions.append(gpa, .{
                                .name = try gpa.dupe(u8, cur_struct_name),
                                .fields = fields,
                            });
                            gpa.free(cur_struct_name);
                            cur_struct_name = try gpa.dupe(u8, "");
                            scope = .xcb;
                        }
                    },
                    .union_field => {
                        if (std.mem.eql(u8, el, "field")) scope = .union_;
                    },
                    .union_pad => {
                        if (std.mem.eql(u8, el, "pad")) scope = .union_;
                    },
                    .union_list => {
                        if (std.mem.eql(u8, el, "list")) {
                            const l_name = try gpa.dupe(u8, cur_list_name);
                            errdefer gpa.free(l_name);
                            const l_type = try gpa.dupe(u8, cur_list_type);
                            errdefer gpa.free(l_type);
                            try cur_struct_fields.append(gpa, .{
                                .kind = .list,
                                .name = l_name,
                                .type_ref = l_type,
                                .list_len = cur_list_len,
                            });
                            cur_list_len = null;
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, "");
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, "");
                            scope = .union_;
                        }
                    },
                    // Request end handlers
                    .request => {
                        if (std.mem.eql(u8, el, "request")) {
                            const req_fields = try cur_req_fields.toOwnedSlice(gpa);
                            errdefer freeFields(gpa, req_fields);
                            const reply_fields: ?[]Field = if (cur_req_has_reply)
                                try cur_reply_fields.toOwnedSlice(gpa)
                            else blk: {
                                // Discard any accumulated reply fields (shouldn't have any)
                                for (cur_reply_fields.items) |f| {
                                    gpa.free(f.name);
                                    gpa.free(f.type_ref);
                                    if (f.list_len) |le| freeExpr(gpa, le);
                                    if (f.switch_data) |s| freeSwitch(gpa, s);
                                }
                                cur_reply_fields.clearRetainingCapacity();
                                break :blk null;
                            };
                            errdefer if (reply_fields) |rf| freeFields(gpa, rf);
                            const req_name = try gpa.dupe(u8, cur_req_name);
                            errdefer gpa.free(req_name);
                            try requests.append(gpa, .{
                                .name = req_name,
                                .opcode = cur_req_opcode,
                                .fields = req_fields,
                                .reply = reply_fields,
                            });
                            gpa.free(cur_req_name);
                            cur_req_name = try gpa.dupe(u8, "");
                            cur_req_opcode = 0;
                            cur_req_has_reply = false;
                            scope = .xcb;
                        }
                    },
                    .request_field => {
                        if (std.mem.eql(u8, el, "field")) {
                            scope = .request;
                        }
                    },
                    .request_pad => {
                        if (std.mem.eql(u8, el, "pad")) {
                            scope = .request;
                        }
                    },
                    .request_list => {
                        if (std.mem.eql(u8, el, "list")) {
                            const l_name = try gpa.dupe(u8, cur_list_name);
                            errdefer gpa.free(l_name);
                            const l_type = try gpa.dupe(u8, cur_list_type);
                            errdefer gpa.free(l_type);
                            try cur_req_fields.append(gpa, .{
                                .kind = .list,
                                .name = l_name,
                                .type_ref = l_type,
                                .list_len = cur_list_len,
                            });
                            cur_list_len = null;
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, "");
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, "");
                            scope = .request;
                        }
                    },
                    // Reply end handlers
                    .reply => {
                        if (std.mem.eql(u8, el, "reply")) {
                            // Reply closed, go back to request scope
                            scope = .request;
                        }
                    },
                    .reply_field => {
                        if (std.mem.eql(u8, el, "field")) {
                            scope = .reply;
                        }
                    },
                    .reply_pad => {
                        if (std.mem.eql(u8, el, "pad")) {
                            scope = .reply;
                        }
                    },
                    .reply_list => {
                        if (std.mem.eql(u8, el, "list")) {
                            const l_name = try gpa.dupe(u8, cur_list_name);
                            errdefer gpa.free(l_name);
                            const l_type = try gpa.dupe(u8, cur_list_type);
                            errdefer gpa.free(l_type);
                            try cur_reply_fields.append(gpa, .{
                                .kind = .list,
                                .name = l_name,
                                .type_ref = l_type,
                                .list_len = cur_list_len,
                            });
                            cur_list_len = null;
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, "");
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, "");
                            scope = .reply;
                        }
                    },
                    // Event end handlers
                    .event_ => {
                        if (std.mem.eql(u8, el, "event")) {
                            const ev_fields = try cur_event_fields.toOwnedSlice(gpa);
                            errdefer freeFields(gpa, ev_fields);
                            const ev_name = try gpa.dupe(u8, cur_event_name);
                            errdefer gpa.free(ev_name);
                            try events.append(gpa, .{
                                .name = ev_name,
                                .number = cur_event_number,
                                .fields = ev_fields,
                            });
                            gpa.free(cur_event_name);
                            cur_event_name = try gpa.dupe(u8, "");
                            cur_event_number = 0;
                            scope = .xcb;
                        }
                    },
                    .event_field => {
                        if (std.mem.eql(u8, el, "field")) {
                            scope = .event_;
                        }
                    },
                    .event_pad => {
                        if (std.mem.eql(u8, el, "pad")) {
                            scope = .event_;
                        }
                    },
                    .event_list => {
                        if (std.mem.eql(u8, el, "list")) {
                            const l_name = try gpa.dupe(u8, cur_list_name);
                            errdefer gpa.free(l_name);
                            const l_type = try gpa.dupe(u8, cur_list_type);
                            errdefer gpa.free(l_type);
                            try cur_event_fields.append(gpa, .{
                                .kind = .list,
                                .name = l_name,
                                .type_ref = l_type,
                                .list_len = cur_list_len,
                            });
                            cur_list_len = null;
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, "");
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, "");
                            scope = .event_;
                        }
                    },
                    // Error end handlers
                    .error_ => {
                        if (std.mem.eql(u8, el, "error")) {
                            const err_fields = try cur_error_fields.toOwnedSlice(gpa);
                            errdefer freeFields(gpa, err_fields);
                            const err_name = try gpa.dupe(u8, cur_error_name);
                            errdefer gpa.free(err_name);
                            try errors.append(gpa, .{
                                .name = err_name,
                                .number = cur_error_number,
                                .fields = err_fields,
                            });
                            gpa.free(cur_error_name);
                            cur_error_name = try gpa.dupe(u8, "");
                            cur_error_number = 0;
                            scope = .xcb;
                        }
                    },
                    .error_field => {
                        if (std.mem.eql(u8, el, "field")) {
                            scope = .error_;
                        }
                    },
                    .error_pad => {
                        if (std.mem.eql(u8, el, "pad")) {
                            scope = .error_;
                        }
                    },
                    .error_list => {
                        if (std.mem.eql(u8, el, "list")) {
                            const l_name = try gpa.dupe(u8, cur_list_name);
                            errdefer gpa.free(l_name);
                            const l_type = try gpa.dupe(u8, cur_list_type);
                            errdefer gpa.free(l_type);
                            try cur_error_fields.append(gpa, .{
                                .kind = .list,
                                .name = l_name,
                                .type_ref = l_type,
                                .list_len = cur_list_len,
                            });
                            cur_list_len = null;
                            gpa.free(cur_list_name);
                            cur_list_name = try gpa.dupe(u8, "");
                            gpa.free(cur_list_type);
                            cur_list_type = try gpa.dupe(u8, "");
                            scope = .error_;
                        }
                    },
                    .xcb => {
                        if (std.mem.eql(u8, el, "xcb")) {
                            scope = .root;
                        }
                    },
                    else => {},
                }
            },
            .text => {
                const t = reader.textRaw();
                switch (scope) {
                    .import => try import_buf.appendSlice(gpa, t),
                    .enum_item_value, .enum_item_bit => try cur_item_text.appendSlice(gpa, t),
                    else => {},
                }
            },
            else => {},
        }
    }

    return .{
        .header = header,
        .extension_xname = extension_xname,
        .imports = try imports.toOwnedSlice(gpa),
        .enums = try enums.toOwnedSlice(gpa),
        .xids = try xids.toOwnedSlice(gpa),
        .structs = try structs.toOwnedSlice(gpa),
        .unions = try unions.toOwnedSlice(gpa),
        .typedefs = try typedefs.toOwnedSlice(gpa),
        .requests = try requests.toOwnedSlice(gpa),
        .events = try events.toOwnedSlice(gpa),
        .errors = try errors.toOwnedSlice(gpa),
        .event_copies = try event_copies.toOwnedSlice(gpa),
        .error_copies = try error_copies.toOwnedSlice(gpa),
    };
}

test "captures switch/bitcase, no field leak" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="CreateWindow" opcode="1">
        \\    <field type="CARD8" name="depth"/>
        \\    <field type="CARD32" name="value_mask" mask="CW"/>
        \\    <switch name="value_list"><fieldref>value_mask</fieldref>
        \\      <bitcase><enumref ref="CW">BackPixmap</enumref><field type="PIXMAP" name="background_pixmap"/></bitcase>
        \\      <bitcase><enumref ref="CW">BackPixel</enumref><field type="CARD32" name="background_pixel"/></bitcase>
        \\    </switch>
        \\  </request>
        \\</xcb>
    ;
    var p = try parse(std.testing.allocator, doc);
    defer p.deinit(std.testing.allocator);
    const req = p.requests[0];
    var switch_field: ?Field = null;
    var leaked = false;
    for (req.fields) |f| {
        if (f.kind == .switch_) switch_field = f;
        if (std.mem.eql(u8, f.name, "background_pixmap") or std.mem.eql(u8, f.name, "background_pixel")) leaked = true;
    }
    try std.testing.expect(!leaked);
    const sw = switch_field.?.switch_data.?;
    try std.testing.expectEqualStrings("value_mask", sw.mask_fieldref);
    try std.testing.expectEqual(@as(usize, 2), sw.bitcases.len);
    try std.testing.expectEqualStrings("CW", sw.bitcases[0].conds[0].enum_name);
    try std.testing.expectEqualStrings("BackPixmap", sw.bitcases[0].conds[0].item);
    try std.testing.expectEqual(@as(usize, 1), sw.bitcases[0].fields.len);
    try std.testing.expectEqualStrings("background_pixmap", sw.bitcases[0].fields[0].name);
}

test "parse request with reply, event, error, list field" {
    const doc =
        \\<?xml version="1.0"?>
        \\<xcb header="xproto">
        \\  <request name="GetInputFocus" opcode="43">
        \\    <reply>
        \\      <field type="CARD8" name="revert_to" />
        \\      <field type="WINDOW" name="focus" />
        \\    </reply>
        \\  </request>
        \\  <request name="QueryTree" opcode="15">
        \\    <field type="WINDOW" name="window" />
        \\    <reply>
        \\      <field type="WINDOW" name="root" />
        \\      <field type="CARD16" name="children_len" />
        \\      <list type="WINDOW" name="children"><fieldref>children_len</fieldref></list>
        \\    </reply>
        \\  </request>
        \\  <event name="KeyPress" number="2">
        \\    <field type="CARD8" name="detail" />
        \\  </event>
        \\  <error name="Request" number="1">
        \\    <field type="CARD32" name="bad_value" />
        \\  </error>
        \\</xcb>
    ;
    var p = try parse(std.testing.allocator, doc);
    defer p.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), p.requests.len);
    try std.testing.expectEqual(@as(u8, 43), p.requests[0].opcode);
    try std.testing.expect(p.requests[0].reply != null);
    try std.testing.expectEqual(@as(usize, 2), p.requests[0].reply.?.len);

    const qt = p.requests[1];
    try std.testing.expectEqual(@as(u8, 15), qt.opcode);
    try std.testing.expectEqual(@as(usize, 1), qt.fields.len); // request-side: window
    const rfields = qt.reply.?;
    try std.testing.expectEqual(FieldType.list, rfields[2].kind);
    try std.testing.expect(rfields[2].list_len.?.* == .fieldref);
    try std.testing.expectEqualStrings("children_len", rfields[2].list_len.?.fieldref);

    try std.testing.expectEqual(@as(usize, 1), p.events.len);
    try std.testing.expectEqual(@as(u8, 2), p.events[0].number);
    try std.testing.expectEqual(@as(usize, 1), p.errors.len);
    try std.testing.expectEqual(@as(u8, 1), p.errors[0].number);
}

test "parses op and fieldref list-length expressions" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="GetModifierMapping" opcode="119"><reply>
        \\    <field type="CARD8" name="keycodes_per_modifier"/>
        \\    <list type="CARD8" name="keycodes"><op op="*"><fieldref>keycodes_per_modifier</fieldref><value>8</value></op></list>
        \\  </reply></request>
        \\  <request name="GetKeyboardMapping" opcode="101"><reply>
        \\    <field type="BYTE" name="kpk"/>
        \\    <list type="CARD32" name="keysyms"><fieldref>length</fieldref></list>
        \\  </reply></request>
        \\</xcb>
    ;
    var p = try parse(std.testing.allocator, doc);
    defer p.deinit(std.testing.allocator);
    const gmm = p.requests[0];
    const kc = gmm.reply.?[1]; // the list field
    try std.testing.expect(kc.kind == .list);
    const e = kc.list_len.?;
    try std.testing.expect(e.* == .op);
    try std.testing.expectEqualStrings("*", e.op.operator);
    try std.testing.expect(e.op.lhs.* == .fieldref);
    try std.testing.expectEqualStrings("keycodes_per_modifier", e.op.lhs.fieldref);
    try std.testing.expect(e.op.rhs.* == .value);
    try std.testing.expectEqual(@as(i64, 8), e.op.rhs.value);
    const gkm = p.requests[1];
    const ks = gkm.reply.?[1];
    try std.testing.expect(ks.list_len.?.* == .fieldref);
    try std.testing.expectEqualStrings("length", ks.list_len.?.fieldref);
}

test "doc block fields are not parsed as request fields" {
    const doc =
        \\<xcb header="xproto">
        \\  <request name="Foo" opcode="7">
        \\    <field type="CARD8" name="mode"/>
        \\    <list type="char" name="name"><fieldref>mode</fieldref></list>
        \\    <doc>
        \\      <brief>foo</brief>
        \\      <field name="mode"><![CDATA[the mode]]></field>
        \\      <field name="name"><![CDATA[the name]]></field>
        \\    </doc>
        \\  </request>
        \\</xcb>
    ;
    var p = try parse(std.testing.allocator, doc);
    defer p.deinit(std.testing.allocator);
    const req = p.requests[0];
    // Only the 2 real fields (mode scalar, name list) - NOT the 2 doc <field> entries.
    try std.testing.expectEqual(@as(usize, 2), req.fields.len);
    try std.testing.expect(req.fields[0].kind == .scalar);
    try std.testing.expect(req.fields[1].kind == .list);
}

test "parse enum, xidtype, and struct" {
    const doc =
        \\<?xml version="1.0"?>
        \\<xcb header="xproto">
        \\  <xidtype name="WINDOW" />
        \\  <enum name="GX">
        \\    <item name="clear"><value>0</value></item>
        \\    <item name="and"><value>1</value></item>
        \\  </enum>
        \\  <struct name="POINT">
        \\    <field type="INT16" name="x" />
        \\    <field type="INT16" name="y" />
        \\  </struct>
        \\</xcb>
    ;
    var p = try parse(std.testing.allocator, doc);
    defer p.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("xproto", p.header);
    try std.testing.expectEqual(@as(usize, 1), p.xids.len);
    try std.testing.expectEqualStrings("WINDOW", p.xids[0].name);
    try std.testing.expectEqual(@as(usize, 1), p.enums.len);
    try std.testing.expectEqual(@as(usize, 2), p.enums[0].items.len);
    try std.testing.expectEqual(@as(i64, 1), p.enums[0].items[1].value);
    try std.testing.expectEqual(@as(usize, 1), p.structs.len);
    try std.testing.expectEqual(@as(usize, 2), p.structs[0].fields.len);
    try std.testing.expectEqualStrings("INT16", p.structs[0].fields[0].type_ref);
}

test "parses extension-xname (null for core)" {
    const ext = "<xcb header=\"xkb\" extension-xname=\"XKEYBOARD\" extension-name=\"xkb\"></xcb>";
    var pe = try parse(std.testing.allocator, ext);
    defer pe.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("XKEYBOARD", pe.extension_xname.?);
    const core = "<xcb header=\"xproto\"></xcb>";
    var pc = try parse(std.testing.allocator, core);
    defer pc.deinit(std.testing.allocator);
    try std.testing.expect(pc.extension_xname == null);
}

test "bitcase captures list fields and multi-field bitcases" {
    const doc =
        \\<xcb header="test">
        \\  <request name="Foo" opcode="1">
        \\    <field type="CARD32" name="which" mask="X"/>
        \\    <switch name="values"><fieldref>which</fieldref>
        \\      <bitcase><enumref ref="X">A</enumref><field type="ATOM" name="single"/></bitcase>
        \\      <bitcase><enumref ref="X">B</enumref><list type="CARD8" name="alist"><fieldref>n</fieldref></list></bitcase>
        \\      <bitcase><enumref ref="X">C</enumref><list type="CARD8" name="l1"><fieldref>n</fieldref></list><pad align="4"/><list type="ATOM" name="l2"><fieldref>n</fieldref></list></bitcase>
        \\    </switch>
        \\  </request>
        \\</xcb>
    ;
    var proto = try parse(std.testing.allocator, doc);
    defer proto.deinit(std.testing.allocator);

    var sw: ?*Switch = null;
    for (proto.requests[0].fields) |f| {
        if (f.kind == .switch_) sw = f.switch_data;
    }
    try std.testing.expect(sw != null);
    const bc = sw.?.bitcases;
    try std.testing.expectEqual(@as(usize, 3), bc.len);
    // bitcase A: one scalar
    try std.testing.expectEqual(@as(usize, 1), bc[0].fields.len);
    try std.testing.expectEqual(FieldType.scalar, bc[0].fields[0].kind);
    // bitcase B: one list (with a length expr captured)
    try std.testing.expectEqual(@as(usize, 1), bc[1].fields.len);
    try std.testing.expectEqual(FieldType.list, bc[1].fields[0].kind);
    try std.testing.expect(bc[1].fields[0].list_len != null);
    // bitcase C: two lists plus an align pad between them (3 fields)
    try std.testing.expectEqual(@as(usize, 3), bc[2].fields.len);
    try std.testing.expectEqual(FieldType.list, bc[2].fields[0].kind);
    try std.testing.expectEqual(FieldType.pad, bc[2].fields[1].kind);
    try std.testing.expect(bc[2].fields[1].pad_align);
    try std.testing.expectEqual(FieldType.list, bc[2].fields[2].kind);
}
