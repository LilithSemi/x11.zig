const std = @import("std");
const xcbproto = @import("xcbproto.zig");
const registry = @import("registry.zig");
const codegen = @import("codegen.zig");

/// CLI entry point. The error set stays inferred by design: as the program
/// entry it has no caller to inform, and it aborts on any fault (bad args, an
/// unreadable input, malformed protocol XML, or a failed write).
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // usage: x11-gen <input.xml> <output.zig> [import1.xml import2.xml ...]
    if (args.len < 3) return error.Usage;

    const input = args[1];
    const output = args[2];

    var main_proto = try parseFile(gpa, io, input);
    defer main_proto.deinit(gpa);

    var reg = registry.Registry.init(gpa);
    defer reg.deinit();

    // Parse import-seed XMLs (args[3..]) into the registry so cross-file refs
    // resolve. Keep them alive until after generate().
    var seeds: std.ArrayList(xcbproto.Protocol) = .empty;
    defer {
        for (seeds.items) |*p| p.deinit(gpa);
        seeds.deinit(gpa);
    }
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const sp = try parseFile(gpa, io, args[i]);
        try seeds.append(gpa, sp);
    }
    for (seeds.items) |*p| try reg.addProtocol(p);
    try reg.addProtocol(&main_proto);

    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    try codegen.generate(gpa, &out_buf.writer, &main_proto, &reg);
    const generated = try out_buf.toOwnedSlice();
    defer gpa.free(generated);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = generated });
}

fn parseFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) (std.Io.Dir.ReadFileAllocError || xcbproto.ParseError)!xcbproto.Protocol {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.unlimited);
    defer gpa.free(bytes);
    return xcbproto.parse(gpa, bytes);
}
