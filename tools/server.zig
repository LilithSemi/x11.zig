/// Minimal X11 server: listen on the given display, accept clients one at a
/// time, handshake, and serve their requests until they disconnect.
const std = @import("std");
const x11 = @import("x11");
const xproto = @import("xproto");

/// Test-only synthetic input backend, enabled by the `--inject-demo` flag. Once
/// the first client-owned window becomes viewable, inject a Motion + ButtonPress
/// + ButtonRelease into its center - a stand-in for Lattice's libinput feed
/// (a real X server reads hardware; this reads a hardcoded script). Off by
/// default; normal runs are unaffected.
var inject_demo_enabled: bool = false;
var inject_demo_done: bool = false;
var inject_key_demo_done: bool = false;
var inject_grab_demo_done: bool = false;
var inject_passive_demo_done: bool = false;
var passive_key_grab_seen: bool = false;
var passive_button_grab_seen: bool = false;

fn maybeInjectDemo(display: *x11.Display, mux: *x11.Multiplexer, wid: u32) !void {
    if (!inject_demo_enabled or inject_demo_done) return;
    // Wait for a real client window. We gate on "not the root" rather than
    // owner!=0 because client_id 0 (the first accepted client) collides with the
    // 0 server/root-owned sentinel - reserving id 0 for the server is a separate
    // cleanup. The root is never mapped by a client (mapWindow(root) is a no-op),
    // so the first non-root window reaching here is a client's.
    if (wid == display.root) return;
    const win = display.windows.getPtr(wid) orelse return;
    inject_demo_done = true;
    // Center of the window in root coords (its outer origin + border + half-extent).
    const cx: i16 = @truncate(@as(i32, win.geom.x) + win.geom.border_width + @divTrunc(win.geom.width, 2));
    const cy: i16 = @truncate(@as(i32, win.geom.y) + win.geom.border_width + @divTrunc(win.geom.height, 2));
    try display.injectMotion(cx, cy, 1);
    try display.injectButton(1, true, 2);
    try display.injectButton(1, false, 3);
    deliverPending(display, mux);
}

/// Test-only (with --inject-demo): on the first client SetInputFocus, inject
/// Shift press, 'a' press+release (carrying ShiftMask), then Shift release.
/// Proves the focus -> key-routing path AND modifier-state tracking end to
/// end. The map-triggered pointer demo is separate.
fn maybeInjectKeyDemo(display: *x11.Display, mux: *x11.Multiplexer) !void {
    if (!inject_demo_enabled or inject_key_demo_done) return;
    inject_key_demo_done = true;
    try display.injectKey(50, true, 10); // Shift press
    try display.injectKey(38, true, 11); // 'a' press (carries ShiftMask)
    try display.injectKey(38, false, 12); // 'a' release
    try display.injectKey(50, false, 13); // Shift release
    deliverPending(display, mux);
}

/// Test-only (with --inject-demo): on the first successful GrabPointer, inject
/// a motion to a corner FAR from the grab window plus a button press+release.
/// Proves grabbed events reach the grab client on grab_window regardless of
/// where the pointer actually lands (the live-proof harness checks the
/// received events' event_window == the grabbed window, not the spatial
/// window under (600,400)).
fn maybeInjectGrabDemo(display: *x11.Display, mux: *x11.Multiplexer) !void {
    if (!inject_demo_enabled or inject_grab_demo_done) return;
    inject_grab_demo_done = true;
    try display.injectMotion(600, 400, 20); // far corner, away from any typical window placement
    try display.injectButton(1, true, 21);
    try display.injectButton(1, false, 22);
    deliverPending(display, mux);
}

/// Test-only (with --inject-demo): once BOTH a passive GrabKey and a passive
/// GrabButton have been registered (in either order -- called from both the
/// .grab_key and .grab_button arms below, tracking each separately), inject
/// the SAME key/button+modifiers the live-proof harness grabs (keycode 24,
/// button 1, no modifiers) as a press+release pair each. Each press should
/// auto-activate the matching passive grab and deliver the press to the
/// grabbing client (see matchButtonGrab/matchKeyGrab in server_state.zig);
/// each release should auto-release it. Deferred until both grabs are seen
/// so the demo doesn't fire half-armed if the harness registers them in the
/// opposite order.
fn maybeInjectPassiveDemo(display: *x11.Display, mux: *x11.Multiplexer) !void {
    if (!inject_demo_enabled or inject_passive_demo_done) return;
    if (!(passive_key_grab_seen and passive_button_grab_seen)) return;
    inject_passive_demo_done = true;
    try display.injectKey(24, true, 30); // matches GrabKey(key=24, modifiers=0)
    try display.injectKey(24, false, 31);
    try display.injectButton(1, true, 32); // matches GrabButton(button=1, modifiers=0)
    try display.injectButton(1, false, 33);
    deliverPending(display, mux);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const disp_str = args.next() orelse ":77";
    // Remaining args are flags; only `--inject-demo` is recognized so far.
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--inject-demo")) inject_demo_enabled = true;
    }
    // parse the display number (":77" -> 77)
    const num = std.fmt.parseInt(u16, disp_str[if (disp_str.len > 0 and disp_str[0] == ':') 1 else 0..], 10) catch 77;

    var srv = try x11.Server.listen(gpa, io, num);
    defer srv.deinit();

    var out_buf: [256]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_fw.interface;
    try out.print("x11.zig server listening on :{d}\n", .{num});
    try stdout_fw.flush();

    var mux = x11.Multiplexer.init(&srv);
    defer mux.deinit();
    while (mux.next() catch |err| {
        out.print("server serve loop ended: {s}\n", .{@errorName(err)}) catch {};
        stdout_fw.flush() catch {};
        return;
    }) |ev| switch (ev) {
        .connected => |c| {
            out.print("client connected (fd {d})\n", .{c.fd()}) catch {};
            stdout_fw.flush() catch {};
        },
        .disconnected => |c| {
            // SetCloseDownMode(mode) picks the teardown: DestroyAll(0, the
            // default) destroys everything this client owned (firing
            // DestroyNotify to other selectors) and scrubs its selections,
            // then reclaims its id range. RetainPermanent(1)/RetainTemporary(2)
            // only scrub its selections/grabs -- its resources stay alive
            // under its owner id, so the id range is NOT released (a new
            // client must not collide with still-live retained resources);
            // a later KillClient destroys them. The set_close_down_mode arm
            // rejects mode > 2, so only 0/1/2 ever land here.
            if (c.close_down_mode == 0) {
                // On a cleanup OOM, drop the partial event recording and
                // RETIRE the index rather than reuse a range that may still
                // hold undestroyed windows.
                if (srv.display.cleanupClient(c.client_id)) {
                    deliverPending(&srv.display, &mux);
                    mux.releaseClientId(c.client_id);
                } else |err| {
                    srv.display.clearPending();
                    out.print("client {d} cleanup failed: {s}\n", .{ c.client_id, @errorName(err) }) catch {};
                }
            } else {
                if (srv.display.retainClient(c.client_id, c.close_down_mode == 2)) {
                    deliverPending(&srv.display, &mux);
                } else |err| {
                    srv.display.clearPending();
                    out.print("client {d} retain failed: {s}\n", .{ c.client_id, @errorName(err) }) catch {};
                }
            }
            out.print("client disconnected (fd {d})\n", .{c.fd()}) catch {};
            stdout_fw.flush() catch {};
        },
        .request => |r| dispatchRequest(r.conn, r.bytes, &srv.display, &mux) catch |err| {
            out.print("request dispatch fault: {s}\n", .{@errorName(err)}) catch {};
            stdout_fw.flush() catch {};
        },
    };
}

/// Decode and answer ONE request, writing replies/events into the connection's
/// outbound buffer (the Multiplexer flushes it). The 8 window requests are
/// dispatched to the shared `display`; others get their reply or
/// BadImplementation as before. `errdefer clearPending` drops any events
/// recorded before a faulting exit, so they cannot bleed into the next request
/// on the shared Display.
fn dispatchRequest(conn: *x11.ServerConn, bytes: []const u8, display: *x11.Display, mux: *x11.Multiplexer) !void {
    errdefer display.clearPending();
    const en = conn.client_endian;
    const opcode = bytes[0];
    const seq = conn.nextSeq();
    const w = conn.outWriter();
    // Extension requests (major opcode >=128) are never seen by
    // xproto.decodeRequest -- the generator only emits core xproto+xkb, so
    // an extension's requests are hand-decoded in handleExtensionRequest.
    // Intercept BEFORE the core-request switch below (opcode<128 is never
    // an extension opcode, so the two paths never overlap).
    if (opcode >= 128) {
        try handleExtensionRequest(conn, opcode, bytes, display, seq, mux);
        return;
    }
    switch (xproto.decodeRequest(opcode, bytes, en)) {
        .create_window => |r| {
            const geom: x11.server_state.Geometry = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height, .border_width = r.border_width, .depth = r.depth };
            if (display.createWindow(r.wid, r.parent, geom, r.class, r.visual, deltaFromCreate(r.value_list), conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.IdInUse => try xproto.encodeIDChoiceError(w, en, seq, .{ .bad_value = r.wid, .minor_opcode = 0, .major_opcode = opcode }),
                error.NoParent => try xproto.encodeWindowError(w, en, seq, .{ .bad_value = r.parent, .minor_opcode = 0, .major_opcode = opcode }),
                error.TooManyResources => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = r.wid, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .destroy_window => |r| {
            if (display.destroyWindow(r.window)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.OutOfMemory => return e,
            }
        },
        .map_window => |r| {
            if (display.mapWindow(r.window, conn.client_id)) {
                deliverPending(display, mux);
                try maybeInjectDemo(display, mux, r.window);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.OutOfMemory => return e,
            }
        },
        .unmap_window => |r| {
            if (display.unmapWindow(r.window)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.OutOfMemory => return e,
            }
        },
        .warp_pointer => |r| {
            if (display.warpPointer(r.src_window, r.dst_window, r.src_x, r.src_y, r.src_width, r.src_height, r.dst_x, r.dst_y)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                // Either src_window or dst_window could be the offender; report
                // dst_window (the loose bad_value precedent used elsewhere).
                error.NoWindow => try badWindow(w, en, seq, opcode, r.dst_window),
                error.OutOfMemory => return e,
            }
        },
        .map_subwindows => |r| {
            if (display.mapSubwindows(r.window, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.OutOfMemory => return e,
            }
        },
        .unmap_subwindows => |r| {
            if (display.unmapSubwindows(r.window)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.OutOfMemory => return e,
            }
        },
        .change_window_attributes => |r| {
            display.changeAttributes(r.window, deltaFromChange(r.value_list), conn.client_id) catch |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                // SubstructureRedirect is exclusive; a second selector is rejected.
                error.Access => try xproto.encodeAccessError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .configure_window => |r| {
            if (display.configureWindow(r.window, deltaFromConfigure(r.value_list), conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.TooLarge => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = r.window, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .reparent_window => |r| {
            if (display.reparentWindow(r.window, r.parent, r.x, r.y, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                // Either the window or the new parent could be the missing id;
                // reparentWindow collapses both to NoWindow, so report the window
                // (the request's primary resource) - matches the neighboring arms.
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .change_save_set => |r| {
            // No reply, no events of its own; the rescue reparent that this
            // save-set entry may later trigger fires ReparentNotify at the
            // saving client's disconnect, delivered from that codepath.
            display.changeSaveSet(r.mode, r.window, conn.client_id) catch |e| switch (e) {
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.mode, .minor_opcode = 0, .major_opcode = opcode }),
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .circulate_window => |r| {
            if (display.circulateWindow(r.window, r.direction, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.direction, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .get_geometry => |r| {
            if (display.drawable(r.drawable)) |info| {
                try xproto.encodeGetGeometryReply(w, en, seq, .{ .depth = info.depth, .root = info.root, .x = info.x, .y = info.y, .width = info.width, .height = info.height, .border_width = info.border_width });
            } else try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode });
        },
        .poly_fill_rectangle => |r| {
            var i: usize = 0;
            while (i < r.rectangles.len()) : (i += 1) {
                const rect = r.rectangles.at(i);
                display.fillRect(r.drawable, r.gc, rect.x, rect.y, rect.width, rect.height) catch |e| {
                    switch (e) {
                        error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                        error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                    }
                    break; // drawable/gc are constant within a request
                };
            }
        },
        .poly_point => |r| {
            const n = r.points.len();
            const pts = try display.gpa.alloc(x11.render.Point, n);
            defer display.gpa.free(pts);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const p = r.points.at(i);
                pts[i] = .{ .x = p.x, .y = p.y };
            }
            display.polyPoint(r.drawable, r.gc, r.coordinate_mode, pts) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .poly_line => |r| {
            const n = r.points.len();
            const pts = try display.gpa.alloc(x11.render.Point, n);
            defer display.gpa.free(pts);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const p = r.points.at(i);
                pts[i] = .{ .x = p.x, .y = p.y };
            }
            display.polyLine(r.drawable, r.gc, r.coordinate_mode, pts) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .poly_segment => |r| {
            const n = r.segments.len();
            const flat = try display.gpa.alloc(x11.render.Point, n * 2);
            defer display.gpa.free(flat);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const s = r.segments.at(i);
                flat[i * 2] = .{ .x = s.x1, .y = s.y1 };
                flat[i * 2 + 1] = .{ .x = s.x2, .y = s.y2 };
            }
            display.polySegment(r.drawable, r.gc, flat) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
            };
        },
        .poly_rectangle => |r| {
            const n = r.rectangles.len();
            const rects = try display.gpa.alloc(x11.render.Rect, n);
            defer display.gpa.free(rects);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const rc = r.rectangles.at(i);
                rects[i] = .{ .x = rc.x, .y = rc.y, .width = rc.width, .height = rc.height };
            }
            display.polyRectangle(r.drawable, r.gc, rects) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
            };
        },
        .poly_arc => |r| {
            const n = r.arcs.len();
            const arcs = try display.gpa.alloc(x11.render.Arc, n);
            defer display.gpa.free(arcs);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const a = r.arcs.at(i);
                arcs[i] = .{ .x = a.x, .y = a.y, .width = a.width, .height = a.height, .angle1 = a.angle1, .angle2 = a.angle2 };
            }
            display.polyArc(r.drawable, r.gc, arcs) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .poly_fill_arc => |r| {
            const n = r.arcs.len();
            const arcs = try display.gpa.alloc(x11.render.Arc, n);
            defer display.gpa.free(arcs);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const a = r.arcs.at(i);
                arcs[i] = .{ .x = a.x, .y = a.y, .width = a.width, .height = a.height, .angle1 = a.angle1, .angle2 = a.angle2 };
            }
            display.polyFillArc(r.drawable, r.gc, arcs) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .fill_poly => |r| {
            const n = r.points.len();
            const pts = try display.gpa.alloc(x11.render.Point, n);
            defer display.gpa.free(pts);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const p = r.points.at(i);
                pts[i] = .{ .x = p.x, .y = p.y };
            }
            display.fillPoly(r.drawable, r.gc, r.coordinate_mode, pts) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .put_image => |r| {
            display.putImage(r.drawable, r.gc, r.format, r.depth, r.width, r.height, r.dst_x, r.dst_y, r.left_pad, r.data) catch |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
            };
        },
        .get_image => |r| {
            if (display.getImage(r.drawable, r.format, r.x, r.y, r.width, r.height, r.plane_mask)) |res| {
                defer display.gpa.free(res.data);
                try xproto.encodeGetImageReply(w, en, seq, .{ .depth = res.depth, .visual = res.visual, .data = res.data });
            } else |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .clear_area => |r| {
            display.clearArea(r.window, r.x, r.y, r.width, r.height, r.exposures) catch |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
            deliverPending(display, mux); // exposures=true may have recorded an Expose
        },
        .copy_area => |r| {
            if (display.copyArea(r.src_drawable, r.dst_drawable, r.gc, r.src_x, r.src_y, r.dst_x, r.dst_y, r.width, r.height)) |ce| {
                if (ce.graphics_exposures) {
                    if (ce.fully_covered) {
                        try display.recordNoExpose(r.dst_drawable, conn.client_id, opcode);
                    } else {
                        try display.recordGraphicsExpose(r.dst_drawable, conn.client_id, opcode, ce.x, ce.y, ce.width, ce.height);
                    }
                }
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.src_drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .create_pixmap => |r| {
            display.createPixmap(r.pid, r.drawable, r.depth, r.width, r.height, conn.client_id) catch |e| switch (e) {
                error.IdInUse => try xproto.encodeIDChoiceError(w, en, seq, .{ .bad_value = r.pid, .minor_opcode = 0, .major_opcode = opcode }),
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.width, .minor_opcode = 0, .major_opcode = opcode }),
                error.TooLarge => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = r.pid, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .free_pixmap => |r| display.freePixmap(r.pixmap) catch try xproto.encodePixmapError(w, en, seq, .{ .bad_value = r.pixmap, .minor_opcode = 0, .major_opcode = opcode }),
        .create_gc => |r| {
            display.createGC(r.cid, r.drawable, deltaFromGC(r.value_list), conn.client_id) catch |e| switch (e) {
                error.IdInUse => try xproto.encodeIDChoiceError(w, en, seq, .{ .bad_value = r.cid, .minor_opcode = 0, .major_opcode = opcode }),
                error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .change_gc => |r| display.changeGC(r.gc, deltaFromGC(r.value_list)) catch try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
        .free_gc => |r| display.freeGC(r.gc) catch try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
        .copy_gc => |r| display.copyGC(r.src_gc, r.dst_gc, r.value_mask) catch try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.src_gc, .minor_opcode = 0, .major_opcode = opcode }),
        .create_colormap => |r| {
            display.createColormap(r.mid, r.window, r.visual, r.alloc, conn.client_id) catch |e| switch (e) {
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.alloc, .minor_opcode = 0, .major_opcode = opcode }),
                error.IdInUse => try xproto.encodeIDChoiceError(w, en, seq, .{ .bad_value = r.mid, .minor_opcode = 0, .major_opcode = opcode }),
                error.NoWindow => try badWindow(w, en, seq, opcode, r.window),
                error.OutOfMemory => return e,
            };
        },
        .free_colormap => |r| display.freeColormap(r.cmap) catch try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
        .alloc_color => |r| {
            if (display.allocColor(r.cmap, r.red, r.green, r.blue)) |c| {
                try xproto.encodeAllocColorReply(w, en, seq, .{ .red = c.red, .green = c.green, .blue = c.blue, .pixel = c.pixel });
            } else |_| try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode });
        },
        .free_colors => |r| display.freeColors(r.cmap) catch try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
        .install_colormap => |r| {
            display.installColormap(r.cmap) catch |e| switch (e) {
                error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .uninstall_colormap => |r| display.uninstallColormap(r.cmap) catch try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
        .list_installed_colormaps => |r| {
            if (display.listInstalledColormaps(r.window)) |cmaps| {
                try xproto.encodeListInstalledColormapsReply(w, en, seq, .{ .cmaps_len = @intCast(cmaps.len), .cmaps = cmaps });
            } else |_| try badWindow(w, en, seq, opcode, r.window);
        },
        .query_colors => |r| {
            display.queryColorsValidate(r.cmap) catch {
                try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode });
                return;
            };
            // r.pixels is bounded by the framed request (the socket layer caps
            // request size), so this alloc is never attacker-unbounded.
            const n = r.pixels.len;
            const buf = try display.gpa.alloc(u8, n * 8);
            defer display.gpa.free(buf);
            // Rgb.encodeElement writes only 6 of the 8 wire bytes per element
            // (2 trailing pad bytes are left untouched); zero the buffer first
            // so no uninitialized heap leaks to the client.
            @memset(buf, 0);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const rgb = display.unpackColor(r.pixels[i]);
                (xproto.Rgb{ .red = rgb.red, .green = rgb.green, .blue = rgb.blue }).encodeElement(buf[i * 8 ..][0..8], en);
            }
            try xproto.encodeQueryColorsReply(w, en, seq, .{ .colors_len = @intCast(n), .colors = .{ .bytes = buf, .count = n, .endian = en } });
        },
        .lookup_color => |r| {
            if (display.lookupColor(r.cmap, r.name)) |lr| {
                try xproto.encodeLookupColorReply(w, en, seq, .{
                    .exact_red = lr.exact.red,
                    .exact_green = lr.exact.green,
                    .exact_blue = lr.exact.blue,
                    .visual_red = lr.visual.red,
                    .visual_green = lr.visual.green,
                    .visual_blue = lr.visual.blue,
                });
            } else |e| switch (e) {
                error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadName => try xproto.encodeNameError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
            }
        },
        .alloc_named_color => |r| {
            if (display.allocNamedColor(r.cmap, r.name)) |ar| {
                try xproto.encodeAllocNamedColorReply(w, en, seq, .{
                    .pixel = ar.pixel,
                    .exact_red = ar.exact.red,
                    .exact_green = ar.exact.green,
                    .exact_blue = ar.exact.blue,
                    .visual_red = ar.visual.red,
                    .visual_green = ar.visual.green,
                    .visual_blue = ar.visual.blue,
                });
            } else |e| switch (e) {
                error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadName => try xproto.encodeNameError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
            }
        },
        .alloc_color_cells => |r| display.allocColorCells(r.cmap) catch |e| switch (e) {
            error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
            error.BadAlloc => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
        },
        .alloc_color_planes => |r| display.allocColorPlanes(r.cmap) catch |e| switch (e) {
            error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
            error.BadAlloc => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
        },
        .store_colors => |r| display.storeColors(r.cmap) catch |e| switch (e) {
            error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
            error.BadAccess => try xproto.encodeAccessError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
        },
        .store_named_color => |r| display.storeNamedColor(r.cmap) catch |e| switch (e) {
            error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.cmap, .minor_opcode = 0, .major_opcode = opcode }),
            error.BadAccess => try xproto.encodeAccessError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
        },
        .copy_colormap_and_free => |r| {
            display.copyColormapAndFree(r.mid, r.src_cmap, conn.client_id) catch |e| switch (e) {
                error.BadColor => try xproto.encodeColormapError(w, en, seq, .{ .bad_value = r.src_cmap, .minor_opcode = 0, .major_opcode = opcode }),
                error.IdInUse => try xproto.encodeIDChoiceError(w, en, seq, .{ .bad_value = r.mid, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            };
        },
        .get_window_attributes => |r| {
            if (display.getAttributes(r.window, conn.client_id)) |a| {
                try xproto.encodeGetWindowAttributesReply(w, en, seq, .{
                    .backing_store = a.attrs.backing_store,
                    .visual = a.visual,
                    .class = a.class,
                    .bit_gravity = a.attrs.bit_gravity,
                    .win_gravity = a.attrs.win_gravity,
                    .backing_planes = a.attrs.backing_planes,
                    .backing_pixel = a.attrs.backing_pixel,
                    .save_under = a.attrs.save_under,
                    .map_is_installed = (a.map_state == .viewable),
                    .map_state = @intFromEnum(a.map_state),
                    .override_redirect = a.attrs.override_redirect,
                    .colormap = a.attrs.colormap,
                    .all_event_masks = a.all_event_masks,
                    .your_event_mask = a.your_event_mask,
                    .do_not_propagate_mask = @intCast(a.attrs.do_not_propagate_mask & 0xffff),
                });
            } else |_| try badWindow(w, en, seq, opcode, r.window);
        },
        .query_tree => |r| {
            if (display.queryTree(r.window)) |t| {
                // children_len is a u16 wire field; a client could create
                // more than 65535 children of one window, so cap rather than
                // @intCast (which would panic-crash the server on overflow).
                // The encoder derives the actual list byte length from
                // r.children.len, so capping only the count stays consistent.
                const child_count: u16 = std.math.cast(u16, t.children.len) orelse std.math.maxInt(u16);
                try xproto.encodeQueryTreeReply(w, en, seq, .{ .root = t.root, .parent = t.parent, .children_len = child_count, .children = t.children });
            } else |_| try badWindow(w, en, seq, opcode, r.window);
        },
        .query_pointer => |r| {
            if (display.queryPointer(r.window)) |p| {
                try xproto.encodeQueryPointerReply(w, en, seq, .{ .same_screen = true, .root = p.root, .child = p.child, .root_x = p.root_x, .root_y = p.root_y, .win_x = p.win_x, .win_y = p.win_y, .mask = p.mask });
            } else |_| try badWindow(w, en, seq, opcode, r.window);
        },
        .translate_coordinates => |r| {
            if (display.translateCoordinates(r.src_window, r.dst_window, r.src_x, r.src_y)) |t| {
                try xproto.encodeTranslateCoordinatesReply(w, en, seq, .{ .same_screen = true, .child = t.child, .dst_x = t.dst_x, .dst_y = t.dst_y });
            } else |_| try badWindow(w, en, seq, opcode, r.src_window);
        },
        .send_event => |r| {
            if (r.event.len < 32) {
                // The wire event field is fixed at 32 bytes; anything shorter is malformed.
                try xproto.encodeValueError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode });
            } else if (display.sendEventTargets(r.destination, r.propagate, r.event_mask)) |targets| {
                defer display.gpa.free(targets);
                // Relay the client's 32-byte event verbatim, but set the SendEvent
                // bit so recipients can tell it is synthetic. We deliberately
                // relay as-is: a conforming server would restamp the recipient's
                // sequence number and byte-swap the event into the recipient's
                // endianness, but that rewrite is deferred (fine same-endian).
                var buf: [32]u8 = r.event[0..32].*;
                buf[0] |= 0x80;
                for (targets) |cid| {
                    if (mux.clientById(cid)) |tc| {
                        tc.outWriter().writeAll(&buf) catch mux.disconnect(tc);
                    }
                }
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.destination),
                error.OutOfMemory => return e,
            }
        },
        .get_input_focus => try xproto.encodeGetInputFocusReply(w, en, seq, .{ .revert_to = display.focus_revert, .focus = display.focus }),
        .get_keyboard_mapping => |r| {
            if (display.keyboardMapping(r.first_keycode, r.count)) |m| {
                try xproto.encodeGetKeyboardMappingReply(w, en, seq, .{ .keysyms_per_keycode = m.per, .keysyms = m.syms });
            } else |e| switch (e) {
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.first_keycode, .minor_opcode = 0, .major_opcode = opcode }),
            }
        },
        .get_modifier_mapping => {
            const m = display.modifierMapping();
            try xproto.encodeGetModifierMappingReply(w, en, seq, .{ .keycodes_per_modifier = m.per, .keycodes = m.codes });
        },
        .set_modifier_mapping => |r| {
            if (display.setModifierMapping(r.keycodes_per_modifier, r.keycodes)) |status| {
                try xproto.encodeSetModifierMappingReply(w, en, seq, .{ .status = status });
            } else |e| switch (e) {
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
            }
        },
        .get_pointer_mapping => {
            const m = display.getPointerMapping();
            try xproto.encodeGetPointerMappingReply(w, en, seq, .{ .map_len = @intCast(m.len), .map = m });
        },
        .set_pointer_mapping => |r| {
            if (display.setPointerMapping(r.map)) |status| {
                try xproto.encodeSetPointerMappingReply(w, en, seq, .{ .status = status });
            } else |e| switch (e) {
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.map_len, .minor_opcode = 0, .major_opcode = opcode }),
            }
        },
        .bell => |r| {
            // No audio backend: a valid percent is accepted as a no-op (no
            // reply). Out-of-range is the one thing that's actually invalid.
            if (r.percent < -100 or r.percent > 100) {
                try xproto.encodeValueError(w, en, seq, .{ .bad_value = @as(u32, @bitCast(@as(i32, r.percent))), .minor_opcode = 0, .major_opcode = opcode });
            }
        },
        .set_input_focus => |r| {
            if (display.setInputFocus(r.focus, r.revert_to, r.time)) {
                deliverPending(display, mux);
                try maybeInjectKeyDemo(display, mux);
            } else |e| switch (e) {
                error.NoWindow => try badWindow(w, en, seq, opcode, r.focus),
                error.NotViewable => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = r.focus, .minor_opcode = 0, .major_opcode = opcode }),
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.revert_to, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .intern_atom => |r| {
            if (display.atoms.intern(display.gpa, r.name, r.only_if_exists)) |atom| {
                try xproto.encodeInternAtomReply(w, en, seq, .{ .atom = atom });
            } else |e| switch (e) {
                error.TooManyAtoms => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e, // fatal, as elsewhere
            }
        },
        .get_atom_name => |r| {
            if (display.atoms.nameOf(r.atom)) |name| {
                try xproto.encodeGetAtomNameReply(w, en, seq, .{ .name_len = @intCast(name.len), .name = name });
            } else {
                try xproto.encodeAtomError(w, en, seq, .{ .bad_value = r.atom, .minor_opcode = 0, .major_opcode = opcode });
            }
        },
        .change_property => |r| {
            if (display.changeProperty(r.window, r.property, r.type, r.format, r.mode, r.data, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| {
                const bad: u32 = switch (e) {
                    error.NoWindow => r.window,
                    error.BadAtom => r.property,
                    error.BadValue => r.format,
                    else => r.property,
                };
                try propError(w, en, seq, opcode, bad, e);
            }
        },
        .delete_property => |r| {
            if (display.deleteProperty(r.window, r.property, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| try propError(w, en, seq, opcode, if (e == error.NoWindow) r.window else r.property, e);
        },
        .get_property => |r| {
            if (display.getProperty(r.window, r.property, r.type, r.long_offset, r.long_length, r.delete, conn.client_id)) |g| {
                const unit: u32 = if (g.format == 0) 1 else g.format / 8;
                const value_len: u32 = @intCast(g.value.len / unit);
                try xproto.encodeGetPropertyReply(w, en, seq, .{
                    .format = g.format,
                    .type = g.type,
                    .bytes_after = g.bytes_after,
                    .value_len = value_len,
                    .value = g.value,
                });
                deliverPending(display, mux); // a delete may have recorded PropertyNotify
            } else |e| try propError(w, en, seq, opcode, if (e == error.NoWindow) r.window else r.property, e);
        },
        .list_properties => |r| {
            if (display.listProperties(r.window)) |keys| {
                defer display.gpa.free(keys);
                try xproto.encodeListPropertiesReply(w, en, seq, .{ .atoms_len = @intCast(keys.len), .atoms = keys });
            } else |e| try propError(w, en, seq, opcode, r.window, e);
        },
        .rotate_properties => |r| {
            if (display.rotateProperties(r.window, r.atoms, r.delta)) {
                deliverPending(display, mux);
            } else |e| try propError(w, en, seq, opcode, if (e == error.NoWindow) r.window else 0, e);
        },
        .set_selection_owner => |r| {
            if (display.setSelectionOwner(r.selection, r.owner, r.time, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.BadWindow => try badWindow(w, en, seq, opcode, r.owner),
                error.BadAtom => try xproto.encodeAtomError(w, en, seq, .{ .bad_value = r.selection, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .get_selection_owner => |r| {
            if (display.getSelectionOwner(r.selection)) |owner| {
                try xproto.encodeGetSelectionOwnerReply(w, en, seq, .{ .owner = owner });
            } else |e| switch (e) {
                error.BadAtom => try xproto.encodeAtomError(w, en, seq, .{ .bad_value = r.selection, .minor_opcode = 0, .major_opcode = opcode }),
            }
        },
        .convert_selection => |r| {
            if (display.convertSelection(r.requestor, r.selection, r.target, r.property, r.time, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.BadWindow => try badWindow(w, en, seq, opcode, r.requestor),
                error.BadAtom => try xproto.encodeAtomError(w, en, seq, .{ .bad_value = r.selection, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .query_extension => |r| {
            if (x11.server_state.extensionByName(r.name)) |info| {
                try xproto.encodeQueryExtensionReply(w, en, seq, .{ .present = true, .major_opcode = info.major_opcode, .first_event = info.first_event, .first_error = info.first_error });
            } else {
                try xproto.encodeQueryExtensionReply(w, en, seq, .{ .present = false, .major_opcode = 0, .first_event = 0, .first_error = 0 });
            }
        },
        .list_extensions => {
            // HAND-ENCODE: the generated encodeListExtensionsReply only writes
            // the 32-byte header (same generator gap as ListFonts -- variable
            // STR-list bodies aren't emitted). Body is the registry's names as
            // real STR entries (1 length byte + bytes), padded to 4.
            var body_len: usize = 0;
            for (x11.server_state.extensions) |e| body_len += 1 + e.name.len;
            const padded = (body_len + 3) / 4 * 4;
            var hdr: [32]u8 = std.mem.zeroes([32]u8);
            hdr[0] = 1; // reply
            hdr[1] = @intCast(x11.server_state.extensions.len); // names_len
            std.mem.writeInt(u16, hdr[2..4], seq, en);
            std.mem.writeInt(u32, hdr[4..8], @intCast(padded / 4), en);
            try w.writeAll(&hdr);
            for (x11.server_state.extensions) |e| {
                try w.writeAll(&[_]u8{@intCast(e.name.len)});
                try w.writeAll(e.name);
            }
            const pad = padded - body_len;
            if (pad > 0) try w.writeAll(([_]u8{0} ** 4)[0..pad]);
        },
        .open_font => |r| display.openFont(r.fid, r.name, conn.client_id) catch |e| switch (e) {
            error.IdInUse => try xproto.encodeIDChoiceError(w, en, seq, .{ .bad_value = r.fid, .minor_opcode = 0, .major_opcode = opcode }),
            error.BadName => try xproto.encodeNameError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
            error.OutOfMemory => return e,
        },
        .close_font => |r| display.closeFont(r.font) catch try xproto.encodeFontError(w, en, seq, .{ .bad_value = r.font, .minor_opcode = 0, .major_opcode = opcode }),
        .query_font => |r| {
            if (display.queryFont(r.font)) |m| {
                const cw: i16 = m.max_width;
                const ci = xproto.Charinfo{ .left_side_bearing = 0, .right_side_bearing = cw, .character_width = cw, .ascent = m.ascent, .descent = m.descent, .attributes = 0 };
                try xproto.encodeQueryFontReply(w, en, seq, .{
                    .min_bounds = ci,
                    .max_bounds = ci,
                    .min_char_or_byte2 = m.min_char,
                    .max_char_or_byte2 = m.max_char,
                    .default_char = m.default_char,
                    .properties_len = 0,
                    .draw_direction = 0,
                    .min_byte1 = 0,
                    .max_byte1 = 0,
                    .all_chars_exist = true,
                    .font_ascent = m.ascent,
                    .font_descent = m.descent,
                    .char_infos_len = 0,
                    .properties = .{},
                    .char_infos = .{},
                });
            } else |_| try xproto.encodeFontError(w, en, seq, .{ .bad_value = r.font, .minor_opcode = 0, .major_opcode = opcode });
        },
        .list_fonts => |r| {
            // HAND-ENCODE: the generated encodeListFontsReply only writes the
            // 32-byte header (a generator gap -- variable-size STR list bodies
            // aren't emitted). Return the provider's names (via the FontProvider
            // seam so an injected provider's names show up here too), capped
            // at max_names, as real STR entries (len byte + bytes), padded to
            // a 4-byte boundary like every other reply body.
            const names = display.listFonts(r.pattern);
            const cap: usize = if (r.max_names == 0) 0 else r.max_names;
            // A STR length is a single byte, so a name longer than 255 bytes is
            // unencodable; skip it (truncating would corrupt the wire framing).
            // With the default provider ("fixed") this never trips, but an
            // injected provider could return arbitrary names.
            var count: usize = 0;
            var body_len: usize = 0;
            for (names) |nm| {
                if (count >= cap) break;
                if (nm.len > 255) continue;
                count += 1;
                body_len += 1 + nm.len;
            }
            const padded = (body_len + 3) / 4 * 4;
            var hdr: [32]u8 = std.mem.zeroes([32]u8);
            hdr[0] = 1; // reply
            std.mem.writeInt(u16, hdr[2..4], seq, en);
            std.mem.writeInt(u32, hdr[4..8], @intCast(padded / 4), en);
            std.mem.writeInt(u16, hdr[8..10], @intCast(count), en);
            try w.writeAll(&hdr);
            var written: usize = 0;
            for (names) |nm| {
                if (written >= count) break;
                if (nm.len > 255) continue;
                try w.writeAll(&[_]u8{@intCast(nm.len)});
                try w.writeAll(nm);
                written += 1;
            }
            const pad = padded - body_len;
            if (pad > 0) try w.writeAll(([_]u8{0} ** 4)[0..pad]);
        },
        .image_text8 => |r| display.imageText8(r.drawable, r.gc, r.x, r.y, r.string) catch |e| switch (e) {
            error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
            error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
        },
        .poly_text8 => |r| display.polyText8(r.drawable, r.gc, r.x, r.y, r.items) catch |e| switch (e) {
            error.NoDrawable => try xproto.encodeDrawableError(w, en, seq, .{ .bad_value = r.drawable, .minor_opcode = 0, .major_opcode = opcode }),
            error.NotGC => try xproto.encodeGContextError(w, en, seq, .{ .bad_value = r.gc, .minor_opcode = 0, .major_opcode = opcode }),
        },
        .grab_pointer => |r| {
            const status = display.grabPointer(r.grab_window, r.event_mask, r.owner_events, r.pointer_mode, r.keyboard_mode, conn.client_id);
            try xproto.encodeGrabPointerReply(w, en, seq, .{ .status = status });
            try maybeInjectGrabDemo(display, mux);
        },
        .ungrab_pointer => display.ungrabPointer(conn.client_id),
        .grab_keyboard => |r| {
            const status = display.grabKeyboard(r.grab_window, r.owner_events, r.pointer_mode, r.keyboard_mode, conn.client_id);
            try xproto.encodeGrabKeyboardReply(w, en, seq, .{ .status = status });
        },
        .ungrab_keyboard => display.ungrabKeyboard(conn.client_id),
        .grab_button => |r| {
            if (display.grabButton(r.grab_window, r.event_mask, r.owner_events, r.button, r.modifiers, r.pointer_mode, r.keyboard_mode, conn.client_id)) {
                passive_button_grab_seen = true;
                try maybeInjectPassiveDemo(display, mux);
            } else |e| switch (e) {
                error.Access => try xproto.encodeAccessError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .ungrab_button => |r| display.ungrabButton(r.button, r.grab_window, r.modifiers, conn.client_id),
        .grab_key => |r| {
            if (display.grabKey(r.grab_window, r.owner_events, r.key, r.modifiers, r.pointer_mode, r.keyboard_mode, conn.client_id)) {
                passive_key_grab_seen = true;
                try maybeInjectPassiveDemo(display, mux);
            } else |e| switch (e) {
                error.Access => try xproto.encodeAccessError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .ungrab_key => |r| display.ungrabKey(r.key, r.grab_window, r.modifiers, conn.client_id),
        .allow_events => |r| {
            if (display.allowEvents(r.mode, conn.client_id)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.mode, .minor_opcode = 0, .major_opcode = opcode }),
                error.OutOfMemory => return e,
            }
        },
        .change_active_pointer_grab => |r| display.changeActivePointerGrab(r.event_mask, conn.client_id), // no reply, no events
        .grab_server => mux.setServerGrab(conn.client_id),
        .ungrab_server => mux.clearServerGrab(conn.client_id),
        .set_close_down_mode => |r| {
            if (r.mode > 2) {
                try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.mode, .minor_opcode = 0, .major_opcode = opcode });
            } else {
                conn.close_down_mode = r.mode;
            }
        },
        .kill_client => |r| {
            if (r.resource == 0) {
                // AllTemporary: sweep every RetainTemporary-retained client.
                try display.killTemporary();
                deliverPending(display, mux);
            } else if (display.ownerOf(r.resource)) |owner| {
                if (mux.clientById(owner)) |c| {
                    // A LIVE client: force-disconnect it. Per X, a KillClient'd
                    // client and its resources are destroyed REGARDLESS of the
                    // client's close-down mode (Retain only applies when a client
                    // closes its OWN connection), so force DestroyAll here before
                    // the .disconnected teardown runs on the next next() call.
                    c.close_down_mode = 0;
                    mux.disconnect(c);
                } else {
                    // A RETAINED (already-disconnected) client: destroy its
                    // kept-alive resources now.
                    try display.destroyClientResources(owner);
                    deliverPending(display, mux);
                }
            } else {
                // Neither AllTemporary(0) nor a resource id this server knows: BadValue.
                try xproto.encodeValueError(w, en, seq, .{ .bad_value = r.resource, .minor_opcode = 0, .major_opcode = opcode });
            }
        },
        else => {
            // A reply-bearing request we do not implement must not hang the
            // client's awaitReply; answer with BadImplementation (17).
            if (xproto.requestHasReply(opcode)) {
                try xproto.encodeImplementationError(w, en, seq, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = opcode });
            }
        },
    }
}

/// Encode one recorded event into `w` with the RECEIVING client's endian + seq.
fn encodeEvent(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, ev: x11.server_state.PendingEvent) error{WriteFailed}!void {
    switch (ev.kind) {
        .create => try xproto.encodeCreateNotifyEvent(w, en, seq, .{
            .parent = ev.parent,
            .window = ev.window,
            .x = ev.x,
            .y = ev.y,
            .width = ev.width,
            .height = ev.height,
            .border_width = ev.border_width,
            .override_redirect = ev.override_redirect,
        }),
        .destroy => try xproto.encodeDestroyNotifyEvent(w, en, seq, .{ .event = ev.event_window, .window = ev.window }),
        .map => try xproto.encodeMapNotifyEvent(w, en, seq, .{ .event = ev.event_window, .window = ev.window, .override_redirect = ev.override_redirect }),
        .unmap => try xproto.encodeUnmapNotifyEvent(w, en, seq, .{ .event = ev.event_window, .window = ev.window, .from_configure = false }),
        .property => try xproto.encodePropertyNotifyEvent(w, en, seq, .{
            .window = ev.window,
            .atom = ev.atom,
            .time = ev.time,
            .state = ev.state,
        }),
        .configure => try xproto.encodeConfigureNotifyEvent(w, en, seq, .{
            .event = ev.event_window,
            .window = ev.window,
            .above_sibling = ev.above_sibling,
            .x = ev.x,
            .y = ev.y,
            .width = ev.width,
            .height = ev.height,
            .border_width = ev.border_width,
            .override_redirect = ev.override_redirect,
        }),
        .motion => try xproto.encodeMotionNotifyEvent(w, en, seq, .{
            .detail = ev.detail,
            .time = ev.time,
            .root = ev.root,
            .event = ev.event_window,
            .child = ev.child,
            .root_x = ev.root_x,
            .root_y = ev.root_y,
            .event_x = ev.event_x,
            .event_y = ev.event_y,
            .state = ev.input_state,
            .same_screen = true,
        }),
        .button_press => try xproto.encodeButtonPressEvent(w, en, seq, .{
            .detail = ev.detail,
            .time = ev.time,
            .root = ev.root,
            .event = ev.event_window,
            .child = ev.child,
            .root_x = ev.root_x,
            .root_y = ev.root_y,
            .event_x = ev.event_x,
            .event_y = ev.event_y,
            .state = ev.input_state,
            .same_screen = true,
        }),
        .button_release => try xproto.encodeButtonReleaseEvent(w, en, seq, .{
            .detail = ev.detail,
            .time = ev.time,
            .root = ev.root,
            .event = ev.event_window,
            .child = ev.child,
            .root_x = ev.root_x,
            .root_y = ev.root_y,
            .event_x = ev.event_x,
            .event_y = ev.event_y,
            .state = ev.input_state,
            .same_screen = true,
        }),
        .key_press => try xproto.encodeKeyPressEvent(w, en, seq, .{
            .detail = ev.detail,
            .time = ev.time,
            .root = ev.root,
            .event = ev.event_window,
            .child = ev.child,
            .root_x = ev.root_x,
            .root_y = ev.root_y,
            .event_x = ev.event_x,
            .event_y = ev.event_y,
            .state = ev.input_state,
            .same_screen = true,
        }),
        .key_release => try xproto.encodeKeyReleaseEvent(w, en, seq, .{
            .detail = ev.detail,
            .time = ev.time,
            .root = ev.root,
            .event = ev.event_window,
            .child = ev.child,
            .root_x = ev.root_x,
            .root_y = ev.root_y,
            .event_x = ev.event_x,
            .event_y = ev.event_y,
            .state = ev.input_state,
            .same_screen = true,
        }),
        .enter => try xproto.encodeEnterNotifyEvent(w, en, seq, .{
            .detail = ev.detail,
            .time = ev.time,
            .root = ev.root,
            .event = ev.event_window,
            .child = ev.child,
            .root_x = ev.root_x,
            .root_y = ev.root_y,
            .event_x = ev.event_x,
            .event_y = ev.event_y,
            .state = ev.input_state,
            .mode = ev.mode,
            .same_screen_focus = 2, // same_screen set, focus clear
        }),
        .leave => try xproto.encodeLeaveNotifyEvent(w, en, seq, .{
            .detail = ev.detail,
            .time = ev.time,
            .root = ev.root,
            .event = ev.event_window,
            .child = ev.child,
            .root_x = ev.root_x,
            .root_y = ev.root_y,
            .event_x = ev.event_x,
            .event_y = ev.event_y,
            .state = ev.input_state,
            .mode = ev.mode,
            .same_screen_focus = 2,
        }),
        .focus_in => try xproto.encodeFocusInEvent(w, en, seq, .{ .detail = ev.detail, .event = ev.event_window, .mode = ev.mode }),
        .focus_out => try xproto.encodeFocusOutEvent(w, en, seq, .{ .detail = ev.detail, .event = ev.event_window, .mode = ev.mode }),
        .expose => try xproto.encodeExposeEvent(w, en, seq, .{
            .window = ev.window,
            .x = @intCast(ev.x),
            .y = @intCast(ev.y),
            .width = ev.width,
            .height = ev.height,
            .count = ev.count,
        }),
        .graphics_expose => try xproto.encodeGraphicsExposureEvent(w, en, seq, .{
            .drawable = ev.window,
            .x = @intCast(ev.x),
            .y = @intCast(ev.y),
            .width = ev.width,
            .height = ev.height,
            .minor_opcode = 0,
            .count = ev.count,
            .major_opcode = ev.major_opcode,
        }),
        .no_expose => try xproto.encodeNoExposureEvent(w, en, seq, .{ .drawable = ev.window, .minor_opcode = 0, .major_opcode = ev.major_opcode }),
        .map_request => try xproto.encodeMapRequestEvent(w, en, seq, .{ .parent = ev.parent, .window = ev.window }),
        .configure_request => try xproto.encodeConfigureRequestEvent(w, en, seq, .{
            .stack_mode = ev.detail,
            .parent = ev.parent,
            .window = ev.window,
            .sibling = ev.above_sibling,
            .x = ev.x,
            .y = ev.y,
            .width = ev.width,
            .height = ev.height,
            .border_width = ev.border_width,
            .value_mask = ev.value_mask,
        }),
        .reparent => try xproto.encodeReparentNotifyEvent(w, en, seq, .{ .event = ev.event_window, .window = ev.window, .parent = ev.parent, .x = ev.x, .y = ev.y, .override_redirect = ev.override_redirect }),
        .circulate => try xproto.encodeCirculateNotifyEvent(w, en, seq, .{ .event = ev.event_window, .window = ev.window, .place = ev.detail }),
        .circulate_request => try xproto.encodeCirculateRequestEvent(w, en, seq, .{ .event = ev.event_window, .window = ev.window, .place = ev.detail }),
        .selection_clear => try xproto.encodeSelectionClearEvent(w, en, seq, .{ .time = ev.time, .owner = ev.event_window, .selection = ev.atom }),
        .selection_request => try xproto.encodeSelectionRequestEvent(w, en, seq, .{ .time = ev.time, .owner = ev.event_window, .requestor = ev.window, .selection = ev.atom, .target = ev.target_atom, .property = ev.property_atom }),
        .selection_notify => try xproto.encodeSelectionNotifyEvent(w, en, seq, .{ .time = ev.time, .requestor = ev.event_window, .selection = ev.atom, .target = ev.target_atom, .property = ev.property_atom }),
        .randr_screen_change => try x11.randr.encodeScreenChangeEvent(
            w,
            en,
            seq,
            ev.randr.rotation,
            ev.time,
            ev.randr.config_timestamp,
            ev.root,
            ev.randr.request_window,
            ev.randr.size_id,
            ev.randr.subpixel,
            ev.width,
            ev.height,
            ev.randr.mwidth,
            ev.randr.mheight,
        ),
        .randr_crtc_change => try x11.randr.encodeCrtcChangeEvent(
            w,
            en,
            seq,
            ev.time,
            ev.window,
            ev.randr.crtc,
            ev.randr.mode,
            ev.randr.rotation,
            ev.x,
            ev.y,
            ev.width,
            ev.height,
        ),
        .randr_output_property => try x11.randr.encodeOutputPropertyEvent(
            w,
            en,
            seq,
            ev.window, // the window the client SelectInput'd RANDR events on (root)
            ev.randr.output,
            ev.randr.atom,
            ev.time,
            ev.randr.state,
        ),
    }
}

/// Fan out every recorded event to the client that selected it: resolve
/// target_client -> connection, encode into THAT connection's queue with its own
/// endian + sequence number (an X11 event carries the seq of the last request the
/// server processed from the receiving client). A target that has since
/// disconnected is skipped; a queue-encode failure disconnects only that target.
fn deliverPending(display: *x11.Display, mux: *x11.Multiplexer) void {
    for (display.pending.items) |ev| {
        const tc = mux.clientById(ev.target_client) orelse continue;
        encodeEvent(tc.outWriter(), tc.client_endian, tc.seq, ev) catch {
            mux.disconnect(tc);
            continue;
        };
    }
    display.clearPending();
}

/// Answer a window-resource request that named a nonexistent window with a
/// real BadWindow (code 3) error, carrying the offending id and request
/// opcode.
fn badWindow(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, opcode: u8, id: u32) !void {
    try xproto.encodeWindowError(w, en, seq, .{ .bad_value = id, .minor_opcode = 0, .major_opcode = opcode });
}

/// Cap on XC-MISC GetXIDList's client-requested id count. The request names
/// an untrusted CARD32 count with no protocol-level upper bound; without a
/// cap a client could ask for ~4 billion ids and force an equally huge reply
/// body. 4096 ids (16KB of reply) is far more than any real client asks for
/// in one call (Xlib top-ups are in the low thousands at most).
const xid_list_cap: u32 = 4096;

/// Answer an extension request this server does not implement (an unknown
/// major opcode, or an unknown minor within a known extension) with a real
/// BadRequest (error code 1), carrying the request's minor/major opcode.
fn badRequest(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, opcode: u8, minor: u8) !void {
    try xproto.encodeRequestError(w, en, seq, .{ .bad_value = 0, .minor_opcode = minor, .major_opcode = opcode });
}

/// Decode and answer ONE extension request (major opcode `opcode` >=128).
/// Extension requests are never core xproto (the generator only emits
/// xproto+xkb), so unlike the core dispatch above, this hand-decodes the
/// body itself. Only the two extensions this server registers
/// (server_state.extensions: BIG-REQUESTS major 128, XC-MISC major 129) are
/// handled; any other major, or a minor this server does not implement
/// within a known extension, gets a BadRequest.
fn handleExtensionRequest(conn: *x11.ServerConn, opcode: u8, bytes: []const u8, display: *x11.Display, seq: u16, mux: *x11.Multiplexer) !void {
    const en = conn.client_endian;
    const w = conn.outWriter();
    // Every extension request here is at least a 4-byte core header (major,
    // minor, length); a shorter buffer can't even carry a minor opcode.
    const minor: u8 = if (bytes.len > 1) bytes[1] else 0;
    switch (opcode) {
        129 => switch (minor) { // XC-MISC
            0 => { // GetVersion: no request body; reply server 1.1 (this server's fixed version).
                var buf: [32]u8 = std.mem.zeroes([32]u8);
                buf[0] = 1;
                std.mem.writeInt(u16, buf[2..4], seq, en);
                std.mem.writeInt(u32, buf[4..8], 0, en);
                std.mem.writeInt(u16, buf[8..10], 1, en); // server_major_version
                std.mem.writeInt(u16, buf[10..12], 1, en); // server_minor_version
                try w.writeAll(&buf);
            },
            1 => { // GetXIDRange: no request body; top up the caller with a fresh block of ids.
                const r = display.allocXidRange(0x10000);
                var buf: [32]u8 = std.mem.zeroes([32]u8);
                buf[0] = 1;
                std.mem.writeInt(u16, buf[2..4], seq, en);
                std.mem.writeInt(u32, buf[4..8], 0, en);
                std.mem.writeInt(u32, buf[8..12], r.start, en);
                std.mem.writeInt(u32, buf[12..16], r.count, en);
                try w.writeAll(&buf);
            },
            2 => { // GetXIDList: request body is {count: CARD32} at bytes[4..8].
                if (bytes.len < 8) {
                    try badRequest(w, en, seq, opcode, minor);
                    return;
                }
                const requested = std.mem.readInt(u32, bytes[4..8], en);
                // Bound the untrusted client-named count before it drives an
                // allocation or a reply body (see xid_list_cap's doc comment).
                const n = @min(requested, xid_list_cap);
                const r = display.allocXidRange(n);
                var hdr: [32]u8 = std.mem.zeroes([32]u8);
                hdr[0] = 1;
                std.mem.writeInt(u16, hdr[2..4], seq, en);
                std.mem.writeInt(u32, hdr[4..8], n, en); // length: n CARD32 ids == n 4-byte units
                std.mem.writeInt(u32, hdr[8..12], n, en); // ids_len
                try w.writeAll(&hdr);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    var idbuf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &idbuf, r.start + i, en);
                    try w.writeAll(&idbuf);
                }
            },
            else => try badRequest(w, en, seq, opcode, minor),
        },
        128 => switch (minor) { // BIG-REQUESTS
            0 => { // BigReqEnable: no request body; opt this conn into extended framing.
                conn.big_requests_enabled = true;
                // maximum_request_length is in 4-byte units, same unit as the
                // core setup's max_request_length -- but this is the heap
                // buffer's real extended ceiling (x11.server_loop.max_request_bytes,
                // 4MiB), always greater than the setup-advertised 65535 units
                // per the BIG-REQUESTS spec ("will always be greater than the
                // maximum-request-length returned in the connection setup").
                const max_units: u32 = @intCast(x11.server_loop.max_request_bytes / 4);
                var buf: [32]u8 = std.mem.zeroes([32]u8);
                buf[0] = 1;
                std.mem.writeInt(u16, buf[2..4], seq, en);
                std.mem.writeInt(u32, buf[4..8], 0, en);
                std.mem.writeInt(u32, buf[8..12], max_units, en); // maximum_request_length
                try w.writeAll(&buf);
            },
            else => try badRequest(w, en, seq, opcode, minor),
        },
        130 => try handleRandr(conn, minor, bytes, display, seq, mux), // RANDR
        else => try badRequest(w, en, seq, opcode, minor),
    }
}

/// Decode and answer ONE RANDR request (major 130, server_state.extensions).
/// Task 1 covers the requests with no structured list body -- QueryVersion
/// (0), GetScreenSizeRange (6), GetOutputPrimary (31), SelectInput (4, no
/// reply). Task 2 adds the structured list replies: GetScreenResources[Current]
/// (8/25), GetOutputInfo (9, BadOutput on a mismatched output id), GetCrtcInfo
/// (20, BadCrtc on a mismatched crtc id), GetScreenInfo (5). Any other minor
/// this server does not implement gets BadRequest, same as an unknown minor
/// within any other extension.
///
/// Dynamic-RANDR Task 1: GetScreenResources/GetOutputInfo/GetScreenInfo now
/// report `Display.randrModeList()`'s full mode set (the live current mode +
/// the fixed alt modes, `server_state.randr_mode_count` entries total) rather
/// than a single mode -- see randr.zig's `ModeEntry`/`SizeEntry`. GetCrtcInfo
/// is unchanged: a CRTC always reports just the one current-mode id it's
/// driving.
///
/// Dynamic-RANDR Task 3: SetScreenSize (7)/SetCrtcConfig (21)/SetScreenConfig
/// (2)/SetOutputPrimary (30) actually mutate the screen -- resizing the root
/// (`Display.resizeRoot`/`setCrtcMode`/`setScreenConfigSize`) and emitting the
/// core ConfigureNotify + RANDR ScreenChangeNotify/RRNotify-CrtcChange events
/// Task 2 wired up. `mux` is needed here (unlike every minor above) so a
/// resize's recorded events can be flushed to selecting clients before this
/// request's own reply/no-reply returns.
///
/// RANDR-deferred Task 2 (client-defined modes): CreateMode (16)/DestroyMode
/// (17)/AddOutputMode (18)/DeleteOutputMode (19) let a client grow/shrink the
/// mode table `Display.createMode`/`destroyMode` maintain
/// (`randr_created_modes`); GetScreenResources/GetOutputInfo/GetScreenInfo
/// above now report those alongside the built-in modes (`randrModeList`'s
/// buffer is sized to `server_state.max_mode_count` since the count is
/// runtime-variable once CreateMode can grow it). AddOutputMode/
/// DeleteOutputMode are no-ops beyond validation -- this single-output config
/// already lists every mode it knows about against its one output.
fn handleRandr(conn: *x11.ServerConn, minor: u8, bytes: []const u8, display: *x11.Display, seq: u16, mux: *x11.Multiplexer) !void {
    const en = conn.client_endian;
    const w = conn.outWriter();
    switch (minor) {
        0 => try x11.randr.encodeQueryVersion(w, en, seq), // QueryVersion: request carries client major/minor, unused (see randr.zig).
        6 => try x11.randr.encodeGetScreenSizeRange(w, en, seq), // GetScreenSizeRange
        31 => try x11.randr.encodeGetOutputPrimary(w, en, seq, display.randr.output), // GetOutputPrimary
        4 => { // SelectInput: request window@[4..8], enable(CARD16)@[8..10]; no reply.
            if (bytes.len < 10) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const window = std.mem.readInt(u32, bytes[4..8], en);
            const enable = std.mem.readInt(u16, bytes[8..10], en);
            try display.randrSelectInput(conn.client_id, window, enable);
        },
        8, 25 => { // GetScreenResources (8) / GetScreenResourcesCurrent (25): same reply, always "current".
            // Every mode this server ever reports: index 0 is the live current
            // mode, then the fixed alt modes, then every client-created mode
            // (Display.randrModeList's contract). Buffers sized to
            // max_mode_count (a fixed comptime upper bound -- randr_created_modes
            // is capped there) since the real count is runtime-variable now
            // that CreateMode can grow it.
            var mode_buf: [x11.server_state.max_mode_count]x11.server_state.RandrMode = undefined;
            const mode_list = display.randrModeList(&mode_buf);
            var name_buf: [x11.server_state.max_mode_count * 16]u8 = undefined; // "65535x65535" (11B) worst case per mode, w/ margin
            var modes: [x11.server_state.max_mode_count]x11.randr.ModeEntry = undefined;
            var off: usize = 0;
            for (mode_list, 0..) |m, i| {
                const name = std.fmt.bufPrint(name_buf[off..], "{d}x{d}", .{ m.width, m.height }) catch unreachable;
                modes[i] = .{ .id = m.id, .width = m.width, .height = m.height, .name = name };
                off += name.len;
            }
            try x11.randr.encodeGetScreenResources(w, en, seq, display.randr, modes[0..mode_list.len]);
        },
        9 => { // GetOutputInfo: request output@[4..8]; BadOutput if it doesn't match this config's single output.
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            if (output != display.randr.output) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_output, output, minor);
                return;
            }
            const size = display.randrScreenSize();
            const mm_width = x11.Display.randrMm(size.w);
            const mm_height = x11.Display.randrMm(size.h);
            var mode_buf: [x11.server_state.max_mode_count]x11.server_state.RandrMode = undefined;
            const mode_list = display.randrModeList(&mode_buf);
            var mode_ids: [x11.server_state.max_mode_count]u32 = undefined;
            for (mode_list, 0..) |m, i| mode_ids[i] = m.id;
            try x11.randr.encodeGetOutputInfo(w, en, seq, display.randr, mm_width, mm_height, mode_ids[0..mode_list.len]);
        },
        20 => { // GetCrtcInfo: request crtc@[4..8]; BadCrtc if it doesn't match this config's single crtc.
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            const size = display.randrScreenSize();
            try x11.randr.encodeGetCrtcInfo(w, en, seq, display.randr, size.w, size.h);
        },
        16 => { // CreateMode: request window@[4..8] (unused -- single-output config, no per-window mode registry); ModeInfo@[8..40] (id@[8..12] client-supplied and ignored -- this server always mints its own id via Display.createMode; width@[12..14]; height@[14..16]; the rest of ModeInfo -- dot_clock/hsync*/vsync*/mode_flags -- is untrusted timing data this synthetic mode table never uses); name(char list)@[40..][0..name_len], name_len CARD16@[34..36] (ModeInfo's own nameLength field) -- read only to bound the request length, the name itself is never stored (RandrMode carries no name, see encodeGetScreenResources's caller-built names); reply the newly minted mode id.
            if (bytes.len < 40) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const width = std.mem.readInt(u16, bytes[12..14], en);
            const height = std.mem.readInt(u16, bytes[14..16], en);
            const name_len = std.mem.readInt(u16, bytes[34..36], en);
            // Bound the declared name length against what the request
            // actually carries BEFORE trusting it for anything -- a hostile
            // client can claim any name_len while sending a short body.
            if (bytes.len < 40 + @as(usize, name_len)) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const mode_id = try display.createMode(width, height);
            try x11.randr.encodeCreateModeReply(w, en, seq, mode_id);
        },
        17 => { // DestroyMode: request mode@[4..8]; BadMode if `mode` isn't a client-created mode (the current/alt modes can't be destroyed); NO reply.
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const mode = std.mem.readInt(u32, bytes[4..8], en);
            display.destroyMode(mode) catch |e| switch (e) {
                error.BadMode => try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_mode, mode, minor),
            };
        },
        18, 19 => { // AddOutputMode (18) / DeleteOutputMode (19): request output@[4..8], mode@[8..12]; BadOutput/BadMode on an unknown id, else accept as a no-op -- this single output already lists every mode this server reports (randrModeList), so there's no separate per-output mode subset to actually add/remove from.
            if (bytes.len < 12) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            const mode = std.mem.readInt(u32, bytes[8..12], en);
            if (output != display.randr.output) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_output, output, minor);
                return;
            }
            if (display.randrModeById(mode) == null) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_mode, mode, minor);
                return;
            }
        },
        5 => { // GetScreenInfo: minimal RANDR 1.0 path (see randr.zig), one ScreenSize per reported mode.
            var mode_buf: [x11.server_state.max_mode_count]x11.server_state.RandrMode = undefined;
            const mode_list = display.randrModeList(&mode_buf);
            var sizes: [x11.server_state.max_mode_count]x11.randr.SizeEntry = undefined;
            for (mode_list, 0..) |m, i| sizes[i] = .{
                .width = m.width,
                .height = m.height,
                .mm_width = x11.Display.randrMm(m.width),
                .mm_height = x11.Display.randrMm(m.height),
            };
            try x11.randr.encodeGetScreenInfo(w, en, seq, display.root, display.randr, sizes[0..mode_list.len]);
        },
        7 => { // SetScreenSize: request window@[4..8], width@[8..10], height@[10..12], mm_width@[12..16], mm_height@[16..20]; no reply.
            if (bytes.len < 20) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const window = std.mem.readInt(u32, bytes[4..8], en);
            const width = std.mem.readInt(u16, bytes[8..10], en);
            const height = std.mem.readInt(u16, bytes[10..12], en);
            const mm_width = std.mem.readInt(u32, bytes[12..16], en);
            const mm_height = std.mem.readInt(u32, bytes[16..20], en);
            // mm_width/mm_height are CARD32 on the wire but only ever feed
            // ScreenChangeNotify's CARD16 mwidth/mheight fields -- truncate
            // the untrusted value rather than reject the request (an
            // out-of-u16-range physical size is nonsensical anyway; this
            // just reports it clipped, same spirit as configureWindow's
            // value-list @truncate on untrusted deltas).
            if (display.resizeRoot(width, height, @truncate(mm_width), @truncate(mm_height), window)) {
                deliverPending(display, mux);
            } else |e| switch (e) {
                // Bound against a hostile 16384x16384 request forcing a ~1 GiB
                // allocation, same cap + same BadAlloc convention as
                // configureWindow's resize path.
                error.TooLarge => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = width, .minor_opcode = minor, .major_opcode = 130 }),
                error.NoWindow => return e, // the root always exists; a genuine hit here is fatal-worthy, not a client error
                error.OutOfMemory => return e,
            }
        },
        21 => { // SetCrtcConfig: request crtc@[4..8], mode@[20..24]; BadCrtc on a mismatched crtc, BadMode via setCrtcMode, else Success + the new timestamp.
            if (bytes.len < 24) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            const mode = std.mem.readInt(u32, bytes[20..24], en);
            if (display.setCrtcMode(mode)) {
                try x11.randr.encodeSetCrtcConfigReply(w, en, seq, 0, display.randr.timestamp);
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.BadMode => try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_mode, mode, minor),
                // Inert in practice -- every mode in the fixed table tops out
                // at 1920x1080, well under max_pixmap_bytes -- but resizeRoot's
                // cap is real, so handle it rather than let a silent widening
                // of the mode table someday force an unbounded allocation.
                error.TooLarge => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = mode, .minor_opcode = minor, .major_opcode = 130 }),
                error.NoWindow => return e, // the root always exists; a genuine hit here is fatal-worthy, not a client error
                error.OutOfMemory => return e,
            }
        },
        2 => { // SetScreenConfig: request sizeID@[16..18]; BadValue via setScreenConfigSize, else Success + timestamps/root/subpixel.
            if (bytes.len < 24) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const size_id = std.mem.readInt(u16, bytes[16..18], en);
            if (display.setScreenConfigSize(size_id)) {
                try x11.randr.encodeSetScreenConfigReply(w, en, seq, 0, display.randr.timestamp, display.randr.timestamp, display.root, 0);
                deliverPending(display, mux);
            } else |e| switch (e) {
                error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = size_id, .minor_opcode = minor, .major_opcode = 130 }),
                // Inert in practice (see SetCrtcConfig above) -- kept so the
                // fixed mode table's sizes staying under max_pixmap_bytes is
                // an enforced invariant, not an assumption.
                error.TooLarge => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = size_id, .minor_opcode = minor, .major_opcode = 130 }),
                error.NoWindow => return e,
                error.OutOfMemory => return e,
            }
        },
        30 => { // SetOutputPrimary: request window@[4..8] (unused -- no per-window primary tracked), output@[8..12]; BadOutput on mismatch, else accept silently (no reply, nothing recorded -- this single-output config's primary can never actually change).
            if (bytes.len < 12) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[8..12], en);
            if (output != display.randr.output) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_output, output, minor);
                return;
            }
        },
        22 => { // GetCrtcGammaSize: request crtc@[4..8]; BadCrtc on mismatch, else reply the stored ramp length (256 by default; SetCrtcGamma(24) can shrink it).
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            try x11.randr.encodeGetCrtcGammaSize(w, en, seq, display.gamma_size);
        },
        23 => { // GetCrtcGamma: request crtc@[4..8]; BadCrtc on mismatch, else reply the current ramps (Display.gammaRamps).
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            const g = display.gammaRamps();
            try x11.randr.encodeGetCrtcGamma(w, en, seq, g.size, g.red, g.green, g.blue);
        },
        24 => { // SetCrtcGamma: request crtc@[4..8], size CARD16@[8..10], pad2, then red[size]/green[size]/blue[size] CARD16; BadCrtc on mismatch, BadValue on size>256, a short request body, or size != GetCrtcGammaSize (the ramp length is fixed, Display.setCrtcGamma rejects any other size), else Display.setCrtcGamma; no reply.
            if (bytes.len < 12) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            const size = std.mem.readInt(u16, bytes[8..10], en);
            if (size > 256) {
                // setCrtcGamma would reject this too, but bail before touching
                // the fixed 256-entry decode buffers below (they can't hold
                // more) -- a hostile client controls this CARD16 fully.
                try xproto.encodeValueError(w, en, seq, .{ .bad_value = size, .minor_opcode = minor, .major_opcode = 130 });
                return;
            }
            // Bound the ramp reads against the actual request length BEFORE
            // trusting `size` for anything else -- a hostile client can claim
            // any size while sending a short request body.
            const needed = 12 + @as(usize, size) * 2 * 3;
            if (bytes.len < needed) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            var red: [256]u16 = undefined;
            var green: [256]u16 = undefined;
            var blue: [256]u16 = undefined;
            var off: usize = 12;
            for (0..size) |i| {
                red[i] = std.mem.readInt(u16, bytes[off..][0..2], en);
                off += 2;
            }
            for (0..size) |i| {
                green[i] = std.mem.readInt(u16, bytes[off..][0..2], en);
                off += 2;
            }
            for (0..size) |i| {
                blue[i] = std.mem.readInt(u16, bytes[off..][0..2], en);
                off += 2;
            }
            display.setCrtcGamma(size, red[0..size], green[0..size], blue[0..size]) catch |err| switch (err) {
                // size <= 256 is already bounded above, but setCrtcGamma also
                // rejects any size that doesn't match the fixed gamma_size
                // (256) -- the ramp length is a fixed hardware property, so a
                // smaller `size` here is a client error, not a resize request.
                error.BadValue => {
                    try xproto.encodeValueError(w, en, seq, .{ .bad_value = size, .minor_opcode = minor, .major_opcode = 130 });
                    return;
                },
            };
        },
        42 => { // GetMonitors: request window@[4..8] (unused -- no per-window filtering), get_active BOOL@[8] (unused -- no "pending" monitor state distinct from "active"); reply `display.randr_monitors` (SetMonitor's client-defined list) once non-empty, else the synthetic default (1 MonitorInfo covering the single output at the live screen size).
            if (bytes.len < 9) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            if (display.randr_monitors.items.len == 0) {
                const name_atom = display.atoms.intern(display.gpa, "default", false) catch |e| switch (e) {
                    error.TooManyAtoms => {
                        try xproto.encodeAllocError(w, en, seq, .{ .bad_value = 0, .minor_opcode = minor, .major_opcode = 130 });
                        return;
                    },
                    error.OutOfMemory => return e,
                };
                const size = display.randrScreenSize();
                const mm_width = x11.Display.randrMm(size.w);
                const mm_height = x11.Display.randrMm(size.h);
                const outputs = [_]u32{display.randr.output};
                const monitors = [_]x11.randr.MonitorEntry{.{
                    .name = name_atom,
                    .primary = true,
                    .automatic = true,
                    .x = 0,
                    .y = 0,
                    .width = size.w,
                    .height = size.h,
                    .mm_width = mm_width,
                    .mm_height = mm_height,
                    .outputs = &outputs,
                }};
                try x11.randr.encodeGetMonitors(w, en, seq, display.randr.timestamp, &monitors);
            } else {
                // Buffer sized to max_monitors (a fixed comptime upper bound --
                // randr_monitors is capped there, see Display.setMonitor).
                var buf: [x11.server_state.max_monitors]x11.randr.MonitorEntry = undefined;
                for (display.randr_monitors.items, 0..) |m, i| {
                    buf[i] = .{
                        .name = m.name,
                        .primary = m.primary,
                        .automatic = true,
                        .x = m.x,
                        .y = m.y,
                        .width = m.width,
                        .height = m.height,
                        .mm_width = m.mm_width,
                        .mm_height = m.mm_height,
                        // Slice the STABLE backing store (randr_monitors.items[i]), not
                        // `m` -- `m` is a by-value loop copy, so `m.outputs[0..]` would
                        // point at a loop-local stack array that's stale/clobbered by the
                        // time encodeGetMonitors reads it (every monitor's outputs would
                        // read back as the last iteration's stack contents).
                        .outputs = display.randr_monitors.items[i].outputs[0..m.n_outputs],
                    };
                }
                try x11.randr.encodeGetMonitors(w, en, seq, display.randr.timestamp, buf[0..display.randr_monitors.items.len]);
            }
        },
        43 => { // SetMonitor: request window@[4..8], MonitorInfo@[8..]: name ATOM@[8..12], primary BOOL@[12], automatic BOOL@[13], nOutput CARD16@[14..16], x INT16@[16..18], y@[18..20], width CARD16@[20..22], height@[22..24], width_mm CARD32@[24..28], height_mm@[28..32], outputs[nOutput] CARD32@[32..]. NO reply.
            if (bytes.len < 32) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const name = std.mem.readInt(u32, bytes[8..12], en);
            if (display.atoms.nameOf(name) == null) {
                try xproto.encodeAtomError(w, en, seq, .{ .bad_value = name, .minor_opcode = minor, .major_opcode = 130 });
                return;
            }
            const primary = bytes[12] != 0;
            const n_output_wire = std.mem.readInt(u16, bytes[14..16], en);
            const x = std.mem.readInt(i16, bytes[16..18], en);
            const y = std.mem.readInt(i16, bytes[18..20], en);
            const width = std.mem.readInt(u16, bytes[20..22], en);
            const height = std.mem.readInt(u16, bytes[22..24], en);
            const mm_width = std.mem.readInt(u32, bytes[24..28], en);
            const mm_height = std.mem.readInt(u32, bytes[28..32], en);
            // Bound the outputs list against BOTH the wire's actual remaining
            // bytes (a hostile client claiming more outputs than it sent) AND
            // max_monitor_outputs (RandrMonitor's fixed-size array) -- extra
            // claimed outputs beyond either bound are simply not read/stored.
            const outputs_available = (bytes.len - 32) / 4;
            const n_output = @min(n_output_wire, @min(outputs_available, x11.server_state.max_monitor_outputs));
            var mon = x11.server_state.RandrMonitor{
                .name = name,
                .primary = primary,
                .x = x,
                .y = y,
                .width = width,
                .height = height,
                .mm_width = mm_width,
                .mm_height = mm_height,
                .n_outputs = @intCast(n_output),
            };
            var i: usize = 0;
            while (i < n_output) : (i += 1) {
                mon.outputs[i] = std.mem.readInt(u32, bytes[32 + i * 4 ..][0..4], en);
            }
            display.setMonitor(mon) catch |e| switch (e) {
                // max_monitors reached with a genuinely new name -- no RANDR-
                // specific "too many monitors" code exists, so this maps to
                // the generic core BadAlloc (mirrors createWindow's TooManyResources->BadAlloc convention).
                error.OutOfMemory => {
                    try xproto.encodeAllocError(w, en, seq, .{ .bad_value = 0, .minor_opcode = minor, .major_opcode = 130 });
                    return;
                },
            };
        },
        44 => { // DeleteMonitor: request window@[4..8], name ATOM@[8..12]. NO reply.
            if (bytes.len < 12) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const name = std.mem.readInt(u32, bytes[8..12], en);
            display.deleteMonitor(name) catch |e| switch (e) {
                error.BadValue => {
                    try xproto.encodeValueError(w, en, seq, .{ .bad_value = name, .minor_opcode = minor, .major_opcode = 130 });
                    return;
                },
            };
        },
        10 => { // ListOutputProperties: request output@[4..8]; BadOutput on mismatch, else every property atom set on it (incl. the seeded EDID).
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            if (display.outputListProperties(output)) |atoms| {
                defer display.gpa.free(atoms);
                try x11.randr.encodeListOutputProperties(w, en, seq, atoms);
            } else |e| switch (e) {
                error.BadOutput => try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_output, output, minor),
                error.OutOfMemory => return e,
            }
        },
        11 => { // QueryOutputProperty: request output@[4..8], property@[8..12]; BadOutput/BadAtom, else a plain (non-range/non-immutable) reply.
            if (bytes.len < 12) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            const property = std.mem.readInt(u32, bytes[8..12], en);
            if (output != display.randr.output) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_output, output, minor);
                return;
            }
            if (display.atoms.nameOf(property) == null) {
                try xproto.encodeAtomError(w, en, seq, .{ .bad_value = property, .minor_opcode = minor, .major_opcode = 130 });
                return;
            }
            try x11.randr.encodeQueryOutputProperty(w, en, seq);
        },
        12 => { // ConfigureOutputProperty: request output@[4..8] (property/pending/range/values accepted + ignored -- no range enforcement); BadOutput on mismatch; NO reply.
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            if (output != display.randr.output) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_output, output, minor);
                return;
            }
        },
        13 => { // ChangeOutputProperty: request output@[4..8], property@[8..12], type@[12..16], format@[16], mode@[17], pad2, num_units@[20..24], data@[24..]; NO reply.
            if (bytes.len < 24) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            const property = std.mem.readInt(u32, bytes[8..12], en);
            const ptype = std.mem.readInt(u32, bytes[12..16], en);
            const format = bytes[16];
            const mode = bytes[17];
            const num_units = std.mem.readInt(u32, bytes[20..24], en);
            // Bound the declared data length against what the request actually
            // carries BEFORE trusting num_units for anything -- a hostile
            // client can claim any num_units while sending a short body. A
            // non-8/16/32 format divides to 0 units here; outputChangeProperty
            // still rejects it with BadValue.
            const unit_bytes: usize = if (format == 0) 0 else format / 8;
            const data_len: usize = @as(usize, num_units) * unit_bytes;
            if (bytes.len < 24 + data_len) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const data = bytes[24..][0..data_len];
            if (display.outputChangeProperty(output, property, ptype, format, mode, data, conn.client_id)) {
                deliverPending(display, mux); // flush the OutputProperty(NewValue) event it just recorded
            } else |e| {
                const bad: u32 = switch (e) {
                    error.BadOutput => output,
                    error.BadValue => format,
                    else => property, // BadAtom / BadMatch / TooLarge
                };
                try randrPropError(w, en, seq, minor, bad, e);
            }
        },
        14 => { // DeleteOutputProperty: request output@[4..8], property@[8..12]; NO reply.
            if (bytes.len < 12) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            const property = std.mem.readInt(u32, bytes[8..12], en);
            if (display.outputDeleteProperty(output, property)) {
                deliverPending(display, mux); // a delete may have recorded OutputProperty(Deleted)
            } else |e| {
                try randrPropError(w, en, seq, minor, if (e == error.BadOutput) output else property, e);
            }
        },
        15 => { // GetOutputProperty: request output@[4..8], property@[8..12], type@[12..16], long_offset@[16..20], long_length@[20..24], delete BOOL@[24]; reply mirrors core GetProperty.
            if (bytes.len < 25) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const output = std.mem.readInt(u32, bytes[4..8], en);
            const property = std.mem.readInt(u32, bytes[8..12], en);
            const type_filter = std.mem.readInt(u32, bytes[12..16], en);
            const long_offset = std.mem.readInt(u32, bytes[16..20], en);
            const long_length = std.mem.readInt(u32, bytes[20..24], en);
            const delete = bytes[24] != 0;
            if (display.outputGetProperty(output, property, type_filter, long_offset, long_length, delete)) |g| {
                const unit: u32 = if (g.format == 0) 1 else g.format / 8;
                const num_items: u32 = @intCast(g.value.len / unit);
                try x11.randr.encodeGetOutputProperty(w, en, seq, g.format, g.type, g.bytes_after, num_items, g.value);
            } else |e| {
                try randrPropError(w, en, seq, minor, if (e == error.BadOutput) output else property, e);
            }
        },
        26 => { // SetCrtcTransform: request crtc@[4..8], transform TRANSFORM(36)@[8..44] (+ an optional filter name/params tail this server ignores -- no named filters supported); BadCrtc on mismatch; NO reply.
            if (bytes.len < 44) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            var matrix: [9]u32 = undefined;
            for (&matrix, 0..) |*v, i| v.* = std.mem.readInt(u32, bytes[8 + i * 4 ..][0..4], en);
            display.setCrtcTransform(matrix);
        },
        27 => { // GetCrtcTransform: request crtc@[4..8]; BadCrtc on mismatch, else reply the stored matrix as both pending and current.
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            try x11.randr.encodeGetCrtcTransform(w, en, seq, display.randr_transform);
        },
        28 => { // GetPanning: request crtc@[4..8]; BadCrtc on mismatch, else reply status Success + all-zero panning fields (this server never pans).
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            try x11.randr.encodeGetPanning(w, en, seq, display.randr.timestamp);
        },
        29 => { // SetPanning: request crtc@[4..8] (+ the panning fields this server ignores -- panning is unsupported, accepted as a no-op); BadCrtc on mismatch, else reply status Success.
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const crtc = std.mem.readInt(u32, bytes[4..8], en);
            if (crtc != display.randr.crtc) {
                try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_crtc, crtc, minor);
                return;
            }
            try x11.randr.encodeSetPanningReply(w, en, seq, 0, display.randr.timestamp);
        },
        32 => { // GetProviders: request window@[4..8] (unused -- no per-window filtering); reply 0 providers (no GPU providers in this software-render model).
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            try x11.randr.encodeGetProviders(w, en, seq, display.randr.timestamp);
        },
        33, 34, 35, 36, 37, 38, 39, 40, 41 => { // GetProviderInfo/SetProviderOffloadSink/SetProviderOutputSource/ListProviderProperties/QueryProviderProperty/ConfigureProviderProperty/ChangeProviderProperty/DeleteProviderProperty/GetProviderProperty: every one operates on a PROVIDER id@[4..8] that never exists in this server -- core BadValue (not a RANDR-specific code; RANDR only defines BadOutput/BadCrtc/BadMode/BadProvider and none of those fit "provider id doesn't exist" as cleanly as the generic BadValue every real client already handles).
            if (bytes.len < 8) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const provider = std.mem.readInt(u32, bytes[4..8], en);
            try xproto.encodeValueError(w, en, seq, .{ .bad_value = provider, .minor_opcode = minor, .major_opcode = 130 });
        },
        45 => { // CreateLease: request window@[4..8], lid@[8..12] (+ crtcs/outputs lists this server never reads); always BadValue -- leasing needs real DRM fd-passing this server doesn't do.
            if (bytes.len < 12) {
                try badRequest(w, en, seq, 130, minor);
                return;
            }
            const lid = std.mem.readInt(u32, bytes[8..12], en);
            try xproto.encodeValueError(w, en, seq, .{ .bad_value = lid, .minor_opcode = minor, .major_opcode = 130 });
        },
        46 => {}, // FreeLease: no lease ever exists to free (CreateLease always fails) -- accept as a no-op, no reply.
        else => try badRequest(w, en, seq, 130, minor),
    }
}

/// Build a heap-allocated ServerConn touching only the fields handleRandr's
/// dynamic-mode minors read/write (`client_endian`, `out`/`out_sent`) --
/// mirrors server.zig's "no sockets" ServerConn tests (`stream`/`request_buf`/
/// etc. stay untouched and are never read by these code paths). Caller must
/// `gpa.destroy` + `conn.out.deinit()`.
fn testConn(gpa: std.mem.Allocator) !*x11.ServerConn {
    const conn = try gpa.create(x11.ServerConn);
    conn.client_endian = .little;
    conn.out = std.Io.Writer.Allocating.init(gpa);
    conn.out_sent = 0;
    return conn;
}

test "handleRandr CreateMode: mints a fresh id, DestroyMode/AddOutputMode/DeleteOutputMode validate + no-op" {
    const gpa = std.testing.allocator;
    var display = try x11.Display.init(gpa, 0x12a, 24, 0x21);
    defer display.deinit();
    const conn = try testConn(gpa);
    defer gpa.destroy(conn);
    defer conn.out.deinit();
    // Only .server/.gpa are read by handleRandr's minors below (none of them
    // resize the screen or emit events, so no deliverPending call ever
    // touches mux.clients/pollfds) -- same minimal-Multiplexer pattern as
    // server.zig's "Multiplexer.clientById" test.
    var mux: x11.Multiplexer = .{ .server = undefined, .gpa = gpa };
    defer mux.clients.deinit(gpa);
    defer mux.polled.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6), display.randrModeCount());

    // CreateMode: window@[4..8] (unused), ModeInfo@[8..40] (id@[8..12]
    // client-supplied + ignored, width@[12..14]=1600, height@[14..16]=900,
    // name_len@[34..36]=6), name "custom"@[40..46].
    var create_req: [46]u8 = std.mem.zeroes([46]u8);
    std.mem.writeInt(u16, create_req[12..14], 1600, .little);
    std.mem.writeInt(u16, create_req[14..16], 900, .little);
    std.mem.writeInt(u16, create_req[34..36], 6, .little);
    @memcpy(create_req[40..46], "custom");
    try handleRandr(conn, 16, &create_req, &display, 1, &mux);
    const create_reply = conn.pendingOut();
    try std.testing.expectEqual(@as(usize, 32), create_reply.len);
    try std.testing.expectEqual(@as(u8, 1), create_reply[0]); // Reply
    const mode_id = std.mem.readInt(u32, create_reply[8..12], .little);
    try std.testing.expect(mode_id >= 0xf0002000);
    conn.clearOut();

    // A second CreateMode mints the NEXT id, not the same one.
    try handleRandr(conn, 16, &create_req, &display, 2, &mux);
    const mode_id2 = std.mem.readInt(u32, conn.pendingOut()[8..12], .little);
    try std.testing.expect(mode_id2 != mode_id);
    conn.clearOut();

    try std.testing.expectEqual(@as(usize, 8), display.randrModeCount()); // 6 built-in + 2 created
    const m = display.randrModeById(mode_id).?;
    try std.testing.expectEqual(@as(u16, 1600), m.width);
    try std.testing.expectEqual(@as(u16, 900), m.height);

    // GetScreenResources now reports num_modes==8 (num_modes CARD16 @ [20..22]).
    const res_req = [_]u8{0} ** 8;
    try handleRandr(conn, 8, &res_req, &display, 3, &mux);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, conn.pendingOut()[20..22], .little));
    conn.clearOut();

    // DestroyMode(mode_id2) removes it: num_modes back to 7.
    var destroy_req = [_]u8{0} ** 8;
    std.mem.writeInt(u32, destroy_req[4..8], mode_id2, .little);
    try handleRandr(conn, 17, &destroy_req, &display, 4, &mux);
    try std.testing.expectEqual(@as(usize, 0), conn.pendingOut().len); // no reply
    try std.testing.expectEqual(@as(usize, 7), display.randrModeCount());
    try std.testing.expectEqual(@as(?x11.server_state.RandrMode, null), display.randrModeById(mode_id2));

    try handleRandr(conn, 8, &res_req, &display, 5, &mux);
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, conn.pendingOut()[20..22], .little));
    conn.clearOut();

    // DestroyMode on the CURRENT (built-in) mode id -> BadMode (only
    // client-created modes are destroyable).
    std.mem.writeInt(u32, destroy_req[4..8], display.randr.mode, .little);
    try handleRandr(conn, 17, &destroy_req, &display, 6, &mux);
    var err_reply = conn.pendingOut();
    try std.testing.expectEqual(@as(u8, 0), err_reply[0]); // Error
    try std.testing.expectEqual(x11.randr.bad_mode, err_reply[1]);
    conn.clearOut();

    // DestroyMode on an already-removed id -> BadMode.
    std.mem.writeInt(u32, destroy_req[4..8], mode_id2, .little);
    try handleRandr(conn, 17, &destroy_req, &display, 7, &mux);
    err_reply = conn.pendingOut();
    try std.testing.expectEqual(x11.randr.bad_mode, err_reply[1]);
    conn.clearOut();

    // AddOutputMode: wrong output -> BadOutput.
    var add_req = [_]u8{0} ** 12;
    std.mem.writeInt(u32, add_req[4..8], 0xdeadbeef, .little);
    std.mem.writeInt(u32, add_req[8..12], mode_id, .little);
    try handleRandr(conn, 18, &add_req, &display, 8, &mux);
    err_reply = conn.pendingOut();
    try std.testing.expectEqual(@as(u8, 0), err_reply[0]);
    try std.testing.expectEqual(x11.randr.bad_output, err_reply[1]);
    conn.clearOut();

    // AddOutputMode: right output, unknown mode -> BadMode.
    std.mem.writeInt(u32, add_req[4..8], display.randr.output, .little);
    std.mem.writeInt(u32, add_req[8..12], 0xdead, .little);
    try handleRandr(conn, 18, &add_req, &display, 9, &mux);
    err_reply = conn.pendingOut();
    try std.testing.expectEqual(x11.randr.bad_mode, err_reply[1]);
    conn.clearOut();

    // AddOutputMode / DeleteOutputMode: right output + a real (created) mode
    // -> accepted as a no-op, no reply.
    std.mem.writeInt(u32, add_req[8..12], mode_id, .little);
    try handleRandr(conn, 18, &add_req, &display, 10, &mux);
    try std.testing.expectEqual(@as(usize, 0), conn.pendingOut().len);
    try handleRandr(conn, 19, &add_req, &display, 11, &mux);
    try std.testing.expectEqual(@as(usize, 0), conn.pendingOut().len);
}

test "handleRandr SetMonitor/DeleteMonitor/GetMonitors: replace-by-name, N-monitor sum, BadAtom/BadValue, fallback to synthetic default" {
    const gpa = std.testing.allocator;
    var display = try x11.Display.init(gpa, 0x12a, 24, 0x21);
    defer display.deinit();
    const conn = try testConn(gpa);
    defer gpa.destroy(conn);
    defer conn.out.deinit();
    var mux: x11.Multiplexer = .{ .server = undefined, .gpa = gpa };
    defer mux.clients.deinit(gpa);
    defer mux.polled.deinit(gpa);

    const atom_a = try display.atoms.intern(gpa, "MON_A", false);
    const atom_b = try display.atoms.intern(gpa, "MON_B", false);
    const get_req = [_]u8{0} ** 9; // GetMonitors: window@[4..8] (unused), get_active@[8] (unused).

    // SetMonitor(A, 800x600 @ (10,20), 1 output) -- no reply.
    var set_a: [36]u8 = std.mem.zeroes([36]u8);
    std.mem.writeInt(u32, set_a[8..12], atom_a, .little);
    set_a[12] = 1; // primary
    std.mem.writeInt(u16, set_a[14..16], 1, .little); // nOutput
    std.mem.writeInt(i16, set_a[16..18], 10, .little); // x
    std.mem.writeInt(i16, set_a[18..20], 20, .little); // y
    std.mem.writeInt(u16, set_a[20..22], 800, .little); // width
    std.mem.writeInt(u16, set_a[22..24], 600, .little); // height
    std.mem.writeInt(u32, set_a[24..28], 300, .little); // mm_width
    std.mem.writeInt(u32, set_a[28..32], 200, .little); // mm_height
    std.mem.writeInt(u32, set_a[32..36], display.randr.output, .little); // outputs[0]
    try handleRandr(conn, 43, &set_a, &display, 1, &mux);
    try std.testing.expectEqual(@as(usize, 0), conn.pendingOut().len); // no reply
    try std.testing.expectEqual(@as(usize, 1), display.randr_monitors.items.len);

    // GetMonitors: nMonitors==1, nOutputs==1, monitor A's geometry + output.
    try handleRandr(conn, 42, &get_req, &display, 2, &mux);
    {
        const out = conn.pendingOut();
        try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[12..16], .little)); // nMonitors
        try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[16..20], .little)); // nOutputs
        try std.testing.expectEqual(atom_a, std.mem.readInt(u32, out[32..36], .little)); // name
        try std.testing.expectEqual(@as(u8, 1), out[36]); // primary
        try std.testing.expectEqual(@as(u16, 800), std.mem.readInt(u16, out[44..46], .little)); // width
        try std.testing.expectEqual(@as(u16, 600), std.mem.readInt(u16, out[46..48], .little)); // height
        try std.testing.expectEqual(display.randr.output, std.mem.readInt(u32, out[56..60], .little)); // outputs[0]
    }
    conn.clearOut();

    // A second SetMonitor for the SAME name (A) REPLACES in place -- still
    // nMonitors==1, but the geometry now reflects the new call.
    std.mem.writeInt(u16, set_a[20..22], 1024, .little); // width
    std.mem.writeInt(u16, set_a[22..24], 768, .little); // height
    try handleRandr(conn, 43, &set_a, &display, 3, &mux);
    try std.testing.expectEqual(@as(usize, 1), display.randr_monitors.items.len); // replaced, not appended
    try handleRandr(conn, 42, &get_req, &display, 4, &mux);
    {
        const out = conn.pendingOut();
        try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[12..16], .little)); // nMonitors still 1
        try std.testing.expectEqual(@as(u16, 1024), std.mem.readInt(u16, out[44..46], .little)); // new width
        try std.testing.expectEqual(@as(u16, 768), std.mem.readInt(u16, out[46..48], .little)); // new height
    }
    conn.clearOut();

    // SetMonitor(B, a different name, 2 outputs) -- nMonitors grows to 2,
    // nOutputs sums across both entries (1 + 2 = 3).
    var set_b: [40]u8 = std.mem.zeroes([40]u8);
    std.mem.writeInt(u32, set_b[8..12], atom_b, .little);
    std.mem.writeInt(u16, set_b[14..16], 2, .little); // nOutput
    std.mem.writeInt(u16, set_b[20..22], 1280, .little); // width
    std.mem.writeInt(u16, set_b[22..24], 720, .little); // height
    std.mem.writeInt(u32, set_b[32..36], 0xf0000010, .little); // outputs[0]
    std.mem.writeInt(u32, set_b[36..40], 0xf0000011, .little); // outputs[1]
    try handleRandr(conn, 43, &set_b, &display, 5, &mux);
    try std.testing.expectEqual(@as(usize, 2), display.randr_monitors.items.len);
    try handleRandr(conn, 42, &get_req, &display, 6, &mux);
    {
        const out = conn.pendingOut();
        try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[12..16], .little)); // nMonitors
        try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[16..20], .little)); // nOutputs: 1 + 2

        // Regression for the dangling-stack-pointer bug: the GetMonitors handler
        // used to build each MonitorEntry's `outputs` slice from the BY-VALUE
        // `for (...) |m|` loop copy (`m.outputs[0..m.n_outputs]`) instead of the
        // stable `display.randr_monitors.items[i]`, so every monitor's output
        // IDS (not just their counts) came back as whatever the LAST loop
        // iteration's stack copy happened to hold. A (1 output) is at [32..60):
        // 24-byte MonitorInfo fixed part + 1 output CARD32; B (2 outputs) follows
        // at [60..92): 24-byte fixed part + 2 output CARD32s. Assert the actual
        // output VALUES land at the right offsets for each monitor, not just
        // that the counts sum correctly.
        try std.testing.expectEqual(atom_a, std.mem.readInt(u32, out[32..36], .little)); // A's name
        try std.testing.expectEqual(display.randr.output, std.mem.readInt(u32, out[56..60], .little)); // A's outputs[0]
        try std.testing.expectEqual(atom_b, std.mem.readInt(u32, out[60..64], .little)); // B's name
        try std.testing.expectEqual(@as(u32, 0xf0000010), std.mem.readInt(u32, out[84..88], .little)); // B's outputs[0]
        try std.testing.expectEqual(@as(u32, 0xf0000011), std.mem.readInt(u32, out[88..92], .little)); // B's outputs[1]
    }
    conn.clearOut();

    // SetMonitor w/ an unregistered name atom -> BadAtom, no monitor added.
    var set_bad: [36]u8 = std.mem.zeroes([36]u8);
    std.mem.writeInt(u32, set_bad[8..12], 0xdead, .little); // never interned
    try handleRandr(conn, 43, &set_bad, &display, 7, &mux);
    {
        const err_reply = conn.pendingOut();
        try std.testing.expectEqual(@as(u8, 0), err_reply[0]); // Error
        try std.testing.expectEqual(@as(u8, 5), err_reply[1]); // core BadAtom (5)
    }
    try std.testing.expectEqual(@as(usize, 2), display.randr_monitors.items.len); // unchanged
    conn.clearOut();

    // DeleteMonitor(unknown) -> BadValue.
    var del_req = [_]u8{0} ** 12;
    std.mem.writeInt(u32, del_req[8..12], 0xdead, .little);
    try handleRandr(conn, 44, &del_req, &display, 8, &mux);
    {
        const err_reply = conn.pendingOut();
        try std.testing.expectEqual(@as(u8, 0), err_reply[0]); // Error
        try std.testing.expectEqual(@as(u8, 2), err_reply[1]); // core BadValue (2)
    }
    conn.clearOut();

    // DeleteMonitor(A) removes just A -- GetMonitors now reports only B.
    std.mem.writeInt(u32, del_req[8..12], atom_a, .little);
    try handleRandr(conn, 44, &del_req, &display, 9, &mux);
    try std.testing.expectEqual(@as(usize, 0), conn.pendingOut().len); // no reply
    try std.testing.expectEqual(@as(usize, 1), display.randr_monitors.items.len);
    try handleRandr(conn, 42, &get_req, &display, 10, &mux);
    try std.testing.expectEqual(atom_b, std.mem.readInt(u32, conn.pendingOut()[32..36], .little));
    conn.clearOut();

    // DeleteMonitor(B) removes the last one -- GetMonitors falls all the way
    // back to the synthetic default (640x480, the live root size).
    std.mem.writeInt(u32, del_req[8..12], atom_b, .little);
    try handleRandr(conn, 44, &del_req, &display, 11, &mux);
    try std.testing.expectEqual(@as(usize, 0), display.randr_monitors.items.len);
    try handleRandr(conn, 42, &get_req, &display, 12, &mux);
    {
        const out = conn.pendingOut();
        try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[12..16], .little)); // nMonitors
        try std.testing.expectEqual(@as(u16, 640), std.mem.readInt(u16, out[44..46], .little)); // width
        try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, out[46..48], .little)); // height
    }
    conn.clearOut();
}

/// Encode the X error for an output-property op failure. RANDR only defines
/// its own BadOutput/BadCrtc/BadMode/BadProvider (`randrError`'s encoder);
/// everything else this store can raise (BadAtom/BadMatch/BadValue/BadAlloc)
/// reuses the shared core error encoders, same convention as `propError`
/// above but with `minor_opcode = minor` / `major_opcode = 130` (an
/// extension request, not a core one).
fn randrPropError(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, minor: u8, bad: u32, err: anyerror) !void {
    switch (err) {
        error.BadOutput => try x11.randr.encodeRandrError(w, en, seq, x11.randr.bad_output, bad, minor),
        error.BadAtom => try xproto.encodeAtomError(w, en, seq, .{ .bad_value = bad, .minor_opcode = minor, .major_opcode = 130 }),
        error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = bad, .minor_opcode = minor, .major_opcode = 130 }),
        error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = bad, .minor_opcode = minor, .major_opcode = 130 }),
        error.TooLarge => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = bad, .minor_opcode = minor, .major_opcode = 130 }),
        else => return err, // OutOfMemory (fatal) and anything unexpected
    }
}

/// Encode the X error for a property-op failure (BadWindow / BadAtom / BadMatch
/// / BadValue / BadAlloc), carrying the offending resource in bad_value.
fn propError(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, opcode: u8, bad: u32, err: anyerror) !void {
    switch (err) {
        error.NoWindow => try xproto.encodeWindowError(w, en, seq, .{ .bad_value = bad, .minor_opcode = 0, .major_opcode = opcode }),
        error.BadAtom => try xproto.encodeAtomError(w, en, seq, .{ .bad_value = bad, .minor_opcode = 0, .major_opcode = opcode }),
        error.BadMatch => try xproto.encodeMatchError(w, en, seq, .{ .bad_value = bad, .minor_opcode = 0, .major_opcode = opcode }),
        error.BadValue => try xproto.encodeValueError(w, en, seq, .{ .bad_value = bad, .minor_opcode = 0, .major_opcode = opcode }),
        error.TooLarge => try xproto.encodeAllocError(w, en, seq, .{ .bad_value = bad, .minor_opcode = 0, .major_opcode = opcode }),
        else => return err, // OutOfMemory (fatal) and anything unexpected
    }
}

/// Unpack a decoded CreateWindow value-list into the xproto-free AttrDelta
/// Display.createWindow expects. Only the fields server_state.Attributes
/// tracks are carried over (background_pixmap/border_pixmap/cursor have no
/// tracked counterpart yet). bit_gravity/win_gravity/backing_store arrive as
/// ?u32 on the wire but are narrow enum-like values in practice, so they are
/// truncated to the u8 AttrDelta stores; override_redirect/save_under arrive
/// as ?BOOL32 (u32) and are normalized to bool.
fn deltaFromCreate(v: xproto.CreateWindowValueList) x11.server_state.AttrDelta {
    return .{
        .background_pixel = v.background_pixel,
        .border_pixel = v.border_pixel,
        .bit_gravity = if (v.bit_gravity) |x| @truncate(x) else null,
        .win_gravity = if (v.win_gravity) |x| @truncate(x) else null,
        .backing_store = if (v.backing_store) |x| @truncate(x) else null,
        .backing_planes = v.backing_planes,
        .backing_pixel = v.backing_pixel,
        .override_redirect = if (v.override_redirect) |x| (x != 0) else null,
        .save_under = if (v.save_under) |x| (x != 0) else null,
        .event_mask = v.event_mask,
        .do_not_propagate_mask = v.do_not_propogate_mask,
        .colormap = v.colormap,
    };
}

/// Same shape as deltaFromCreate, for ChangeWindowAttributesValueList (its
/// fields match CreateWindowValueList one-for-one, including the xcbproto
/// `do_not_propogate_mask` spelling).
fn deltaFromChange(v: xproto.ChangeWindowAttributesValueList) x11.server_state.AttrDelta {
    return .{
        .background_pixel = v.background_pixel,
        .border_pixel = v.border_pixel,
        .bit_gravity = if (v.bit_gravity) |x| @truncate(x) else null,
        .win_gravity = if (v.win_gravity) |x| @truncate(x) else null,
        .backing_store = if (v.backing_store) |x| @truncate(x) else null,
        .backing_planes = v.backing_planes,
        .backing_pixel = v.backing_pixel,
        .override_redirect = if (v.override_redirect) |x| (x != 0) else null,
        .save_under = if (v.save_under) |x| (x != 0) else null,
        .event_mask = v.event_mask,
        .do_not_propagate_mask = v.do_not_propogate_mask,
        .colormap = v.colormap,
    };
}

/// Unpack a decoded ConfigureWindow value-list into the xproto-free ConfigDelta
/// (the fields map 1:1; configureWindow validates + narrows the wire widths).
fn deltaFromConfigure(v: xproto.ConfigureWindowValueList) x11.server_state.ConfigDelta {
    return .{
        .x = v.x,
        .y = v.y,
        .width = v.width,
        .height = v.height,
        .border_width = v.border_width,
        .sibling = v.sibling,
        .stack_mode = v.stack_mode,
    };
}

/// Unpack a decoded CreateGC/ChangeGC value-list into the xproto-free GCDelta.
/// Accepts either value-list type (same field names). Only the components this
/// server stores are carried; graphics_exposures arrives as ?BOOL32 (u32).
fn deltaFromGC(v: anytype) x11.server_state.GCDelta {
    return .{
        .function = v.function,
        .plane_mask = v.plane_mask,
        .foreground = v.foreground,
        .background = v.background,
        .line_width = v.line_width,
        .line_style = v.line_style,
        .cap_style = v.cap_style,
        .join_style = v.join_style,
        .fill_style = v.fill_style,
        .subwindow_mode = v.subwindow_mode,
        .graphics_exposures = if (v.graphics_exposures) |x| (x != 0) else null,
        .arc_mode = v.arc_mode,
        .font = v.font,
    };
}
