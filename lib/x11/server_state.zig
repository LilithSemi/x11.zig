//! X11 server window state: an xproto-free resource table (id -> Window) and
//! window tree. Pure data + logic so it unit-tests without a socket and does
//! not import the generated xproto module (which depends on x11 -> circular).
const std = @import("std");
const server_atoms = @import("server_atoms.zig");
const render = @import("render.zig");
const fontprovider = @import("fontprovider.zig");
const randr = @import("randr.zig");

pub const MapState = enum(u8) { unmapped = 0, unviewable = 1, viewable = 2 };

/// xproto EventMask bits this server acts on. StructureNotify selects events
/// about a window itself; SubstructureNotify selects events about its children.
pub const structure_notify: u32 = 0x20000; // 1 << 17
pub const substructure_notify: u32 = 0x80000; // 1 << 19
/// SubstructureRedirect: a WM selects this on a window (typically the root) to
/// intercept OTHER clients' Map/Configure of its non-override-redirect
/// children (MapRequest/ConfigureRequest instead of the op happening). Exclusive.
pub const substructure_redirect: u32 = 0x100000; // 1 << 20

/// xproto EventMask bits for input events (reused by the per-(window,client) mask list).
pub const key_press: u32 = 0x1; // 1 << 0
pub const key_release: u32 = 0x2; // 1 << 1
pub const button_press: u32 = 0x4; // 1 << 2
pub const button_release: u32 = 0x8; // 1 << 3
pub const enter_window: u32 = 0x10; // 1 << 4
pub const leave_window: u32 = 0x20; // 1 << 5
pub const pointer_motion: u32 = 0x40; // 1 << 6

/// xproto EventMask bit for FocusChange (FocusIn/FocusOut).
pub const focus_change: u32 = 0x200000; // 1 << 21

/// xproto EventMask bit for Exposure (Expose).
pub const exposure: u32 = 0x8000; // 1 << 15 (ExposureMask)

pub const EventKind = enum { create, destroy, map, unmap, property, configure, motion, button_press, button_release, key_press, key_release, enter, leave, focus_in, focus_out, expose, graphics_expose, no_expose, map_request, configure_request, reparent, circulate, circulate_request, selection_clear, selection_request, selection_notify, randr_screen_change, randr_crtc_change, randr_output_property };

/// xproto EventMask bit for PropertyNotify.
pub const property_change: u32 = 0x400000; // 1 << 22

/// RANDR event payload (kind == .randr_screen_change/.randr_crtc_change), the
/// fields that don't already have a home on `PendingEvent` (which supplies
/// the shared width/height/x/y/window/root/time per the wire layouts in
/// sp-server-randr-dynamic-spec.md). Defaults are the values every static
/// reply already reports (rotation Normal, no timestamp/window/size/subpixel
/// yet) so a caller only sets what a given event kind actually carries.
pub const RandrEventData = struct {
    rotation: u16 = 1,
    config_timestamp: u32 = 0,
    request_window: u32 = 0,
    size_id: u16 = 0,
    subpixel: u16 = 0,
    mwidth: u16 = 0,
    mheight: u16 = 0,
    crtc: u32 = 0,
    mode: u32 = 0,
    /// OutputProperty payload (kind == .randr_output_property): the output
    /// the property lives on, the property atom, and the wire `status`
    /// (0 NewValue / 1 Deleted -- same encoding as core PropertyNotify's
    /// `state`, just named `state` here too since it has no other home on
    /// `PendingEvent`/`RandrEventData` for a RANDR-only event).
    output: u32 = 0,
    atom: u32 = 0,
    state: u8 = 0,
};

/// An xproto-free descriptor of a window event the Display decided to fire.
/// server_main encodes each via the matching xproto.encode*NotifyEvent. The
/// `event_window` is the event's routing target (the `event` field of
/// Map/Unmap/DestroyNotify); CreateNotify has no `event` field and is routed
/// by `parent` instead, so create descriptors set event_window == parent.
pub const PendingEvent = struct {
    kind: EventKind,
    event_window: u32,
    window: u32,
    parent: u32 = 0,
    x: i16 = 0,
    y: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    border_width: u16 = 0,
    override_redirect: bool = false,
    /// Which client should receive this event (its selecting client). server_main
    /// resolves it to that client's connection for fan-out delivery.
    target_client: u32 = 0,
    /// PropertyNotify payload (kind == .property).
    atom: u32 = 0,
    state: u8 = 0, // 0 = NewValue, 1 = Deleted
    time: u32 = 0,
    /// ConfigureNotify payload (kind == .configure): the sibling directly below
    /// this window in the new stacking order (0 if bottommost).
    above_sibling: u32 = 0,
    /// ConfigureRequest payload (kind == .configure_request): which fields the
    /// client actually set in its value-list (x=1,y=2,width=4,height=8,
    /// border_width=16,sibling=32,stack_mode=64).
    value_mask: u16 = 0,
    /// Device-event payload (kind == .motion/.button_*/.key_*/.enter/.leave).
    /// `event_window` is the receiving window; `root`/`child` per X; coords are
    /// root-relative (root_x/root_y) and window-relative (event_x/event_y);
    /// `input_state` is the button+modifier mask; `mode` is the crossing mode.
    detail: u8 = 0,
    root: u32 = 0,
    child: u32 = 0,
    root_x: i16 = 0,
    root_y: i16 = 0,
    event_x: i16 = 0,
    event_y: i16 = 0,
    input_state: u16 = 0,
    mode: u8 = 0,
    /// Expose payload (kind == .expose): number of Expose events still to
    /// come for this exposure. 0 = last (or only) one. x/y/width/height carry
    /// the exposed rect, window-relative.
    count: u16 = 0,
    /// GraphicsExpose/NoExpose payload: the major opcode of the request that
    /// caused them (minor is always 0 for core). window carries the drawable.
    major_opcode: u8 = 0,
    /// Selection-event payload (kind == .selection_request/.selection_notify):
    /// the `target` and `property` atoms. selection_clear uses neither.
    target_atom: u32 = 0,
    property_atom: u32 = 0,
    /// RANDR event payload (kind == .randr_screen_change/.randr_crtc_change).
    randr: RandrEventData = .{},
};

/// A window's geometry (relative to its parent). depth 0 on create means
/// CopyFromParent and is resolved to the parent's depth.
pub const Geometry = struct {
    x: i16 = 0,
    y: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    border_width: u16 = 0,
    depth: u8 = 0,
};

/// The window attributes this server tracks (the subset GetWindowAttributes
/// needs). Extend as later requests need more.
pub const Attributes = struct {
    background_pixel: u32 = 0,
    border_pixel: u32 = 0,
    bit_gravity: u8 = 0,
    win_gravity: u8 = 0,
    backing_store: u8 = 0,
    backing_planes: u32 = 0xffffffff,
    backing_pixel: u32 = 0,
    override_redirect: bool = false,
    save_under: bool = false,
    do_not_propagate_mask: u32 = 0,
    colormap: u32 = 0,
};

/// A partial attribute update (the value-list on CreateWindow /
/// ChangeWindowAttributes): only the set optionals are applied. Kept
/// xproto-free; server_main unpacks the decoded xproto value-list into this.
pub const AttrDelta = struct {
    background_pixel: ?u32 = null,
    border_pixel: ?u32 = null,
    bit_gravity: ?u8 = null,
    win_gravity: ?u8 = null,
    backing_store: ?u8 = null,
    backing_planes: ?u32 = null,
    backing_pixel: ?u32 = null,
    override_redirect: ?bool = null,
    save_under: ?bool = null,
    event_mask: ?u32 = null,
    do_not_propagate_mask: ?u32 = null,
    colormap: ?u32 = null,

    fn applyTo(self: AttrDelta, a: *Attributes) void {
        if (self.background_pixel) |v| a.background_pixel = v;
        if (self.border_pixel) |v| a.border_pixel = v;
        if (self.bit_gravity) |v| a.bit_gravity = v;
        if (self.win_gravity) |v| a.win_gravity = v;
        if (self.backing_store) |v| a.backing_store = v;
        if (self.backing_planes) |v| a.backing_planes = v;
        if (self.backing_pixel) |v| a.backing_pixel = v;
        if (self.override_redirect) |v| a.override_redirect = v;
        if (self.save_under) |v| a.save_under = v;
        if (self.do_not_propagate_mask) |v| a.do_not_propagate_mask = v;
        if (self.colormap) |v| a.colormap = v;
    }
};

/// One client's event selection on a window. StructureNotify/SubstructureNotify
/// are shareable, so a window carries a list of these (one per selecting client).
pub const ClientMask = struct { client: u32, mask: u32 };

/// A window property's stored value. `data` is owned (freed on window destroy /
/// property replace / Display.deinit).
pub const Property = struct { type: u32, format: u8, data: []u8 };

pub const Window = struct {
    id: u32,
    parent: u32, // 0 for the root
    /// The client_id that created this window (0 = the root / server-owned).
    /// On that client's disconnect, cleanupClient destroys it.
    owner: u32 = 0,
    class: u16, // 1 = InputOutput, 2 = InputOnly (0 = CopyFromParent, resolved at create)
    visual: u32,
    geom: Geometry,
    attrs: Attributes = .{},
    map_state: MapState = .unmapped,
    children: std.ArrayListUnmanaged(u32) = .empty,
    /// Per-client event selections (the shareable Structure/SubstructureNotify
    /// masks). Replaces a single window-global event_mask so each client's
    /// selection is independent. Dies with the window.
    masks: std.ArrayListUnmanaged(ClientMask) = .empty,
    /// This window's properties, keyed by property-atom.
    props: std.AutoHashMapUnmanaged(u32, Property) = .{},
    /// This window's rendering surface (its drawable backing store), owned by
    /// the Display's renderer. Created at window-create, destroyed on
    /// window-destroy + Display.deinit. The root's surface is set in init.
    surface: render.Surface = undefined,

    /// Set `client`'s event mask on this window (upsert). A zero mask removes
    /// the client's entry (deselection).
    pub fn setMask(self: *Window, gpa: std.mem.Allocator, client: u32, mask: u32) std.mem.Allocator.Error!void {
        for (self.masks.items, 0..) |*cm, i| {
            if (cm.client == client) {
                if (mask == 0) {
                    _ = self.masks.orderedRemove(i);
                } else {
                    cm.mask = mask;
                }
                return;
            }
        }
        if (mask != 0) try self.masks.append(gpa, .{ .client = client, .mask = mask });
    }

    /// `client`'s selected mask on this window (0 if it selected nothing).
    pub fn maskFor(self: *const Window, client: u32) u32 {
        for (self.masks.items) |cm| {
            if (cm.client == client) return cm.mask;
        }
        return 0;
    }

    /// OR of every client's mask on this window.
    pub fn allMasks(self: *const Window) u32 {
        var m: u32 = 0;
        for (self.masks.items) |cm| m |= cm.mask;
        return m;
    }
};

/// The client holding SubstructureRedirect on `w` (exclusive selection), else
/// null. A WM selects this on the root to intercept children's map/configure.
fn redirectClient(w: *const Window) ?u32 {
    for (w.masks.items) |cm| if (cm.mask & substructure_redirect != 0) return cm.client;
    return null;
}

/// A read-only attribute view returned by getAttributes. `your_event_mask` is
/// the asking client's own selection; `all_event_masks` is the OR of all.
pub const AttrView = struct {
    class: u16,
    visual: u32,
    map_state: MapState,
    attrs: Attributes,
    your_event_mask: u32,
    all_event_masks: u32,
};
/// queryTree result; `children` borrows the window's list, valid until the
/// next tree mutation.
pub const TreeView = struct { root: u32, parent: u32, children: []const u32 };

/// Unified drawable geometry for GetGeometry (a window OR a pixmap).
pub const DrawableInfo = struct { depth: u8, root: u32, x: i16, y: i16, width: u16, height: u16, border_width: u16 };

/// queryPointer result: pointer position in root coords + relative to the
/// queried window + the child of that window under the pointer + the
/// button/modifier mask.
pub const PointerInfo = struct { root: u32, child: u32, root_x: i16, root_y: i16, win_x: i16, win_y: i16, mask: u16 };
/// translateCoordinates result: the point relative to dst + the child of dst
/// containing it.
pub const TranslateResult = struct { child: u32, dst_x: i16, dst_y: i16 };

/// An off-screen drawable: a renderer-owned surface plus its dimensions/depth.
/// The `surface` backs all drawing into this pixmap; freed on FreePixmap +
/// Display.deinit.
pub const Pixmap = struct { depth: u8, width: u16, height: u16, owner: u32, surface: render.Surface };

/// The graphics-context state this server stores (the subset drawing will
/// consume). Other GC value-list components are accepted but not stored yet.
/// Defaults are the X protocol GC defaults.
pub const GCValues = struct {
    function: u32 = 3, // GXcopy
    plane_mask: u32 = 0xffffffff,
    foreground: u32 = 0,
    background: u32 = 1,
    line_width: u32 = 0,
    line_style: u32 = 0, // LineSolid
    cap_style: u32 = 1, // CapButt
    join_style: u32 = 0, // JoinMiter
    fill_style: u32 = 0, // FillSolid
    subwindow_mode: u32 = 0, // ClipByChildren
    graphics_exposures: bool = true,
    arc_mode: u32 = 1, // ArcPieSlice
    /// The GC's font (FONT id). NOT validated on set (lenient; this server has
    /// one built-in font, so text ops always render with it regardless).
    font: u32 = 0,
};

/// A partial GC update (the CreateGC/ChangeGC value-list). Only the set
/// optionals apply. server_main unpacks the decoded xproto value-list into this.
pub const GCDelta = struct {
    function: ?u32 = null,
    plane_mask: ?u32 = null,
    foreground: ?u32 = null,
    background: ?u32 = null,
    line_width: ?u32 = null,
    line_style: ?u32 = null,
    cap_style: ?u32 = null,
    join_style: ?u32 = null,
    fill_style: ?u32 = null,
    subwindow_mode: ?u32 = null,
    graphics_exposures: ?bool = null,
    arc_mode: ?u32 = null,
    font: ?u32 = null,

    fn applyTo(self: GCDelta, v: *GCValues) void {
        if (self.function) |x| v.function = x;
        if (self.plane_mask) |x| v.plane_mask = x;
        if (self.foreground) |x| v.foreground = x;
        if (self.background) |x| v.background = x;
        if (self.line_width) |x| v.line_width = x;
        if (self.line_style) |x| v.line_style = x;
        if (self.cap_style) |x| v.cap_style = x;
        if (self.join_style) |x| v.join_style = x;
        if (self.fill_style) |x| v.fill_style = x;
        if (self.subwindow_mode) |x| v.subwindow_mode = x;
        if (self.graphics_exposures) |x| v.graphics_exposures = x;
        if (self.arc_mode) |x| v.arc_mode = x;
        if (self.font) |x| v.font = x;
    }
};

pub const GC = struct { owner: u32, values: GCValues };

/// A server-side font resource: the owner for id-namespace membership +
/// cleanup on disconnect (mirroring Pixmap/GC), plus the opaque ref the
/// injected FontProvider returned from openFont -- must be closed via
/// `font_provider.closeFont(ref)` exactly once (CloseFont, cleanupClient, or
/// deinit).
pub const Font = struct { owner: u32 = 0, ref: fontprovider.FontRef = undefined };

/// A server-side colormap resource: the owner for id-namespace membership +
/// cleanup on disconnect (mirroring Pixmap/GC/Font), plus the visual it was
/// created against. TrueColor-only this slice -- no real cell storage, so
/// there is nothing else to hold (AllocColor derives the pixel arithmetically).
pub const Colormap = struct { owner: u32 = 0, visual: u32 = 0 };

/// A selection's current owner (ICCCM: SetSelectionOwner/GetSelectionOwner/
/// ConvertSelection). `client` is who to deliver SelectionClear/SelectionRequest
/// to; `window` is the owner window reported by GetSelectionOwner; `time` is
/// the resolved (never CurrentTime) last-change timestamp.
pub const SelectionOwner = struct { client: u32, window: u32, time: u32 };

/// The ConfigureWindow value-list, xproto-free (wire widths preserved;
/// configureWindow validates + narrows). server_main unpacks the decoded
/// xproto value-list into this.
pub const ConfigDelta = struct {
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    border_width: ?u32 = null,
    sibling: ?u32 = null,
    stack_mode: ?u32 = null,
};

/// Cap on how deep pointer hit-testing descends, bounding a hostile deep
/// window chain the same way iterative destroy is bounded.
pub const MAX_POINTER_DEPTH: usize = 256;

/// One window on the root->target path, carrying its absolute drawable
/// origin (root coords) so event coordinates are `root - abs`.
pub const PathNode = struct { wid: u32, abs_x: i32, abs_y: i32 };

/// The keyboard range advertised in the SetupReply (lib/x11/server.zig).
pub const min_keycode: u8 = 8;
pub const max_keycode: u8 = 255;

/// GrabPointer/GrabKeyboard/GrabButton/GrabKey `pointer_mode`/`keyboard_mode`
/// wire values. A device whose mode == mode_sync FREEZES on grab activation
/// (see Display.pointer_frozen/keyboard_frozen); mode_async never freezes.
pub const mode_sync: u8 = 0;
pub const mode_async: u8 = 1;

/// An active GrabPointer (op 26). While set, motion/button events route ONLY
/// to `client` (see recordPointerGrabbed), bypassing the normal spatial
/// propagation + crossing. `event_mask` filters what's reported on
/// `grab_window` when owner_events is false (or there's no owner_events hit).
/// `auto`: true when this grab was AUTO-ACTIVATED from a passive GrabButton
/// (see matchButtonGrab/injectButton) rather than an explicit GrabPointer --
/// drives auto-release on all-buttons-up. Explicit GrabPointer leaves it false.
/// `pointer_mode`/`keyboard_mode`: Sync(0)/Async(1) -- see mode_sync/mode_async.
pub const PointerGrab = struct { client: u32, grab_window: u32, event_mask: u16, owner_events: bool, auto: bool = false, pointer_mode: u8 = mode_async, keyboard_mode: u8 = mode_async };

/// An active GrabKeyboard (op 31). While set, key events route ONLY to
/// `client` on `grab_window` (see recordKeyGrabbed), bypassing focus routing
/// entirely. No event_mask -- a keyboard grab captures every key.
/// `auto_key`: set to the activating keycode when this grab was
/// AUTO-ACTIVATED from a passive GrabKey (see matchKeyGrab/injectKey) --
/// drives auto-release when that SAME key is released. Explicit
/// GrabKeyboard leaves it null. `pointer_mode`/`keyboard_mode`: see PointerGrab.
pub const KeyboardGrab = struct { client: u32, grab_window: u32, owner_events: bool, auto_key: ?u8 = null, pointer_mode: u8 = mode_async, keyboard_mode: u8 = mode_async };

/// One ChangeSaveSet entry: `client` asked to save-set (protect) `window`,
/// a window it does not own. See `Display.save_set` + `changeSaveSet`.
pub const SaveSetEntry = struct { client: u32, window: u32 };

/// A registered passive pointer grab (GrabButton, op 28). Not itself an
/// active grab -- matchButtonGrab checks a pending press against these; a
/// match promotes it to a real `pointer_grab` (see injectButton). button==0
/// is AnyButton; modifiers==0x8000 is AnyModifier. `pointer_mode`/
/// `keyboard_mode` carry into the auto-activated PointerGrab.
pub const ButtonGrabSpec = struct { client: u32, grab_window: u32, event_mask: u16, owner_events: bool, button: u8, modifiers: u16, pointer_mode: u8, keyboard_mode: u8 };

/// A registered passive keyboard grab (GrabKey, op 33). Not itself an active
/// grab -- matchKeyGrab checks a pending press against these; a match
/// promotes it to a real `keyboard_grab` (see injectKey). key==0 is AnyKey;
/// modifiers==0x8000 is AnyModifier. `pointer_mode`/`keyboard_mode` carry
/// into the auto-activated KeyboardGrab.
pub const KeyGrabSpec = struct { client: u32, grab_window: u32, owner_events: bool, key: u8, modifiers: u16, pointer_mode: u8, keyboard_mode: u8 };

/// A device event captured while its device was frozen (Sync grab), or the
/// event that activated a passive Sync grab (kept for AllowEvents Replay,
/// added in Task 2). Enough to re-dispatch: kind + detail (button/keycode) +
/// root coords + time.
pub const FrozenEvent = struct { kind: EventKind, detail: u8, px: i16, py: i16, time: u32 };

/// Which grab froze a device. A grab's cross-mode (its OTHER device's mode)
/// can freeze a device that grab does not itself hold: GrabPointer's
/// keyboard_mode==Sync freezes the keyboard while keyboard_grab stays null,
/// and symmetrically for GrabKeyboard's pointer_mode. Teardown (clearing a
/// grab) and AllowEvents (thawing a device) must both act on the OWNING grab,
/// not assume "the grab of the same device type" -- that assumption is the
/// bug this enum fixes (a cross-mode freeze used to be untouchable once the
/// grab that induced it released, since only the same-device clear path ran).
pub const FreezeOwner = enum { none, pointer_grab, keyboard_grab };

/// One registered X extension: its wire name (matched by QueryExtension /
/// listed by ListExtensions) + the major opcode >=128 requests for it are
/// dispatched under + its event/error code base (both 0 -- neither extension
/// this server implements defines extension events or errors). xproto-free
/// by design (the generator only emits core xproto/xkb, not extensions), so
/// this table + its two implementing extensions are hand-maintained here.
pub const ExtensionInfo = struct { name: []const u8, major_opcode: u8, first_event: u8, first_error: u8 };

/// The extensions this server answers for. BIG-REQUESTS (major 128) raises
/// the maximum request length via BigReqEnable; XC-MISC (major 129) hands
/// out fresh resource-id ranges when a client's own range runs low. Both are
/// hand-decoded/encoded in server_main.zig (handleExtensionRequest) since
/// the generator never sees extension XML.
pub const extensions = [_]ExtensionInfo{
    .{ .name = "BIG-REQUESTS", .major_opcode = 128, .first_event = 0, .first_error = 0 },
    .{ .name = "XC-MISC", .major_opcode = 129, .first_event = 0, .first_error = 0 },
    // RANDR (4z): the first extension this server gives real event/error bases
    // to (64/128, both above the core ranges) -- it actually defines
    // ScreenChangeNotify/Notify events and BadOutput/BadCrtc/BadMode/BadProvider
    // errors, hand-encoded in randr.zig / handleRandr (server_main.zig). Bases
    // pulled from randr.zig itself (single source of truth -- randr.zig is
    // std-only, so this import can't cycle back).
    .{ .name = "RANDR", .major_opcode = 130, .first_event = randr.first_event, .first_error = randr.first_error },
};

/// QueryExtension's lookup: the client names the extension by string.
pub fn extensionByName(name: []const u8) ?ExtensionInfo {
    for (extensions) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// The extension router's lookup: dispatch keys off the request's major
/// opcode (bytes[0], which is >=128 for every extension request).
pub fn extensionByMajor(major: u8) ?ExtensionInfo {
    for (extensions) |e| if (e.major_opcode == major) return e;
    return null;
}

/// RANDR's static single-monitor config: 1 crtc/1 output/1 mode, screen size
/// derived from the root window's geom (not stored here, so a future resize
/// can't desync it from what ConfigureNotify/GetGeometry already report).
/// Fixed ids in a high, non-colliding space (the shared client id namespace
/// tops out well below this). MUTABLE (a struct field on Display, not
/// constants) on purpose: the wanted follow-up (SetCrtcConfig/SetScreenSize)
/// mutates `timestamp` and the ids stay stable across it.
pub const RandrConfig = struct {
    crtc: u32 = 0xf0000001,
    output: u32 = 0xf0000002,
    mode: u32 = 0xf0000003,
    /// config_timestamp: bumped by a future SetCrtc-family request. Starts at
    /// 1 (0 is X's CurrentTime/"no timestamp" sentinel, avoided here so a
    /// naive client comparison against CurrentTime never accidentally matches).
    timestamp: u32 = 1,
};

/// SetCrtcTransform's identity TRANSFORM (9 FIXED 16.16, row-major 3x3):
/// matrix11/matrix22/matrix33 (the diagonal) = 1.0 in 16.16 fixed point
/// (0x00010000), every off-diagonal entry 0. This is what a fresh crtc
/// reports before any SetCrtcTransform call -- see `Display.randr_transform`.
pub const identity_transform = [9]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x00010000 };

/// One RANDR mode this server can report: a stable id + fixed pixel dims.
/// The CURRENT mode (id == RandrConfig.mode) is special-cased everywhere it's
/// resolved (`randrModeById`/`randrModeList`): its dims always track the live
/// root geom rather than a stored value, so a resize can never desync the
/// mode table from what GetGeometry/ConfigureNotify already report (same
/// single-source-of-truth reasoning as `randrScreenSize`).
pub const RandrMode = struct { id: u32, width: u16, height: u16 };

/// Fixed alternative modes this server advertises alongside the (dynamic)
/// current mode -- common resolutions a client's mode-switch UI expects to
/// see. None of these is ever actually live; this synthetic single-monitor
/// config only ever paints at the current mode's dims (a future
/// SetCrtcConfig/SetScreenConfig resizes the root TO one of these, at which
/// point it becomes the reported current mode instead). Ids sit right above
/// RandrConfig's fixed ids, in the same non-colliding high id space.
pub const randr_alt_modes = [_]RandrMode{
    .{ .id = 0xf0001000, .width = 800, .height = 600 },
    .{ .id = 0xf0001001, .width = 1024, .height = 768 },
    .{ .id = 0xf0001002, .width = 1280, .height = 720 },
    .{ .id = 0xf0001003, .width = 1280, .height = 1024 },
    .{ .id = 0xf0001004, .width = 1920, .height = 1080 },
};

/// The number of BUILT-IN modes this server ever reports: the current mode
/// plus every fixed alternative. GetScreenResources/GetOutputInfo/
/// GetScreenInfo report this many PLUS however many client-created modes
/// (`Display.randr_created_modes`) exist -- see `max_mode_count`.
pub const randr_mode_count: usize = 1 + randr_alt_modes.len;

/// CreateMode's (RANDR minor 16) cap on `Display.randr_created_modes`: a
/// hostile/careless client spamming CreateMode without ever DestroyMode-ing
/// can't grow the reported mode list without bound (a real RANDR server's
/// mode table is similarly finite). See `Display.createMode`'s doc comment
/// for what happens at the cap.
pub const max_created_modes: usize = 64;

/// The most modes this server can EVER report at once (built-in +
/// `max_created_modes`). Callers that need a comptime-sized stack buffer for
/// `Display.randrModeList` (server_main's handleRandr) size it to this.
pub const max_mode_count: usize = randr_mode_count + max_created_modes;

/// Most OUTPUTs a single SetMonitor'd `RandrMonitor` can list. This server
/// only ever has one real output (`RandrConfig.output`), but SetMonitor's
/// wire layout carries a client-supplied nOutput/outputs list -- 4 is a
/// generous bound matching real multi-head monitor groupings while keeping
/// `RandrMonitor` a plain fixed-size struct (no per-monitor allocation).
/// `Display.setMonitor` clamps/ignores any outputs beyond this.
pub const max_monitor_outputs: usize = 4;

/// A client-defined monitor (SetMonitor, RANDR minor 43): a named rectangle
/// (position + size + physical mm) covering some subset of this server's
/// outputs. Once any `SetMonitor` call succeeds, `Display.randr_monitors`
/// REPLACES the synthetic single-monitor default GetMonitors otherwise
/// reports (see `Display.randrMonitorCount`/the GetMonitors handler) -- a real
/// multi-monitor WM (e.g. via xrandr --setmonitor) drives exactly this path.
pub const RandrMonitor = struct {
    name: u32,
    primary: bool,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    mm_width: u32,
    mm_height: u32,
    outputs: [max_monitor_outputs]u32 = .{ 0, 0, 0, 0 },
    n_outputs: u8 = 0,
};

/// Cap on `Display.randr_monitors` -- mirrors `max_created_modes`: bounds a
/// hostile/careless client spamming SetMonitor with ever-new names without
/// bound. At the cap, SetMonitor for a genuinely NEW name is refused
/// (OutOfMemory) rather than evicting -- unlike modes, a monitor a WM is
/// actively relying on shouldn't silently disappear to make room for another.
pub const max_monitors: usize = 16;

/// One SelectInput(RRSelectInput) registration: `client` asked to receive
/// RANDR events matching `mask` on `window`. Consulted by
/// `Display.recordRandrEvent` -- every dynamic-RANDR mutation
/// (resizeRoot/setCrtcMode/setScreenConfigSize) fans ScreenChangeNotify/
/// RRNotify-CrtcChange out to exactly the clients registered here whose mask
/// matches. See `Display.randr_event_masks`.
pub const RandrEventMask = struct { client: u32, window: u32, mask: u16 };

/// RANDR gamma's default "unity" ramp: value[i] = i * 65535/255, so a fresh
/// Display's gamma reports as a no-op identity curve (matches a real X server
/// before any SetCrtcGamma call) rather than all-zero/all-black. Built once at
/// comptime; shared as the default for `Display.gamma_red/green/blue`.
fn linearGammaRamp() [256]u16 {
    var ramp: [256]u16 = undefined;
    for (&ramp, 0..) |*v, i| v.* = @intCast(@as(u32, i) * 65535 / 255);
    return ramp;
}
const linear_gamma_ramp: [256]u16 = linearGammaRamp();

pub const Display = struct {
    gpa: std.mem.Allocator,
    /// The injectable rendering backend that owns every drawable surface. All
    /// pixel work (fill/copy/put/get/resize + surface lifecycle) delegates here.
    renderer: render.Renderer = undefined,
    /// True when this Display heap-allocated its own default SoftwareRenderer
    /// (via `init`) and must free it in deinit; false when a renderer was
    /// injected (via `initWithRenderer`) and is owned by the caller.
    owns_renderer: bool = false,
    /// The heap-allocated default software renderer (stable address so the
    /// interface ptr survives Display being returned/moved by value), or null
    /// when a renderer was injected.
    renderer_impl: ?*render.SoftwareRenderer = null,
    /// The injectable font backend that owns every open font's glyph data +
    /// metrics. OpenFont/CloseFont/QueryFont/ListFonts + ImageText8/PolyText8
    /// glyph lookups all delegate here (mirrors `renderer` above).
    font_provider: fontprovider.FontProvider = undefined,
    /// True when this Display heap-allocated its own default Font8x8Provider
    /// (font_provider was not injected) and must free it in deinit.
    owns_font_provider: bool = false,
    /// The heap-allocated default font provider (stable address across the
    /// by-value return), or null when a font provider was injected.
    font_provider_impl: ?*fontprovider.Font8x8Provider = null,
    /// The font opened via `font_provider.openFont("fixed")` at init time, used
    /// as ImageText8/PolyText8's fallback when a GC's font is not a live Font
    /// resource. Null if the (injected) provider has no "fixed" font -- text
    /// with no resolvable font then draws nothing (graceful, no crash).
    default_font: ?fontprovider.FontRef = null,
    windows: std.AutoHashMapUnmanaged(u32, Window) = .{},
    pending: std.ArrayListUnmanaged(PendingEvent) = .empty,
    root: u32,
    root_depth: u8,
    root_visual: u32,
    /// Hard cap on live windows (incl. the root): createWindow past this
    /// returns TooManyResources, bounding memory against a hostile client that
    /// creates windows without bound. A field (not a const) so tests can lower
    /// it; the executable maps the error to BadAlloc(11).
    max_windows: usize = 100_000,
    /// The server's one global atom table (shared across all clients).
    atoms: server_atoms.AtomTable = .{},
    /// Monotonic timestamp for PropertyNotify (no real clock available). Bumped
    /// per property change.
    prop_time: u32 = 0,
    /// Off-screen drawables, keyed by pixmap id (part of the shared id namespace).
    pixmaps: std.AutoHashMapUnmanaged(u32, Pixmap) = .{},
    /// Cap on a single pixmap's backing buffer (bounds a hostile width*height).
    max_pixmap_bytes: usize = 64 * 1024 * 1024,
    /// Graphics contexts, keyed by gcontext id (part of the shared id namespace).
    gcs: std.AutoHashMapUnmanaged(u32, GC) = .{},
    /// Open fonts, keyed by font id (part of the shared id namespace). Each
    /// entry holds the FontProvider's ref for that open font (the default
    /// provider serves font8x8; an injected provider serves whatever it wants).
    fonts: std.AutoHashMapUnmanaged(u32, Font) = .{},
    /// Colormaps, keyed by colormap id (part of the shared id namespace).
    /// `default_colormap` is pre-registered at init (owner 0 = server) and is
    /// never client-freed on disconnect.
    colormaps: std.AutoHashMapUnmanaged(u32, Colormap) = .{},
    /// The screen-wide installed set (InstallColormap/UninstallColormap
    /// membership), returned verbatim by ListInstalledColormaps.
    installed_colormaps: std.ArrayListUnmanaged(u32) = .empty,
    /// The current owner of each selection atom (ICCCM SetSelectionOwner /
    /// GetSelectionOwner / ConvertSelection). Missing key = unowned (None).
    selections: std.AutoHashMapUnmanaged(u32, SelectionOwner) = .{},
    /// Current pointer position (root coords) + the window under it. Injected
    /// input routes from here; `input_state` is the button+modifier mask carried
    /// in each device event (modifier bits stay 0 until a keymap exists).
    pointer_x: i16 = 0,
    pointer_y: i16 = 0,
    pointer_window: u32 = 0,
    input_state: u16 = 0,
    /// Keyboard focus: a window id, or None(0) / PointerRoot(1). Key events route
    /// here (see injectKey). focus_revert is where focus goes if the focus window
    /// becomes unviewable. Default = PointerRoot, matching real X's startup focus.
    focus: u32 = 1,
    focus_revert: u8 = 1,
    /// Active input grabs (GrabPointer/GrabKeyboard). Null = no grab (normal
    /// spatial/focus routing). See grabPointer/grabKeyboard + the
    /// recordPointerGrabbed/recordKeyGrabbed routing they enable.
    pointer_grab: ?PointerGrab = null,
    keyboard_grab: ?KeyboardGrab = null,
    /// True while a Sync-mode grab has frozen the pointer/keyboard device:
    /// injectMotion/injectButton/injectKey QUEUE instead of dispatching (see
    /// frozen_pointer_events/frozen_keyboard_events below). Set on a
    /// successful Sync GrabPointer/GrabKeyboard, or after the activating
    /// event of a Sync passive GrabButton/GrabKey is delivered. Cleared by
    /// clearPointerGrab/clearKeyboardGrab (grab release) or AllowEvents (Task 2).
    pointer_frozen: bool = false,
    keyboard_frozen: bool = false,
    /// Which grab froze each device (see FreezeOwner) -- the OTHER device's
    /// cross-mode can freeze a device whose own grab field stays null (e.g.
    /// GrabPointer's keyboard_mode==Sync freezes the keyboard while
    /// keyboard_grab is null). Teardown and AllowEvents key off these, not
    /// off "the grab of the matching device type". `.none` iff the matching
    /// *_frozen bool is false (kept in sync by every site that sets/clears it).
    pointer_freeze_owner: FreezeOwner = .none,
    keyboard_freeze_owner: FreezeOwner = .none,
    /// AllowEvents(SyncPointer/SyncKeyboard) (Task 2): re-freeze after the
    /// NEXT button/key event dispatches, checked at the end of
    /// dispatchButton/dispatchKey. Always false until Task 2 wires allowEvents.
    pointer_resync: bool = false,
    keyboard_resync: bool = false,
    /// The passive-grab-activating event that froze the device (for
    /// AllowEvents ReplayPointer/ReplayKeyboard, Task 2). Null for an
    /// EXPLICIT Sync grab (nothing to replay) or when not frozen.
    pointer_trigger: ?FrozenEvent = null,
    keyboard_trigger: ?FrozenEvent = null,
    /// Events injected while pointer_frozen/keyboard_frozen, queued in FIFO
    /// order instead of dispatched. Discarded (not replayed) on grab release
    /// -- AllowEvents (Task 2) is the supported thaw/replay path. Bounded by
    /// max_frozen_events (see the const below) against unbounded growth while
    /// a device stays frozen a long time.
    frozen_pointer_events: std.ArrayListUnmanaged(FrozenEvent) = .empty,
    frozen_keyboard_events: std.ArrayListUnmanaged(FrozenEvent) = .empty,
    /// Passive grabs registered via GrabButton/GrabKey (see
    /// matchButtonGrab/matchKeyGrab + injectButton/injectKey activation).
    /// Distinct from the single active pointer_grab/keyboard_grab above --
    /// many may be registered at once; at most one activates per matching
    /// press, becoming the (single) active grab.
    button_grabs: std.ArrayListUnmanaged(ButtonGrabSpec) = .empty,
    key_grabs: std.ArrayListUnmanaged(KeyGrabSpec) = .empty,
    /// ChangeSaveSet entries: {client, window} pairs where `client` asked to
    /// save-set (protect) a window it does NOT own. On `client`'s disconnect,
    /// cleanupClient rescues (reparents to root) any entry that is an inferior
    /// of `client`'s own subtree BEFORE destroying that subtree, so a WM's
    /// reparented client windows survive the WM's death (ICCCM save-set).
    save_set: std.ArrayListUnmanaged(SaveSetEntry) = .empty,
    /// Client ids that disconnected under SetCloseDownMode(RetainTemporary) --
    /// their windows/pixmaps/gcs/fonts were kept alive (see retainClient) but
    /// this list records them so KillClient(AllTemporary, resource==0) knows
    /// which retained clients to sweep (killTemporary). RetainPermanent
    /// clients are retained too but never added here -- only an explicit
    /// KillClient(their resource) destroys them.
    retained_temporary: std.ArrayListUnmanaged(u32) = .empty,
    /// Default keyboard map: keysyms_per_keycode = 2 (unshifted, shifted) over
    /// keycodes min_keycode..max_keycode. Minimal by design (populated in init) -
    /// a real server / Lattice supplies the full map. Keycode K -> base index
    /// (K - min_keycode) * 2.
    keymap: [(@as(u16, max_keycode) - min_keycode + 1) * 2]u32 = [_]u32{0} ** ((@as(u16, max_keycode) - min_keycode + 1) * 2),
    /// Modifier map: 8 modifiers x up to 8 keycodes each, flat in wire order
    /// (Shift, Lock, Control, Mod1..Mod5). Only the first `8 * modmap_per`
    /// bytes are live; SetModifierMapping picks modmap_per (<=8) at runtime,
    /// so the backing buffer is sized for the largest legal per-modifier count.
    modmap: [64]u8 = [_]u8{0} ** 64,
    /// Keycodes per modifier currently in `modmap` (GetModifierMapping's `per`).
    modmap_per: u8 = 2,
    /// Physical->logical pointer button map (GetPointerMapping/SetPointerMapping).
    /// Fixed at 5 buttons; default identity.
    pointer_map: [5]u8 = .{ 1, 2, 3, 4, 5 },

    /// RANDR's static single-monitor config (crtc/output/mode ids + config
    /// timestamp). See `RandrConfig`'s doc comment for why this is a mutable
    /// field rather than constants.
    randr: RandrConfig = .{},
    /// RANDR SelectInput registrations (see `RandrEventMask`). Scrubbed per
    /// client in scrubClientConnection, freed in deinit -- mirrors every other
    /// per-client connection-state list on this struct (masks/grabs/selections).
    randr_event_masks: std.ArrayListUnmanaged(RandrEventMask) = .empty,

    /// Client-created modes (CreateMode, RANDR minor 16), in creation order.
    /// Folded into every mode list this server reports (`randrModeList`) and
    /// resolvable by id (`randrModeById`) alongside the built-in modes.
    /// Bounded to `max_created_modes` -- see `createMode`. Freed in
    /// `Display.deinit`.
    randr_created_modes: std.ArrayListUnmanaged(RandrMode) = .empty,
    /// Next id `createMode` mints (then advances, wrapping -- see
    /// `next_xid`'s doc comment for the same convention). Starts well above
    /// `randr_alt_modes`'s fixed range so a created mode's id never collides
    /// with the current mode, an alt mode, or another created mode.
    randr_next_mode_id: u32 = 0xf0002000,

    /// Client-defined monitors (SetMonitor/DeleteMonitor, RANDR minors 43/44),
    /// keyed by `.name` (a name ATOM), in first-set order. GetMonitors (minor
    /// 42) reports these verbatim once non-empty, REPLACING the synthetic
    /// single-monitor default it otherwise synthesizes. Bounded to
    /// `max_monitors` -- see `setMonitor`. Freed in `Display.deinit`.
    randr_monitors: std.ArrayListUnmanaged(RandrMonitor) = .empty,

    /// GetCrtcGammaSize's reported ramp length. FIXED at 256 -- a real X
    /// server's gamma ramp length is a hardware property of the crtc, not
    /// something a client's SetCrtcGamma can change; `setCrtcGamma` never
    /// writes this field, it only accepts a request whose `size` already
    /// matches. This single-crtc config keeps one ramp triple for the one
    /// crtc it has -- no per-crtc map needed.
    gamma_size: u16 = 256,
    /// Per-crtc gamma ramps (GetCrtcGamma/SetCrtcGamma), linear ("unity") by
    /// default. STORED ONLY -- never applied to rendering. Software rendering
    /// stays gamma-naive; a future gamma renderer-seam (mirroring
    /// render.Renderer) is where Lattice/Prism would sample these ramps and
    /// actually color-correct output. Keeping x11.zig Prism-free means this
    /// server can answer every gamma request correctly on the wire without
    /// ever needing to import a real compositor/GPU backend.
    gamma_red: [256]u16 = linear_gamma_ramp,
    gamma_green: [256]u16 = linear_gamma_ramp,
    gamma_blue: [256]u16 = linear_gamma_ramp,

    /// SetCrtcTransform/GetCrtcTransform's stored per-crtc TRANSFORM (9
    /// FIXED 16.16 values, row-major 3x3): identity by default (matrix11/22/33
    /// = 0x00010000, the rest 0). STORED ONLY -- like `gamma_red`/`green`/
    /// `blue` above, never applied to rendering; software rendering stays
    /// transform-naive. A future transform renderer-seam (mirroring
    /// render.Renderer) is where Lattice/Prism would sample this matrix and
    /// actually scale/rotate output. Keeps x11.zig Prism-free.
    randr_transform: [9]u32 = identity_transform,

    /// RANDR output-property store (ChangeOutputProperty/GetOutputProperty/
    /// DeleteOutputProperty/ListOutputProperties): this static single-output
    /// config has exactly one output, so one map keyed by property atom
    /// suffices -- no per-output table needed. Mirrors `Window.props`
    /// structurally (same `Property` value type), but carries no
    /// PropertyNotify wiring (RANDR's own OutputProperty event is deferred).
    /// Seeded with a synthetic EDID at init (`seedEdid`); freed in
    /// Display.deinit.
    output_props: std.AutoHashMapUnmanaged(u32, Property) = .{},

    /// XC-MISC's GetXIDRange/GetXIDList dispenser: the next id `allocXidRange`
    /// hands out. Starts at 0x70000000, a high fixed space no per-client
    /// range (base 0x00400000, step 0x00200000, see
    /// server_loop.resourceRangeForIndex) reaches at any realistic client
    /// count, so ranges handed out here are disjoint from every client's own
    /// id space by construction -- no idInUse check is needed (or possible:
    /// these ids are handed to the CLIENT to mint resources with later, so
    /// they are necessarily not yet in use). Monotonic and never reused (a
    /// dispensed range is never reclaimed on client death); wrapping (+%) so
    /// exhausting the space is a documented non-panic, not a crash, though at
    /// 2^32 ids it is not a realistic concern.
    next_xid: u32 = 0x70000000,

    /// The colormap id the setup reply advertises (wire.zig encodeSetupReply
    /// buf[44..48]) -- pre-registered at init so AllocColor works against it
    /// with no CreateColormap round-trip.
    pub const default_colormap: u32 = 0x25;

    /// Cap on frozen_pointer_events/frozen_keyboard_events: a device can stay
    /// frozen indefinitely (an owning client that never calls AllowEvents, a
    /// stuck cross-device freeze, etc.), and every injected event while
    /// frozen queues -- without a bound that queue grows without limit. When
    /// full, the OLDEST queued event is dropped to make room for the newest
    /// (the most recent device state matters most once the device thaws).
    pub const max_frozen_events: usize = 4096;

    pub const CreateError = error{ IdInUse, NoParent, TooManyResources } || std.mem.Allocator.Error;
    pub const ConfigError = error{ NoWindow, BadValue, BadMatch, TooLarge } || std.mem.Allocator.Error;
    pub const WindowError = error{NoWindow};
    pub const SendError = error{NoWindow} || std.mem.Allocator.Error;
    pub const EventError = error{NoWindow} || std.mem.Allocator.Error;
    pub const PixmapError = error{ IdInUse, NoDrawable, BadValue, TooLarge } || std.mem.Allocator.Error;
    pub const FreePixmapError = error{NotPixmap};
    pub const GCError = error{ IdInUse, NoDrawable } || std.mem.Allocator.Error;
    pub const GCOpError = error{NotGC};
    pub const max_property_bytes: usize = 1 << 20; // 1 MB per property (Append accumulates untrusted data)
    pub const PropError = error{ NoWindow, BadAtom, BadMatch, BadValue, TooLarge } || std.mem.Allocator.Error;
    pub const GetPropError = error{ NoWindow, BadAtom, BadValue } || std.mem.Allocator.Error;
    pub const ListPropError = error{NoWindow} || std.mem.Allocator.Error;
    pub const DeletePropError = error{ NoWindow, BadAtom } || std.mem.Allocator.Error;
    pub const GetPropResult = struct { found: bool, type: u32, format: u8, bytes_after: u32, value: []const u8 };

    /// Output-property error sets (mirror the window ones above, `BadOutput`
    /// standing in for `NoWindow`). `OutputPropError` keeps the same
    /// `max_property_bytes` TooLarge cap as `PropError` -- Append accumulates
    /// untrusted client data here too, and there's no per-request bound this
    /// store can otherwise rely on across repeated ChangeOutputProperty calls.
    /// `OutputPropError`/`OutputDeletePropError` now also carry `NoWindow`:
    /// both record RANDR's OutputProperty event via `recordRandrEvent`, whose
    /// declared `EventError` return includes it (same as every other
    /// `recordRandrEvent` caller, e.g. `resizeRoot`) even though this path
    /// never actually produces it (there's no window lookup here). What DOES
    /// happen for real is the `Allocator.Error` from appending the recorded
    /// event to `pending`. `OutputGetPropError` still has no OutOfMemory: its
    /// delete path is a plain free+remove, no RANDR event recorded (only
    /// ChangeOutputProperty/DeleteOutputProperty fire OutputProperty per the
    /// X spec). `OutputListPropError` does need OutOfMemory: it still
    /// allocates the returned atom-id slice.
    pub const OutputPropError = error{ BadOutput, BadAtom, BadMatch, BadValue, TooLarge, NoWindow } || std.mem.Allocator.Error;
    pub const OutputGetPropError = error{ BadOutput, BadAtom, BadValue };
    pub const OutputDeletePropError = error{ BadOutput, BadAtom, NoWindow } || std.mem.Allocator.Error;
    pub const OutputListPropError = error{BadOutput} || std.mem.Allocator.Error;

    /// Build a Display with the root window pre-created (map_state viewable),
    /// matching the setup the server advertises. Shared body for both entry
    /// points; `renderer` supplies the drawable surfaces and `font_provider`
    /// the font backend (each default or injected). The caller sets
    /// owns_renderer/renderer_impl + owns_font_provider/font_provider_impl
    /// after this returns.
    fn initCommon(gpa: std.mem.Allocator, root: u32, root_depth: u8, root_visual: u32, renderer: render.Renderer, font_provider: fontprovider.FontProvider) std.mem.Allocator.Error!Display {
        var self: Display = .{ .gpa = gpa, .renderer = renderer, .font_provider = font_provider, .root = root, .root_depth = root_depth, .root_visual = root_visual };
        // The root's backing surface (640x480), owned by the renderer.
        const root_surface = try renderer.createSurface(root_depth, 640, 480);
        errdefer renderer.destroySurface(root_surface);
        try self.windows.put(gpa, root, .{
            .id = root,
            .parent = 0,
            .class = 1,
            .visual = root_visual,
            .geom = .{ .width = 640, .height = 480, .depth = root_depth },
            .map_state = .viewable,
            .surface = root_surface,
        });
        // If a later init step fails, free the window map we just populated so
        // init is all-or-nothing (the caller never gets a Display to deinit).
        errdefer self.windows.deinit(gpa);
        self.atoms = try server_atoms.AtomTable.init(gpa);
        // The default colormap: owner 0 (server), matching the id the setup
        // reply advertises. Pre-installed so ListInstalledColormaps is never
        // empty and AllocColor works against it immediately.
        try self.colormaps.put(gpa, default_colormap, .{ .owner = 0, .visual = root_visual });
        errdefer self.colormaps.deinit(gpa);
        try self.installed_colormaps.append(gpa, default_colormap);
        errdefer self.installed_colormaps.deinit(gpa);
        self.pointer_window = root; // the pointer starts over the root window
        // Minimal default keymap: 'a', Shift_L, Control_L; the rest NoSymbol(0).
        self.keymap[(38 - min_keycode) * 2] = 0x61; // XK_a
        self.keymap[(38 - min_keycode) * 2 + 1] = 0x41; // XK_A
        self.keymap[(50 - min_keycode) * 2] = 0xffe1; // XK_Shift_L
        self.keymap[(50 - min_keycode) * 2 + 1] = 0xffe1;
        self.keymap[(37 - min_keycode) * 2] = 0xffe3; // XK_Control_L
        self.keymap[(37 - min_keycode) * 2 + 1] = 0xffe3;
        // Standard PC modifier map (Shift, Lock, Control, Mod1..Mod5), 2 keycodes
        // each (modmap_per stays 2; the rest of the 64-byte buffer stays 0).
        const default_mod = [16]u8{ 50, 62, 66, 0, 37, 105, 64, 108, 77, 0, 0, 0, 133, 0, 108, 0 };
        @memcpy(self.modmap[0..16], &default_mod);
        // Open the fallback font used by ImageText8/PolyText8 when a GC's font
        // isn't a live Font resource. If the (injected) provider has no "fixed"
        // font this stays null and such text draws nothing (graceful).
        self.default_font = font_provider.openFont("fixed");
        errdefer if (self.default_font) |r| font_provider.closeFont(r);
        // RANDR's single output starts with a synthetic EDID property so
        // clients that read it recognize a (fake but valid) monitor.
        try self.seedEdid(gpa);
        return self;
    }

    /// Options for `initWith`: an injected renderer and/or font provider. A
    /// null field gets a heap-allocated default (owned + freed by this Display).
    pub const InitOptions = struct {
        renderer: ?render.Renderer = null,
        font_provider: ?fontprovider.FontProvider = null,
    };

    /// Build a Display, heap-allocating a default SoftwareRenderer and/or
    /// default Font8x8Provider for whichever of `opts` was not injected (each
    /// heap-allocated BEFORE initCommon so its interface ptr is stable across
    /// the by-value return -- the Renderer/FontProvider ptr must not dangle
    /// when Display moves into Server).
    pub fn initWith(gpa: std.mem.Allocator, root: u32, root_depth: u8, root_visual: u32, opts: InitOptions) std.mem.Allocator.Error!Display {
        var rimpl: ?*render.SoftwareRenderer = null;
        const renderer = if (opts.renderer) |r| r else blk: {
            const impl = try gpa.create(render.SoftwareRenderer);
            impl.* = .{ .gpa = gpa };
            rimpl = impl;
            break :blk impl.renderer();
        };
        errdefer if (rimpl) |i| gpa.destroy(i);
        var fimpl: ?*fontprovider.Font8x8Provider = null;
        const fp = if (opts.font_provider) |f| f else blk: {
            const impl = try gpa.create(fontprovider.Font8x8Provider);
            impl.* = .{};
            fimpl = impl;
            break :blk impl.provider();
        };
        errdefer if (fimpl) |i| gpa.destroy(i);
        var self = try initCommon(gpa, root, root_depth, root_visual, renderer, fp);
        self.owns_renderer = rimpl != null;
        self.renderer_impl = rimpl;
        self.owns_font_provider = fimpl != null;
        self.font_provider_impl = fimpl;
        return self;
    }

    /// Build a Display owning a default software renderer + default font
    /// provider. Keeps its original signature so server.zig + non-pixel tests
    /// are unchanged.
    pub fn init(gpa: std.mem.Allocator, root: u32, root_depth: u8, root_visual: u32) std.mem.Allocator.Error!Display {
        return initWith(gpa, root, root_depth, root_visual, .{});
    }

    /// Build a Display driving an injected renderer (e.g. a Prism-backed GPU
    /// backend). The caller owns the renderer's lifetime (owns_renderer = false).
    pub fn initWithRenderer(gpa: std.mem.Allocator, root: u32, root_depth: u8, root_visual: u32, renderer: render.Renderer) std.mem.Allocator.Error!Display {
        return initWith(gpa, root, root_depth, root_visual, .{ .renderer = renderer });
    }

    /// Build a Display driving an injected font provider (e.g. PhantomUI
    /// supplying real fonts). The caller owns its lifetime (owns_font_provider
    /// = false).
    pub fn initWithFontProvider(gpa: std.mem.Allocator, root: u32, root_depth: u8, root_visual: u32, font_provider: fontprovider.FontProvider) std.mem.Allocator.Error!Display {
        return initWith(gpa, root, root_depth, root_visual, .{ .font_provider = font_provider });
    }

    pub fn deinit(self: *Display) void {
        // Destroy every drawable surface through the renderer BEFORE freeing the
        // renderer itself (surfaces belong to it), then the rest of the tables.
        var it = self.windows.valueIterator();
        while (it.next()) |wptr| {
            wptr.children.deinit(self.gpa);
            wptr.masks.deinit(self.gpa);
            self.freeProps(wptr);
            self.renderer.destroySurface(wptr.surface);
        }
        self.windows.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.button_grabs.deinit(self.gpa);
        self.key_grabs.deinit(self.gpa);
        self.frozen_pointer_events.deinit(self.gpa);
        self.frozen_keyboard_events.deinit(self.gpa);
        self.save_set.deinit(self.gpa);
        self.randr_event_masks.deinit(self.gpa);
        self.randr_created_modes.deinit(self.gpa);
        self.randr_monitors.deinit(self.gpa);
        self.retained_temporary.deinit(self.gpa);
        // RANDR output-property store (e.g. the seeded EDID): free each
        // value's owned data before the map itself, same pattern as freeProps.
        var op_it = self.output_props.valueIterator();
        while (op_it.next()) |p| self.gpa.free(p.data);
        self.output_props.deinit(self.gpa);
        self.atoms.deinit(self.gpa);
        var px_it = self.pixmaps.valueIterator();
        while (px_it.next()) |p| self.renderer.destroySurface(p.surface);
        self.pixmaps.deinit(self.gpa);
        self.gcs.deinit(self.gpa);
        self.colormaps.deinit(self.gpa);
        self.installed_colormaps.deinit(self.gpa);
        self.selections.deinit(self.gpa);
        // Close every opened font ref (they belong to the provider) BEFORE
        // freeing the fonts map + BEFORE freeing the provider itself.
        {
            var fit = self.fonts.valueIterator();
            while (fit.next()) |f| self.font_provider.closeFont(f.ref);
        }
        if (self.default_font) |r| self.font_provider.closeFont(r);
        self.fonts.deinit(self.gpa);
        // Free the heap default renderer + font provider last (only when we
        // own them); all fonts/surfaces are closed/destroyed by now.
        if (self.owns_renderer) {
            if (self.renderer_impl) |impl| self.gpa.destroy(impl);
        }
        if (self.owns_font_provider) {
            if (self.font_provider_impl) |impl| self.gpa.destroy(impl);
        }
        self.* = undefined;
    }

    /// Drop all recorded pending events (retaining the backing capacity).
    /// server_main calls this after it has encoded + written them.
    pub fn clearPending(self: *Display) void {
        self.pending.clearRetainingCapacity();
    }

    fn recordEvent(self: *Display, ev: PendingEvent) std.mem.Allocator.Error!void {
        try self.pending.append(self.gpa, ev);
    }

    /// Record one event per client that selected `bit` on `selector`, each
    /// tagged with that client as target_client. Iterating `selector.masks`
    /// only reads the window table; recordEvent appends to the separate
    /// `pending` list, so `selector` stays valid across the loop.
    fn recordSelected(self: *Display, selector: *const Window, bit: u32, ev: PendingEvent) std.mem.Allocator.Error!void {
        for (selector.masks.items) |cm| {
            if (cm.mask & bit != 0) {
                var e = ev;
                e.target_client = cm.client;
                try self.recordEvent(e);
            }
        }
    }

    /// Record a GraphicsExpose for the requesting client only (not mask fan-out):
    /// a CopyArea/CopyPlane left part of the destination unfilled (source out of
    /// bounds), so that region needs repainting.
    pub fn recordGraphicsExpose(self: *Display, drawable_id: u32, client: u32, major: u8, x: i16, y: i16, width: u16, height: u16) std.mem.Allocator.Error!void {
        try self.recordEvent(.{ .kind = .graphics_expose, .event_window = drawable_id, .window = drawable_id, .target_client = client, .major_opcode = major, .x = x, .y = y, .width = width, .height = height, .count = 0 });
    }

    /// Record a NoExpose for the requesting client only: a CopyArea/CopyPlane
    /// fully filled its destination, so nothing needs repainting.
    pub fn recordNoExpose(self: *Display, drawable_id: u32, client: u32, major: u8) std.mem.Allocator.Error!void {
        try self.recordEvent(.{ .kind = .no_expose, .event_window = drawable_id, .window = drawable_id, .target_client = client, .major_opcode = major });
    }

    /// Record the DestroyNotify descriptors for `wid` (StructureNotify on the
    /// window, SubstructureNotify on its parent). Called BEFORE `wid` is removed
    /// so both masks are still readable.
    fn recordDestroy(self: *Display, wid: u32) EventError!void {
        const w = self.windows.getPtr(wid) orelse return;
        try self.recordSelected(w, structure_notify, .{ .kind = .destroy, .event_window = wid, .window = wid });
        const parent = w.parent;
        if (self.windows.getPtr(parent)) |pp| {
            try self.recordSelected(pp, substructure_notify, .{ .kind = .destroy, .event_window = parent, .window = wid });
        }
    }

    pub fn createWindow(self: *Display, wid: u32, parent: u32, geom: Geometry, class: u16, visual: u32, delta: AttrDelta, client_id: u32) CreateError!void {
        if (self.idInUse(wid)) return error.IdInUse;
        if (self.windows.count() >= self.max_windows) return error.TooManyResources;
        const p = self.windows.get(parent) orelse return error.NoParent;
        // Resolve CopyFromParent (0) for depth/visual/class from the parent.
        var g = geom;
        if (g.depth == 0) g.depth = p.geom.depth;
        const vis: u32 = if (visual == 0) p.visual else visual;
        const cls: u16 = if (class == 0) p.class else class;
        var attrs: Attributes = .{};
        delta.applyTo(&attrs);
        // Create the window's backing surface. Cap its size so a hostile huge
        // width*height fails cleanly instead of attempting a giant alloc.
        const buf_size = @as(usize, g.width) * @as(usize, g.height) * render.bytesPerPixel(g.depth);
        if (buf_size > self.max_pixmap_bytes) return error.TooManyResources;
        const surface = try self.renderer.createSurface(g.depth, g.width, g.height);
        self.windows.put(self.gpa, wid, .{ .id = wid, .parent = parent, .owner = client_id, .class = cls, .visual = vis, .geom = g, .attrs = attrs, .surface = surface }) catch |e| {
            self.renderer.destroySurface(surface); // not inserted -> destroy the surface
            return e;
        };
        // put() may rehash and invalidate any prior pointer, so re-fetch the
        // parent before mutating its child list.
        const pptr = self.windows.getPtr(parent).?;
        // If linking fails, roll the window back out of the table AND free its
        // buffer (its children/masks/props lists are still empty/zero-cap).
        pptr.children.append(self.gpa, wid) catch |e| {
            if (self.windows.fetchRemove(wid)) |kv| self.renderer.destroySurface(kv.value.surface);
            return e;
        };
        // Record the creating client's own selection on the new window.
        if (delta.event_mask) |m| {
            const wptr = self.windows.getPtr(wid).?;
            try wptr.setMask(self.gpa, client_id, m);
        }
        // CreateNotify -> every client that selected SubstructureNotify on the
        // parent (routed via `parent`, so event_window == parent).
        const pptr2 = self.windows.getPtr(parent).?;
        try self.recordSelected(pptr2, substructure_notify, .{
            .kind = .create,
            .event_window = parent,
            .window = wid,
            .parent = parent,
            .x = g.x,
            .y = g.y,
            .width = g.width,
            .height = g.height,
            .border_width = g.border_width,
            .override_redirect = attrs.override_redirect,
        });
    }

    pub fn destroyWindow(self: *Display, wid: u32) EventError!void {
        // DestroyWindow on the root is ignored (X11 semantics: no error, no-op);
        // the root outlives every client.
        if (wid == self.root) return;
        if (!self.windows.contains(wid)) return error.NoWindow;
        try self.destroySubtree(wid);
        try self.revertFocusIfInvalid();
        // A grab_window destroyed out from under its holder releases the grab
        // (there is no window left to route events on).
        self.revalidateGrabs();
    }

    /// Destroy `wid` and its whole subtree WITHOUT recursion, so a hostile deep
    /// window chain cannot overflow the call stack. Phase 1 collects every
    /// subtree id parents-first via an explicit heap stack. Phase 2 walks that
    /// list children-first, recording each DestroyNotify while all nodes are
    /// still present (so masks + parents stay readable); then a separate pass
    /// removes each node and frees its child list; finally the subtree root is
    /// unlinked from its (surviving) parent. Heap buffers are bounded by
    /// max_windows. On OOM the tree is left intact (nothing is removed until
    /// after every event is recorded), matching createWindow's fatal-OOM
    /// contract.
    fn destroySubtree(self: *Display, wid: u32) EventError!void {
        var order: std.ArrayListUnmanaged(u32) = .empty;
        defer order.deinit(self.gpa);
        var stack: std.ArrayListUnmanaged(u32) = .empty;
        defer stack.deinit(self.gpa);

        try stack.append(self.gpa, wid);
        while (stack.pop()) |id| {
            try order.append(self.gpa, id); // parents appended before their children
            if (self.windows.getPtr(id)) |w| {
                for (w.children.items) |child| try stack.append(self.gpa, child);
            }
        }

        const root_parent = if (self.windows.getPtr(wid)) |w| w.parent else 0;

        // Children-first: record DestroyNotify while everything still exists.
        var i: usize = order.items.len;
        while (i > 0) {
            i -= 1;
            try self.recordDestroy(order.items[i]);
        }
        // Now remove every node (order no longer matters - all events recorded).
        for (order.items) |id| {
            if (self.windows.getPtr(id)) |w| {
                w.children.deinit(self.gpa);
                w.masks.deinit(self.gpa);
                self.freeProps(w);
                self.renderer.destroySurface(w.surface);
            }
            _ = self.windows.remove(id);
            self.pruneSaveSetWindow(id); // no dangling save-set entry for a window that no longer exists
        }
        // Unlink the subtree root from its surviving parent.
        if (self.windows.getPtr(root_parent)) |pp| {
            for (pp.children.items, 0..) |c, j| {
                if (c == wid) {
                    _ = pp.children.orderedRemove(j);
                    break;
                }
            }
        }
    }

    /// The DESTRUCTIVE half of disconnect teardown: rescue save-set windows,
    /// then destroy every window/pixmap/gc/font this client owns.
    /// destroySubtree records a DestroyNotify for the whole subtree (including
    /// other clients' subwindows), so surviving selectors are notified; the
    /// caller delivers the recorded events. The owned ids are snapshotted
    /// first because destroying mutates the underlying tables. The root
    /// (owner 0) is guarded out so a client that happens to have id 0 never
    /// destroys it.
    ///
    /// Used by BOTH `cleanupClient` (SetCloseDownMode DestroyAll, right after
    /// a disconnect) and `killTemporary`/KillClient(resource) (destroying an
    /// already-*retained* client's resources later, potentially long after
    /// its connection is gone) -- so this function must not touch anything
    /// connection-specific (masks/grabs live in `scrubClientConnection`,
    /// already run at retain time for a retained client).
    pub fn destroyClientResources(self: *Display, client_id: u32) EventError!void {
        // Save-set: rescue this client's save-set windows (owned by OTHER
        // clients) that live inside this client's own subtree by reparenting
        // them to root (preserving their absolute position) BEFORE we destroy
        // this client's windows below -- otherwise destroySubtree would take
        // them down with the frames that hold them (ICCCM save-set contract).
        {
            var i: usize = 0;
            while (i < self.save_set.items.len) {
                const e = self.save_set.items[i];
                if (e.client == client_id) {
                    if (self.windows.getPtr(e.window) != null and self.isInferiorOfClient(e.window, client_id)) {
                        const abs = self.absOrigin(e.window);
                        const nx: i16 = @intCast(std.math.clamp(abs.x, -32768, 32767));
                        const ny: i16 = @intCast(std.math.clamp(abs.y, -32768, 32767));
                        self.reparentWindow(e.window, self.root, nx, ny, client_id) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            // Best-effort during teardown: the window (or root,
                            // which never happens) vanished, or reparenting it
                            // is otherwise disallowed -- nothing left to rescue.
                            error.NoWindow, error.BadMatch => {},
                        };
                    }
                    _ = self.save_set.orderedRemove(i); // consumed, whether rescued or not
                } else i += 1;
            }
        }
        var owned: std.ArrayListUnmanaged(u32) = .empty;
        defer owned.deinit(self.gpa);
        {
            var it = self.windows.valueIterator();
            while (it.next()) |w| {
                if (w.owner == client_id and w.id != self.root) try owned.append(self.gpa, w.id);
            }
        }
        for (owned.items) |id| {
            // A later id may already be gone (it was a subwindow of an
            // earlier-destroyed owned window); skip those.
            if (self.windows.contains(id)) try self.destroySubtree(id);
        }
        // Free the client's pixmaps (snapshot ids first; can't remove mid-iterate).
        var owned_px: std.ArrayListUnmanaged(u32) = .empty;
        defer owned_px.deinit(self.gpa);
        var pit = self.pixmaps.iterator();
        while (pit.next()) |e| {
            if (e.value_ptr.owner == client_id) try owned_px.append(self.gpa, e.key_ptr.*);
        }
        for (owned_px.items) |id| {
            if (self.pixmaps.fetchRemove(id)) |kv| self.renderer.destroySurface(kv.value.surface);
        }
        // Free the client's GCs (no buffers; snapshot ids then remove).
        var owned_gc: std.ArrayListUnmanaged(u32) = .empty;
        defer owned_gc.deinit(self.gpa);
        var git = self.gcs.iterator();
        while (git.next()) |e| {
            if (e.value_ptr.owner == client_id) try owned_gc.append(self.gpa, e.key_ptr.*);
        }
        for (owned_gc.items) |id| _ = self.gcs.remove(id);
        // Free the client's fonts (snapshot ids then remove, same pattern as
        // GCs), closing each ref via the provider before dropping it -- refs
        // belong to the provider, not this table.
        var owned_ft: std.ArrayListUnmanaged(u32) = .empty;
        defer owned_ft.deinit(self.gpa);
        var fit = self.fonts.iterator();
        while (fit.next()) |e| {
            if (e.value_ptr.owner == client_id) try owned_ft.append(self.gpa, e.key_ptr.*);
        }
        for (owned_ft.items) |id| {
            if (self.fonts.fetchRemove(id)) |kv| self.font_provider.closeFont(kv.value.ref);
        }
        // Free the client's colormaps (snapshot ids then remove, same pattern
        // as GCs/fonts), also dropping each from the installed set. The
        // default colormap (owner 0 = server) is never owned by a client id,
        // so it survives every disconnect unconditionally.
        var owned_cm: std.ArrayListUnmanaged(u32) = .empty;
        defer owned_cm.deinit(self.gpa);
        var cit = self.colormaps.iterator();
        while (cit.next()) |e| {
            if (e.value_ptr.owner == client_id) try owned_cm.append(self.gpa, e.key_ptr.*);
        }
        for (owned_cm.items) |id| {
            _ = self.colormaps.remove(id);
            self.uninstallColormapId(id);
        }
    }

    /// The NON-destructive half of disconnect teardown: scrub this client's
    /// event selections from every surviving window and release its grabs
    /// (both active and passive). A client with no live connection can no
    /// longer receive events or hold a grab, whether or not its resources are
    /// being kept alive (SetCloseDownMode Retain*) -- so this runs for every
    /// disconnect, destructive or not.
    fn scrubClientConnection(self: *Display, client_id: u32) std.mem.Allocator.Error!void {
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            var i: usize = 0;
            while (i < w.masks.items.len) {
                if (w.masks.items[i].client == client_id) {
                    _ = w.masks.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
        // Drop this client's RANDR SelectInput registrations too -- a stale
        // entry could otherwise "deliver" to a client no longer connected
        // once the dynamic-RANDR follow-up starts emitting through this list.
        {
            var i: usize = 0;
            while (i < self.randr_event_masks.items.len) {
                if (self.randr_event_masks.items[i].client == client_id) _ = self.randr_event_masks.orderedRemove(i) else i += 1;
            }
        }
        // Release any grabs this client held -- a dropped client must not
        // leave a dangling grab that starves every other client of input.
        // (Also prunes the client's passive GrabButton/GrabKey registrations.)
        self.releaseGrabsForClient(client_id);
        // A different, still-connected client may hold a grab on a window this
        // client owned (possibly just destroyed by destroyClientResources);
        // release any such dangling grab.
        self.revalidateGrabs();
        // Disown every selection this client held. Nobody is left to receive a
        // SelectionClear (the client is gone), so this is a silent drop -- NOT
        // a call to setSelectionOwner. Cannot remove map entries while
        // iterating the hashmap, so collect the keys first (same
        // snapshot-then-remove pattern destroyClientResources uses for
        // pixmaps/gcs/fonts/colormaps).
        var dead: std.ArrayListUnmanaged(u32) = .empty;
        defer dead.deinit(self.gpa);
        var sit = self.selections.iterator();
        while (sit.next()) |entry| {
            if (entry.value_ptr.client == client_id) try dead.append(self.gpa, entry.key_ptr.*);
        }
        for (dead.items) |sel| _ = self.selections.remove(sel);
    }

    /// SetCloseDownMode(DestroyAll) disconnect teardown (the default, and the
    /// only mode before 4r): destroy everything the client owns, then scrub
    /// its connection traces. Order: destroy first (matches the original,
    /// unfactored behavior -- save-set rescue and window/pixmap/gc/font
    /// destruction happen before masks/grabs are scrubbed), so tests written
    /// against the old single function still see the exact same end state.
    pub fn cleanupClient(self: *Display, client_id: u32) EventError!void {
        try self.destroyClientResources(client_id);
        try self.scrubClientConnection(client_id);
    }

    /// SetCloseDownMode(Retain*) disconnect teardown: scrub the client's
    /// connection traces (masks + grabs -- nobody is left to deliver to or
    /// hold a grab on its behalf) but KEEP its windows/pixmaps/gcs/fonts alive
    /// under its owner id. A future KillClient (either targeting one of its
    /// resources directly, or AllTemporary via killTemporary) destroys them.
    /// `temporary` records the client id in `retained_temporary` for
    /// killTemporary to later sweep -- RetainPermanent (temporary == false)
    /// clients are retained the same way but never auto-swept, only killed by
    /// an explicit KillClient(resource).
    pub fn retainClient(self: *Display, client_id: u32, temporary: bool) std.mem.Allocator.Error!void {
        try self.scrubClientConnection(client_id);
        if (temporary) try self.retained_temporary.append(self.gpa, client_id);
    }

    /// KillClient(AllTemporary, resource == 0): destroy the resources of
    /// every client retained under SetCloseDownMode(RetainTemporary), then
    /// forget them. destroyClientResources is idempotent for an id with
    /// nothing left owned (an empty scan), so a partial failure that leaves
    /// some ids still in the list is safe to retry on a later call.
    pub fn killTemporary(self: *Display) EventError!void {
        for (self.retained_temporary.items) |id| try self.destroyClientResources(id);
        self.retained_temporary.clearRetainingCapacity();
    }

    /// The owner client of a window/pixmap/gc/font resource id (whether that
    /// client is still connected or retained), or null if `resource` names
    /// none of those tables. KillClient(resource) uses this to find who to
    /// tear down; the caller treats null as an unresolvable resource (BadValue).
    pub fn ownerOf(self: *Display, resource: u32) ?u32 {
        if (self.windows.get(resource)) |w| return w.owner;
        if (self.pixmaps.get(resource)) |p| return p.owner;
        if (self.gcs.get(resource)) |g| return g.owner;
        if (self.fonts.get(resource)) |f| return f.owner;
        if (self.colormaps.get(resource)) |c| return c.owner;
        return null;
    }

    pub fn mapWindow(self: *Display, wid: u32, client_id: u32) EventError!void {
        if (wid == self.root) return; // the root is always viewable; MapWindow(root) is a no-op
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        if (w.map_state == .viewable) return; // MapNotify only on a real transition
        // SubstructureRedirect: hand a non-override-redirect child's map to the WM
        // (the redirect holder on the parent) if that WM is a DIFFERENT client, and
        // leave the window unmapped. The WM maps it itself -- being the redirect
        // holder, its own MapWindow is not re-intercepted (X: "some other client").
        if (!w.attrs.override_redirect) {
            if (self.windows.getPtr(w.parent)) |pp| {
                if (redirectClient(pp)) |rc| {
                    if (rc != client_id) {
                        try self.recordEvent(.{ .kind = .map_request, .target_client = rc, .event_window = w.parent, .parent = w.parent, .window = wid });
                        return;
                    }
                }
            }
        }
        w.map_state = .viewable;
        const orr = w.attrs.override_redirect;
        try self.recordSelected(w, structure_notify, .{ .kind = .map, .event_window = wid, .window = wid, .override_redirect = orr });
        const parent = w.parent;
        if (self.windows.getPtr(parent)) |pp| {
            try self.recordSelected(pp, substructure_notify, .{ .kind = .map, .event_window = parent, .window = wid, .override_redirect = orr });
        }
        // A freshly-viewable InputOutput window has lost contents (no backing
        // store here), so tell any Exposure-selecting client to repaint it all.
        // InputOnly (class 2) has no pixel buffer, so nothing to expose.
        if (w.class != 2) {
            // Clear the freshly-viewable window to its background before exposing it,
            // so a client sees its background_pixel (X paints the background on map).
            // No backing store, so this is a one-shot paint of the whole surface.
            self.renderer.fillRect(w.surface, 0, 0, w.geom.width, w.geom.height, w.attrs.background_pixel);
            try self.recordSelected(w, exposure, .{
                .kind = .expose,
                .event_window = wid,
                .window = wid,
                .x = 0,
                .y = 0,
                .width = w.geom.width,
                .height = w.geom.height,
                .count = 0,
            });
        }
    }

    pub fn unmapWindow(self: *Display, wid: u32) EventError!void {
        if (wid == self.root) return; // the root cannot be unmapped
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        // UnmapNotify fires only if the window was mapped. 3a never yields the
        // `unviewable` state, so "not unmapped" == "was mapped" here.
        if (w.map_state == .unmapped) return;
        w.map_state = .unmapped;
        try self.recordSelected(w, structure_notify, .{ .kind = .unmap, .event_window = wid, .window = wid });
        const parent = w.parent;
        if (self.windows.getPtr(parent)) |pp| {
            try self.recordSelected(pp, substructure_notify, .{ .kind = .unmap, .event_window = parent, .window = wid });
        }
        try self.revertFocusIfInvalid();
    }

    /// WarpPointer: move the pointer to an absolute position, optionally
    /// gated by a source rectangle (the move is skipped entirely, no error,
    /// when the pointer is not currently inside it). dst_window == None (0)
    /// means a RELATIVE move by (dst_x, dst_y) from the current position;
    /// otherwise the target is absOrigin(dst_window) + (dst_x, dst_y).
    /// Reuses injectMotion so a warp generates the same MotionNotify /
    /// crossing events a real pointer move would.
    pub fn warpPointer(self: *Display, src_window: u32, dst_window: u32, src_x: i16, src_y: i16, src_width: u16, src_height: u16, dst_x: i16, dst_y: i16) EventError!void {
        if (src_window != 0) {
            const sw = self.windows.getPtr(src_window) orelse return error.NoWindow;
            const so = self.absOrigin(src_window);
            const rx: i32 = so.x + @as(i32, src_x);
            const ry: i32 = so.y + @as(i32, src_y);
            // width/height == 0 means "to the window's far edge" from (src_x,src_y).
            const rw: i32 = if (src_width == 0) @as(i32, sw.geom.width) - @as(i32, src_x) else @as(i32, src_width);
            const rh: i32 = if (src_height == 0) @as(i32, sw.geom.height) - @as(i32, src_y) else @as(i32, src_height);
            const px: i32 = self.pointer_x;
            const py: i32 = self.pointer_y;
            if (px < rx or px >= rx + rw or py < ry or py >= ry + rh) return; // outside the source constraint: no-op, no error
        }
        var tx: i32 = undefined;
        var ty: i32 = undefined;
        if (dst_window == 0) {
            tx = @as(i32, self.pointer_x) + @as(i32, dst_x);
            ty = @as(i32, self.pointer_y) + @as(i32, dst_y);
        } else {
            if (!self.windows.contains(dst_window)) return error.NoWindow;
            const dorigin = self.absOrigin(dst_window);
            tx = dorigin.x + @as(i32, dst_x);
            ty = dorigin.y + @as(i32, dst_y);
        }
        const ctx = clampI16(tx);
        const cty = clampI16(ty);
        if (ctx == self.pointer_x and cty == self.pointer_y) return; // no movement: X generates no motion event
        self.prop_time +%= 1;
        try self.injectMotion(ctx, cty, self.prop_time);
    }

    /// MapSubwindows: map every child of `wid`, in children-list order. Each
    /// child goes through the canonical mapWindow (so SubstructureRedirect
    /// interception and the already-mapped skip both apply per child, same as
    /// if the client had called MapWindow on each one itself). The children
    /// are snapshotted into a local list first -- mapWindow never mutates the
    /// parent's children list, but snapshotting is defensive and cheap.
    pub fn mapSubwindows(self: *Display, wid: u32, client_id: u32) EventError!void {
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        var children: std.ArrayListUnmanaged(u32) = .empty;
        defer children.deinit(self.gpa);
        for (w.children.items) |cid| try children.append(self.gpa, cid);
        for (children.items) |cid| try self.mapWindow(cid, client_id);
    }

    /// UnmapSubwindows: unmap every child of `wid`, in children-list order.
    /// Same snapshot-then-iterate shape as mapSubwindows.
    pub fn unmapSubwindows(self: *Display, wid: u32) EventError!void {
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        var children: std.ArrayListUnmanaged(u32) = .empty;
        defer children.deinit(self.gpa);
        for (w.children.items) |cid| try children.append(self.gpa, cid);
        for (children.items) |cid| try self.unmapWindow(cid);
    }

    /// Reparent `wid` into `new_parent` at (x,y), on top of its new siblings.
    /// A mapped window is auto-unmapped first (UnmapNotify to the OLD parent)
    /// and auto-remapped after (under the NEW parent), matching core X
    /// semantics. ReparentWindow itself is never SubstructureRedirect-intercepted.
    pub fn reparentWindow(self: *Display, wid: u32, new_parent: u32, x: i16, y: i16, client_id: u32) (error{ NoWindow, BadMatch } || std.mem.Allocator.Error)!void {
        if (wid == self.root) return error.BadMatch; // the root cannot be reparented
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        const np = self.windows.getPtr(new_parent) orelse return error.NoWindow; // BadWindow: parent missing
        // BadMatch: InputOutput window cannot become a child of an InputOnly window.
        if (w.class == 1 and np.class == 2) return error.BadMatch;
        // Cycle guard: new_parent must not be the window or a descendant of it.
        if (new_parent == wid) return error.BadMatch;
        {
            var cur = new_parent;
            var depth: usize = 0;
            while (depth < MAX_POINTER_DEPTH) : (depth += 1) {
                const cp = self.windows.getPtr(cur) orelse break;
                if (cur == self.root) break;
                cur = cp.parent;
                if (cur == wid) return error.BadMatch; // window is an ancestor of new_parent
                if (cur == 0) break;
            }
        }
        const was_mapped = w.map_state == .viewable;
        // 1. Auto-unmap first (UnmapNotify to window + OLD parent) while parent is old.
        if (was_mapped) try self.unmapWindow(wid);
        // 2. Move in the tree. Append to the NEW parent first (the only fallible
        //    tree op) so an OOM leaves the old tree intact -- then unlink from the
        //    old parent (infallible). (Same-parent restack is handled fine: the
        //    orderedRemove below drops the original entry, leaving the appended
        //    one on top.)
        const old_parent = w.parent;
        try np.children.append(self.gpa, wid); // on top
        if (self.windows.getPtr(old_parent)) |op| {
            for (op.children.items, 0..) |c, i| if (c == wid) {
                _ = op.children.orderedRemove(i);
                break;
            };
        }
        w.parent = new_parent;
        w.geom.x = x;
        w.geom.y = y;
        // 3. ReparentNotify: window StructureNotify + old & new parent SubstructureNotify.
        const orr = w.attrs.override_redirect;
        try self.recordSelected(w, structure_notify, .{ .kind = .reparent, .event_window = wid, .window = wid, .parent = new_parent, .x = x, .y = y, .override_redirect = orr });
        // Skip the old-parent notify when the parent is unchanged, so a
        // reparent-to-same-parent does not deliver a duplicate ReparentNotify.
        if (old_parent != new_parent) {
            if (self.windows.getPtr(old_parent)) |op| try self.recordSelected(op, substructure_notify, .{ .kind = .reparent, .event_window = old_parent, .window = wid, .parent = new_parent, .x = x, .y = y, .override_redirect = orr });
        }
        try self.recordSelected(np, substructure_notify, .{ .kind = .reparent, .event_window = new_parent, .window = wid, .parent = new_parent, .x = x, .y = y, .override_redirect = orr });
        // 4. Auto-remap if it was mapped.
        if (was_mapped) try self.mapWindow(wid, client_id);
    }

    /// ChangeSaveSet: add (mode Insert=0) or remove (mode Delete=1) `window`
    /// from `client_id`'s save-set. A client may only save-set OTHER clients'
    /// windows (BadMatch on its own); the window must exist (NoWindow); any
    /// other mode value is BadValue. See `cleanupClient`'s rescue block for
    /// what the save-set is for. No reply, no events.
    pub fn changeSaveSet(self: *Display, mode: u8, window: u32, client_id: u32) (error{ BadValue, NoWindow, BadMatch } || std.mem.Allocator.Error)!void {
        if (mode > 1) return error.BadValue;
        const w = self.windows.getPtr(window) orelse return error.NoWindow;
        if (w.owner == client_id) return error.BadMatch; // may only save-set OTHER clients' windows
        if (mode == 0) { // Insert (idempotent: a repeat Insert is a no-op)
            for (self.save_set.items) |e| if (e.client == client_id and e.window == window) return;
            try self.save_set.append(self.gpa, .{ .client = client_id, .window = window });
        } else { // Delete: remove every matching entry (there is at most one, but
            // walk defensively rather than assume Insert's idempotency held).
            var i: usize = 0;
            while (i < self.save_set.items.len) {
                if (self.save_set.items[i].client == client_id and self.save_set.items[i].window == window) {
                    _ = self.save_set.orderedRemove(i);
                } else i += 1;
            }
        }
    }

    /// Remove every save-set entry naming `wid` -- called when `wid` is
    /// destroyed (destroySubtree), so a stale entry never outlives the window
    /// it points at (whether the window was destroyed by its own owner or was
    /// some other client's save-set target).
    fn pruneSaveSetWindow(self: *Display, wid: u32) void {
        var i: usize = 0;
        while (i < self.save_set.items.len) {
            if (self.save_set.items[i].window == wid) {
                _ = self.save_set.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Is `wid` an inferior of (a window owned by) `client`? Walks wid's
    /// ancestor chain (bounded by MAX_POINTER_DEPTH, matching every other
    /// tree walk in this file) -- true if `wid` itself or any ancestor up to
    /// (not including) the root is owned by `client`. A save-set window that
    /// already sits directly under root, outside any of the client's frames,
    /// needs no rescue and returns false.
    fn isInferiorOfClient(self: *Display, wid: u32, client: u32) bool {
        var cur = wid;
        var depth: usize = 0;
        while (cur != 0 and cur != self.root and depth < MAX_POINTER_DEPTH) : (depth += 1) {
            const w = self.windows.getPtr(cur) orelse return false;
            if (w.owner == client) return true;
            cur = w.parent;
        }
        return false;
    }

    pub fn changeAttributes(self: *Display, wid: u32, delta: AttrDelta, client_id: u32) (error{ NoWindow, Access } || std.mem.Allocator.Error)!void {
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        // SubstructureRedirect is an EXCLUSIVE selection: only one client may hold it
        // on a window. Reject a second holder with BadAccess.
        if (delta.event_mask) |m| {
            if (m & substructure_redirect != 0) {
                for (w.masks.items) |cm| {
                    if (cm.client != client_id and cm.mask & substructure_redirect != 0) return error.Access;
                }
            }
        }
        delta.applyTo(&w.attrs);
        if (delta.event_mask) |m| try w.setMask(self.gpa, client_id, m);
    }

    /// Reorder `wid` within its parent's (bottom-to-top) child list per
    /// stack_mode + optional sibling. Callers validated the sibling. Only
    /// grows the list back to its prior length, so it does not actually
    /// allocate, but insert's signature is fallible.
    fn restack(self: *Display, wid: u32, parent: u32, sibling: ?u32, stack_mode: u32) std.mem.Allocator.Error!void {
        const pp = self.windows.getPtr(parent) orelse return;
        var idx: ?usize = null;
        for (pp.children.items, 0..) |c, i| if (c == wid) {
            idx = i;
            break;
        };
        if (idx == null) return; // not a child (shouldn't happen)
        _ = pp.children.orderedRemove(idx.?);
        if (sibling) |sib| {
            for (pp.children.items, 0..) |c, i| if (c == sib) {
                // Below/BottomIf -> just below the sibling; else just above it.
                const pos: usize = switch (stack_mode) {
                    1, 3 => i,
                    else => i + 1,
                };
                try pp.children.insert(self.gpa, pos, wid);
                return;
            };
            // sibling vanished: fall through to the no-sibling behavior.
        }
        switch (stack_mode) {
            1, 3 => try pp.children.insert(self.gpa, 0, wid), // Below/BottomIf -> bottom
            else => try pp.children.append(self.gpa, wid), // Above/TopIf/Opposite -> top
        }
    }

    /// Move/resize/restack a window and fire a ConfigureNotify. The value-list
    /// arrives with wire widths; validated + narrowed here. On the root it is a
    /// no-op (X ignores root geometry changes). If a DIFFERENT client holds
    /// SubstructureRedirect on the parent and the window is not override-redirect,
    /// the configure is handed to that WM (ConfigureRequest) and nothing is
    /// applied; otherwise it is applied directly.
    pub fn configureWindow(self: *Display, wid: u32, delta: ConfigDelta, client_id: u32) ConfigError!void {
        if (wid == self.root) return;
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        // SubstructureRedirect: hand a non-override-redirect child's configure to the
        // WM (different client) WITHOUT applying it or validating it; the WM decides.
        // Unset fields carry the window's current geometry; value_mask flags which the
        // client actually requested. @truncate the untrusted delta values so a
        // hostile redirected configure cannot panic (no validation on this path).
        if (!w.attrs.override_redirect) {
            if (self.windows.getPtr(w.parent)) |pp| {
                if (redirectClient(pp)) |rc| {
                    if (rc != client_id) {
                        var vm: u16 = 0;
                        if (delta.x != null) vm |= 1;
                        if (delta.y != null) vm |= 2;
                        if (delta.width != null) vm |= 4;
                        if (delta.height != null) vm |= 8;
                        if (delta.border_width != null) vm |= 16;
                        if (delta.sibling != null) vm |= 32;
                        if (delta.stack_mode != null) vm |= 64;
                        try self.recordEvent(.{
                            .kind = .configure_request,
                            .target_client = rc,
                            .event_window = w.parent,
                            .parent = w.parent,
                            .window = wid,
                            .x = if (delta.x) |v| @truncate(v) else w.geom.x,
                            .y = if (delta.y) |v| @truncate(v) else w.geom.y,
                            .width = if (delta.width) |v| @truncate(v) else w.geom.width,
                            .height = if (delta.height) |v| @truncate(v) else w.geom.height,
                            .border_width = if (delta.border_width) |v| @truncate(v) else w.geom.border_width,
                            .above_sibling = delta.sibling orelse 0,
                            .detail = if (delta.stack_mode) |v| @truncate(v) else 0,
                            .value_mask = vm,
                        });
                        return;
                    }
                }
            }
        }
        // Validate width/height and stacking BEFORE any mutation.
        var new_w = w.geom.width;
        var new_h = w.geom.height;
        if (delta.width) |ww| {
            if (ww == 0 or ww > 65535) return error.BadValue;
            new_w = @intCast(ww);
        }
        if (delta.height) |hh| {
            if (hh == 0 or hh > 65535) return error.BadValue;
            new_h = @intCast(hh);
        }
        if (delta.sibling != null and delta.stack_mode == null) return error.BadMatch;
        if (delta.stack_mode) |sm| {
            if (sm > 4) return error.BadValue;
        }
        if (delta.sibling) |sib| {
            const s = self.windows.getPtr(sib) orelse return error.BadMatch;
            if (s.parent != w.parent) return error.BadMatch;
        }
        // Resize the backing surface if the dimensions changed (before mutating
        // geom). resizeSurface updates w.surface.width/height in place + zeroes.
        // Captured here (before geom is mutated below) so the post-ConfigureNotify
        // expose block can still tell whether this configure changed dimensions.
        const dims_changed = new_w != w.geom.width or new_h != w.geom.height;
        if (dims_changed) {
            const size = @as(usize, new_w) * @as(usize, new_h) * render.bytesPerPixel(w.geom.depth);
            if (size > self.max_pixmap_bytes) return error.TooLarge;
            try self.renderer.resizeSurface(&w.surface, new_w, new_h);
        }
        // Apply geometry.
        if (delta.x) |xx| w.geom.x = @truncate(xx);
        if (delta.y) |yy| w.geom.y = @truncate(yy);
        if (delta.border_width) |bw| w.geom.border_width = @truncate(bw);
        w.geom.width = new_w;
        w.geom.height = new_h;
        // Restack.
        if (delta.stack_mode) |sm| try self.restack(wid, w.parent, delta.sibling, sm);
        // Record ConfigureNotify (StructureNotify on the window, SubstructureNotify
        // on the parent). above_sibling = the sibling directly below wid now.
        const parent = w.parent;
        var above: u32 = 0;
        if (self.windows.getPtr(parent)) |pp| {
            var i: usize = 0;
            while (i < pp.children.items.len) : (i += 1) {
                if (pp.children.items[i] == wid) {
                    if (i > 0) above = pp.children.items[i - 1];
                    break;
                }
            }
        }
        const orr = w.attrs.override_redirect;
        const base: PendingEvent = .{
            .kind = .configure,
            .event_window = wid,
            .window = wid,
            .above_sibling = above,
            .x = w.geom.x,
            .y = w.geom.y,
            .width = w.geom.width,
            .height = w.geom.height,
            .border_width = w.geom.border_width,
            .override_redirect = orr,
        };
        try self.recordSelected(w, structure_notify, base);
        if (self.windows.getPtr(parent)) |pp| {
            var sub = base;
            sub.event_window = parent;
            try self.recordSelected(pp, substructure_notify, sub);
        }
        // A resize reallocated + zeroed the backing surface, so the window's contents
        // are lost. Repaint the background and expose the whole window (as on map) so
        // an Exposure-selecting client repaints. Move/restack-only configures preserve
        // content (persistent buffers) and expose nothing. InputOnly (2) has no surface.
        if (dims_changed and w.map_state == .viewable and w.class != 2) {
            self.renderer.fillRect(w.surface, 0, 0, w.geom.width, w.geom.height, w.attrs.background_pixel);
            try self.recordSelected(w, exposure, .{
                .kind = .expose,
                .event_window = wid,
                .window = wid,
                .x = 0,
                .y = 0,
                .width = w.geom.width,
                .height = w.geom.height,
                .count = 0,
            });
        }
    }

    pub fn getGeometry(self: *Display, wid: u32) WindowError!Geometry {
        const w = self.windows.get(wid) orelse return error.NoWindow;
        return w.geom;
    }

    pub fn getAttributes(self: *Display, wid: u32, client_id: u32) WindowError!AttrView {
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        return .{
            .class = w.class,
            .visual = w.visual,
            .map_state = w.map_state,
            .attrs = w.attrs,
            .your_event_mask = w.maskFor(client_id),
            .all_event_masks = w.allMasks(),
        };
    }

    pub fn queryTree(self: *Display, wid: u32) WindowError!TreeView {
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        return .{ .root = self.root, .parent = w.parent, .children = w.children.items };
    }

    /// Is `wid` currently .viewable? Missing window counts as not mapped.
    fn windowMapped(self: *Display, wid: u32) bool {
        if (self.windows.getPtr(wid)) |w| return w.map_state == .viewable;
        return false;
    }

    /// Do two children's OUTER rects (border-inclusive) overlap? Used to decide
    /// occlusion for CirculateWindow. Missing window counts as no overlap.
    fn childrenOverlap(self: *Display, a: u32, b: u32) bool {
        const wa = self.windows.getPtr(a) orelse return false;
        const wb = self.windows.getPtr(b) orelse return false;
        const ax0: i32 = wa.geom.x;
        const ax1 = ax0 + @as(i32, wa.geom.width) + 2 * @as(i32, wa.geom.border_width);
        const ay0: i32 = wa.geom.y;
        const ay1 = ay0 + @as(i32, wa.geom.height) + 2 * @as(i32, wa.geom.border_width);
        const bx0: i32 = wb.geom.x;
        const bx1 = bx0 + @as(i32, wb.geom.width) + 2 * @as(i32, wb.geom.border_width);
        const by0: i32 = wb.geom.y;
        const by1 = by0 + @as(i32, wb.geom.height) + 2 * @as(i32, wb.geom.border_width);
        return ax0 < bx1 and bx0 < ax1 and ay0 < by1 and by0 < ay1;
    }

    /// Restack ONE of `window`'s children by occlusion: RaiseLowest(0) raises the
    /// lowest mapped child occluded by a higher mapped sibling to the top;
    /// LowerHighest(1) lowers the highest mapped child that occludes a lower
    /// mapped sibling to the bottom. No qualifying child -> no-op, no event. If a
    /// DIFFERENT client holds SubstructureRedirect on `window`, a CirculateRequest
    /// is sent to it instead and nothing is restacked (same redirect pattern as
    /// mapWindow/configureWindow).
    pub fn circulateWindow(self: *Display, window: u32, direction: u8, client_id: u32) (error{ NoWindow, BadValue } || std.mem.Allocator.Error)!void {
        if (direction > 1) return error.BadValue;
        const w = self.windows.getPtr(window) orelse return error.NoWindow;
        const ch = w.children.items;
        var pick: ?usize = null;
        if (direction == 0) { // RaiseLowest: lowest child occluded by a higher sibling
            var i: usize = 0;
            outer0: while (i < ch.len) : (i += 1) {
                if (!self.windowMapped(ch[i])) continue;
                var j = i + 1;
                while (j < ch.len) : (j += 1) {
                    if (self.windowMapped(ch[j]) and self.childrenOverlap(ch[i], ch[j])) {
                        pick = i;
                        break :outer0;
                    }
                }
            }
        } else { // LowerHighest: highest child occluding a lower sibling
            var i = ch.len;
            outer1: while (i > 0) {
                i -= 1;
                if (!self.windowMapped(ch[i])) continue;
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    if (self.windowMapped(ch[j]) and self.childrenOverlap(ch[i], ch[j])) {
                        pick = i;
                        break :outer1;
                    }
                }
            }
        }
        const idx = pick orelse return; // nothing to circulate
        const child = ch[idx];
        const place: u8 = if (direction == 0) 0 else 1;
        // Redirect: a DIFFERENT client holding SubstructureRedirect on `window`
        // intercepts the circulate (CirculateRequest, no restack).
        if (redirectClient(w)) |rc| {
            if (rc != client_id) {
                try self.recordEvent(.{ .kind = .circulate_request, .target_client = rc, .event_window = window, .window = child, .detail = place });
                return;
            }
        }
        // Restack (the captured `ch` slice is now stale; mutate via w.children).
        // `w` itself stays valid: children ops realloc only the child
        // ArrayList, not the windows map that owns `w`.
        _ = w.children.orderedRemove(idx);
        if (direction == 0) try w.children.append(self.gpa, child) else try w.children.insert(self.gpa, 0, child);
        // CirculateNotify: child StructureNotify + parent SubstructureNotify.
        if (self.windows.getPtr(child)) |cw| try self.recordSelected(cw, structure_notify, .{ .kind = .circulate, .event_window = child, .window = child, .detail = place });
        try self.recordSelected(w, substructure_notify, .{ .kind = .circulate, .event_window = window, .window = child, .detail = place });
    }

    /// Fill `out` with the chain root..deepest-viewable-window containing
    /// (px,py) in root coords, each node carrying that window's absolute
    /// drawable origin. At each level hit-tests children top-to-bottom (children
    /// is bottom-to-top, so reversed); a child matches when the point is in its
    /// OUTER rect (`geom` inflated by border_width) and it is `.viewable`.
    /// InputOnly windows participate; unmapped/unviewable are skipped. Bounded
    /// by MAX_POINTER_DEPTH. Root is always the first node.
    pub fn pointerPath(self: *Display, px: i16, py: i16, out: *std.ArrayListUnmanaged(PathNode)) std.mem.Allocator.Error!void {
        out.clearRetainingCapacity();
        var cur = self.root;
        var abs_x: i32 = 0; // the root's drawable origin is (0,0)
        var abs_y: i32 = 0;
        var depth: usize = 0;
        while (depth < MAX_POINTER_DEPTH) : (depth += 1) {
            try out.append(self.gpa, .{ .wid = cur, .abs_x = abs_x, .abs_y = abs_y });
            const w = self.windows.getPtr(cur) orelse break;
            var found: ?u32 = null;
            var child_abs_x: i32 = 0;
            var child_abs_y: i32 = 0;
            var i = w.children.items.len;
            while (i > 0) {
                i -= 1;
                const cid = w.children.items[i];
                const cw = self.windows.getPtr(cid) orelse continue;
                if (cw.map_state != .viewable) continue;
                const ox: i32 = abs_x + cw.geom.x; // outer-rect origin in root coords
                const oy: i32 = abs_y + cw.geom.y;
                const bw: i32 = cw.geom.border_width;
                const ow: i32 = @as(i32, cw.geom.width) + 2 * bw;
                const oh: i32 = @as(i32, cw.geom.height) + 2 * bw;
                if (px >= ox and px < ox + ow and py >= oy and py < oy + oh) {
                    found = cid;
                    child_abs_x = ox + bw; // drawable origin = outer origin + border
                    child_abs_y = oy + bw;
                    break;
                }
            }
            if (found) |fc| {
                cur = fc;
                abs_x = child_abs_x;
                abs_y = child_abs_y;
            } else break;
        }
    }

    /// The deepest viewable window under (px,py); root is the floor.
    pub fn windowAt(self: *Display, px: i16, py: i16) std.mem.Allocator.Error!u32 {
        var path: std.ArrayListUnmanaged(PathNode) = .empty;
        defer path.deinit(self.gpa);
        try self.pointerPath(px, py, &path);
        return path.items[path.items.len - 1].wid;
    }

    /// The absolute drawable origin (root coords) of `wid`: the running sum of
    /// each ancestor's `geom` offset plus its border width. Bounded by
    /// MAX_POINTER_DEPTH.
    pub fn absOrigin(self: *Display, wid: u32) struct { x: i32, y: i32 } {
        var x: i32 = 0;
        var y: i32 = 0;
        var cur = wid;
        var depth: usize = 0;
        while (cur != 0 and depth < MAX_POINTER_DEPTH) : (depth += 1) {
            const w = self.windows.getPtr(cur) orelse break;
            x += @as(i32, w.geom.x) + w.geom.border_width;
            y += @as(i32, w.geom.y) + w.geom.border_width;
            cur = w.parent;
        }
        return .{ .x = x, .y = y };
    }

    /// Clamp a wider coordinate sum to the wire's i16 range rather than
    /// truncating, so extreme (but legal per-window) geometry can't silently
    /// wrap into a bogus reply value.
    fn clampI16(v: i32) i16 {
        return @intCast(std.math.clamp(v, -32768, 32767));
    }

    /// The topmost mapped child of `parent` whose outer rect contains the root-coord
    /// point (rx,ry), else 0. Same hit-test as pointerPath (viewable, border-inclusive).
    fn childContaining(self: *Display, parent: u32, rx: i32, ry: i32) u32 {
        const w = self.windows.getPtr(parent) orelse return 0;
        const po = self.absOrigin(parent); // parent drawable origin in root coords
        var i = w.children.items.len;
        while (i > 0) {
            i -= 1;
            const cid = w.children.items[i];
            const cw = self.windows.getPtr(cid) orelse continue;
            if (cw.map_state != .viewable) continue;
            const bw: i32 = cw.geom.border_width;
            const ox: i32 = po.x + cw.geom.x;
            const oy: i32 = po.y + cw.geom.y;
            const ow: i32 = @as(i32, cw.geom.width) + 2 * bw;
            const oh: i32 = @as(i32, cw.geom.height) + 2 * bw;
            if (rx >= ox and rx < ox + ow and ry >= oy and ry < oy + oh) return cid;
        }
        return 0;
    }

    /// QueryPointer: the pointer's absolute position + its position relative to
    /// `window`'s drawable origin + the topmost mapped child of `window` under
    /// the pointer + the current button/modifier mask.
    pub fn queryPointer(self: *Display, window: u32) error{NoWindow}!PointerInfo {
        _ = self.windows.getPtr(window) orelse return error.NoWindow;
        const wo = self.absOrigin(window);
        return .{
            .root = self.root,
            .child = self.childContaining(window, self.pointer_x, self.pointer_y),
            .root_x = self.pointer_x,
            .root_y = self.pointer_y,
            .win_x = clampI16(@as(i32, self.pointer_x) - wo.x),
            .win_y = clampI16(@as(i32, self.pointer_y) - wo.y),
            .mask = self.input_state,
        };
    }

    /// TranslateCoordinates: re-express (src_x,src_y), relative to `src_window`,
    /// relative to `dst_window` instead, plus the child of dst_window containing it.
    pub fn translateCoordinates(self: *Display, src_window: u32, dst_window: u32, src_x: i16, src_y: i16) error{NoWindow}!TranslateResult {
        _ = self.windows.getPtr(src_window) orelse return error.NoWindow;
        _ = self.windows.getPtr(dst_window) orelse return error.NoWindow;
        const so = self.absOrigin(src_window);
        const dobj = self.absOrigin(dst_window);
        const abs_x: i32 = so.x + src_x;
        const abs_y: i32 = so.y + src_y;
        return .{
            .child = self.childContaining(dst_window, abs_x, abs_y),
            .dst_x = clampI16(abs_x - dobj.x),
            .dst_y = clampI16(abs_y - dobj.y),
        };
    }

    /// Does any client select `bit` on `w`?
    fn anySelector(w: *const Window, bit: u32) bool {
        for (w.masks.items) |cm| if (cm.mask & bit != 0) return true;
        return false;
    }

    /// Deliver a device event by propagation: walk `path` from target (last) up
    /// to root, record on the first window with any client selecting `bit`, with
    /// coordinates relative to that window and `child` = the path node one level
    /// below it (0 if the selecting window is the target). No selector anywhere
    /// in the path -> the event is dropped (normal X device-event behavior).
    fn recordDevice(self: *Display, path: []const PathNode, bit: u32, kind: EventKind, detail: u8, px: i16, py: i16, time: u32) std.mem.Allocator.Error!void {
        var i = path.len;
        while (i > 0) {
            i -= 1;
            const node = path[i];
            const w = self.windows.getPtr(node.wid) orelse continue;
            if (!anySelector(w, bit)) continue;
            const child: u32 = if (i + 1 < path.len) path[i + 1].wid else 0;
            try self.recordSelected(w, bit, .{
                .kind = kind,
                .event_window = node.wid,
                .window = node.wid,
                .detail = detail,
                .root = self.root,
                .child = child,
                .root_x = px,
                .root_y = py,
                .event_x = @truncate(@as(i32, px) - node.abs_x),
                .event_y = @truncate(@as(i32, py) - node.abs_y),
                .input_state = self.input_state,
                .time = time,
            });
            return;
        }
    }

    /// Record the endpoint crossing when the pointer moves from `old` window to
    /// `new`: LeaveNotify on `old` (its LeaveWindow selectors) THEN EnterNotify
    /// on `new` (its EnterWindow selectors). Endpoint-only, detail=Nonlinear(3),
    /// mode=Normal(0) - the intermediate virtual-crossing chain is deferred.
    /// Enter/Leave do not propagate.
    fn recordCrossing(self: *Display, old: u32, new: u32, px: i16, py: i16, time: u32) std.mem.Allocator.Error!void {
        if (self.windows.getPtr(old)) |ow| {
            const o = self.absOrigin(old);
            try self.recordSelected(ow, leave_window, .{
                .kind = .leave,
                .event_window = old,
                .window = old,
                .detail = 3, // NotifyNonlinear
                .mode = 0, // NotifyNormal
                .root = self.root,
                .child = 0,
                .root_x = px,
                .root_y = py,
                .event_x = @truncate(@as(i32, px) - o.x),
                .event_y = @truncate(@as(i32, py) - o.y),
                .input_state = self.input_state,
                .time = time,
            });
        }
        if (self.windows.getPtr(new)) |nw| {
            const n = self.absOrigin(new);
            try self.recordSelected(nw, enter_window, .{
                .kind = .enter,
                .event_window = new,
                .window = new,
                .detail = 3,
                .mode = 0,
                .root = self.root,
                .child = 0,
                .root_x = px,
                .root_y = py,
                .event_x = @truncate(@as(i32, px) - n.x),
                .event_y = @truncate(@as(i32, py) - n.y),
                .input_state = self.input_state,
                .time = time,
            });
        }
    }

    pub const FocusError = error{ NoWindow, NotViewable, BadValue } || std.mem.Allocator.Error;

    /// Record FocusOut(old) then FocusIn(new), but only for real-window endpoints
    /// (None(0)/PointerRoot(1) are not windows). Endpoint-only, detail=Nonlinear(3),
    /// mode=Normal(0); the full focus crossing chain is deferred (as with Enter/Leave).
    fn recordFocusChange(self: *Display, old: u32, new: u32) std.mem.Allocator.Error!void {
        if (old > 1) {
            if (self.windows.getPtr(old)) |ow| {
                try self.recordSelected(ow, focus_change, .{ .kind = .focus_out, .event_window = old, .window = old, .detail = 3, .mode = 0 });
            }
        }
        if (new > 1) {
            if (self.windows.getPtr(new)) |nw| {
                try self.recordSelected(nw, focus_change, .{ .kind = .focus_in, .event_window = new, .window = new, .detail = 3, .mode = 0 });
            }
        }
    }

    /// Set the keyboard focus. `focus` = None(0) / PointerRoot(1) / a window that
    /// must exist and be viewable. Fires FocusOut(old)+FocusIn(new). `time` is
    /// accepted unconditionally (no CurrentTime/timestamp comparison modeled).
    pub fn setInputFocus(self: *Display, focus: u32, revert_to: u8, time: u32) FocusError!void {
        _ = time;
        if (revert_to > 2) return error.BadValue;
        if (focus > 1) {
            const w = self.windows.getPtr(focus) orelse return error.NoWindow;
            if (w.map_state != .viewable) return error.NotViewable;
        }
        const old = self.focus;
        try self.recordFocusChange(old, focus);
        self.focus = focus;
        self.focus_revert = revert_to;
    }

    /// If the focus window has become invalid (destroyed or not viewable), revert
    /// the focus per focus_revert: Parent -> the window's parent (or root if the
    /// window is gone - a documented simplification, since a destroyed window's
    /// parent is unknown here); PointerRoot -> 1; None -> 0. Fires the focus
    /// change. None/PointerRoot focus needs no revert.
    fn revertFocusIfInvalid(self: *Display) std.mem.Allocator.Error!void {
        if (self.focus <= 1) return;
        const maybe = self.windows.getPtr(self.focus);
        const invalid = (maybe == null) or (maybe.?.map_state != .viewable);
        if (!invalid) return;
        const old = self.focus;
        const new: u32 = switch (self.focus_revert) {
            2 => if (maybe) |w| w.parent else self.root, // Parent (root if the window is gone)
            1 => 1, // PointerRoot
            else => 0, // None
        };
        try self.recordFocusChange(old, new);
        self.focus = new;
    }

    /// Set an active pointer grab for `client`. Returns the GrabPointer status:
    /// 0 Success (free, or re-grabbed by the same client that already holds
    /// it), 1 AlreadyGrabbed (another client holds it), 3 NotViewable
    /// (grab_window doesn't exist or isn't viewable; the root is always
    /// viewable). A successful grab stores `pointer_mode`/`keyboard_mode`; a
    /// Sync mode FREEZES that device immediately (no activating event to
    /// replay -- an explicit grab has none, unlike a passive one).
    pub fn grabPointer(self: *Display, grab_window: u32, event_mask: u16, owner_events: bool, pointer_mode: u8, keyboard_mode: u8, client: u32) u8 {
        if (self.windows.getPtr(grab_window)) |gw| {
            if (gw.map_state != .viewable) return 3;
        } else if (grab_window != self.root) return 3;
        if (self.pointer_grab) |g| {
            if (g.client != client) return 1;
        }
        self.pointer_grab = .{ .client = client, .grab_window = grab_window, .event_mask = event_mask, .owner_events = owner_events, .pointer_mode = pointer_mode, .keyboard_mode = keyboard_mode };
        // pointer_mode freezes the pointer itself; keyboard_mode freezes the
        // OTHER device (a cross-mode freeze) -- both are owned by THIS grab
        // (.pointer_grab), so both teardown (clearPointerGrab) and AllowEvents
        // can find and thaw them even though keyboard_grab stays null here.
        if (pointer_mode == mode_sync) {
            self.pointer_frozen = true;
            self.pointer_freeze_owner = .pointer_grab;
        }
        if (keyboard_mode == mode_sync) {
            self.keyboard_frozen = true;
            self.keyboard_freeze_owner = .pointer_grab;
        }
        return 0;
    }

    /// Release the pointer grab if `client` holds it (a no-op otherwise -- X
    /// ignores UngrabPointer from a non-holder rather than erroring). Routed
    /// through clearPointerGrab so a Sync freeze + its queue are dropped too.
    pub fn ungrabPointer(self: *Display, client: u32) void {
        if (self.pointer_grab) |g| {
            if (g.client == client) self.clearPointerGrab();
        }
    }

    /// Set an active keyboard grab for `client`. Same status codes + Sync
    /// freeze behavior as grabPointer. Keyboard-grab owner_events is stored
    /// but not yet acted on (keys always deliver to grab_window this slice --
    /// the refinement is deferred; keyboard grabs are usually owner_events=false anyway).
    pub fn grabKeyboard(self: *Display, grab_window: u32, owner_events: bool, pointer_mode: u8, keyboard_mode: u8, client: u32) u8 {
        if (self.windows.getPtr(grab_window)) |gw| {
            if (gw.map_state != .viewable) return 3;
        } else if (grab_window != self.root) return 3;
        if (self.keyboard_grab) |g| {
            if (g.client != client) return 1;
        }
        self.keyboard_grab = .{ .client = client, .grab_window = grab_window, .owner_events = owner_events, .pointer_mode = pointer_mode, .keyboard_mode = keyboard_mode };
        // Mirror of grabPointer above: pointer_mode==Sync here freezes the
        // pointer as a CROSS-mode freeze owned by THIS (.keyboard_grab) grab,
        // even though pointer_grab stays null.
        if (pointer_mode == mode_sync) {
            self.pointer_frozen = true;
            self.pointer_freeze_owner = .keyboard_grab;
        }
        if (keyboard_mode == mode_sync) {
            self.keyboard_frozen = true;
            self.keyboard_freeze_owner = .keyboard_grab;
        }
        return 0;
    }

    /// Release the keyboard grab if `client` holds it. Routed through
    /// clearKeyboardGrab so a Sync freeze + its queue are dropped too.
    pub fn ungrabKeyboard(self: *Display, client: u32) void {
        if (self.keyboard_grab) |g| {
            if (g.client == client) self.clearKeyboardGrab();
        }
    }

    /// Unfreeze the pointer + discard its queue (DISCARDED, not replayed --
    /// AllowEvents is the supported thaw path; see the module doc). Does NOT
    /// touch pointer_grab -- callers own that.
    fn clearPointerFreeze(self: *Display) void {
        self.pointer_frozen = false;
        self.pointer_resync = false;
        self.pointer_trigger = null;
        self.pointer_freeze_owner = .none;
        self.frozen_pointer_events.clearRetainingCapacity();
    }

    /// Keyboard-side equivalent of clearPointerFreeze.
    fn clearKeyboardFreeze(self: *Display) void {
        self.keyboard_frozen = false;
        self.keyboard_resync = false;
        self.keyboard_trigger = null;
        self.keyboard_freeze_owner = .none;
        self.frozen_keyboard_events.clearRetainingCapacity();
    }

    /// Clear the active pointer grab and every bit of Sync-freeze state IT
    /// OWNS -- which is not necessarily only the pointer's: a GrabPointer
    /// whose keyboard_mode was Sync also freezes the KEYBOARD (see
    /// grabPointer), and that freeze must thaw here too, or the keyboard
    /// would be stuck frozen forever with no live grab left to release it
    /// (the bug this owner-tracking fixes). Every pointer-grab teardown site
    /// routes through here instead of `pointer_grab = null` so none of them
    /// can leave a device stuck frozen with a stale queue.
    fn clearPointerGrab(self: *Display) void {
        self.pointer_grab = null;
        if (self.pointer_freeze_owner == .pointer_grab) self.clearPointerFreeze();
        if (self.keyboard_freeze_owner == .pointer_grab) self.clearKeyboardFreeze();
    }

    /// Keyboard-side equivalent of clearPointerGrab: also thaws a POINTER
    /// freeze this keyboard grab owns (GrabKeyboard's pointer_mode==Sync).
    fn clearKeyboardGrab(self: *Display) void {
        self.keyboard_grab = null;
        if (self.keyboard_freeze_owner == .keyboard_grab) self.clearKeyboardFreeze();
        if (self.pointer_freeze_owner == .keyboard_grab) self.clearPointerFreeze();
    }

    /// Register a passive pointer grab (GrabButton, op 28). BadAccess if a
    /// DIFFERENT client already holds a registration on the same
    /// (grab_window,button,modifiers) triple -- a genuine conflict (two WMs
    /// fighting over the same combo). The SAME client re-registering the
    /// identical triple is allowed (harmlessly duplicated; ungrabButton
    /// removes every one of the caller's matches at once).
    pub fn grabButton(self: *Display, grab_window: u32, event_mask: u16, owner_events: bool, button: u8, modifiers: u16, pointer_mode: u8, keyboard_mode: u8, client: u32) (error{Access} || std.mem.Allocator.Error)!void {
        for (self.button_grabs.items) |g| {
            if (g.grab_window == grab_window and g.button == button and g.modifiers == modifiers and g.client != client) return error.Access;
        }
        try self.button_grabs.append(self.gpa, .{ .client = client, .grab_window = grab_window, .event_mask = event_mask, .owner_events = owner_events, .button = button, .modifiers = modifiers, .pointer_mode = pointer_mode, .keyboard_mode = keyboard_mode });
    }

    /// Remove every passive button grab `client` registered matching
    /// (button,grab_window,modifiers) (UngrabButton, op 29). A no-op if none
    /// match, mirroring ungrabPointer's non-holder tolerance.
    pub fn ungrabButton(self: *Display, button: u8, grab_window: u32, modifiers: u16, client: u32) void {
        var i: usize = 0;
        while (i < self.button_grabs.items.len) {
            const g = self.button_grabs.items[i];
            if (g.client == client and g.grab_window == grab_window and g.button == button and g.modifiers == modifiers) {
                _ = self.button_grabs.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Register a passive keyboard grab (GrabKey, op 33). Same conflict rule
    /// as grabButton.
    pub fn grabKey(self: *Display, grab_window: u32, owner_events: bool, key: u8, modifiers: u16, pointer_mode: u8, keyboard_mode: u8, client: u32) (error{Access} || std.mem.Allocator.Error)!void {
        for (self.key_grabs.items) |g| {
            if (g.grab_window == grab_window and g.key == key and g.modifiers == modifiers and g.client != client) return error.Access;
        }
        try self.key_grabs.append(self.gpa, .{ .client = client, .grab_window = grab_window, .owner_events = owner_events, .key = key, .modifiers = modifiers, .pointer_mode = pointer_mode, .keyboard_mode = keyboard_mode });
    }

    /// Remove every passive key grab `client` registered matching
    /// (key,grab_window,modifiers) (UngrabKey, op 34).
    pub fn ungrabKey(self: *Display, key: u8, grab_window: u32, modifiers: u16, client: u32) void {
        var i: usize = 0;
        while (i < self.key_grabs.items.len) {
            const g = self.key_grabs.items[i];
            if (g.client == client and g.grab_window == grab_window and g.key == key and g.modifiers == modifiers) {
                _ = self.key_grabs.orderedRemove(i);
            } else i += 1;
        }
    }

    /// The first registered passive button grab matching `button` at the
    /// CURRENT modifier state (input_state carries the mods held BEFORE this
    /// press), whose grab_window is an ancestor-or-self of the pointer
    /// window. Simplified from real X (which prefers the most specific
    /// match); the dominant WM case (one root grab per combo) never hits the
    /// difference.
    fn matchButtonGrab(self: *Display, button: u8) ?ButtonGrabSpec {
        const mods: u16 = self.input_state & 0xff;
        for (self.button_grabs.items) |g| {
            if ((g.button == 0 or g.button == button) and (g.modifiers == 0x8000 or g.modifiers == mods) and self.isInSubtree(g.grab_window, self.pointer_window)) return g;
        }
        return null;
    }

    /// The first registered passive key grab matching `key`, analogous to
    /// matchButtonGrab. Matched against the POINTER window (not the focus
    /// window -- see the module's passive-grab note): the dominant WM case
    /// registers on the root, an ancestor of everything, so it matches
    /// regardless of focus.
    fn matchKeyGrab(self: *Display, key: u8) ?KeyGrabSpec {
        const mods: u16 = self.input_state & 0xff;
        for (self.key_grabs.items) |g| {
            if ((g.key == 0 or g.key == key) and (g.modifiers == 0x8000 or g.modifiers == mods) and self.isInSubtree(g.grab_window, self.pointer_window)) return g;
        }
        return null;
    }

    /// Release both grabs `client` holds (called from cleanupClient on
    /// disconnect -- a dropped client must not leave a dangling grab that
    /// starves every other client of input).
    fn releaseGrabsForClient(self: *Display, client: u32) void {
        if (self.pointer_grab) |g| {
            if (g.client == client) self.clearPointerGrab();
        }
        if (self.keyboard_grab) |g| {
            if (g.client == client) self.clearKeyboardGrab();
        }
        // The client's PASSIVE registrations must go too -- a stale entry
        // could otherwise auto-activate after disconnect with nobody left to
        // deliver to.
        {
            var i: usize = 0;
            while (i < self.button_grabs.items.len) {
                if (self.button_grabs.items[i].client == client) _ = self.button_grabs.orderedRemove(i) else i += 1;
            }
        }
        {
            var i: usize = 0;
            while (i < self.key_grabs.items.len) {
                if (self.key_grabs.items[i].client == client) _ = self.key_grabs.orderedRemove(i) else i += 1;
            }
        }
    }

    /// Release a grab whose grab_window no longer exists (called after a
    /// destroy, like revertFocusIfInvalid for focus). The root is never
    /// destroyed, so a root grab_window never trips this.
    fn revalidateGrabs(self: *Display) void {
        if (self.pointer_grab) |g| {
            if (g.grab_window != self.root and !self.windows.contains(g.grab_window)) self.clearPointerGrab();
        }
        if (self.keyboard_grab) |g| {
            if (g.grab_window != self.root and !self.windows.contains(g.grab_window)) self.clearKeyboardGrab();
        }
        // Prune passive registrations on a destroyed grab_window too --
        // matchButtonGrab/matchKeyGrab would never match them again (a
        // destroyed window can't be in any pointer subtree), but pruning
        // stops the tables accumulating dead entries forever.
        {
            var i: usize = 0;
            while (i < self.button_grabs.items.len) {
                const g = self.button_grabs.items[i];
                if (g.grab_window != self.root and !self.windows.contains(g.grab_window)) _ = self.button_grabs.orderedRemove(i) else i += 1;
            }
        }
        {
            var i: usize = 0;
            while (i < self.key_grabs.items.len) {
                const g = self.key_grabs.items[i];
                if (g.grab_window != self.root and !self.windows.contains(g.grab_window)) _ = self.key_grabs.orderedRemove(i) else i += 1;
            }
        }
    }

    /// Deliver a motion/button event to a client holding an active pointer
    /// grab, bypassing the normal spatial propagation (recordDevice) entirely.
    /// owner_events=true: report to the grab client's OWN selecting window
    /// under the pointer (walked deepest-first along `path`, the same as
    /// recordDevice) if any such window exists; else fall through to
    /// grab_window. owner_events=false (or no such window found): grab_window,
    /// filtered by the grab's event_mask -- a grab that didn't ask for `bit`
    /// on grab_window sees nothing here. `child` in the grab_window case is
    /// always 0 (the exact child-under-pointer is a deferred refinement).
    fn recordPointerGrabbed(self: *Display, grab: PointerGrab, path: []const PathNode, bit: u32, kind: EventKind, detail: u8, px: i16, py: i16, time: u32) std.mem.Allocator.Error!void {
        if (grab.owner_events) {
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const node = path[i];
                const wp = self.windows.getPtr(node.wid) orelse continue;
                if (wp.maskFor(grab.client) & bit != 0) {
                    const child: u32 = if (i + 1 < path.len) path[i + 1].wid else 0;
                    try self.recordEvent(.{
                        .kind = kind,
                        .target_client = grab.client,
                        .event_window = node.wid,
                        .window = node.wid,
                        .detail = detail,
                        .root = self.root,
                        .child = child,
                        .root_x = px,
                        .root_y = py,
                        .event_x = @truncate(@as(i32, px) - node.abs_x),
                        .event_y = @truncate(@as(i32, py) - node.abs_y),
                        .input_state = self.input_state,
                        .time = time,
                    });
                    return;
                }
            }
        }
        if (grab.event_mask & @as(u16, @truncate(bit)) == 0) return;
        if (grab.grab_window != self.root and !self.windows.contains(grab.grab_window)) return; // gone; revalidateGrabs should have caught it
        const o = self.absOrigin(grab.grab_window);
        try self.recordEvent(.{
            .kind = kind,
            .target_client = grab.client,
            .event_window = grab.grab_window,
            .window = grab.grab_window,
            .detail = detail,
            .root = self.root,
            .child = 0,
            .root_x = px,
            .root_y = py,
            .event_x = @truncate(@as(i32, px) - o.x),
            .event_y = @truncate(@as(i32, py) - o.y),
            .input_state = self.input_state,
            .time = time,
        });
    }

    /// Deliver a key event to a client holding an active keyboard grab, on
    /// grab_window, bypassing focus routing entirely. No event_mask filter (a
    /// keyboard grab captures every key). Coords are relative to grab_window,
    /// using the CURRENT pointer position (keys carry the pointer position,
    /// same as the un-grabbed path in injectKey).
    fn recordKeyGrabbed(self: *Display, grab: KeyboardGrab, keycode: u8, pressed: bool, time: u32) std.mem.Allocator.Error!void {
        const kind: EventKind = if (pressed) .key_press else .key_release;
        if (grab.grab_window != self.root and !self.windows.contains(grab.grab_window)) return; // gone; revalidateGrabs should have caught it
        const o = self.absOrigin(grab.grab_window);
        try self.recordEvent(.{
            .kind = kind,
            .target_client = grab.client,
            .event_window = grab.grab_window,
            .window = grab.grab_window,
            .detail = keycode,
            .root = self.root,
            .child = 0,
            .root_x = self.pointer_x,
            .root_y = self.pointer_y,
            .event_x = @truncate(@as(i32, self.pointer_x) - o.x),
            .event_y = @truncate(@as(i32, self.pointer_y) - o.y),
            .input_state = self.input_state,
            .time = time,
        });
    }

    /// RAW motion dispatch: current routing verbatim, no freeze check (motion
    /// never activates a passive grab, so there is no preamble to strip).
    /// Records a MotionNotify routed by propagation to the window under the
    /// pointer, plus an endpoint Leave(old)+Enter(new) crossing (in that
    /// order) when the target window under the pointer changed.
    fn dispatchMotion(self: *Display, px: i16, py: i16, time: u32) std.mem.Allocator.Error!void {
        var path: std.ArrayListUnmanaged(PathNode) = .empty;
        defer path.deinit(self.gpa);
        try self.pointerPath(px, py, &path);
        const target = path.items[path.items.len - 1].wid;
        self.pointer_x = px;
        self.pointer_y = py;
        if (self.pointer_grab) |grab| {
            // A pointer grab suppresses the normal Enter/Leave crossing (X
            // would emit NotifyGrab-mode crossings instead -- deferred, so we
            // just suppress). pointer_window is still tracked silently so
            // crossing resumes correctly once the grab is released.
            self.pointer_window = target;
            try self.recordPointerGrabbed(grab, path.items, pointer_motion, .motion, 0, px, py, time);
            return;
        }
        if (target != self.pointer_window) {
            try self.recordCrossing(self.pointer_window, target, px, py, time);
            self.pointer_window = target;
        }
        try self.recordDevice(path.items, pointer_motion, .motion, 0, px, py, time);
    }

    /// Inject a pointer motion to (px,py) (root coords). While the pointer is
    /// frozen (a Sync grab), the motion QUEUES instead of dispatching -- no
    /// pointer_x/y update, no event (see the module's Sync-freeze doc on
    /// pointer_frozen). Otherwise dispatches immediately.
    pub fn injectMotion(self: *Display, px: i16, py: i16, time: u32) std.mem.Allocator.Error!void {
        if (self.pointer_frozen) {
            try self.appendFrozenPointer(.{ .kind = .motion, .detail = 0, .px = px, .py = py, .time = time });
            return;
        }
        try self.dispatchMotion(px, py, time);
    }

    /// Append to frozen_pointer_events, capped at max_frozen_events -- the
    /// OLDEST queued event is dropped first to make room (see the const's
    /// doc). Shared by injectMotion + injectButton's frozen-append branches.
    fn appendFrozenPointer(self: *Display, ev: FrozenEvent) std.mem.Allocator.Error!void {
        if (self.frozen_pointer_events.items.len >= max_frozen_events) _ = self.frozen_pointer_events.orderedRemove(0);
        try self.frozen_pointer_events.append(self.gpa, ev);
    }

    /// Keyboard-side equivalent of appendFrozenPointer.
    fn appendFrozenKeyboard(self: *Display, ev: FrozenEvent) std.mem.Allocator.Error!void {
        if (self.frozen_keyboard_events.items.len >= max_frozen_events) _ = self.frozen_keyboard_events.orderedRemove(0);
        try self.frozen_keyboard_events.append(self.gpa, ev);
    }

    /// RAW button dispatch: current routing verbatim minus the passive-grab
    /// activation preamble (that stays in the public injectButton wrapper, so
    /// it only runs once per press, not on every replay of this raw path).
    fn dispatchButton(self: *Display, button: u8, pressed: bool, time: u32) std.mem.Allocator.Error!void {
        var path: std.ArrayListUnmanaged(PathNode) = .empty;
        defer path.deinit(self.gpa);
        try self.pointerPath(self.pointer_x, self.pointer_y, &path);
        const bit: u32 = if (pressed) button_press else button_release;
        const kind: EventKind = if (pressed) .button_press else .button_release;
        if (self.pointer_grab) |grab| {
            try self.recordPointerGrabbed(grab, path.items, bit, kind, button, self.pointer_x, self.pointer_y, time);
        } else {
            try self.recordDevice(path.items, bit, kind, button, self.pointer_x, self.pointer_y, time);
        }
        // Update the button mask AFTER recording so `state` carries the state
        // BEFORE the event (X semantics). Buttons 1..5 -> mask 0x100<<(n-1).
        if (button >= 1 and button <= 5) {
            const mask: u16 = @as(u16, 0x100) << @intCast(button - 1);
            if (pressed) self.input_state |= mask else self.input_state &= ~mask;
        }
        // Auto-release: a passively-activated grab drops once every button is
        // back up (X's whole-click grab semantics), freeing the device for
        // the next passive match. Routed through clearPointerGrab so a Sync
        // freeze it carried is cleared too.
        if (!pressed) {
            if (self.pointer_grab) |g| {
                if (g.auto and (self.input_state & 0x1f00) == 0) self.clearPointerGrab();
            }
        }
        // AllowEvents(SyncPointer) resync hook (Task 2): re-freeze right after
        // this button dispatches. pointer_resync is always false until Task 2
        // wires allowEvents, so this is inert in Task 1.
        if (self.pointer_resync) {
            self.pointer_frozen = true;
            self.pointer_resync = false;
        }
    }

    /// Inject a button press/release at the current pointer position. While
    /// the pointer is frozen (a Sync grab), the event QUEUES instead of
    /// dispatching. Otherwise: a matching passive grab (GrabButton)
    /// AUTO-ACTIVATES a pointer grab before dispatch, so the very press that
    /// triggered it is delivered through the newly-active grab (see
    /// matchButtonGrab); if that activation is Sync-mode, the device freezes
    /// AFTER the trigger is delivered, and the trigger is remembered
    /// (pointer_trigger) for AllowEvents ReplayPointer (Task 2).
    pub fn injectButton(self: *Display, button: u8, pressed: bool, time: u32) std.mem.Allocator.Error!void {
        if (self.pointer_frozen) {
            try self.appendFrozenPointer(.{ .kind = if (pressed) .button_press else .button_release, .detail = button, .px = self.pointer_x, .py = self.pointer_y, .time = time });
            return;
        }
        var activated = false;
        if (self.pointer_grab == null and pressed) {
            if (self.matchButtonGrab(button)) |g| {
                self.pointer_grab = .{ .client = g.client, .grab_window = g.grab_window, .event_mask = g.event_mask, .owner_events = g.owner_events, .pointer_mode = g.pointer_mode, .keyboard_mode = g.keyboard_mode, .auto = true };
                activated = true;
            }
        }
        try self.dispatchButton(button, pressed, time); // delivers the trigger through the (possibly just-activated) grab
        if (activated) {
            if (self.pointer_grab) |gr| {
                if (gr.pointer_mode == mode_sync) {
                    self.pointer_frozen = true;
                    self.pointer_freeze_owner = .pointer_grab;
                    self.pointer_trigger = .{ .kind = if (pressed) .button_press else .button_release, .detail = button, .px = self.pointer_x, .py = self.pointer_y, .time = time };
                }
                // A cross-mode freeze: this passive BUTTON grab's
                // keyboard_mode==Sync freezes the KEYBOARD, owned by THIS
                // (.pointer_grab) grab even though keyboard_grab stays null.
                if (gr.keyboard_mode == mode_sync) {
                    self.keyboard_frozen = true;
                    self.keyboard_freeze_owner = .pointer_grab;
                }
            }
        }
    }

    /// Is `ancestor` an ancestor-or-self of `descendant`? Walks the parent chain,
    /// bounded by MAX_POINTER_DEPTH.
    fn isInSubtree(self: *Display, ancestor: u32, descendant: u32) bool {
        var cur = descendant;
        var depth: usize = 0;
        while (cur != 0 and depth < MAX_POINTER_DEPTH) : (depth += 1) {
            if (cur == ancestor) return true;
            const w = self.windows.getPtr(cur) orelse return false;
            cur = w.parent;
        }
        return false;
    }

    /// Fill `out` with the chain root..wid, each node carrying its absolute
    /// drawable origin. Walks wid's parent chain up (bounded by MAX_POINTER_DEPTH)
    /// then emits it reversed. Callers guard wid's existence first.
    pub fn pathToWindow(self: *Display, wid: u32, out: *std.ArrayListUnmanaged(PathNode)) std.mem.Allocator.Error!void {
        out.clearRetainingCapacity();
        var chain: [MAX_POINTER_DEPTH]u32 = undefined;
        var n: usize = 0;
        var cur = wid;
        while (cur != 0 and n < MAX_POINTER_DEPTH) {
            chain[n] = cur;
            n += 1;
            const w = self.windows.getPtr(cur) orelse break;
            cur = w.parent;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            const o = self.absOrigin(chain[i]);
            try out.append(self.gpa, .{ .wid = chain[i], .abs_x = o.x, .abs_y = o.y });
        }
    }

    pub const KeyboardMap = struct { per: u8, syms: []const u32 };

    /// The keysyms for keycodes [first, first+count). `first` below min_keycode
    /// or the range past max_keycode -> BadValue. Borrows the keymap array.
    pub fn keyboardMapping(self: *Display, first: u8, count: u8) error{BadValue}!KeyboardMap {
        if (first < min_keycode) return error.BadValue;
        if (@as(u32, first) + count > @as(u32, max_keycode) + 1) return error.BadValue;
        const start = (@as(usize, first) - min_keycode) * 2;
        const len = @as(usize, count) * 2;
        return .{ .per = 2, .syms = self.keymap[start .. start + len] };
    }

    pub const ModifierMap = struct { per: u8, codes: []const u8 };

    /// The 8-modifier x modmap_per-keycode map in wire order. Borrows the
    /// live prefix of the modmap array (SetModifierMapping picks modmap_per).
    pub fn modifierMapping(self: *Display) ModifierMap {
        return .{ .per = self.modmap_per, .codes = self.modmap[0 .. 8 * @as(usize, self.modmap_per)] };
    }

    /// The modifier index (0=Shift .. 7=Mod5) a nonzero keycode belongs to, else null.
    fn modifierIndexOf(self: *Display, keycode: u8) ?u3 {
        if (keycode == 0) return null;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            var k: usize = 0;
            while (k < self.modmap_per) : (k += 1) {
                if (self.modmap[i * @as(usize, self.modmap_per) + k] == keycode) return @intCast(i);
            }
        }
        return null;
    }

    /// GetPointerMapping: the current physical->logical button map (len 5).
    pub fn getPointerMapping(self: *Display) []const u8 {
        return &self.pointer_map;
    }

    /// SetPointerMapping: replace the button map. The client must send
    /// exactly `pointer_map.len` (5) entries -- our button count is fixed --
    /// else BadValue. 0 disables a button; no dedup rule. We do not model a
    /// currently-down remapped button (Busy(1)); always Success(0) on a
    /// valid-length map.
    pub fn setPointerMapping(self: *Display, map: []const u8) error{BadValue}!u8 {
        if (map.len != self.pointer_map.len) return error.BadValue;
        @memcpy(&self.pointer_map, map);
        return 0; // Success
    }

    /// SetModifierMapping: replace the modifier map wholesale.
    /// `keycodes_per_modifier` bounds the buffer we own (up to 8); the
    /// keycode list must be exactly `8 * keycodes_per_modifier` long
    /// (malformed otherwise) and every NONZERO keycode must be a real
    /// keycode (0 means "no key", always allowed). We do not model
    /// Busy/Failed (grabbed device / a modifier currently held down);
    /// always Success(0) on valid input.
    pub fn setModifierMapping(self: *Display, keycodes_per_modifier: u8, keycodes: []align(1) const u8) error{BadValue}!u8 {
        if (keycodes_per_modifier > 8) return error.BadValue; // beyond our 64-byte buffer
        if (keycodes.len != 8 * @as(usize, keycodes_per_modifier)) return error.BadValue;
        for (keycodes) |k| {
            if (k != 0 and (k < min_keycode or k > max_keycode)) return error.BadValue;
        }
        @memset(&self.modmap, 0);
        @memcpy(self.modmap[0..keycodes.len], keycodes);
        self.modmap_per = keycodes_per_modifier;
        return 0; // Success
    }

    /// RAW key dispatch: current routing verbatim minus the passive-grab
    /// activation preamble (that stays in the public injectKey wrapper, so it
    /// only runs once per press, not on every replay of this raw path). A
    /// keyboard grab bypasses focus entirely (routes to the grab client on
    /// grab_window -- see recordKeyGrabbed). Otherwise the key EVENT routes by
    /// focus (None->discarded; PointerRoot->pointer window; focus F->pointer
    /// window if in F's subtree else F, propagating). Modifier state
    /// (input_state bits 0-7) is GLOBAL keyboard state: updated for a modifier
    /// keycode regardless of focus/grab, AFTER recording so an event carries
    /// the modifiers in effect BEFORE it (button semantics).
    fn dispatchKey(self: *Display, keycode: u8, pressed: bool, time: u32) std.mem.Allocator.Error!void {
        if (self.keyboard_grab) |grab| {
            try self.recordKeyGrabbed(grab, keycode, pressed, time);
        } else if (self.focus != 0) {
            const event_window: u32 = if (self.focus == 1)
                self.pointer_window
            else if (self.isInSubtree(self.focus, self.pointer_window))
                self.pointer_window
            else
                self.focus;
            // Skip a dangling target (revert should prevent this) rather than
            // route to a ghost window.
            if (event_window == self.root or self.windows.contains(event_window)) {
                var path: std.ArrayListUnmanaged(PathNode) = .empty;
                defer path.deinit(self.gpa);
                try self.pathToWindow(event_window, &path);
                if (path.items.len != 0) {
                    const bit: u32 = if (pressed) key_press else key_release;
                    const kind: EventKind = if (pressed) .key_press else .key_release;
                    try self.recordDevice(path.items, bit, kind, keycode, self.pointer_x, self.pointer_y, time);
                }
            }
        }
        // Global modifier state, tracked even when the event was discarded.
        if (self.modifierIndexOf(keycode)) |i| {
            const mask: u16 = @as(u16, 1) << i;
            if (pressed) self.input_state |= mask else self.input_state &= ~mask;
        }
        // Auto-release: a passively-activated key grab drops when the SAME
        // key that activated it is released (X's single-key passive-grab
        // semantics -- a different key going up leaves the grab held).
        // Routed through clearKeyboardGrab so a Sync freeze it carried is
        // cleared too.
        if (!pressed) {
            if (self.keyboard_grab) |g| {
                if (g.auto_key) |ak| {
                    if (ak == keycode) self.clearKeyboardGrab();
                }
            }
        }
        // AllowEvents(SyncKeyboard) resync hook (Task 2): re-freeze right
        // after this key dispatches. keyboard_resync is always false until
        // Task 2 wires allowEvents, so this is inert in Task 1.
        if (self.keyboard_resync) {
            self.keyboard_frozen = true;
            self.keyboard_resync = false;
        }
    }

    /// Inject a key press/release. While the keyboard is frozen (a Sync
    /// grab), the event QUEUES instead of dispatching -- no modifier-state
    /// update. Otherwise: a matching passive grab (GrabKey) AUTO-ACTIVATES a
    /// keyboard grab before dispatch, so the very press that triggered it is
    /// delivered through the newly-active grab (bypasses the focus/pointer-
    /// window routing, same as an explicit GrabKeyboard would); if that
    /// activation is Sync-mode, the device freezes AFTER the trigger is
    /// delivered, and the trigger is remembered (keyboard_trigger) for
    /// AllowEvents ReplayKeyboard (Task 2).
    pub fn injectKey(self: *Display, keycode: u8, pressed: bool, time: u32) std.mem.Allocator.Error!void {
        if (self.keyboard_frozen) {
            try self.appendFrozenKeyboard(.{ .kind = if (pressed) .key_press else .key_release, .detail = keycode, .px = self.pointer_x, .py = self.pointer_y, .time = time });
            return;
        }
        var activated = false;
        if (self.keyboard_grab == null and pressed) {
            if (self.matchKeyGrab(keycode)) |g| {
                self.keyboard_grab = .{ .client = g.client, .grab_window = g.grab_window, .owner_events = g.owner_events, .pointer_mode = g.pointer_mode, .keyboard_mode = g.keyboard_mode, .auto_key = keycode };
                activated = true;
            }
        }
        try self.dispatchKey(keycode, pressed, time);
        if (activated) {
            if (self.keyboard_grab) |gr| {
                if (gr.keyboard_mode == mode_sync) {
                    self.keyboard_frozen = true;
                    self.keyboard_freeze_owner = .keyboard_grab;
                    self.keyboard_trigger = .{ .kind = if (pressed) .key_press else .key_release, .detail = keycode, .px = self.pointer_x, .py = self.pointer_y, .time = time };
                }
                // A cross-mode freeze: this passive KEY grab's
                // pointer_mode==Sync freezes the POINTER, owned by THIS
                // (.keyboard_grab) grab even though pointer_grab stays null.
                if (gr.pointer_mode == mode_sync) {
                    self.pointer_frozen = true;
                    self.pointer_freeze_owner = .keyboard_grab;
                }
            }
        }
    }

    /// Re-dispatch a queued/trigger FrozenEvent through CURRENT routing --
    /// through the grab if one is still active, else spatial/focus routing
    /// (dispatchMotion/dispatchButton/dispatchKey each re-check that on their
    /// own, since a Replay may run after the grab was just released). Used by
    /// AllowEvents to flush a device's frozen queue and to replay a
    /// passive-grab trigger.
    fn dispatchFrozen(self: *Display, ev: FrozenEvent) std.mem.Allocator.Error!void {
        switch (ev.kind) {
            .motion => try self.dispatchMotion(ev.px, ev.py, ev.time),
            .button_press => try self.dispatchButton(ev.detail, true, ev.time),
            .button_release => try self.dispatchButton(ev.detail, false, ev.time),
            .key_press => try self.dispatchKey(ev.detail, true, ev.time),
            .key_release => try self.dispatchKey(ev.detail, false, ev.time),
            else => {}, // FrozenEvent only ever carries the 5 kinds above
        }
    }

    /// Drain frozen_pointer_events in FIFO order via dispatchFrozen. A
    /// flushed button can re-freeze the pointer (AllowEvents(SyncPointer) set
    /// pointer_resync, and dispatchButton's resync hook tripped at the end of
    /// that dispatch) -- if so, stop, requeue the still-untouched tail (the
    /// already-flushed prefix is dropped), and return; otherwise the whole
    /// queue drained, so clear it.
    fn flushPointerQueue(self: *Display) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < self.frozen_pointer_events.items.len) : (i += 1) {
            try self.dispatchFrozen(self.frozen_pointer_events.items[i]);
            if (self.pointer_frozen) {
                const rest = self.frozen_pointer_events.items[i + 1 ..];
                std.mem.copyForwards(FrozenEvent, self.frozen_pointer_events.items[0..rest.len], rest);
                self.frozen_pointer_events.shrinkRetainingCapacity(rest.len);
                return;
            }
        }
        self.frozen_pointer_events.clearRetainingCapacity();
    }

    /// Keyboard-side equivalent of flushPointerQueue.
    fn flushKeyboardQueue(self: *Display) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < self.frozen_keyboard_events.items.len) : (i += 1) {
            try self.dispatchFrozen(self.frozen_keyboard_events.items[i]);
            if (self.keyboard_frozen) {
                const rest = self.frozen_keyboard_events.items[i + 1 ..];
                std.mem.copyForwards(FrozenEvent, self.frozen_keyboard_events.items[0..rest.len], rest);
                self.frozen_keyboard_events.shrinkRetainingCapacity(rest.len);
                return;
            }
        }
        self.frozen_keyboard_events.clearRetainingCapacity();
    }

    /// The pointer-side of AllowEvents. `sub`: 0=Async 1=Sync 2=Replay (the
    /// AllowEvents mode numbering maps directly for modes 0/1/2; AsyncBoth(6)/
    /// SyncBoth(7) call this with 0/1). A silent no-op unless `client` is the
    /// OWNER of the grab that froze the pointer (pointer_freeze_owner --
    /// which may be a keyboard_grab's cross-mode, not necessarily a held
    /// pointer_grab; see the module's Sync-freeze doc). `.none` means the
    /// pointer isn't frozen at all -- nothing to thaw either way.
    fn allowPointer(self: *Display, sub: u8, client: u32) std.mem.Allocator.Error!void {
        const owner_client: ?u32 = switch (self.pointer_freeze_owner) {
            .none => null,
            .pointer_grab => if (self.pointer_grab) |g| g.client else null,
            .keyboard_grab => if (self.keyboard_grab) |g| g.client else null,
        };
        if (owner_client != client) return;
        switch (sub) {
            0 => { // AsyncPointer: thaw, flow through the still-active grab (if any).
                if (self.pointer_frozen) {
                    self.pointer_frozen = false;
                    self.pointer_trigger = null;
                    self.pointer_freeze_owner = .none;
                    try self.flushPointerQueue();
                }
            },
            1 => { // SyncPointer: thaw for one button, then re-freeze.
                if (self.pointer_frozen) {
                    self.pointer_frozen = false;
                    self.pointer_trigger = null;
                    self.pointer_resync = true;
                    // pointer_freeze_owner is left as-is: dispatchButton's
                    // resync hook may re-freeze before this call returns, and
                    // it must still be attributed to the grab that governs it.
                    try self.flushPointerQueue();
                }
            },
            2 => { // ReplayPointer: release the grab, replay the trigger + queue spatially.
                // Only a PASSIVELY-activated Sync GrabButton owns a trigger to
                // replay; an explicit GrabPointer(Sync) froze with no
                // activating event, and a cross-mode freeze owned by a
                // keyboard_grab has no pointer_grab trigger either -- both
                // are a no-op for Replay (X: Replay only makes sense for the
                // matching device's own passive grab).
                if (self.pointer_frozen and self.pointer_freeze_owner == .pointer_grab and self.pointer_grab.?.auto and self.pointer_trigger != null) {
                    const trig = self.pointer_trigger.?;
                    // clearPointerGrab (below) discards frozen_pointer_events
                    // as part of normal grab release -- move the queue aside
                    // first so we can still replay it after releasing.
                    var queued = self.frozen_pointer_events;
                    self.frozen_pointer_events = .empty;
                    self.clearPointerGrab();
                    defer queued.deinit(self.gpa);
                    try self.dispatchFrozen(trig); // grab is gone now -> spatial routing = the replay
                    for (queued.items) |ev| try self.dispatchFrozen(ev);
                }
            },
            else => unreachable, // callers only ever pass 0/1/2
        }
    }

    /// Keyboard-side equivalent of allowPointer.
    fn allowKeyboard(self: *Display, sub: u8, client: u32) std.mem.Allocator.Error!void {
        const owner_client: ?u32 = switch (self.keyboard_freeze_owner) {
            .none => null,
            .keyboard_grab => if (self.keyboard_grab) |g| g.client else null,
            .pointer_grab => if (self.pointer_grab) |g| g.client else null,
        };
        if (owner_client != client) return;
        switch (sub) {
            0 => { // AsyncKeyboard
                if (self.keyboard_frozen) {
                    self.keyboard_frozen = false;
                    self.keyboard_trigger = null;
                    self.keyboard_freeze_owner = .none;
                    try self.flushKeyboardQueue();
                }
            },
            1 => { // SyncKeyboard
                if (self.keyboard_frozen) {
                    self.keyboard_frozen = false;
                    self.keyboard_trigger = null;
                    self.keyboard_resync = true;
                    // keyboard_freeze_owner left as-is -- see allowPointer's
                    // SyncPointer comment.
                    try self.flushKeyboardQueue();
                }
            },
            2 => { // ReplayKeyboard: only a matching passive GrabKey trigger replays.
                if (self.keyboard_frozen and self.keyboard_freeze_owner == .keyboard_grab and self.keyboard_grab.?.auto_key != null and self.keyboard_trigger != null) {
                    const trig = self.keyboard_trigger.?;
                    var queued = self.frozen_keyboard_events;
                    self.frozen_keyboard_events = .empty;
                    self.clearKeyboardGrab();
                    defer queued.deinit(self.gpa);
                    try self.dispatchFrozen(trig);
                    for (queued.items) |ev| try self.dispatchFrozen(ev);
                }
            },
            else => unreachable, // callers only ever pass 0/1/2
        }
    }

    /// AllowEvents (op 35). mode: 0=AsyncPointer 1=SyncPointer 2=ReplayPointer
    /// 3=AsyncKeyboard 4=SyncKeyboard 5=ReplayKeyboard 6=AsyncBoth 7=SyncBoth;
    /// anything else -> BadValue. Both(6/7) run the pointer mode then the
    /// keyboard mode. Each mode is a silent no-op unless `client` holds the
    /// relevant active grab (see allowPointer/allowKeyboard).
    pub fn allowEvents(self: *Display, mode: u8, client: u32) (error{BadValue} || std.mem.Allocator.Error)!void {
        switch (mode) {
            0, 1, 2 => try self.allowPointer(mode, client),
            3, 4, 5 => try self.allowKeyboard(mode - 3, client),
            6 => {
                try self.allowPointer(0, client);
                try self.allowKeyboard(0, client);
            },
            7 => {
                try self.allowPointer(1, client);
                try self.allowKeyboard(1, client);
            },
            else => return error.BadValue,
        }
    }

    /// ChangeActivePointerGrab (op 30): update the ACTIVE pointer grab's
    /// event_mask if `client` holds it; a no-op otherwise. `cursor`/`time`
    /// are accepted on the wire but ignored -- we don't render cursors (so no
    /// BadCursor) and don't model timestamp-ordering here.
    pub fn changeActivePointerGrab(self: *Display, event_mask: u16, client: u32) void {
        if (self.pointer_grab) |*g| {
            if (g.client == client) g.event_mask = event_mask;
        }
    }

    /// Append every client that selected any bit of `event_mask` on `w`.
    fn collectSelectors(self: *Display, w: *const Window, event_mask: u32, out: *std.ArrayListUnmanaged(u32)) std.mem.Allocator.Error!void {
        for (w.masks.items) |cm| {
            if (cm.mask & event_mask != 0) try out.append(self.gpa, cm.client);
        }
    }

    /// The client_ids a SendEvent to `destination` should be delivered to.
    /// event_mask != 0: clients selecting any of it on destination; if none and
    /// `propagate`, the first ancestor level with such a selector. event_mask
    /// == 0: the destination window's owner only (X's empty-mask rule). The
    /// caller (server_main) relays the opaque event bytes; this is xproto-free
    /// routing only. Returns an owned slice (free with display.gpa).
    pub fn sendEventTargets(self: *Display, destination: u32, propagate: bool, event_mask: u32) SendError![]u32 {
        const w = self.windows.getPtr(destination) orelse return error.NoWindow;
        var out: std.ArrayListUnmanaged(u32) = .empty;
        errdefer out.deinit(self.gpa);
        if (event_mask == 0) {
            try out.append(self.gpa, w.owner);
            return out.toOwnedSlice(self.gpa);
        }
        try self.collectSelectors(w, event_mask, &out);
        if (out.items.len == 0 and propagate) {
            var cur = w.parent;
            while (cur != 0) {
                const anc = self.windows.getPtr(cur) orelse break;
                try self.collectSelectors(anc, event_mask, &out);
                if (out.items.len > 0) break; // first ancestor level with a selector
                cur = anc.parent;
            }
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Is `id` already a live resource (window, pixmap, or GC)? The X id space
    /// is one namespace per client, so every create op rejects a collision.
    pub fn idInUse(self: *Display, id: u32) bool {
        return self.windows.contains(id) or self.pixmaps.contains(id) or self.gcs.contains(id) or self.fonts.contains(id) or self.colormaps.contains(id);
    }

    /// XC-MISC GetXIDRange/GetXIDList: hand out `count` consecutive fresh ids
    /// starting at the dispenser's current position, then advance past them.
    /// See `next_xid`'s doc comment for why no idInUse check is needed.
    pub fn allocXidRange(self: *Display, count: u32) struct { start: u32, count: u32 } {
        const s = self.next_xid;
        self.next_xid +%= count;
        return .{ .start = s, .count = count };
    }

    /// RANDR's screen size: the root window's own geom, so RANDR can never
    /// desync from what GetGeometry/ConfigureNotify already report (single
    /// source of truth -- see RandrConfig's doc comment). The root always has
    /// a Window entry (created in initCommon), so this never returns null in
    /// practice; a missing root is treated as 0x0 rather than panicking.
    pub fn randrScreenSize(self: *Display) struct { w: u16, h: u16 } {
        const root_w = self.windows.get(self.root) orelse return .{ .w = 0, .h = 0 };
        return .{ .w = root_w.geom.width, .h = root_w.geom.height };
    }

    /// Convert a pixel length to millimeters at a fixed 96 DPI (the value
    /// every RANDR/Xinerama-aware toolkit assumes when a real EDID-reported
    /// physical size is unavailable, which this synthetic single-monitor
    /// config never has).
    pub fn randrMm(px: u16) u32 {
        return @intFromFloat(@round(@as(f64, @floatFromInt(px)) * 25.4 / 96.0));
    }

    /// Resolve a RANDR mode id to its dims: the current mode (`randr.mode`)
    /// always reports the LIVE root size (see `randrScreenSize`'s doc
    /// comment), any id in `randr_alt_modes` reports its fixed dims, any id
    /// in `randr_created_modes` (CreateMode) reports its stored dims,
    /// anything else is unknown (BadMode/BadValue at the caller).
    pub fn randrModeById(self: *Display, id: u32) ?RandrMode {
        if (id == self.randr.mode) {
            const size = self.randrScreenSize();
            return .{ .id = id, .width = size.w, .height = size.h };
        }
        for (randr_alt_modes) |m| {
            if (m.id == id) return m;
        }
        for (self.randr_created_modes.items) |m| {
            if (m.id == id) return m;
        }
        return null;
    }

    /// The full mode list this server ever reports (GetScreenResources/
    /// GetOutputInfo/GetScreenInfo): index 0 is the current mode (live dims),
    /// then the fixed `randr_alt_modes`, then every client-created mode
    /// (`randr_created_modes`, creation order), same order every caller.
    /// Written into `buf` (caller-owned) rather than returned by value --
    /// unlike the built-in-only list this replaces, the created-modes tail is
    /// runtime-sized, so this can't be a comptime-sized array anymore. `buf`
    /// must be at least `randrModeCount()` long; `max_mode_count` is always
    /// enough (`randr_created_modes` is capped there -- see `createMode`).
    /// Returns the filled prefix of `buf`.
    pub fn randrModeList(self: *Display, buf: []RandrMode) []RandrMode {
        const count = self.randrModeCount();
        std.debug.assert(buf.len >= count);
        const size = self.randrScreenSize();
        buf[0] = .{ .id = self.randr.mode, .width = size.w, .height = size.h };
        for (randr_alt_modes, 0..) |m, i| buf[i + 1] = m;
        for (self.randr_created_modes.items, 0..) |m, i| buf[randr_mode_count + i] = m;
        return buf[0..count];
    }

    /// How many entries `randrModeList` fills: the fixed built-in count plus
    /// however many client-created modes currently exist. Callers size their
    /// `randrModeList` buffer off `server_state.max_mode_count` (a fixed
    /// upper bound) rather than this (a runtime value), but this is the exact
    /// count they'll get back.
    pub fn randrModeCount(self: *Display) usize {
        return randr_mode_count + self.randr_created_modes.items.len;
    }

    /// CreateMode (RANDR minor 16): mint a fresh id (from `randr_next_mode_id`)
    /// for a {width,height} mode and append it to `randr_created_modes`,
    /// folded into every mode list this server reports from then on. Bounded
    /// to `max_created_modes`: at the cap, evicts the OLDEST created mode
    /// (index 0) rather than growing without bound or refusing outright --
    /// this keeps the error set to plain OutOfMemory (no separate "table
    /// full" error) while still bounding memory against a client that spams
    /// CreateMode without ever DestroyMode-ing. The evicted mode simply stops
    /// being reported/resolvable (`randrModeList`/`randrModeById`); nothing
    /// else in this server references a mode id after this call returns.
    pub fn createMode(self: *Display, width: u16, height: u16) std.mem.Allocator.Error!u32 {
        if (self.randr_created_modes.items.len >= max_created_modes) {
            _ = self.randr_created_modes.orderedRemove(0);
        }
        const id = self.randr_next_mode_id;
        self.randr_next_mode_id +%= 1;
        try self.randr_created_modes.append(self.gpa, .{ .id = id, .width = width, .height = height });
        return id;
    }

    pub const DestroyModeError = error{BadMode};

    /// DestroyMode (RANDR minor 17): remove `id` from `randr_created_modes`.
    /// `id` must name a CLIENT-CREATED mode -- the current mode / a fixed
    /// `randr_alt_modes` entry / an unknown id are all BadMode here (only
    /// `createMode` ever adds to this list, so only its ids can be removed
    /// from it).
    pub fn destroyMode(self: *Display, id: u32) DestroyModeError!void {
        for (self.randr_created_modes.items, 0..) |m, i| {
            if (m.id == id) {
                _ = self.randr_created_modes.orderedRemove(i);
                return;
            }
        }
        return error.BadMode;
    }

    /// SetCrtcTransform (RANDR minor 26): store the 9-FIXED matrix against
    /// this single crtc, then push it across the renderer seam
    /// (`Renderer.setCrtcTransform`, SP-Server-5a) so an injected backend
    /// (Prism, for Lattice) actually receives the RANDR-configured output
    /// transform rather than it staying server-side-only. Unconditional (the
    /// caller has already validated the crtc id), so this can't fail.
    pub fn setCrtcTransform(self: *Display, matrix: [9]u32) void {
        self.randr_transform = matrix;
        // FIXED (RANDR's 16.16 fixed-point) is SIGNED; the wire/storage type
        // is u32 but the renderer seam takes i32, so re-interpret each
        // element's bits rather than numerically truncating/converting.
        var signed: [9]i32 = undefined;
        for (&signed, matrix) |*s, u| s.* = @bitCast(u);
        self.renderer.setCrtcTransform(signed);
    }

    /// SetMonitor (RANDR minor 43): add `mon` to `randr_monitors`, or REPLACE
    /// the existing entry with the same `.name` in place (preserving its
    /// position -- a WM re-issuing SetMonitor for a monitor it already
    /// defined, e.g. after a resolution change, shouldn't reorder
    /// GetMonitors's list). A genuinely new name past `max_monitors` is
    /// refused rather than evicting an existing monitor a WM may still be
    /// relying on (see `max_monitors`'s doc comment).
    pub fn setMonitor(self: *Display, mon: RandrMonitor) error{OutOfMemory}!void {
        for (self.randr_monitors.items) |*existing| {
            if (existing.name == mon.name) {
                existing.* = mon;
                return;
            }
        }
        if (self.randr_monitors.items.len >= max_monitors) return error.OutOfMemory;
        try self.randr_monitors.append(self.gpa, mon);
    }

    pub const DeleteMonitorError = error{BadValue};

    /// DeleteMonitor (RANDR minor 44): remove the monitor named `name` from
    /// `randr_monitors`. `name` must match a monitor `setMonitor` actually
    /// added -- BadValue if not (mirrors `destroyMode`'s BadMode-on-unknown-id
    /// shape, just with RANDR's generic BadValue since RANDR defines no
    /// "unknown monitor" error code of its own).
    pub fn deleteMonitor(self: *Display, name: u32) DeleteMonitorError!void {
        for (self.randr_monitors.items, 0..) |m, i| {
            if (m.name == name) {
                _ = self.randr_monitors.orderedRemove(i);
                return;
            }
        }
        return error.BadValue;
    }

    pub const GammaError = error{BadValue};

    /// SetCrtcGamma (RANDR minor 24): install a new ramp triple. `size` must
    /// equal `gamma_size` exactly (BadValue otherwise) -- the gamma ramp
    /// length is a fixed hardware property of the crtc, so a real X server
    /// rejects any SetCrtcGamma whose size disagrees with GetCrtcGammaSize
    /// rather than silently resizing to match (a smaller `size` here must
    /// NOT shrink `gamma_size`, or a later GetCrtcGammaSize would lie about
    /// the ramp length). `red`/`green`/`blue` must each be at least `size`
    /// long (the caller, server_main's handleRandr, already bounds its own
    /// read against the request's real byte length before calling this).
    pub fn setCrtcGamma(self: *Display, size: u16, red: []const u16, green: []const u16, blue: []const u16) GammaError!void {
        if (size != self.gamma_size) return error.BadValue;
        @memcpy(self.gamma_red[0..size], red[0..size]);
        @memcpy(self.gamma_green[0..size], green[0..size]);
        @memcpy(self.gamma_blue[0..size], blue[0..size]);
        // Push the new ramps across the renderer seam (SP-Server-5a) so an
        // injected backend (Prism, for Lattice) applies the RANDR-configured
        // gamma at present time instead of it staying stored-but-unused here.
        self.renderer.setCrtcGamma(&self.gamma_red, &self.gamma_green, &self.gamma_blue);
    }

    /// GetCrtcGamma's read side: the current size + a read-only view of the
    /// first `gamma_size` entries of each ramp. A plain getter (the arrays
    /// themselves are the state; nothing to compute) -- kept as a method
    /// rather than public-field reads so server_main has one call site to
    /// update if gamma ever grows a real per-crtc map.
    pub fn gammaRamps(self: *Display) struct { size: u16, red: []const u16, green: []const u16, blue: []const u16 } {
        return .{
            .size = self.gamma_size,
            .red = self.gamma_red[0..self.gamma_size],
            .green = self.gamma_green[0..self.gamma_size],
            .blue = self.gamma_blue[0..self.gamma_size],
        };
    }

    /// RANDR SelectInput (minor 4): record `client`'s event mask for `window`,
    /// replacing any prior registration for the same pair. Read by
    /// `recordRandrEvent` (see `RandrEventMask`'s doc comment) to fan out
    /// ScreenChangeNotify/RRNotify-CrtcChange whenever the screen actually
    /// resizes.
    pub fn randrSelectInput(self: *Display, client: u32, window: u32, mask: u16) std.mem.Allocator.Error!void {
        for (self.randr_event_masks.items) |*e| {
            if (e.client == client and e.window == window) {
                e.mask = mask;
                return;
            }
        }
        try self.randr_event_masks.append(self.gpa, .{ .client = client, .window = window, .mask = mask });
    }

    /// Fan out one RANDR event (ScreenChangeNotify/RRNotify-CrtcChange) to
    /// every client whose `randr_event_masks` registration includes
    /// `event_bit` (ScreenChange=0x1, CrtcChange=0x2) -- the RANDR SelectInput
    /// store, NOT core window masks (see `RandrEventMask`'s doc comment; this
    /// is the follow-up that finally reads it). `entry.window` doubles as
    /// both the event's routing target (`event_window`) and its `window` wire
    /// field (RRNotify's `window`), since a RANDR client always SelectInputs
    /// on the window it wants to hear RANDR changes about (the root, in this
    /// synthetic single-CRTC config) -- there is no separate "event" vs
    /// "window" distinction the way core StructureNotify has one.
    pub fn recordRandrEvent(self: *Display, event_bit: u16, kind: EventKind, data: RandrEventData, width: u16, height: u16, x: i16, y: i16, root: u32, time: u32) EventError!void {
        for (self.randr_event_masks.items) |entry| {
            if (entry.mask & event_bit != 0) {
                try self.recordEvent(.{
                    .kind = kind,
                    .event_window = entry.window,
                    .window = entry.window,
                    .target_client = entry.client,
                    .width = width,
                    .height = height,
                    .x = x,
                    .y = y,
                    .root = root,
                    .time = time,
                    .randr = data,
                });
            }
        }
    }

    /// Resize the ROOT window (RANDR's mutation surface -- SetScreenSize
    /// directly, SetCrtcConfig/SetScreenConfig via `setCrtcMode`/
    /// `setScreenConfigSize` below): clamp the untrusted client-named w/h to
    /// RANDR's own advertised range (`randr.min_screen_dim`/`max_screen_dim`,
    /// GetScreenSizeRange's bounds) so a hostile/out-of-range request degrades
    /// to the nearest valid size instead of erroring or desyncing the root
    /// from what it advertises. A same-size resize is a genuine no-op --
    /// nothing changed, so nothing is recorded (no ConfigureNotify/RANDR
    /// events for a request that had no effect). Otherwise: reallocate the
    /// root's backing surface (contents are lost, like any resize -- see
    /// configureWindow), repaint it to the background pixel (there is no
    /// backing store), update geom, bump the RANDR config timestamp (skipping
    /// 0, X's CurrentTime sentinel), then record -- IN ORDER -- the core
    /// ConfigureNotify(root) a StructureNotify-selecting client expects,
    /// followed by the two RANDR events (ScreenChangeNotify then
    /// RRNotify/CrtcChange) per sp-server-randr-dynamic-spec.md's TASK 3.
    ///
    /// RANDR's own [1, 16384] clamp bounds the *dimensions* but not the
    /// resulting *allocation* -- 16384x16384x4 is ~1 GiB, so a hostile
    /// SetScreenSize/SetCrtcConfig/SetScreenConfig could otherwise force an
    /// unbounded root-surface allocation. Cap the byte size against
    /// `max_pixmap_bytes`, same bound + same rationale as configureWindow's
    /// resize path, and do it BEFORE any mutation so a rejected resize leaves
    /// the root geom/surface untouched.
    pub fn resizeRoot(self: *Display, w: u16, h: u16, mm_w: u16, mm_h: u16, request_window: u32) (EventError || error{TooLarge})!void {
        const cw = std.math.clamp(w, randr.min_screen_dim, randr.max_screen_dim);
        const ch = std.math.clamp(h, randr.min_screen_dim, randr.max_screen_dim);
        // The root always has a Window entry (initCommon creates it); treated
        // as NoWindow rather than unreachable so a corrupted Display can't panic.
        const root = self.windows.getPtr(self.root) orelse return error.NoWindow;
        if (cw == root.geom.width and ch == root.geom.height) return;
        const size = @as(usize, cw) * @as(usize, ch) * render.bytesPerPixel(root.geom.depth);
        if (size > self.max_pixmap_bytes) return error.TooLarge;
        try self.renderer.resizeSurface(&root.surface, cw, ch);
        self.renderer.fillRect(root.surface, 0, 0, cw, ch, root.attrs.background_pixel);
        root.geom.width = cw;
        root.geom.height = ch;
        self.randr.timestamp +%= 1;
        if (self.randr.timestamp == 0) self.randr.timestamp +%= 1; // 0 is CurrentTime's sentinel, never a real timestamp
        try self.recordSelected(root, structure_notify, .{
            .kind = .configure,
            .event_window = self.root,
            .window = self.root,
            .above_sibling = 0, // the root has no parent/siblings
            .x = root.geom.x,
            .y = root.geom.y,
            .width = cw,
            .height = ch,
            .border_width = root.geom.border_width,
            .override_redirect = root.attrs.override_redirect,
        });
        try self.recordRandrEvent(0x1, .randr_screen_change, .{
            .rotation = 1,
            .config_timestamp = self.randr.timestamp,
            .request_window = request_window,
            .size_id = 0,
            .subpixel = 0,
            .mwidth = mm_w,
            .mheight = mm_h,
        }, cw, ch, 0, 0, self.root, self.randr.timestamp);
        try self.recordRandrEvent(0x2, .randr_crtc_change, .{
            .crtc = self.randr.crtc,
            .mode = self.randr.mode,
            .rotation = 1,
        }, cw, ch, 0, 0, self.root, self.randr.timestamp);
    }

    /// SetCrtcConfig (RANDR minor 21) resolved to a mode: mode id 0 means
    /// "keep the current mode" (a real RANDR client uses this to just change
    /// rotation/outputs, neither of which this synthetic single-CRTC config
    /// supports) -- a pure no-op, the caller replies Success without
    /// resizing. Any other id must resolve via `randrModeById` (the current
    /// mode or a fixed `randr_alt_modes` entry) or it's BadMode. No
    /// `request_window` -- SetCrtcConfig's wire request has no window field
    /// (only SetScreenSize/SetScreenConfig do), so the emitted
    /// ScreenChangeNotify carries request_window 0. `TooLarge` is threaded
    /// through from `resizeRoot` for type honesty -- the current mode and
    /// every `randr_alt_modes` entry top out at 1920x1080 (well under
    /// `max_pixmap_bytes`), so it can never actually fire here, but the modes
    /// table is fixed data, not a guarantee resizeRoot's cap doesn't apply.
    pub fn setCrtcMode(self: *Display, mode_id: u32) (EventError || error{ BadMode, TooLarge })!void {
        if (mode_id == 0) return;
        const m = self.randrModeById(mode_id) orelse return error.BadMode;
        try self.resizeRoot(m.width, m.height, @intCast(randrMm(m.width)), @intCast(randrMm(m.height)), 0);
    }

    /// SetScreenConfig (RANDR minor 2) resolved to a size index: `size_id`
    /// indexes the same list `randrModeList` reports (0 = the live current
    /// size, 1.. the fixed `randr_alt_modes`, then any client-created modes,
    /// same order) -- out of range is BadValue. Like `setCrtcMode`, no request_window carried
    /// (SetScreenConfig's own `window` field addresses the config, but this
    /// helper resizes unconditionally off the index; a future caller wanting
    /// that window echoed in the event would thread it through separately).
    /// `TooLarge` propagates from `resizeRoot` for the same reason as
    /// `setCrtcMode`'s -- inert against the fixed mode table, kept for type
    /// honesty.
    pub fn setScreenConfigSize(self: *Display, size_id: u16) (EventError || error{ BadValue, TooLarge })!void {
        var buf: [max_mode_count]RandrMode = undefined;
        const list = self.randrModeList(&buf);
        if (size_id >= list.len) return error.BadValue;
        const m = list[size_id];
        try self.resizeRoot(m.width, m.height, @intCast(randrMm(m.width)), @intCast(randrMm(m.height)), 0);
    }

    /// Geometry for a drawable id (window or pixmap), else null (-> BadDrawable).
    pub fn drawable(self: *Display, id: u32) ?DrawableInfo {
        if (self.windows.getPtr(id)) |w| return .{
            .depth = w.geom.depth,
            .root = self.root,
            .x = w.geom.x,
            .y = w.geom.y,
            .width = w.geom.width,
            .height = w.geom.height,
            .border_width = w.geom.border_width,
        };
        if (self.pixmaps.get(id)) |p| return .{
            .depth = p.depth,
            .root = self.root,
            .x = 0,
            .y = 0,
            .width = p.width,
            .height = p.height,
            .border_width = 0,
        };
        return null;
    }

    /// The rendering surface for a drawable id (window or pixmap), else null
    /// (-> BadDrawable). Display reads only the surface's public dims/format; the
    /// renderer owns the pixels. Public so tests can assert BadDrawable ids.
    pub fn surfaceOf(self: *Display, id: u32) ?render.Surface {
        if (self.windows.getPtr(id)) |w| return w.surface;
        if (self.pixmaps.getPtr(id)) |p| return p.surface;
        return null;
    }

    /// Fill a rectangle in a drawable with the GC's foreground (GXcopy). The
    /// renderer clips to the drawable bounds (i16 coords, so negative/off-screen
    /// handled). Other raster functions + the GC clip region are ignored for now.
    pub fn fillRect(self: *Display, drawable_id: u32, gc_id: u32, x: i16, y: i16, width: u16, height: u16) error{ NoDrawable, NotGC }!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        self.renderer.fillRect(surf, x, y, width, height, gc.values.foreground);
    }

    /// Copy client pixel data (ZPixmap) into a drawable at (dst_x,dst_y), clipped
    /// to bounds. Only ZPixmap(2), matching depth, and left_pad 0 are supported.
    pub fn putImage(self: *Display, drawable_id: u32, gc_id: u32, format: u8, depth: u8, width: u16, height: u16, dst_x: i16, dst_y: i16, left_pad: u8, data: []const u8) error{ NoDrawable, NotGC, BadMatch }!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        if (!self.gcs.contains(gc_id)) return error.NotGC;
        if (format != 2) return error.BadMatch; // ZPixmap only
        if (depth != surf.depth) return error.BadMatch;
        if (left_pad != 0) return error.BadMatch;
        const expected = @as(usize, width) * @as(usize, height) * @as(usize, surf.bpp);
        if (data.len != expected) return error.BadMatch;
        self.renderer.putImage(surf, dst_x, dst_y, width, height, data);
    }

    pub const GetImageResult = struct { depth: u8, visual: u32, data: []u8 };

    /// Read a rectangle of a drawable as ZPixmap, ANDing each pixel with
    /// plane_mask. The rect must be fully contained in the drawable (else
    /// BadMatch). The returned `data` is caller-owned (free with display.gpa).
    /// Display validates containment + applies plane_mask; the renderer only
    /// does the raw readback.
    pub fn getImage(self: *Display, drawable_id: u32, format: u8, x: i16, y: i16, width: u16, height: u16, plane_mask: u32) (error{ NoDrawable, BadMatch } || std.mem.Allocator.Error)!GetImageResult {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        if (format != 2) return error.BadMatch; // ZPixmap only
        if (x < 0 or y < 0) return error.BadMatch;
        if (@as(i32, x) + @as(i32, width) > @as(i32, surf.width)) return error.BadMatch;
        if (@as(i32, y) + @as(i32, height) > @as(i32, surf.height)) return error.BadMatch;
        // Windows carry their visual; a pixmap reports visual 0 (looked up before
        // the readback so the result carries the right value).
        const vis: u32 = if (self.windows.getPtr(drawable_id)) |w| w.visual else 0;
        const out = try self.gpa.alloc(u8, @as(usize, width) * @as(usize, height) * @as(usize, surf.bpp));
        errdefer self.gpa.free(out);
        self.renderer.getImage(surf, @intCast(x), @intCast(y), width, height, out);
        // Apply plane_mask to each returned pixel (skip the identity mask).
        if (plane_mask != 0xffffffff) {
            const bpp: usize = surf.bpp;
            var p: usize = 0;
            while (p + bpp <= out.len) : (p += bpp) {
                var v: u32 = 0;
                var i: usize = 0;
                while (i < bpp and i < 4) : (i += 1) v |= @as(u32, out[p + i]) << @intCast(i * 8);
                v &= plane_mask;
                i = 0;
                while (i < bpp and i < 4) : (i += 1) out[p + i] = @truncate(v >> @intCast(i * 8));
            }
        }
        return .{ .depth = surf.depth, .visual = vis, .data = out };
    }

    /// Clear a window rectangle to its background_pixel; width/height 0 extend to
    /// the window's right/bottom edge (per X). If `exposures`, record an Expose
    /// over the cleared region (mask-filtered to Exposure selectors, same path as
    /// map). InputOnly (class 2) has no pixels -> BadMatch; a non-window id is the
    /// caller's BadWindow (ClearArea is a Window-only request).
    pub fn clearArea(self: *Display, window_id: u32, x: i16, y: i16, width: u16, height: u16, exposures: bool) (error{ NoWindow, BadMatch } || std.mem.Allocator.Error)!void {
        const wp = self.windows.getPtr(window_id) orelse return error.NoWindow;
        if (wp.class == 2) return error.BadMatch; // InputOnly: no pixel buffer to clear
        // Compute the clipped clear rect from the surface dims; width/height 0
        // extend to the window edge (per X). The renderer re-clips (harmless,
        // already in-bounds).
        const surf = wp.surface;
        const x0 = @max(@as(i32, 0), @as(i32, x));
        const y0 = @max(@as(i32, 0), @as(i32, y));
        const x1 = if (width == 0) @as(i32, surf.width) else @min(@as(i32, surf.width), @as(i32, x) + @as(i32, width));
        const y1 = if (height == 0) @as(i32, surf.height) else @min(@as(i32, surf.height), @as(i32, y) + @as(i32, height));
        if (x1 <= x0 or y1 <= y0) return; // nothing lands inside the window
        self.renderer.fillRect(surf, @intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0), wp.attrs.background_pixel);
        if (exposures) {
            try self.recordSelected(wp, exposure, .{
                .kind = .expose,
                .event_window = window_id,
                .window = window_id,
                .x = @intCast(x0),
                .y = @intCast(y0),
                .width = @intCast(x1 - x0),
                .height = @intCast(y1 - y0),
                .count = 0,
            });
        }
    }

    pub const CopyExpose = struct { graphics_exposures: bool, fully_covered: bool, x: i16, y: i16, width: u16, height: u16 };

    /// Blit a rectangle from src to dst (equal depth; GXcopy assumed like fillRect).
    /// Display computes the destination-clipped rect + the sub-rect covered by an
    /// in-bounds source, then asks the renderer to blit that covered sub-rect once
    /// (the renderer snapshots the source first so a self-overlapping copy reads
    /// original pixels). Destination pixels whose source falls outside the source
    /// drawable are left untouched and reported as not-fully-covered so the caller
    /// can GraphicsExpose them. Returns the dst-clipped rect (over-reported, not the
    /// exact covered slice) + whether it was fully covered + the GC's
    /// graphics_exposures flag.
    pub fn copyArea(self: *Display, src_id: u32, dst_id: u32, gc_id: u32, src_x: i16, src_y: i16, dst_x: i16, dst_y: i16, width: u16, height: u16) (error{ NoDrawable, NotGC, BadMatch } || std.mem.Allocator.Error)!CopyExpose {
        const src = self.surfaceOf(src_id) orelse return error.NoDrawable;
        const dst = self.surfaceOf(dst_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        if (src.depth != dst.depth) return error.BadMatch; // CopyArea requires equal depth
        const gx = gc.values.graphics_exposures;
        // Destination-clipped rectangle: only pixels landing inside dst matter.
        const dx0 = @max(@as(i32, 0), @as(i32, dst_x));
        const dy0 = @max(@as(i32, 0), @as(i32, dst_y));
        const dx1 = @min(@as(i32, dst.width), @as(i32, dst_x) + @as(i32, width));
        const dy1 = @min(@as(i32, dst.height), @as(i32, dst_y) + @as(i32, height));
        if (dx1 <= dx0 or dy1 <= dy0) {
            return .{ .graphics_exposures = gx, .fully_covered = true, .x = 0, .y = 0, .width = 0, .height = 0 };
        }
        // Source origin for the dst-clipped rect's top-left pixel (dx0,dy0).
        const sox = @as(i32, src_x) + (dx0 - @as(i32, dst_x));
        const soy = @as(i32, src_y) + (dy0 - @as(i32, dst_y));
        // Covered sub-rect (dst space): clamp so the source stays in bounds.
        const cov_x0 = dx0 + @max(@as(i32, 0), -sox);
        const cov_y0 = dy0 + @max(@as(i32, 0), -soy);
        const cov_x1 = @min(dx1, dx0 + (@as(i32, src.width) - sox));
        const cov_y1 = @min(dy1, dy0 + (@as(i32, src.height) - soy));
        const covered = cov_x1 > cov_x0 and cov_y1 > cov_y0;
        // Fully covered only when the covered sub-rect equals the whole dst-clipped rect.
        const fully = covered and cov_x0 == dx0 and cov_y0 == dy0 and cov_x1 == dx1 and cov_y1 == dy1;
        if (covered) {
            const cw: u16 = @intCast(cov_x1 - cov_x0);
            const ch: u16 = @intCast(cov_y1 - cov_y0);
            const s_x: u16 = @intCast(@as(i32, src_x) + (cov_x0 - @as(i32, dst_x)));
            const s_y: u16 = @intCast(@as(i32, src_y) + (cov_y0 - @as(i32, dst_y)));
            try self.renderer.copyRect(dst, src, s_x, s_y, @intCast(cov_x0), @intCast(cov_y0), cw, ch);
        }
        // Exposed rect returned is the whole dst-clipped rect (over-report, safe).
        return .{ .graphics_exposures = gx, .fully_covered = fully, .x = @intCast(dx0), .y = @intCast(dy0), .width = @intCast(dx1 - dx0), .height = @intCast(dy1 - dy0) };
    }

    /// Resolve a raw point list under CoordMode (0=Origin absolute, 1=Previous
    /// relative to the running point; first point always absolute) into absolute
    /// points. Origin returns `raw` unchanged (no alloc); Previous accumulates into
    /// a freshly allocated slice the caller must free.
    fn resolveCoords(self: *Display, raw: []const render.Point, coord_mode: u8) std.mem.Allocator.Error!struct { pts: []render.Point, owned: bool } {
        if (coord_mode != 1 or raw.len == 0) {
            return .{ .pts = @constCast(raw), .owned = false };
        }
        const out = try self.gpa.alloc(render.Point, raw.len);
        // Accumulate in i64: a Previous-mode list can be up to ~65532 points of
        // extreme i16 deltas, whose running sum overflows i32. Widening removes
        // the overflow outright (matches render.fillPolygon's i64 discipline).
        var acc_x: i64 = raw[0].x;
        var acc_y: i64 = raw[0].y;
        out[0] = .{ .x = clamp16(acc_x), .y = clamp16(acc_y) };
        var i: usize = 1;
        while (i < raw.len) : (i += 1) {
            acc_x += raw[i].x;
            acc_y += raw[i].y;
            out[i] = .{ .x = clamp16(acc_x), .y = clamp16(acc_y) };
        }
        return .{ .pts = out, .owned = true };
    }
    fn clamp16(v: i64) i16 {
        return @intCast(std.math.clamp(v, -32768, 32767));
    }

    /// Draw a set of points with the GC foreground. `coord_mode` 1 (Previous)
    /// resolves each point relative to the last (first point absolute).
    pub fn polyPoint(self: *Display, drawable_id: u32, gc_id: u32, coord_mode: u8, raw: []const render.Point) (error{ NoDrawable, NotGC } || std.mem.Allocator.Error)!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const r = try self.resolveCoords(raw, coord_mode);
        defer if (r.owned) self.gpa.free(r.pts);
        self.renderer.drawPoints(surf, r.pts, gc.values.foreground);
    }

    /// Draw a connected polyline (thin, GXcopy) with the GC foreground.
    /// `coord_mode` 1 (Previous) resolves each point relative to the last.
    pub fn polyLine(self: *Display, drawable_id: u32, gc_id: u32, coord_mode: u8, raw: []const render.Point) (error{ NoDrawable, NotGC } || std.mem.Allocator.Error)!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const r = try self.resolveCoords(raw, coord_mode);
        defer if (r.owned) self.gpa.free(r.pts);
        self.renderer.drawLines(surf, r.pts, gc.values.foreground);
    }

    /// `flat` holds each segment's two endpoints back-to-back (2*N points). Absolute.
    pub fn polySegment(self: *Display, drawable_id: u32, gc_id: u32, flat: []const render.Point) (error{ NoDrawable, NotGC })!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const fg = gc.values.foreground;
        var i: usize = 0;
        while (i + 1 < flat.len) : (i += 2) self.renderer.drawLines(surf, flat[i .. i + 2], fg);
    }

    /// Draw closed rectangle outlines (border on the rectangle path; width/height
    /// are the outer extent) with the GC foreground. Absolute, no coord mode.
    pub fn polyRectangle(self: *Display, drawable_id: u32, gc_id: u32, rects: []const render.Rect) (error{ NoDrawable, NotGC })!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const fg = gc.values.foreground;
        for (rects) |rc| {
            const rx: i32 = rc.x;
            const ry: i32 = rc.y;
            const x2 = clamp16(rx + rc.width);
            const y2 = clamp16(ry + rc.height);
            // Closed outline: TL -> TR -> BR -> BL -> TL.
            const outline = [_]render.Point{
                .{ .x = rc.x, .y = rc.y },
                .{ .x = x2, .y = rc.y },
                .{ .x = x2, .y = y2 },
                .{ .x = rc.x, .y = y2 },
                .{ .x = rc.x, .y = rc.y },
            };
            self.renderer.drawLines(surf, &outline, fg);
        }
    }

    /// Fill a polygon (even-odd) with the GC foreground. `coord_mode` 1
    /// (Previous) resolves each point relative to the last.
    pub fn fillPoly(self: *Display, drawable_id: u32, gc_id: u32, coord_mode: u8, raw: []const render.Point) (error{ NoDrawable, NotGC } || std.mem.Allocator.Error)!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const r = try self.resolveCoords(raw, coord_mode);
        defer if (r.owned) self.gpa.free(r.pts);
        try self.renderer.fillPolygon(surf, r.pts, gc.values.foreground);
    }

    /// Draw arc outlines (ellipse boundary, thin, GXcopy) with the GC foreground.
    pub fn polyArc(self: *Display, drawable_id: u32, gc_id: u32, arcs: []const render.Arc) (error{ NoDrawable, NotGC } || std.mem.Allocator.Error)!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        try self.renderer.drawArcs(surf, arcs, gc.values.foreground);
    }

    /// Fill arcs (Chord or PieSlice per the GC's arc_mode) with the GC foreground.
    pub fn polyFillArc(self: *Display, drawable_id: u32, gc_id: u32, arcs: []const render.Arc) (error{ NoDrawable, NotGC } || std.mem.Allocator.Error)!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const mode: render.ArcMode = if (gc.values.arc_mode == 0) .chord else .pie_slice;
        try self.renderer.fillArcs(surf, arcs, mode, gc.values.foreground);
    }

    /// Create an off-screen pixmap `pid` matching `drawable_id`'s root, backed
    /// by a zeroed renderer surface of width*height*render.bytesPerPixel(depth)
    /// bytes (capped by max_pixmap_bytes against a hostile width*height). Only
    /// depths 1/24 are supported (this server's advertised depths).
    pub fn createPixmap(self: *Display, pid: u32, drawable_id: u32, depth: u8, width: u16, height: u16, client_id: u32) PixmapError!void {
        if (self.idInUse(pid)) return error.IdInUse;
        if (self.drawable(drawable_id) == null) return error.NoDrawable;
        if (width == 0 or height == 0) return error.BadValue;
        if (depth != 1 and depth != 24) return error.BadValue; // our supported depths
        const size = @as(usize, width) * @as(usize, height) * render.bytesPerPixel(depth);
        if (size > self.max_pixmap_bytes) return error.TooLarge;
        const surface = try self.renderer.createSurface(depth, width, height);
        errdefer self.renderer.destroySurface(surface);
        try self.pixmaps.put(self.gpa, pid, .{ .depth = depth, .width = width, .height = height, .owner = client_id, .surface = surface });
    }

    pub fn freePixmap(self: *Display, pid: u32) FreePixmapError!void {
        if (self.pixmaps.fetchRemove(pid)) |kv| {
            self.renderer.destroySurface(kv.value.surface);
        } else return error.NotPixmap;
    }

    pub fn createGC(self: *Display, cid: u32, drawable_id: u32, delta: GCDelta, client_id: u32) GCError!void {
        if (self.idInUse(cid)) return error.IdInUse;
        if (self.drawable(drawable_id) == null) return error.NoDrawable;
        var v: GCValues = .{};
        delta.applyTo(&v);
        try self.gcs.put(self.gpa, cid, .{ .owner = client_id, .values = v });
    }

    pub fn changeGC(self: *Display, gc: u32, delta: GCDelta) GCOpError!void {
        const g = self.gcs.getPtr(gc) orelse return error.NotGC;
        delta.applyTo(&g.values);
    }

    pub fn freeGC(self: *Display, gc: u32) GCOpError!void {
        if (!self.gcs.remove(gc)) return error.NotGC;
    }

    /// Copy the value-mask-selected components from `src` to `dst`. Only the
    /// stored components have mask bits here; bits for unstored components are
    /// ignored. GC value-mask bit positions per the xproto GC enum.
    pub fn copyGC(self: *Display, src: u32, dst: u32, mask: u32) GCOpError!void {
        const s = (self.gcs.get(src) orelse return error.NotGC).values;
        const d = self.gcs.getPtr(dst) orelse return error.NotGC;
        if (mask & (1 << 0) != 0) d.values.function = s.function;
        if (mask & (1 << 1) != 0) d.values.plane_mask = s.plane_mask;
        if (mask & (1 << 2) != 0) d.values.foreground = s.foreground;
        if (mask & (1 << 3) != 0) d.values.background = s.background;
        if (mask & (1 << 4) != 0) d.values.line_width = s.line_width;
        if (mask & (1 << 5) != 0) d.values.line_style = s.line_style;
        if (mask & (1 << 6) != 0) d.values.cap_style = s.cap_style;
        if (mask & (1 << 7) != 0) d.values.join_style = s.join_style;
        if (mask & (1 << 8) != 0) d.values.fill_style = s.fill_style;
        if (mask & (1 << 14) != 0) d.values.font = s.font;
        if (mask & (1 << 15) != 0) d.values.subwindow_mode = s.subwindow_mode;
        if (mask & (1 << 16) != 0) d.values.graphics_exposures = s.graphics_exposures;
        if (mask & (1 << 22) != 0) d.values.arc_mode = s.arc_mode;
    }

    /// The result of a successful AllocColor: the packed TrueColor pixel plus
    /// the 8-bit-quantized channels expanded back to 16-bit (what the reply
    /// echoes back to the client as the "actual" allocated color).
    pub const AllocColorResult = struct { pixel: u32, red: u16, green: u16, blue: u16 };

    /// Expand an 8-bit channel to 16-bit by replicating it into both bytes
    /// (0xRR -> 0xRRRR), the standard X11 8-to-16 quantization readback.
    fn expand8(c: u32) u16 {
        return @intCast((c << 8) | c);
    }

    /// Register a new colormap `mid` for `visual` on `window`'s screen. `alloc`
    /// must be 0 (None) or 1 (All) per the wire request; this TrueColor-only
    /// server accepts either without distinguishing them (no real cell storage
    /// either way), so the AllocAll-on-TrueColor BadMatch nuance some real
    /// servers enforce is deliberately not enforced here.
    pub fn createColormap(self: *Display, mid: u32, window: u32, visual: u32, alloc: u8, client_id: u32) (error{ BadValue, IdInUse, NoWindow } || std.mem.Allocator.Error)!void {
        if (alloc > 1) return error.BadValue;
        if (self.idInUse(mid)) return error.IdInUse;
        if (!self.windows.contains(window)) return error.NoWindow;
        try self.colormaps.put(self.gpa, mid, .{ .owner = client_id, .visual = visual });
    }

    /// Destroy a colormap, also dropping it from the installed set (a freed
    /// colormap cannot stay "installed").
    pub fn freeColormap(self: *Display, cmap: u32) error{BadColor}!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        _ = self.colormaps.remove(cmap);
        self.uninstallColormapId(cmap);
    }

    /// Allocate a color on `cmap`. TrueColor packing: the pixel IS the top 8
    /// bits of each 16-bit channel, so this is arithmetic (no cell storage,
    /// never fails once `cmap` is validated).
    pub fn allocColor(self: *Display, cmap: u32, red: u16, green: u16, blue: u16) error{BadColor}!AllocColorResult {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        const r8: u32 = red >> 8;
        const g8: u32 = green >> 8;
        const b8: u32 = blue >> 8;
        const pixel: u32 = (r8 << 16) | (g8 << 8) | b8;
        return .{ .pixel = pixel, .red = expand8(r8), .green = expand8(g8), .blue = expand8(b8) };
    }

    /// TrueColor has no allocated cells to free -- validate `cmap` and no-op.
    pub fn freeColors(self: *Display, cmap: u32) error{BadColor}!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
    }

    /// Add `cmap` to the installed set (idempotent -- installing an
    /// already-installed colormap is not an error).
    pub fn installColormap(self: *Display, cmap: u32) (error{BadColor} || std.mem.Allocator.Error)!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        for (self.installed_colormaps.items) |c| {
            if (c == cmap) return;
        }
        try self.installed_colormaps.append(self.gpa, cmap);
    }

    /// Drop `cmap` from the installed set (a no-op if it wasn't installed).
    pub fn uninstallColormap(self: *Display, cmap: u32) error{BadColor}!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        self.uninstallColormapId(cmap);
    }

    /// Remove `cmap` from `installed_colormaps` if present. Shared by
    /// uninstallColormap and freeColormap/destroyClientResources (a colormap
    /// leaving existence must also leave the installed set).
    fn uninstallColormapId(self: *Display, cmap: u32) void {
        var i: usize = 0;
        while (i < self.installed_colormaps.items.len) {
            if (self.installed_colormaps.items[i] == cmap) {
                _ = self.installed_colormaps.orderedRemove(i);
            } else i += 1;
        }
    }

    /// The screen-wide installed set. `window` is validated (BadWindow on a
    /// bogus id) but the result is not per-window -- this server has one screen.
    pub fn listInstalledColormaps(self: *Display, window: u32) error{NoWindow}![]const u32 {
        if (!self.windows.contains(window)) return error.NoWindow;
        return self.installed_colormaps.items;
    }

    /// A single entry in the built-in color-name db (a fixed table, not a real
    /// rgb.txt -- an unknown name is BadName, not a nearest-match guess).
    const ColorName = struct { name: []const u8, r: u8, g: u8, b: u8 };
    const color_names = [_]ColorName{
        .{ .name = "black", .r = 0, .g = 0, .b = 0 },          .{ .name = "white", .r = 255, .g = 255, .b = 255 },
        .{ .name = "red", .r = 255, .g = 0, .b = 0 },          .{ .name = "green", .r = 0, .g = 255, .b = 0 },
        .{ .name = "blue", .r = 0, .g = 0, .b = 255 },         .{ .name = "yellow", .r = 255, .g = 255, .b = 0 },
        .{ .name = "cyan", .r = 0, .g = 255, .b = 255 },       .{ .name = "magenta", .r = 255, .g = 0, .b = 255 },
        .{ .name = "gray", .r = 190, .g = 190, .b = 190 },     .{ .name = "grey", .r = 190, .g = 190, .b = 190 },
        .{ .name = "orange", .r = 255, .g = 165, .b = 0 },     .{ .name = "purple", .r = 160, .g = 32, .b = 240 },
        .{ .name = "brown", .r = 165, .g = 42, .b = 42 },      .{ .name = "pink", .r = 255, .g = 192, .b = 203 },
        .{ .name = "darkgray", .r = 169, .g = 169, .b = 169 }, .{ .name = "lightgray", .r = 211, .g = 211, .b = 211 },
    };

    pub const NamedColor = struct { r8: u8, g8: u8, b8: u8 };

    /// Case-insensitive lookup of a built-in color name against `color_names`.
    fn lookupColorName(name: []const u8) ?NamedColor {
        for (color_names) |c| {
            if (c.name.len != name.len) continue;
            var eq = true;
            for (c.name, name) |a, b| {
                if (a != std.ascii.toLower(b)) {
                    eq = false;
                    break;
                }
            }
            if (eq) return .{ .r8 = c.r, .g8 = c.g, .b8 = c.b };
        }
        return null;
    }

    pub const RgbColor = struct { red: u16, green: u16, blue: u16 };

    /// Unpack a TrueColor-24 pixel into 16-bit-per-channel RGB (the reverse of
    /// allocColor's packing -- 8-bit expanded, same as expand8's readback).
    pub fn unpackColor(self: *Display, pixel: u32) RgbColor {
        _ = self;
        return .{
            .red = expand8((pixel >> 16) & 0xff),
            .green = expand8((pixel >> 8) & 0xff),
            .blue = expand8(pixel & 0xff),
        };
    }

    pub const LookupResult = struct { exact: RgbColor, visual: RgbColor };

    /// Resolve `name` against the built-in db for `cmap`. BadColor first (a
    /// bogus colormap is checked before a bogus name, per X error priority).
    pub fn lookupColor(self: *Display, cmap: u32, name: []const u8) error{ BadColor, BadName }!LookupResult {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        const c = lookupColorName(name) orelse return error.BadName;
        // TrueColor renders exactly at 8-bit precision, so exact == visual.
        const rgb = RgbColor{ .red = expand8(c.r8), .green = expand8(c.g8), .blue = expand8(c.b8) };
        return .{ .exact = rgb, .visual = rgb };
    }

    pub const AllocNamedResult = struct { pixel: u32, exact: RgbColor, visual: RgbColor };

    /// lookupColor + pack the result into a TrueColor pixel, same as allocColor.
    pub fn allocNamedColor(self: *Display, cmap: u32, name: []const u8) error{ BadColor, BadName }!AllocNamedResult {
        const lr = try self.lookupColor(cmap, name);
        const c = lookupColorName(name).?; // lookupColor above already validated the name
        return .{
            .pixel = (@as(u32, c.r8) << 16) | (@as(u32, c.g8) << 8) | c.b8,
            .exact = lr.exact,
            .visual = lr.visual,
        };
    }

    /// Validate `cmap` for QueryColors (the actual pixel->RGB unpack has no
    /// failure mode once the colormap exists, so this is the only check).
    pub fn queryColorsValidate(self: *Display, cmap: u32) error{BadColor}!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
    }

    /// r/w cell allocation: a read-only TrueColor visual has no allocatable
    /// cells, so any request past a valid `cmap` is BadAlloc. (Cell/plane
    /// allocation is identical for this always-full visual.)
    pub fn allocColorCells(self: *Display, cmap: u32) error{ BadColor, BadAlloc }!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        return error.BadAlloc;
    }

    pub fn allocColorPlanes(self: *Display, cmap: u32) error{ BadColor, BadAlloc }!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        return error.BadAlloc;
    }

    /// Storing into a read-only TrueColor colormap is never allowed once
    /// `cmap` itself is valid. (StoreColors/StoreNamedColor are identical.)
    pub fn storeColors(self: *Display, cmap: u32) error{ BadColor, BadAccess }!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        return error.BadAccess;
    }

    pub fn storeNamedColor(self: *Display, cmap: u32) error{ BadColor, BadAccess }!void {
        if (!self.colormaps.contains(cmap)) return error.BadColor;
        return error.BadAccess;
    }

    /// Copy `src`'s visual into a newly-registered `mid` (owned by `client`),
    /// then free `src` (there are no allocated cells to actually copy under
    /// TrueColor, so this is register-then-free). BadColor if `src` isn't a
    /// colormap; IdInUse if `mid` is already a live resource id.
    pub fn copyColormapAndFree(self: *Display, mid: u32, src: u32, client: u32) (error{ BadColor, IdInUse } || std.mem.Allocator.Error)!void {
        const s = self.colormaps.get(src) orelse return error.BadColor;
        if (self.idInUse(mid)) return error.IdInUse;
        try self.colormaps.put(self.gpa, mid, .{ .owner = client, .visual = s.visual });
        _ = self.colormaps.remove(src);
        self.uninstallColormapId(src);
    }

    /// Open `name` under a client-chosen id, via the injected FontProvider.
    /// BadName if the provider has no matching font (the default provider is
    /// lenient and never returns null); on a map-insert failure (OOM) the just-
    /// opened ref is rolled back via closeFont so it isn't leaked.
    pub fn openFont(self: *Display, fid: u32, name: []const u8, client_id: u32) (error{ IdInUse, BadName } || std.mem.Allocator.Error)!void {
        if (self.idInUse(fid)) return error.IdInUse;
        const ref = self.font_provider.openFont(name) orelse return error.BadName;
        self.fonts.put(self.gpa, fid, .{ .owner = client_id, .ref = ref }) catch |e| {
            self.font_provider.closeFont(ref); // rollback: the map insert failed, so nobody else owns this ref
            return e;
        };
    }

    pub fn closeFont(self: *Display, fid: u32) error{NotFont}!void {
        const kv = self.fonts.fetchRemove(fid) orelse return error.NotFont;
        self.font_provider.closeFont(kv.value.ref);
    }

    /// Return the metrics of a live font resource. NotFont for BadFont.
    /// (A GC-as-fontable is not supported; note.)
    pub fn queryFont(self: *Display, fid: u32) error{NotFont}!fontprovider.FontMetrics {
        const f = self.fonts.get(fid) orelse return error.NotFont;
        return self.font_provider.metrics(f.ref);
    }

    /// The provider's font names matching `pattern` (borrowed, provider-lifetime).
    pub fn listFonts(self: *Display, pattern: []const u8) []const []const u8 {
        return self.font_provider.listNames(pattern);
    }

    /// Resolve a GC's font id to a live FontRef, falling back to `default_font`
    /// when the GC's font isn't an open Font resource (e.g. never set).
    fn fontRefFor(self: *Display, gc_font: u32) ?fontprovider.FontRef {
        if (self.fonts.get(gc_font)) |f| return f.ref;
        return self.default_font;
    }

    /// Draw a Latin-1 string at (x,y) (y = baseline) into `drawable_id` with
    /// `gc_id`'s font -- OPAQUE: the text box (x, y-ascent, n*char_width,
    /// ascent+descent) is filled with the GC's background first, then each
    /// glyph is blit in the GC's foreground. `string` is untrusted (client
    /// wire data) but is safe here: it is iterated in-slice, never indexed
    /// past its own length.
    pub fn imageText8(self: *Display, drawable_id: u32, gc_id: u32, x: i16, y: i16, string: []const u8) error{ NoDrawable, NotGC }!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const ref = self.fontRefFor(gc.values.font) orelse return; // no font resolvable -> draw nothing
        const m = self.font_provider.metrics(ref);
        const top: i16 = y - m.ascent;
        // Opaque: measure the text box (sum of advances) and fill with GC background.
        var box_w: i32 = 0;
        for (string) |ch| box_w += self.font_provider.glyph(ref, ch).advance;
        if (box_w < 0) box_w = 0;
        self.renderer.fillRect(surf, x, top, @intCast(@min(box_w, 65535)), @intCast(m.ascent + m.descent), gc.values.background);
        var pen: i16 = x;
        for (string) |ch| {
            const g = self.font_provider.glyph(ref, ch);
            self.renderer.drawGlyph(surf, pen, top, g.bits, g.width, g.height, gc.values.foreground);
            pen +%= g.advance;
        }
    }

    /// Draw a Latin-1 item-stream string at (x,y) (y = baseline) into
    /// `drawable_id` with `gc_id`'s font -- TRANSPARENT: no background fill,
    /// only foreground glyphs land. `items` is UNTRUSTED client wire data (the
    /// PolyText8 item list): every index into it is bounds-checked before use,
    /// and the declared per-item string length `mlen` is clamped to the buffer's
    /// actual remaining length so a malformed/truncated stream can only draw
    /// fewer glyphs, never read out of bounds. Pen advances use wrapping add
    /// (`+%=`) so a hostile run of deltas/glyphs cannot panic on i16 overflow.
    pub fn polyText8(self: *Display, drawable_id: u32, gc_id: u32, x: i16, y: i16, items: []const u8) error{ NoDrawable, NotGC }!void {
        const surf = self.surfaceOf(drawable_id) orelse return error.NoDrawable;
        const gc = self.gcs.get(gc_id) orelse return error.NotGC;
        const ref = self.fontRefFor(gc.values.font) orelse return; // no font resolvable -> draw nothing
        const m = self.font_provider.metrics(ref);
        const top: i16 = y - m.ascent;
        var pen: i16 = x;
        var p: usize = 0;
        while (p < items.len) {
            const mlen = items[p];
            if (mlen == 255) { // font-shift item: 1 marker + 4-byte font id; parsed + ignored (single font).
                p += 5;
                continue;
            }
            if (p + 2 > items.len) break; // need length + delta; truncated stream, stop cleanly
            const delta: i16 = @as(i8, @bitCast(items[p + 1]));
            pen +%= delta;
            const s_start = p + 2;
            const s_end = @min(items.len, s_start + mlen); // clamp the untrusted declared length to the buffer
            var i = s_start;
            while (i < s_end) : (i += 1) {
                const g = self.font_provider.glyph(ref, items[i]);
                self.renderer.drawGlyph(surf, pen, top, g.bits, g.width, g.height, gc.values.foreground); // transparent: no bg fill
                pen +%= g.advance;
            }
            p = s_start + mlen; // advance by the DECLARED length even if clamped (wire framing)
        }
    }

    /// Free every property's data + the props map of a window being torn down.
    fn freeProps(self: *Display, w: *Window) void {
        var it = w.props.valueIterator();
        while (it.next()) |p| self.gpa.free(p.data);
        w.props.deinit(self.gpa);
    }

    /// Record a PropertyNotify for every client that selected PropertyChange on
    /// `wid`, with the given atom + state (0 NewValue / 1 Deleted).
    fn recordProperty(self: *Display, wid: u32, atom: u32, state: u8) std.mem.Allocator.Error!void {
        const w = self.windows.getPtr(wid) orelse return;
        self.prop_time +%= 1;
        try self.recordSelected(w, property_change, .{
            .kind = .property,
            .event_window = wid,
            .window = wid,
            .atom = atom,
            .state = state,
            .time = self.prop_time,
        });
    }

    /// Set/extend window property `prop`. mode 0 Replace (store data as-is);
    /// mode 1 Prepend / 2 Append (concatenate with the existing value, which
    /// must have a matching type+format or it is a BadMatch). Validates the
    /// window, format (8/16/32), the property + type atoms, and the mode; caps
    /// the resulting size (Append accumulates untrusted client data). Records a
    /// PropertyNotify(NewValue) for PropertyChange selectors.
    pub fn changeProperty(self: *Display, wid: u32, prop: u32, ptype: u32, format: u8, mode: u8, data: []const u8, client_id: u32) PropError!void {
        _ = client_id;
        if (!self.windows.contains(wid)) return error.NoWindow;
        if (format != 8 and format != 16 and format != 32) return error.BadValue;
        if (mode > 2) return error.BadValue; // only Replace(0)/Prepend(1)/Append(2)
        if (self.atoms.nameOf(prop) == null) return error.BadAtom;
        if (self.atoms.nameOf(ptype) == null) return error.BadAtom;
        const w = self.windows.getPtr(wid).?;
        const existing = w.props.get(prop);
        // Prepend/Append require a matching type+format when a value exists.
        if (mode != 0) {
            if (existing) |e| {
                if (e.type != ptype or e.format != format) return error.BadMatch;
            }
        }
        const old: []const u8 = if (mode != 0 and existing != null) existing.?.data else &.{};
        const new_len = old.len + data.len;
        if (new_len > max_property_bytes) return error.TooLarge;
        const buf = try self.gpa.alloc(u8, new_len);
        // Fill buf (infallible). After this, buf is transferred into w.props on
        // the commit below; from that point the map owns it, so it must NOT be
        // freed again by any later fallible step (recordProperty).
        switch (mode) {
            2 => { // Append: old ++ data
                @memcpy(buf[0..old.len], old);
                @memcpy(buf[old.len..], data);
            },
            1 => { // Prepend: data ++ old
                @memcpy(buf[0..data.len], data);
                @memcpy(buf[data.len..], old);
            },
            else => @memcpy(buf, data), // Replace (old is empty here)
        }
        // Commit. The replace path frees the previous data and is infallible
        // after the free; the insert path is fallible, so free buf explicitly if
        // the put fails (no function-scoped errdefer, which would double-free buf
        // after a successful commit if recordProperty later OOMs).
        if (w.props.getPtr(prop)) |p| {
            self.gpa.free(p.data);
            p.* = .{ .type = ptype, .format = format, .data = buf };
        } else {
            w.props.put(self.gpa, prop, .{ .type = ptype, .format = format, .data = buf }) catch |e| {
                self.gpa.free(buf);
                return e;
            };
        }
        try self.recordProperty(wid, prop, 0); // NewValue (buf now owned by the map)
    }

    pub fn getProperty(self: *Display, wid: u32, prop: u32, type_filter: u32, long_offset: u32, long_length: u32, delete: bool, client_id: u32) GetPropError!GetPropResult {
        _ = client_id;
        if (!self.windows.contains(wid)) return error.NoWindow;
        if (self.atoms.nameOf(prop) == null) return error.BadAtom;
        if (type_filter != 0 and self.atoms.nameOf(type_filter) == null) return error.BadAtom;
        const w = self.windows.getPtr(wid).?;
        const p = w.props.get(prop) orelse return .{ .found = false, .type = 0, .format = 0, .bytes_after = 0, .value = &.{} };
        // Requested a specific type that does not match -> report the type but no data.
        if (type_filter != 0 and type_filter != p.type) {
            return .{ .found = true, .type = p.type, .format = p.format, .bytes_after = @intCast(p.data.len), .value = &.{} };
        }
        const total = p.data.len;
        const off: usize = @as(usize, long_offset) * 4;
        if (off > total) return error.BadValue;
        const want: usize = @as(usize, long_length) * 4;
        const take = @min(total - off, want);
        const bytes_after: u32 = @intCast(total - off - take);
        const value = p.data[off .. off + take];
        // Delete only when the entire remaining value was returned.
        if (delete and bytes_after == 0) {
            const ptype = p.type;
            self.gpa.free(p.data);
            _ = w.props.remove(prop);
            try self.recordProperty(wid, prop, 1); // Deleted
            return .{ .found = true, .type = ptype, .format = p.format, .bytes_after = 0, .value = &.{} };
        }
        return .{ .found = true, .type = p.type, .format = p.format, .bytes_after = bytes_after, .value = value };
    }

    pub fn deleteProperty(self: *Display, wid: u32, prop: u32, client_id: u32) DeletePropError!void {
        _ = client_id;
        if (!self.windows.contains(wid)) return error.NoWindow;
        if (self.atoms.nameOf(prop) == null) return error.BadAtom;
        const w = self.windows.getPtr(wid).?;
        if (w.props.fetchRemove(prop)) |kv| {
            self.gpa.free(kv.value.data);
            try self.recordProperty(wid, prop, 1); // Deleted
        }
    }

    pub fn listProperties(self: *Display, wid: u32) ListPropError![]u32 {
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        var out = try self.gpa.alloc(u32, w.props.count());
        errdefer self.gpa.free(out);
        var it = w.props.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        return out;
    }

    /// Build & store a minimal-but-valid SYNTHETIC EDID (128 bytes) under the
    /// "EDID" atom in `output_props`, so a RANDR client reading it recognizes
    /// a (fake) real monitor rather than an empty/garbage blob. Standard
    /// header + version 1.4 + one "monitor name" descriptor (type 0xFC,
    /// "Midstall") + a valid checksum (byte 127 chosen so the 128-byte sum
    /// mod 256 is 0, per the EDID spec) -- no real timing/chromaticity data,
    /// since this server has no physical panel to describe. Called once, at
    /// Display init.
    fn seedEdid(self: *Display, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        var edid: [128]u8 = std.mem.zeroes([128]u8);
        // The fixed EDID magic header (bytes 0-7).
        const header = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
        @memcpy(edid[0..8], &header);
        // Manufacturer id + product/serial: any nonzero synthetic values --
        // no real vendor to report, and no client is expected to check these
        // against a PNP id database.
        edid[8] = 0x4D; // "M" (informal, not a real 5-bit-packed PNP id)
        edid[9] = 0x53; // "S"
        edid[10] = 0x01; // product code lo
        edid[11] = 0x00; // product code hi
        edid[12] = 0x01; // serial byte 0
        edid[13] = 0x00;
        edid[14] = 0x00;
        edid[15] = 0x00;
        edid[16] = 1; // week of manufacture
        edid[17] = 30; // year - 1990
        edid[18] = 0x01; // EDID version 1
        edid[19] = 0x04; // EDID revision 4 (1.4)
        // Bytes 20..54 (basic display params, chromaticity, established/
        // standard timings) stay zero -- no real physical panel to describe.
        // Descriptor block 1 @ [54..72) (18 bytes): monitor-name descriptor.
        // [54..57]=0 (not a detailed timing), [57]=0xFC (monitor name tag),
        // [58]=0 (reserved), [59..72)=13 bytes of ASCII text terminated with
        // 0x0A and padded with 0x20 per the EDID spec.
        edid[57] = 0xFC;
        const name: [13]u8 = "Midstall\n    ".*; // "Midstall" + LF + 4 spaces = 13
        @memcpy(edid[59..72], &name);
        // Descriptor blocks 2-4 @ [72..126) stay zero (unused).
        edid[126] = 0; // extension count: no extension blocks
        var sum: u32 = 0;
        for (edid[0..127]) |b| sum += b;
        edid[127] = @intCast((256 - (sum % 256)) % 256); // checksum: sum of all 128 bytes mod 256 == 0

        const data = try gpa.dupe(u8, &edid);
        errdefer gpa.free(data);
        const edid_atom = self.atoms.intern(gpa, "EDID", false) catch |e| switch (e) {
            error.TooManyAtoms => unreachable, // a fresh atom table with one more name is far under any realistic cap
            error.OutOfMemory => return error.OutOfMemory,
        };
        // type = XA_INTEGER (atom id 19: server_atoms' predefined table, 1-based).
        try self.output_props.put(gpa, edid_atom, .{ .type = 19, .format = 8, .data = data });
    }

    /// Record RANDR's OutputProperty event (RRNotify subCode 2) for `output`'s
    /// `atom` to every client that SelectInput'd NotifyMask OutputProperty
    /// (bit 0x8) -- the fan-out counterpart of `recordProperty` for RANDR's
    /// output-property store (called from `outputChangeProperty`/
    /// `outputDeleteProperty` once the mutation has actually happened).
    /// Shares `prop_time` with core PropertyNotify: there's no other
    /// unambiguous "now" for this synthetic single-threaded server to stamp
    /// either kind of property event with.
    fn recordOutputProperty(self: *Display, output: u32, atom: u32, state: u8) EventError!void {
        self.prop_time +%= 1;
        try self.recordRandrEvent(0x8, .randr_output_property, .{
            .output = output,
            .atom = atom,
            .state = state,
        }, 0, 0, 0, 0, self.root, self.prop_time);
    }

    /// ChangeOutputProperty (RANDR minor 13): set/extend property `prop` on
    /// RANDR's single reported output. Mirrors `changeProperty` (same
    /// format/mode/atom validation and Replace(0)/Prepend(1)/Append(2)
    /// semantics, same `max_property_bytes` cap), but validates `output`
    /// against `self.randr.output` (BadOutput) instead of a window id.
    /// Records RANDR's OutputProperty event (NewValue) for OutputProperty
    /// selectors on success.
    pub fn outputChangeProperty(self: *Display, output: u32, prop: u32, ptype: u32, format: u8, mode: u8, data: []const u8, client_id: u32) OutputPropError!void {
        _ = client_id;
        if (output != self.randr.output) return error.BadOutput;
        if (format != 8 and format != 16 and format != 32) return error.BadValue;
        if (mode > 2) return error.BadValue; // only Replace(0)/Prepend(1)/Append(2)
        if (self.atoms.nameOf(prop) == null) return error.BadAtom;
        if (self.atoms.nameOf(ptype) == null) return error.BadAtom;
        const existing = self.output_props.get(prop);
        if (mode != 0) {
            if (existing) |e| {
                if (e.type != ptype or e.format != format) return error.BadMatch;
            }
        }
        const old: []const u8 = if (mode != 0 and existing != null) existing.?.data else &.{};
        const new_len = old.len + data.len;
        if (new_len > max_property_bytes) return error.TooLarge;
        const buf = try self.gpa.alloc(u8, new_len);
        switch (mode) {
            2 => { // Append: old ++ data
                @memcpy(buf[0..old.len], old);
                @memcpy(buf[old.len..], data);
            },
            1 => { // Prepend: data ++ old
                @memcpy(buf[0..data.len], data);
                @memcpy(buf[data.len..], old);
            },
            else => @memcpy(buf, data), // Replace (old is empty here)
        }
        if (self.output_props.getPtr(prop)) |p| {
            self.gpa.free(p.data);
            p.* = .{ .type = ptype, .format = format, .data = buf };
        } else {
            self.output_props.put(self.gpa, prop, .{ .type = ptype, .format = format, .data = buf }) catch |e| {
                self.gpa.free(buf);
                return e;
            };
        }
        try self.recordOutputProperty(output, prop, 0); // NewValue
    }

    /// GetOutputProperty (RANDR minor 15): read (optionally deleting) property
    /// `prop` on RANDR's single output. Mirrors `getProperty`'s windowing/
    /// type-filter/delete semantics exactly, minus the PropertyNotify on
    /// delete (RANDR's own OutputProperty event is deferred, so the delete
    /// path here is a plain free+remove -- no fallible step, hence no
    /// OutOfMemory in `OutputGetPropError`).
    pub fn outputGetProperty(self: *Display, output: u32, prop: u32, type_filter: u32, long_offset: u32, long_length: u32, delete: bool) OutputGetPropError!GetPropResult {
        if (output != self.randr.output) return error.BadOutput;
        if (self.atoms.nameOf(prop) == null) return error.BadAtom;
        if (type_filter != 0 and self.atoms.nameOf(type_filter) == null) return error.BadAtom;
        const p = self.output_props.get(prop) orelse return .{ .found = false, .type = 0, .format = 0, .bytes_after = 0, .value = &.{} };
        if (type_filter != 0 and type_filter != p.type) {
            return .{ .found = true, .type = p.type, .format = p.format, .bytes_after = @intCast(p.data.len), .value = &.{} };
        }
        const total = p.data.len;
        const off: usize = @as(usize, long_offset) * 4;
        if (off > total) return error.BadValue;
        const want: usize = @as(usize, long_length) * 4;
        const take = @min(total - off, want);
        const bytes_after: u32 = @intCast(total - off - take);
        const value = p.data[off .. off + take];
        if (delete and bytes_after == 0) {
            const ptype = p.type;
            const pformat = p.format;
            self.gpa.free(p.data);
            _ = self.output_props.remove(prop);
            return .{ .found = true, .type = ptype, .format = pformat, .bytes_after = 0, .value = &.{} };
        }
        return .{ .found = true, .type = p.type, .format = p.format, .bytes_after = bytes_after, .value = value };
    }

    /// DeleteOutputProperty (RANDR minor 14): remove `prop` from RANDR's
    /// single output, freeing its stored data. Records RANDR's OutputProperty
    /// event (Deleted) for OutputProperty selectors, but only when `prop`
    /// actually existed -- mirrors `deleteProperty`'s "no event for a no-op
    /// delete" rule.
    pub fn outputDeleteProperty(self: *Display, output: u32, prop: u32) OutputDeletePropError!void {
        if (output != self.randr.output) return error.BadOutput;
        if (self.atoms.nameOf(prop) == null) return error.BadAtom;
        if (self.output_props.fetchRemove(prop)) |kv| {
            self.gpa.free(kv.value.data);
            try self.recordOutputProperty(output, prop, 1); // Deleted
        }
    }

    /// ListOutputProperties (RANDR minor 10): every property atom currently
    /// set on RANDR's single output (including the seeded "EDID"). Caller frees.
    pub fn outputListProperties(self: *Display, output: u32) OutputListPropError![]u32 {
        if (output != self.randr.output) return error.BadOutput;
        var out = try self.gpa.alloc(u32, self.output_props.count());
        errdefer self.gpa.free(out);
        var it = self.output_props.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        return out;
    }

    /// RotateProperties: cyclically permute the VALUES of the named properties
    /// on `wid` (Xlib XRotateWindowProperties convention: new value at
    /// atoms[i] = old value of atoms[(i+delta) mod n]). All validation
    /// (window exists, every atom is a real atom, no duplicate atom in the
    /// list, every atom names an EXISTING property on the window) happens
    /// BEFORE any mutation, so a rejected call leaves the window untouched.
    /// The permutation itself just reassigns the owned Property structs among
    /// the existing map keys (a bijection over `atoms` -- no data is copied,
    /// freed, or leaked) and records a PropertyNotify(NewValue) per atom, in
    /// list order.
    pub fn rotateProperties(self: *Display, wid: u32, atoms: []align(1) const u32, delta: i16) (error{ NoWindow, BadAtom, BadMatch } || std.mem.Allocator.Error)!void {
        const w = self.windows.getPtr(wid) orelse return error.NoWindow;
        const n = atoms.len;
        if (n == 0) return;
        for (atoms) |a| {
            if (self.atoms.nameOf(a) == null) return error.BadAtom;
        }
        // O(n^2) duplicate scan: n is a client-supplied property-list length,
        // always small in practice (a window has few properties).
        for (atoms, 0..) |a, i| {
            for (atoms[i + 1 ..]) |b| {
                if (a == b) return error.BadMatch; // duplicate atom in the list
            }
        }
        for (atoms) |a| {
            if (!w.props.contains(a)) return error.BadMatch; // must already be present
        }
        const r: usize = @intCast(@mod(@as(i32, delta), @as(i32, @intCast(n))));
        if (r == 0) return; // no rotation: no mutation, no events
        const temp = try self.gpa.alloc(Property, n);
        defer self.gpa.free(temp);
        for (atoms, 0..) |a, i| temp[i] = w.props.get(a).?;
        for (atoms, 0..) |a, i| w.props.getPtr(a).?.* = temp[(i + r) % n];
        for (atoms) |a| try self.recordProperty(wid, a, 0); // NewValue
    }

    /// SetSelectionOwner: `owner_window` == 0 (None) disowns `selection`;
    /// otherwise `client` (owning `owner_window`) becomes the new owner. A
    /// previous owner that is being REPLACED (different client OR window) gets
    /// a SelectionClear; re-asserting the same client+window is a silent no-op
    /// change (no self-clear, matching real X).
    pub fn setSelectionOwner(self: *Display, selection: u32, owner_window: u32, time: u32, client: u32) error{ BadWindow, BadAtom, OutOfMemory }!void {
        if (self.atoms.nameOf(selection) == null) return error.BadAtom;
        if (owner_window != 0 and self.windows.getPtr(owner_window) == null) return error.BadWindow;
        // CurrentTime(0) -> bump the monotonic property/selection clock (no real
        // clock available); a client-supplied time is trusted as-is (no
        // later-than rejection -- matches the grab-code precedent).
        self.prop_time +%= 1;
        const t = if (time == 0) self.prop_time else time;
        if (self.selections.get(selection)) |prev| {
            if (prev.window != owner_window or prev.client != client) {
                try self.recordEvent(.{
                    .kind = .selection_clear,
                    .target_client = prev.client,
                    .event_window = prev.window,
                    .window = prev.window, // PendingEvent.window has no default; unused by encodeEvent for this kind
                    .atom = selection,
                    .time = t,
                });
            }
        }
        if (owner_window == 0) {
            _ = self.selections.remove(selection);
        } else {
            try self.selections.put(self.gpa, selection, .{ .client = client, .window = owner_window, .time = t });
        }
    }

    /// GetSelectionOwner: the current owner window, or None(0) if unowned.
    pub fn getSelectionOwner(self: *Display, selection: u32) error{BadAtom}!u32 {
        if (self.atoms.nameOf(selection) == null) return error.BadAtom;
        return if (self.selections.get(selection)) |o| o.window else 0;
    }

    /// ConvertSelection: an owned selection gets a single-target SelectionRequest
    /// to the owner; an unowned one gets an immediate SelectionNotify(property =
    /// None) straight back to the requestor (the X "conversion refused, no
    /// owner" signal) -- no MULTIPLE/INCR, no actual data move (the
    /// requestor+owner do that themselves via GetProperty/ChangeProperty).
    pub fn convertSelection(self: *Display, requestor: u32, selection: u32, target: u32, property: u32, time: u32, client: u32) error{ BadWindow, BadAtom, OutOfMemory }!void {
        if (self.windows.getPtr(requestor) == null) return error.BadWindow;
        if (self.atoms.nameOf(selection) == null) return error.BadAtom;
        if (self.atoms.nameOf(target) == null) return error.BadAtom;
        if (property != 0 and self.atoms.nameOf(property) == null) return error.BadAtom;
        if (self.selections.get(selection)) |o| {
            try self.recordEvent(.{
                .kind = .selection_request,
                .target_client = o.client,
                .event_window = o.window,
                .window = requestor,
                .atom = selection,
                .target_atom = target,
                .property_atom = property,
                .time = time, // forwarded verbatim, incl. CurrentTime(0)
            });
        } else {
            try self.recordEvent(.{
                .kind = .selection_notify,
                .target_client = client,
                .event_window = requestor,
                .window = requestor, // PendingEvent.window has no default; unused by encodeEvent for this kind
                .atom = selection,
                .target_atom = target,
                .property_atom = 0, // None: conversion refused, no owner
                .time = time,
            });
        }
    }
};

test "Display pre-creates the root and rejects a duplicate id" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // root exists with the given depth/visual.
    const rg = try d.getGeometry(0x12a);
    try std.testing.expectEqual(@as(u8, 24), rg.depth);
    // create a child under root; CopyFromParent depth(0)/visual(0)/class(0) inherit.
    try d.createWindow(0x200001, 0x12a, .{ .x = 5, .y = 6, .width = 100, .height = 100, .border_width = 0, .depth = 0 }, 0, 0, .{ .event_mask = 0x20000, .override_redirect = true }, 1);
    const g = try d.getGeometry(0x200001);
    try std.testing.expectEqual(@as(u16, 100), g.width);
    try std.testing.expectEqual(@as(u8, 24), g.depth); // inherited
    const a = try d.getAttributes(0x200001, 1);
    try std.testing.expectEqual(@as(u32, 0x20000), a.your_event_mask);
    try std.testing.expectEqual(true, a.attrs.override_redirect);
    try std.testing.expectEqual(@as(u32, 0x21), a.visual); // inherited
    // duplicate id -> IdInUse; bad parent -> NoParent.
    try std.testing.expectError(error.IdInUse, d.createWindow(0x200001, 0x12a, .{}, 1, 0x21, .{}, 1));
    try std.testing.expectError(error.NoParent, d.createWindow(0x200002, 0xDEAD, .{}, 1, 0x21, .{}, 1));
}

test "tree: queryTree lists children; destroyWindow recurses and unlinks" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xB, 0xA, .{ .width = 5, .height = 5 }, 1, 0x21, .{}, 1); // child of A
    const t = try d.queryTree(0x12a);
    try std.testing.expectEqual(@as(u32, 0x12a), t.root);
    try std.testing.expectEqual(@as(usize, 1), t.children.len); // root has A
    try std.testing.expectEqual(@as(u32, 0xA), t.children[0]);
    // destroy A -> A and its child B both gone, root's child list empty.
    try d.destroyWindow(0xA);
    try std.testing.expectError(error.NoWindow, d.getGeometry(0xA));
    try std.testing.expectError(error.NoWindow, d.getGeometry(0xB));
    try std.testing.expectEqual(@as(usize, 0), (try d.queryTree(0x12a)).children.len);
    // bad window ops -> NoWindow.
    try std.testing.expectError(error.NoWindow, d.mapWindow(0xDEAD, 1));
    try std.testing.expectError(error.NoWindow, d.destroyWindow(0xDEAD));
}

test "map/unmap and changeAttributes mutate state" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0xA, 1)).map_state);
    try d.unmapWindow(0xA);
    try std.testing.expectEqual(MapState.unmapped, (try d.getAttributes(0xA, 1)).map_state);
    try d.changeAttributes(0xA, .{ .background_pixel = 0xFFFFFF, .event_mask = 0xFF }, 1);
    const a = try d.getAttributes(0xA, 1);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), a.attrs.background_pixel);
    try std.testing.expectEqual(@as(u32, 0xFF), a.your_event_mask);
}

test "createWindow records CreateNotify only when parent selected SubstructureNotify" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Root has event_mask 0 -> no CreateNotify recorded.
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    d.clearPending();
    // Give A SubstructureNotify, then create a child B under A -> 1 CreateNotify.
    try d.changeAttributes(0xA, .{ .event_mask = substructure_notify }, 1);
    try d.createWindow(0xB, 0xA, .{ .x = 1, .y = 2, .width = 5, .height = 6, .border_width = 1 }, 1, 0x21, .{ .override_redirect = true }, 1);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.create, ev.kind);
    try std.testing.expectEqual(@as(u32, 0xA), ev.event_window); // routed via parent
    try std.testing.expectEqual(@as(u32, 0xA), ev.parent);
    try std.testing.expectEqual(@as(u32, 0xB), ev.window);
    try std.testing.expectEqual(@as(u16, 5), ev.width);
    try std.testing.expectEqual(@as(u16, 6), ev.height);
    try std.testing.expectEqual(@as(u16, 1), ev.border_width);
    try std.testing.expectEqual(true, ev.override_redirect);
}

test "mapWindow records up to two MapNotify and only on a real state change" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // A selects StructureNotify AND its parent (root) selects SubstructureNotify -> 2 MapNotify.
    try d.changeAttributes(0x12a, .{ .event_mask = substructure_notify }, 1);
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify, .override_redirect = true }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 2), d.pending.items.len);
    // First: StructureNotify path (event = the window itself).
    try std.testing.expectEqual(EventKind.map, d.pending.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0xA), d.pending.items[0].event_window);
    try std.testing.expectEqual(@as(u32, 0xA), d.pending.items[0].window);
    try std.testing.expectEqual(true, d.pending.items[0].override_redirect);
    // Second: SubstructureNotify path (event = the parent).
    try std.testing.expectEqual(@as(u32, 0x12a), d.pending.items[1].event_window);
    try std.testing.expectEqual(@as(u32, 0xA), d.pending.items[1].window);
    d.clearPending();
    // Mapping an already-viewable window records nothing.
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "mapWindow records a full-window Expose for an InputOutput window selecting ExposureMask" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 30, .height = 20 }, 1, 0x21, .{ .event_mask = exposure }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.expose, ev.kind);
    try std.testing.expectEqual(@as(u32, 0xA), ev.window);
    try std.testing.expectEqual(@as(i16, 0), ev.x);
    try std.testing.expectEqual(@as(i16, 0), ev.y);
    try std.testing.expectEqual(@as(u16, 30), ev.width);
    try std.testing.expectEqual(@as(u16, 20), ev.height);
    try std.testing.expectEqual(@as(u16, 0), ev.count);
    d.clearPending();
    // Mapping an already-viewable window records no new Expose either.
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "mapWindow still records MapNotify alongside Expose when both are selected" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify | exposure }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 2), d.pending.items.len);
    try std.testing.expectEqual(EventKind.map, d.pending.items[0].kind);
    try std.testing.expectEqual(EventKind.expose, d.pending.items[1].kind);
}

test "mapWindow records no Expose for an InputOnly window even if it selected ExposureMask" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // class 2 == InputOnly: no pixel buffer, so nothing to expose.
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 2, 0x21, .{ .event_mask = exposure }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "mapWindow records no Expose when ExposureMask was not selected" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Selects StructureNotify only -> MapNotify still fires, no Expose.
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    try std.testing.expectEqual(EventKind.map, d.pending.items[0].kind);
}

test "mapWindow paints the window to its background_pixel before the Expose" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 6, .depth = 24 }, 1, 0x21, .{ .background_pixel = 0x00AABBCC, .event_mask = exposure }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    // No ClearArea involved: the paint happens as part of mapWindow itself.
    try std.testing.expectEqual(@as(u32, 0x00AABBCC), readbackPixel(&d, 0xA, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x00AABBCC), readbackPixel(&d, 0xA, 5, 3));
    try std.testing.expectEqual(@as(u32, 0x00AABBCC), readbackPixel(&d, 0xA, 9, 5)); // bottom-right corner
    // The 4c Expose behavior must not regress: still recorded on this map.
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    try std.testing.expectEqual(EventKind.expose, d.pending.items[0].kind);
}

test "mapWindow with default background_pixel (0) leaves the surface at 0" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 8, .height = 4, .depth = 24 }, 1, 0x21, .{ .event_mask = exposure }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0xA, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0xA, 7, 3));
}

test "mapWindow on an InputOnly window does not touch a surface (no crash)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // class 2 == InputOnly: X defines it as having no pixels, so the
    // `w.class != 2` guard must keep the background fillRect (and the Expose)
    // from ever running here (the surface is allocated, but must stay untouched).
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 2, 0x21, .{ .background_pixel = 0x00AABBCC, .event_mask = exposure }, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "unmapWindow records UnmapNotify only when it was mapped" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify }, 1);
    d.clearPending();
    // Not mapped yet -> unmap records nothing.
    try d.unmapWindow(0xA);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    // Map then unmap -> 1 UnmapNotify (only A selects; root selects nothing).
    try d.mapWindow(0xA, 1);
    d.clearPending();
    try d.unmapWindow(0xA);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    try std.testing.expectEqual(EventKind.unmap, d.pending.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0xA), d.pending.items[0].event_window);
    try std.testing.expectEqual(@as(u32, 0xA), d.pending.items[0].window);
}

test "reparentWindow: basic (unmapped) - tree move, geometry, ReparentNotify to window + new parent" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // F = a frame window (will become the new parent); C = a client window, both
    // start as children of root. C selects StructureNotify on itself; F selects
    // SubstructureNotify (so it hears about children reparented into it).
    try d.createWindow(0xF, 0x12a, .{ .width = 20, .height = 20 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xC, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify }, 1);
    try d.changeAttributes(0xF, .{ .event_mask = substructure_notify }, 1);
    d.clearPending();
    try d.reparentWindow(0xC, 0xF, 5, 6, 1);
    // Tree: C now lives under F, not under root.
    try std.testing.expectEqual(@as(u32, 0xF), (try d.queryTree(0xC)).parent);
    const f_tree = try d.queryTree(0xF);
    try std.testing.expectEqual(@as(usize, 1), f_tree.children.len);
    try std.testing.expectEqual(@as(u32, 0xC), f_tree.children[0]);
    const root_tree = try d.queryTree(0x12a);
    for (root_tree.children) |c| try std.testing.expect(c != 0xC);
    // Geometry moved to the request coords.
    const geom = try d.getGeometry(0xC);
    try std.testing.expectEqual(@as(i16, 5), geom.x);
    try std.testing.expectEqual(@as(i16, 6), geom.y);
    // Exactly 2 ReparentNotify: C's own StructureNotify, then F's SubstructureNotify
    // (the old parent, root, selected nothing, so it gets no third event here).
    try std.testing.expectEqual(@as(usize, 2), d.pending.items.len);
    try std.testing.expectEqual(EventKind.reparent, d.pending.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0xC), d.pending.items[0].event_window);
    try std.testing.expectEqual(@as(u32, 0xC), d.pending.items[0].window);
    try std.testing.expectEqual(@as(u32, 0xF), d.pending.items[0].parent);
    try std.testing.expectEqual(EventKind.reparent, d.pending.items[1].kind);
    try std.testing.expectEqual(@as(u32, 0xF), d.pending.items[1].event_window);
    try std.testing.expectEqual(@as(u32, 0xC), d.pending.items[1].window);
}

test "reparentWindow: mapped window auto-unmaps, reparents, and auto-remaps under the new parent" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xF, 0x12a, .{ .width = 20, .height = 20 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xC, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify }, 1);
    try d.mapWindow(0xC, 1);
    d.clearPending();
    try d.reparentWindow(0xC, 0xF, 0, 0, 1);
    // Order: unmap (old parent), reparent, map (new parent) - all three kinds present in order.
    try std.testing.expect(d.pending.items.len >= 3);
    try std.testing.expectEqual(EventKind.unmap, d.pending.items[0].kind);
    var saw_reparent = false;
    var saw_map = false;
    var reparent_idx: usize = 0;
    var map_idx: usize = 0;
    for (d.pending.items, 0..) |ev, i| {
        if (ev.kind == .reparent and !saw_reparent) {
            saw_reparent = true;
            reparent_idx = i;
        }
        if (ev.kind == .map and !saw_map) {
            saw_map = true;
            map_idx = i;
        }
    }
    try std.testing.expect(saw_reparent);
    try std.testing.expect(saw_map);
    try std.testing.expect(reparent_idx < map_idx);
    // C ends viewable, under F.
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0xC, 1)).map_state);
    try std.testing.expectEqual(@as(u32, 0xF), (try d.queryTree(0xC)).parent);
}

test "reparentWindow: cycle guards - self and own descendant are BadMatch" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xF, 0x12a, .{ .width = 20, .height = 20 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xC, 0xF, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1); // child of F
    try d.createWindow(0x67, 0xC, .{ .width = 4, .height = 4 }, 1, 0x21, .{}, 1); // grandchild of F, under C
    // A window cannot be reparented into itself.
    try std.testing.expectError(error.BadMatch, d.reparentWindow(0xC, 0xC, 0, 0, 1));
    // F cannot be reparented into its own descendant G (F -> C -> G).
    try std.testing.expectError(error.BadMatch, d.reparentWindow(0xF, 0x67, 0, 0, 1));
}

test "reparentWindow: InputOutput window into an InputOnly parent is BadMatch" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x70, 0x12a, .{ .width = 20, .height = 20 }, 2, 0x21, .{}, 1); // InputOnly
    try d.createWindow(0xC, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1); // InputOutput
    try std.testing.expectError(error.BadMatch, d.reparentWindow(0xC, 0x70, 0, 0, 1));
}

test "reparentWindow: a missing window or parent is NoWindow" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xF, 0x12a, .{ .width = 20, .height = 20 }, 1, 0x21, .{}, 1);
    try std.testing.expectError(error.NoWindow, d.reparentWindow(0xDEAD, 0xF, 0, 0, 1));
    try std.testing.expectError(error.NoWindow, d.reparentWindow(0xF, 0xDEAD, 0, 0, 1));
}

test "warpPointer: relative move (dst_window=None) moves the pointer and records a MotionNotify" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x80, 0x12a, .{ .width = 100, .height = 100 }, 1, 0x21, .{ .event_mask = pointer_motion }, 1);
    try d.mapWindow(0x80, 1);
    d.pointer_x = 10;
    d.pointer_y = 10;
    d.clearPending();
    try d.warpPointer(0, 0, 0, 0, 0, 0, 5, 3); // None dst -> relative +5,+3
    try std.testing.expectEqual(@as(i16, 15), d.pointer_x);
    try std.testing.expectEqual(@as(i16, 13), d.pointer_y);
    var saw_motion = false;
    for (d.pending.items) |e| {
        if (e.kind == .motion) saw_motion = true;
    }
    try std.testing.expect(saw_motion);
}

test "warpPointer: warp to a window lands at its absOrigin + (dst_x,dst_y)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x81, 0x12a, .{ .x = 200, .y = 150, .width = 50, .height = 50 }, 1, 0x21, .{}, 1);
    const origin = d.absOrigin(0x81);
    try d.warpPointer(0, 0x81, 0, 0, 0, 0, 10, 5);
    try std.testing.expectEqual(Display.clampI16(origin.x + 10), d.pointer_x);
    try std.testing.expectEqual(Display.clampI16(origin.y + 5), d.pointer_y);
}

test "warpPointer: pointer outside the source constraint rect is a no-op" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Source window covers root-relative [0,20)x[0,20) (src_width/height==0 -> to the edge).
    try d.createWindow(0x82, 0x12a, .{ .width = 20, .height = 20 }, 1, 0x21, .{}, 1);
    d.pointer_x = 100;
    d.pointer_y = 100; // well outside the source rect
    d.clearPending();
    try d.warpPointer(0x82, 0, 0, 0, 0, 0, 5, 5);
    try std.testing.expectEqual(@as(i16, 100), d.pointer_x);
    try std.testing.expectEqual(@as(i16, 100), d.pointer_y);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "warpPointer: warping to the current spot records no motion" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    d.pointer_x = 77;
    d.pointer_y = 33;
    d.clearPending();
    try d.warpPointer(0, 0, 0, 0, 0, 0, 0, 0); // relative +0,+0
    try std.testing.expectEqual(@as(i16, 77), d.pointer_x);
    try std.testing.expectEqual(@as(i16, 33), d.pointer_y);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "warpPointer: a bad dst_window or a bad nonzero src_window is BadWindow" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try std.testing.expectError(error.NoWindow, d.warpPointer(0, 0xDEAD, 0, 0, 0, 0, 0, 0));
    try std.testing.expectError(error.NoWindow, d.warpPointer(0xDEAD, 0, 0, 0, 0, 0, 0, 0));
}

test "mapSubwindows maps every unmapped child; an already-mapped child is not double-mapped" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x90, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1); // parent P
    try d.createWindow(0x91, 0x90, .{ .width = 5, .height = 5 }, 1, 0x21, .{ .event_mask = structure_notify }, 1); // C1
    try d.createWindow(0x92, 0x90, .{ .width = 5, .height = 5 }, 1, 0x21, .{ .event_mask = structure_notify }, 1); // C2
    try d.mapWindow(0x91, 1); // C1 already mapped before the batch call
    d.clearPending();
    try d.mapSubwindows(0x90, 1);
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0x91, 1)).map_state);
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0x92, 1)).map_state);
    var saw_c1_map = false;
    var saw_c2_map = false;
    for (d.pending.items) |e| {
        if (e.kind == .map and e.window == 0x91) saw_c1_map = true;
        if (e.kind == .map and e.window == 0x92) saw_c2_map = true;
    }
    try std.testing.expect(!saw_c1_map); // already-mapped: no second MapNotify
    try std.testing.expect(saw_c2_map);
}

test "unmapSubwindows unmaps every mapped child" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA0, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1); // parent P
    try d.createWindow(0xA1, 0xA0, .{ .width = 5, .height = 5 }, 1, 0x21, .{ .event_mask = structure_notify }, 1); // C1
    try d.createWindow(0xA2, 0xA0, .{ .width = 5, .height = 5 }, 1, 0x21, .{ .event_mask = structure_notify }, 1); // C2
    try d.mapWindow(0xA1, 1);
    try d.mapWindow(0xA2, 1);
    d.clearPending();
    try d.unmapSubwindows(0xA0);
    try std.testing.expectEqual(MapState.unmapped, (try d.getAttributes(0xA1, 1)).map_state);
    try std.testing.expectEqual(MapState.unmapped, (try d.getAttributes(0xA2, 1)).map_state);
    var saw_c1_unmap = false;
    var saw_c2_unmap = false;
    for (d.pending.items) |e| {
        if (e.kind == .unmap and e.window == 0xA1) saw_c1_unmap = true;
        if (e.kind == .unmap and e.window == 0xA2) saw_c2_unmap = true;
    }
    try std.testing.expect(saw_c1_unmap);
    try std.testing.expect(saw_c2_unmap);
}

test "mapSubwindows/unmapSubwindows on a bad window is BadWindow" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try std.testing.expectError(error.NoWindow, d.mapSubwindows(0xDEAD, 1));
    try std.testing.expectError(error.NoWindow, d.unmapSubwindows(0xDEAD));
}

test "rotateProperties: delta=1 permutes three props' values and notifies per atom" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xB0, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const str = try d.atoms.intern(gpa, "STRING", false);
    const p0 = try d.atoms.intern(gpa, "P0", false);
    const p1 = try d.atoms.intern(gpa, "P1", false);
    const p2 = try d.atoms.intern(gpa, "P2", false);
    try d.changeProperty(0xB0, p0, str, 8, 0, "v0", 1);
    try d.changeProperty(0xB0, p1, str, 8, 0, "v1", 1);
    try d.changeProperty(0xB0, p2, str, 8, 0, "v2", 1);
    try d.changeAttributes(0xB0, .{ .event_mask = property_change }, 2);
    d.clearPending();

    const atoms = [_]u32{ p0, p1, p2 };
    try d.rotateProperties(0xB0, &atoms, 1);
    // new[i] = old[(i+1) mod 3]: P0<-v1, P1<-v2, P2<-v0.
    var g = try d.getProperty(0xB0, p0, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v1", g.value);
    g = try d.getProperty(0xB0, p1, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v2", g.value);
    g = try d.getProperty(0xB0, p2, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v0", g.value);
    // A PropertyNotify per atom, in list order.
    try std.testing.expectEqual(@as(usize, 3), d.pending.items.len);
    try std.testing.expectEqual(p0, d.pending.items[0].atom);
    try std.testing.expectEqual(p1, d.pending.items[1].atom);
    try std.testing.expectEqual(p2, d.pending.items[2].atom);
    for (d.pending.items) |e| try std.testing.expectEqual(@as(u8, 0), e.state); // NewValue
}

test "rotateProperties: delta=0 or delta==n is a no-op with no events" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xB1, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const str = try d.atoms.intern(gpa, "STRING", false);
    const p0 = try d.atoms.intern(gpa, "P0", false);
    const p1 = try d.atoms.intern(gpa, "P1", false);
    try d.changeProperty(0xB1, p0, str, 8, 0, "v0", 1);
    try d.changeProperty(0xB1, p1, str, 8, 0, "v1", 1);
    d.clearPending();
    const atoms = [_]u32{ p0, p1 };
    try d.rotateProperties(0xB1, &atoms, 0);
    try d.rotateProperties(0xB1, &atoms, 2); // == n
    var g = try d.getProperty(0xB1, p0, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v0", g.value);
    g = try d.getProperty(0xB1, p1, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v1", g.value);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "rotateProperties: negative delta normalizes (rotates the other way)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xB2, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const str = try d.atoms.intern(gpa, "STRING", false);
    const p0 = try d.atoms.intern(gpa, "P0", false);
    const p1 = try d.atoms.intern(gpa, "P1", false);
    const p2 = try d.atoms.intern(gpa, "P2", false);
    try d.changeProperty(0xB2, p0, str, 8, 0, "v0", 1);
    try d.changeProperty(0xB2, p1, str, 8, 0, "v1", 1);
    try d.changeProperty(0xB2, p2, str, 8, 0, "v2", 1);
    const atoms = [_]u32{ p0, p1, p2 };
    try d.rotateProperties(0xB2, &atoms, -1); // same as delta=2: new[i]=old[(i+2)%3]
    var g = try d.getProperty(0xB2, p0, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v2", g.value);
    g = try d.getProperty(0xB2, p1, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v0", g.value);
    g = try d.getProperty(0xB2, p2, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v1", g.value);
}

test "rotateProperties: duplicate atom, missing prop, invalid atom, bad window" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xB3, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const str = try d.atoms.intern(gpa, "STRING", false);
    const p0 = try d.atoms.intern(gpa, "P0", false);
    const p1 = try d.atoms.intern(gpa, "P1", false);
    try d.changeProperty(0xB3, p0, str, 8, 0, "v0", 1);
    try d.changeProperty(0xB3, p1, str, 8, 0, "v1", 1);

    const dup = [_]u32{ p0, p0 };
    try std.testing.expectError(error.BadMatch, d.rotateProperties(0xB3, &dup, 1));
    const missing = [_]u32{ p0, 9999 }; // 9999 not a real atom -> BadAtom takes priority
    try std.testing.expectError(error.BadAtom, d.rotateProperties(0xB3, &missing, 1));
    const p2 = try d.atoms.intern(gpa, "P2", false); // valid atom, never set on the window
    const not_present = [_]u32{ p0, p2 };
    try std.testing.expectError(error.BadMatch, d.rotateProperties(0xB3, &not_present, 1));
    const ok = [_]u32{ p0, p1 };
    try std.testing.expectError(error.NoWindow, d.rotateProperties(0xDEAD, &ok, 1));

    // None of the rejected calls mutated anything.
    const g = try d.getProperty(0xB3, p0, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("v0", g.value);
}

test "rotateProperties: no leak on a real rotation (test allocator proves it)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xB4, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const str = try d.atoms.intern(gpa, "STRING", false);
    const p0 = try d.atoms.intern(gpa, "P0", false);
    const p1 = try d.atoms.intern(gpa, "P1", false);
    const p2 = try d.atoms.intern(gpa, "P2", false);
    try d.changeProperty(0xB4, p0, str, 8, 0, "aaa", 1);
    try d.changeProperty(0xB4, p1, str, 8, 0, "bb", 1);
    try d.changeProperty(0xB4, p2, str, 8, 0, "c", 1);
    const atoms = [_]u32{ p0, p1, p2 };
    try d.rotateProperties(0xB4, &atoms, 1);
    try d.rotateProperties(0xB4, &atoms, -1);
    // d.deinit() at scope exit frees every remaining property's data; the test
    // allocator asserts no leak/double-free across the whole test.
}

test "pointer mapping: default identity, set + readback, wrong length is BadValue" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, d.getPointerMapping());
    const status = try d.setPointerMapping(&.{ 2, 1, 3, 4, 5 });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u8, 2), d.getPointerMapping()[0]);
    try std.testing.expectEqual(@as(u8, 1), d.getPointerMapping()[1]);
    try std.testing.expectError(error.BadValue, d.setPointerMapping(&.{ 1, 2, 3 })); // wrong length
}

test "setModifierMapping: per=2 valid remap round-trips through modifierMapping/modifierIndexOf" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    var codes = [_]u8{0} ** 16;
    codes[0] = 60; // Shift slot 0 moved to keycode 60
    codes[8] = 40; // Mod1 slot 0 (index 4*2=8) moved to keycode 40
    const status = try d.setModifierMapping(2, &codes);
    try std.testing.expectEqual(@as(u8, 0), status);
    const mm = d.modifierMapping();
    try std.testing.expectEqual(@as(u8, 2), mm.per);
    try std.testing.expectEqual(@as(u8, 60), mm.codes[0]);
    try std.testing.expectEqual(@as(?u3, 0), d.modifierIndexOf(60)); // Shift
    try std.testing.expectEqual(@as(?u3, 4), d.modifierIndexOf(40)); // Mod1
}

test "setModifierMapping: per=1 with 8 keycodes shrinks per and codes.len" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const codes = [_]u8{ 50, 0, 37, 0, 0, 0, 0, 0 };
    const status = try d.setModifierMapping(1, &codes);
    try std.testing.expectEqual(@as(u8, 0), status);
    const mm = d.modifierMapping();
    try std.testing.expectEqual(@as(u8, 1), mm.per);
    try std.testing.expectEqual(@as(usize, 8), mm.codes.len);
    try std.testing.expectEqual(@as(?u3, 0), d.modifierIndexOf(50));
}

test "setModifierMapping: out-of-range keycode, length mismatch, per=9 are BadValue" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    var bad_range = [_]u8{0} ** 16;
    bad_range[0] = 3; // below min_keycode(8)
    try std.testing.expectError(error.BadValue, d.setModifierMapping(2, &bad_range));
    const wrong_len = [_]u8{ 1, 2, 3 }; // != 8*per
    try std.testing.expectError(error.BadValue, d.setModifierMapping(2, &wrong_len));
    const per9 = [_]u8{0} ** 72;
    try std.testing.expectError(error.BadValue, d.setModifierMapping(9, &per9));
}

test "destroyWindow records a DestroyNotify per window, bottom-up" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // A (StructureNotify) has child B (StructureNotify). Destroying A emits
    // DestroyNotify for B (deepest) before A.
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify }, 1);
    try d.createWindow(0xB, 0xA, .{ .width = 5, .height = 5 }, 1, 0x21, .{ .event_mask = structure_notify }, 1);
    d.clearPending();
    try d.destroyWindow(0xA);
    try std.testing.expectEqual(@as(usize, 2), d.pending.items.len);
    // Bottom-up: B before A.
    try std.testing.expectEqual(EventKind.destroy, d.pending.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0xB), d.pending.items[0].window);
    try std.testing.expectEqual(@as(u32, 0xA), d.pending.items[1].window);
    // clearPending empties the list.
    d.clearPending();
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "destroySubtree is iterative: a deep chain destroys without overflow, bottom-up" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Build a linear chain root -> w1 -> w2 -> ... -> wN, each selecting
    // StructureNotify so each destroyed window records one DestroyNotify.
    // IDs start well above the root's id (0x12a == 298) so the chain never
    // collides with the pre-existing root window.
    const base: u32 = 0x10000;
    const N: u32 = 5000;
    var parent: u32 = 0x12a;
    var id: u32 = base;
    while (id < base + N) : (id += 1) {
        try d.createWindow(id, parent, .{ .width = 1, .height = 1 }, 1, 0x21, .{ .event_mask = structure_notify }, 1);
        parent = id;
    }
    d.clearPending();
    try d.destroyWindow(base); // destroys the whole chain
    // Every window gone.
    try std.testing.expectError(error.NoWindow, d.getGeometry(base));
    try std.testing.expectError(error.NoWindow, d.getGeometry(base + N - 1));
    // One DestroyNotify per window, deepest (last) first (bottom-up).
    try std.testing.expectEqual(@as(usize, N), d.pending.items.len);
    try std.testing.expectEqual(@as(u32, base + N - 1), d.pending.items[0].window);
    try std.testing.expectEqual(@as(u32, base), d.pending.items[N - 1].window);
}

test "window-count cap returns TooManyResources at the limit" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    d.max_windows = 3; // root counts as one; room for two more
    try d.createWindow(0xA, 0x12a, .{ .width = 1, .height = 1 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xB, 0x12a, .{ .width = 1, .height = 1 }, 1, 0x21, .{}, 1);
    // count is now 3 (root, A, B) == cap -> next create is refused.
    try std.testing.expectError(error.TooManyResources, d.createWindow(0xC, 0x12a, .{ .width = 1, .height = 1 }, 1, 0x21, .{}, 1));
}

test "map/unmap ignore the root (no state flip, no event)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    d.clearPending();
    try d.unmapWindow(0x12a); // hostile UnmapWindow(root)
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0x12a, 1)).map_state);
    try d.mapWindow(0x12a, 1);
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0x12a, 1)).map_state);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "per-client masks: distinct selections, fan-out tagging, your vs all" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // W under root; client 1 selects StructureNotify on W, client 2 selects
    // SubstructureNotify on the root (W's parent).
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    try d.changeAttributes(0xA, .{ .event_mask = structure_notify }, 1);
    try d.changeAttributes(0x12a, .{ .event_mask = substructure_notify }, 2);
    d.clearPending();
    try d.mapWindow(0xA, 1);
    // Two MapNotifys: one to client 1 (StructureNotify on W), one to client 2
    // (SubstructureNotify on root).
    try std.testing.expectEqual(@as(usize, 2), d.pending.items.len);
    var saw1 = false;
    var saw2 = false;
    for (d.pending.items) |ev| {
        try std.testing.expectEqual(EventKind.map, ev.kind);
        try std.testing.expectEqual(@as(u32, 0xA), ev.window);
        if (ev.target_client == 1) saw1 = true;
        if (ev.target_client == 2) saw2 = true;
    }
    try std.testing.expect(saw1 and saw2);
    // your_event_mask is per-asker; all_event_masks is the OR.
    const a1 = try d.getAttributes(0xA, 1);
    try std.testing.expectEqual(structure_notify, a1.your_event_mask);
    const a3 = try d.getAttributes(0xA, 3); // a client that selected nothing
    try std.testing.expectEqual(@as(u32, 0), a3.your_event_mask);
    try std.testing.expectEqual(structure_notify, a1.all_event_masks);
}

test "changeAttributes updates only the calling client's mask entry" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    try d.changeAttributes(0xA, .{ .event_mask = structure_notify }, 1);
    try d.changeAttributes(0xA, .{ .event_mask = substructure_notify }, 2);
    // Client 1 changes its own mask; client 2's is untouched.
    try d.changeAttributes(0xA, .{ .event_mask = 0 }, 1); // deselect
    try std.testing.expectEqual(@as(u32, 0), (try d.getAttributes(0xA, 1)).your_event_mask);
    try std.testing.expectEqual(substructure_notify, (try d.getAttributes(0xA, 2)).your_event_mask);
    try std.testing.expectEqual(substructure_notify, (try d.getAttributes(0xA, 1)).all_event_masks);
}

test "non-selecting client gets no event" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    d.clearPending();
    try d.mapWindow(0xA, 1); // nobody selected StructureNotify on A or Substructure on root
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "cleanupClient destroys owned windows, notifies selectors, scrubs masks, spares others" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // client 1 creates W1 (0xA) under root.
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    // client 2 creates W2 (0xB) under root, and selects StructureNotify on W1 (watches client 1's window).
    try d.createWindow(0xB, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 2);
    try d.changeAttributes(0xA, .{ .event_mask = structure_notify }, 2);
    // client 3 selects SubstructureNotify on the root.
    try d.changeAttributes(0x12a, .{ .event_mask = substructure_notify }, 3);
    // client 1 also selects StructureNotify on W2 (a window it does NOT own) - must be scrubbed.
    try d.changeAttributes(0xB, .{ .event_mask = structure_notify }, 1);
    d.clearPending();

    try d.cleanupClient(1);

    // W1 (owner 1) is gone; W2 (owner 2) and the root survive.
    try std.testing.expectError(error.NoWindow, d.getGeometry(0xA));
    _ = try d.getGeometry(0xB);
    _ = try d.getGeometry(0x12a);
    // DestroyNotify for W1 fired to client 2 (StructureNotify on W1) and client 3 (SubstructureNotify on root).
    var to2 = false;
    var to3 = false;
    for (d.pending.items) |ev| {
        if (ev.kind == .destroy and ev.window == 0xA) {
            if (ev.target_client == 2) to2 = true;
            if (ev.target_client == 3) to3 = true;
        }
    }
    try std.testing.expect(to2 and to3);
    // Client 1's selection on the surviving W2 was scrubbed; client 2's own selection is intact.
    try std.testing.expectEqual(@as(u32, 0), (try d.getAttributes(0xB, 1)).your_event_mask);
}

test "changeSaveSet: Insert an OTHER client's window ok, own window is BadMatch, bad mode is BadValue, missing window is NoWindow, Delete removes it" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Client 2 owns W; client 1 save-sets it.
    try d.createWindow(0xB, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 2);
    try d.changeSaveSet(0, 0xB, 1); // Insert
    try std.testing.expectEqual(@as(usize, 1), d.save_set.items.len);
    try std.testing.expectEqual(@as(u32, 1), d.save_set.items[0].client);
    try std.testing.expectEqual(@as(u32, 0xB), d.save_set.items[0].window);

    // A client may not save-set its OWN window.
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    try std.testing.expectError(error.BadMatch, d.changeSaveSet(0, 0xA, 1));

    // mode > 1 is BadValue.
    try std.testing.expectError(error.BadValue, d.changeSaveSet(2, 0xB, 1));

    // A missing window is NoWindow.
    try std.testing.expectError(error.NoWindow, d.changeSaveSet(0, 0xDEAD, 1));

    // Delete removes the entry (idempotent Insert above left exactly one).
    try d.changeSaveSet(1, 0xB, 1); // Delete
    try std.testing.expectEqual(@as(usize, 0), d.save_set.items.len);
}

test "cleanupClient RESCUE: a save-set window inside the disconnecting client's frame survives, reparented to root" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // A (client 1) is the WM: it creates frame F under root.
    try d.createWindow(0xF, 0x12a, .{ .x = 5, .y = 6, .width = 20, .height = 20 }, 1, 0x21, .{}, 1);
    // B (client 2) creates window C under root, then A reparents C into F
    // (the classic reparenting-WM move) at (2,3) relative to F.
    try d.createWindow(0xC, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .event_mask = structure_notify }, 2);
    try d.reparentWindow(0xC, 0xF, 2, 3, 1);
    try std.testing.expectEqual(@as(u32, 0xF), (try d.queryTree(0xC)).parent);
    // A save-sets C (protecting it -- ICCCM save-set).
    try d.changeSaveSet(0, 0xC, 1);
    const abs_before = d.absOrigin(0xC); // F's (5,6) + C's (2,3) = (7,9)
    try std.testing.expectEqual(@as(i32, 7), abs_before.x);
    try std.testing.expectEqual(@as(i32, 9), abs_before.y);
    d.clearPending();

    try d.cleanupClient(1); // A disconnects

    // C survived, reparented to root, at its preserved absolute position.
    const tree = try d.queryTree(0xC);
    try std.testing.expectEqual(@as(u32, 0x12a), tree.parent);
    const geom = try d.getGeometry(0xC);
    try std.testing.expectEqual(@as(i16, 7), geom.x);
    try std.testing.expectEqual(@as(i16, 9), geom.y);
    // F (A's frame) is gone.
    try std.testing.expectError(error.NoWindow, d.getGeometry(0xF));
    // The save-set entry was consumed.
    try std.testing.expectEqual(@as(usize, 0), d.save_set.items.len);
    // A ReparentNotify fired for C (its own StructureNotify selection).
    var saw_reparent = false;
    for (d.pending.items) |ev| {
        if (ev.kind == .reparent and ev.window == 0xC and ev.parent == 0x12a) saw_reparent = true;
    }
    try std.testing.expect(saw_reparent);
}

test "cleanupClient CONTROL: without a save-set entry, a reparented-in window dies with its owner's frame" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xF, 0x12a, .{ .width = 20, .height = 20 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xC, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 2);
    try d.reparentWindow(0xC, 0xF, 0, 0, 1);
    // No changeSaveSet call this time.
    try d.cleanupClient(1);
    // C was destroyed along with F -- the exact hazard the save-set exists to prevent.
    try std.testing.expectError(error.NoWindow, d.getGeometry(0xC));
    try std.testing.expectError(error.NoWindow, d.getGeometry(0xF));
}

test "destroySubtree PRUNE: destroying a save-set window leaves no stale save_set entry" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xC, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 2);
    try d.changeSaveSet(0, 0xC, 1);
    try std.testing.expectEqual(@as(usize, 1), d.save_set.items.len);
    try d.destroyWindow(0xC); // C's own owner (client 2) destroys it directly
    try std.testing.expectEqual(@as(usize, 0), d.save_set.items.len);
}

test "Display owns a shared atom table with predefined atoms" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try std.testing.expectEqual(@as(u32, 39), try d.atoms.intern(gpa, "WM_NAME", false));
    try std.testing.expectEqualStrings("WM_NAME", d.atoms.nameOf(39).?);
    // Display.init's seedEdid already interned "EDID" as atom 69 (the 68
    // predefined atoms + 1), so the next fresh name is 70.
    try std.testing.expectEqual(@as(u32, 70), try d.atoms.intern(gpa, "FRESH", false));
}

test "createWindow rolls back the window if linking to the parent OOMs" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = fa.allocator();
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Reserve window-table capacity so createWindow's put() does NOT allocate.
    // createWindow allocates in order: the window pixel buffer, then (put uses
    // the reserved capacity), then children.append. So fail the SECOND next
    // allocation to land on children.append - exercising the rollback branch
    // that frees the window's pixel buffer and removes it via fetchRemove.
    try d.windows.ensureTotalCapacity(gpa, 8);
    fa.fail_index = fa.alloc_index + 1; // skip the pixel-buffer alloc, fail children.append
    try std.testing.expectError(error.OutOfMemory, d.createWindow(0xA, 0x12a, .{ .width = 1, .height = 1 }, 1, 0x21, .{}, 1));
    fa.fail_index = std.math.maxInt(usize); // stop failing so deinit can run
    // The half-created window must be gone (rolled back), not a lingering orphan.
    try std.testing.expectError(error.NoWindow, d.getGeometry(0xA));
}

test "properties: change/get round-trip, append, type-filter, delete, notify" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const wm_name = try d.atoms.intern(gpa, "WM_NAME", false); // 39
    const str = try d.atoms.intern(gpa, "STRING", false); // 31
    // client 2 selects PropertyChange on the window.
    try d.changeAttributes(0xA, .{ .event_mask = property_change }, 2);
    d.clearPending();

    // Replace with "hello".
    try d.changeProperty(0xA, wm_name, str, 8, 0, "hello", 1);
    // A PropertyNotify(NewValue) targeting client 2 was recorded.
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    try std.testing.expectEqual(EventKind.property, d.pending.items[0].kind);
    try std.testing.expectEqual(wm_name, d.pending.items[0].atom);
    try std.testing.expectEqual(@as(u8, 0), d.pending.items[0].state); // NewValue
    try std.testing.expectEqual(@as(u32, 2), d.pending.items[0].target_client);

    // Read it back whole.
    var g = try d.getProperty(0xA, wm_name, 0, 0, 100, false, 1);
    try std.testing.expect(g.found);
    try std.testing.expectEqual(str, g.type);
    try std.testing.expectEqual(@as(u8, 8), g.format);
    try std.testing.expectEqual(@as(u32, 0), g.bytes_after);
    try std.testing.expectEqualStrings("hello", g.value);

    // Append " world" -> "hello world".
    try d.changeProperty(0xA, wm_name, str, 8, 2, " world", 1);
    g = try d.getProperty(0xA, wm_name, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("hello world", g.value);
    // Append with a mismatched type -> BadMatch.
    try std.testing.expectError(error.BadMatch, d.changeProperty(0xA, wm_name, str + 1, 8, 2, "x", 1));

    // type_filter mismatch -> stored type, empty value, full bytes_after.
    g = try d.getProperty(0xA, wm_name, str + 1, 0, 100, false, 1);
    try std.testing.expectEqual(str, g.type);
    try std.testing.expectEqual(@as(usize, 0), g.value.len);
    try std.testing.expectEqual(@as(u32, 11), g.bytes_after);

    // Offset windowing: skip 4 bytes (long_offset 1), take 1 unit (4 bytes).
    g = try d.getProperty(0xA, wm_name, 0, 1, 1, false, 1);
    try std.testing.expectEqualStrings("o wo", g.value);
    try std.testing.expectEqual(@as(u32, 3), g.bytes_after); // "rld" left
    // Offset past the end -> BadValue.
    try std.testing.expectError(error.BadValue, d.getProperty(0xA, wm_name, 0, 3, 1, false, 1)); // 3*4=12 > 11

    // listProperties returns the key.
    const keys = try d.listProperties(0xA);
    defer gpa.free(keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqual(wm_name, keys[0]);

    // delete via getProperty(delete=true) once fully read.
    d.clearPending();
    g = try d.getProperty(0xA, wm_name, 0, 0, 100, true, 1);
    try std.testing.expect(g.found);
    try std.testing.expectError(error.NoWindow, d.getProperty(0xDEAD, wm_name, 0, 0, 1, false, 1));
    // Property is gone now; a PropertyNotify(Deleted) to client 2 was recorded.
    const g2 = try d.getProperty(0xA, wm_name, 0, 0, 100, false, 1);
    try std.testing.expect(!g2.found);
    try std.testing.expectEqual(@as(u8, 1), d.pending.items[d.pending.items.len - 1].state); // Deleted

    // Bad format -> BadValue; bad property atom -> BadAtom.
    try std.testing.expectError(error.BadValue, d.changeProperty(0xA, wm_name, str, 7, 0, "x", 1));
    try std.testing.expectError(error.BadAtom, d.changeProperty(0xA, 9999, str, 8, 0, "x", 1));
}

test "changeProperty rejects an invalid mode without corrupting an existing property" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const p = try d.atoms.intern(gpa, "PROP", false);
    const str = try d.atoms.intern(gpa, "STRING", false);
    try d.changeProperty(0xA, p, str, 8, 0, "hello world", 1);
    // A mode that isn't Replace/Prepend/Append is BadValue (must not @memcpy-panic
    // or corrupt the stored value).
    try std.testing.expectError(error.BadValue, d.changeProperty(0xA, p, str, 8, 5, "x", 1));
    // The original value is intact.
    const g = try d.getProperty(0xA, p, 0, 0, 100, false, 1);
    try std.testing.expectEqualStrings("hello world", g.value);
}

test "setSelectionOwner + getSelectionOwner round-trip" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    try d.setSelectionOwner(primary, 0xA, 0, 1);
    try std.testing.expectEqual(@as(u32, 0xA), try d.getSelectionOwner(primary));
}

test "setSelectionOwner: re-assert by a DIFFERENT client/window records a selection_clear to the previous owner" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xB, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 2);
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    try d.setSelectionOwner(primary, 0xA, 0, 1);
    d.clearPending();
    try d.setSelectionOwner(primary, 0xB, 0, 2); // different client AND window
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.selection_clear, ev.kind);
    try std.testing.expectEqual(@as(u32, 1), ev.target_client);
    try std.testing.expectEqual(@as(u32, 0xA), ev.event_window);
    try std.testing.expectEqual(primary, ev.atom);
    try std.testing.expectEqual(@as(u32, 0xB), try d.getSelectionOwner(primary));
}

test "setSelectionOwner: re-assert by the SAME client+window records NO selection_clear" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    try d.setSelectionOwner(primary, 0xA, 0, 1);
    d.clearPending();
    try d.setSelectionOwner(primary, 0xA, 0, 1); // same client + window
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    try std.testing.expectEqual(@as(u32, 0xA), try d.getSelectionOwner(primary));
}

test "setSelectionOwner(None) disowns: getSelectionOwner -> 0, no entry left" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    try d.setSelectionOwner(primary, 0xA, 0, 1);
    try d.setSelectionOwner(primary, 0, 0, 1); // None
    try std.testing.expectEqual(@as(u32, 0), try d.getSelectionOwner(primary));
    try std.testing.expect(!d.selections.contains(primary));
}

test "convertSelection with an owner records a single-target selection_request to the owner" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1); // owner window
    try d.createWindow(0xB, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 2); // requestor window
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    const string_atom = try d.atoms.intern(gpa, "STRING", false);
    const prop = try d.atoms.intern(gpa, "MY_PROP", false);
    try d.setSelectionOwner(primary, 0xA, 0, 1);
    d.clearPending();
    try d.convertSelection(0xB, primary, string_atom, prop, 0, 2);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.selection_request, ev.kind);
    try std.testing.expectEqual(@as(u32, 1), ev.target_client); // owner client
    try std.testing.expectEqual(@as(u32, 0xA), ev.event_window); // owner window
    try std.testing.expectEqual(@as(u32, 0xB), ev.window); // requestor
    try std.testing.expectEqual(primary, ev.atom);
    try std.testing.expectEqual(string_atom, ev.target_atom);
    try std.testing.expectEqual(prop, ev.property_atom);
}

test "convertSelection with NO owner records an immediate selection_notify(property=None) to the requestor" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xB, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 2);
    const secondary = try d.atoms.intern(gpa, "SECONDARY", false);
    const string_atom = try d.atoms.intern(gpa, "STRING", false);
    try d.convertSelection(0xB, secondary, string_atom, 0, 0, 2);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.selection_notify, ev.kind);
    try std.testing.expectEqual(@as(u32, 2), ev.target_client); // the requesting client
    try std.testing.expectEqual(@as(u32, 0xB), ev.event_window); // requestor window
    try std.testing.expectEqual(secondary, ev.atom);
    try std.testing.expectEqual(string_atom, ev.target_atom);
    try std.testing.expectEqual(@as(u32, 0), ev.property_atom); // None
}

test "selections: BadAtom on an unknown selection/target/property atom" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    const string_atom = try d.atoms.intern(gpa, "STRING", false);
    const bogus: u32 = 0xDEAD;
    try std.testing.expectError(error.BadAtom, d.setSelectionOwner(bogus, 0xA, 0, 1));
    try std.testing.expectError(error.BadAtom, d.getSelectionOwner(bogus));
    try std.testing.expectError(error.BadAtom, d.convertSelection(0xA, bogus, string_atom, 0, 0, 1));
    try std.testing.expectError(error.BadAtom, d.convertSelection(0xA, primary, bogus, 0, 0, 1)); // unknown target
    try std.testing.expectError(error.BadAtom, d.convertSelection(0xA, primary, string_atom, bogus, 0, 1)); // unknown non-zero property
}

test "selections: BadWindow on a non-existent owner window / requestor window" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    const string_atom = try d.atoms.intern(gpa, "STRING", false);
    try std.testing.expectError(error.BadWindow, d.setSelectionOwner(primary, 0xDEAD, 0, 1));
    try std.testing.expectError(error.BadWindow, d.convertSelection(0xDEAD, primary, string_atom, 0, 0, 1));
}

test "disconnect (cleanupClient) disowns a client's selections, with no SelectionClear" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    const primary = try d.atoms.intern(gpa, "PRIMARY", false);
    try d.setSelectionOwner(primary, 0xA, 0, 1);
    d.clearPending();
    try d.cleanupClient(1);
    try std.testing.expectEqual(@as(u32, 0), try d.getSelectionOwner(primary));
    // No SelectionClear -- the owning client is gone, nobody to deliver to.
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

/// Read one pixel (as a little-endian u32) from a drawable via getImage, for
/// tests that used to poke the raw pixel buffer directly.
fn readbackPixel(d: *Display, id: u32, x: u16, y: u16) u32 {
    const res = d.getImage(id, 2, @intCast(x), @intCast(y), 1, 1, 0xffffffff) catch unreachable;
    defer d.gpa.free(res.data);
    var v: u32 = 0;
    var i: usize = 0;
    while (i < res.data.len and i < 4) : (i += 1) v |= @as(u32, res.data[i]) << @intCast(i * 8);
    return v;
}

test "pixmaps: create allocates a zeroed buffer, geometry, free, id namespace, cleanup" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, 1);
    // Create a 4x3 depth-24 pixmap: 4*3*4 = 48 zeroed bytes.
    try d.createPixmap(0x100, 0x12a, 24, 4, 3, 7);
    // Readback the whole 4x3 depth-24 pixmap: 48 zeroed bytes.
    const pg = try d.getImage(0x100, 2, 0, 0, 4, 3, 0xffffffff);
    defer gpa.free(pg.data);
    try std.testing.expectEqual(@as(usize, 48), pg.data.len);
    try std.testing.expectEqual(@as(u8, 0), pg.data[0]);
    try std.testing.expectEqual(@as(u8, 0), pg.data[47]);
    // drawable() returns the pixmap geometry (x/y/border 0).
    const info = d.drawable(0x100).?;
    try std.testing.expectEqual(@as(u16, 4), info.width);
    try std.testing.expectEqual(@as(u16, 3), info.height);
    try std.testing.expectEqual(@as(u8, 24), info.depth);
    try std.testing.expectEqual(@as(i16, 0), info.x);
    // drawable() also works for a window.
    try std.testing.expectEqual(@as(u16, 10), d.drawable(0xA).?.width);
    // Unified id namespace: a window's id is In use.
    try std.testing.expectError(error.IdInUse, d.createPixmap(0xA, 0x12a, 24, 2, 2, 7));
    try std.testing.expectError(error.IdInUse, d.createWindow(0x100, 0x12a, .{ .width = 1, .height = 1 }, 1, 0x21, .{}, 1)); // pixmap id
    // Validation.
    try std.testing.expectError(error.NoDrawable, d.createPixmap(0x101, 0xDEAD, 24, 2, 2, 7));
    try std.testing.expectError(error.BadValue, d.createPixmap(0x101, 0x12a, 24, 0, 2, 7)); // width 0
    try std.testing.expectError(error.BadValue, d.createPixmap(0x101, 0x12a, 3, 2, 2, 7)); // bad depth
    d.max_pixmap_bytes = 16;
    try std.testing.expectError(error.TooLarge, d.createPixmap(0x101, 0x12a, 24, 4, 3, 7)); // 48 > 16
    d.max_pixmap_bytes = 64 * 1024 * 1024;
    // Free: gone; freeing a window id -> NotPixmap.
    try d.freePixmap(0x100);
    try std.testing.expectEqual(@as(?DrawableInfo, null), d.drawable(0x100));
    try std.testing.expectError(error.NotPixmap, d.freePixmap(0xA));
    // cleanupClient frees the client's pixmaps (client 7 owns this one).
    try d.createPixmap(0x102, 0x12a, 24, 2, 2, 7);
    try d.cleanupClient(7);
    try std.testing.expectEqual(@as(?DrawableInfo, null), d.drawable(0x102));
}

test "graphics contexts: create/change/free/copy, id namespace, cleanup" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // create a GC on the root with foreground 0xAB.
    try d.createGC(0x200, 0x12a, .{ .foreground = 0xAB }, 5);
    try std.testing.expectEqual(@as(u32, 0xAB), d.gcs.get(0x200).?.values.foreground);
    try std.testing.expectEqual(@as(u32, 3), d.gcs.get(0x200).?.values.function); // GXcopy default
    // id namespace spans gcs.
    try std.testing.expectError(error.IdInUse, d.createGC(0x200, 0x12a, .{}, 5));
    try std.testing.expectError(error.IdInUse, d.createWindow(0x200, 0x12a, .{ .width = 1, .height = 1 }, 1, 0x21, .{}, 1));
    try std.testing.expectError(error.NoDrawable, d.createGC(0x201, 0xDEAD, .{}, 5));
    // changeGC applies; non-GC -> NotGC.
    try d.changeGC(0x200, .{ .foreground = 0xCD, .line_width = 2 });
    try std.testing.expectEqual(@as(u32, 0xCD), d.gcs.get(0x200).?.values.foreground);
    try std.testing.expectEqual(@as(u32, 2), d.gcs.get(0x200).?.values.line_width);
    try std.testing.expectError(error.NotGC, d.changeGC(0x12a, .{})); // a window
    // copyGC copies only masked components (bit 2 = foreground).
    try d.createGC(0x201, 0x12a, .{ .foreground = 0x11, .background = 0x22 }, 5);
    try d.copyGC(0x200, 0x201, 1 << 2); // copy foreground (0xCD) only
    try std.testing.expectEqual(@as(u32, 0xCD), d.gcs.get(0x201).?.values.foreground); // copied
    try std.testing.expectEqual(@as(u32, 0x22), d.gcs.get(0x201).?.values.background); // untouched
    // freeGC removes; non-GC -> NotGC.
    try d.freeGC(0x200);
    try std.testing.expect(!d.gcs.contains(0x200));
    try std.testing.expectError(error.NotGC, d.freeGC(0x200));
    // cleanupClient frees the client's GCs.
    try d.cleanupClient(5);
    try std.testing.expect(!d.gcs.contains(0x201));
}

test "fonts: open/close, id namespace, query validation, cleanup" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Open a font under a fresh id.
    try d.openFont(0x300, "fixed", 9);
    try std.testing.expect(d.idInUse(0x300));
    // A font id collides with an existing window id (the root) -> IdInUse.
    try std.testing.expectError(error.IdInUse, d.openFont(0x12a, "fixed", 9));
    // closeFont a non-font (a window id) -> NotFont.
    try std.testing.expectError(error.NotFont, d.closeFont(0x12a));
    // queryFont: a real font id returns the fixed 8x8 metrics; an unknown id -> NotFont.
    const m = try d.queryFont(0x300);
    try std.testing.expectEqual(@as(i16, 8), m.max_width);
    try std.testing.expectEqual(@as(i16, 8), m.ascent);
    try std.testing.expectError(error.NotFont, d.queryFont(0xDEAD));
    // closeFont removes; a second close on the same id -> NotFont.
    try d.closeFont(0x300);
    try std.testing.expect(!d.fonts.contains(0x300));
    try std.testing.expectError(error.NotFont, d.closeFont(0x300));
    // cleanupClient frees the disconnecting client's fonts, spares another's.
    try d.openFont(0x301, "fixed", 9);
    try d.openFont(0x302, "fixed", 10);
    try d.cleanupClient(9);
    try std.testing.expect(!d.fonts.contains(0x301));
    try std.testing.expect(d.fonts.contains(0x302));
}

test "imageText8: opaque box (fg glyph pixel, bg cell pixel, prior content outside)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 12, .height = 12, .depth = 24 }, 1, 0x21, .{}, 1);
    // Paint the whole window a distinct "prior content" color first.
    try d.createGC(0x200, 0xA, .{ .foreground = 0x00445566 }, 1);
    try d.fillRect(0xA, 0x200, 0, 0, 12, 12);
    // Now point the same GC at the real fg/bg and draw "H" at baseline y=10
    // (ascent=8 -> glyph top=2). font8x8 'H' row0 = 0x33 = 0b00110011: col0/1
    // set, col2/3 clear, col4/5 set, col6/7 clear.
    try d.changeGC(0x200, .{ .foreground = 0x00AABBCC, .background = 0x00112233 });
    try d.imageText8(0xA, 0x200, 2, 10, "H");

    // glyph SET pixel (row0,col0 -> x=2,y=2) == foreground.
    {
        const g = try d.getImage(0xA, 2, 2, 2, 1, 1, 0xffffffff);
        defer gpa.free(g.data);
        try std.testing.expectEqual(@as(u32, 0x00AABBCC), std.mem.readInt(u32, g.data[0..4], .little));
    }
    // cell pixel with glyph bit CLEAR (row0,col2 -> x=4,y=2) == background (opaque box).
    {
        const g = try d.getImage(0xA, 2, 4, 2, 1, 1, 0xffffffff);
        defer gpa.free(g.data);
        try std.testing.expectEqual(@as(u32, 0x00112233), std.mem.readInt(u32, g.data[0..4], .little));
    }
    // pixel OUTSIDE the text box (0,0) == the surface's prior content.
    {
        const g = try d.getImage(0xA, 2, 0, 0, 1, 1, 0xffffffff);
        defer gpa.free(g.data);
        try std.testing.expectEqual(@as(u32, 0x00445566), std.mem.readInt(u32, g.data[0..4], .little));
    }
}

test "polyText8: transparent (no bg fill), delta advances the pen, malformed items don't panic" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xB, 0x12a, .{ .width = 30, .height = 12, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.createGC(0x201, 0xB, .{ .foreground = 0x00998877 }, 1);
    try d.fillRect(0xB, 0x201, 0, 0, 30, 12); // prior content
    try d.changeGC(0x201, .{ .foreground = 0x00AABBCC, .background = 0x00112233 });

    // Two single-char item runs: [len=1,delta=0,'H'] then [len=1,delta=4,'H'].
    // The second run lands at pen = 2 + 8(first glyph width) + 4(delta) = 14.
    const items = [_]u8{ 1, 0, 'H', 1, 4, 'H' };
    try d.polyText8(0xB, 0x201, 2, 10, &items); // baseline y=10 -> top=2

    // First glyph SET pixel (row0,col0 -> x=2) == foreground.
    {
        const g = try d.getImage(0xB, 2, 2, 2, 1, 1, 0xffffffff);
        defer gpa.free(g.data);
        try std.testing.expectEqual(@as(u32, 0x00AABBCC), std.mem.readInt(u32, g.data[0..4], .little));
    }
    // Second glyph SET pixel at x=14 == foreground (proves the delta advance).
    {
        const g = try d.getImage(0xB, 2, 14, 2, 1, 1, 0xffffffff);
        defer gpa.free(g.data);
        try std.testing.expectEqual(@as(u32, 0x00AABBCC), std.mem.readInt(u32, g.data[0..4], .little));
    }
    // A cell pixel with glyph bit CLEAR (row0,col2 -> x=4) stays the PRIOR
    // content, NOT the GC background -- proving PolyText8 paints no box.
    {
        const g = try d.getImage(0xB, 2, 4, 2, 1, 1, 0xffffffff);
        defer gpa.free(g.data);
        try std.testing.expectEqual(@as(u32, 0x00998877), std.mem.readInt(u32, g.data[0..4], .little));
    }

    // Bound-safety: malformed/truncated item streams (client-controlled wire
    // data) must not panic or read out of bounds; each of these must simply
    // return successfully having drawn whatever is safely parseable.
    try d.polyText8(0xB, 0x201, 0, 0, &[_]u8{5}); // length byte only, no delta byte -> stops cleanly
    try d.polyText8(0xB, 0x201, 0, 0, &[_]u8{ 10, 0, 'a' }); // declared len 10, only 1 string byte actually present -> clamped
    try d.polyText8(0xB, 0x201, 0, 0, &[_]u8{ 255, 0, 0 }); // font-shift marker truncated (needs 5 bytes, only 2 remain)
    try d.polyText8(0xB, 0x201, 0, 0, &[_]u8{}); // empty items stream
}

test "drawable pixel surfaces: window + pixmap buffers, sizes, oversized window" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // The root has a surface (640x480 depth 24, visual 0x21).
    const rg = try d.getImage(0x12a, 2, 0, 0, 640, 480, 0xffffffff);
    defer gpa.free(rg.data);
    try std.testing.expectEqual(@as(usize, 640 * 480 * 4), rg.data.len);
    try std.testing.expectEqual(@as(u32, 0x21), rg.visual);
    // A created window gets a zeroed surface sized w*h*4.
    try d.createWindow(0xA, 0x12a, .{ .width = 5, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    const ws = d.surfaceOf(0xA).?;
    try std.testing.expectEqual(@as(u16, 5), ws.width);
    try std.testing.expectEqual(@as(u8, 24), ws.depth);
    try std.testing.expectEqual(@as(u8, 4), ws.bpp);
    const wg = try d.getImage(0xA, 2, 0, 0, 5, 4, 0xffffffff);
    defer gpa.free(wg.data);
    try std.testing.expectEqual(@as(usize, 5 * 4 * 4), wg.data.len);
    try std.testing.expectEqual(@as(u8, 0), wg.data[0]);
    try std.testing.expectEqual(@as(u32, 0x21), wg.visual);
    // A pixmap has a surface too (visual 0).
    try d.createPixmap(0x100, 0x12a, 24, 3, 2, 1);
    const psg = try d.getImage(0x100, 2, 0, 0, 3, 2, 0xffffffff);
    defer gpa.free(psg.data);
    try std.testing.expectEqual(@as(usize, 3 * 2 * 4), psg.data.len);
    try std.testing.expectEqual(@as(u32, 0), psg.visual);
    // A non-drawable id -> null surface / NoDrawable.
    try std.testing.expectEqual(@as(?render.Surface, null), d.surfaceOf(0xDEAD));
    // An oversized window buffer -> TooManyResources (not a giant alloc).
    d.max_pixmap_bytes = 16;
    try std.testing.expectError(error.TooManyResources, d.createWindow(0xB, 0x12a, .{ .width = 5, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1)); // 80 > 16
    // The window still destroys cleanly (its surface is freed).
    d.max_pixmap_bytes = 64 * 1024 * 1024;
    try d.destroyWindow(0xA);
    try std.testing.expectEqual(@as(?render.Surface, null), d.surfaceOf(0xA));
}

test "draw ops: fillRect + clip, putImage, getImage + plane_mask, errors" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 4, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00112233 }, 1);

    // Fill the whole 4x4 window; every pixel is 0x00112233 (LE bytes 33 22 11 00).
    try d.fillRect(0xA, 0x200, 0, 0, 4, 4);
    const g = try d.getImage(0xA, 2, 0, 0, 4, 4, 0xffffffff);
    defer gpa.free(g.data);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), g.data.len);
    try std.testing.expectEqual(@as(u8, 0x33), g.data[0]);
    try std.testing.expectEqual(@as(u8, 0x22), g.data[1]);
    try std.testing.expectEqual(@as(u8, 0x11), g.data[2]);
    try std.testing.expectEqual(@as(u8, 0x00), g.data[3]);
    try std.testing.expectEqual(@as(u8, 24), g.depth);
    try std.testing.expectEqual(@as(u32, 0x21), g.visual);

    // Clip: a rect straddling the top-left corner only fills the in-bounds part.
    try d.createWindow(0xB, 0x12a, .{ .width = 4, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.changeGC(0x200, .{ .foreground = 0x000000ff });
    try d.fillRect(0xB, 0x200, -1, -1, 2, 2); // clipped region is just pixel (0,0)
    const gb = try d.getImage(0xB, 2, 0, 0, 4, 4, 0xffffffff);
    defer gpa.free(gb.data);
    try std.testing.expectEqual(@as(u8, 0xff), gb.data[0]); // (0,0) filled
    try std.testing.expectEqual(@as(u8, 0x00), gb.data[4]); // (1,0) untouched

    // PutImage a 2x2 block of 0x00445566 at (1,1); GetImage reads it back.
    const block = [_]u8{ 0x66, 0x55, 0x44, 0x00 } ** 4; // 2x2 pixels
    try d.putImage(0xA, 0x200, 2, 24, 2, 2, 1, 1, 0, &block);
    const gp = try d.getImage(0xA, 2, 1, 1, 2, 2, 0xffffffff);
    defer gpa.free(gp.data);
    try std.testing.expectEqual(@as(u8, 0x66), gp.data[0]);
    try std.testing.expectEqual(@as(u8, 0x44), gp.data[2]);

    // plane_mask ANDs the returned pixels.
    const gm = try d.getImage(0xA, 2, 0, 0, 1, 1, 0x0000ff00);
    defer gpa.free(gm.data);
    try std.testing.expectEqual(@as(u8, 0x00), gm.data[0]); // 0x112233 & 0x00ff00 -> 0x002200; byte0=0x00
    try std.testing.expectEqual(@as(u8, 0x22), gm.data[1]);

    // Errors.
    try std.testing.expectError(error.NoDrawable, d.fillRect(0xDEAD, 0x200, 0, 0, 1, 1));
    try std.testing.expectError(error.NotGC, d.fillRect(0xA, 0x12a, 0, 0, 1, 1)); // gc = a window
    try std.testing.expectError(error.BadMatch, d.getImage(0xA, 0, 0, 0, 1, 1, 0)); // format != ZPixmap
    try std.testing.expectError(error.BadMatch, d.getImage(0xA, 2, 0, 0, 5, 5, 0)); // rect not contained
    try std.testing.expectError(error.BadMatch, d.putImage(0xA, 0x200, 2, 8, 1, 1, 0, 0, 0, &[_]u8{0})); // depth mismatch
    try std.testing.expectError(error.BadMatch, d.putImage(0xA, 0x200, 2, 24, 1, 1, 0, 0, 0, &[_]u8{ 0, 0 })); // wrong data len
}

test "clearArea: fills background_pixel and records Expose over the cleared rect" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 20, .height = 10, .depth = 24 }, 1, 0x21, .{ .background_pixel = 0x00223344, .event_mask = exposure }, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00ff0000 }, 1);
    // Paint a non-background pixel inside the region we are about to clear.
    try d.fillRect(0xA, 0x200, 3, 3, 1, 1);
    d.clearPending();

    try d.clearArea(0xA, 2, 2, 5, 4, true);

    try std.testing.expectEqual(@as(u32, 0x00223344), readbackPixel(&d, 0xA, 3, 3)); // repainted to bg
    try std.testing.expectEqual(@as(u32, 0x00223344), readbackPixel(&d, 0xA, 2, 2));
    try std.testing.expectEqual(@as(u32, 0x00223344), readbackPixel(&d, 0xA, 6, 5)); // (2+5-1, 2+4-1)
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0xA, 0, 0)); // outside the cleared rect, untouched

    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.expose, ev.kind);
    try std.testing.expectEqual(@as(u32, 0xA), ev.window);
    try std.testing.expectEqual(@as(i16, 2), ev.x);
    try std.testing.expectEqual(@as(i16, 2), ev.y);
    try std.testing.expectEqual(@as(u16, 5), ev.width);
    try std.testing.expectEqual(@as(u16, 4), ev.height);
    try std.testing.expectEqual(@as(u16, 0), ev.count);
}

test "clearArea: exposures=false records no event" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{ .background_pixel = 0x00223344, .event_mask = exposure }, 1);
    d.clearPending();
    try d.clearArea(0xA, 0, 0, 5, 5, false);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    try std.testing.expectEqual(@as(u32, 0x00223344), readbackPixel(&d, 0xA, 0, 0));
}

test "clearArea: width/height 0 extends to the window edge" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 6, .height = 4, .depth = 24 }, 1, 0x21, .{ .background_pixel = 0x00010203 }, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00ffffff }, 1);
    try d.fillRect(0xA, 0x200, 0, 0, 6, 4); // paint the whole window non-bg first
    try d.clearArea(0xA, 0, 0, 0, 0, false);
    try std.testing.expectEqual(@as(u32, 0x00010203), readbackPixel(&d, 0xA, 5, 3)); // bottom-right corner cleared too
}

test "clearArea: InputOnly window has no pixels -> BadMatch; unknown id -> NoWindow" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 2, 0x21, .{}, 1); // class 2 = InputOnly
    try std.testing.expectError(error.BadMatch, d.clearArea(0xA, 0, 0, 1, 1, false));
    try std.testing.expectError(error.NoWindow, d.clearArea(0xDEAD, 0, 0, 1, 1, false));
}

test "copyArea: full in-bounds copy, partial exposure, depth mismatch, self-overlap snapshot" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 8, 8, 1); // src
    try d.createPixmap(0x101, 0x12a, 24, 8, 8, 1); // dst
    try d.createGC(0x200, 0x12a, .{}, 1); // graphics_exposures default true

    // Known pattern: pixel(x,y) == y*8+x, so every pixel is distinguishable.
    var pattern: [8 * 8 * 4]u8 = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            const val: u32 = @intCast(y * 8 + x);
            const off = (y * 8 + x) * 4;
            pattern[off + 0] = @truncate(val);
            pattern[off + 1] = @truncate(val >> 8);
            pattern[off + 2] = @truncate(val >> 16);
            pattern[off + 3] = @truncate(val >> 24);
        }
    }
    try d.putImage(0x100, 0x200, 2, 24, 8, 8, 0, 0, 0, &pattern);

    // Full in-bounds copy -> fully_covered + pixels land.
    d.clearPending();
    const ce1 = try d.copyArea(0x100, 0x101, 0x200, 0, 0, 0, 0, 8, 8);
    try std.testing.expect(ce1.fully_covered);
    try std.testing.expect(ce1.graphics_exposures);
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x101, 0, 0));
    try std.testing.expectEqual(@as(u32, 7 * 8 + 3), readbackPixel(&d, 0x101, 3, 7));

    // Partial copy: source runs off the right edge -> not fully covered, exposed
    // rect == the whole dst-clipped rect (over-reported, not the exact slice).
    try d.createPixmap(0x102, 0x12a, 24, 8, 8, 1); // dst2, zeroed
    const ce2 = try d.copyArea(0x100, 0x102, 0x200, 4, 0, 0, 0, 8, 8);
    try std.testing.expect(!ce2.fully_covered);
    try std.testing.expectEqual(@as(i16, 0), ce2.x);
    try std.testing.expectEqual(@as(i16, 0), ce2.y);
    try std.testing.expectEqual(@as(u16, 8), ce2.width);
    try std.testing.expectEqual(@as(u16, 8), ce2.height);
    try std.testing.expectEqual(@as(u32, 0 * 8 + 4), readbackPixel(&d, 0x102, 0, 0)); // in-bounds: src(4,0)
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x102, 4, 0)); // out-of-bounds: untouched (still zero)

    // Depth mismatch -> BadMatch.
    try d.createPixmap(0x103, 0x12a, 1, 8, 8, 1); // depth 1
    try std.testing.expectError(error.BadMatch, d.copyArea(0x100, 0x103, 0x200, 0, 0, 0, 0, 8, 8));

    // NoDrawable / NotGC.
    try std.testing.expectError(error.NoDrawable, d.copyArea(0xDEAD, 0x101, 0x200, 0, 0, 0, 0, 1, 1));
    try std.testing.expectError(error.NotGC, d.copyArea(0x100, 0x101, 0x12a, 0, 0, 0, 0, 1, 1)); // gc = a window

    // Self-overlap: copy within the SAME pixmap, shifted by (+2,+2), overlapping.
    // A naive forward in-place copy would read pixels already overwritten by an
    // earlier iteration; the temp-buffer snapshot must reproduce the ORIGINAL
    // pattern exactly regardless of iteration order.
    const ce3 = try d.copyArea(0x100, 0x100, 0x200, 0, 0, 2, 2, 6, 6);
    try std.testing.expect(ce3.fully_covered);
    for (0..6) |j| {
        for (0..6) |i| {
            const expect: u32 = @intCast(j * 8 + i); // original pattern value at (i,j)
            try std.testing.expectEqual(expect, readbackPixel(&d, 0x100, @intCast(2 + i), @intCast(2 + j)));
        }
    }
}

test "polyRectangle: outline sets the edges but not the interior center" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 10, 10, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00ff0000 }, 1);

    const rects = [_]render.Rect{.{ .x = 1, .y = 1, .width = 6, .height = 4 }};
    try d.polyRectangle(0x100, 0x200, &rects);

    // Corners + edge midpoints set.
    try std.testing.expectEqual(@as(u32, 0x00ff0000), readbackPixel(&d, 0x100, 1, 1)); // TL
    try std.testing.expectEqual(@as(u32, 0x00ff0000), readbackPixel(&d, 0x100, 7, 1)); // TR
    try std.testing.expectEqual(@as(u32, 0x00ff0000), readbackPixel(&d, 0x100, 7, 5)); // BR
    try std.testing.expectEqual(@as(u32, 0x00ff0000), readbackPixel(&d, 0x100, 1, 5)); // BL
    try std.testing.expectEqual(@as(u32, 0x00ff0000), readbackPixel(&d, 0x100, 4, 1)); // top edge midpoint
    // Interior center stays untouched (outline only, not filled).
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x100, 4, 3));
}

test "fillPoly: 4-point square fills the interior; an outside pixel stays clear" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 10, 10, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x0000ff00 }, 1);

    const square = [_]render.Point{
        .{ .x = 2, .y = 2 },
        .{ .x = 7, .y = 2 },
        .{ .x = 7, .y = 7 },
        .{ .x = 2, .y = 7 },
    };
    try d.fillPoly(0x100, 0x200, 0, &square); // coord_mode Origin

    try std.testing.expectEqual(@as(u32, 0x0000ff00), readbackPixel(&d, 0x100, 4, 4)); // interior
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x100, 9, 9)); // outside
}

test "polySegment: two disjoint segments each set their endpoints; the gap stays clear" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 10, 10, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x000000ff }, 1);

    // Segment A: (0,0)-(1,0). Segment B: (8,8)-(9,8). A gap between them at (5,5).
    const flat = [_]render.Point{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 },
        .{ .x = 8, .y = 8 }, .{ .x = 9, .y = 8 },
    };
    try d.polySegment(0x100, 0x200, &flat);

    try std.testing.expectEqual(@as(u32, 0x000000ff), readbackPixel(&d, 0x100, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x000000ff), readbackPixel(&d, 0x100, 1, 0));
    try std.testing.expectEqual(@as(u32, 0x000000ff), readbackPixel(&d, 0x100, 8, 8));
    try std.testing.expectEqual(@as(u32, 0x000000ff), readbackPixel(&d, 0x100, 9, 8));
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x100, 5, 5)); // the gap
}

test "polyLine: coord_mode Previous resolves relative points to the right absolute pixel" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 10, 10, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00abcdef }, 1);

    // First point (1,1) absolute; second point (2,3) relative -> lands at (3,4).
    const rel = [_]render.Point{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 3 } };
    try d.polyLine(0x100, 0x200, 1, &rel); // coord_mode Previous

    try std.testing.expectEqual(@as(u32, 0x00abcdef), readbackPixel(&d, 0x100, 1, 1)); // absolute first point
    try std.testing.expectEqual(@as(u32, 0x00abcdef), readbackPixel(&d, 0x100, 3, 4)); // resolved absolute second point
}

test "polyPoint: sets exactly the listed pixels" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 10, 10, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00112233 }, 1);

    const pts = [_]render.Point{ .{ .x = 2, .y = 3 }, .{ .x = 7, .y = 6 } };
    try d.polyPoint(0x100, 0x200, 0, &pts); // coord_mode Origin

    try std.testing.expectEqual(@as(u32, 0x00112233), readbackPixel(&d, 0x100, 2, 3));
    try std.testing.expectEqual(@as(u32, 0x00112233), readbackPixel(&d, 0x100, 7, 6));
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x100, 0, 0));
}

test "vector primitive ops: bad drawable -> NoDrawable, bad gc -> NotGC" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 10, 10, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00112233 }, 1);

    const pts = [_]render.Point{.{ .x = 1, .y = 1 }};
    const rects = [_]render.Rect{.{ .x = 1, .y = 1, .width = 2, .height = 2 }};
    const flat = [_]render.Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } };

    try std.testing.expectError(error.NoDrawable, d.polyPoint(0xDEAD, 0x200, 0, &pts));
    try std.testing.expectError(error.NotGC, d.polyPoint(0x100, 0x12a, 0, &pts)); // gc = a drawable

    try std.testing.expectError(error.NoDrawable, d.polyLine(0xDEAD, 0x200, 0, &pts));
    try std.testing.expectError(error.NotGC, d.polyLine(0x100, 0x12a, 0, &pts));

    try std.testing.expectError(error.NoDrawable, d.polySegment(0xDEAD, 0x200, &flat));
    try std.testing.expectError(error.NotGC, d.polySegment(0x100, 0x12a, &flat));

    try std.testing.expectError(error.NoDrawable, d.polyRectangle(0xDEAD, 0x200, &rects));
    try std.testing.expectError(error.NotGC, d.polyRectangle(0x100, 0x12a, &rects));

    try std.testing.expectError(error.NoDrawable, d.fillPoly(0xDEAD, 0x200, 0, &pts));
    try std.testing.expectError(error.NotGC, d.fillPoly(0x100, 0x12a, 0, &pts));

    const arcs = [_]render.Arc{.{ .x = 1, .y = 1, .width = 4, .height = 4, .angle1 = 0, .angle2 = 360 * 64 }};
    try std.testing.expectError(error.NoDrawable, d.polyArc(0xDEAD, 0x200, &arcs));
    try std.testing.expectError(error.NotGC, d.polyArc(0x100, 0x12a, &arcs));
    try std.testing.expectError(error.NoDrawable, d.polyFillArc(0xDEAD, 0x200, &arcs));
    try std.testing.expectError(error.NotGC, d.polyFillArc(0x100, 0x12a, &arcs));
}

test "polyFillArc: PieSlice full circle fills the center; polyArc outline leaves it hollow" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 20, 20, 1);
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00445566 }, 1); // arc_mode defaults to PieSlice

    const circle = [_]render.Arc{.{ .x = 0, .y = 0, .width = 20, .height = 20, .angle1 = 0, .angle2 = 360 * 64 }};

    // Outline first: the center stays clear (hollow).
    try d.polyArc(0x100, 0x200, &circle);
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x100, 10, 10));

    // A fresh pixmap for the filled case, so the outline draw above doesn't
    // taint the fill assertion below.
    try d.createPixmap(0x101, 0x12a, 24, 20, 20, 1);
    try d.polyFillArc(0x101, 0x200, &circle);
    try std.testing.expectEqual(@as(u32, 0x00445566), readbackPixel(&d, 0x101, 10, 10));
}

test "polyFillArc: GC arc_mode PieSlice vs Chord differ on a quarter arc's center" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createPixmap(0x100, 0x12a, 24, 20, 20, 1);
    try d.createPixmap(0x101, 0x12a, 24, 20, 20, 1);
    // Same arc geometry, one GC per arc_mode.
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00aabbcc, .arc_mode = 1 }, 1); // PieSlice (default, explicit here)
    try d.createGC(0x201, 0x12a, .{ .foreground = 0x00aabbcc, .arc_mode = 0 }, 1); // Chord

    // Quarter circle: 3-o'clock to 12-o'clock. The PieSlice wedge is the
    // triangle (center, rightmost endpoint, topmost endpoint) unioned with
    // the circular segment; the Chord fill is just the segment (between the
    // arc and the straight line joining its endpoints). (13,8) sits close to
    // center (radius ~0.36 of the semi-axes, well inside the sector angle),
    // so it's inside the wedge's triangle but nowhere near the segment.
    const quarter = [_]render.Arc{.{ .x = 0, .y = 0, .width = 20, .height = 20, .angle1 = 0, .angle2 = 90 * 64 }};

    try d.polyFillArc(0x100, 0x200, &quarter); // PieSlice
    try d.polyFillArc(0x101, 0x201, &quarter); // Chord

    try std.testing.expectEqual(@as(u32, 0x00aabbcc), readbackPixel(&d, 0x100, 13, 8)); // PieSlice: inside the wedge triangle
    try std.testing.expectEqual(@as(u32, 0), readbackPixel(&d, 0x101, 13, 8)); // Chord: outside the segment
}

test "recordNoExpose/recordGraphicsExpose target the requesting client only" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.recordNoExpose(0x100, 1, 62);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    var ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.no_expose, ev.kind);
    try std.testing.expectEqual(@as(u32, 0x100), ev.window);
    try std.testing.expectEqual(@as(u32, 1), ev.target_client);
    try std.testing.expectEqual(@as(u8, 62), ev.major_opcode);

    d.clearPending();
    try d.recordGraphicsExpose(0x100, 1, 62, 4, 5, 6, 7);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.graphics_expose, ev.kind);
    try std.testing.expectEqual(@as(u32, 0x100), ev.window);
    try std.testing.expectEqual(@as(u32, 1), ev.target_client);
    try std.testing.expectEqual(@as(u8, 62), ev.major_opcode);
    try std.testing.expectEqual(@as(i16, 4), ev.x);
    try std.testing.expectEqual(@as(i16, 5), ev.y);
    try std.testing.expectEqual(@as(u16, 6), ev.width);
    try std.testing.expectEqual(@as(u16, 7), ev.height);
    try std.testing.expectEqual(@as(u16, 0), ev.count);
}

test "configureWindow: move/resize/border, buffer realloc, cap, root no-op" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 4, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    // Move + resize + border.
    try d.configureWindow(0xA, .{ .x = 5, .y = 6, .width = 20, .height = 10, .border_width = 2 }, 1);
    const g = try d.getGeometry(0xA);
    try std.testing.expectEqual(@as(i16, 5), g.x);
    try std.testing.expectEqual(@as(u16, 20), g.width);
    try std.testing.expectEqual(@as(u16, 10), g.height);
    try std.testing.expectEqual(@as(u16, 2), g.border_width);
    // The backing surface was resized to the new dims (20*10*4 bytes).
    const cg = try d.getImage(0xA, 2, 0, 0, 20, 10, 0xffffffff);
    defer gpa.free(cg.data);
    try std.testing.expectEqual(@as(usize, 20 * 10 * 4), cg.data.len);
    // width 0 -> BadValue; oversized -> TooLarge; root -> no-op.
    try std.testing.expectError(error.BadValue, d.configureWindow(0xA, .{ .width = 0 }, 1));
    d.max_pixmap_bytes = 16;
    try std.testing.expectError(error.TooLarge, d.configureWindow(0xA, .{ .width = 30, .height = 30 }, 1));
    d.max_pixmap_bytes = 64 * 1024 * 1024;
    try d.configureWindow(0x12a, .{ .x = 1 }, 1); // root: no-op, no error
    try std.testing.expectError(error.NoWindow, d.configureWindow(0xDEAD, .{ .x = 1 }, 1));
}

test "configureWindow: stacking + ConfigureNotify + above_sibling" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Three siblings under root, created bottom-to-top: A, B, C.
    try d.createWindow(0xA, 0x12a, .{ .width = 4, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xB, 0x12a, .{ .width = 4, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xC, 0x12a, .{ .width = 4, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    // A selects StructureNotify (to receive its own ConfigureNotify).
    try d.changeAttributes(0xA, .{ .event_mask = structure_notify }, 2);
    d.clearPending();

    // Raise A to the top (Above, no sibling). Order becomes B, C, A.
    try d.configureWindow(0xA, .{ .stack_mode = 0 }, 1);
    const t = try d.queryTree(0x12a);
    try std.testing.expectEqual(@as(u32, 0xA), t.children[t.children.len - 1]); // A topmost
    // ConfigureNotify to client 2 (StructureNotify on A) with above_sibling = C (below A).
    var to2 = false;
    for (d.pending.items) |ev| {
        if (ev.kind == .configure and ev.window == 0xA and ev.target_client == 2) {
            to2 = true;
            try std.testing.expectEqual(@as(u32, 0xC), ev.above_sibling);
        }
    }
    try std.testing.expect(to2);

    // Lower A to the bottom (Below, no sibling). Order: A, B, C.
    try d.configureWindow(0xA, .{ .stack_mode = 1 }, 1);
    const t2 = try d.queryTree(0x12a);
    try std.testing.expectEqual(@as(u32, 0xA), t2.children[0]); // A bottommost

    // Above sibling B: A goes just above B. Order: B, A, C.
    try d.configureWindow(0xA, .{ .sibling = 0xB, .stack_mode = 0 }, 1);
    const t3 = try d.queryTree(0x12a);
    try std.testing.expectEqual(@as(u32, 0xB), t3.children[0]);
    try std.testing.expectEqual(@as(u32, 0xA), t3.children[1]);

    // Errors: sibling without stack_mode -> BadMatch; non-sibling sibling -> BadMatch; bad stack_mode -> BadValue.
    try std.testing.expectError(error.BadMatch, d.configureWindow(0xA, .{ .sibling = 0xB }, 1));
    try std.testing.expectError(error.BadValue, d.configureWindow(0xA, .{ .stack_mode = 9 }, 1));
    try d.createWindow(0xD, 0xB, .{ .width = 2, .height = 2, .depth = 24 }, 1, 0x21, .{}, 1); // child of B, not root
    try std.testing.expectError(error.BadMatch, d.configureWindow(0xA, .{ .sibling = 0xD, .stack_mode = 0 }, 1));
}

test "configureWindow: a dimension change on a viewable InputOutput window repaints + exposes" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{ .background_pixel = 0x00445566, .event_mask = structure_notify | exposure }, 1);
    try d.mapWindow(0xA, 1);
    d.clearPending();
    try d.configureWindow(0xA, .{ .width = 40, .height = 30 }, 1);
    // Both a ConfigureNotify and a full-window Expose are recorded (in that order).
    try std.testing.expectEqual(@as(usize, 2), d.pending.items.len);
    try std.testing.expectEqual(EventKind.configure, d.pending.items[0].kind);
    const ev = d.pending.items[1];
    try std.testing.expectEqual(EventKind.expose, ev.kind);
    try std.testing.expectEqual(@as(u32, 0xA), ev.window);
    try std.testing.expectEqual(@as(u16, 40), ev.width);
    try std.testing.expectEqual(@as(u16, 30), ev.height);
    try std.testing.expectEqual(@as(u16, 0), ev.count);
    // The resized surface was repainted to background_pixel (not left zeroed).
    try std.testing.expectEqual(@as(u32, 0x00445566), readbackPixel(&d, 0xA, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x00445566), readbackPixel(&d, 0xA, 39, 29));
}

test "configureWindow: a move-only configure preserves content and exposes nothing" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{ .background_pixel = 0x00445566, .event_mask = exposure }, 1);
    try d.mapWindow(0xA, 1);
    d.clearPending();
    try d.configureWindow(0xA, .{ .x = 5 }, 1);
    for (d.pending.items) |ev| try std.testing.expect(ev.kind != EventKind.expose);
}

test "configureWindow: resizing an unmapped window exposes nothing (not viewable)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{ .event_mask = exposure }, 1);
    d.clearPending();
    try d.configureWindow(0xA, .{ .width = 40, .height = 30 }, 1);
    for (d.pending.items) |ev| try std.testing.expect(ev.kind != EventKind.expose);
}

test "configureWindow: resizing an InputOnly window exposes nothing (no surface)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10 }, 2, 0x21, .{ .event_mask = exposure }, 1);
    try d.mapWindow(0xA, 1);
    d.clearPending();
    try d.configureWindow(0xA, .{ .width = 40, .height = 30 }, 1);
    for (d.pending.items) |ev| try std.testing.expect(ev.kind != EventKind.expose);
}

test "configureWindow: a no-op resize (same dims) exposes nothing" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{ .event_mask = exposure }, 1);
    try d.mapWindow(0xA, 1);
    d.clearPending();
    try d.configureWindow(0xA, .{ .width = 10 }, 1);
    for (d.pending.items) |ev| try std.testing.expect(ev.kind != EventKind.expose);
}

test "sendEventTargets: mask intersect, propagation, empty-mask owner" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // A under root (owner 1); B under A (owner 1).
    try d.createWindow(0xA, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.createWindow(0xB, 0xA, .{ .width = 5, .height = 5, .depth = 24 }, 1, 0x21, .{}, 1);
    // On B: client 2 selects ButtonPress(4), client 3 selects KeyPress(1).
    try d.changeAttributes(0xB, .{ .event_mask = 4 }, 2);
    try d.changeAttributes(0xB, .{ .event_mask = 1 }, 3);

    // ButtonPress query on B -> [2] (client 3's KeyPress does not match).
    const t1 = try d.sendEventTargets(0xB, false, 4);
    defer gpa.free(t1);
    try std.testing.expectEqual(@as(usize, 1), t1.len);
    try std.testing.expectEqual(@as(u32, 2), t1[0]);

    // Propagation: give A a ButtonPress selector (client 2), remove B's.
    try d.changeAttributes(0xA, .{ .event_mask = 4 }, 2);
    try d.changeAttributes(0xB, .{ .event_mask = 0 }, 2); // client 2 deselects on B
    // B now has no ButtonPress selector; propagate -> A's client 2.
    const t2 = try d.sendEventTargets(0xB, true, 4);
    defer gpa.free(t2);
    try std.testing.expectEqual(@as(usize, 1), t2.len);
    try std.testing.expectEqual(@as(u32, 2), t2[0]);
    // Without propagate -> empty.
    const t3 = try d.sendEventTargets(0xB, false, 4);
    defer gpa.free(t3);
    try std.testing.expectEqual(@as(usize, 0), t3.len);

    // Empty mask -> the destination's owner only (B owner = 1).
    const t4 = try d.sendEventTargets(0xB, false, 0);
    defer gpa.free(t4);
    try std.testing.expectEqual(@as(usize, 1), t4.len);
    try std.testing.expectEqual(@as(u32, 1), t4[0]);

    // Bad destination.
    try std.testing.expectError(error.NoWindow, d.sendEventTargets(0xDEAD, false, 4));
}

test "pointerPath: hit inside a child, miss outside, windowAt convenience" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0xA, 0x12a, .{ .x = 10, .y = 10, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0xA, 1);
    var path: std.ArrayListUnmanaged(PathNode) = .empty;
    defer path.deinit(gpa);
    // Point inside A -> [root, A]; A's drawable origin is (10,10).
    try d.pointerPath(50, 50, &path);
    try std.testing.expectEqual(@as(usize, 2), path.items.len);
    try std.testing.expectEqual(@as(u32, 0xA), path.items[1].wid);
    try std.testing.expectEqual(@as(i32, 10), path.items[1].abs_x);
    try std.testing.expectEqual(@as(i32, 10), path.items[1].abs_y);
    // Point outside A -> [root].
    try d.pointerPath(5, 5, &path);
    try std.testing.expectEqual(@as(usize, 1), path.items.len);
    try std.testing.expectEqual(@as(u32, 0x12a), path.items[0].wid);
    try std.testing.expectEqual(@as(u32, 0xA), try d.windowAt(50, 50));
    try std.testing.expectEqual(@as(u32, 0x12a), try d.windowAt(5, 5));
    // absOrigin of A is its drawable origin.
    const o = d.absOrigin(0xA);
    try std.testing.expectEqual(@as(i32, 10), o.x);
    try std.testing.expectEqual(@as(i32, 10), o.y);
}

test "pointerPath: topmost sibling wins, unmapped skipped, InputOnly hit, nested descent" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Two overlapping siblings; C is created after B so it stacks above.
    try d.createWindow(0xB, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0xB, 1);
    try d.createWindow(0xC, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0xC, 1);
    try std.testing.expectEqual(@as(u32, 0xC), try d.windowAt(50, 50));
    // An unmapped window on top is skipped.
    try d.createWindow(0xD, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try std.testing.expectEqual(@as(u32, 0xC), try d.windowAt(50, 50));
    // An InputOnly window (class 2) on top still receives the hit.
    try d.createWindow(0xE, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 2, 0x21, .{}, 1);
    try d.mapWindow(0xE, 1);
    try std.testing.expectEqual(@as(u32, 0xE), try d.windowAt(50, 50));
    // Nested: grandchild G at (10,10) inside F at (200,200).
    try d.createWindow(0xF, 0x12a, .{ .x = 200, .y = 200, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0xF, 1);
    try d.createWindow(0x60, 0xF, .{ .x = 10, .y = 10, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x60, 1);
    // (215,215) -> F-local (15,15) -> inside G (10..30). windowAt -> G.
    try std.testing.expectEqual(@as(u32, 0x60), try d.windowAt(215, 215));
}

test "injectButton: propagates to first selecting ancestor with relative coords + child" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Parent P at (100,100) 200x200 selects ButtonPress (client 2); child K at
    // (10,20) 50x50 inside P selects nothing.
    try d.createWindow(0x50, 0x12a, .{ .x = 100, .y = 100, .width = 200, .height = 200, .depth = 24 }, 1, 0x21, .{ .event_mask = button_press | button_release }, 2);
    try d.mapWindow(0x50, 1);
    try d.createWindow(0x1, 0x50, .{ .x = 10, .y = 20, .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x1, 1);
    d.clearPending();
    // Pointer at root (130,140): inside P (100..300) and inside K (P-local 30,40
    // -> K spans 10..60,20..70 -> hit). Target = K, which selects nothing, so the
    // press propagates up to P.
    d.pointer_x = 130;
    d.pointer_y = 140;
    try d.injectButton(1, true, 7);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const e = d.pending.items[0];
    try std.testing.expectEqual(EventKind.button_press, e.kind);
    try std.testing.expectEqual(@as(u32, 0x50), e.event_window); // delivered on P
    try std.testing.expectEqual(@as(u32, 0x1), e.child); // path node below P
    try std.testing.expectEqual(@as(u32, 2), e.target_client);
    try std.testing.expectEqual(@as(u8, 1), e.detail);
    try std.testing.expectEqual(@as(i16, 130), e.root_x);
    // event coords relative to P (drawable origin 100,100): (30,40).
    try std.testing.expectEqual(@as(i16, 30), e.event_x);
    try std.testing.expectEqual(@as(i16, 40), e.event_y);
    // state reflects buttons BEFORE the press -> 0; after, button 1 is down.
    try std.testing.expectEqual(@as(u16, 0), e.input_state);
    try std.testing.expectEqual(@as(u16, 0x100), d.input_state);
    // Release: state still shows button 1 down, then clears.
    d.clearPending();
    try d.injectButton(1, false, 8);
    try std.testing.expectEqual(EventKind.button_release, d.pending.items[0].kind);
    try std.testing.expectEqual(@as(u16, 0x100), d.pending.items[0].input_state);
    try std.testing.expectEqual(@as(u16, 0), d.input_state);
}

test "injectButton: dropped when nothing in the path selects" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x2, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x2, 1);
    d.clearPending();
    d.pointer_x = 50;
    d.pointer_y = 50;
    try d.injectButton(1, true, 1);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "injectMotion: motion delivered to the window under the pointer" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x3, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{ .event_mask = pointer_motion }, 2);
    try d.mapWindow(0x3, 1);
    d.clearPending();
    try d.injectMotion(40, 60, 5);
    // A MotionNotify to window 3 (plus, from Task 3, a crossing - but this task
    // has no crossing yet, so exactly one event here).
    var saw_motion = false;
    for (d.pending.items) |e| {
        if (e.kind == .motion) {
            saw_motion = true;
            try std.testing.expectEqual(@as(u32, 0x3), e.event_window);
            try std.testing.expectEqual(@as(i16, 40), e.event_x);
            try std.testing.expectEqual(@as(i16, 60), e.event_y);
        }
    }
    try std.testing.expect(saw_motion);
    try std.testing.expectEqual(@as(i16, 40), d.pointer_x);
    try std.testing.expectEqual(@as(u32, 0x3), d.pointer_window);
}

test "injectMotion: crossing fires Leave(old) then Enter(new)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // W1 selects EnterWindow|LeaveWindow (client 2) at (0,0); W2 same at (200,0).
    const mask = enter_window | leave_window;
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{ .event_mask = mask }, 2);
    try d.mapWindow(0x10, 1);
    try d.createWindow(0x20, 0x12a, .{ .x = 200, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{ .event_mask = mask }, 2);
    try d.mapWindow(0x20, 1);
    // Move into W1 (from root): Enter(W1). pointer_window was root; root has no
    // Enter selector, so only Enter(W1) is recorded.
    d.clearPending();
    try d.injectMotion(50, 50, 1);
    try std.testing.expectEqual(@as(u32, 0x10), d.pointer_window);
    var enter_w1 = false;
    for (d.pending.items) |e| if (e.kind == .enter and e.event_window == 0x10) {
        enter_w1 = true;
    };
    try std.testing.expect(enter_w1);
    // Move from W1 into W2: Leave(W1) then Enter(W2), in that order.
    d.clearPending();
    try d.injectMotion(250, 50, 2);
    try std.testing.expectEqual(@as(u32, 0x20), d.pointer_window);
    var leave_i: ?usize = null;
    var enter_i: ?usize = null;
    for (d.pending.items, 0..) |e, idx| {
        if (e.kind == .leave and e.event_window == 0x10) leave_i = idx;
        if (e.kind == .enter and e.event_window == 0x20) enter_i = idx;
    }
    try std.testing.expect(leave_i != null and enter_i != null);
    try std.testing.expect(leave_i.? < enter_i.?); // Leave before Enter
    // Enter(W2) event coords are relative to W2 (origin 200,0): (50,50).
    for (d.pending.items) |e| if (e.kind == .enter and e.event_window == 0x20) {
        try std.testing.expectEqual(@as(i16, 50), e.event_x);
        try std.testing.expectEqual(@as(i16, 50), e.event_y);
        try std.testing.expectEqual(@as(u8, 3), e.detail); // Nonlinear
        try std.testing.expectEqual(@as(u8, 0), e.mode); // Normal
    };
}

test "setInputFocus: sets focus + records FocusOut(old)/FocusIn(new); fields reflect" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{ .event_mask = focus_change }, 2);
    try d.mapWindow(0x10, 1);
    try d.createWindow(0x20, 0x12a, .{ .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{ .event_mask = focus_change }, 2);
    try d.mapWindow(0x20, 1);
    // Initial focus is PointerRoot(1).
    try std.testing.expectEqual(@as(u32, 1), d.focus);
    // Focus W1: FocusIn(W1) only (old = PointerRoot is not a window).
    d.clearPending();
    try d.setInputFocus(0x10, 2, 0);
    try std.testing.expectEqual(@as(u32, 0x10), d.focus);
    try std.testing.expectEqual(@as(u8, 2), d.focus_revert);
    var fin_w1 = false;
    for (d.pending.items) |e| if (e.kind == .focus_in and e.event_window == 0x10) {
        fin_w1 = true;
    };
    try std.testing.expect(fin_w1);
    // Focus W2: FocusOut(W1) BEFORE FocusIn(W2).
    d.clearPending();
    try d.setInputFocus(0x20, 2, 0);
    var fout_i: ?usize = null;
    var fin_i: ?usize = null;
    for (d.pending.items, 0..) |e, idx| {
        if (e.kind == .focus_out and e.event_window == 0x10) fout_i = idx;
        if (e.kind == .focus_in and e.event_window == 0x20) fin_i = idx;
    }
    try std.testing.expect(fout_i != null and fin_i != null);
    try std.testing.expect(fout_i.? < fin_i.?);
}

test "setInputFocus: validation (NotViewable, NoWindow, BadValue); None/PointerRoot ok" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Created but not mapped -> not viewable.
    try d.createWindow(0x30, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, 2);
    try std.testing.expectError(error.NotViewable, d.setInputFocus(0x30, 0, 0));
    try std.testing.expectError(error.NoWindow, d.setInputFocus(0xDEAD, 0, 0));
    try std.testing.expectError(error.BadValue, d.setInputFocus(1, 9, 0));
    try d.setInputFocus(0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), d.focus);
    try d.setInputFocus(1, 1, 0);
    try std.testing.expectEqual(@as(u32, 1), d.focus);
}

/// Test helper: assert a KeyPress for `win` is among the recorded events.
fn expectKeyPressOn(d: *Display, win: u32) !void {
    for (d.pending.items) |e| if (e.kind == .key_press and e.event_window == win) return;
    return error.TestExpectedKeyPress;
}

test "injectKey: focus routing None/PointerRoot/window-in-subtree/window-outside" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{ .event_mask = key_press }, 2);
    try d.mapWindow(0x10, 1);
    try d.createWindow(0x20, 0x12a, .{ .x = 200, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{ .event_mask = key_press }, 3);
    try d.mapWindow(0x20, 1);
    // Pointer inside W1 (0x10).
    try d.injectMotion(50, 50, 1);

    // focus = None -> discarded.
    try d.setInputFocus(0, 0, 0);
    d.clearPending();
    try d.injectKey(38, true, 2);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);

    // focus = PointerRoot -> the pointer window (W1).
    try d.setInputFocus(1, 1, 0);
    d.clearPending();
    try d.injectKey(38, true, 3);
    try expectKeyPressOn(&d, 0x10);

    // focus = W2, pointer in W1 (NOT W2's subtree) -> delivered to W2 (focus).
    try d.setInputFocus(0x20, 2, 0);
    d.clearPending();
    try d.injectKey(38, true, 4);
    try expectKeyPressOn(&d, 0x20);

    // focus = W1, pointer in W1 (in subtree) -> delivered to W1 (pointer window).
    try d.setInputFocus(0x10, 2, 0);
    d.clearPending();
    try d.injectKey(38, true, 5);
    try expectKeyPressOn(&d, 0x10);
}

test "injectKey: modifier state tracked; a later key carries the held modifier" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{ .event_mask = key_press | key_release }, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(50, 50, 1);
    try d.setInputFocus(0x10, 2, 0);
    d.clearPending();
    // Press Shift (kc 50): input_state gains ShiftMask(1); the Shift event itself
    // carries state BEFORE (0).
    try d.injectKey(50, true, 2);
    try std.testing.expectEqual(@as(u16, 1), d.input_state);
    for (d.pending.items) |e| if (e.kind == .key_press and e.detail == 50) {
        try std.testing.expectEqual(@as(u16, 0), e.input_state);
    };
    // Press 'a' (kc 38): its event carries ShiftMask(1).
    d.clearPending();
    try d.injectKey(38, true, 3);
    var found = false;
    for (d.pending.items) |e| if (e.kind == .key_press and e.detail == 38) {
        found = true;
        try std.testing.expectEqual(@as(u16, 1), e.input_state);
    };
    try std.testing.expect(found);
    // Release Shift: input_state clears ShiftMask.
    try d.injectKey(50, false, 4);
    try std.testing.expectEqual(@as(u16, 0), d.input_state);
}

test "grabPointer: status 0 + a FAR injectMotion delivers .motion to the grabber on grab_window, not the spatial window" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Grab window Wg (client 1) near the origin; spatial window S (client 2,
    // selects PointerMotion) FAR away. The injected motion lands inside S, not
    // Wg -- proving grabbed events bypass spatial propagation entirely rather
    // than merely happening to land on Wg.
    try d.createWindow(0x10, 0x12a, .{ .x = 10, .y = 10, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try d.createWindow(0x20, 0x12a, .{ .x = 500, .y = 300, .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{ .event_mask = pointer_motion }, 2);
    try d.mapWindow(0x20, 1);
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));

    try d.injectMotion(520, 320, 5); // inside S (0x20), far from Wg (0x10)
    var to_grabber = false;
    var to_spatial = false;
    var saw_crossing = false;
    for (d.pending.items) |e| {
        if (e.kind == .motion and e.event_window == 0x10 and e.target_client == 1) to_grabber = true;
        if (e.kind == .motion and e.event_window == 0x20) to_spatial = true;
        if (e.kind == .enter or e.kind == .leave) saw_crossing = true;
    }
    try std.testing.expect(to_grabber);
    try std.testing.expect(!to_spatial);
    try std.testing.expect(!saw_crossing); // crossing suppressed while grabbed
    try std.testing.expectEqual(@as(u32, 0x20), d.pointer_window); // tracked silently
}

test "grabPointer: a second client's grab while held -> AlreadyGrabbed; same client re-grab -> Success" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));
    try std.testing.expectEqual(@as(u8, 1), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 2)); // AlreadyGrabbed
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1)); // same holder re-grabs fine
}

test "ungrabPointer releases the grab; normal spatial routing resumes" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try d.createWindow(0x20, 0x12a, .{ .x = 500, .y = 300, .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{ .event_mask = pointer_motion }, 2);
    try d.mapWindow(0x20, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));
    d.clearPending();
    try d.injectMotion(520, 320, 1);
    for (d.pending.items) |e| try std.testing.expect(!(e.kind == .motion and e.event_window == 0x20));

    d.ungrabPointer(1);
    d.clearPending();
    try d.injectMotion(521, 321, 2); // still inside S; re-trigger motion
    var to_spatial = false;
    for (d.pending.items) |e| if (e.kind == .motion and e.event_window == 0x20 and e.target_client == 2) {
        to_spatial = true;
    };
    try std.testing.expect(to_spatial);
}

test "grabPointer: non-viewable / nonexistent grab_window -> NotViewable" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Created but never mapped -> map_state stays .unmapped.
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try std.testing.expectEqual(@as(u8, 3), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));
    // A window id that was never created at all.
    try std.testing.expectEqual(@as(u8, 3), d.grabPointer(0x9999, pointer_motion, false, mode_async, mode_async, 1));
    try std.testing.expect(d.pointer_grab == null); // neither attempt set a grab
}

test "grabPointer owner_events=true: reports to the grab client's OWN selecting window under the pointer, else grab_window" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    // U is owned by a DIFFERENT client, but the grab holder (client 1) also
    // selects PointerMotion on it directly -- owner_events reports to the
    // grab client's own selection, not to whoever owns the window.
    try d.createWindow(0x30, 0x12a, .{ .x = 500, .y = 300, .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x30, 1);
    try d.changeAttributes(0x30, .{ .event_mask = pointer_motion }, 1);
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, true, mode_async, mode_async, 1));

    // Pointer inside U -> delivered on U (the grab client's own selection).
    try d.injectMotion(520, 320, 1);
    var on_u = false;
    for (d.pending.items) |e| if (e.kind == .motion and e.event_window == 0x30 and e.target_client == 1) {
        on_u = true;
    };
    try std.testing.expect(on_u);

    // Pointer over bare root (no client-1 selection anywhere in the path) ->
    // falls through to grab_window, filtered by the grab's event_mask.
    d.clearPending();
    try d.injectMotion(300, 300, 2);
    var on_grab_window = false;
    for (d.pending.items) |e| if (e.kind == .motion and e.event_window == 0x10 and e.target_client == 1) {
        on_grab_window = true;
    };
    try std.testing.expect(on_grab_window);
}

test "grabKeyboard routes injectKey to grab_window regardless of focus; ungrab restores focus routing" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{ .event_mask = key_press }, 2);
    try d.mapWindow(0x10, 1);
    try d.createWindow(0x20, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 3);
    try d.mapWindow(0x20, 1);
    // Focus W1 (0x10) so the grab can be proven to bypass it.
    try d.setInputFocus(0x10, 2, 0);
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabKeyboard(0x20, false, mode_async, mode_async, 3));
    try d.injectKey(38, true, 5);
    var to_grab_window = false;
    for (d.pending.items) |e| {
        if (e.kind == .key_press and e.event_window == 0x20 and e.target_client == 3) to_grab_window = true;
        try std.testing.expect(!(e.kind == .key_press and e.event_window == 0x10)); // NOT the focus window
    }
    try std.testing.expect(to_grab_window);

    d.ungrabKeyboard(3);
    d.clearPending();
    try d.injectKey(38, true, 6);
    try expectKeyPressOn(&d, 0x10); // normal focus routing resumes
}

test "cleanupClient releases the disconnecting client's pointer + keyboard grabs" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));
    try std.testing.expectEqual(@as(u8, 0), d.grabKeyboard(0x10, false, mode_async, mode_async, 1));
    try std.testing.expect(d.pointer_grab != null);
    try std.testing.expect(d.keyboard_grab != null);

    try d.cleanupClient(1);
    try std.testing.expect(d.pointer_grab == null);
    try std.testing.expect(d.keyboard_grab == null);
}

test "revalidateGrabs: destroying the grab_window releases the grab" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));
    try std.testing.expectEqual(@as(u8, 0), d.grabKeyboard(0x10, false, mode_async, mode_async, 1));

    try d.destroyWindow(0x10);
    try std.testing.expect(d.pointer_grab == null);
    try std.testing.expect(d.keyboard_grab == null);
}

test "grabButton: passive grab on root auto-activates + delivers ButtonPress to the grabber; release auto-releases" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1); // pointer lands over 0x10, a descendant of root
    d.clearPending();

    // Client 1 registers a passive grab on root for button 1, no modifiers.
    try d.grabButton(0x12a, button_press | button_release, false, 1, 0, mode_async, mode_async, 1);
    try std.testing.expect(d.pointer_grab == null); // registered but not yet active

    try d.injectButton(1, true, 2);
    try std.testing.expect(d.pointer_grab != null);
    try std.testing.expect(d.pointer_grab.?.auto);
    var press_delivered = false;
    for (d.pending.items) |e| {
        if (e.kind == .button_press and e.target_client == 1 and e.event_window == 0x12a) press_delivered = true;
    }
    try std.testing.expect(press_delivered);

    d.clearPending();
    try d.injectButton(1, false, 3);
    try std.testing.expect(d.pointer_grab == null); // all buttons up -> auto-released
    var release_delivered = false;
    for (d.pending.items) |e| {
        if (e.kind == .button_release and e.target_client == 1 and e.event_window == 0x12a) release_delivered = true;
    }
    try std.testing.expect(release_delivered);
}

test "grabButton: non-matching button does not activate; normal spatial routing resumes" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{ .event_mask = button_press }, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1);
    d.clearPending();

    try d.grabButton(0x12a, button_press | button_release, false, 1, 0, mode_async, mode_async, 1); // button 1 only

    try d.injectButton(2, true, 2); // button 2 -- not registered
    try std.testing.expect(d.pointer_grab == null);
    var to_spatial = false;
    for (d.pending.items) |e| {
        if (e.kind == .button_press and e.event_window == 0x10 and e.target_client == 2) to_spatial = true;
    }
    try std.testing.expect(to_spatial);
}

test "grabButton: exact-modifier match requires the held modifiers to equal the grab's" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1);
    d.clearPending();

    try d.grabButton(0x12a, button_press | button_release, false, 1, 8, mode_async, mode_async, 1); // Mod1(8) required

    // No modifiers held -> the grab doesn't activate.
    try d.injectButton(1, true, 2);
    try std.testing.expect(d.pointer_grab == null);
    try d.injectButton(1, false, 3); // release the (ungrabbed) press to keep button state clean

    // Hold Mod1 -> now it activates.
    d.input_state = 8;
    try d.injectButton(1, true, 4);
    try std.testing.expect(d.pointer_grab != null);
    try std.testing.expectEqual(@as(u32, 0x12a), d.pointer_grab.?.grab_window);
}

test "grabButton: AnyButton(0) and AnyModifier(0x8000) wildcards match any button/modifiers" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1);
    d.clearPending();

    try d.grabButton(0x12a, button_press | button_release, false, 0, 0x8000, mode_async, mode_async, 1); // AnyButton, AnyModifier

    d.input_state = 8; // arbitrary modifiers held -- AnyModifier ignores this
    try d.injectButton(3, true, 2); // any button
    try std.testing.expect(d.pointer_grab != null);
    try std.testing.expectEqual(@as(u32, 1), d.pointer_grab.?.client);
}

test "grabKey: passive grab activates on the matching key+modifiers; auto-releases on that SAME key's release" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1); // pointer over 0x10, in root's subtree
    d.clearPending();

    try d.grabKey(0x12a, false, 24, 8, mode_async, mode_async, 1); // key 24, Mod1(8) required
    d.input_state = 8; // Mod1 held (24 isn't itself a modifier keycode, so this stays put)

    try d.injectKey(24, true, 2);
    try std.testing.expect(d.keyboard_grab != null);
    try std.testing.expectEqual(@as(u8, 24), d.keyboard_grab.?.auto_key.?);
    var press_delivered = false;
    for (d.pending.items) |e| {
        if (e.kind == .key_press and e.target_client == 1 and e.event_window == 0x12a) press_delivered = true;
    }
    try std.testing.expect(press_delivered);

    d.clearPending();
    try d.injectKey(24, false, 3);
    try std.testing.expect(d.keyboard_grab == null); // released by the SAME key going up
}

test "grabButton: BadAccess on a conflicting registration by a different client; different modifiers is fine" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try d.grabButton(0x12a, button_press, false, 1, 0, mode_async, mode_async, 1); // client 1: root/button1/mods0
    try std.testing.expectError(error.Access, d.grabButton(0x12a, button_press, false, 1, 0, mode_async, mode_async, 2)); // client 2, same triple
    try d.grabButton(0x12a, button_press, false, 1, 8, mode_async, mode_async, 2); // client 2, different modifiers -> fine
    try std.testing.expectEqual(@as(usize, 2), d.button_grabs.items.len);
}

test "grabKey: BadAccess on a conflicting registration by a different client" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try d.grabKey(0x12a, false, 24, 0, mode_async, mode_async, 1); // client 1: root/key24/mods0
    try std.testing.expectError(error.Access, d.grabKey(0x12a, false, 24, 0, mode_async, mode_async, 2)); // client 2, same triple
    try d.grabKey(0x12a, false, 24, 8, mode_async, mode_async, 2); // client 2, different modifiers -> fine
    try std.testing.expectEqual(@as(usize, 2), d.key_grabs.items.len);
}

test "ungrabButton removes the passive grab; a subsequent matching press no longer activates" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1);
    d.clearPending();

    try d.grabButton(0x12a, button_press | button_release, false, 1, 0, mode_async, mode_async, 1);
    d.ungrabButton(1, 0x12a, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), d.button_grabs.items.len);

    try d.injectButton(1, true, 2);
    try std.testing.expect(d.pointer_grab == null); // no passive grab left to activate
}

test "releaseGrabsForClient prunes a disconnecting client's passive button + key grabs" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.grabButton(0x12a, button_press, false, 1, 0, mode_async, mode_async, 1);
    try d.grabKey(0x12a, false, 24, 0, mode_async, mode_async, 1);
    try std.testing.expectEqual(@as(usize, 1), d.button_grabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.key_grabs.items.len);

    try d.cleanupClient(1);
    try std.testing.expectEqual(@as(usize, 0), d.button_grabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), d.key_grabs.items.len);
}

test "revalidateGrabs prunes passive button + key grabs whose grab_window was destroyed" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.grabButton(0x10, button_press, false, 1, 0, mode_async, mode_async, 1);
    try d.grabKey(0x10, false, 24, 0, mode_async, mode_async, 1);
    try std.testing.expectEqual(@as(usize, 1), d.button_grabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.key_grabs.items.len);

    try d.destroyWindow(0x10);
    try std.testing.expectEqual(@as(usize, 0), d.button_grabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), d.key_grabs.items.len);
}

test "grabPointer(pointer_mode=Sync) freezes immediately: no trigger, injected events QUEUE, pointer_x/y untouched" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion | button_press, false, mode_sync, mode_async, 1));
    try std.testing.expect(d.pointer_frozen);
    try std.testing.expect(d.pointer_trigger == null); // explicit grab: no activating event to replay

    const before_x = d.pointer_x;
    const before_y = d.pointer_y;
    try d.injectMotion(500, 400, 1);
    try std.testing.expectEqual(before_x, d.pointer_x); // dispatchMotion never ran -> untouched
    try std.testing.expectEqual(before_y, d.pointer_y);
    try d.injectButton(1, true, 2);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len); // nothing dispatched
    try std.testing.expectEqual(@as(usize, 2), d.frozen_pointer_events.items.len); // both queued, FIFO
    try std.testing.expectEqual(EventKind.motion, d.frozen_pointer_events.items[0].kind);
    try std.testing.expectEqual(EventKind.button_press, d.frozen_pointer_events.items[1].kind);
}

test "grabPointer(pointer_mode=Async) does not freeze: injectButton delivers normally (unchanged 4m behavior)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, button_press, false, mode_async, mode_async, 1));
    try std.testing.expect(!d.pointer_frozen);
    try d.injectButton(1, true, 3);
    try std.testing.expectEqual(@as(usize, 0), d.frozen_pointer_events.items.len);
    var delivered = false;
    for (d.pending.items) |e| if (e.kind == .button_press and e.target_client == 1) {
        delivered = true;
    };
    try std.testing.expect(delivered);
}

test "grabKeyboard(keyboard_mode=Sync) freezes: injectKey queues, no key event, modifier state unchanged" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabKeyboard(0x10, false, mode_async, mode_sync, 1));
    try std.testing.expect(d.keyboard_frozen);
    const before_state = d.input_state;

    try d.injectKey(50, true, 1); // Shift_L -- would flip a modifier bit if dispatched
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.frozen_keyboard_events.items.len);
    try std.testing.expectEqual(EventKind.key_press, d.frozen_keyboard_events.items[0].kind);
    try std.testing.expectEqual(@as(u8, 50), d.frozen_keyboard_events.items[0].detail);
    try std.testing.expectEqual(before_state, d.input_state); // no modifier update while frozen
}

test "passive GrabButton(pointer_mode=Sync): the activating press IS delivered, THEN freezes with pointer_trigger set; the next event queues" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Root grab, matching the existing 4n passive-grab test shape.
    try d.grabButton(0x12a, button_press | button_release, false, 1, 0, mode_sync, mode_async, 1);
    d.clearPending();

    try std.testing.expect(!d.pointer_frozen);
    try d.injectButton(1, true, 1); // matches -> auto-activates -> delivers -> THEN freezes
    var delivered = false;
    for (d.pending.items) |e| if (e.kind == .button_press and e.target_client == 1) {
        delivered = true;
    };
    try std.testing.expect(delivered); // the trigger reached the grabber
    try std.testing.expect(d.pointer_frozen); // frozen AFTER delivery
    try std.testing.expect(d.pointer_trigger != null);
    try std.testing.expectEqual(@as(u8, 1), d.pointer_trigger.?.detail);
    try std.testing.expectEqual(EventKind.button_press, d.pointer_trigger.?.kind);

    // A following event queues instead of dispatching.
    d.clearPending();
    try d.injectMotion(30, 30, 2);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.frozen_pointer_events.items.len);
}

test "passive GrabButton(pointer_mode=Async): activates + delivers, stays NOT frozen (4n behavior intact)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.grabButton(0x12a, button_press | button_release, false, 1, 0, mode_async, mode_async, 1);
    d.clearPending();

    try d.injectButton(1, true, 1);
    try std.testing.expect(!d.pointer_frozen);
    try std.testing.expect(d.pointer_trigger == null);
    try std.testing.expectEqual(@as(usize, 0), d.frozen_pointer_events.items.len);
}

test "clearPointerGrab clears freeze + queue on ungrab, disconnect, and grab_window destroy" {
    const gpa = std.testing.allocator;

    // ungrabPointer while frozen.
    {
        var d = try Display.init(gpa, 0x12a, 24, 0x21);
        defer d.deinit();
        try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
        try d.mapWindow(0x10, 1);
        try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_sync, mode_async, 1));
        try d.injectMotion(1, 1, 1); // queues one frozen event
        try std.testing.expect(d.pointer_frozen);
        try std.testing.expectEqual(@as(usize, 1), d.frozen_pointer_events.items.len);

        d.ungrabPointer(1);
        try std.testing.expect(d.pointer_grab == null);
        try std.testing.expect(!d.pointer_frozen);
        try std.testing.expectEqual(@as(usize, 0), d.frozen_pointer_events.items.len);
    }

    // disconnect (releaseGrabsForClient) while frozen.
    {
        var d = try Display.init(gpa, 0x12a, 24, 0x21);
        defer d.deinit();
        try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
        try d.mapWindow(0x10, 1);
        try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_sync, mode_async, 1));
        try d.injectMotion(1, 1, 1);
        try std.testing.expect(d.pointer_frozen);

        try d.cleanupClient(1);
        try std.testing.expect(d.pointer_grab == null);
        try std.testing.expect(!d.pointer_frozen);
        try std.testing.expectEqual(@as(usize, 0), d.frozen_pointer_events.items.len);
    }

    // grab_window destroyed (revalidateGrabs) while frozen.
    {
        var d = try Display.init(gpa, 0x12a, 24, 0x21);
        defer d.deinit();
        try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2); // owned by a DIFFERENT client so it outlives client 1's cleanup
        try d.mapWindow(0x10, 1);
        try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_sync, mode_async, 1));
        try d.injectMotion(1, 1, 1);
        try std.testing.expect(d.pointer_frozen);

        try d.destroyWindow(0x10);
        try std.testing.expect(d.pointer_grab == null);
        try std.testing.expect(!d.pointer_frozen);
        try std.testing.expectEqual(@as(usize, 0), d.frozen_pointer_events.items.len);
    }
}

test "AllowEvents(AsyncPointer): a Sync passive grab's queued events flow through the still-active grab" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1); // pointer over 0x10, in root's subtree
    d.clearPending();

    try d.grabButton(0x12a, button_press | button_release | pointer_motion, false, 1, 0, mode_sync, mode_async, 1);
    try d.injectButton(1, true, 2); // activates: trigger delivered, THEN freezes
    try std.testing.expect(d.pointer_frozen);
    d.clearPending();

    try d.injectMotion(6, 6, 3); // queues
    try d.injectButton(2, true, 4); // queues
    try std.testing.expectEqual(@as(usize, 2), d.frozen_pointer_events.items.len);

    try d.allowEvents(0, 1); // AsyncPointer, by the grab holder
    try std.testing.expect(!d.pointer_frozen);
    try std.testing.expectEqual(@as(usize, 0), d.frozen_pointer_events.items.len);
    var saw_motion = false;
    var saw_button2 = false;
    for (d.pending.items) |e| {
        if (e.kind == .motion and e.event_window == 0x12a and e.target_client == 1) saw_motion = true;
        if (e.kind == .button_press and e.detail == 2 and e.event_window == 0x12a and e.target_client == 1) saw_button2 = true;
    }
    try std.testing.expect(saw_motion);
    try std.testing.expect(saw_button2);
}

test "AllowEvents(ReplayPointer): the WM's click-to-focus replay -- trigger re-dispatches spatially to the app after the WM releases the grab" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // WM (client 1) owns P; app A (client 2) owns child C of P and selects
    // ButtonPress on it.
    try d.createWindow(0x30, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x30, 1);
    try d.createWindow(0x31, 0x30, .{ .x = 10, .y = 10, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{ .event_mask = button_press }, 2);
    try d.mapWindow(0x31, 1);
    try d.injectMotion(15, 15, 1); // pointer over C
    d.clearPending();

    // WM registers a Sync passive grab on P for button 1.
    try d.grabButton(0x30, button_press | button_release, false, 1, 0, mode_sync, mode_async, 1);
    try d.injectButton(1, true, 2);
    try std.testing.expect(d.pointer_frozen);
    try std.testing.expect(d.pointer_grab.?.auto);
    var wm_got_trigger = false;
    for (d.pending.items) |e| {
        if (e.kind == .button_press and e.event_window == 0x30 and e.target_client == 1) wm_got_trigger = true;
    }
    try std.testing.expect(wm_got_trigger); // WM saw the click first
    d.clearPending();

    try d.allowEvents(2, 1); // ReplayPointer, by the WM
    try std.testing.expect(d.pointer_grab == null); // grab released
    try std.testing.expect(!d.pointer_frozen);
    var app_got_replay = false;
    for (d.pending.items) |e| {
        if (e.kind == .button_press and e.event_window == 0x31 and e.target_client == 2) app_got_replay = true;
    }
    try std.testing.expect(app_got_replay); // ...then the app got it via spatial replay
}

test "AllowEvents(ReplayPointer): a no-op when the freeze came from an EXPLICIT GrabPointer(Sync) (no trigger to replay)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_sync, mode_async, 1));
    try std.testing.expect(d.pointer_frozen);
    try std.testing.expect(d.pointer_trigger == null); // explicit grab: nothing to replay
    d.clearPending();

    try d.allowEvents(2, 1); // ReplayPointer
    try std.testing.expect(d.pointer_grab != null); // untouched -- no-op
    try std.testing.expect(d.pointer_frozen);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "AllowEvents(SyncPointer): flushes through the next button, then re-freezes, leaving the tail queued" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion | button_press | button_release, false, mode_sync, mode_async, 1));
    try std.testing.expect(d.pointer_frozen);
    d.clearPending();

    try d.injectMotion(1, 1, 1); // queues: motion
    try d.injectButton(1, true, 2); // queues: button_press
    try d.injectMotion(2, 2, 3); // queues: motion
    try std.testing.expectEqual(@as(usize, 3), d.frozen_pointer_events.items.len);

    try d.allowEvents(1, 1); // SyncPointer
    try std.testing.expect(d.pointer_frozen); // re-frozen after the button
    try std.testing.expectEqual(@as(usize, 1), d.frozen_pointer_events.items.len); // the trailing motion
    try std.testing.expectEqual(EventKind.motion, d.frozen_pointer_events.items[0].kind);
    var saw_motion = false;
    var saw_press = false;
    for (d.pending.items) |e| {
        if (e.kind == .motion and e.event_window == 0x10 and e.target_client == 1) saw_motion = true;
        if (e.kind == .button_press and e.event_window == 0x10 and e.target_client == 1) saw_press = true;
    }
    try std.testing.expect(saw_motion);
    try std.testing.expect(saw_press);
}

test "AllowEvents(AsyncKeyboard): a Sync passive key grab's queued key flows through the still-active grab" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1);
    d.clearPending();

    try d.grabKey(0x12a, false, 24, 8, mode_async, mode_sync, 1); // key 24, Mod1(8), Sync keyboard
    d.input_state = 8;
    try d.injectKey(24, true, 2); // activates: trigger delivered, THEN freezes
    try std.testing.expect(d.keyboard_frozen);
    d.clearPending();

    try d.injectKey(25, true, 3); // queues
    try std.testing.expectEqual(@as(usize, 1), d.frozen_keyboard_events.items.len);

    try d.allowEvents(3, 1); // AsyncKeyboard, by the grab holder
    try std.testing.expect(!d.keyboard_frozen);
    try std.testing.expectEqual(@as(usize, 0), d.frozen_keyboard_events.items.len);
    var saw_key25 = false;
    for (d.pending.items) |e| {
        if (e.kind == .key_press and e.detail == 25 and e.event_window == 0x12a and e.target_client == 1) saw_key25 = true;
    }
    try std.testing.expect(saw_key25);
}

test "AllowEvents(ReplayKeyboard): trigger re-dispatches by focus routing to the selecting app after the WM releases the grab" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x30, 0x12a, .{ .x = 0, .y = 0, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x30, 1);
    try d.createWindow(0x31, 0x30, .{ .x = 10, .y = 10, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{ .event_mask = key_press }, 2);
    try d.mapWindow(0x31, 1);
    try d.injectMotion(15, 15, 1); // pointer over C
    try d.setInputFocus(1, 0, 0); // PointerRoot
    d.clearPending();

    try d.grabKey(0x30, false, 24, 0, mode_async, mode_sync, 1); // WM's Sync key grab on P
    try d.injectKey(24, true, 2);
    try std.testing.expect(d.keyboard_frozen);
    var wm_got_trigger = false;
    for (d.pending.items) |e| {
        if (e.kind == .key_press and e.event_window == 0x30 and e.target_client == 1) wm_got_trigger = true;
    }
    try std.testing.expect(wm_got_trigger);
    d.clearPending();

    try d.allowEvents(5, 1); // ReplayKeyboard
    try std.testing.expect(d.keyboard_grab == null);
    try std.testing.expect(!d.keyboard_frozen);
    var app_got_replay = false;
    for (d.pending.items) |e| {
        if (e.kind == .key_press and e.event_window == 0x31 and e.target_client == 2) app_got_replay = true;
    }
    try std.testing.expect(app_got_replay);
}

test "AllowEvents: mode > 7 is BadValue; a client with no matching grab is a silent no-op" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try std.testing.expectError(error.BadValue, d.allowEvents(8, 1));
    try std.testing.expectError(error.BadValue, d.allowEvents(255, 1));

    // No grab held by anyone -- every mode is a no-op, not a crash.
    try d.allowEvents(0, 1);
    try d.allowEvents(2, 1);
    try d.allowEvents(7, 1);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);

    // client 1 holds a grab; client 99 (a stranger) invokes AllowEvents -> no-op.
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_sync, mode_async, 1));
    try std.testing.expect(d.pointer_frozen);
    try d.allowEvents(0, 99);
    try std.testing.expect(d.pointer_frozen); // untouched -- 99 doesn't hold the grab
}

test "ChangeActivePointerGrab: the holder's new mask takes effect immediately; a non-holder is a no-op" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, button_press | button_release, false, mode_async, mode_async, 1));
    d.clearPending();

    // Non-holder: no-op.
    d.changeActivePointerGrab(button_release, 2);
    try std.testing.expectEqual(@as(u16, button_press | button_release), d.pointer_grab.?.event_mask);

    // Holder: narrows the mask to button_release only.
    d.changeActivePointerGrab(button_release, 1);
    try std.testing.expectEqual(@as(u16, button_release), d.pointer_grab.?.event_mask);

    // A subsequent grabbed press is now filtered out (mask lacks button_press)...
    try d.injectButton(1, true, 1);
    for (d.pending.items) |e| try std.testing.expect(!(e.kind == .button_press and e.event_window == 0x10));
    // ...but the matching release still delivers.
    d.clearPending();
    try d.injectButton(1, false, 2);
    var saw_release = false;
    for (d.pending.items) |e| if (e.kind == .button_release and e.event_window == 0x10 and e.target_client == 1) {
        saw_release = true;
    };
    try std.testing.expect(saw_release);
}

test "GrabPointer(pointer_mode=Async, keyboard_mode=Sync): cross-mode freezes the KEYBOARD (no keyboard_grab); AllowEvents(AsyncKeyboard) by the pointer-grab holder THAWS it" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{ .event_mask = key_press }, 2);
    try d.mapWindow(0x10, 1);
    try d.injectMotion(5, 5, 1); // pointer over 0x10 -- PointerRoot (default focus) routes keys here
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, button_press, false, mode_async, mode_sync, 1));
    try std.testing.expect(!d.pointer_frozen); // pointer_mode is Async -- pointer itself untouched
    try std.testing.expect(d.keyboard_frozen); // keyboard_mode is Sync -- cross-mode freeze
    try std.testing.expect(d.keyboard_grab == null); // no keyboard grab was ever taken

    // Before the fix, AllowEvents(AsyncKeyboard) was a no-op here: it gated
    // on keyboard_grab.client, which is null, so the keyboard stayed frozen
    // forever. It's owned by the pointer_grab, so its holder can thaw it.
    try d.allowEvents(3, 1); // AsyncKeyboard, by the client holding the pointer grab that froze it
    try std.testing.expect(!d.keyboard_frozen);

    try d.injectKey(38, true, 2); // 'a' -- should now deliver normally
    var delivered = false;
    for (d.pending.items) |e| if (e.kind == .key_press and e.event_window == 0x10 and e.target_client == 2) {
        delivered = true;
    };
    try std.testing.expect(delivered);
}

test "GrabPointer(Async,Sync) cross-mode keyboard freeze: UngrabPointer clears it too (no permanent freeze)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);

    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, button_press, false, mode_async, mode_sync, 1));
    try std.testing.expect(d.keyboard_frozen);
    try d.injectKey(38, true, 2); // queues while frozen
    try std.testing.expectEqual(@as(usize, 1), d.frozen_keyboard_events.items.len);

    d.ungrabPointer(1);
    try std.testing.expect(d.pointer_grab == null);
    try std.testing.expect(!d.keyboard_frozen); // the cross-owned freeze is released along with the grab
    try std.testing.expectEqual(@as(usize, 0), d.frozen_keyboard_events.items.len);
}

test "GrabPointer(Async,Sync) cross-mode keyboard freeze: the pointer-grab client's disconnect clears it too" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);

    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, button_press, false, mode_async, mode_sync, 1));
    try std.testing.expect(d.keyboard_frozen);
    try d.injectKey(38, true, 2);
    try std.testing.expectEqual(@as(usize, 1), d.frozen_keyboard_events.items.len);

    try d.cleanupClient(1); // client 1 (the pointer-grab holder) disconnects
    try std.testing.expect(d.pointer_grab == null);
    try std.testing.expect(!d.keyboard_frozen);
    try std.testing.expectEqual(@as(usize, 0), d.frozen_keyboard_events.items.len);
}

test "GrabKeyboard(pointer_mode=Sync): cross-mode freezes the POINTER (no pointer_grab); AllowEvents(AsyncPointer) thaws it, UngrabKeyboard clears a re-frozen one too" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    d.clearPending();

    try std.testing.expectEqual(@as(u8, 0), d.grabKeyboard(0x10, false, mode_sync, mode_async, 1));
    try std.testing.expect(d.pointer_frozen); // pointer_mode is Sync -- cross-mode freeze
    try std.testing.expect(!d.keyboard_frozen);
    try std.testing.expect(d.pointer_grab == null); // no pointer grab was ever taken

    try d.injectMotion(5, 5, 1); // queues while frozen
    try std.testing.expectEqual(@as(usize, 1), d.frozen_pointer_events.items.len);

    // Before the fix, AllowEvents(AsyncPointer) was a no-op here (gated on a
    // held pointer_grab, which is null) -- the pointer stayed frozen forever.
    try d.allowEvents(0, 1); // AsyncPointer, by the client holding the keyboard grab that froze it
    try std.testing.expect(!d.pointer_frozen);
    try std.testing.expectEqual(@as(usize, 0), d.frozen_pointer_events.items.len); // flushed

    // Re-freeze via a fresh GrabKeyboard, then prove UngrabKeyboard clears it too.
    try std.testing.expectEqual(@as(u8, 0), d.grabKeyboard(0x10, false, mode_sync, mode_async, 1));
    try std.testing.expect(d.pointer_frozen);
    d.ungrabKeyboard(1);
    try std.testing.expect(d.keyboard_grab == null);
    try std.testing.expect(!d.pointer_frozen);
}

test "frozen queue caps at max_frozen_events, dropping the oldest to keep the newest" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_sync, mode_async, 1));
    try std.testing.expect(d.pointer_frozen);

    var i: u32 = 0;
    while (i < Display.max_frozen_events + 10) : (i += 1) {
        try d.injectMotion(@intCast(i % 32000), 0, i);
    }
    try std.testing.expectEqual(Display.max_frozen_events, d.frozen_pointer_events.items.len);
    // The oldest 10 were dropped -- the queue now starts at time=10...
    try std.testing.expectEqual(@as(u32, 10), d.frozen_pointer_events.items[0].time);
    // ...and the newest survived -- the queue ends at time=max_frozen_events+9.
    try std.testing.expectEqual(@as(u32, @intCast(Display.max_frozen_events + 9)), d.frozen_pointer_events.items[d.frozen_pointer_events.items.len - 1].time);
}

test "revertFocusIfInvalid: destroy + unmap revert the focus per focus_revert" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // PointerRoot revert: destroy the focus window -> focus becomes PointerRoot(1).
    try d.createWindow(0x10, 0x12a, .{ .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x10, 1);
    try d.setInputFocus(0x10, 1, 0);
    try d.destroyWindow(0x10);
    try std.testing.expectEqual(@as(u32, 1), d.focus);
    // None revert: destroy -> focus becomes None(0).
    try d.createWindow(0x11, 0x12a, .{ .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x11, 1);
    try d.setInputFocus(0x11, 0, 0);
    try d.destroyWindow(0x11);
    try std.testing.expectEqual(@as(u32, 0), d.focus);
    // Parent revert on UNMAP (window still exists -> real parent): child 0x13 in 0x12.
    try d.createWindow(0x12, 0x12a, .{ .width = 80, .height = 80, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x12, 1);
    try d.createWindow(0x13, 0x12, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x13, 1);
    try d.setInputFocus(0x13, 2, 0);
    try d.unmapWindow(0x13);
    try std.testing.expectEqual(@as(u32, 0x12), d.focus); // reverted to the real parent
    // Parent revert on DESTROY -> root (the window is gone; documented simplification).
    try d.createWindow(0x14, 0x12a, .{ .width = 40, .height = 40, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.mapWindow(0x14, 1);
    try d.setInputFocus(0x14, 2, 0);
    try d.destroyWindow(0x14);
    try std.testing.expectEqual(@as(u32, 0x12a), d.focus); // root
}

test "keyboardMapping + modifierMapping + modifierIndexOf" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const km = try d.keyboardMapping(38, 1);
    try std.testing.expectEqual(@as(u8, 2), km.per);
    try std.testing.expectEqual(@as(usize, 2), km.syms.len);
    try std.testing.expectEqual(@as(u32, 0x61), km.syms[0]); // 'a'
    try std.testing.expectEqual(@as(u32, 0x41), km.syms[1]); // 'A'
    const full = try d.keyboardMapping(8, 248);
    try std.testing.expectEqual(@as(usize, 496), full.syms.len);
    try std.testing.expectError(error.BadValue, d.keyboardMapping(0, 1)); // first < min
    try std.testing.expectError(error.BadValue, d.keyboardMapping(255, 2)); // past max

    const mm = d.modifierMapping();
    try std.testing.expectEqual(@as(u8, 2), mm.per);
    try std.testing.expectEqual(@as(usize, 16), mm.codes.len);
    try std.testing.expectEqual(@as(u8, 50), mm.codes[0]); // Shift first keycode
    try std.testing.expectEqual(@as(u8, 62), mm.codes[1]);
    try std.testing.expectEqual(@as(u8, 37), mm.codes[4]); // Control first keycode

    try std.testing.expectEqual(@as(?u3, 0), d.modifierIndexOf(50)); // Shift
    try std.testing.expectEqual(@as(?u3, 2), d.modifierIndexOf(37)); // Control
    try std.testing.expectEqual(@as(?u3, null), d.modifierIndexOf(99));
    try std.testing.expectEqual(@as(?u3, null), d.modifierIndexOf(0));
}

/// A counting wrapper around a real SoftwareRenderer, proving the injection
/// seam (`initWithRenderer`) actually drives an injected vtable rather than
/// silently falling back to the default. Every call increments a counter and
/// then delegates to the wrapped software renderer so surfaces stay real
/// (getImage/etc keep working through the wrapper).
const CountingRenderer = struct {
    inner: render.SoftwareRenderer,
    create_surface_count: usize = 0,
    fill_rect_count: usize = 0,

    /// Recording for the SP-Server-5a output-stage seam: proves
    /// Display.setCrtcGamma/setCrtcTransform actually drive the INJECTED
    /// renderer (not just the default SoftwareRenderer Display would
    /// otherwise heap-allocate for itself).
    set_gamma_called: bool = false,
    last_gamma_red0: u16 = 0,
    set_transform_called: bool = false,
    last_transform: [9]i32 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },

    pub fn renderer(self: *CountingRenderer) render.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: render.Renderer.VTable = .{
        .createSurface = createSurface,
        .destroySurface = destroySurface,
        .resizeSurface = resizeSurface,
        .fillRect = fillRect,
        .copyRect = copyRect,
        .putImage = putImage,
        .getImage = getImage,
        .drawPoints = drawPoints,
        .drawLines = drawLines,
        .fillPolygon = fillPolygon,
        .drawArcs = drawArcs,
        .fillArcs = fillArcs,
        .drawGlyph = drawGlyph,
        .setCrtcGamma = setCrtcGamma,
        .setCrtcTransform = setCrtcTransform,
    };

    fn createSurface(ptr: *anyopaque, depth: u8, width: u16, height: u16) render.RenderError!render.Surface {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.create_surface_count += 1;
        return self.inner.renderer().createSurface(depth, width, height);
    }
    fn destroySurface(ptr: *anyopaque, surface: render.Surface) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.inner.renderer().destroySurface(surface);
    }
    fn resizeSurface(ptr: *anyopaque, surface: *render.Surface, width: u16, height: u16) render.RenderError!void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        return self.inner.renderer().resizeSurface(surface, width, height);
    }
    fn fillRect(ptr: *anyopaque, surface: render.Surface, x: i16, y: i16, width: u16, height: u16, pixel: u32) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.fill_rect_count += 1;
        self.inner.renderer().fillRect(surface, x, y, width, height, pixel);
    }
    fn copyRect(ptr: *anyopaque, dst: render.Surface, src: render.Surface, src_x: u16, src_y: u16, dst_x: u16, dst_y: u16, width: u16, height: u16) render.RenderError!void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        return self.inner.renderer().copyRect(dst, src, src_x, src_y, dst_x, dst_y, width, height);
    }
    fn putImage(ptr: *anyopaque, surface: render.Surface, dst_x: i16, dst_y: i16, width: u16, height: u16, data: []const u8) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.inner.renderer().putImage(surface, dst_x, dst_y, width, height, data);
    }
    fn getImage(ptr: *anyopaque, surface: render.Surface, x: u16, y: u16, width: u16, height: u16, out: []u8) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.inner.renderer().getImage(surface, x, y, width, height, out);
    }
    fn drawPoints(ptr: *anyopaque, surface: render.Surface, points: []const render.Point, pixel: u32) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.inner.renderer().drawPoints(surface, points, pixel);
    }
    fn drawLines(ptr: *anyopaque, surface: render.Surface, points: []const render.Point, pixel: u32) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.inner.renderer().drawLines(surface, points, pixel);
    }
    fn fillPolygon(ptr: *anyopaque, surface: render.Surface, points: []const render.Point, pixel: u32) render.RenderError!void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        return self.inner.renderer().fillPolygon(surface, points, pixel);
    }
    fn drawArcs(ptr: *anyopaque, surface: render.Surface, arcs: []const render.Arc, pixel: u32) render.RenderError!void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        return self.inner.renderer().drawArcs(surface, arcs, pixel);
    }
    fn fillArcs(ptr: *anyopaque, surface: render.Surface, arcs: []const render.Arc, mode: render.ArcMode, pixel: u32) render.RenderError!void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        return self.inner.renderer().fillArcs(surface, arcs, mode, pixel);
    }
    fn drawGlyph(ptr: *anyopaque, surface: render.Surface, x: i16, y: i16, bits: []const u8, w: u8, h: u8, fg: u32) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.inner.renderer().drawGlyph(surface, x, y, bits, w, h, fg);
    }
    fn setCrtcGamma(ptr: *anyopaque, red: []const u16, green: []const u16, blue: []const u16) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.set_gamma_called = true;
        self.last_gamma_red0 = red[0];
        self.inner.renderer().setCrtcGamma(red, green, blue);
    }
    fn setCrtcTransform(ptr: *anyopaque, matrix: [9]i32) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ptr));
        self.set_transform_called = true;
        self.last_transform = matrix;
        self.inner.renderer().setCrtcTransform(matrix);
    }
};

test "initWithRenderer: injected renderer's vtable is actually driven (createSurface/fillRect counted)" {
    const gpa = std.testing.allocator;
    var counting: CountingRenderer = .{ .inner = .{ .gpa = gpa } };
    var d = try Display.initWithRenderer(gpa, 0x12a, 24, 0x21, counting.renderer());
    defer d.deinit();

    // Display.init's root window already drove one createSurface call.
    try std.testing.expectEqual(@as(usize, 1), counting.create_surface_count);

    try d.createWindow(0xA, 0x12a, .{ .width = 4, .height = 4, .depth = 24 }, 1, 0x21, .{}, 1);
    try std.testing.expectEqual(@as(usize, 2), counting.create_surface_count);

    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00112233 }, 1);
    try d.fillRect(0xA, 0x200, 0, 0, 4, 4);
    try std.testing.expectEqual(@as(usize, 1), counting.fill_rect_count);

    // The fill actually landed through the wrapped software renderer.
    try std.testing.expectEqual(@as(u32, 0x00112233), readbackPixel(&d, 0xA, 0, 0));

    // A second fill bumps the count again, proving it isn't a one-shot fluke.
    try d.fillRect(0xA, 0x200, 1, 1, 1, 1);
    try std.testing.expectEqual(@as(usize, 2), counting.fill_rect_count);
}

test "setCrtcGamma/setCrtcTransform: Display pushes RANDR-stored values across the renderer seam (mock)" {
    // Proves the SP-Server-5a wiring: Display.setCrtcGamma/setCrtcTransform
    // (the RANDR request paths) actually call through to an INJECTED
    // renderer's setCrtcGamma/setCrtcTransform, not just store locally.
    const gpa = std.testing.allocator;
    var counting: CountingRenderer = .{ .inner = .{ .gpa = gpa } };
    var d = try Display.initWithRenderer(gpa, 0x12a, 24, 0x21, counting.renderer());
    defer d.deinit();

    try std.testing.expect(!counting.set_gamma_called);
    try std.testing.expect(!counting.set_transform_called);

    var red: [256]u16 = undefined;
    var green: [256]u16 = undefined;
    var blue: [256]u16 = undefined;
    for (0..256) |i| {
        red[i] = @intCast(i * 257);
        green[i] = red[i];
        blue[i] = red[i];
    }
    red[0] = 0xBEEF; // marker so the recorded value is unambiguous

    try d.setCrtcGamma(256, &red, &green, &blue);
    try std.testing.expect(counting.set_gamma_called);
    try std.testing.expectEqual(@as(u16, 0xBEEF), counting.last_gamma_red0);

    const scaled = [9]u32{ 0x00020000, 0, 0, 0, 0x00020000, 0, 0, 0, 0x00010000 };
    d.setCrtcTransform(scaled);
    try std.testing.expect(counting.set_transform_called);
    // FIXED is signed 16.16; every element here has bit 31 clear, so the
    // u32->i32 bit-reinterpretation is numerically identity for this matrix.
    const expected_signed = [9]i32{ 0x00020000, 0, 0, 0, 0x00020000, 0, 0, 0, 0x00010000 };
    try std.testing.expectEqual(expected_signed, counting.last_transform);
}

test "setCrtcGamma: real SoftwareRenderer through the Display seam inverts a present()d pattern" {
    // End-to-end (no mock): Display.setCrtcGamma -> renderer.setCrtcGamma ->
    // SoftwareRenderer.present() actually applies the ramp.
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    // Fill the whole root surface with a known, non-gray pattern (so every
    // channel exercises a distinct ramp entry).
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00112233 }, 1);
    try d.fillRect(d.root, 0x200, 0, 0, 640, 480);

    // An exactly-invertible ramp: ramp[i]=(255-i)*257, so (ramp[i]>>8)==255-i
    // with no rounding error (mirrors render.zig's linear_gamma construction).
    var inv_red: [256]u16 = undefined;
    var inv_green: [256]u16 = undefined;
    var inv_blue: [256]u16 = undefined;
    for (0..256) |i| {
        const v: u16 = @intCast((255 - i) * 257);
        inv_red[i] = v;
        inv_green[i] = v;
        inv_blue[i] = v;
    }
    try d.setCrtcGamma(256, &inv_red, &inv_green, &inv_blue);

    const root_surface = d.surfaceOf(d.root).?;
    const out = try gpa.alloc(u8, @as(usize, 640) * 480 * 4);
    defer gpa.free(out);
    try d.renderer.present(root_surface, out, 640, 480);

    // Source pixel 0x00112233 (b=0x33,g=0x22,r=0x11,a=0x00) inverted
    // per-channel, alpha passed through; writePx's byte order is
    // [b,g,r,a] (see render.zig's writePx/applyGamma).
    try std.testing.expectEqual(@as(u8, 0xCC), out[0]); // b: 0xff-0x33
    try std.testing.expectEqual(@as(u8, 0xDD), out[1]); // g: 0xff-0x22
    try std.testing.expectEqual(@as(u8, 0xEE), out[2]); // r: 0xff-0x11
    try std.testing.expectEqual(@as(u8, 0x00), out[3]); // a: passthrough
}

test "setCrtcTransform: real SoftwareRenderer through the Display seam resamples a present()d pattern" {
    // End-to-end (no mock): Display.setCrtcTransform -> renderer.setCrtcTransform
    // -> SoftwareRenderer.present() actually resamples through the matrix.
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    // A single marker pixel at source (2,0); everything else stays 0.
    try d.createGC(0x200, 0x12a, .{ .foreground = 0x00abcdef }, 1);
    try d.fillRect(d.root, 0x200, 2, 0, 1, 1);

    // 2x scale: dest(ox,oy) samples src(2*ox,2*oy).
    const scaled = [9]u32{ 0x00020000, 0, 0, 0, 0x00020000, 0, 0, 0, 0x00010000 };
    d.setCrtcTransform(scaled);

    const root_surface = d.surfaceOf(d.root).?;
    const out_w: u16 = 320;
    const out_h: u16 = 240;
    const out = try gpa.alloc(u8, @as(usize, out_w) * out_h * 4);
    defer gpa.free(out);
    try d.renderer.present(root_surface, out, out_w, out_h);

    // dest(1,0) -> src(2,0) -> the marker pixel.
    const off1 = (0 * @as(usize, out_w) + 1) * 4;
    try std.testing.expectEqual(@as(u8, 0xEF), out[off1 + 0]); // b
    try std.testing.expectEqual(@as(u8, 0xCD), out[off1 + 1]); // g
    try std.testing.expectEqual(@as(u8, 0xAB), out[off1 + 2]); // r
    // dest(0,0) -> src(0,0), untouched (stays 0).
    const off0 = (0 * @as(usize, out_w) + 0) * 4;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[off0..][0..4], .little));
}

/// A counting wrapper around a real Font8x8Provider, proving the injection
/// seam (`initWithFontProvider`) actually drives an injected FontProvider
/// rather than silently falling back to the default. openFont/glyph calls are
/// counted, then delegated to the wrapped Font8x8Provider so glyphs stay real
/// (imageText8/etc keep drawing through the wrapper).
const CountingFontProvider = struct {
    inner: fontprovider.Font8x8Provider = .{},
    open_font_count: usize = 0,
    close_font_count: usize = 0,
    glyph_count: usize = 0,

    pub fn provider(self: *CountingFontProvider) fontprovider.FontProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: fontprovider.FontProvider.VTable = .{
        .openFont = openFont,
        .closeFont = closeFont,
        .metrics = metrics,
        .glyph = glyph,
        .listNames = listNames,
    };

    fn openFont(ptr: *anyopaque, name: []const u8) ?fontprovider.FontRef {
        const self: *CountingFontProvider = @ptrCast(@alignCast(ptr));
        self.open_font_count += 1;
        return self.inner.provider().openFont(name);
    }
    fn closeFont(ptr: *anyopaque, ref: fontprovider.FontRef) void {
        const self: *CountingFontProvider = @ptrCast(@alignCast(ptr));
        self.close_font_count += 1;
        self.inner.provider().closeFont(ref);
    }
    fn metrics(ptr: *anyopaque, ref: fontprovider.FontRef) fontprovider.FontMetrics {
        const self: *CountingFontProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().metrics(ref);
    }
    fn glyph(ptr: *anyopaque, ref: fontprovider.FontRef, char: u32) fontprovider.Glyph {
        const self: *CountingFontProvider = @ptrCast(@alignCast(ptr));
        self.glyph_count += 1;
        return self.inner.provider().glyph(ref, char);
    }
    fn listNames(ptr: *anyopaque, pattern: []const u8) []const []const u8 {
        const self: *CountingFontProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().listNames(pattern);
    }
};

test "initWithFontProvider: injected font provider's vtable is actually driven (openFont/glyph counted, real glyph pixel)" {
    const gpa = std.testing.allocator;
    var counting: CountingFontProvider = .{};
    // owns_font_provider is false here: the test (not Display) owns `counting`.
    var d = try Display.initWithFontProvider(gpa, 0x12a, 24, 0x21, counting.provider());
    defer d.deinit();

    // initCommon's default_font = provider.openFont("fixed") already drove one call.
    try std.testing.expectEqual(@as(usize, 1), counting.open_font_count);

    try d.createWindow(0xA, 0x12a, .{ .width = 12, .height = 12, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.createGC(0x200, 0xA, .{ .foreground = 0x00AABBCC, .background = 0x00112233 }, 1);
    try d.openFont(0x300, "fixed", 1);
    try std.testing.expectEqual(@as(usize, 2), counting.open_font_count);

    try d.changeGC(0x200, .{ .font = 0x300 });
    try d.imageText8(0xA, 0x200, 2, 10, "H");
    try std.testing.expect(counting.glyph_count > 0);

    // The glyph actually landed through the wrapped provider: 'H' row0 SET
    // pixel (col0 -> x=2, y=2; top = baseline(10) - ascent(8) = 2) reads fg,
    // proving Display drives the INJECTED provider, not just the default.
    try std.testing.expectEqual(@as(u32, 0x00AABBCC), readbackPixel(&d, 0xA, 2, 2));
}

test "FontProvider: every opened ref is closed exactly once (no leak, no double-close)" {
    const gpa = std.testing.allocator;
    var counting: CountingFontProvider = .{};
    var d = try Display.initWithFontProvider(gpa, 0x12a, 24, 0x21, counting.provider());
    // Open three fonts; close one explicitly; the other two + default_font are
    // closed by deinit. Balance MUST be exact (a leak leaves opens>closes, a
    // double-close makes closes>opens). deinit is called explicitly (not defer)
    // so the counters can be inspected after teardown.
    try d.openFont(0x301, "fixed", 1);
    try d.openFont(0x302, "fixed", 1);
    try d.openFont(0x303, "fixed", 1);
    try d.closeFont(0x301);
    d.deinit();
    // 4 opens (default_font + 3) == 4 closes (1 explicit + default_font + 0x302 + 0x303).
    try std.testing.expectEqual(counting.open_font_count, counting.close_font_count);
    try std.testing.expectEqual(@as(usize, 4), counting.open_font_count);
}

test "SubstructureRedirect: mapWindow by another client is redirected to a MapRequest, stays unmapped" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const A: u32 = 1; // the WM
    const B: u32 = 2; // another client
    try d.changeAttributes(d.root, .{ .event_mask = substructure_redirect }, A);
    try d.createWindow(0xC, d.root, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, B);
    d.clearPending();
    try d.mapWindow(0xC, B);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.map_request, ev.kind);
    try std.testing.expectEqual(A, ev.target_client);
    try std.testing.expectEqual(d.root, ev.parent);
    try std.testing.expectEqual(@as(u32, 0xC), ev.window);
    // The redirected map did NOT apply: still unmapped.
    try std.testing.expectEqual(MapState.unmapped, (try d.getAttributes(0xC, B)).map_state);
}

test "SubstructureRedirect: the WM's own mapWindow executes (no re-intercept)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const A: u32 = 1;
    const B: u32 = 2;
    // A also selects SubstructureNotify on root so a real MapNotify is observable.
    try d.changeAttributes(d.root, .{ .event_mask = substructure_redirect | substructure_notify }, A);
    try d.createWindow(0xC, d.root, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, B);
    d.clearPending();
    try d.mapWindow(0xC, A); // the redirect holder maps it itself
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0xC, A)).map_state);
    var saw_map_request = false;
    var saw_map = false;
    for (d.pending.items) |ev| {
        if (ev.kind == .map_request) saw_map_request = true;
        if (ev.kind == .map) saw_map = true;
    }
    try std.testing.expect(!saw_map_request);
    try std.testing.expect(saw_map);
}

test "SubstructureRedirect: override_redirect children bypass redirect and map directly" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const A: u32 = 1;
    const B: u32 = 2;
    try d.changeAttributes(d.root, .{ .event_mask = substructure_redirect }, A);
    try d.createWindow(0xC2, d.root, .{ .width = 10, .height = 10 }, 1, 0x21, .{ .override_redirect = true }, B);
    d.clearPending();
    try d.mapWindow(0xC2, B);
    try std.testing.expectEqual(MapState.viewable, (try d.getAttributes(0xC2, B)).map_state);
    var saw_map_request = false;
    for (d.pending.items) |ev| if (ev.kind == .map_request) {
        saw_map_request = true;
    };
    try std.testing.expect(!saw_map_request);
}

test "SubstructureRedirect: configureWindow by another client is redirected to a ConfigureRequest, geom unchanged" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const A: u32 = 1;
    const B: u32 = 2;
    try d.changeAttributes(d.root, .{ .event_mask = substructure_redirect }, A);
    try d.createWindow(0xC, d.root, .{ .x = 3, .y = 4, .width = 10, .height = 10 }, 1, 0x21, .{}, B);
    d.clearPending();
    try d.configureWindow(0xC, .{ .width = 50, .height = 40 }, B);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.configure_request, ev.kind);
    try std.testing.expectEqual(A, ev.target_client);
    try std.testing.expectEqual(d.root, ev.parent);
    try std.testing.expectEqual(@as(u32, 0xC), ev.window);
    try std.testing.expectEqual(@as(u16, 4 | 8), ev.value_mask); // width|height
    try std.testing.expectEqual(@as(u16, 50), ev.width);
    try std.testing.expectEqual(@as(u16, 40), ev.height);
    // Unset fields carry the window's current geometry.
    try std.testing.expectEqual(@as(i16, 3), ev.x);
    try std.testing.expectEqual(@as(i16, 4), ev.y);
    // The redirected configure did NOT apply: geometry unchanged.
    const geom = try d.getGeometry(0xC);
    try std.testing.expectEqual(@as(u16, 10), geom.width);
    try std.testing.expectEqual(@as(u16, 10), geom.height);
}

test "SubstructureRedirect: the WM's own configureWindow applies directly" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const A: u32 = 1;
    const B: u32 = 2;
    // A also selects SubstructureNotify on root so a real ConfigureNotify is observable.
    try d.changeAttributes(d.root, .{ .event_mask = substructure_redirect | substructure_notify }, A);
    try d.createWindow(0xC, d.root, .{ .width = 10, .height = 10 }, 1, 0x21, .{}, B);
    d.clearPending();
    try d.configureWindow(0xC, .{ .width = 50 }, A); // the redirect holder configures it itself
    const geom = try d.getGeometry(0xC);
    try std.testing.expectEqual(@as(u16, 50), geom.width);
    var saw_configure_request = false;
    var saw_configure = false;
    for (d.pending.items) |ev| {
        if (ev.kind == .configure_request) saw_configure_request = true;
        if (ev.kind == .configure) saw_configure = true;
    }
    try std.testing.expect(!saw_configure_request);
    try std.testing.expect(saw_configure);
}

test "SubstructureRedirect: exclusive selection - a second holder gets BadAccess, same-client re-set is ok" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const A: u32 = 1;
    const B: u32 = 2;
    try d.changeAttributes(d.root, .{ .event_mask = substructure_redirect }, A);
    try std.testing.expectError(error.Access, d.changeAttributes(d.root, .{ .event_mask = substructure_redirect }, B));
    // The same client re-setting its own redirect selection is fine.
    try d.changeAttributes(d.root, .{ .event_mask = substructure_redirect }, A);
}

test "circulateWindow: RaiseLowest raises the lowest occluded child to top" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const client: u32 = 1;
    // P under root; A (bottom, created first) + B (top) under P, overlapping, both mapped.
    try d.createWindow(0x1000, d.root, .{ .width = 40, .height = 40, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0x1000, client);
    try d.createWindow(0xA, 0x1000, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, client);
    try d.createWindow(0xB, 0x1000, .{ .x = 5, .y = 5, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0xA, client);
    try d.mapWindow(0xB, client);
    try d.changeAttributes(0xA, .{ .event_mask = structure_notify }, client);
    try d.changeAttributes(0x1000, .{ .event_mask = substructure_notify }, client);
    d.clearPending();

    try d.circulateWindow(0x1000, 0, client); // RaiseLowest
    const t = try d.queryTree(0x1000);
    try std.testing.expectEqual(@as(u32, 0xA), t.children[t.children.len - 1]); // A raised to top

    var saw_child = false;
    var saw_parent = false;
    for (d.pending.items) |ev| {
        if (ev.kind != .circulate) continue;
        try std.testing.expectEqual(@as(u8, 0), ev.detail); // place = PlaceOnTop
        if (ev.event_window == 0xA and ev.window == 0xA) saw_child = true;
        if (ev.event_window == 0x1000 and ev.window == 0xA) saw_parent = true;
    }
    try std.testing.expect(saw_child);
    try std.testing.expect(saw_parent);
}

test "circulateWindow: LowerHighest lowers the highest occluding child to bottom" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const client: u32 = 1;
    try d.createWindow(0x1000, d.root, .{ .width = 40, .height = 40, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0x1000, client);
    try d.createWindow(0xA, 0x1000, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, client);
    try d.createWindow(0xB, 0x1000, .{ .x = 5, .y = 5, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0xA, client);
    try d.mapWindow(0xB, client);
    try d.changeAttributes(0xB, .{ .event_mask = structure_notify }, client);
    try d.changeAttributes(0x1000, .{ .event_mask = substructure_notify }, client);
    d.clearPending();

    try d.circulateWindow(0x1000, 1, client); // LowerHighest
    const t = try d.queryTree(0x1000);
    try std.testing.expectEqual(@as(u32, 0xB), t.children[0]); // B (highest, occludes A) lowered to bottom

    var saw = false;
    for (d.pending.items) |ev| {
        if (ev.kind == .circulate and ev.window == 0xB) {
            saw = true;
            try std.testing.expectEqual(@as(u8, 1), ev.detail); // place = PlaceOnBottom
        }
    }
    try std.testing.expect(saw);
}

test "circulateWindow: non-overlapping / single / no-mapped children is a no-op" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const client: u32 = 1;
    try d.createWindow(0x1000, d.root, .{ .width = 40, .height = 40, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0x1000, client);
    // Non-overlapping mapped children: no pick.
    try d.createWindow(0xA, 0x1000, .{ .x = 0, .y = 0, .width = 5, .height = 5, .depth = 24 }, 1, 0x21, .{}, client);
    try d.createWindow(0xB, 0x1000, .{ .x = 30, .y = 30, .width = 5, .height = 5, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0xA, client);
    try d.mapWindow(0xB, client);
    d.clearPending();
    try d.circulateWindow(0x1000, 0, client);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    const t = try d.queryTree(0x1000);
    try std.testing.expectEqual(@as(u32, 0xA), t.children[0]);
    try std.testing.expectEqual(@as(u32, 0xB), t.children[1]);

    // Single child: no-op.
    try d.createWindow(0x2000, d.root, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0x2000, client);
    try d.createWindow(0xC, 0x2000, .{ .width = 5, .height = 5, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0xC, client);
    d.clearPending();
    try d.circulateWindow(0x2000, 0, client);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);

    // No mapped children (overlapping but unmapped): no-op.
    try d.createWindow(0x3000, d.root, .{ .width = 40, .height = 40, .depth = 24 }, 1, 0x21, .{}, client);
    try d.mapWindow(0x3000, client);
    try d.createWindow(0xD, 0x3000, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, client);
    try d.createWindow(0xE, 0x3000, .{ .x = 5, .y = 5, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, client); // overlaps D, both stay unmapped
    d.clearPending();
    try d.circulateWindow(0x3000, 0, client);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "circulateWindow: BadValue on direction > 1; NoWindow on a missing window" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const client: u32 = 1;
    try d.createWindow(0x1000, d.root, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, client);
    try std.testing.expectError(error.BadValue, d.circulateWindow(0x1000, 2, client));
    try std.testing.expectError(error.NoWindow, d.circulateWindow(0xDEAD, 0, client));
}

test "circulateWindow: SubstructureRedirect sends CirculateRequest instead of restacking; the holder's own call restacks" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const X: u32 = 1; // the WM, holds SubstructureRedirect on P
    const Y: u32 = 2; // another client
    try d.createWindow(0x1000, d.root, .{ .width = 40, .height = 40, .depth = 24 }, 1, 0x21, .{}, X);
    try d.mapWindow(0x1000, X);
    // X also selects SubstructureNotify so its own restack's CirculateNotify is observable.
    try d.changeAttributes(0x1000, .{ .event_mask = substructure_redirect | substructure_notify }, X);
    try d.createWindow(0xA, 0x1000, .{ .x = 0, .y = 0, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, X);
    try d.createWindow(0xB, 0x1000, .{ .x = 5, .y = 5, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, X);
    try d.mapWindow(0xA, X);
    try d.mapWindow(0xB, X);
    d.clearPending();

    // Y's circulate is redirected to X: no restack, one CirculateRequest.
    try d.circulateWindow(0x1000, 0, Y);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    const ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.circulate_request, ev.kind);
    try std.testing.expectEqual(X, ev.target_client);
    try std.testing.expectEqual(@as(u32, 0x1000), ev.event_window);
    try std.testing.expectEqual(@as(u32, 0xA), ev.window); // the pick: lowest occluded child
    try std.testing.expectEqual(@as(u8, 0), ev.detail);
    const t = try d.queryTree(0x1000);
    try std.testing.expectEqual(@as(u32, 0xA), t.children[0]); // unchanged: A still bottommost
    try std.testing.expectEqual(@as(u32, 0xB), t.children[1]);

    // X's own circulate executes directly: a real restack, no CirculateRequest.
    d.clearPending();
    try d.circulateWindow(0x1000, 0, X);
    var saw_request = false;
    var saw_notify = false;
    for (d.pending.items) |pev| {
        if (pev.kind == .circulate_request) saw_request = true;
        if (pev.kind == .circulate) saw_notify = true;
    }
    try std.testing.expect(!saw_request);
    try std.testing.expect(saw_notify);
    const t2 = try d.queryTree(0x1000);
    try std.testing.expectEqual(@as(u32, 0xA), t2.children[t2.children.len - 1]); // A now raised to top
}

test "queryPointer: root position/mask readback, child hit-test, missing window" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // A at (10,10) 50x50, a mapped child of root.
    try d.createWindow(0xA, d.root, .{ .x = 10, .y = 10, .width = 50, .height = 50, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0xA, 1);

    // Default pointer state (0,0), no buttons/modifiers: over bare root.
    {
        const p = try d.queryPointer(d.root);
        try std.testing.expectEqual(d.pointer_x, p.root_x);
        try std.testing.expectEqual(d.pointer_y, p.root_y);
        try std.testing.expectEqual(@as(i16, 0), p.win_x); // root's drawable origin is (0,0)
        try std.testing.expectEqual(@as(i16, 0), p.win_y);
        try std.testing.expectEqual(d.input_state, p.mask);
        try std.testing.expectEqual(@as(u32, 0), p.child); // (0,0) is outside A
        try std.testing.expectEqual(d.root, p.root);
    }

    // Move the pointer over A and set a nonzero mask.
    d.pointer_x = 30;
    d.pointer_y = 30;
    d.input_state = 0x11;
    {
        const p = try d.queryPointer(d.root);
        try std.testing.expectEqual(@as(i16, 30), p.root_x);
        try std.testing.expectEqual(@as(i16, 30), p.root_y);
        try std.testing.expectEqual(@as(i16, 30), p.win_x); // root origin (0,0) -> win == root coords
        try std.testing.expectEqual(@as(i16, 30), p.win_y);
        try std.testing.expectEqual(@as(u16, 0x11), p.mask);
        try std.testing.expectEqual(@as(u32, 0xA), p.child); // (30,30) is inside A's 10..60 box
    }

    // QueryPointer(A): win_x/win_y are relative to A's drawable origin (10,10).
    {
        const p = try d.queryPointer(0xA);
        try std.testing.expectEqual(@as(i16, 20), p.win_x);
        try std.testing.expectEqual(@as(i16, 20), p.win_y);
        try std.testing.expectEqual(@as(u32, 0), p.child); // A has no children
    }

    try std.testing.expectError(error.NoWindow, d.queryPointer(0xDEAD));
}

test "translateCoordinates: parent+child chain, child hit-test, missing src/dst" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // P at (10,10) 100x100 under root; C at (5,5) 20x20 under P (root-abs 15,15..35,35).
    try d.createWindow(0x50, d.root, .{ .x = 10, .y = 10, .width = 100, .height = 100, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x50, 1);
    try d.createWindow(0x51, 0x50, .{ .x = 5, .y = 5, .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x51, 1);

    // A point 20,20 relative to root falls inside C: dst=P -> P-relative (10,10) + child == C.
    {
        const t = try d.translateCoordinates(d.root, 0x50, 20, 20);
        try std.testing.expectEqual(@as(i16, 10), t.dst_x);
        try std.testing.expectEqual(@as(i16, 10), t.dst_y);
        try std.testing.expectEqual(@as(u32, 0x51), t.child);
    }

    // Same point, dst=C directly: C-relative = point - (10+5) each axis; C has no children.
    {
        const t = try d.translateCoordinates(d.root, 0x51, 20, 20);
        try std.testing.expectEqual(@as(i16, 5), t.dst_x);
        try std.testing.expectEqual(@as(i16, 5), t.dst_y);
        try std.testing.expectEqual(@as(u32, 0), t.child);
    }

    // src == dst == root round-trips to the same point.
    {
        const t = try d.translateCoordinates(d.root, d.root, 42, 43);
        try std.testing.expectEqual(@as(i16, 42), t.dst_x);
        try std.testing.expectEqual(@as(i16, 43), t.dst_y);
    }

    try std.testing.expectError(error.NoWindow, d.translateCoordinates(0xDEAD, 0x50, 0, 0));
    try std.testing.expectError(error.NoWindow, d.translateCoordinates(0x50, 0xDEAD, 0, 0));
}

// --- SP-Server-4r: SetCloseDownMode retain/destroy split + KillClient -----

test "retainClient keeps a client's window/pixmap/gc (owner intact) but scrubs its masks + releases its grabs" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Client 1 owns a window + a pixmap + a gc, and holds an active pointer grab
    // plus a passive button grab. Client 2 selects StructureNotify on client 1's
    // window (must be scrubbed by retainClient).
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try d.createPixmap(0x20, 0x12a, 24, 8, 8, 1);
    try d.createGC(0x30, 0x12a, .{}, 1);
    try d.changeAttributes(0x10, .{ .event_mask = structure_notify }, 2);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));
    try d.grabButton(0x12a, button_press, false, 1, 0, mode_async, mode_async, 1);

    try d.retainClient(1, false); // RetainPermanent

    // Resources survive, still owned by client 1.
    _ = try d.getGeometry(0x10);
    try std.testing.expectEqual(@as(u32, 1), d.windows.get(0x10).?.owner);
    try std.testing.expect(d.pixmaps.contains(0x20));
    try std.testing.expectEqual(@as(u32, 1), d.pixmaps.get(0x20).?.owner);
    try std.testing.expect(d.gcs.contains(0x30));
    try std.testing.expectEqual(@as(u32, 1), d.gcs.get(0x30).?.owner);
    // Client 2's own selection on the window is untouched.
    try std.testing.expectEqual(@as(u32, 0), (try d.getAttributes(0x10, 1)).your_event_mask);
    // Client 1's grabs are gone (active + passive) -- nobody left to deliver to.
    try std.testing.expect(d.pointer_grab == null);
    try std.testing.expectEqual(@as(usize, 0), d.button_grabs.items.len);
    // RetainPermanent does NOT record the client for AllTemporary sweeping.
    try std.testing.expectEqual(@as(usize, 0), d.retained_temporary.items.len);
}

test "retainClient(temporary) records the client id; a later destroyClientResources tears it down" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 20, .height = 20, .depth = 24 }, 1, 0x21, .{}, 1);

    try d.retainClient(1, true); // RetainTemporary
    try std.testing.expectEqual(@as(usize, 1), d.retained_temporary.items.len);
    try std.testing.expectEqual(@as(u32, 1), d.retained_temporary.items[0]);
    _ = try d.getGeometry(0x10); // still alive after retain

    try d.destroyClientResources(1);
    try std.testing.expectError(error.NoWindow, d.getGeometry(0x10));
}

test "killTemporary sweeps every RetainTemporary-recorded client and clears the list" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.createWindow(0x11, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, 2);
    try d.createWindow(0x12, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, 3);
    try d.retainClient(1, true); // RetainTemporary
    try d.retainClient(2, false); // RetainPermanent -- must survive killTemporary
    try std.testing.expectEqual(@as(usize, 1), d.retained_temporary.items.len);

    try d.killTemporary();

    try std.testing.expectError(error.NoWindow, d.getGeometry(0x10)); // swept
    _ = try d.getGeometry(0x11); // RetainPermanent survives AllTemporary
    _ = try d.getGeometry(0x12); // client 3 was never retained/disconnected at all
    try std.testing.expectEqual(@as(usize, 0), d.retained_temporary.items.len);
}

test "ownerOf resolves a window/pixmap/gc/font id to its owner, and null for a bogus id" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, 5);
    try d.createPixmap(0x20, 0x12a, 24, 4, 4, 6);
    try d.createGC(0x30, 0x12a, .{}, 7);
    try d.openFont(0x40, "fixed", 8);

    try std.testing.expectEqual(@as(?u32, 5), d.ownerOf(0x10));
    try std.testing.expectEqual(@as(?u32, 6), d.ownerOf(0x20));
    try std.testing.expectEqual(@as(?u32, 7), d.ownerOf(0x30));
    try std.testing.expectEqual(@as(?u32, 8), d.ownerOf(0x40));
    try std.testing.expectEqual(@as(?u32, null), d.ownerOf(0xDEAD));
}

test "cleanupClient (DestroyAll) still fully destroys owned resources -- unchanged after the retain/destroy split" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createWindow(0x10, 0x12a, .{ .width = 10, .height = 10, .depth = 24 }, 1, 0x21, .{}, 1);
    try d.mapWindow(0x10, 1);
    try d.createPixmap(0x20, 0x12a, 24, 4, 4, 1);
    try d.createGC(0x30, 0x12a, .{}, 1);
    try std.testing.expectEqual(@as(u8, 0), d.grabPointer(0x10, pointer_motion, false, mode_async, mode_async, 1));

    try d.cleanupClient(1);

    try std.testing.expectError(error.NoWindow, d.getGeometry(0x10));
    try std.testing.expect(!d.pixmaps.contains(0x20));
    try std.testing.expect(!d.gcs.contains(0x30));
    try std.testing.expect(d.pointer_grab == null);
    // DestroyAll never touches retained_temporary (that's a Retain*-only concept).
    try std.testing.expectEqual(@as(usize, 0), d.retained_temporary.items.len);
}

test "default colormap 0x25 is pre-registered + installed at init" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try std.testing.expect(d.colormaps.contains(Display.default_colormap));
    try std.testing.expectEqual(@as(u32, 0), d.colormaps.get(Display.default_colormap).?.owner);
    try std.testing.expectEqual(@as(u32, 0x21), d.colormaps.get(Display.default_colormap).?.visual);
    const installed = try d.listInstalledColormaps(0x12a);
    try std.testing.expectEqual(@as(usize, 1), installed.len);
    try std.testing.expectEqual(Display.default_colormap, installed[0]);
}

test "createColormap: ok, alloc>1 -> BadValue, mid collision -> IdInUse, missing window -> NoWindow" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try d.createColormap(0x50, d.root, 0x21, 0, 1);
    try std.testing.expect(d.colormaps.contains(0x50));
    try std.testing.expectEqual(@as(u32, 1), d.colormaps.get(0x50).?.owner);

    try std.testing.expectError(error.BadValue, d.createColormap(0x51, d.root, 0x21, 2, 1));
    // Colliding with a live window id (the root) -- shared id namespace.
    try std.testing.expectError(error.IdInUse, d.createColormap(d.root, d.root, 0x21, 0, 1));
    try std.testing.expectError(error.NoWindow, d.createColormap(0x52, 0xDEAD, 0x21, 0, 1));
}

test "allocColor: TrueColor pixel packing + 8-to-16 quantized readback" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const c = try d.allocColor(Display.default_colormap, 0xffff, 0x8000, 0x0000);
    try std.testing.expectEqual(@as(u32, 0xff8000), c.pixel);
    try std.testing.expectEqual(@as(u16, 0xffff), c.red);
    try std.testing.expectEqual(@as(u16, 0x8080), c.green);
    try std.testing.expectEqual(@as(u16, 0), c.blue);
}

test "allocColor on a non-colormap id -> BadColor" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try std.testing.expectError(error.BadColor, d.allocColor(0xDEAD, 0, 0, 0));
}

test "installColormap/uninstallColormap track the installed set" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createColormap(0x50, d.root, 0x21, 0, 1);

    // Not yet installed.
    var installed = try d.listInstalledColormaps(d.root);
    try std.testing.expectEqual(@as(usize, 1), installed.len); // just the default

    try d.installColormap(0x50);
    installed = try d.listInstalledColormaps(d.root);
    try std.testing.expectEqual(@as(usize, 2), installed.len);
    try std.testing.expect(d.installed_colormaps.items[1] == 0x50);

    // Idempotent: installing again does not duplicate.
    try d.installColormap(0x50);
    installed = try d.listInstalledColormaps(d.root);
    try std.testing.expectEqual(@as(usize, 2), installed.len);

    try d.uninstallColormap(0x50);
    installed = try d.listInstalledColormaps(d.root);
    try std.testing.expectEqual(@as(usize, 1), installed.len);
    try std.testing.expectEqual(Display.default_colormap, installed[0]);
}

test "freeColormap removes it (+ uninstalls); free non-colormap -> BadColor" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createColormap(0x50, d.root, 0x21, 0, 1);
    try d.installColormap(0x50);

    try d.freeColormap(0x50);
    try std.testing.expect(!d.colormaps.contains(0x50));
    const installed = try d.listInstalledColormaps(d.root);
    try std.testing.expectEqual(@as(usize, 1), installed.len); // just the default survives

    try std.testing.expectError(error.BadColor, d.freeColormap(0x50));
}

test "freeColors validates the colormap (BadColor on a bad id) and is otherwise a no-op" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try d.freeColors(Display.default_colormap); // no-op, must not error
    try std.testing.expectError(error.BadColor, d.freeColors(0xDEAD));
}

test "idInUse sees a colormap id" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createColormap(0x50, d.root, 0x21, 0, 1);

    try std.testing.expect(d.idInUse(0x50));
    try std.testing.expect(d.idInUse(Display.default_colormap));
}

test "destroyClientResources frees a client's colormaps; the default (owner 0) survives" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.createColormap(0x50, d.root, 0x21, 0, 1);
    try d.installColormap(0x50);

    try d.cleanupClient(1);

    try std.testing.expect(!d.colormaps.contains(0x50));
    try std.testing.expect(d.colormaps.contains(Display.default_colormap));
    const installed = try d.listInstalledColormaps(d.root);
    try std.testing.expectEqual(@as(usize, 1), installed.len);
    try std.testing.expectEqual(Display.default_colormap, installed[0]);
}

test "lookupColorName is case-insensitive; unknown name -> null" {
    const red_lower = Display.lookupColorName("red").?;
    const red_upper = Display.lookupColorName("RED").?;
    const red_mixed = Display.lookupColorName("Red").?;
    try std.testing.expectEqual(@as(u8, 255), red_lower.r8);
    try std.testing.expectEqual(@as(u8, 0), red_lower.g8);
    try std.testing.expectEqual(@as(u8, 0), red_lower.b8);
    try std.testing.expectEqual(red_lower, red_upper);
    try std.testing.expectEqual(red_lower, red_mixed);

    try std.testing.expect(Display.lookupColorName("bogus") == null);
}

test "lookupColor: exact/visual match the name db, non-colormap -> BadColor, unknown name -> BadName" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const lr = try d.lookupColor(Display.default_colormap, "blue");
    try std.testing.expectEqual(Display.RgbColor{ .red = 0, .green = 0, .blue = 0xffff }, lr.exact);
    try std.testing.expectEqual(Display.RgbColor{ .red = 0, .green = 0, .blue = 0xffff }, lr.visual);

    try std.testing.expectError(error.BadColor, d.lookupColor(0xDEAD, "blue"));
    try std.testing.expectError(error.BadName, d.lookupColor(Display.default_colormap, "nope"));
}

test "allocNamedColor packs a TrueColor pixel from the name db" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const r = try d.allocNamedColor(Display.default_colormap, "green");
    try std.testing.expectEqual(@as(u32, 0x00ff00), r.pixel);
    try std.testing.expectEqual(Display.RgbColor{ .red = 0, .green = 0xffff, .blue = 0 }, r.exact);
    try std.testing.expectEqual(Display.RgbColor{ .red = 0, .green = 0xffff, .blue = 0 }, r.visual);
}

test "unpackColor reverses the TrueColor pack (8-bit expanded)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const rgb = d.unpackColor(0xff8000);
    try std.testing.expectEqual(Display.RgbColor{ .red = 0xffff, .green = 0x8080, .blue = 0x0000 }, rgb);
}

test "allocColorCells/allocColorPlanes: BadAlloc on a read-only TrueColor visual, BadColor first" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try std.testing.expectError(error.BadAlloc, d.allocColorCells(Display.default_colormap));
    try std.testing.expectError(error.BadAlloc, d.allocColorPlanes(Display.default_colormap));
    try std.testing.expectError(error.BadColor, d.allocColorCells(0xDEAD));
    try std.testing.expectError(error.BadColor, d.allocColorPlanes(0xDEAD));
}

test "storeColors/storeNamedColor: BadAccess on a read-only colormap, BadColor first" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try std.testing.expectError(error.BadAccess, d.storeColors(Display.default_colormap));
    try std.testing.expectError(error.BadAccess, d.storeNamedColor(Display.default_colormap));
    try std.testing.expectError(error.BadColor, d.storeColors(0xDEAD));
    try std.testing.expectError(error.BadColor, d.storeNamedColor(0xDEAD));
}

test "copyColormapAndFree: copies the visual + frees src; non-colormap -> BadColor; mid collision -> IdInUse" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    // Use a client-created colormap as src (NOT the default) so the default
    // survives for any test sharing this Display.
    try d.createColormap(0x50, d.root, 0x21, 0, 1);

    try d.copyColormapAndFree(0x60, 0x50, 2);
    try std.testing.expect(d.colormaps.contains(0x60));
    try std.testing.expectEqual(@as(u32, 2), d.colormaps.get(0x60).?.owner);
    try std.testing.expectEqual(@as(u32, 0x21), d.colormaps.get(0x60).?.visual);
    try std.testing.expect(!d.colormaps.contains(0x50)); // src freed

    try std.testing.expectError(error.BadColor, d.copyColormapAndFree(0x61, 0xDEAD, 2));

    try d.createColormap(0x70, d.root, 0x21, 0, 1);
    try std.testing.expectError(error.IdInUse, d.copyColormapAndFree(0x70, 0x60, 2)); // mid already in use
}

test "extensionByName/extensionByMajor: XC-MISC and BIG-REQUESTS found, bogus lookups null" {
    const xcmisc = extensionByName("XC-MISC") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 129), xcmisc.major_opcode);
    const bigreq = extensionByName("BIG-REQUESTS") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 128), bigreq.major_opcode);
    try std.testing.expectEqual(@as(?ExtensionInfo, null), extensionByName("BOGUS"));

    try std.testing.expect(extensionByMajor(129) != null);
    try std.testing.expect(extensionByMajor(128) != null);
    try std.testing.expectEqual(@as(?ExtensionInfo, null), extensionByMajor(200));
}

test "extensionByName/extensionByMajor: RANDR at major 130, first_event 64, first_error 128" {
    const randr_ext = extensionByName("RANDR") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 130), randr_ext.major_opcode);
    try std.testing.expectEqual(@as(u8, 64), randr_ext.first_event);
    try std.testing.expectEqual(@as(u8, 128), randr_ext.first_error);

    const by_major = extensionByMajor(130) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("RANDR", by_major.name);
}

test "allocXidRange: successive ranges are non-overlapping, in the high space, never a client id" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const r0 = d.allocXidRange(16);
    const r1 = d.allocXidRange(32);
    try std.testing.expectEqual(@as(u32, 0x70000000), r0.start);
    try std.testing.expectEqual(@as(u32, 16), r0.count);
    // r1 starts exactly where r0 left off -- disjoint, no gaps, no overlap.
    try std.testing.expectEqual(r0.start + r0.count, r1.start);
    try std.testing.expectEqual(@as(u32, 32), r1.count);

    // Every id in both ranges sits in the dispenser's high space, well above
    // any realistic client resource-id range (base 0x00400000, step
    // 0x00200000 -- see server_loop.resourceRangeForIndex).
    try std.testing.expect(r0.start >= 0x70000000);
    try std.testing.expect(r1.start >= 0x70000000);
    try std.testing.expect(r0.start != d.root);
}

test "randrScreenSize: tracks the root window's own geom (single source of truth)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    // Display.init leaves the root at its initCommon default (640x480);
    // configureWindow is a deliberate no-op on the root (see configureWindow),
    // so the only way to move the root to a real display size is to poke its
    // geom directly -- exactly what a future SetScreenSize would do.
    const root_w = d.windows.getPtr(d.root).?;
    root_w.geom.width = 1920;
    root_w.geom.height = 1080;

    const size = d.randrScreenSize();
    try std.testing.expectEqual(@as(u16, 1920), size.w);
    try std.testing.expectEqual(@as(u16, 1080), size.h);
}

test "randrMm: 96 DPI conversion" {
    try std.testing.expectEqual(@as(u32, 508), Display.randrMm(1920));
    try std.testing.expectEqual(@as(u32, 286), Display.randrMm(1080));
    try std.testing.expectEqual(@as(u32, 0), Display.randrMm(0));
}

test "randrModeById: current mode resolves to the live root size, alt modes resolve fixed, unknown id is null" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    // Display.init leaves the root at the initCommon default (640x480).
    const current = d.randrModeById(d.randr.mode).?;
    try std.testing.expectEqual(d.randr.mode, current.id);
    try std.testing.expectEqual(@as(u16, 640), current.width);
    try std.testing.expectEqual(@as(u16, 480), current.height);

    const alt = d.randrModeById(0xf0001004).?;
    try std.testing.expectEqual(@as(u32, 0xf0001004), alt.id);
    try std.testing.expectEqual(@as(u16, 1920), alt.width);
    try std.testing.expectEqual(@as(u16, 1080), alt.height);

    try std.testing.expectEqual(@as(?RandrMode, null), d.randrModeById(0xdead));
}

test "randrModeList: 6 entries, index 0 tracks the live root size, 1.. are the fixed alt modes in order" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const root_w = d.windows.getPtr(d.root).?;
    root_w.geom.width = 1024;
    root_w.geom.height = 768;

    var buf: [max_mode_count]RandrMode = undefined;
    const list = d.randrModeList(&buf);
    try std.testing.expectEqual(@as(usize, 6), list.len);
    try std.testing.expectEqual(d.randr.mode, list[0].id);
    try std.testing.expectEqual(@as(u16, 1024), list[0].width);
    try std.testing.expectEqual(@as(u16, 768), list[0].height);
    for (randr_alt_modes, 0..) |m, i| {
        try std.testing.expectEqual(m.id, list[i + 1].id);
        try std.testing.expectEqual(m.width, list[i + 1].width);
        try std.testing.expectEqual(m.height, list[i + 1].height);
    }
}

test "gammaRamps: defaults to a linear 256-entry ramp on every channel" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const g = d.gammaRamps();
    try std.testing.expectEqual(@as(u16, 256), g.size);
    try std.testing.expectEqual(@as(usize, 256), g.red.len);
    try std.testing.expectEqual(@as(u16, 0), g.red[0]);
    try std.testing.expectEqual(@as(u16, 65535), g.red[255]);
    try std.testing.expectEqual(@as(u16, 0), g.green[0]);
    try std.testing.expectEqual(@as(u16, 65535), g.blue[255]);
}

test "setCrtcGamma: round-trips a marker value through gammaRamps" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    var red: [256]u16 = undefined;
    var green: [256]u16 = undefined;
    var blue: [256]u16 = undefined;
    for (0..256) |i| {
        red[i] = @intCast(@as(u32, @intCast(i)) * 65535 / 255);
        green[i] = red[i];
        blue[i] = red[i];
    }
    red[1] = 0x1234; // marker

    try d.setCrtcGamma(256, &red, &green, &blue);

    const g = d.gammaRamps();
    try std.testing.expectEqual(@as(u16, 256), g.size);
    try std.testing.expectEqual(@as(u16, 0x1234), g.red[1]);
    try std.testing.expectEqual(@as(u16, red[2]), g.red[2]);
}

test "setCrtcTransform: defaults to identity, stores a non-identity matrix" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try std.testing.expectEqual(identity_transform, d.randr_transform);

    const scaled = [9]u32{ 0x00020000, 0, 0, 0, 0x00020000, 0, 0, 0, 0x00010000 };
    d.setCrtcTransform(scaled);
    try std.testing.expectEqual(scaled, d.randr_transform);
}

test "setCrtcGamma: size > 256 is BadValue, leaves the stored ramp untouched" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    var red: [1]u16 = .{0x9999};
    try std.testing.expectError(error.BadValue, d.setCrtcGamma(257, &red, &red, &red));

    // Untouched: still the default linear ramp.
    const g = d.gammaRamps();
    try std.testing.expectEqual(@as(u16, 256), g.size);
    try std.testing.expectEqual(@as(u16, 0), g.red[0]);
}

test "setCrtcGamma: size != 256 (even if smaller) is BadValue and never shrinks gamma_size" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    var red: [128]u16 = undefined;
    for (0..128) |i| red[i] = @intCast(i);

    // The gamma ramp length is a fixed hardware property -- a smaller size
    // must be rejected outright, not accepted as a "shrink" of gamma_size.
    try std.testing.expectError(error.BadValue, d.setCrtcGamma(128, &red, &red, &red));

    // GetCrtcGammaSize must still report the fixed 256, never 128.
    const g = d.gammaRamps();
    try std.testing.expectEqual(@as(u16, 256), g.size);
    try std.testing.expectEqual(@as(u16, 0), g.red[0]);
}

test "seedEdid: the EDID atom is listed on the output, 128 bytes, format 8, header + valid checksum" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    const edid_atom = try d.atoms.intern(gpa, "EDID", true); // only_if_exists: must already be interned by seedEdid
    try std.testing.expect(edid_atom != 0);

    const atoms = try d.outputListProperties(d.randr.output);
    defer gpa.free(atoms);
    var found = false;
    for (atoms) |a| {
        if (a == edid_atom) found = true;
    }
    try std.testing.expect(found);

    const g = try d.outputGetProperty(d.randr.output, edid_atom, 0, 0, 32, false);
    try std.testing.expect(g.found);
    try std.testing.expectEqual(@as(u8, 8), g.format);
    try std.testing.expectEqual(@as(u32, 19), g.type); // XA_INTEGER
    try std.testing.expectEqual(@as(usize, 128), g.value.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 }, g.value[0..8]);

    // Checksum: the full 128-byte blob sums to 0 mod 256.
    var sum: u32 = 0;
    for (g.value) |b| sum += b;
    try std.testing.expectEqual(@as(u32, 0), sum % 256);
}

test "output properties: change/get round-trip, append/prepend, delete, bad output, bad atom" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const output = d.randr.output;
    const prop = try d.atoms.intern(gpa, "TESTPROP", false);
    const str = try d.atoms.intern(gpa, "STRING", false);

    try d.outputChangeProperty(output, prop, str, 8, 0, "hi", 1); // Replace
    var g = try d.outputGetProperty(output, prop, 0, 0, 100, false);
    try std.testing.expect(g.found);
    try std.testing.expectEqual(str, g.type);
    try std.testing.expectEqual(@as(u8, 8), g.format);
    try std.testing.expectEqualStrings("hi", g.value);

    try d.outputChangeProperty(output, prop, str, 8, 2, "!!", 1); // Append -> "hi!!"
    g = try d.outputGetProperty(output, prop, 0, 0, 100, false);
    try std.testing.expectEqualStrings("hi!!", g.value);

    try d.outputChangeProperty(output, prop, str, 8, 1, ">>", 1); // Prepend -> ">>hi!!"
    g = try d.outputGetProperty(output, prop, 0, 0, 100, false);
    try std.testing.expectEqualStrings(">>hi!!", g.value);

    // delete via GetOutputProperty(delete=true) once fully read.
    g = try d.outputGetProperty(output, prop, 0, 0, 100, true);
    try std.testing.expect(g.found);
    const g2 = try d.outputGetProperty(output, prop, 0, 0, 100, false);
    try std.testing.expect(!g2.found);

    // outputDeleteProperty on an already-gone prop is a silent no-op.
    try d.outputDeleteProperty(output, prop);

    // bad output -> BadOutput, on every method.
    try std.testing.expectError(error.BadOutput, d.outputChangeProperty(output + 1, prop, str, 8, 0, "x", 1));
    try std.testing.expectError(error.BadOutput, d.outputGetProperty(output + 1, prop, 0, 0, 1, false));
    try std.testing.expectError(error.BadOutput, d.outputDeleteProperty(output + 1, prop));
    try std.testing.expectError(error.BadOutput, d.outputListProperties(output + 1));

    // bad atom -> BadAtom.
    try std.testing.expectError(error.BadAtom, d.outputChangeProperty(output, 9999, str, 8, 0, "x", 1));
    try std.testing.expectError(error.BadAtom, d.outputGetProperty(output, 9999, 0, 0, 1, false));
    try std.testing.expectError(error.BadAtom, d.outputDeleteProperty(output, 9999));
}

test "outputChangeProperty: no leak on repeated Replace/Append/Prepend + Display.deinit (testing allocator)" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit(); // must free the EDID seed + every prop below with no leak
    const output = d.randr.output;
    const prop = try d.atoms.intern(gpa, "LEAKCHECK", false);
    const str = try d.atoms.intern(gpa, "STRING", false);
    try d.outputChangeProperty(output, prop, str, 8, 0, "a", 1);
    try d.outputChangeProperty(output, prop, str, 8, 2, "b", 1);
    try d.outputChangeProperty(output, prop, str, 8, 1, "c", 1);
    try d.outputChangeProperty(output, prop, str, 8, 0, "replaced", 1); // Replace frees the old buffer
}

test "outputChangeProperty/outputDeleteProperty: record randr_output_property to OutputProperty(0x8) selectors only" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const output = d.randr.output;
    const prop = try d.atoms.intern(gpa, "EVPROP", false);
    const str = try d.atoms.intern(gpa, "STRING", false);

    try d.randrSelectInput(1, d.root, 0x8); // client 1: OutputProperty
    try d.randrSelectInput(2, d.root, 0x1); // client 2: ScreenChange only -- must get NOTHING

    // A successful ChangeOutputProperty records exactly one event, to client 1
    // only, kind randr_output_property, state 0 (NewValue).
    try d.outputChangeProperty(output, prop, str, 8, 0, "x", 1);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    var ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.randr_output_property, ev.kind);
    try std.testing.expectEqual(@as(u32, 1), ev.target_client);
    try std.testing.expectEqual(d.root, ev.window);
    try std.testing.expectEqual(output, ev.randr.output);
    try std.testing.expectEqual(prop, ev.randr.atom);
    try std.testing.expectEqual(@as(u8, 0), ev.randr.state); // NewValue
    d.clearPending();

    // A successful DeleteOutputProperty likewise records exactly one event,
    // state 1 (Deleted).
    try d.outputDeleteProperty(output, prop);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.randr_output_property, ev.kind);
    try std.testing.expectEqual(@as(u32, 1), ev.target_client);
    try std.testing.expectEqual(output, ev.randr.output);
    try std.testing.expectEqual(prop, ev.randr.atom);
    try std.testing.expectEqual(@as(u8, 1), ev.randr.state); // Deleted
    d.clearPending();

    // A repeat delete on an already-gone prop is a silent no-op: no event,
    // no error (mirrors outputDeleteProperty's existing no-op behavior).
    try d.outputDeleteProperty(output, prop);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
}

test "randrSelectInput: records + replaces per (client,window), scrubbed on client disconnect" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try d.randrSelectInput(1, d.root, 0x1);
    try std.testing.expectEqual(@as(usize, 1), d.randr_event_masks.items.len);
    try std.testing.expectEqual(@as(u16, 0x1), d.randr_event_masks.items[0].mask);

    // A second SelectInput from the same client on the same window replaces
    // (not appends) the mask.
    try d.randrSelectInput(1, d.root, 0x3);
    try std.testing.expectEqual(@as(usize, 1), d.randr_event_masks.items.len);
    try std.testing.expectEqual(@as(u16, 0x3), d.randr_event_masks.items[0].mask);

    // A different client's registration is a distinct entry.
    try d.randrSelectInput(2, d.root, 0x1);
    try std.testing.expectEqual(@as(usize, 2), d.randr_event_masks.items.len);

    // Disconnect scrubs only that client's entry.
    try d.cleanupClient(1);
    try std.testing.expectEqual(@as(usize, 1), d.randr_event_masks.items.len);
    try std.testing.expectEqual(@as(u32, 2), d.randr_event_masks.items[0].client);
}

test "recordRandrEvent: fans out only to clients whose registered mask includes the event bit" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try d.randrSelectInput(1, d.root, 0x1); // client 1: ScreenChange only
    try d.randrSelectInput(2, d.root, 0x3); // client 2: ScreenChange + CrtcChange
    try d.randrSelectInput(3, d.root, 0x0); // client 3: nothing selected

    // ScreenChange (bit 0x1): clients 1 and 2 both have it set, client 3 doesn't.
    try d.recordRandrEvent(0x1, .randr_screen_change, .{ .rotation = 1, .config_timestamp = 5 }, 1024, 768, 0, 0, d.root, 42);
    try std.testing.expectEqual(@as(usize, 2), d.pending.items.len);
    try std.testing.expectEqual(@as(u32, 1), d.pending.items[0].target_client);
    try std.testing.expectEqual(@as(u32, 2), d.pending.items[1].target_client);
    for (d.pending.items) |ev| {
        try std.testing.expectEqual(EventKind.randr_screen_change, ev.kind);
        try std.testing.expectEqual(d.root, ev.event_window);
        try std.testing.expectEqual(d.root, ev.window);
        try std.testing.expectEqual(@as(u16, 1024), ev.width);
        try std.testing.expectEqual(@as(u16, 768), ev.height);
        try std.testing.expectEqual(@as(u32, 42), ev.time);
        try std.testing.expectEqual(@as(u32, 5), ev.randr.config_timestamp);
    }
    d.clearPending();

    // CrtcChange (bit 0x2): only client 2 has that bit set.
    try d.recordRandrEvent(0x2, .randr_crtc_change, .{ .crtc = 0xf0000001, .mode = 0xf0001004 }, 1920, 1080, 0, 0, d.root, 43);
    try std.testing.expectEqual(@as(usize, 1), d.pending.items.len);
    try std.testing.expectEqual(@as(u32, 2), d.pending.items[0].target_client);
    try std.testing.expectEqual(EventKind.randr_crtc_change, d.pending.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0xf0000001), d.pending.items[0].randr.crtc);
    try std.testing.expectEqual(@as(u32, 0xf0001004), d.pending.items[0].randr.mode);
    d.clearPending();

    // A mask of 0 (client 3) never matches any nonzero event_bit.
    try d.recordRandrEvent(0x1, .randr_screen_change, .{}, 640, 480, 0, 0, d.root, 44);
    for (d.pending.items) |ev| try std.testing.expect(ev.target_client != 3);
}

test "resizeRoot: changes root geom + surface size, emits ConfigureNotify + both RANDR events in order, bumps the timestamp" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    // Client 2 selects core StructureNotify on the root; client 3 selects
    // RANDR ScreenChange+CrtcChange on the root.
    try d.changeAttributes(d.root, .{ .event_mask = structure_notify }, 2);
    try d.randrSelectInput(3, d.root, 0x3);
    d.clearPending();

    const before_ts = d.randr.timestamp;
    try d.resizeRoot(1024, 768, 271, 203, 0x77);

    // Root geom + backing surface both moved to the new size.
    const root_w = d.windows.getPtr(d.root).?;
    try std.testing.expectEqual(@as(u16, 1024), root_w.geom.width);
    try std.testing.expectEqual(@as(u16, 768), root_w.geom.height);
    try std.testing.expectEqual(@as(u16, 1024), root_w.surface.width);
    try std.testing.expectEqual(@as(u16, 768), root_w.surface.height);
    try std.testing.expectEqual(d.randr.timestamp, before_ts +% 1); // bumped exactly once

    // Exactly 3 events recorded, IN ORDER: core configure, then the two RANDR events.
    try std.testing.expectEqual(@as(usize, 3), d.pending.items.len);

    const configure_ev = d.pending.items[0];
    try std.testing.expectEqual(EventKind.configure, configure_ev.kind);
    try std.testing.expectEqual(@as(u32, 2), configure_ev.target_client);
    try std.testing.expectEqual(d.root, configure_ev.window);
    try std.testing.expectEqual(@as(u16, 1024), configure_ev.width);
    try std.testing.expectEqual(@as(u16, 768), configure_ev.height);

    const screen_change_ev = d.pending.items[1];
    try std.testing.expectEqual(EventKind.randr_screen_change, screen_change_ev.kind);
    try std.testing.expectEqual(@as(u32, 3), screen_change_ev.target_client);
    try std.testing.expectEqual(@as(u16, 1024), screen_change_ev.width);
    try std.testing.expectEqual(@as(u16, 768), screen_change_ev.height);
    try std.testing.expectEqual(@as(u32, 0x77), screen_change_ev.randr.request_window);
    try std.testing.expectEqual(@as(u16, 271), screen_change_ev.randr.mwidth);
    try std.testing.expectEqual(@as(u16, 203), screen_change_ev.randr.mheight);
    try std.testing.expectEqual(d.randr.timestamp, screen_change_ev.randr.config_timestamp);

    const crtc_change_ev = d.pending.items[2];
    try std.testing.expectEqual(EventKind.randr_crtc_change, crtc_change_ev.kind);
    try std.testing.expectEqual(@as(u32, 3), crtc_change_ev.target_client);
    try std.testing.expectEqual(@as(u16, 1024), crtc_change_ev.width);
    try std.testing.expectEqual(@as(u16, 768), crtc_change_ev.height);
    try std.testing.expectEqual(d.randr.crtc, crtc_change_ev.randr.crtc);
    try std.testing.expectEqual(d.randr.mode, crtc_change_ev.randr.mode);
}

test "resizeRoot: a same-size resize is a genuine no-op -- no state change, no events" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.changeAttributes(d.root, .{ .event_mask = structure_notify }, 2);
    try d.randrSelectInput(3, d.root, 0x3);
    d.clearPending();
    const before_ts = d.randr.timestamp;

    try d.resizeRoot(640, 480, 169, 127, 0); // initCommon's default root size
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);
    try std.testing.expectEqual(before_ts, d.randr.timestamp); // untouched
}

test "resizeRoot: clamps an out-of-range size to RANDR's advertised bounds" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();

    try d.resizeRoot(0, 65535, 0, 0, 0); // 0 clamps up to min, 65535 (u16 max) clamps down to max_screen_dim
    const root_w = d.windows.getPtr(d.root).?;
    try std.testing.expectEqual(randr.min_screen_dim, root_w.geom.width);
    try std.testing.expectEqual(randr.max_screen_dim, root_w.geom.height);
}

test "resizeRoot: rejects a size whose allocation would exceed max_pixmap_bytes, mutating nothing; a size within the cap still succeeds" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.changeAttributes(d.root, .{ .event_mask = structure_notify }, 2);
    try d.randrSelectInput(3, d.root, 0x3);
    d.clearPending();
    const before_ts = d.randr.timestamp;
    const before_w = d.windows.getPtr(d.root).?.geom.width;
    const before_h = d.windows.getPtr(d.root).?.geom.height;
    const before_surf_w = d.windows.getPtr(d.root).?.surface.width;
    const before_surf_h = d.windows.getPtr(d.root).?.surface.height;

    // 16384x16384 depth-24 (4 bytes/px) is ~1 GiB, way past the 64 MiB
    // default max_pixmap_bytes -- same DoS RANDR's own [1,16384] clamp does
    // NOT stop (only configureWindow's resize path capped the bytes, until
    // now).
    try std.testing.expectError(error.TooLarge, d.resizeRoot(16384, 16384, 0, 0, 0));

    // Rejected BEFORE any mutation: geom, surface, timestamp, and pending
    // events are all untouched.
    const root_w = d.windows.getPtr(d.root).?;
    try std.testing.expectEqual(before_w, root_w.geom.width);
    try std.testing.expectEqual(before_h, root_w.geom.height);
    try std.testing.expectEqual(before_surf_w, root_w.surface.width);
    try std.testing.expectEqual(before_surf_h, root_w.surface.height);
    try std.testing.expectEqual(before_ts, d.randr.timestamp);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);

    // A resize within the cap (1024x768x4 =~ 3 MiB) still goes through.
    try d.resizeRoot(1024, 768, 0, 0, 0);
    try std.testing.expectEqual(@as(u16, 1024), root_w.geom.width);
    try std.testing.expectEqual(@as(u16, 768), root_w.geom.height);
}

test "setCrtcMode: resizes to an alt mode + emits both RANDR events; mode 0 keeps current; unknown id is BadMode" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    try d.randrSelectInput(1, d.root, 0x3);
    d.clearPending();

    try d.setCrtcMode(0xf0001004); // 1920x1080 alt mode
    const root_w = d.windows.getPtr(d.root).?;
    try std.testing.expectEqual(@as(u16, 1920), root_w.geom.width);
    try std.testing.expectEqual(@as(u16, 1080), root_w.geom.height);
    var saw_screen = false;
    var saw_crtc = false;
    for (d.pending.items) |ev| {
        if (ev.kind == .randr_screen_change) {
            saw_screen = true;
            try std.testing.expectEqual(@as(u16, 1920), ev.width);
            try std.testing.expectEqual(@as(u16, 1080), ev.height);
        }
        if (ev.kind == .randr_crtc_change) saw_crtc = true;
    }
    try std.testing.expect(saw_screen);
    try std.testing.expect(saw_crtc);
    d.clearPending();

    // mode 0: keep current -- no-op, no error, no events (still 1920x1080).
    try d.setCrtcMode(0);
    try std.testing.expectEqual(@as(u16, 1920), root_w.geom.width);
    try std.testing.expectEqual(@as(usize, 0), d.pending.items.len);

    // Unknown mode id -> BadMode, no state change.
    try std.testing.expectError(error.BadMode, d.setCrtcMode(0xdead));
    try std.testing.expectEqual(@as(u16, 1920), root_w.geom.width);
}

test "setScreenConfigSize: 0 is the current size, 5 is the last alt mode, out of range is BadValue" {
    const gpa = std.testing.allocator;
    var d = try Display.init(gpa, 0x12a, 24, 0x21);
    defer d.deinit();
    const root_w = d.windows.getPtr(d.root).?;

    // Index 0 always resolves to the LIVE current size (randrModeList's
    // contract), so applying it is inherently a no-op -- proves it neither
    // errors nor desyncs anything.
    try d.setScreenConfigSize(0);
    try std.testing.expectEqual(@as(u16, 640), root_w.geom.width);
    try std.testing.expectEqual(@as(u16, 480), root_w.geom.height);

    // Index 5 is the last alt mode (randr_alt_modes[4] = 1920x1080).
    try d.setScreenConfigSize(5);
    try std.testing.expectEqual(@as(u16, 1920), root_w.geom.width);
    try std.testing.expectEqual(@as(u16, 1080), root_w.geom.height);

    // Out of range (only 6 entries, indices 0..5) -> BadValue, no state change.
    try std.testing.expectError(error.BadValue, d.setScreenConfigSize(99));
    try std.testing.expectEqual(@as(u16, 1920), root_w.geom.width);
}
