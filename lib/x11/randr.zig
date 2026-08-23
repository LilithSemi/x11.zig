//! RANDR (RRXExtension) hand-encoders. randr.xml has no xproto/xcbproto
//! coverage in this generator, so -- like BIG-REQUESTS/XC-MISC before it --
//! every reply/error this server answers with is hand-encoded here rather
//! than generated. xproto-free by design (imports std only) so server_state
//! stays xproto-free too; server_main.zig's handleRandr calls these against
//! the conn's real *std.Io.Writer, conn endian, and threaded seq.
//!
//! Task 1 covers the RANDR requests with no structured list body: QueryVersion,
//! GetScreenSizeRange, GetOutputPrimary, and the shared X-error encoder (RANDR's
//! BadOutput/BadCrtc/BadMode/BadProvider). Task 2 adds the structured list
//! replies: GetScreenResources[Current]/GetOutputInfo/GetCrtcInfo/GetScreenInfo.
const std = @import("std");

/// This server's advertised RANDR protocol version (randr.xml's extension
/// major/minor as of the xcbproto snapshot this slice was written against).
/// QueryVersion always answers with this pair -- real RANDR servers clamp to
/// min(client, ours), but every 1.x client is happy with 1.6.
pub const major_version: u32 = 1;
pub const minor_version: u32 = 6;

/// This extension's event/error code bases (server_state.extensions'
/// `ExtensionInfo.first_event`/`.first_error` for RANDR pull these straight
/// from here -- single source of truth, since server_state imports this
/// std-only module with no cycle). `evt_screen_change`/`evt_crtc_change` are
/// the two RANDR events the dynamic-RANDR follow-up (Task 2) emits;
/// `first_event` itself is unused as a bare code (every real RANDR event is
/// one of the two below).
pub const first_event: u8 = 64;
pub const first_error: u8 = 128;
pub const evt_screen_change: u8 = first_event + 0;
pub const evt_crtc_change: u8 = first_event + 1;

/// RRNotify's `subCode` byte (buf[1]) for the OutputProperty sub-event --
/// `evt_crtc_change` doubles as RRNotify's generic code (65) for every
/// subCode, CrtcChange (0, `encodeCrtcChangeEvent`) included.
pub const evt_output_property_subcode: u8 = 2;

/// RANDR error codes, relative to `first_error`. Only BadOutput/BadCrtc are
/// raised this slice (GetOutputInfo/GetCrtcInfo, Task 2); BadMode/BadProvider
/// are defined here for the follow-up that raises them (SetCrtcConfig et al).
pub const bad_output: u8 = first_error + 0;
pub const bad_crtc: u8 = first_error + 1;
pub const bad_mode: u8 = first_error + 2;
pub const bad_provider: u8 = first_error + 3;

/// RANDR's fixed screen-size bounds this server advertises (GetScreenSizeRange,
/// minor 6). min matches the smallest sane screen; max is comfortably above
/// any real display this synthetic single-monitor config will ever report.
pub const min_screen_dim: u16 = 1;
pub const max_screen_dim: u16 = 16384;

const reply_base_len: usize = 32;

/// QueryVersion (minor 0) reply: fixed 32-byte reply, major/minor_version as
/// CARD32 at [8..12]/[12..16], the rest zero (length field = 0: no trailing
/// list). Client-requested major/minor (request bytes [4..8]/[8..12]) are
/// unused -- see `major_version`'s doc comment.
pub fn encodeQueryVersion(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1; // reply
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en); // length: no trailing list
    std.mem.writeInt(u32, buf[8..12], major_version, en);
    std.mem.writeInt(u32, buf[12..16], minor_version, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// GetScreenSizeRange (minor 6) reply: fixed 32-byte reply, 4 CARD16 bounds
/// at [8..16], the rest (incl. byte 1, which real RANDR leaves unused/pad
/// here) zero.
pub fn encodeGetScreenSizeRange(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en);
    std.mem.writeInt(u16, buf[8..10], min_screen_dim, en);
    std.mem.writeInt(u16, buf[10..12], min_screen_dim, en);
    std.mem.writeInt(u16, buf[12..14], max_screen_dim, en);
    std.mem.writeInt(u16, buf[14..16], max_screen_dim, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// GetOutputPrimary (minor 31) reply: fixed 32-byte reply, the primary output
/// id as CARD32 at [8..12].
pub fn encodeGetOutputPrimary(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, output: u32) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en);
    std.mem.writeInt(u32, buf[8..12], output, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// The shared RANDR X-error encoder (BadOutput/BadCrtc/BadMode/BadProvider):
/// standard 32-byte X error format -- [0]=0, [1]=code, [2..4]=seq,
/// [4..8]=bad_value, [8..10]=minor_opcode, [10]=major_opcode(130), the rest
/// zero. `code` is one of this module's `bad_*` consts (already offset by
/// the extension's first_error base -- callers pass the absolute code, not a
/// 0-based RANDR-local one).
pub fn encodeRandrError(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, code: u8, bad_value: u32, minor: u8) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 0; // error
    buf[1] = code;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], bad_value, en);
    std.mem.writeInt(u16, buf[8..10], minor, en);
    buf[10] = 130; // major_opcode: RANDR (server_state.extensions)
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// One mode entry for the variadic list encoders below (GetScreenResources/
/// GetOutputInfo, Task 1): an id + dims + its wire name ("{w}x{h}", built by
/// the caller). Mirrors server_state's `RandrMode` structurally, but is its
/// own type -- randr.zig stays std-only (no import of server_state), so
/// server_main builds this list from `Display.randrModeList()`'s entries.
pub const ModeEntry = struct { id: u32, width: u16, height: u16, name: []const u8 };

/// One ScreenSize entry for `encodeGetScreenInfo` (Task 1): dims + their
/// millimeter equivalents. Kept separate from `ModeEntry` since GetScreenInfo
/// (the RANDR 1.0 path) has no mode ids or names, only sizes -- and the mm
/// conversion (`Display.randrMm`) is server_state's to compute, not this
/// std-only module's.
pub const SizeEntry = struct { width: u16, height: u16, mm_width: u32, mm_height: u32 };

/// The single ModeInfo this static config reports (32 bytes, no trailing
/// pad -- the trailing `names` list is a separate byte run appended by each
/// caller, since GetScreenResources folds every mode's name into one shared
/// tail while GetOutputInfo doesn't emit ModeInfo names at all).
/// Layout (randr.xml): id CARD32, width/height CARD16, dot_clock CARD32=0,
/// hsync_start/end/total/skew CARD16=0 (4 fields), vsync_start/end/total
/// CARD16=0 (3 fields), name_len CARD16, mode_flags CARD32=0.
fn writeModeInfo(w: *std.Io.Writer, en: std.builtin.Endian, mode: u32, width: u16, height: u16, name_len: u16) error{WriteFailed}!void {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    std.mem.writeInt(u32, buf[0..4], mode, en);
    std.mem.writeInt(u16, buf[4..6], width, en);
    std.mem.writeInt(u16, buf[6..8], height, en);
    // dot_clock, hsync*4, vsync*3 stay zero -- this synthetic mode has no
    // real timing to report.
    std.mem.writeInt(u16, buf[26..28], name_len, en);
    // mode_flags @ [28..32] stays zero.
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// Write `n` zero bytes (`n` <= 4) -- the tail padding every variable-length
/// RANDR reply below needs to land on a 4-byte boundary.
fn writePad(w: *std.Io.Writer, n: usize) error{WriteFailed}!void {
    std.debug.assert(n <= 4);
    var buf: [4]u8 = std.mem.zeroes([4]u8);
    w.writeAll(buf[0..n]) catch return error.WriteFailed;
}

/// GetScreenResources (minor 8) / GetScreenResourcesCurrent (minor 25) --
/// both minors answer with this same reply (this server never distinguishes
/// "current" from "queried" resources). Fixed part is exactly 32 bytes (ends
/// at the CRTC list), then: CRTC list (1 id), OUTPUT list (1 id), MODE list
/// (one 32-byte ModeInfo per entry in `modes`), then every mode's name bytes
/// concatenated (in the same order). `config` is duck-typed against
/// `server_state.RandrConfig` (`.crtc`/`.output`/`.mode`/`.timestamp`) so
/// this std-only module never has to import server_state to name the type --
/// server_main.zig passes `display.randr` straight through. `modes` is
/// caller-built (server_main, from `Display.randrModeList()`); this server
/// always reports `server_state.randr_mode_count` (6) entries, but nothing
/// here hardcodes that -- the length fields are recomputed from `modes.len`.
pub fn encodeGetScreenResources(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, config: anytype, modes: []const ModeEntry) error{WriteFailed}!void {
    var names_len: usize = 0;
    for (modes) |m| names_len += m.name.len;
    const list_bytes: usize = 4 + 4 + 32 * modes.len + names_len; // crtcs + outputs + N ModeInfo + names
    const total = std.mem.alignForward(usize, reply_base_len + list_bytes, 4);
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var head: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    head[0] = 1;
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u32, head[8..12], config.timestamp, en);
    std.mem.writeInt(u32, head[12..16], config.timestamp, en); // config_timestamp: same clock, no separate one tracked yet
    std.mem.writeInt(u16, head[16..18], 1, en); // num_crtcs
    std.mem.writeInt(u16, head[18..20], 1, en); // num_outputs
    std.mem.writeInt(u16, head[20..22], @intCast(modes.len), en); // num_modes
    std.mem.writeInt(u16, head[22..24], @intCast(names_len), en); // names_len: bounded by the small fixed mode list, never overflows u16
    w.writeAll(&head) catch return error.WriteFailed;

    var id_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_buf, config.crtc, en);
    w.writeAll(&id_buf) catch return error.WriteFailed;
    std.mem.writeInt(u32, &id_buf, config.output, en);
    w.writeAll(&id_buf) catch return error.WriteFailed;

    // Every ModeInfo first (fixed 32B each), THEN every name concatenated --
    // that's the wire order RANDR's SCREEN_RESOURCES reply defines (the
    // names blob is one shared tail, not interleaved per mode).
    for (modes) |m| try writeModeInfo(w, en, m.id, m.width, m.height, @intCast(m.name.len));
    for (modes) |m| w.writeAll(m.name) catch return error.WriteFailed;

    try writePad(w, total - (reply_base_len + list_bytes));
}

/// GetOutputInfo (minor 9) reply. NOTE the fixed part here runs to offset 36
/// (not 32 -- RANDR's OUTPUT_INFO has more fixed fields than SCREEN_RESOURCES),
/// then: CRTC list (1 id), MODE list (`mode_ids`, every mode this server
/// reports -- this single output can drive any of them), OUTPUT list
/// (0 -- no clones), then the name "default". Caller has already validated
/// the requested output id matches `config.output` (else it sends BadOutput
/// instead of calling this). `config` needs `.crtc`/`.timestamp` (duck-typed,
/// see `encodeGetScreenResources`'s doc comment; `.mode` is no longer read
/// here -- the current mode's id is just `mode_ids[0]` by `randrModeList`'s
/// contract). `num_preferred` is always 1: the first entry (the live current
/// mode) is this server's one "preferred" mode.
pub fn encodeGetOutputInfo(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, config: anytype, mm_width: u32, mm_height: u32, mode_ids: []const u32) error{WriteFailed}!void {
    const name = "default";
    const fixed_len: usize = 36;
    const list_bytes: usize = 4 + 4 * mode_ids.len + 0 + name.len; // crtcs + N modes + clones(empty) + name
    const total = std.mem.alignForward(usize, fixed_len + list_bytes, 4);
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var head: [fixed_len]u8 = std.mem.zeroes([fixed_len]u8);
    head[0] = 1;
    head[1] = 0; // status: Success
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u32, head[8..12], config.timestamp, en);
    std.mem.writeInt(u32, head[12..16], config.crtc, en);
    std.mem.writeInt(u32, head[16..20], mm_width, en);
    std.mem.writeInt(u32, head[20..24], mm_height, en);
    head[24] = 0; // connection: Connected
    head[25] = 0; // subpixel_order: Unknown
    std.mem.writeInt(u16, head[26..28], 1, en); // num_crtcs
    std.mem.writeInt(u16, head[28..30], @intCast(mode_ids.len), en); // num_modes
    std.mem.writeInt(u16, head[30..32], 1, en); // num_preferred: mode_ids[0], the live current mode
    std.mem.writeInt(u16, head[32..34], 0, en); // num_clones
    std.mem.writeInt(u16, head[34..36], @intCast(name.len), en); // name_len
    w.writeAll(&head) catch return error.WriteFailed;

    var id_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_buf, config.crtc, en);
    w.writeAll(&id_buf) catch return error.WriteFailed;
    for (mode_ids) |id| {
        std.mem.writeInt(u32, &id_buf, id, en);
        w.writeAll(&id_buf) catch return error.WriteFailed;
    }
    // clones list is empty -- this single output has no siblings.
    w.writeAll(name) catch return error.WriteFailed;

    try writePad(w, total - (fixed_len + list_bytes));
}

/// GetCrtcInfo (minor 20) reply. Fixed part is exactly 32 bytes, then:
/// OUTPUT list (1 id, the one output this crtc drives) followed by the
/// POSSIBLE OUTPUT list (the same single id -- this static config has no
/// other output this crtc could ever drive). Caller has already validated
/// the requested crtc id matches `config.crtc` (else BadCrtc). `config`
/// needs `.output`/`.mode`/`.timestamp` (duck-typed).
pub fn encodeGetCrtcInfo(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, config: anytype, width: u16, height: u16) error{WriteFailed}!void {
    const list_bytes: usize = 4 + 4; // outputs + possible
    const total = reply_base_len + list_bytes; // already 4-byte aligned
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var head: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    head[0] = 1;
    head[1] = 0; // status: Success
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u32, head[8..12], config.timestamp, en);
    std.mem.writeInt(i16, head[12..14], 0, en); // x
    std.mem.writeInt(i16, head[14..16], 0, en); // y
    std.mem.writeInt(u16, head[16..18], width, en);
    std.mem.writeInt(u16, head[18..20], height, en);
    std.mem.writeInt(u32, head[20..24], config.mode, en);
    std.mem.writeInt(u16, head[24..26], 1, en); // rotation: Rotate_0/Normal
    std.mem.writeInt(u16, head[26..28], 1, en); // rotations: Rotate_0 supported only
    std.mem.writeInt(u16, head[28..30], 1, en); // num_outputs
    std.mem.writeInt(u16, head[30..32], 1, en); // num_possible_outputs
    w.writeAll(&head) catch return error.WriteFailed;

    var id_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_buf, config.output, en);
    w.writeAll(&id_buf) catch return error.WriteFailed; // outputs
    w.writeAll(&id_buf) catch return error.WriteFailed; // possible (same single output)
}

/// GetScreenInfo (minor 5) reply -- the RANDR 1.0 path: one ScreenSize per
/// entry in `sizes` (index 0 is always the live current size, by
/// `randrModeList`'s contract) and an EMPTY trailing RefreshRates list (valid
/// per randr.xml since the list length is `nInfo - nSizes`, and this reply
/// keeps `nInfo == nSizes`). `sizeID` is always 0 -- the current size is
/// always reported first. `config` needs `.timestamp` only (duck-typed).
pub fn encodeGetScreenInfo(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, root: u32, config: anytype, sizes: []const SizeEntry) error{WriteFailed}!void {
    const list_bytes: usize = 8 * sizes.len; // N ScreenSize{width,height,mwidth,mheight}; rates list is empty
    const total = reply_base_len + list_bytes; // 8*N is already a multiple of 4
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var head: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    head[0] = 1;
    head[1] = 1; // rotations: Rotate_0 supported only (SetScreenConfig's bitmask, not the current rotation)
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u32, head[8..12], root, en);
    std.mem.writeInt(u32, head[12..16], config.timestamp, en);
    std.mem.writeInt(u32, head[16..20], config.timestamp, en); // config_timestamp: same clock, no separate one tracked yet
    std.mem.writeInt(u16, head[20..22], @intCast(sizes.len), en); // nSizes
    std.mem.writeInt(u16, head[22..24], 0, en); // sizeID: index 0 (the current size) is always reported first
    std.mem.writeInt(u16, head[24..26], 1, en); // rotation: current rotation, Rotate_0
    std.mem.writeInt(u16, head[26..28], 60, en); // rate
    std.mem.writeInt(u16, head[28..30], @intCast(sizes.len), en); // nInfo == nSizes: rates list below is empty
    std.mem.writeInt(u16, head[30..32], 0, en); // pad2
    w.writeAll(&head) catch return error.WriteFailed;

    var size_buf: [8]u8 = undefined;
    for (sizes) |s| {
        std.mem.writeInt(u16, size_buf[0..2], s.width, en);
        std.mem.writeInt(u16, size_buf[2..4], s.height, en);
        std.mem.writeInt(u16, size_buf[4..6], @intCast(s.mm_width), en);
        std.mem.writeInt(u16, size_buf[6..8], @intCast(s.mm_height), en);
        w.writeAll(&size_buf) catch return error.WriteFailed;
    }
    // RefreshRates list is empty (nInfo - nSizes == 0): nothing more to write.
}

/// ScreenChangeNotify (event code `evt_screen_change` = `first_event`+0): the
/// one RANDR event every client that selected ScreenChangeNotifyMask
/// (SelectInput bit 0x1) gets on a screen-size change. Fixed 32 bytes, no
/// trailing list. Byte layout (randr.xml, per sp-server-randr-dynamic-spec.md):
/// [0]=code,[1]=rotation(CARD8),[2..4]=seq,[4..8]=timestamp,
/// [8..12]=config_timestamp,[12..16]=root,[16..20]=request_window,
/// [20..22]=sizeID,[22..24]=subpixel_order,[24..26]=width(px),[26..28]=height,
/// [28..30]=mwidth(mm),[30..32]=mheight. Unlike every reply above, byte 1
/// (rotation) is real payload, not a status/pad byte -- ScreenChangeNotify has
/// no status.
pub fn encodeScreenChangeEvent(
    w: *std.Io.Writer,
    en: std.builtin.Endian,
    seq: u16,
    rotation: u16,
    timestamp: u32,
    config_timestamp: u32,
    root: u32,
    request_window: u32,
    size_id: u16,
    subpixel: u16,
    width: u16,
    height: u16,
    mwidth: u16,
    mheight: u16,
) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = evt_screen_change;
    buf[1] = @intCast(rotation); // rotation is CARD8 on the wire despite being CARD16-typed in the xml enum
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], timestamp, en);
    std.mem.writeInt(u32, buf[8..12], config_timestamp, en);
    std.mem.writeInt(u32, buf[12..16], root, en);
    std.mem.writeInt(u32, buf[16..20], request_window, en);
    std.mem.writeInt(u16, buf[20..22], size_id, en);
    std.mem.writeInt(u16, buf[22..24], subpixel, en);
    std.mem.writeInt(u16, buf[24..26], width, en);
    std.mem.writeInt(u16, buf[26..28], height, en);
    std.mem.writeInt(u16, buf[28..30], mwidth, en);
    std.mem.writeInt(u16, buf[30..32], mheight, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// RRNotify/CrtcChange (event code `evt_crtc_change` = `first_event`+1,
/// subCode CrtcChange=0 at byte 1 -- RRNotify is a generic wrapper event RANDR
/// reuses for CrtcChange/OutputChange/OutputProperty, this server only ever
/// emits the CrtcChange sub-event). Fixed 32 bytes, no trailing list. Byte
/// layout: [0]=code,[1]=subCode(0),[2..4]=seq,[4..8]=timestamp,[8..12]=window,
/// [12..16]=crtc,[16..20]=mode,[20..22]=rotation(CARD16),[22..24]=pad,
/// [24..26]=x(INT16),[26..28]=y,[28..30]=width,[30..32]=height.
pub fn encodeCrtcChangeEvent(
    w: *std.Io.Writer,
    en: std.builtin.Endian,
    seq: u16,
    timestamp: u32,
    window: u32,
    crtc: u32,
    mode: u32,
    rotation: u16,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = evt_crtc_change;
    buf[1] = 0; // subCode: CrtcChange
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], timestamp, en);
    std.mem.writeInt(u32, buf[8..12], window, en);
    std.mem.writeInt(u32, buf[12..16], crtc, en);
    std.mem.writeInt(u32, buf[16..20], mode, en);
    std.mem.writeInt(u16, buf[20..22], rotation, en);
    // pad @ [22..24] stays zero.
    std.mem.writeInt(i16, buf[24..26], x, en);
    std.mem.writeInt(i16, buf[26..28], y, en);
    std.mem.writeInt(u16, buf[28..30], width, en);
    std.mem.writeInt(u16, buf[30..32], height, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// RRNotify/OutputProperty (event code `evt_crtc_change` = `first_event`+1,
/// the same RRNotify wrapper CrtcChange reuses, subCode
/// `evt_output_property_subcode`=2) -- fired from ChangeOutputProperty/
/// DeleteOutputProperty for clients that SelectInput'd NotifyMask
/// OutputProperty (bit 0x8). Fixed 32 bytes, no trailing list. Byte layout
/// (randr.xml's `OutputProperty` NotifyData): [0]=code,[1]=subCode(2),
/// [2..4]=seq,[4..8]=window,[8..12]=output,[12..16]=atom,[16..20]=timestamp,
/// [20]=status(CARD8: 0 NewValue/1 Deleted),[21..32]=pad11.
pub fn encodeOutputPropertyEvent(
    w: *std.Io.Writer,
    en: std.builtin.Endian,
    seq: u16,
    window: u32,
    output: u32,
    atom: u32,
    timestamp: u32,
    state: u8,
) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = evt_crtc_change; // RRNotify's generic base code (first_event+1 = 65)
    buf[1] = evt_output_property_subcode;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], window, en);
    std.mem.writeInt(u32, buf[8..12], output, en);
    std.mem.writeInt(u32, buf[12..16], atom, en);
    std.mem.writeInt(u32, buf[16..20], timestamp, en);
    buf[20] = state;
    // pad11 @ [21..32] stays zero.
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// SetCrtcConfig (minor 21) reply: fixed 32 bytes, `status` (CARD8, 0=Success/
/// 1=InvalidConfigTime/2=InvalidTime/3=Failed -- this server only ever sends
/// 0, the BadMode/BadCrtc cases are real X errors instead) at byte 1, the new
/// config `timestamp` (CARD32) at [8..12], the rest (incl. [4..8] length,
/// which stays 0: no trailing list) zero.
pub fn encodeSetCrtcConfigReply(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, status: u8, timestamp: u32) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    buf[1] = status;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en);
    std.mem.writeInt(u32, buf[8..12], timestamp, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// CreateMode (minor 16) reply: fixed 32-byte reply, the newly minted mode id
/// (`Display.createMode`'s return value) as MODE (CARD32) at [8..12], the
/// rest (a pad byte at [1], 20 trailing pad bytes, [4..8] length which stays
/// 0: no trailing list) zero. Shape mirrors `encodeGetOutputPrimary` (an
/// id-only reply).
pub fn encodeCreateModeReply(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, mode_id: u32) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en);
    std.mem.writeInt(u32, buf[8..12], mode_id, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// SetScreenConfig (minor 2) reply: fixed 32 bytes, `status` at byte 1,
/// `new_timestamp` (CARD32) at [8..12], `config_timestamp` at [12..16],
/// `root` at [16..20], `subpixel` (CARD16) at [20..22], the rest (incl.
/// [4..8] length, which stays 0) zero.
pub fn encodeSetScreenConfigReply(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, status: u8, new_timestamp: u32, config_timestamp: u32, root: u32, subpixel: u16) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    buf[1] = status;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en);
    std.mem.writeInt(u32, buf[8..12], new_timestamp, en);
    std.mem.writeInt(u32, buf[12..16], config_timestamp, en);
    std.mem.writeInt(u32, buf[16..20], root, en);
    std.mem.writeInt(u16, buf[20..22], subpixel, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// GetCrtcGammaSize (minor 22) reply: fixed 32-byte reply, `size` (CARD16) at
/// [8..10], the rest zero.
pub fn encodeGetCrtcGammaSize(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, size: u16) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en); // length: no trailing list
    std.mem.writeInt(u16, buf[8..10], size, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// GetCrtcGamma (minor 23) reply: fixed 32-byte base (`size` CARD16 at
/// [8..10]) then `red`/`green`/`blue`, `size` CARD16 entries each, in that
/// order (randr.xml's GAMMA reply lists all of red, then all of green, then
/// all of blue -- not interleaved per index). `red`/`green`/`blue` must each
/// be at least `size` long; the caller (server_state's gamma storage is
/// always exactly 256 long) never passes a shorter slice.
pub fn encodeGetCrtcGamma(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, size: u16, red: []const u16, green: []const u16, blue: []const u16) error{WriteFailed}!void {
    const list_bytes: usize = @as(usize, size) * 2 * 3; // red+green+blue, CARD16 each
    const total = std.mem.alignForward(usize, reply_base_len + list_bytes, 4);
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var head: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    head[0] = 1;
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u16, head[8..10], size, en);
    w.writeAll(&head) catch return error.WriteFailed;

    var v: [2]u8 = undefined;
    for (red[0..size]) |c| {
        std.mem.writeInt(u16, &v, c, en);
        w.writeAll(&v) catch return error.WriteFailed;
    }
    for (green[0..size]) |c| {
        std.mem.writeInt(u16, &v, c, en);
        w.writeAll(&v) catch return error.WriteFailed;
    }
    for (blue[0..size]) |c| {
        std.mem.writeInt(u16, &v, c, en);
        w.writeAll(&v) catch return error.WriteFailed;
    }

    try writePad(w, total - (reply_base_len + list_bytes));
}

/// One MonitorInfo entry `encodeGetMonitors` emits, xproto-free (server_main
/// builds this either from `Display.randr_monitors` -- SetMonitor's client
/// data -- or from the synthetic single-monitor default when that list is
/// empty). Mirrors `ModeEntry`'s role for GetScreenResources's mode list:
/// randr.zig stays a pure wire-encoder with no Display/AtomTable dependency.
pub const MonitorEntry = struct {
    name: u32,
    primary: bool,
    automatic: bool,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    mm_width: u32,
    mm_height: u32,
    outputs: []const u32,
};

/// GetMonitors (minor 42) reply, RANDR 1.5: fixed 32-byte base (`timestamp`
/// CARD32 at [8..12], nMonitors CARD32 at [12..16] = `monitors.len`, nOutputs
/// CARD32 at [16..20] = the sum of every monitor's output count, pad12), then
/// one MonitorInfo per entry back-to-back. MonitorInfo layout (randr.xml):
/// name ATOM(4), primary BOOL(1), automatic BOOL(1), nOutput CARD16(2), x/y
/// INT16(2 each), width/height CARD16(2 each), width_mm/height_mm CARD32(4
/// each), then outputs[nOutput] CARD32. Each entry's fixed part is 24 bytes
/// (already 4-aligned); its output list is `4*nOutput` bytes (also
/// 4-aligned), so only the reply's OVERALL length can ever need a trailing
/// pad (there isn't one in practice since every per-entry size is already a
/// multiple of 4, but `writePad` covers it defensively -- mirrors every other
/// variadic encoder in this file).
pub fn encodeGetMonitors(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, timestamp: u32, monitors: []const MonitorEntry) error{WriteFailed}!void {
    var n_outputs: usize = 0;
    var monitor_bytes: usize = 0;
    for (monitors) |m| {
        n_outputs += m.outputs.len;
        monitor_bytes += 24 + m.outputs.len * 4;
    }
    const total = std.mem.alignForward(usize, reply_base_len + monitor_bytes, 4);
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var head: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    head[0] = 1;
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u32, head[8..12], timestamp, en);
    std.mem.writeInt(u32, head[12..16], @intCast(monitors.len), en); // nMonitors
    std.mem.writeInt(u32, head[16..20], @intCast(n_outputs), en); // nOutputs: summed across every monitor
    w.writeAll(&head) catch return error.WriteFailed;

    for (monitors) |m| {
        var mi: [24]u8 = std.mem.zeroes([24]u8);
        std.mem.writeInt(u32, mi[0..4], m.name, en);
        mi[4] = @intFromBool(m.primary);
        mi[5] = @intFromBool(m.automatic);
        std.mem.writeInt(u16, mi[6..8], @intCast(m.outputs.len), en); // nOutput
        std.mem.writeInt(i16, mi[8..10], m.x, en);
        std.mem.writeInt(i16, mi[10..12], m.y, en);
        std.mem.writeInt(u16, mi[12..14], m.width, en);
        std.mem.writeInt(u16, mi[14..16], m.height, en);
        std.mem.writeInt(u32, mi[16..20], m.mm_width, en);
        std.mem.writeInt(u32, mi[20..24], m.mm_height, en);
        w.writeAll(&mi) catch return error.WriteFailed;

        for (m.outputs) |o| {
            var out_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &out_buf, o, en);
            w.writeAll(&out_buf) catch return error.WriteFailed;
        }
    }

    try writePad(w, total - (reply_base_len + monitor_bytes));
}

test "encodeQueryVersion: major/minor at the right offsets, seq threaded, no trailing length" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeQueryVersion(&w, .big, 0x1234);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[8..12], .big));
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, out[12..16], .big));
    for (out[16..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "encodeGetScreenSizeRange: min/max CARD16s at the documented offsets" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetScreenSizeRange(&w, .little, 7);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[8..10], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[10..12], .little));
    try std.testing.expectEqual(@as(u16, 16384), std.mem.readInt(u16, out[12..14], .little));
    try std.testing.expectEqual(@as(u16, 16384), std.mem.readInt(u16, out[14..16], .little));
    for (out[16..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "encodeGetOutputPrimary: output id at [8..12], cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetOutputPrimary(&w, .big, 3, 0xf0000002);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out[8..12], .big));

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeGetOutputPrimary(&w2, .little, 3, 0xf0000002);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out2[8..12], .little));
}

test "encodeRandrError: BadOutput/BadCrtc carry code/bad_value/minor/major" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeRandrError(&w, .little, 42, bad_output, 0xDEAD, 9);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u8, 128), out[1]);
    try std.testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 0xDEAD), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, out[8..10], .little));
    try std.testing.expectEqual(@as(u8, 130), out[10]);
    for (out[11..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeRandrError(&w2, .little, 1, bad_crtc, 0xBEEF, 20);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u8, 129), out2[1]);
    try std.testing.expectEqual(@as(u32, 0xBEEF), std.mem.readInt(u32, out2[4..8], .little));
    try std.testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, out2[8..10], .little));
}

const test_config = struct {
    crtc: u32 = 0xf0000001,
    output: u32 = 0xf0000002,
    mode: u32 = 0xf0000003,
    timestamp: u32 = 1,
}{};

/// The 6-mode list every server_state.randrModeList() call produces: index 0
/// is the "current" mode (config.mode, live 640x480 in these tests), 1..5
/// are the fixed alt modes (server_state.randr_alt_modes) -- kept in sync by
/// hand since randr.zig can't import server_state's consts (std-only).
const test_modes = [_]ModeEntry{
    .{ .id = 0xf0000003, .width = 640, .height = 480, .name = "640x480" },
    .{ .id = 0xf0001000, .width = 800, .height = 600, .name = "800x600" },
    .{ .id = 0xf0001001, .width = 1024, .height = 768, .name = "1024x768" },
    .{ .id = 0xf0001002, .width = 1280, .height = 720, .name = "1280x720" },
    .{ .id = 0xf0001003, .width = 1280, .height = 1024, .name = "1280x1024" },
    .{ .id = 0xf0001004, .width = 1920, .height = 1080, .name = "1920x1080" },
};

const test_mode_ids = [_]u32{ 0xf0000003, 0xf0001000, 0xf0001001, 0xf0001002, 0xf0001003, 0xf0001004 };

const test_sizes = [_]SizeEntry{
    .{ .width = 640, .height = 480, .mm_width = 169, .mm_height = 127 },
    .{ .width = 800, .height = 600, .mm_width = 212, .mm_height = 159 },
    .{ .width = 1024, .height = 768, .mm_width = 271, .mm_height = 203 },
    .{ .width = 1280, .height = 720, .mm_width = 339, .mm_height = 191 },
    .{ .width = 1280, .height = 1024, .mm_width = 339, .mm_height = 271 },
    .{ .width = 1920, .height = 1080, .mm_width = 508, .mm_height = 286 },
};

test "encodeGetScreenResources: 6 modes, length field, names concatenated + names_len, ModeInfo exactly 32 bytes each" {
    var buf: [320]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetScreenResources(&w, .big, 5, test_config, &test_modes);
    const out = w.buffered();

    // 32 (base) + 4 (crtcs) + 4 (outputs) + 6*32 (ModeInfo) + 48 (names: 7+7+8+8+9+9) = 280, already 4-byte aligned.
    try std.testing.expectEqual(@as(usize, 280), out.len);
    try std.testing.expectEqual(@as(usize, 0), out.len % 4); // whole reply is 4-byte aligned
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, out[2..4], .big));
    // length is in 4-byte units of the bytes AFTER the 32-byte base: (280-32)/4 = 62.
    try std.testing.expectEqual(@as(u32, 62), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[8..12], .big)); // timestamp
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[12..16], .big)); // config_timestamp
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[16..18], .big)); // num_crtcs
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[18..20], .big)); // num_outputs
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, out[20..22], .big)); // num_modes
    try std.testing.expectEqual(@as(u16, 48), std.mem.readInt(u16, out[22..24], .big)); // names_len

    // CRTC list (1 id) @ [32..36], OUTPUT list (1 id) @ [36..40].
    try std.testing.expectEqual(@as(u32, 0xf0000001), std.mem.readInt(u32, out[32..36], .big));
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out[36..40], .big));

    // 6 ModeInfo entries @ [40..232], each exactly 32 bytes, ids/dims/name_len in order.
    for (test_modes, 0..) |m, i| {
        const off = 40 + i * 32;
        const mi = out[off .. off + 32];
        try std.testing.expectEqual(m.id, std.mem.readInt(u32, mi[0..4], .big));
        try std.testing.expectEqual(m.width, std.mem.readInt(u16, mi[4..6], .big));
        try std.testing.expectEqual(m.height, std.mem.readInt(u16, mi[6..8], .big));
        try std.testing.expectEqual(@as(u16, @intCast(m.name.len)), std.mem.readInt(u16, mi[26..28], .big));
    }

    // names concatenated @ [232..280], no gaps between entries.
    try std.testing.expectEqualStrings("640x480800x6001024x7681280x7201280x10241920x1080", out[232..280]);
}

test "encodeGetOutputInfo: fixed part runs to 36, 6 mode ids in the trailing list, num_preferred=1, cross-endian" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetOutputInfo(&w, .little, 9, test_config, 169, 127, &test_mode_ids);
    const out = w.buffered();

    // 36 (fixed) + 4 (crtcs) + 24 (6 modes) + 0 (clones) + 7 ("default") = 71, padded to 72.
    try std.testing.expectEqual(@as(usize, 72), out.len);
    try std.testing.expectEqual(@as(usize, 0), out.len % 4);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[1]); // status: Success
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, out[4..8], .little)); // (72-32)/4 = 10
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[8..12], .little)); // timestamp
    try std.testing.expectEqual(@as(u32, 0xf0000001), std.mem.readInt(u32, out[12..16], .little)); // crtc
    try std.testing.expectEqual(@as(u32, 169), std.mem.readInt(u32, out[16..20], .little)); // mm_width
    try std.testing.expectEqual(@as(u32, 127), std.mem.readInt(u32, out[20..24], .little)); // mm_height
    try std.testing.expectEqual(@as(u8, 0), out[24]); // connection: Connected
    try std.testing.expectEqual(@as(u8, 0), out[25]); // subpixel_order
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[26..28], .little)); // num_crtcs
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, out[28..30], .little)); // num_modes
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[30..32], .little)); // num_preferred
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[32..34], .little)); // num_clones
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, out[34..36], .little)); // name_len ("default")

    try std.testing.expectEqual(@as(u32, 0xf0000001), std.mem.readInt(u32, out[36..40], .little)); // crtcs[0]
    for (test_mode_ids, 0..) |id, i| {
        const off = 40 + i * 4;
        try std.testing.expectEqual(id, std.mem.readInt(u32, out[off..][0..4], .little));
    }
    // clones list is empty: name starts right after the modes list ([40..64]).
    try std.testing.expectEqualStrings("default", out[64..71]);
    try std.testing.expectEqual(@as(u8, 0), out[71]); // pad
}

test "encodeGetCrtcInfo: length field, output list (outputs + possible), ids/size at the right offsets" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetCrtcInfo(&w, .big, 3, test_config, 640, 480);
    const out = w.buffered();

    // 32 (fixed) + 4 (outputs) + 4 (possible) = 40, already 4-byte aligned.
    try std.testing.expectEqual(@as(usize, 40), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[1]); // status: Success
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[4..8], .big)); // (40-32)/4 = 2
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[8..12], .big)); // timestamp
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[12..14], .big)); // x
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[14..16], .big)); // y
    try std.testing.expectEqual(@as(u16, 640), std.mem.readInt(u16, out[16..18], .big)); // width
    try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, out[18..20], .big)); // height
    try std.testing.expectEqual(@as(u32, 0xf0000003), std.mem.readInt(u32, out[20..24], .big)); // mode
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[24..26], .big)); // rotation
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[26..28], .big)); // rotations
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[28..30], .big)); // num_outputs
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[30..32], .big)); // num_possible_outputs
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out[32..36], .big)); // outputs[0]
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out[36..40], .big)); // possible[0]
}

test "encodeGetScreenInfo: 6 ScreenSizes, sizeID=0, nInfo==nSizes, empty rates list" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetScreenInfo(&w, .little, 8, 0x100, test_config, &test_sizes);
    const out = w.buffered();

    // 32 (fixed) + 6*8 (ScreenSize) = 80; rates list is empty (nInfo == nSizes).
    try std.testing.expectEqual(@as(usize, 80), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 1), out[1]); // rotations bitmask: Rotate_0 only
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, out[4..8], .little)); // (80-32)/4 = 12
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, out[8..12], .little)); // root
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[12..16], .little)); // timestamp
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[16..20], .little)); // config_timestamp
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, out[20..22], .little)); // nSizes
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[22..24], .little)); // sizeID: current is always index 0
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[24..26], .little)); // rotation
    try std.testing.expectEqual(@as(u16, 60), std.mem.readInt(u16, out[26..28], .little)); // rate
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, out[28..30], .little)); // nInfo == nSizes
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[30..32], .little)); // pad2

    // 6 ScreenSize{width,height,mwidth,mheight} entries @ [32..80], in order.
    for (test_sizes, 0..) |s, i| {
        const off = 32 + i * 8;
        try std.testing.expectEqual(s.width, std.mem.readInt(u16, out[off..][0..2], .little));
        try std.testing.expectEqual(s.height, std.mem.readInt(u16, out[off + 2 ..][0..2], .little));
        try std.testing.expectEqual(@as(u16, @intCast(s.mm_width)), std.mem.readInt(u16, out[off + 4 ..][0..2], .little));
        try std.testing.expectEqual(@as(u16, @intCast(s.mm_height)), std.mem.readInt(u16, out[off + 6 ..][0..2], .little));
    }
}

test "encodeScreenChangeEvent: exactly 32 bytes, code 64, every field at its documented offset, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeScreenChangeEvent(&w, .big, 7, 1, 100, 5, 0x2a, 0x2b, 3, 0, 1024, 768, 271, 203);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(evt_screen_change, out[0]);
    try std.testing.expectEqual(@as(u8, 1), out[1]); // rotation
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 100), std.mem.readInt(u32, out[4..8], .big)); // timestamp
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, out[8..12], .big)); // config_timestamp
    try std.testing.expectEqual(@as(u32, 0x2a), std.mem.readInt(u32, out[12..16], .big)); // root
    try std.testing.expectEqual(@as(u32, 0x2b), std.mem.readInt(u32, out[16..20], .big)); // request_window
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[20..22], .big)); // sizeID
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[22..24], .big)); // subpixel_order
    try std.testing.expectEqual(@as(u16, 1024), std.mem.readInt(u16, out[24..26], .big)); // width
    try std.testing.expectEqual(@as(u16, 768), std.mem.readInt(u16, out[26..28], .big)); // height
    try std.testing.expectEqual(@as(u16, 271), std.mem.readInt(u16, out[28..30], .big)); // mwidth
    try std.testing.expectEqual(@as(u16, 203), std.mem.readInt(u16, out[30..32], .big)); // mheight

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeScreenChangeEvent(&w2, .little, 7, 1, 100, 5, 0x2a, 0x2b, 3, 0, 1024, 768, 271, 203);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u32, 0x2a), std.mem.readInt(u32, out2[12..16], .little));
    try std.testing.expectEqual(@as(u16, 1024), std.mem.readInt(u16, out2[24..26], .little));
}

test "encodeCrtcChangeEvent: exactly 32 bytes, code 65, subCode 0, every field at its documented offset, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeCrtcChangeEvent(&w, .little, 9, 200, 0x100, 0xf0000001, 0xf0001004, 1, -1, -2, 1920, 1080);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(evt_crtc_change, out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[1]); // subCode: CrtcChange
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 200), std.mem.readInt(u32, out[4..8], .little)); // timestamp
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, out[8..12], .little)); // window
    try std.testing.expectEqual(@as(u32, 0xf0000001), std.mem.readInt(u32, out[12..16], .little)); // crtc
    try std.testing.expectEqual(@as(u32, 0xf0001004), std.mem.readInt(u32, out[16..20], .little)); // mode
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[20..22], .little)); // rotation
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[22..24], .little)); // pad
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, out[24..26], .little)); // x
    try std.testing.expectEqual(@as(i16, -2), std.mem.readInt(i16, out[26..28], .little)); // y
    try std.testing.expectEqual(@as(u16, 1920), std.mem.readInt(u16, out[28..30], .little)); // width
    try std.testing.expectEqual(@as(u16, 1080), std.mem.readInt(u16, out[30..32], .little)); // height

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeCrtcChangeEvent(&w2, .big, 9, 200, 0x100, 0xf0000001, 0xf0001004, 1, -1, -2, 1920, 1080);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u32, 0xf0001004), std.mem.readInt(u32, out2[16..20], .big));
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, out2[24..26], .big));
}

test "encodeOutputPropertyEvent: exactly 32 bytes, code 65, subCode 2, every field at its documented offset, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeOutputPropertyEvent(&w, .little, 11, 0x100, 0xf0000002, 0x200, 300, 0);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(evt_crtc_change, out[0]); // RRNotify's generic code (65), same base CrtcChange uses
    try std.testing.expectEqual(evt_output_property_subcode, out[1]);
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, out[4..8], .little)); // window
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out[8..12], .little)); // output
    try std.testing.expectEqual(@as(u32, 0x200), std.mem.readInt(u32, out[12..16], .little)); // atom
    try std.testing.expectEqual(@as(u32, 300), std.mem.readInt(u32, out[16..20], .little)); // timestamp
    try std.testing.expectEqual(@as(u8, 0), out[20]); // state: NewValue
    for (out[21..32]) |b| try std.testing.expectEqual(@as(u8, 0), b); // pad11

    // Deleted (state 1) + cross-endian, atom/output at the right offsets regardless of endian.
    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeOutputPropertyEvent(&w2, .big, 11, 0x100, 0xf0000002, 0x200, 300, 1);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u8, 1), out2[20]); // state: Deleted
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out2[8..12], .big));
    try std.testing.expectEqual(@as(u32, 0x200), std.mem.readInt(u32, out2[12..16], .big));
}

test "encodeSetCrtcConfigReply: status + timestamp at the documented offsets, no trailing length, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeSetCrtcConfigReply(&w, .big, 11, 0, 42);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[1]); // status: Success
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, out[8..12], .big));
    for (out[12..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeSetCrtcConfigReply(&w2, .little, 11, 0, 42);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, out2[8..12], .little));
}

test "encodeCreateModeReply: mode id at [8..12], 32 bytes, no trailing length, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeCreateModeReply(&w, .big, 11, 0xf0002000);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 0xf0002000), std.mem.readInt(u32, out[8..12], .big));
    for (out[12..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeCreateModeReply(&w2, .little, 11, 0xf0002000);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u32, 0xf0002000), std.mem.readInt(u32, out2[8..12], .little));
}

test "encodeSetScreenConfigReply: status/new_timestamp/config_timestamp/root/subpixel at the documented offsets, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeSetScreenConfigReply(&w, .little, 3, 0, 7, 5, 0x100, 0);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[1]); // status: Success
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[8..12], .little)); // new_timestamp
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, out[12..16], .little)); // config_timestamp
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, out[16..20], .little)); // root
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[20..22], .little)); // subpixel
    for (out[22..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeSetScreenConfigReply(&w2, .big, 3, 0, 7, 5, 0x100, 0);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, out2[16..20], .big));
}

test "encodeGetCrtcGammaSize: size at [8..10], no trailing length, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetCrtcGammaSize(&w, .big, 4, 256);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u16, 256), std.mem.readInt(u16, out[8..10], .big));
    for (out[10..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeGetCrtcGammaSize(&w2, .little, 4, 256);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u16, 256), std.mem.readInt(u16, out2[8..10], .little));
}

test "encodeGetCrtcGamma: 3 ramps in red/green/blue order, correct length field, cross-endian" {
    var red: [4]u16 = .{ 0, 1, 2, 3 };
    var green: [4]u16 = .{ 10, 11, 12, 13 };
    var blue: [4]u16 = .{ 20, 21, 22, 23 };

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetCrtcGamma(&w, .big, 6, 4, &red, &green, &blue);
    const out = w.buffered();

    // 32 (base) + 4*2*3 (red+green+blue, CARD16 each) = 56, already 4-aligned.
    try std.testing.expectEqual(@as(usize, 56), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, out[4..8], .big)); // (56-32)/4 = 6
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, out[8..10], .big)); // size

    for (red, 0..) |c, i| try std.testing.expectEqual(c, std.mem.readInt(u16, out[32 + i * 2 ..][0..2], .big));
    for (green, 0..) |c, i| try std.testing.expectEqual(c, std.mem.readInt(u16, out[40 + i * 2 ..][0..2], .big));
    for (blue, 0..) |c, i| try std.testing.expectEqual(c, std.mem.readInt(u16, out[48 + i * 2 ..][0..2], .big));

    // Odd size needs a real trailing pad: 3*2*3 = 18 bytes -> total 50, padded to 52.
    var red3: [3]u16 = .{ 1, 2, 3 };
    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeGetCrtcGamma(&w2, .little, 1, 3, &red3, &red3, &red3);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(usize, 52), out2.len);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, out2[4..8], .little)); // (52-32)/4 = 5
}

/// ListOutputProperties (minor 10) reply: fixed 32-byte base, `num_atoms`
/// CARD16@[8..10] (the rest of the base -- pad22 -- stays zero), then the
/// property atoms themselves as a CARD32 list. `atoms.len` is always small
/// (this server's single output only ever holds a handful of properties), so
/// `atoms.len * 4` is already 4-byte aligned -- no trailing pad byte run is
/// ever needed.
pub fn encodeListOutputProperties(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, atoms: []const u32) error{WriteFailed}!void {
    const length: u32 = @intCast(atoms.len); // atoms.len CARD32s == atoms.len*4 bytes == atoms.len 4-byte units
    var head: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    head[0] = 1;
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u16, head[8..10], @intCast(atoms.len), en);
    w.writeAll(&head) catch return error.WriteFailed;

    var buf: [4]u8 = undefined;
    for (atoms) |a| {
        std.mem.writeInt(u32, &buf, a, en);
        w.writeAll(&buf) catch return error.WriteFailed;
    }
}

/// QueryOutputProperty (minor 11) reply: fixed 32-byte reply, `pending`/
/// `range`/`immutable` BOOLs at [8]/[9]/[10] (this server always reports a
/// plain, non-range, non-immutable property -- ConfigureOutputProperty's
/// range config is accepted-and-ignored, see handleRandr), an EMPTY trailing
/// validValues list (length 0).
pub fn encodeQueryOutputProperty(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en); // length: no trailing list (empty validValues)
    buf[8] = 0; // pending
    buf[9] = 0; // range
    buf[10] = 0; // immutable
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// GetOutputProperty (minor 15) reply -- mirrors the core GetProperty reply
/// shape (xproto's encodeGetPropertyReply) but at RANDR's own byte offsets:
/// `format` CARD8@[1], `type` ATOM@[8..12], `bytes_after` CARD32@[12..16],
/// `num_items` CARD32@[16..20], pad12, then `data` (`num_items*format/8`
/// bytes, zero-padded to a 4-byte boundary). `data`'s length is the caller's
/// (server_state's `GetPropResult.value`) responsibility to match `num_items`.
pub fn encodeGetOutputProperty(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, format: u8, ptype: u32, bytes_after: u32, num_items: u32, data: []const u8) error{WriteFailed}!void {
    const body_end: usize = reply_base_len + data.len;
    const total = std.mem.alignForward(usize, body_end, 4);
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var head: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    head[0] = 1;
    head[1] = format;
    std.mem.writeInt(u16, head[2..4], seq, en);
    std.mem.writeInt(u32, head[4..8], length, en);
    std.mem.writeInt(u32, head[8..12], ptype, en);
    std.mem.writeInt(u32, head[12..16], bytes_after, en);
    std.mem.writeInt(u32, head[16..20], num_items, en);
    w.writeAll(&head) catch return error.WriteFailed;
    w.writeAll(data) catch return error.WriteFailed;

    try writePad(w, total - body_end);
}

test "encodeListOutputProperties: num_atoms at [8..10], atoms list, length==atoms.len, cross-endian" {
    const atoms = [_]u32{ 39, 0x100 };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeListOutputProperties(&w, .big, 4, &atoms);
    const out = w.buffered();

    try std.testing.expectEqual(@as(usize, 40), out.len); // 32 + 2*4
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[4..8], .big)); // length: 2 CARD32s
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[8..10], .big)); // num_atoms
    try std.testing.expectEqual(@as(u32, 39), std.mem.readInt(u32, out[32..36], .big));
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, out[36..40], .big));

    var buf2: [32]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeListOutputProperties(&w2, .little, 1, &.{});
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(usize, 32), out2.len); // empty list: base only
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out2[4..8], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out2[8..10], .little));
}

test "encodeQueryOutputProperty: pending/range/immutable all 0, no trailing length" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeQueryOutputProperty(&w, .little, 9);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqual(@as(u8, 0), out[8]);
    try std.testing.expectEqual(@as(u8, 0), out[9]);
    try std.testing.expectEqual(@as(u8, 0), out[10]);
}

test "encodeGetOutputProperty: format/type/bytes_after/num_items at the documented offsets, data + pad, cross-endian" {
    const data = "hi!"; // 3 bytes -> padded to 4
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetOutputProperty(&w, .big, 3, 8, 31, 0, 3, data);
    const out = w.buffered();

    try std.testing.expectEqual(@as(usize, 36), out.len); // 32 + pad(3->4)
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 8), out[1]); // format
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[4..8], .big)); // (36-32)/4 = 1
    try std.testing.expectEqual(@as(u32, 31), std.mem.readInt(u32, out[8..12], .big)); // type
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[12..16], .big)); // bytes_after
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[16..20], .big)); // num_items
    try std.testing.expectEqualStrings("hi!", out[32..35]);

    // A 128-byte EDID-sized blob (format 8): length = 128/4 = 32, no pad needed.
    var edid: [128]u8 = undefined;
    for (&edid, 0..) |*b, i| b.* = @intCast(i % 256);
    var buf2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeGetOutputProperty(&w2, .little, 5, 8, 19, 0, 128, &edid);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(usize, 160), out2.len); // 32 + 128
    try std.testing.expectEqual(@as(u32, 32), std.mem.readInt(u32, out2[4..8], .little));
    try std.testing.expectEqualSlices(u8, &edid, out2[32..160]);
}

test "encodeGetMonitors: nMonitors/nOutputs=1, one MonitorInfo w/ output id + screen size, length=(total-32)/4" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const outputs = [_]u32{0xf0000002};
    const monitors = [_]MonitorEntry{.{
        .name = 0x50,
        .primary = true,
        .automatic = true,
        .x = 0,
        .y = 0,
        .width = 640,
        .height = 480,
        .mm_width = 169,
        .mm_height = 127,
        .outputs = &outputs,
    }};
    try encodeGetMonitors(&w, .big, 2, 1, &monitors);
    const out = w.buffered();

    // 32 (base) + 24 (MonitorInfo fixed) + 4 (1 output id) = 60, already 4-aligned.
    try std.testing.expectEqual(@as(usize, 60), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[4..8], .big)); // (60-32)/4 = 7
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[8..12], .big)); // timestamp
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[12..16], .big)); // nMonitors
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[16..20], .big)); // nOutputs

    // MonitorInfo @ [32..60].
    try std.testing.expectEqual(@as(u32, 0x50), std.mem.readInt(u32, out[32..36], .big)); // name atom
    try std.testing.expectEqual(@as(u8, 1), out[36]); // primary
    try std.testing.expectEqual(@as(u8, 1), out[37]); // automatic
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[38..40], .big)); // nOutput
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[40..42], .big)); // x
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[42..44], .big)); // y
    try std.testing.expectEqual(@as(u16, 640), std.mem.readInt(u16, out[44..46], .big)); // width
    try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, out[46..48], .big)); // height
    try std.testing.expectEqual(@as(u32, 169), std.mem.readInt(u32, out[48..52], .big)); // width_mm
    try std.testing.expectEqual(@as(u32, 127), std.mem.readInt(u32, out[52..56], .big)); // height_mm
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out[56..60], .big)); // outputs[0]
}

test "encodeGetMonitors: N monitors sum nOutputs across entries and lay out back-to-back" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const outs_a = [_]u32{ 0xf0000002, 0xf0000010 };
    const outs_b = [_]u32{0xf0000011};
    const monitors = [_]MonitorEntry{
        .{ .name = 0x10, .primary = true, .automatic = false, .x = 10, .y = 20, .width = 800, .height = 600, .mm_width = 300, .mm_height = 200, .outputs = &outs_a },
        .{ .name = 0x20, .primary = false, .automatic = true, .x = 810, .y = 0, .width = 1024, .height = 768, .mm_width = 340, .mm_height = 270, .outputs = &outs_b },
    };
    try encodeGetMonitors(&w, .little, 9, 42, &monitors);
    const out = w.buffered();

    // base 32 + monitor A (24 + 8) + monitor B (24 + 4) = 32 + 32 + 28 = 92.
    try std.testing.expectEqual(@as(usize, 92), out.len);
    try std.testing.expectEqual(@as(u32, (92 - 32) / 4), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, out[8..12], .little)); // timestamp
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[12..16], .little)); // nMonitors
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[16..20], .little)); // nOutputs: 2 + 1

    // Monitor A @ [32..64).
    try std.testing.expectEqual(@as(u32, 0x10), std.mem.readInt(u32, out[32..36], .little));
    try std.testing.expectEqual(@as(u8, 1), out[36]); // primary
    try std.testing.expectEqual(@as(u8, 0), out[37]); // automatic
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[38..40], .little)); // nOutput
    try std.testing.expectEqual(@as(u32, 0xf0000002), std.mem.readInt(u32, out[56..60], .little));
    try std.testing.expectEqual(@as(u32, 0xf0000010), std.mem.readInt(u32, out[60..64], .little));

    // Monitor B @ [64..92).
    try std.testing.expectEqual(@as(u32, 0x20), std.mem.readInt(u32, out[64..68], .little));
    try std.testing.expectEqual(@as(u8, 0), out[68]); // primary
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[70..72], .little)); // nOutput
    try std.testing.expectEqual(@as(u16, 1024), std.mem.readInt(u16, out[76..78], .little)); // width
    try std.testing.expectEqual(@as(u32, 0xf0000011), std.mem.readInt(u32, out[88..92], .little));
}

test "encodeGetMonitors: empty monitor list -> nMonitors=0, nOutputs=0, no trailing bytes" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetMonitors(&w, .big, 0, 0, &.{});
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[12..16], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[16..20], .big));
}

/// GetProviders (minor 32) reply: this server has no GPU providers, so this
/// always reports zero -- fixed 32-byte base (`timestamp` CARD32@[8..12],
/// `num_providers` CARD16=0@[12..14], pad18), no trailing list.
pub fn encodeGetProviders(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, timestamp: u32) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en); // length: no trailing providers list
    std.mem.writeInt(u32, buf[8..12], timestamp, en);
    std.mem.writeInt(u16, buf[12..14], 0, en); // num_providers: no GPU providers in this software-render model
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// GetPanning (minor 28) reply: this server never pans (no panning support),
/// so every field beyond `status`/`timestamp` stays zero. 36 bytes total
/// (length = (36-32)/4 = 1): status CARD8@[1] (Success), `timestamp`
/// CARD32@[8..12], left/top/width/height/track_left/track_top/track_width/
/// track_height CARD16 and border_left/top/right/bottom INT16 all
/// zero@[12..36].
pub fn encodeGetPanning(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, timestamp: u32) error{WriteFailed}!void {
    var buf: [36]u8 = std.mem.zeroes([36]u8);
    buf[0] = 1;
    buf[1] = 0; // status: Success
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 1, en); // length: (36-32)/4 = 1
    std.mem.writeInt(u32, buf[8..12], timestamp, en);
    // Every panning field @ [12..36] stays zero -- no panning configured.
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// SetPanning (minor 29) reply: fixed 32 bytes, `status` CARD8@[1] (this
/// server always accepts the no-op request with Success), `timestamp`
/// CARD32@[8..12], the rest (incl. [4..8] length, which stays 0) zero.
pub fn encodeSetPanningReply(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, status: u8, timestamp: u32) error{WriteFailed}!void {
    var buf: [reply_base_len]u8 = std.mem.zeroes([reply_base_len]u8);
    buf[0] = 1;
    buf[1] = status;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], 0, en);
    std.mem.writeInt(u32, buf[8..12], timestamp, en);
    w.writeAll(&buf) catch return error.WriteFailed;
}

/// Write a TRANSFORM (9 FIXED 16.16, row-major 3x3 = 36 bytes) at `buf[0..36]`.
fn writeTransform(buf: *[36]u8, en: std.builtin.Endian, matrix: [9]u32) void {
    for (matrix, 0..) |v, i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], v, en);
}

/// GetCrtcTransform (minor 27) reply: this server stores exactly one matrix
/// per crtc (`Display.randr_transform`, `Display.setCrtcTransform`) and
/// reports it as BOTH the pending and current transform -- there's no
/// separate "pending vs. applied" distinction in a stored-only model. Fixed
/// 96 bytes (length 16): pad1, `pending_transform` (36)@[8..44],
/// `has_transforms` BOOL=1@[44] (SetCrtcTransform is always honored), pad3,
/// `current_transform` (36)@[48..84], pad4, then
/// pending_len/pending_nparams/current_len/current_nparams CARD16 all
/// 0@[88..96] (no filter name/params -- this server never advertises any
/// named transform filter, only the raw matrix).
pub fn encodeGetCrtcTransform(w: *std.Io.Writer, en: std.builtin.Endian, seq: u16, transform: [9]u32) error{WriteFailed}!void {
    const total: usize = 96;
    const length: u32 = @intCast((total - reply_base_len) / 4);

    var buf: [total]u8 = std.mem.zeroes([total]u8);
    buf[0] = 1;
    std.mem.writeInt(u16, buf[2..4], seq, en);
    std.mem.writeInt(u32, buf[4..8], length, en);
    writeTransform(buf[8..44], en, transform);
    buf[44] = 1; // has_transforms: SetCrtcTransform is always honored
    writeTransform(buf[48..84], en, transform);
    // pending_len/pending_nparams/current_len/current_nparams @ [88..96] stay
    // zero: no named filter, no extra params -- empty trailing lists.
    w.writeAll(&buf) catch return error.WriteFailed;
}

test "encodeGetProviders: num_providers=0 at [12..14], timestamp threaded, no trailing list" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetProviders(&w, .big, 4, 0x100);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, out[8..12], .big)); // timestamp
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[12..14], .big)); // num_providers
    for (out[14..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "encodeGetPanning: status 0 + timestamp, every panning field zero, cross-endian" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetPanning(&w, .little, 2, 77);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 36), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[1]); // status: Success
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[2..4], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[4..8], .little)); // (36-32)/4 = 1
    try std.testing.expectEqual(@as(u32, 77), std.mem.readInt(u32, out[8..12], .little));
    for (out[12..36]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "encodeSetPanningReply: status + timestamp at the documented offsets, no trailing length" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeSetPanningReply(&w, .big, 9, 0, 55);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 0), out[1]); // status
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 55), std.mem.readInt(u32, out[8..12], .big));
}

test "encodeGetCrtcTransform: 96 bytes, length 16, identity at pending+current offsets, has_transforms=1" {
    const identity = [9]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x00010000 };
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeGetCrtcTransform(&w, .big, 3, identity);
    const out = w.buffered();

    try std.testing.expectEqual(@as(usize, 96), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[2..4], .big));
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, out[4..8], .big)); // (96-32)/4 = 16
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, out[8..12], .big)); // pending matrix11
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, out[24..28], .big)); // pending matrix22
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, out[40..44], .big)); // pending matrix33
    try std.testing.expectEqual(@as(u8, 1), out[44]); // has_transforms
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, out[48..52], .big)); // current matrix11
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, out[64..68], .big)); // current matrix22
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, out[80..84], .big)); // current matrix33
    for (out[88..96]) |b| try std.testing.expectEqual(@as(u8, 0), b); // pending/current len/nparams all 0

    // A non-identity scaled matrix reflects at both offsets, cross-endian too.
    const scaled = [9]u32{ 0x00020000, 0, 0, 0, 0x00020000, 0, 0, 0, 0x00010000 };
    var buf2: [128]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try encodeGetCrtcTransform(&w2, .little, 1, scaled);
    const out2 = w2.buffered();
    try std.testing.expectEqual(@as(u32, 0x00020000), std.mem.readInt(u32, out2[8..12], .little));
    try std.testing.expectEqual(@as(u32, 0x00020000), std.mem.readInt(u32, out2[48..52], .little));
}
