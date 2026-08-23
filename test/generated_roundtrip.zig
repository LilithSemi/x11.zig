const std = @import("std");
const xproto = @import("xproto");
const xkb = @import("xkb");

test "generated bindings force-analyze" {
    std.testing.refAllDecls(xproto);
    std.testing.refAllDecls(xkb);
}

test "xproto exposes core xid aliases" {
    _ = xproto.WINDOW; // u32 alias exists
}

test "generated GetInputFocus decoder reads scalar fields" {
    const native_endian = @import("builtin").cpu.arch.endian();
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    buf[0] = 1; // reply indicator
    buf[1] = 2; // revert_to = 2
    std.mem.writeInt(u32, buf[8..12], 0x12345678, native_endian); // focus
    const r = xproto.decodeGetInputFocusReply(&buf);
    try std.testing.expectEqual(@as(u8, 2), r.revert_to);
    try std.testing.expectEqual(@as(u32, 0x12345678), r.focus);
}

test "QueryTree reply decodes children list (borrowed)" {
    var buf: [32 + 12]u8 = std.mem.zeroes([32 + 12]u8);
    const ne = @import("builtin").cpu.arch.endian();
    // 32 + 12 bytes total; lists = 12 bytes = 3 words -> length_word = 3
    std.mem.writeInt(u32, buf[4..8], 3, ne); // reply length word (3 WINDOW words)
    std.mem.writeInt(u32, buf[8..12], 0x111, ne); // root
    std.mem.writeInt(u32, buf[12..16], 0x222, ne); // parent
    std.mem.writeInt(u16, buf[16..18], 3, ne); // children_len
    std.mem.writeInt(u32, buf[32..36], 0xAAA, ne);
    std.mem.writeInt(u32, buf[36..40], 0xBBB, ne);
    std.mem.writeInt(u32, buf[40..44], 0xCCC, ne);
    const r = xproto.decodeQueryTreeReply(&buf);
    try std.testing.expectEqual(@as(u32, 0x111), r.root);
    try std.testing.expectEqual(@as(u16, 3), r.children_len);
    try std.testing.expectEqual(@as(usize, 3), r.children.len);
    try std.testing.expectEqual(@as(u32, 0xAAA), r.children[0]);
    try std.testing.expectEqual(@as(u32, 0xCCC), r.children[2]);
}

test "struct list decodes via ListView (GetMotionEvents)" {
    // GetMotionEvents reply layout:
    //   offset 0: reply indicator (1)
    //   offset 1: pad (first-slot)
    //   offsets 2-7: implicit seq+len gap
    //   offset 8..12: events_len (CARD32)
    //   offsets 12-31: 20 bytes pad
    //   offset 32+: list of Timecoord (8 bytes each: time u32, x i16, y i16)
    const ne = @import("builtin").cpu.arch.endian();
    // 32-byte header + 2 Timecoord elements = 32 + 16 bytes
    var buf: [32 + 16]u8 = std.mem.zeroes([32 + 16]u8);
    // 16 bytes of list data = 4 words -> length_word = 4
    std.mem.writeInt(u32, buf[4..8], 4, ne); // reply length word (4 dwords for 2 Timecoord)
    std.mem.writeInt(u32, buf[8..12], 2, ne); // events_len = 2
    // element 0 at offset 32: time=0x1000, x=10, y=20
    std.mem.writeInt(u32, buf[32..36], 0x1000, ne);
    std.mem.writeInt(i16, buf[36..38], 10, ne);
    std.mem.writeInt(i16, buf[38..40], 20, ne);
    // element 1 at offset 40: time=0x2000, x=-5, y=99
    std.mem.writeInt(u32, buf[40..44], 0x2000, ne);
    std.mem.writeInt(i16, buf[44..46], -5, ne);
    std.mem.writeInt(i16, buf[46..48], 99, ne);
    const r = xproto.decodeGetMotionEventsReply(&buf);
    try std.testing.expectEqual(@as(u32, 2), r.events_len);
    try std.testing.expectEqual(@as(usize, 2), r.events.len());
    const e0 = r.events.at(0);
    const e1 = r.events.at(1);
    try std.testing.expectEqual(@as(u32, 0x1000), e0.time);
    try std.testing.expectEqual(@as(i16, 10), e0.x);
    try std.testing.expectEqual(@as(i16, 20), e0.y);
    try std.testing.expectEqual(@as(u32, 0x2000), e1.time);
    try std.testing.expectEqual(@as(i16, -5), e1.x);
    try std.testing.expectEqual(@as(i16, 99), e1.y);
}

test "KeyPress event decodes real fields" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    const ne = @import("builtin").cpu.arch.endian();
    buf[1] = 42; // detail (KEYCODE = u8)
    std.mem.writeInt(u32, buf[4..8], 123456, ne); // time (TIMESTAMP = u32)
    std.mem.writeInt(u32, buf[8..12], 0x1, ne); // root (WINDOW = u32)
    const e = xproto.decodeKeyPressEvent(&buf);
    try std.testing.expectEqual(@as(u8, 42), e.detail);
    try std.testing.expectEqual(@as(u32, 123456), e.time);
    try std.testing.expectEqual(@as(u32, 0x1), e.root);
}

test "error decodes bad_value + opcodes" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    const ne = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(u32, buf[4..8], 0xDEAD, ne); // bad_value@4
    std.mem.writeInt(u16, buf[8..10], 55, ne); // minor_opcode@8
    buf[10] = 77; // major_opcode@10
    const er = xproto.decodeValueError(&buf);
    try std.testing.expectEqual(@as(u32, 0xDEAD), er.bad_value);
    try std.testing.expectEqual(@as(u16, 55), er.minor_opcode);
    try std.testing.expectEqual(@as(u8, 77), er.major_opcode);
}

test "DestroyNotify event decodes WINDOW fields from offset 4 (leading-pad fix)" {
    // DestroyNotify has <pad bytes="1"/> then <field type="WINDOW" name="event"/>
    // then <field type="WINDOW" name="window"/>. The leading pad consumes the
    // offset-1 slot so event sits at offset 4 and window at offset 8.
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    const ne = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(u32, buf[4..8], 0xABCD1234, ne); // event WINDOW @ offset 4
    std.mem.writeInt(u32, buf[8..12], 0xDEADBEEF, ne); // window WINDOW @ offset 8
    const ev = xproto.decodeDestroyNotifyEvent(&buf);
    // Both fields must be non-zero: proves we are NOT falling back to zeroes.
    try std.testing.expectEqual(@as(u32, 0xABCD1234), ev.event);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), ev.window);
}

test "QueryFont reply fully decodes nested Charinfo fields and lists" {
    // QueryFont reply layout (xcbproto xproto.xml):
    //   offset 0: reply indicator (1)
    //   offset 1: pad (first-slot consumed by pad; cursor jumps to 8)
    //   offsets 2-7: implicit seq+len gap
    //   offset 8..20: min_bounds (Charinfo, wire_size=12)
    //   offsets 20-23: pad 4 bytes
    //   offset 24..36: max_bounds (Charinfo, wire_size=12)
    //   offsets 36-39: pad 4 bytes
    //   offset 40: min_char_or_byte2 (u16)
    //   offset 42: max_char_or_byte2 (u16)
    //   offset 44: default_char (u16)
    //   offset 46: properties_len (u16)
    //   offset 48: draw_direction (u8)
    //   offset 49: min_byte1 (u8)
    //   offset 50: max_byte1 (u8)
    //   offset 51: all_chars_exist (bool)
    //   offset 52: font_ascent (i16)
    //   offset 54: font_descent (i16)
    //   offset 56: char_infos_len (u32)
    //   offset 60+: properties (Fontprop, wire_size=8 each), then char_infos (Charinfo, wire_size=12 each)
    const ne = @import("builtin").cpu.arch.endian();
    const P = 1; // 1 Fontprop
    const C = 2; // 2 Charinfos
    const buf_len = 60 + P * 8 + C * 12; // 92 bytes total
    var buf: [buf_len]u8 = std.mem.zeroes([buf_len]u8);
    buf[0] = 1; // reply indicator
    // reply length word: (92 - 32) / 4 = 15 (lists occupy 60 bytes past the 32-byte header)
    std.mem.writeInt(u32, buf[4..8], 15, ne);

    // Plant min_bounds.left_side_bearing = -7 at offset 8
    std.mem.writeInt(i16, buf[8..10], -7, ne);

    // Plant properties_len = 1 at offset 46
    std.mem.writeInt(u16, buf[46..48], P, ne);
    // Plant char_infos_len = 2 at offset 56
    std.mem.writeInt(u32, buf[56..60], C, ne);

    // Plant Fontprop[0] at offset 60: name=0x1234, value=0x5678
    std.mem.writeInt(u32, buf[60..64], 0x1234, ne);
    std.mem.writeInt(u32, buf[64..68], 0x5678, ne);
    // Plant Charinfo[0] at offset 68 (60 + 1*8 aligned): left_side_bearing=100
    std.mem.writeInt(i16, buf[68..70], 100, ne);
    // Plant Charinfo[1] at offset 80 (68 + 12): left_side_bearing=200
    std.mem.writeInt(i16, buf[80..82], 200, ne);

    const r = xproto.decodeQueryFontReply(&buf);

    // min_bounds decoded inline via Charinfo.decodeElement at offset 8
    try std.testing.expectEqual(@as(i16, -7), r.min_bounds.left_side_bearing);

    // properties_len and char_infos_len decoded from fixed header
    try std.testing.expectEqual(@as(u16, 1), r.properties_len);
    try std.testing.expectEqual(@as(u32, 2), r.char_infos_len);

    // Lists are decoded (not empty)
    try std.testing.expectEqual(@as(usize, 1), r.properties.len());
    try std.testing.expectEqual(@as(usize, 2), r.char_infos.len());

    // List element values decode correctly
    try std.testing.expectEqual(@as(u32, 0x1234), r.properties.at(0).name);
    try std.testing.expectEqual(@as(i16, 100), r.char_infos.at(0).left_side_bearing);
    try std.testing.expectEqual(@as(i16, 200), r.char_infos.at(1).left_side_bearing);
}

test "GetKeyboardMapping decodes keysyms via length header" {
    var buf: [32 + 12]u8 = std.mem.zeroes([32 + 12]u8);
    const ne = @import("builtin").cpu.arch.endian();
    buf[1] = 2; // keysyms_per_keycode (detail slot @1)
    std.mem.writeInt(u32, buf[4..8], 3, ne); // reply length word = 3 -> 3 keysyms (KEYSYM=4 bytes)
    std.mem.writeInt(u32, buf[32..36], 0xAA, ne);
    std.mem.writeInt(u32, buf[36..40], 0xBB, ne);
    std.mem.writeInt(u32, buf[40..44], 0xCC, ne);
    const r = xproto.decodeGetKeyboardMappingReply(&buf);
    try std.testing.expectEqual(@as(usize, 3), r.keysyms.len);
    try std.testing.expectEqual(@as(u32, 0xCC), r.keysyms[2]);
}

test "GetModifierMapping decodes keycodes via op length" {
    var buf: [32 + 16]u8 = std.mem.zeroes([32 + 16]u8);
    const ne = @import("builtin").cpu.arch.endian();
    buf[1] = 2; // keycodes_per_modifier (detail slot @1) -> 2*8 = 16 keycodes
    std.mem.writeInt(u32, buf[4..8], 4, ne); // length word = 4 (16 bytes / 4)
    buf[32] = 0x11;
    buf[47] = 0x99;
    const r = xproto.decodeGetModifierMappingReply(&buf);
    try std.testing.expectEqual(@as(usize, 16), r.keycodes.len);
    try std.testing.expectEqual(@as(u8, 0x11), r.keycodes[0]);
    try std.testing.expectEqual(@as(u8, 0x99), r.keycodes[15]);
}

test "variable struct Str decodes its char list" {
    // xproto STR layout: byte[0] = name_len (CARD8), bytes[1..] = name (char list).
    // Str.name is []align(1) const u8. decodeStr takes the raw bytes.
    var buf: [1 + 3]u8 = std.mem.zeroes([1 + 3]u8);
    buf[0] = 3;
    buf[1] = 'a';
    buf[2] = 'b';
    buf[3] = 'c';
    const s = xproto.decodeStr(&buf);
    try std.testing.expectEqual(@as(u8, 3), s.name_len);
    try std.testing.expectEqual(@as(usize, 3), s.name.len);
    try std.testing.expectEqual(@as(u8, 'a'), s.name[0]);
    try std.testing.expectEqual(@as(u8, 'c'), s.name[2]);
}

test "xkb.decodeEvent dispatches on xkbType to a decoded event" {
    // xkb is xkb-style: bytes[1] holds xkbType which selects the event variant.
    // StateNotify has number=2. The decodeStateNotifyEvent fn reads:
    //   xkbType   at bytes[1]  (u8, the discriminator itself)
    //   deviceID  at bytes[8]  (u8)
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    buf[1] = xkb.state_notify_event_number; // xkbType = 2 -> StateNotify
    buf[8] = 0x42; // deviceID
    const ev = xkb.decodeEvent(&buf);
    try std.testing.expect(ev == .state_notify);
    try std.testing.expectEqual(@as(u8, 0x42), ev.state_notify.deviceID);
}

test "ListHosts reply decodes a HOST list via StructIterator" {
    const ne = @import("builtin").cpu.arch.endian();
    var buf: [48]u8 = std.mem.zeroes([48]u8);
    buf[0] = 1; // reply
    buf[1] = 3; // mode
    std.mem.writeInt(u32, buf[4..8], 4, ne); // length = 4 words = 16 bytes of hosts
    std.mem.writeInt(u16, buf[8..10], 2, ne); // hosts_len = 2
    // HOST 1 @32: family=0, address_len=4, address=[1,2,3,4] -> 8 bytes (already 4-aligned)
    buf[32] = 0;
    std.mem.writeInt(u16, buf[34..36], 4, ne);
    buf[36] = 1;
    buf[37] = 2;
    buf[38] = 3;
    buf[39] = 4;
    // HOST 2 @40: family=1, address_len=2, address=[9,9] -> 6 bytes padded to 8
    buf[40] = 1;
    std.mem.writeInt(u16, buf[42..44], 2, ne);
    buf[44] = 9;
    buf[45] = 9;

    const reply = xproto.decodeListHostsReply(&buf);
    try std.testing.expectEqual(@as(u16, 2), reply.hosts_len);
    try std.testing.expectEqual(@as(usize, 2), reply.hosts.len());

    var it = reply.hosts;
    const h1 = it.next().?;
    try std.testing.expectEqual(@as(u8, 0), h1.family);
    try std.testing.expectEqual(@as(u16, 4), h1.address_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, h1.address);
    const h2 = it.next().?;
    try std.testing.expectEqual(@as(u8, 1), h2.family);
    try std.testing.expectEqual(@as(u16, 2), h2.address_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 9 }, h2.address);
    try std.testing.expect(it.next() == null);
}

test "Screen decodes nested allowed_depths then visuals (two-level)" {
    const ne = @import("builtin").cpu.arch.endian();
    var buf: [72]u8 = std.mem.zeroes([72]u8);
    std.mem.writeInt(u32, buf[0..4], 0x111, ne); // root
    std.mem.writeInt(u32, buf[32..36], 0x222, ne); // root_visual
    buf[38] = 24; // root_depth
    buf[39] = 1; // allowed_depths_len = 1
    // DEPTH @40: depth=24, pad, visuals_len=1, pad, then one VISUALTYPE
    buf[40] = 24;
    std.mem.writeInt(u16, buf[42..44], 1, ne); // visuals_len = 1
    std.mem.writeInt(u32, buf[48..52], 0x333, ne); // VISUALTYPE.visual_id

    const r = xproto.Screen.decodeSized(&buf, ne);
    try std.testing.expectEqual(@as(u32, 0x111), r.value.root);
    try std.testing.expectEqual(@as(u8, 1), r.value.allowed_depths_len);
    try std.testing.expectEqual(@as(usize, 72), r.size); // 40 fixed + (8 + 24)

    var depths = r.value.allowed_depths;
    try std.testing.expectEqual(@as(usize, 1), depths.len());
    const d = depths.next().?;
    try std.testing.expectEqual(@as(u8, 24), d.depth);
    try std.testing.expectEqual(@as(u16, 1), d.visuals_len);
    try std.testing.expectEqual(@as(usize, 1), d.visuals.len());
    try std.testing.expectEqual(@as(u32, 0x333), d.visuals.at(0).visual_id);
    try std.testing.expect(depths.next() == null);
}

test "KeymapNotify event decodes 31-byte keys from byte 1" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    buf[0] = 11; // event code (unused by decoder)
    var i: usize = 1;
    while (i < 32) : (i += 1) buf[i] = @intCast(i);
    const ev = xproto.decodeKeymapNotifyEvent(&buf);
    try std.testing.expectEqual(@as(usize, 31), ev.keys.len);
    try std.testing.expectEqual(@as(u8, 1), ev.keys[0]);
    try std.testing.expectEqual(@as(u8, 31), ev.keys[30]);
}

test "fixed struct with a literal-length list decodes (xkb SIAction)" {
    const ne = @import("builtin").cpu.arch.endian();
    var buf: [8]u8 = std.mem.zeroes([8]u8);
    buf[0] = 0xAB; // type
    var i: usize = 1;
    while (i < 8) : (i += 1) buf[i] = @intCast(i * 10);
    const a = xkb.SIAction.decodeElement(&buf, ne);
    try std.testing.expectEqual(@as(u8, 0xAB), a.type);
    try std.testing.expectEqual(@as(usize, 7), a.data.len);
    try std.testing.expectEqual(@as(u8, 10), a.data[0]);
    try std.testing.expectEqual(@as(u8, 70), a.data[6]);
    try std.testing.expectEqual(@as(usize, 8), xkb.SIAction.wire_size);
}

test "interleaved variable struct decodes (xkb KeySymMap)" {
    const ne = @import("builtin").cpu.arch.endian();
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    var i: usize = 0;
    while (i < 4) : (i += 1) buf[i] = @intCast(i + 1); // kt_index[4] = 1,2,3,4
    std.mem.writeInt(u16, buf[6..8], 2, ne); // nSyms = 2
    std.mem.writeInt(u32, buf[8..12], 0x1111, ne); // syms[0]
    std.mem.writeInt(u32, buf[12..16], 0x2222, ne); // syms[1]
    const r = xkb.KeySymMap.decodeSized(&buf, ne);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, r.value.kt_index);
    try std.testing.expectEqual(@as(u16, 2), r.value.nSyms);
    try std.testing.expectEqual(@as(usize, 2), r.value.syms.len);
    try std.testing.expectEqual(@as(u32, 0x1111), r.value.syms[0]);
    try std.testing.expectEqual(@as(u32, 0x2222), r.value.syms[1]);
    try std.testing.expectEqual(@as(usize, 16), r.size); // 8 fixed + 2*4
}

test "fixed-size union list element decodes (xkb Action)" {
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    var i: usize = 0;
    while (i < 16) : (i += 1) buf[i] = @intCast(i);
    // Two 8-byte Actions back to back via ListView.
    var lv = xkb.ListView(xkb.Action){ .bytes = &buf, .count = 2 };
    try std.testing.expectEqual(@as(usize, 2), lv.len());
    const a0 = lv.at(0);
    const a1 = lv.at(1);
    try std.testing.expectEqual(@as(u8, 0), a0.raw[0]);
    try std.testing.expectEqual(@as(u8, 7), a0.raw[7]);
    try std.testing.expectEqual(@as(u8, 8), a1.raw[0]);
    try std.testing.expectEqual(@as(usize, 8), xkb.Action.wire_size);
}

test "reply-side switch decodes a selected bitcase (xkb GetMap modmap)" {
    const ne = @import("builtin").cpu.arch.endian();
    // GetMap reply: fixed header is 40 bytes, then the switch payload. Select
    // ONLY the modmap_rtrn bitcase (present bit 4); its list is totalModMapKeys
    // KeyModMap elements (2 bytes each) starting at offset 40.
    var buf: [44]u8 = std.mem.zeroes([44]u8);
    buf[0] = 1; // reply response type
    buf[1] = 7; // deviceID
    std.mem.writeInt(u16, buf[12..14], 4, ne); // present = modmap only
    buf[33] = 2; // totalModMapKeys = 2
    buf[40] = 0x11; // KeyModMap[0].keycode
    buf[41] = 0x22; // KeyModMap[0].mods
    buf[42] = 0x33; // KeyModMap[1].keycode
    buf[43] = 0x44; // KeyModMap[1].mods
    const r = xkb.decodeGetMapReply(&buf);
    try std.testing.expectEqual(@as(u8, 7), r.deviceID);
    try std.testing.expectEqual(@as(u16, 4), r.present);
    // Only the selected bitcase is populated.
    try std.testing.expect(r.values.types_rtrn == null);
    try std.testing.expect(r.values.modmap_rtrn != null);
    const mm = r.values.modmap_rtrn.?;
    try std.testing.expectEqual(@as(usize, 2), mm.len());
    try std.testing.expectEqual(@as(u8, 0x11), mm.at(0).keycode);
    try std.testing.expectEqual(@as(u8, 0x22), mm.at(0).mods);
    try std.testing.expectEqual(@as(u8, 0x33), mm.at(1).keycode);
    try std.testing.expectEqual(@as(u8, 0x44), mm.at(1).mods);
}

test "reply-side switch decodes a nested variable struct field (xkb GetKbdByName geometry)" {
    const ne = @import("builtin").cpu.arch.endian();
    // GetKbdByName reply: the geometry bitcase (reported bit 64) ends with
    // labelFont, a CountedString16 (u16 length then that many chars). The
    // switch payload starts at offset 32 and labelFont lands at offset 64.
    var buf: [80]u8 = std.mem.zeroes([80]u8);
    buf[0] = 1; // reply response type
    std.mem.writeInt(u16, buf[14..16], 64, ne); // reported = Geometry only
    std.mem.writeInt(u16, buf[64..66], 3, ne); // labelFont.length = 3
    buf[66] = 'a';
    buf[67] = 'b';
    buf[68] = 'c';
    const r = xkb.decodeGetKbdByNameReply(&buf);
    try std.testing.expect(r.values.geometry != null);
    const g = r.values.geometry.?;
    try std.testing.expectEqual(@as(u16, 3), g.labelFont.length);
    try std.testing.expectEqualSlices(u8, "abc", g.labelFont.string);
}

test "xproto.decodeEvent dispatches a core event by masked code" {
    const ne = @import("builtin").cpu.arch.endian();
    // KeyPress is event code 2. Build a minimal 32-byte KeyPress event.
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    buf[0] = 2; // KeyPress
    buf[1] = 44; // detail (keycode)
    std.mem.writeInt(u16, buf[2..4], 7, ne); // sequence
    const ev = xproto.decodeEvent(&buf);
    try std.testing.expect(ev == .key_press);
    try std.testing.expectEqual(@as(u8, 44), ev.key_press.detail);

    // The 0x80 SendEvent bit still dispatches to the same variant.
    buf[0] = 2 | 0x80;
    try std.testing.expect(xproto.decodeEvent(&buf) == .key_press);

    // An unknown/unowned code -> .unknown.
    buf[0] = 0xFF;
    try std.testing.expect(xproto.decodeEvent(&buf) == .unknown);
}

test "xproto.decodeEvent types an eventcopy (KeyRelease shares KeyPress layout)" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    buf[0] = 3; // KeyRelease (eventcopy of KeyPress, code 3)
    buf[1] = 55; // detail (keycode)
    const ev = xproto.decodeEvent(&buf);
    try std.testing.expect(ev == .key_release);
    try std.testing.expectEqual(@as(u8, 55), ev.key_release.detail);
}

test "decodeMapWindowRequest reads the window from the body" {
    const ne = @import("builtin").cpu.arch.endian();
    // MapWindow (opcode 8): byte0 opcode, byte1 unused, bytes2-3 length, bytes4-7 window.
    var buf: [8]u8 = std.mem.zeroes([8]u8);
    buf[0] = 8; // opcode
    std.mem.writeInt(u16, buf[2..4], 2, ne); // length = 2 units
    std.mem.writeInt(u32, buf[4..8], 0xABCD1234, ne); // window
    const r = xproto.decodeMapWindowRequest(&buf, ne);
    try std.testing.expectEqual(@as(u32, 0xABCD1234), r.window);
}

test "decode request honors the endian parameter" {
    // GetInputFocus has no body; use GetGeometry (opcode 14): byte4-7 drawable u32.
    var buf: [8]u8 = std.mem.zeroes([8]u8);
    buf[0] = 14;
    buf[4] = 0x78;
    buf[5] = 0x56;
    buf[6] = 0x34;
    buf[7] = 0x12;
    // Interpreted little-endian, drawable = 0x12345678; big-endian = 0x78563412.
    try std.testing.expectEqual(@as(u32, 0x12345678), xproto.decodeGetGeometryRequest(&buf, .little).drawable);
    try std.testing.expectEqual(@as(u32, 0x78563412), xproto.decodeGetGeometryRequest(&buf, .big).drawable);
}

test "decodeInternAtomRequest borrows the name slice" {
    const ne = @import("builtin").cpu.arch.endian();
    // InternAtom (opcode 16): byte1 only_if_exists, bytes4-5 name_len u16, bytes6-7 pad, then name.
    const name = "PRIMARY";
    var buf: [8 + 8]u8 = std.mem.zeroes([8 + 8]u8); // header(8) + "PRIMARY"(7) padded to 8
    buf[0] = 16;
    buf[1] = 0; // only_if_exists = false
    std.mem.writeInt(u16, buf[2..4], 4, ne); // length units (approx; not read by name decode)
    std.mem.writeInt(u16, buf[4..6], @intCast(name.len), ne); // name_len
    @memcpy(buf[8..][0..name.len], name);
    const r = xproto.decodeInternAtomRequest(&buf, ne);
    try std.testing.expectEqual(@as(u16, 7), r.name_len);
    try std.testing.expectEqualSlices(u8, "PRIMARY", r.name);
}

test "decodeCreateWindowRequest decodes fixed fields and a value list" {
    const ne = @import("builtin").cpu.arch.endian();
    // CreateWindow (opcode 1): byte1 depth, bytes4-7 wid, 8-11 parent, 12-13 x,
    // 14-15 y, 16-17 width, 18-19 height, 20-21 border_width, 22-23 class,
    // 24-27 visual, 28-31 value_mask, then set values (4 bytes each, bit order).
    // Set background_pixel (bit 1<<1=2) and event_mask (bit 1<<11=2048).
    var buf: [8 + 32 + 8]u8 = std.mem.zeroes([8 + 32 + 8]u8);
    buf[0] = 1; // opcode
    buf[1] = 24; // depth
    std.mem.writeInt(u32, buf[4..8], 0x200001, ne); // wid
    std.mem.writeInt(u32, buf[8..12], 0x12a, ne); // parent
    std.mem.writeInt(u16, buf[16..18], 100, ne); // width
    std.mem.writeInt(u16, buf[18..20], 100, ne); // height
    std.mem.writeInt(u16, buf[22..24], 1, ne); // class = InputOutput
    const mask: u32 = 2 | 2048; // background_pixel | event_mask
    std.mem.writeInt(u32, buf[28..32], mask, ne);
    std.mem.writeInt(u32, buf[32..36], 0xFFFFFF, ne); // background_pixel value (first set bit)
    std.mem.writeInt(u32, buf[36..40], 0x20000, ne); // event_mask value (second set bit)
    const r = xproto.decodeCreateWindowRequest(&buf, ne);
    try std.testing.expectEqual(@as(u8, 24), r.depth);
    try std.testing.expectEqual(@as(u32, 0x200001), r.wid);
    try std.testing.expectEqual(@as(u16, 100), r.width);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), r.value_list.background_pixel.?);
    try std.testing.expectEqual(@as(u32, 0x20000), r.value_list.event_mask.?);
    try std.testing.expect(r.value_list.border_pixel == null);
}

test "decodeRequest dispatches by opcode to the typed variant" {
    const ne = @import("builtin").cpu.arch.endian();
    var buf: [8]u8 = std.mem.zeroes([8]u8);
    buf[0] = 8; // MapWindow
    std.mem.writeInt(u32, buf[4..8], 0xABCD, ne);
    const req = xproto.decodeRequest(8, &buf, ne);
    try std.testing.expect(req == .map_window);
    try std.testing.expectEqual(@as(u32, 0xABCD), req.map_window.window);

    // Unknown opcode -> .unknown.
    try std.testing.expect(xproto.decodeRequest(250, &buf, ne) == .unknown);
}

test "requestHasReply reports reply-bearing opcodes" {
    // GetInputFocus (43) has a reply; MapWindow (8) does not.
    try std.testing.expect(xproto.requestHasReply(43));
    try std.testing.expect(!xproto.requestHasReply(8));
}

test "GetInputFocus reply round-trips: encode -> decode" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const r_in = xproto.GetInputFocusReply{ .revert_to = 2, .focus = 0x12345678 };
    try xproto.encodeGetInputFocusReply(&w, .little, 7, r_in);
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 1), bytes[0]); // reply
    try std.testing.expectEqual(@as(u8, 2), bytes[1]); // revert_to (data byte)
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, bytes[2..4], .little)); // seq
    const r_out = xproto.decodeGetInputFocusReply(bytes);
    try std.testing.expectEqual(r_in.revert_to, r_out.revert_to);
    try std.testing.expectEqual(r_in.focus, r_out.focus);
}

test "GetWindowAttributes reply round-trips all fixed fields" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const a = xproto.GetWindowAttributesReply{
        .backing_store = 1,
        .visual = 0x21,
        .class = 1,
        .bit_gravity = 2,
        .win_gravity = 3,
        .backing_planes = 0xAAAA,
        .backing_pixel = 0xBBBB,
        .save_under = true,
        .map_is_installed = true,
        .map_state = 2,
        .override_redirect = false,
        .colormap = 0xCCCC,
        .all_event_masks = 0xD,
        .your_event_mask = 0x20000,
        .do_not_propagate_mask = 5,
    };
    try xproto.encodeGetWindowAttributesReply(&w, .little, 3, a);
    const out = xproto.decodeGetWindowAttributesReply(w.buffered());
    try std.testing.expectEqual(a.visual, out.visual);
    try std.testing.expectEqual(a.your_event_mask, out.your_event_mask);
    try std.testing.expectEqual(a.do_not_propagate_mask, out.do_not_propagate_mask);
    try std.testing.expectEqual(a.override_redirect, out.override_redirect);
}

test "reply encoder honors endian" {
    var buf: [64]u8 = undefined;
    var wl = std.Io.Writer.fixed(&buf);
    try xproto.encodeGetInputFocusReply(&wl, .big, 1, .{ .revert_to = 0, .focus = 0x11223344 });
    // focus at byte 8, big-endian
    try std.testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, wl.buffered()[8..12], .big));
    try std.testing.expectEqual(@as(u32, 0x44332211), std.mem.readInt(u32, wl.buffered()[8..12], .little));
}

test "MapNotify event round-trips: encode -> decode" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const e_in = xproto.MapNotifyEvent{ .event = 0x111, .window = 0x222, .override_redirect = true };
    try xproto.encodeMapNotifyEvent(&w, .little, 9, e_in);
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 19), bytes[0] & 0x7f); // MapNotify code = 19
    const e_out = xproto.decodeMapNotifyEvent(bytes);
    try std.testing.expectEqual(e_in.event, e_out.event);
    try std.testing.expectEqual(e_in.window, e_out.window);
    try std.testing.expectEqual(e_in.override_redirect, e_out.override_redirect);
}

test "Value error round-trips + Implementation error writes code 17" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const er_in = xproto.ValueError{ .bad_value = 0xDEAD, .minor_opcode = 5, .major_opcode = 42 };
    try xproto.encodeValueError(&w, .little, 4, er_in);
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 0), bytes[0]); // error marker
    const er_out = xproto.decodeValueError(bytes);
    try std.testing.expectEqual(er_in.bad_value, er_out.bad_value);
    try std.testing.expectEqual(er_in.major_opcode, er_out.major_opcode);

    // Implementation is an errorcopy of Request with number 17 - its encoder must write 17, not Request's number.
    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try xproto.encodeImplementationError(&w2, .little, 1, .{ .bad_value = 0, .minor_opcode = 0, .major_opcode = 8 });
    try std.testing.expectEqual(@as(u8, 17), w2.buffered()[1]); // error code byte = 17
}

test "QueryTree reply round-trips with a WINDOW list" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var kids = [_]u32{ 0xAAA, 0xBBB, 0xCCC }; // WINDOW == u32 alias
    const r_in = xproto.QueryTreeReply{
        .root = 0x111,
        .parent = 0x222,
        .children_len = 3,
        .children = &kids, // *[3]u32 coerces to []align(1) const WINDOW
    };
    try xproto.encodeQueryTreeReply(&w, .little, 5, r_in);
    const bytes = w.buffered();
    // length word = 12 list bytes / 4 = 3
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[4..8], .little));
    const out = xproto.decodeQueryTreeReply(bytes);
    try std.testing.expectEqual(@as(u16, 3), out.children_len);
    try std.testing.expectEqual(@as(usize, 3), out.children.len);
    try std.testing.expectEqual(@as(u32, 0xAAA), out.children[0]);
    try std.testing.expectEqual(@as(u32, 0xCCC), out.children[2]);
}

test "GetKeyboardControl reply round-trips a sub-32-byte fixed part + CARD8 list" {
    // Regression for the CRITICAL encoder bug: the fixed part here is only 20
    // bytes (less than the 32-byte reply minimum), so a naive encoder that
    // clamps the fixed buffer up to 32 before appending the list would start
    // auto_repeats at byte 32 instead of byte 20 - prepending 12 zero bytes,
    // dropping the last 12 real ones, and writing length word 8 instead of 5.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ar: [32]u8 = undefined;
    for (&ar, 0..) |*b, i| b.* = @intCast(i);
    const r_in = xproto.GetKeyboardControlReply{
        .global_auto_repeat = 1,
        .led_mask = 0xDEADBEEF,
        .key_click_percent = 50,
        .bell_percent = 60,
        .bell_pitch = 400,
        .bell_duration = 100,
        .auto_repeats = &ar,
    };
    try xproto.encodeGetKeyboardControlReply(&w, .little, 7, r_in);
    const bytes = w.buffered();
    // total = 20 (fixed) + 32 (list, already 4-aligned) = 52 bytes;
    // length word = (52 - 32) / 4 = 5.
    try std.testing.expectEqual(@as(usize, 52), bytes.len);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, bytes[4..8], .little));
    const out = xproto.decodeGetKeyboardControlReply(bytes);
    try std.testing.expectEqual(r_in.global_auto_repeat, out.global_auto_repeat);
    try std.testing.expectEqual(r_in.led_mask, out.led_mask);
    try std.testing.expectEqual(r_in.key_click_percent, out.key_click_percent);
    try std.testing.expectEqual(r_in.bell_percent, out.bell_percent);
    try std.testing.expectEqual(r_in.bell_pitch, out.bell_pitch);
    try std.testing.expectEqual(r_in.bell_duration, out.bell_duration);
    try std.testing.expectEqual(@as(usize, 32), out.auto_repeats.len);
    try std.testing.expectEqualSlices(u8, &ar, out.auto_repeats);
}

test "decodeElement honors endian (xproto Timecoord via GetMotionEvents element)" {
    // Timecoord: time(u32), x(i16), y(i16). Build one element's 8 bytes.
    const ne = @import("builtin").cpu.arch.endian();
    var buf: [8]u8 = std.mem.zeroes([8]u8);
    std.mem.writeInt(u32, buf[0..4], 0x11223344, .big);
    std.mem.writeInt(i16, buf[4..6], 10, .big);
    std.mem.writeInt(i16, buf[6..8], 20, .big);
    const tc = xproto.Timecoord.decodeElement(&buf, .big);
    try std.testing.expectEqual(@as(u32, 0x11223344), tc.time);
    try std.testing.expectEqual(@as(i16, 10), tc.x);
    // A little-endian decode of the same bytes differs.
    const tc_le = xproto.Timecoord.decodeElement(&buf, .little);
    try std.testing.expect(tc_le.time != 0x11223344);
    _ = ne;
}

test "ListView carries endian; native default unchanged" {
    // Build 2 big-endian Timecoords, view them with .endian = .big.
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    std.mem.writeInt(u32, buf[0..4], 0x1000, .big);
    std.mem.writeInt(u32, buf[8..12], 0x2000, .big);
    var lv = xproto.ListView(xproto.Timecoord){ .bytes = &buf, .count = 2, .endian = .big };
    try std.testing.expectEqual(@as(u32, 0x1000), lv.at(0).time);
    try std.testing.expectEqual(@as(u32, 0x2000), lv.at(1).time);
}

test "decodePolyPointRequest decodes a POINT struct-element list (endian)" {
    const ne = @import("builtin").cpu.arch.endian();
    // PolyPoint (opcode 64): byte1 coordinate_mode, bytes4-7 drawable, 8-11 gc,
    // then a list of POINT (x i16, y i16) - 4 bytes each. Build 2 points big-endian.
    var buf: [12 + 8]u8 = std.mem.zeroes([12 + 8]u8);
    buf[0] = 64; // opcode
    buf[1] = 0; // coordinate_mode
    std.mem.writeInt(u32, buf[4..8], 0x111, .big); // drawable
    std.mem.writeInt(u32, buf[8..12], 0x222, .big); // gc
    std.mem.writeInt(i16, buf[12..14], 5, .big); // point[0].x
    std.mem.writeInt(i16, buf[14..16], 6, .big); // point[0].y
    std.mem.writeInt(i16, buf[16..18], 7, .big); // point[1].x
    std.mem.writeInt(i16, buf[18..20], 8, .big); // point[1].y
    const r = xproto.decodePolyPointRequest(&buf, .big);
    try std.testing.expectEqual(@as(u32, 0x111), r.drawable);
    try std.testing.expectEqual(@as(usize, 2), r.points.len());
    try std.testing.expectEqual(@as(i16, 5), r.points.at(0).x);
    try std.testing.expectEqual(@as(i16, 8), r.points.at(1).y);
    _ = ne;
}

test "decodeFreeColorsRequest decodes an implicit-length scalar list (count from buffer)" {
    // FreeColors (opcode 88): byte1 pad, cmap@4, plane_mask@8, then pixels
    // (CARD32 list with NO length field - the element count is implied by the
    // remaining request bytes). This exercises the request-decode implicit-length
    // path (Task 3's allow_implicit_len), which also un-defers scalar implicit
    // lists like this one. Endian-simple: a borrowed scalar list is raw bytes.
    const ne = @import("builtin").cpu.arch.endian();
    var buf: [20]u8 = std.mem.zeroes([20]u8);
    buf[0] = 88; // opcode
    std.mem.writeInt(u16, buf[2..4], 5, ne); // length_units = 5 (20 bytes)
    std.mem.writeInt(u32, buf[4..8], 0xC0FFEE, ne); // cmap
    std.mem.writeInt(u32, buf[8..12], 0xF, ne); // plane_mask
    std.mem.writeInt(u32, buf[12..16], 0xAAA, ne); // pixels[0]
    std.mem.writeInt(u32, buf[16..20], 0xBBB, ne); // pixels[1]
    const r = xproto.decodeFreeColorsRequest(&buf, ne);
    try std.testing.expectEqual(@as(u32, 0xC0FFEE), r.cmap);
    try std.testing.expectEqual(@as(usize, 2), r.pixels.len); // count implied by the 8 trailing bytes
    try std.testing.expectEqual(@as(u32, 0xAAA), r.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xBBB), r.pixels[1]);
}

test "encodeElement round-trips a fixed struct at both endians" {
    var buf: [8]u8 = std.mem.zeroes([8]u8);
    const tc = xproto.Timecoord{ .time = 0xAABBCCDD, .x = -3, .y = 9 };
    tc.encodeElement(&buf, .big);
    const back = xproto.Timecoord.decodeElement(&buf, .big);
    try std.testing.expectEqual(tc.time, back.time);
    try std.testing.expectEqual(tc.x, back.x);
    try std.testing.expectEqual(tc.y, back.y);
    // Little differs in the raw bytes.
    var buf2: [8]u8 = std.mem.zeroes([8]u8);
    tc.encodeElement(&buf2, .little);
    try std.testing.expect(!std.mem.eql(u8, &buf, &buf2));
}

test "QueryFont reply encodes its nested-struct fields (min_bounds Charinfo)" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var r = std.mem.zeroes(xproto.QueryFontReply);
    r.min_bounds.left_side_bearing = -7;
    r.max_bounds.character_width = 12;
    try xproto.encodeQueryFontReply(&w, .little, 3, r);
    const out = xproto.decodeQueryFontReply(w.buffered());
    try std.testing.expectEqual(@as(i16, -7), out.min_bounds.left_side_bearing);
    try std.testing.expectEqual(@as(i16, 12), out.max_bounds.character_width);
}
