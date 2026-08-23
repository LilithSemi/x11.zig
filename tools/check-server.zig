/// Proves SP-Server-4z-4 Task 5 (RANDR deferred completion): dynamic modes
/// (CreateMode grows GetScreenResources' mode count), the client-defined
/// monitor store (SetMonitor/GetMonitors/DeleteMonitor, incl. the fallback
/// back to the synthetic default once the store empties again), per-crtc
/// transform storage (GetCrtcTransform reports identity by default,
/// SetCrtcTransform changes it), the honest "no providers" surface
/// (GetProviders reports zero, GetProviderInfo/CreateLease on a
/// nonexistent id/lease both fail), and the new OutputProperty event
/// (RRNotify subCode 2) fired by ChangeOutputProperty for a SelectInput'd
/// client. This replaces server_check's prior SP-Server-4z-3 body (gamma /
/// GetMonitors(1.5) / output-properties / BadCrtc+BadOutput); that coverage
/// lives on in randr.zig's/server_state.zig's own unit tests, only the
/// live-socket demonstration moves on to the deferred slice.
///
/// QueryExtension and InternAtom are generated core requests, so those steps
/// go through the normal generated client API. Every RANDR request (major
/// opcode 130, captured here from the QueryExtension reply rather than
/// re-hardcoded) lives outside the generator's xproto+xkb knowledge, so each
/// one is HAND-BUILT: `Connection.send(major, minor, body)` writes the normal
/// short-form request header (encodeRequest computes the length field from
/// `body`'s length, padding `body` itself to a 4-byte boundary) with `body`
/// being the hand-encoded request payload per randr.xml -- `body[i]`
/// corresponds to wire byte `4+i` (right after the major/minor/length
/// header), matching every offset comment below. Reply-bearing requests come
/// back through the ordinary sequence-tracked awaitReply path (generic over
/// reply shape, so it works unmodified for wire layouts the generator never
/// described); only the byte-offset parsing of those reply bodies is
/// hand-rolled here. The OutputProperty event has no reply at all -- it
/// arrives on the ordinary event channel (`Client.nextEvent`), same as any
/// core event.
///
/// Do not weaken any check: every step asserts on a real decoded reply/error/
/// event field, not just "something arrived".
const std = @import("std");
const x11 = @import("x11");
const xproto = @import("xproto");

/// This client always negotiates its own native byte order at handshake
/// (wire.encodeRequest and the setup codec both write in it), so hand-built
/// request/reply bytes on this connection are always in native order too.
const native_endian = @import("builtin").cpu.arch.endian();

/// RANDR minors this proof exercises (randr.xml).
const randr_select_input: u8 = 4;
const randr_get_screen_resources: u8 = 8;
const randr_create_mode: u8 = 16;
const randr_change_output_property: u8 = 13;
const randr_get_crtc_transform: u8 = 27;
const randr_set_crtc_transform: u8 = 26;
const randr_get_providers: u8 = 32;
const randr_get_provider_info: u8 = 33;
const randr_get_monitors: u8 = 42;
const randr_set_monitor: u8 = 43;
const randr_delete_monitor: u8 = 44;
const randr_create_lease: u8 = 45;

/// This synthetic single-CRTC/output config's fixed ids (server_state.
/// RandrConfig's defaults).
const randr_crtc: u32 = 0xf0000001;
const randr_output: u32 = 0xf0000002;

/// A PROVIDER id that never exists (this server reports zero providers,
/// always), used to prove the BadValue error path without touching real
/// state.
const bogus_provider: u32 = 0xdead;

/// Identity transform's fixed-point (16.16) matrix11: server_state's
/// `identity_transform` default.
const identity_matrix11: u32 = 0x00010000;

/// The scaled transform this proof installs via SetCrtcTransform (2x on the
/// X axis; matrix22/matrix33 stay identity).
const scaled_matrix11: u32 = 0x00020000;

/// The synthetic default monitor's fallback size (server.zig synthetic_setup
/// width/height -- what GetMonitors reports once the client-defined store
/// (SetMonitor/DeleteMonitor) empties back out).
const default_monitor_width: u16 = 640;
const default_monitor_height: u16 = 480;

/// The monitor this proof defines via SetMonitor before deleting it again.
const custom_monitor_width: u16 = 800;
const custom_monitor_height: u16 = 600;

/// STRING, a predefined core atom (ICCCM/core protocol atom table).
const xa_string: u32 = 31;

/// Core BadValue error code (X11 protocol errors table, not RANDR-specific --
/// the provider/lease paths this proof exercises intentionally reuse it, see
/// server_main.zig's handleRandr minors 33/45).
const core_bad_value: u8 = 2;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const disp = args.next() orelse ":77";

    var out_buf: [1024]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_fw.interface;

    var a = try x11.Client.open(gpa, io, disp, null, init.environ_map);
    defer a.close();

    const screen = a.defaultScreen() orelse return error.NoDefaultScreen;
    const root = screen.root;

    var xe: x11.wire.XError = undefined;

    // --- 1. QueryExtension("RANDR") -> present, major_opcode 130.
    const qe_cookie = try xproto.query_extension(&a, gpa, "RANDR");
    var qe_reply = try a.awaitReply(xproto.QueryExtensionReply, qe_cookie, &xe);
    const qe = xproto.decodeQueryExtensionReply(qe_reply.bytes);
    qe_reply.deinit();
    try out.print("query_extension(\"RANDR\") -> present={} major_opcode={d}\n", .{ qe.present, qe.major_opcode });
    try stdout_fw.flush();
    if (!qe.present) return error.RandrNotPresent;
    const randr_major = qe.major_opcode;

    // --- 2. CreateMode (minor 16): body window(u32=root), ModeInfo(32B):
    // id(u32=0, ignored -- the server always mints its own), width
    // CARD16@[8..10], height@[10..12], dotClock/hSync*/hTotal/hSkew/vSync*/
    // vTotal all 0@[12..30], nameLength CARD16@[30..32]=len("custom"),
    // modeFlags(u32=0)@[32..36], then name("custom")@[36..] (encodeRequest
    // pads the trailing odd byte to a 4-byte boundary automatically).
    // Reply: mode MODE(u32)@[8..12].
    const custom_mode_id = blk: {
        const name = "custom";
        var body: [4 + 32 + name.len]u8 = std.mem.zeroes([4 + 32 + name.len]u8);
        std.mem.writeInt(u32, body[0..4], root, native_endian);
        std.mem.writeInt(u16, body[8..10], 1600, native_endian); // width
        std.mem.writeInt(u16, body[10..12], 900, native_endian); // height
        std.mem.writeInt(u16, body[30..32], @intCast(name.len), native_endian); // nameLength
        @memcpy(body[36..][0..name.len], name);
        const seq = try a.conn.send(randr_major, randr_create_mode, &body);
        var reply = try awaitRaw(&a, seq, &xe);
        if (reply.bytes.len < 12) return error.CreateModeReplyTooShort;
        if (reply.bytes[0] != 1) return error.CreateModeGotError;
        const mode_id = std.mem.readInt(u32, reply.bytes[8..12], native_endian);
        reply.deinit();
        try out.print("randr.CreateMode(1600x900, \"custom\") -> mode=0x{x}\n", .{mode_id});
        try stdout_fw.flush();
        if (mode_id == 0) return error.CreateModeUnexpectedId;
        break :blk mode_id;
    };
    // Only its non-zero-ness is asserted above; GetScreenResources below
    // proves the id actually landed in the mode list via the grown count.
    _ = custom_mode_id;

    // --- GetScreenResources (minor 8): body window(u32=root, unused by the
    // server -- always "current"). Reply: num_modes CARD16@[20..22]; the 6
    // builtin modes (current + 5 alt) plus the one CreateMode just minted.
    {
        var body: [4]u8 = undefined;
        std.mem.writeInt(u32, &body, root, native_endian);
        const seq = try a.conn.send(randr_major, randr_get_screen_resources, &body);
        var reply = try awaitRaw(&a, seq, &xe);
        if (reply.bytes.len < 22) return error.GetScreenResourcesReplyTooShort;
        if (reply.bytes[0] != 1) return error.GetScreenResourcesGotError;
        const num_modes = std.mem.readInt(u16, reply.bytes[20..22], native_endian);
        reply.deinit();
        try out.print("randr.GetScreenResources() -> num_modes={d}\n", .{num_modes});
        try stdout_fw.flush();
        if (num_modes != 7) return error.GetScreenResourcesUnexpectedModeCount;
    }

    // --- 3. InternAtom("MON1") (core). SetMonitor (minor 43): body
    // window(u32=root), MonitorInfo: name ATOM@[4..8], primary BOOL@[8]=1,
    // automatic BOOL@[9]=1, nOutput CARD16@[10..12]=1, x INT16@[12..14]=0,
    // y@[14..16]=0, width CARD16@[16..18]=800, height@[18..20]=600, width_mm
    // CARD32@[20..24], height_mm@[24..28], outputs[1] CARD32@[28..32]=
    // randr_output. NO reply.
    const mon1_atom = blk: {
        const cookie = try xproto.intern_atom(&a, gpa, false, "MON1");
        var reply = try a.awaitReply(xproto.InternAtomReply, cookie, &xe);
        const decoded = xproto.decodeInternAtomReply(reply.bytes);
        reply.deinit();
        try out.print("intern_atom(\"MON1\") -> atom=0x{x}\n", .{decoded.atom});
        try stdout_fw.flush();
        break :blk decoded.atom;
    };
    {
        var body: [32]u8 = std.mem.zeroes([32]u8);
        std.mem.writeInt(u32, body[0..4], root, native_endian);
        std.mem.writeInt(u32, body[4..8], mon1_atom, native_endian);
        body[8] = 1; // primary
        body[9] = 1; // automatic
        std.mem.writeInt(u16, body[10..12], 1, native_endian); // nOutput
        std.mem.writeInt(i16, body[12..14], 0, native_endian); // x
        std.mem.writeInt(i16, body[14..16], 0, native_endian); // y
        std.mem.writeInt(u16, body[16..18], custom_monitor_width, native_endian);
        std.mem.writeInt(u16, body[18..20], custom_monitor_height, native_endian);
        std.mem.writeInt(u32, body[20..24], 0, native_endian); // width_mm (unchecked)
        std.mem.writeInt(u32, body[24..28], 0, native_endian); // height_mm (unchecked)
        std.mem.writeInt(u32, body[28..32], randr_output, native_endian);
        _ = try a.conn.send(randr_major, randr_set_monitor, &body);
        try out.print("randr.SetMonitor(MON1, {d}x{d}, output=0x{x})\n", .{ custom_monitor_width, custom_monitor_height, randr_output });
        try stdout_fw.flush();
    }

    // --- GetMonitors (minor 42): body window(u32=root), get_active
    // BOOL(u8=1), pad3. Reply: nMonitors CARD32@[12..16], then ONE
    // MonitorInfo@[32..]: name ATOM@32, primary BOOL@36, automatic BOOL@37,
    // nOutput CARD16@[38..40], x INT16@[40..42], y@[42..44], width
    // CARD16@[44..46], height@[46..48], width_mm CARD32@[48..52],
    // height_mm@[52..56], outputs[nOutput] CARD32 starting @56.
    try assertMonitors(&a, randr_major, root, &xe, out, &stdout_fw, 1, custom_monitor_width, custom_monitor_height, randr_output);

    // --- DeleteMonitor (minor 44): body window(u32=root), name ATOM@[4..8].
    // NO reply. GetMonitors afterward falls back to the synthetic default
    // (1 MonitorInfo covering the single output at the live screen size).
    {
        var body: [8]u8 = undefined;
        std.mem.writeInt(u32, body[0..4], root, native_endian);
        std.mem.writeInt(u32, body[4..8], mon1_atom, native_endian);
        _ = try a.conn.send(randr_major, randr_delete_monitor, &body);
        try out.print("randr.DeleteMonitor(MON1)\n", .{});
        try stdout_fw.flush();
    }
    try assertMonitors(&a, randr_major, root, &xe, out, &stdout_fw, 1, default_monitor_width, default_monitor_height, randr_output);

    // --- 4. GetCrtcTransform (minor 27): body crtc(u32). Reply (96 bytes):
    // pending_transform's matrix11 (first FIXED, CARD32)@[8..12] -- identity
    // by default.
    try assertCrtcTransform(&a, randr_major, &xe, out, &stdout_fw, identity_matrix11);

    // --- SetCrtcTransform (minor 26): body crtc(u32), transform TRANSFORM
    // (9 FIXED = 36 bytes)@[4..40]: matrix11=scaled, matrix22/matrix33=
    // identity, the rest 0. NO reply. GetCrtcTransform afterward reflects it.
    {
        var body: [4 + 36]u8 = std.mem.zeroes([4 + 36]u8);
        std.mem.writeInt(u32, body[0..4], randr_crtc, native_endian);
        std.mem.writeInt(u32, body[4..8], scaled_matrix11, native_endian); // matrix11
        std.mem.writeInt(u32, body[4 + 16 ..][0..4], identity_matrix11, native_endian); // matrix22 (index 4)
        std.mem.writeInt(u32, body[4 + 32 ..][0..4], identity_matrix11, native_endian); // matrix33 (index 8)
        _ = try a.conn.send(randr_major, randr_set_crtc_transform, &body);
        try out.print("randr.SetCrtcTransform(crtc=0x{x}, matrix11=0x{x})\n", .{ randr_crtc, scaled_matrix11 });
        try stdout_fw.flush();
    }
    try assertCrtcTransform(&a, randr_major, &xe, out, &stdout_fw, scaled_matrix11);

    // --- 5. GetProviders (minor 32): body window(u32=root). Reply:
    // num_providers CARD16@[12..14]=0 -- no GPU providers in this
    // software-render model.
    {
        var body: [4]u8 = undefined;
        std.mem.writeInt(u32, &body, root, native_endian);
        const seq = try a.conn.send(randr_major, randr_get_providers, &body);
        var reply = try awaitRaw(&a, seq, &xe);
        if (reply.bytes.len < 14) return error.GetProvidersReplyTooShort;
        if (reply.bytes[0] != 1) return error.GetProvidersGotError;
        const num_providers = std.mem.readInt(u16, reply.bytes[12..14], native_endian);
        reply.deinit();
        try out.print("randr.GetProviders(root=0x{x}) -> num_providers={d}\n", .{ root, num_providers });
        try stdout_fw.flush();
        if (num_providers != 0) return error.GetProvidersUnexpectedCount;
    }

    // --- GetProviderInfo (minor 33) on a provider id that never exists ->
    // core BadValue (code 2). `awaitReply` surfaces a real X error as
    // `error.XProtocolError` (decoded into `xe`), not as reply bytes.
    {
        var body: [4]u8 = undefined;
        std.mem.writeInt(u32, &body, bogus_provider, native_endian);
        const seq = try a.conn.send(randr_major, randr_get_provider_info, &body);
        if (awaitRaw(&a, seq, &xe)) |reply| {
            var r = reply;
            r.deinit();
            return error.GetProviderInfoDidNotError;
        } else |err| {
            if (err != error.XProtocolError) return err;
            try out.print("randr.GetProviderInfo(provider=0x{x} BOGUS) -> error code={d}\n", .{ bogus_provider, xe.code });
            try stdout_fw.flush();
            if (xe.code != core_bad_value) return error.GetProviderInfoUnexpectedCode;
        }
    }

    // --- CreateLease (minor 45): body window(u32=root), lid(u32=arbitrary)
    // (+ crtcs/outputs lists this server never reads). Always BadValue --
    // leasing needs real DRM fd-passing this server doesn't do.
    {
        var body: [8]u8 = undefined;
        std.mem.writeInt(u32, body[0..4], root, native_endian);
        std.mem.writeInt(u32, body[4..8], 0x1, native_endian); // lid
        const seq = try a.conn.send(randr_major, randr_create_lease, &body);
        if (awaitRaw(&a, seq, &xe)) |reply| {
            var r = reply;
            r.deinit();
            return error.CreateLeaseDidNotError;
        } else |err| {
            if (err != error.XProtocolError) return err;
            try out.print("randr.CreateLease() -> error code={d}\n", .{xe.code});
            try stdout_fw.flush();
            if (xe.code != core_bad_value) return error.CreateLeaseUnexpectedCode;
        }
    }

    // --- 6. RANDR SelectInput (minor 4): body window(u32=root), enable
    // CARD16@[4..6]=0x8 (NotifyMask OutputProperty). NO reply.
    {
        var body: [6]u8 = undefined;
        std.mem.writeInt(u32, body[0..4], root, native_endian);
        std.mem.writeInt(u16, body[4..6], 0x8, native_endian);
        _ = try a.conn.send(randr_major, randr_select_input, &body);
        try out.print("randr.SelectInput(root=0x{x}, OutputProperty)\n", .{root});
        try stdout_fw.flush();
    }

    // --- InternAtom("EVPROP") (core). ChangeOutputProperty (minor 13): body
    // output(u32), property(u32=EVPROP), type(u32=STRING), format(u8=8),
    // mode(u8=0 Replace), pad2, num_units(u32=1), data("x"). NO reply --
    // instead it fires a randr_output_property event to this SelectInput'd
    // client, delivered on the ordinary event channel.
    const evprop_atom = blk: {
        const cookie = try xproto.intern_atom(&a, gpa, false, "EVPROP");
        var reply = try a.awaitReply(xproto.InternAtomReply, cookie, &xe);
        const decoded = xproto.decodeInternAtomReply(reply.bytes);
        reply.deinit();
        try out.print("intern_atom(\"EVPROP\") -> atom=0x{x}\n", .{decoded.atom});
        try stdout_fw.flush();
        break :blk decoded.atom;
    };
    {
        var body: [21]u8 = std.mem.zeroes([21]u8);
        std.mem.writeInt(u32, body[0..4], randr_output, native_endian);
        std.mem.writeInt(u32, body[4..8], evprop_atom, native_endian);
        std.mem.writeInt(u32, body[8..12], xa_string, native_endian);
        body[12] = 8; // format
        body[13] = 0; // mode: Replace
        std.mem.writeInt(u32, body[16..20], 1, native_endian); // num_units
        body[20] = 'x';
        _ = try a.conn.send(randr_major, randr_change_output_property, &body);
        try out.print("randr.ChangeOutputProperty(output=0x{x}, EVPROP=\"x\")\n", .{randr_output});
        try stdout_fw.flush();
    }

    // --- Await the RRNotify/OutputProperty event this ChangeOutputProperty
    // just fanned out: [0]=65 (RRNotify's event code, first_event+1),
    // [1]=2 (evt_output_property_subcode), [8..12]=output, [12..16]=atom.
    {
        const incoming = try a.nextEvent();
        const ev = switch (incoming) {
            .event => |e| e,
            .err => |e| {
                try out.print("randr.ChangeOutputProperty -> unexpected X error code={d}\n", .{e.code});
                try stdout_fw.flush();
                return error.OutputPropertyEventGotError;
            },
        };
        const code = ev.bytes[0];
        const sub_code = ev.bytes[1];
        const ev_output = std.mem.readInt(u32, ev.bytes[8..12], native_endian);
        const ev_atom = std.mem.readInt(u32, ev.bytes[12..16], native_endian);
        try out.print("randr OutputProperty event -> code={d} subCode={d} output=0x{x} atom=0x{x}\n", .{ code, sub_code, ev_output, ev_atom });
        try stdout_fw.flush();
        if (code != x11.randr.evt_crtc_change) return error.OutputPropertyEventUnexpectedCode;
        if (sub_code != x11.randr.evt_output_property_subcode) return error.OutputPropertyEventUnexpectedSubCode;
        if (ev_output != randr_output) return error.OutputPropertyEventUnexpectedOutput;
        if (ev_atom != evprop_atom) return error.OutputPropertyEventUnexpectedAtom;
    }

    try out.print("randr deferred proven\n", .{});
    try stdout_fw.flush();
}

/// GetMonitors (minor 42) + assert: nMonitors, the first (only) monitor's
/// width/height, and its bound output id. Shared by the "SetMonitor took"
/// and "DeleteMonitor fell back to the synthetic default" checks above --
/// same wire layout, different expected numbers.
fn assertMonitors(
    a: *x11.Client,
    randr_major: u8,
    root: u32,
    xe: *x11.wire.XError,
    out: *std.Io.Writer,
    stdout_fw: *std.Io.File.Writer,
    expected_n_monitors: u32,
    expected_width: u16,
    expected_height: u16,
    expected_output: u32,
) !void {
    var body: [8]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], root, native_endian);
    body[4] = 1; // get_active
    body[5] = 0;
    body[6] = 0;
    body[7] = 0;
    const seq = try a.conn.send(randr_major, randr_get_monitors, &body);
    var reply = try awaitRaw(a, seq, xe);
    if (reply.bytes.len < 60) return error.GetMonitorsReplyTooShort;
    if (reply.bytes[0] != 1) return error.GetMonitorsGotError;
    const n_monitors = std.mem.readInt(u32, reply.bytes[12..16], native_endian);
    const width = std.mem.readInt(u16, reply.bytes[44..46], native_endian);
    const height = std.mem.readInt(u16, reply.bytes[46..48], native_endian);
    const output = std.mem.readInt(u32, reply.bytes[56..60], native_endian);
    reply.deinit();
    try out.print("randr.GetMonitors(root=0x{x}) -> nMonitors={d} {d}x{d} output=0x{x}\n", .{ root, n_monitors, width, height, output });
    try stdout_fw.flush();
    if (n_monitors != expected_n_monitors) return error.GetMonitorsUnexpectedCount;
    if (width != expected_width) return error.GetMonitorsUnexpectedWidth;
    if (height != expected_height) return error.GetMonitorsUnexpectedHeight;
    if (output != expected_output) return error.GetMonitorsUnexpectedOutput;
}

/// GetCrtcTransform (minor 27) + assert matrix11 (the first FIXED entry of
/// the reported `pending_transform`, CARD32@[8..12]) equals `expected`.
fn assertCrtcTransform(
    a: *x11.Client,
    randr_major: u8,
    xe: *x11.wire.XError,
    out: *std.Io.Writer,
    stdout_fw: *std.Io.File.Writer,
    expected_matrix11: u32,
) !void {
    var body: [4]u8 = undefined;
    std.mem.writeInt(u32, &body, randr_crtc, native_endian);
    const seq = try a.conn.send(randr_major, randr_get_crtc_transform, &body);
    var reply = try awaitRaw(a, seq, xe);
    if (reply.bytes.len < 12) return error.GetCrtcTransformReplyTooShort;
    if (reply.bytes[0] != 1) return error.GetCrtcTransformGotError;
    const matrix11 = std.mem.readInt(u32, reply.bytes[8..12], native_endian);
    reply.deinit();
    try out.print("randr.GetCrtcTransform(crtc=0x{x}) -> matrix11=0x{x}\n", .{ randr_crtc, matrix11 });
    try stdout_fw.flush();
    if (matrix11 != expected_matrix11) return error.GetCrtcTransformUnexpectedMatrix;
}

/// Await a reply for a hand-built (non-generated) extension request. The
/// generic sequence-tracking reply path (Connection.reply, wrapped here
/// through the public awaitReply) does not care what request produced the
/// reply, so this works unmodified for wire layouts the generator never
/// described; the caller parses `bytes` itself per the hand-encoded layout.
/// A real X error never reaches this return path at all -- it surfaces as
/// `error.XProtocolError` with the decoded fields written into `out_err`, so
/// callers expecting an error switch on that instead of inspecting reply
/// bytes.
fn awaitRaw(a: *x11.Client, seq: u64, out_err: *x11.wire.XError) !x11.connection.Reply {
    const RawReply = struct {};
    const c: x11.cookie.Cookie(RawReply) = .{ .sequence = seq };
    return a.awaitReply(RawReply, c, out_err);
}
