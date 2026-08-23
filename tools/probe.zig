/// Live X server conformance walk.
///
/// Connects to a real X server and drives the generated bindings through the
/// wire paths a server implementation will depend on: resource-id allocation,
/// the value-list switch request encoder (CreateWindow), fixed and list reply
/// decoders (GetGeometry, GetWindowAttributes, GetProperty, QueryTree), a
/// property round-trip, extension dispatch (XKB over the wire), and a real
/// asynchronous event (MapNotify). Any wire-format defect surfaces here as a
/// decode mismatch or an X protocol error instead of in the eventual server.
///
/// Usage: zig build run-probe -- :99   (needs an X server, e.g. Xvfb, on :99)
const std = @import("std");
const x11 = @import("x11");
const xproto = @import("xproto");
const xkb = @import("xkb");

/// Predefined atoms (X11 protocol, appendix "Predefined Atoms"): fixed ids
/// every server knows without an InternAtom round-trip.
const atom_wm_name: u32 = 39;
const atom_string: u32 = 31;

/// A subset of the SetOfEvent mask used to select events on our window.
const event_structure_notify: u32 = 1 << 17;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = init.minimal.args.iterate();
    _ = args_it.skip();
    const display_str: []const u8 = args_it.next() orelse ":99";

    var out_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_fw.interface;

    var client = try x11.Client.open(gpa, io, display_str, null, init.environ_map);
    defer client.close();

    const root = client.conn.setup.root;
    try out.print("connected: root=0x{x} root_visual=0x{x}\n", .{ root, client.conn.setup.root_visual });
    try stdout_fw.flush();

    // Walk the default screen's borrowed depth/visual iterators end to end:
    // proves the setup-buffer iterators (Task 2/3) see every depth and every
    // visual the server actually advertised, not just the first of each.
    if (client.defaultScreen()) |screen| {
        var ndepths: usize = 0;
        var nvisuals: usize = 0;
        var dit = screen.depths();
        while (dit.next()) |d| {
            ndepths += 1;
            var vit = d.visuals();
            while (vit.next()) |_| nvisuals += 1;
        }
        try out.print("default screen -> root_depth={d} depths={d} visuals={d}\n", .{ screen.root_depth, ndepths, nvisuals });
        try stdout_fw.flush();
    }

    // Core round-trip: GetInputFocus (opcode 43, no arguments).
    var xe: x11.wire.XError = undefined;
    const focus_cookie = try xproto.get_input_focus(&client);
    var focus_reply = try client.awaitReply(xproto.GetInputFocusReply, focus_cookie, &xe);
    defer focus_reply.deinit();
    const focus = xproto.decodeGetInputFocusReply(focus_reply.bytes);
    try out.print("GetInputFocus -> revert_to={d} focus=0x{x}\n", .{ focus.revert_to, focus.focus });
    try stdout_fw.flush();

    // Intern a well-known atom to prove request-body encoding (list arg).
    var xe2: x11.wire.XError = undefined;
    const atom_cookie = try xproto.intern_atom(&client, gpa, false, "PRIMARY");
    var atom_reply = try client.awaitReply(@TypeOf(atom_cookie).ReplyType, atom_cookie, &xe2);
    defer atom_reply.deinit();
    const interned = xproto.decodeInternAtomReply(atom_reply.bytes);
    try out.print("interned PRIMARY -> atom=0x{x}\n", .{interned.atom});
    try stdout_fw.flush();

    // --- Resource creation: allocate an id and create a real window. This is
    // the value-list SWITCH encoder (the most complex generated request). We
    // set three optionals spanning the mask so packing + mask derivation are
    // exercised, and select StructureNotify so mapping yields an event later.
    const wid = client.generateId();
    var xe_cw: x11.wire.XError = undefined;
    const cw_cookie = try xproto.create_window(
        &client,
        gpa,
        0, // depth = CopyFromParent
        wid,
        root,
        0, // x
        0, // y
        100, // width
        100, // height
        0, // border_width
        1, // class = InputOutput
        0, // visual = CopyFromParent
        .{
            .background_pixel = 0,
            .override_redirect = 1,
            .event_mask = event_structure_notify,
        },
    );
    // CreateWindow has no reply; flush and check for a protocol error via a
    // following synchronous request (GetGeometry on the new window).
    _ = cw_cookie;
    const geom_cookie = try xproto.get_geometry(&client, wid);
    var geom_reply = try client.awaitReply(xproto.GetGeometryReply, geom_cookie, &xe_cw);
    defer geom_reply.deinit();
    const geom = xproto.decodeGetGeometryReply(geom_reply.bytes);
    try out.print("created window 0x{x} -> geometry {d}x{d}+{d}+{d} depth={d}\n", .{ wid, geom.width, geom.height, geom.x, geom.y, geom.depth });
    try stdout_fw.flush();

    // GetWindowAttributes: a fixed reply with many packed scalars. Prove the
    // attributes we set on creation came back (override_redirect, event_mask).
    var xe_ga: x11.wire.XError = undefined;
    const ga_cookie = try xproto.get_window_attributes(&client, wid);
    var ga_reply = try client.awaitReply(xproto.GetWindowAttributesReply, ga_cookie, &xe_ga);
    defer ga_reply.deinit();
    const attrs = xproto.decodeGetWindowAttributesReply(ga_reply.bytes);
    try out.print("attributes -> class={d} override_redirect={} your_event_mask=0x{x}\n", .{ attrs.class, attrs.override_redirect, attrs.your_event_mask });
    try stdout_fw.flush();

    // --- Property round-trip: ChangeProperty then GetProperty, byte-list body.
    var xe_cp: x11.wire.XError = undefined;
    const cp_cookie = try xproto.change_property(&client, gpa, 0, wid, atom_wm_name, atom_string, 8, 5, "hello");
    _ = cp_cookie;
    const gp_cookie = try xproto.get_property(&client, false, wid, atom_wm_name, atom_string, 0, 1024);
    var gp_reply = try client.awaitReply(xproto.GetPropertyReply, gp_cookie, &xe_cp);
    defer gp_reply.deinit();
    const prop = xproto.decodeGetPropertyReply(gp_reply.bytes);
    try out.print("property WM_NAME -> format={d} value_len={d} value=\"{s}\"\n", .{ prop.format, prop.value_len, prop.value });
    try stdout_fw.flush();

    // --- List reply: QueryTree returns the children WINDOW list of the root.
    var xe_qt: x11.wire.XError = undefined;
    const qt_cookie = try xproto.query_tree(&client, root);
    var qt_reply = try client.awaitReply(xproto.QueryTreeReply, qt_cookie, &xe_qt);
    defer qt_reply.deinit();
    const tree = xproto.decodeQueryTreeReply(qt_reply.bytes);
    try out.print("query_tree root -> parent=0x{x} children={d}\n", .{ tree.parent, tree.children_len });
    try stdout_fw.flush();

    // --- Live event: map the window and pull the resulting MapNotify. A
    // reply-bearing request (GetInputFocus) pumps the socket so buffered
    // events land in the queue; nextEvent() then drains them.
    const map_cookie = try xproto.map_window(&client, wid);
    _ = map_cookie;
    var xe_sync: x11.wire.XError = undefined;
    const sync_cookie = try xproto.get_input_focus(&client);
    var sync_reply = try client.awaitReply(xproto.GetInputFocusReply, sync_cookie, &xe_sync);
    sync_reply.deinit();
    // Block for real events now. A mapped StructureNotify-selected window is
    // guaranteed a MapNotify by the protocol, so this terminates. Skip any
    // other spontaneous events; ignore stray errors here.
    var saw_map_notify = false;
    while (!saw_map_notify) {
        switch (try client.nextEvent()) {
            .event => |ev| {
                // Typed dispatch (Task 4) instead of a raw byte compare: proves
                // the generated Event union round-trips a live wire event.
                if (xproto.decodeEvent(&ev.bytes) == .map_notify) saw_map_notify = true;
            },
            .err => {}, // not expected in this phase; the error probe is below
        }
    }
    try out.print("map_window -> saw MapNotify={}\n", .{saw_map_notify});
    try stdout_fw.flush();

    // Deliberate async error: map a window id we never created. map_window has
    // no reply, so its BadWindow error is unclaimed and must surface through
    // the event loop as .err. Pump with a synchronous round-trip first.
    _ = try xproto.map_window(&client, 0xDEADBEEF);
    var xe_pump: x11.wire.XError = undefined;
    const pump_cookie = try xproto.get_input_focus(&client);
    var pump_reply = try client.awaitReply(xproto.GetInputFocusReply, pump_cookie, &xe_pump);
    pump_reply.deinit();
    var bad_code: u8 = 0;
    while (bad_code == 0) {
        switch (try client.nextEvent()) {
            .err => |e| bad_code = e.code,
            .event => {}, // skip any stray event
        }
    }
    try out.print("bad map_window -> surfaced error code={d}\n", .{bad_code});
    try stdout_fw.flush();

    // Query + use the XKB extension over the wire (proves extension dispatch).
    const xkb_info = try client.queryExtension("XKEYBOARD");
    try out.print("XKEYBOARD present={} major=0x{x}\n", .{ xkb_info.present, xkb_info.major_opcode });
    if (xkb_info.present) {
        var xe3: x11.wire.XError = undefined;
        const use_cookie = try xkb.use_extension(&client, 1, 0);
        var use_reply = try client.awaitReply(@TypeOf(use_cookie).ReplyType, use_cookie, &xe3);
        defer use_reply.deinit();
        const used = xkb.decodeUseExtensionReply(use_reply.bytes);
        try out.print("xkb UseExtension -> supported={} server={d}.{d}\n", .{ used.supported, used.serverMajor, used.serverMinor });
    }
    try stdout_fw.flush();

    // Clean up the window we created.
    _ = try xproto.destroy_window(&client, wid);

    const ev_owner = client.eventExtension(xkb_info.first_event) orelse "none";
    const er_owner = client.errorExtension(xkb_info.first_error) orelse "none";
    try out.print("classify: event@0x{x}->{s} error@0x{x}->{s}\n", .{ xkb_info.first_event, ev_owner, xkb_info.first_error, er_owner });
    try out.flush();
}
