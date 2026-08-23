const std = @import("std");

pub const RenderError = std.mem.Allocator.Error;

/// present()'s own error set: everything RenderError covers, plus
/// OutOfBounds for a caller-supplied `out` buffer too small for the
/// requested dimensions (a caller bug, not an allocation failure). Kept
/// separate from RenderError so the existing drawing ops' narrower,
/// caller-declared error sets (server_state.zig) are unaffected.
pub const PresentError = RenderError || error{OutOfBounds};

/// Bytes per pixel for a drawable depth (tight-packed). Single source of truth
/// for Display's resource-size caps and the software renderer's sizing.
pub fn bytesPerPixel(depth: u8) usize {
    return if (depth <= 8) 1 else if (depth <= 16) 2 else 4;
}

/// An opaque per-drawable rendering surface. `handle` is owned + interpreted by
/// the renderer that created it; Display stores it and reads only the public
/// dims/format. Software renderer hides a CPU buffer; a GPU renderer (Prism)
/// hides a texture.
pub const Surface = struct { handle: *anyopaque, width: u16, height: u16, depth: u8, bpp: u8 };

/// A geometric point (X-agnostic; same shape as xproto.Point but not tied to it).
pub const Point = struct { x: i16, y: i16 };
/// A geometric rectangle (for outline drawing).
pub const Rect = struct { x: i16, y: i16, width: u16, height: u16 };

/// A geometric arc: the full ellipse is inscribed in (x,y,width,height); angle1
/// is the start and angle2 the extent, both in 1/64 degree, 0 at 3-o'clock,
/// positive counterclockwise (angle2 negative = clockwise).
pub const Arc = struct { x: i16, y: i16, width: u16, height: u16, angle1: i16, angle2: i16 };
pub const ArcMode = enum(u8) { chord = 0, pie_slice = 1 };

/// Injectable rendering backend (allocator-style ptr+vtable). X-agnostic: knows
/// surfaces, IN-BOUNDS rectangles, and raw pixels only. Display validates X
/// resources/GCs, resolves colors, clips, computes CopyArea coverage, and
/// applies plane_mask; the renderer just moves pixels.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createSurface: *const fn (*anyopaque, depth: u8, width: u16, height: u16) RenderError!Surface,
        destroySurface: *const fn (*anyopaque, Surface) void,
        resizeSurface: *const fn (*anyopaque, *Surface, width: u16, height: u16) RenderError!void,
        fillRect: *const fn (*anyopaque, Surface, x: i16, y: i16, width: u16, height: u16, pixel: u32) void,
        copyRect: *const fn (*anyopaque, dst: Surface, src: Surface, src_x: u16, src_y: u16, dst_x: u16, dst_y: u16, width: u16, height: u16) RenderError!void,
        putImage: *const fn (*anyopaque, Surface, dst_x: i16, dst_y: i16, width: u16, height: u16, data: []const u8) void,
        getImage: *const fn (*anyopaque, Surface, x: u16, y: u16, width: u16, height: u16, out: []u8) void,
        drawPoints: *const fn (*anyopaque, Surface, points: []const Point, pixel: u32) void,
        drawLines: *const fn (*anyopaque, Surface, points: []const Point, pixel: u32) void,
        fillPolygon: *const fn (*anyopaque, Surface, points: []const Point, pixel: u32) RenderError!void,
        drawArcs: *const fn (*anyopaque, Surface, arcs: []const Arc, pixel: u32) RenderError!void,
        fillArcs: *const fn (*anyopaque, Surface, arcs: []const Arc, mode: ArcMode, pixel: u32) RenderError!void,
        drawGlyph: *const fn (*anyopaque, Surface, x: i16, y: i16, bits: []const u8, w: u8, h: u8, fg: u32) void,

        // Output-stage seam (RANDR gamma/transform -> renderer; SP-Server-5a).
        // Defaulted to no-ops/identity-copy so a VTable literal written before
        // these ops existed (e.g. a test double) keeps compiling unmodified;
        // real backends should set these explicitly.
        setCrtcGamma: *const fn (*anyopaque, red: []const u16, green: []const u16, blue: []const u16) void = defaultSetCrtcGamma,
        setCrtcTransform: *const fn (*anyopaque, matrix: [9]i32) void = defaultSetCrtcTransform,
        present: *const fn (*anyopaque, src: Surface, out: []u8, out_width: u16, out_height: u16) PresentError!void = defaultPresent,
    };

    fn defaultSetCrtcGamma(ptr: *anyopaque, red: []const u16, green: []const u16, blue: []const u16) void {
        _ = ptr;
        _ = red;
        _ = green;
        _ = blue;
    }
    fn defaultSetCrtcTransform(ptr: *anyopaque, matrix: [9]i32) void {
        _ = ptr;
        _ = matrix;
    }
    fn defaultPresent(ptr: *anyopaque, src: Surface, out: []u8, out_width: u16, out_height: u16) PresentError!void {
        _ = ptr;
        _ = src;
        _ = out;
        _ = out_width;
        _ = out_height;
    }

    pub fn createSurface(self: Renderer, depth: u8, width: u16, height: u16) RenderError!Surface {
        return self.vtable.createSurface(self.ptr, depth, width, height);
    }
    pub fn destroySurface(self: Renderer, surface: Surface) void {
        self.vtable.destroySurface(self.ptr, surface);
    }
    pub fn resizeSurface(self: Renderer, surface: *Surface, width: u16, height: u16) RenderError!void {
        return self.vtable.resizeSurface(self.ptr, surface, width, height);
    }
    pub fn fillRect(self: Renderer, surface: Surface, x: i16, y: i16, width: u16, height: u16, pixel: u32) void {
        self.vtable.fillRect(self.ptr, surface, x, y, width, height, pixel);
    }
    pub fn copyRect(self: Renderer, dst: Surface, src: Surface, src_x: u16, src_y: u16, dst_x: u16, dst_y: u16, width: u16, height: u16) RenderError!void {
        return self.vtable.copyRect(self.ptr, dst, src, src_x, src_y, dst_x, dst_y, width, height);
    }
    pub fn putImage(self: Renderer, surface: Surface, dst_x: i16, dst_y: i16, width: u16, height: u16, data: []const u8) void {
        self.vtable.putImage(self.ptr, surface, dst_x, dst_y, width, height, data);
    }
    pub fn getImage(self: Renderer, surface: Surface, x: u16, y: u16, width: u16, height: u16, out: []u8) void {
        self.vtable.getImage(self.ptr, surface, x, y, width, height, out);
    }
    pub fn drawPoints(self: Renderer, surface: Surface, points: []const Point, pixel: u32) void {
        self.vtable.drawPoints(self.ptr, surface, points, pixel);
    }
    pub fn drawLines(self: Renderer, surface: Surface, points: []const Point, pixel: u32) void {
        self.vtable.drawLines(self.ptr, surface, points, pixel);
    }
    pub fn fillPolygon(self: Renderer, surface: Surface, points: []const Point, pixel: u32) RenderError!void {
        return self.vtable.fillPolygon(self.ptr, surface, points, pixel);
    }
    pub fn drawArcs(self: Renderer, surface: Surface, arcs: []const Arc, pixel: u32) RenderError!void {
        return self.vtable.drawArcs(self.ptr, surface, arcs, pixel);
    }
    pub fn fillArcs(self: Renderer, surface: Surface, arcs: []const Arc, mode: ArcMode, pixel: u32) RenderError!void {
        return self.vtable.fillArcs(self.ptr, surface, arcs, mode, pixel);
    }
    pub fn drawGlyph(self: Renderer, surface: Surface, x: i16, y: i16, bits: []const u8, w: u8, h: u8, fg: u32) void {
        self.vtable.drawGlyph(self.ptr, surface, x, y, bits, w, h, fg);
    }
    pub fn setCrtcGamma(self: Renderer, red: []const u16, green: []const u16, blue: []const u16) void {
        self.vtable.setCrtcGamma(self.ptr, red, green, blue);
    }
    pub fn setCrtcTransform(self: Renderer, matrix: [9]i32) void {
        self.vtable.setCrtcTransform(self.ptr, matrix);
    }
    pub fn present(self: Renderer, src: Surface, out: []u8, out_width: u16, out_height: u16) PresentError!void {
        return self.vtable.present(self.ptr, src, out, out_width, out_height);
    }
};

/// Linear identity ramp (value[i] = i*257) so an untouched gamma_* array makes
/// present()'s gamma stage an exact passthrough: (i*257) >> 8 == i for every
/// i in [0,255] (257 = 256+1, so i*257 = i*256+i and the low byte i<256 never
/// carries into the shifted-out portion).
const linear_gamma: [256]u16 = blk: {
    var g: [256]u16 = undefined;
    for (&g, 0..) |*v, i| v.* = @intCast(i * 257);
    break :blk g;
};

/// Identity 3x3 homogeneous transform, 16.16 fixed-point, row-major
/// [m11,m12,m13,m21,m22,m23,m31,m32,m33].
const identity_transform: [9]i64 = .{ 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x10000 };

/// Default, behavior-preserving backend: each Surface hides a CPU byte buffer.
pub const SoftwareRenderer = struct {
    gpa: std.mem.Allocator,

    /// Per-channel 16-bit CRTC gamma ramp (RANDR SetCrtcGamma), applied by
    /// present(). Default linear (present with default state is an exact copy).
    gamma_red: [256]u16 = linear_gamma,
    gamma_green: [256]u16 = linear_gamma,
    gamma_blue: [256]u16 = linear_gamma,
    /// CRTC output transform (RANDR SetCrtcTransform), 16.16 fixed-point,
    /// widened to i64 so the present() fixed-point products (coordinate *
    /// FIXED) can't overflow. Default identity.
    transform: [9]i64 = identity_transform,

    /// The backing a software Surface.handle points at.
    const Buf = struct { data: []u8 };

    pub fn renderer(self: *SoftwareRenderer) Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Renderer.VTable = .{
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
        .present = present,
    };

    fn bufOf(surface: Surface) *Buf {
        return @ptrCast(@alignCast(surface.handle));
    }
    fn writePx(data: []u8, stride: usize, bpp: usize, x: usize, y: usize, value: u32) void {
        const off = (y * stride + x) * bpp;
        var i: usize = 0;
        while (i < bpp and i < 4) : (i += 1) data[off + i] = @truncate(value >> @intCast(i * 8));
    }
    /// Mirror of writePx: reassemble the little-endian-per-byte pixel that
    /// writePx/fillRect produce, for present()'s source sampling.
    fn readPx(data: []const u8, stride: usize, bpp: usize, x: usize, y: usize) u32 {
        const off = (y * stride + x) * bpp;
        var value: u32 = 0;
        var i: usize = 0;
        while (i < bpp and i < 4) : (i += 1) value |= @as(u32, data[off + i]) << @intCast(i * 8);
        return value;
    }

    fn createSurface(ptr: *anyopaque, depth: u8, width: u16, height: u16) RenderError!Surface {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        const bpp = bytesPerPixel(depth);
        const buf = try self.gpa.create(Buf);
        errdefer self.gpa.destroy(buf);
        buf.data = try self.gpa.alloc(u8, @as(usize, width) * @as(usize, height) * bpp);
        @memset(buf.data, 0);
        return .{ .handle = buf, .width = width, .height = height, .depth = depth, .bpp = @intCast(bpp) };
    }

    fn destroySurface(ptr: *anyopaque, surface: Surface) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        const buf = bufOf(surface);
        self.gpa.free(buf.data);
        self.gpa.destroy(buf);
    }

    fn resizeSurface(ptr: *anyopaque, surface: *Surface, width: u16, height: u16) RenderError!void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        const buf = bufOf(surface.*);
        const nb = try self.gpa.alloc(u8, @as(usize, width) * @as(usize, height) * @as(usize, surface.bpp));
        @memset(nb, 0);
        self.gpa.free(buf.data);
        buf.data = nb;
        surface.width = width;
        surface.height = height;
    }

    fn fillRect(ptr: *anyopaque, surface: Surface, x: i16, y: i16, width: u16, height: u16, pixel: u32) void {
        _ = ptr;
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        const x0 = @max(@as(i32, 0), @as(i32, x));
        const y0 = @max(@as(i32, 0), @as(i32, y));
        const x1 = @min(@as(i32, surface.width), @as(i32, x) + @as(i32, width));
        const y1 = @min(@as(i32, surface.height), @as(i32, y) + @as(i32, height));
        if (x1 <= x0 or y1 <= y0) return;
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            var xx = x0;
            while (xx < x1) : (xx += 1) writePx(buf.data, stride, bpp, @intCast(xx), @intCast(yy), pixel);
        }
    }

    fn putImage(ptr: *anyopaque, surface: Surface, dst_x: i16, dst_y: i16, width: u16, height: u16, data: []const u8) void {
        _ = ptr;
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        var r: usize = 0;
        while (r < height) : (r += 1) {
            const dy = @as(i32, dst_y) + @as(i32, @intCast(r));
            if (dy < 0 or dy >= @as(i32, surface.height)) continue;
            var c: usize = 0;
            while (c < width) : (c += 1) {
                const dx = @as(i32, dst_x) + @as(i32, @intCast(c));
                if (dx < 0 or dx >= @as(i32, surface.width)) continue;
                const src_off = (r * @as(usize, width) + c) * bpp;
                const dst_off = (@as(usize, @intCast(dy)) * stride + @as(usize, @intCast(dx))) * bpp;
                var i: usize = 0;
                while (i < bpp) : (i += 1) buf.data[dst_off + i] = data[src_off + i];
            }
        }
    }

    fn getImage(ptr: *anyopaque, surface: Surface, x: u16, y: u16, width: u16, height: u16, out: []u8) void {
        _ = ptr;
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        var r: usize = 0;
        while (r < height) : (r += 1) {
            var c: usize = 0;
            while (c < width) : (c += 1) {
                const off = (r * @as(usize, width) + c) * bpp;
                const src_off = ((@as(usize, y) + r) * stride + (@as(usize, x) + c)) * bpp;
                var i: usize = 0;
                while (i < bpp) : (i += 1) out[off + i] = buf.data[src_off + i];
            }
        }
    }

    fn copyRect(ptr: *anyopaque, dst: Surface, src: Surface, src_x: u16, src_y: u16, dst_x: u16, dst_y: u16, width: u16, height: u16) RenderError!void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        const sbuf = bufOf(src);
        const dbuf = bufOf(dst);
        const bpp: usize = dst.bpp;
        // Snapshot the source region FIRST so a self-overlapping copy (same
        // surface, overlapping rects) reads original pixels instead of smearing.
        const tmp = try self.gpa.alloc(u8, @as(usize, width) * @as(usize, height) * bpp);
        defer self.gpa.free(tmp);
        var r: usize = 0;
        while (r < height) : (r += 1) {
            var c: usize = 0;
            while (c < width) : (c += 1) {
                const s_off = ((@as(usize, src_y) + r) * @as(usize, src.width) + (@as(usize, src_x) + c)) * bpp;
                const t_off = (r * @as(usize, width) + c) * bpp;
                var i: usize = 0;
                while (i < bpp) : (i += 1) tmp[t_off + i] = sbuf.data[s_off + i];
            }
        }
        r = 0;
        while (r < height) : (r += 1) {
            var c: usize = 0;
            while (c < width) : (c += 1) {
                const d_off = ((@as(usize, dst_y) + r) * @as(usize, dst.width) + (@as(usize, dst_x) + c)) * bpp;
                const t_off = (r * @as(usize, width) + c) * bpp;
                var i: usize = 0;
                while (i < bpp) : (i += 1) dbuf.data[d_off + i] = tmp[t_off + i];
            }
        }
    }

    fn plotIfInBounds(data: []u8, stride: usize, bpp: usize, w: i32, h: i32, x: i32, y: i32, pixel: u32) void {
        if (x < 0 or y < 0 or x >= w or y >= h) return;
        writePx(data, stride, bpp, @intCast(x), @intCast(y), pixel);
    }

    /// Integer Bresenham between two points (all octants, endpoints inclusive),
    /// clipping each plotted pixel to the surface.
    fn plotLine(data: []u8, stride: usize, bpp: usize, w: i32, h: i32, ax: i32, ay: i32, bx: i32, by: i32, pixel: u32) void {
        var x0 = ax;
        var y0 = ay;
        const dx: i32 = @intCast(@abs(bx - ax));
        const dy: i32 = -@as(i32, @intCast(@abs(by - ay)));
        const sx: i32 = if (ax < bx) 1 else -1;
        const sy: i32 = if (ay < by) 1 else -1;
        var err = dx + dy;
        while (true) {
            plotIfInBounds(data, stride, bpp, w, h, x0, y0, pixel);
            if (x0 == bx and y0 == by) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x0 += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    fn drawPoints(ptr: *anyopaque, surface: Surface, points: []const Point, pixel: u32) void {
        _ = ptr;
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        const w: i32 = surface.width;
        const h: i32 = surface.height;
        for (points) |p| plotIfInBounds(buf.data, stride, bpp, w, h, p.x, p.y, pixel);
    }

    fn drawLines(ptr: *anyopaque, surface: Surface, points: []const Point, pixel: u32) void {
        _ = ptr;
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        const w: i32 = surface.width;
        const h: i32 = surface.height;
        if (points.len == 0) return;
        if (points.len == 1) {
            plotIfInBounds(buf.data, stride, bpp, w, h, points[0].x, points[0].y, pixel);
            return;
        }
        var i: usize = 0;
        while (i + 1 < points.len) : (i += 1) {
            plotLine(buf.data, stride, bpp, w, h, points[i].x, points[i].y, points[i + 1].x, points[i + 1].y, pixel);
        }
    }

    /// Even-odd scanline polygon fill (implicitly closes last->first edge). Clips to
    /// the surface. Allocates a per-scanline intersection scratch (bounded by the
    /// vertex count) -> fallible.
    fn fillPolygon(ptr: *anyopaque, surface: Surface, points: []const Point, pixel: u32) RenderError!void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        return self.fillPolyPoints(surface, points, pixel);
    }

    /// Even-odd scanline fill of an arbitrary point list (implicitly closes
    /// last->first). Clips to the surface. (Extracted from fillPolygon so fillArcs
    /// can reuse it.)
    fn fillPolyPoints(self: *SoftwareRenderer, surface: Surface, points: []const Point, pixel: u32) RenderError!void {
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        const w: i32 = surface.width;
        const h: i32 = surface.height;
        const n = points.len;
        if (n < 3) return; // no area to fill
        // vertical span, clipped to the surface
        var min_y: i32 = points[0].y;
        var max_y: i32 = points[0].y;
        for (points) |p| {
            if (p.y < min_y) min_y = p.y;
            if (p.y > max_y) max_y = p.y;
        }
        if (min_y < 0) min_y = 0;
        if (max_y >= h) max_y = h - 1;
        if (min_y > max_y) return;
        const xs = try self.gpa.alloc(i32, n);
        defer self.gpa.free(xs);
        var y: i32 = min_y;
        while (y <= max_y) : (y += 1) {
            var count: usize = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const a = points[i];
                const b = points[(i + 1) % n];
                const ay: i32 = a.y;
                const by: i32 = b.y;
                // half-open crossing test: count each edge once, handle vertices.
                if ((ay <= y and by > y) or (by <= y and ay > y)) {
                    const ax: i32 = a.x;
                    const bx: i32 = b.x;
                    // Widen the interpolation product to i64: (y-ay) and (bx-ax)
                    // are each up to ~65535 from i16 inputs, so their product can
                    // exceed i32 (a protocol-reachable overflow panic). The result
                    // lies between ax and bx, so it fits i32 after the divide.
                    const num: i64 = @as(i64, y - ay) * @as(i64, bx - ax);
                    const delta: i32 = @intCast(@divFloor(num, @as(i64, by - ay)));
                    xs[count] = ax + delta;
                    count += 1;
                }
            }
            std.mem.sort(i32, xs[0..count], {}, comptime std.sort.asc(i32));
            var k: usize = 0;
            while (k + 1 < count) : (k += 2) {
                var xa = xs[k];
                var xb = xs[k + 1];
                if (xa < 0) xa = 0;
                if (xb >= w) xb = w - 1;
                var x = xa;
                while (x <= xb) : (x += 1) writePx(buf.data, stride, bpp, @intCast(x), @intCast(y), pixel);
            }
        }
    }

    fn clampF(v: f64) i16 {
        const c = std.math.clamp(v, -32768.0, 32767.0);
        return @intFromFloat(@round(c));
    }

    /// Sample the parametric ellipse arc into `out` (needs capacity >= 2049).
    /// Returns the number of points written (steps+1, endpoints inclusive).
    /// X angle convention: 1/64 degree, 0 at 3-o'clock, CCW positive; screen y is
    /// down, so the y term is subtracted.
    fn sampleArc(arc: Arc, out: []Point) usize {
        const wf: f64 = @floatFromInt(arc.width);
        const hf: f64 = @floatFromInt(arc.height);
        const cx: f64 = @as(f64, @floatFromInt(arc.x)) + wf / 2.0;
        const cy: f64 = @as(f64, @floatFromInt(arc.y)) + hf / 2.0;
        const a = wf / 2.0;
        const b = hf / 2.0;
        const start_deg: f64 = @as(f64, @floatFromInt(arc.angle1)) / 64.0;
        const ext_deg: f64 = @as(f64, @floatFromInt(arc.angle2)) / 64.0;
        // ~1 sample per degree of extent, at least 2, capped for a bounded scratch.
        var steps: usize = @intFromFloat(@max(2.0, @min(2048.0, @abs(ext_deg))));
        if (steps + 1 > out.len) steps = out.len - 1;
        const deg2rad = std.math.pi / 180.0;
        var i: usize = 0;
        while (i <= steps) : (i += 1) {
            const frac: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const rad = (start_deg + ext_deg * frac) * deg2rad;
            out[i] = .{ .x = clampF(cx + a * @cos(rad)), .y = clampF(cy - b * @sin(rad)) };
        }
        return steps + 1;
    }

    fn drawArcs(ptr: *anyopaque, surface: Surface, arcs: []const Arc, pixel: u32) RenderError!void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        if (arcs.len == 0) return;
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        const w: i32 = surface.width;
        const h: i32 = surface.height;
        const scratch = try self.gpa.alloc(Point, 2049);
        defer self.gpa.free(scratch);
        for (arcs) |arc| {
            const n = sampleArc(arc, scratch);
            var i: usize = 0;
            while (i + 1 < n) : (i += 1) {
                plotLine(buf.data, stride, bpp, w, h, scratch[i].x, scratch[i].y, scratch[i + 1].x, scratch[i + 1].y, pixel);
            }
        }
    }

    fn fillArcs(ptr: *anyopaque, surface: Surface, arcs: []const Arc, mode: ArcMode, pixel: u32) RenderError!void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        if (arcs.len == 0) return;
        // Slot 0 is reserved for the pie-slice center; samples go into scratch[1..].
        const scratch = try self.gpa.alloc(Point, 2050);
        defer self.gpa.free(scratch);
        for (arcs) |arc| {
            const n = sampleArc(arc, scratch[1..]);
            var pts: []const Point = undefined;
            if (mode == .pie_slice) {
                const wf: f64 = @floatFromInt(arc.width);
                const hf: f64 = @floatFromInt(arc.height);
                const cx = clampF(@as(f64, @floatFromInt(arc.x)) + wf / 2.0);
                const cy = clampF(@as(f64, @floatFromInt(arc.y)) + hf / 2.0);
                scratch[0] = .{ .x = cx, .y = cy };
                pts = scratch[0 .. n + 1];
            } else {
                pts = scratch[1 .. 1 + n];
            }
            try self.fillPolyPoints(surface, pts, pixel);
        }
    }

    /// Blit a 1-bpp glyph mask as fg pixels, clipped to the surface. BIT
    /// CONVENTION: bits[r] is glyph row r (top-down); within a byte, bit c
    /// (LSB, value 1) is the LEFTMOST pixel of that row, i.e. pixel(row r,
    /// col c) is set iff `(bits[r] >> c) & 1 != 0`. This matches the
    /// public-domain font8x8_basic layout the font table vendors from.
    fn drawGlyph(ptr: *anyopaque, surface: Surface, x: i16, y: i16, bits: []const u8, w: u8, h: u8, fg: u32) void {
        _ = ptr;
        const buf = bufOf(surface);
        const stride: usize = surface.width;
        const bpp: usize = surface.bpp;
        const sw: i32 = surface.width;
        const sh: i32 = surface.height;
        var r: usize = 0;
        while (r < h) : (r += 1) {
            if (r >= bits.len) break; // defensive: fewer rows than h
            const row = bits[r];
            var c: usize = 0;
            while (c < w) : (c += 1) {
                if ((row >> @intCast(c)) & 1 != 0) {
                    const px = @as(i32, x) + @as(i32, @intCast(c));
                    const py = @as(i32, y) + @as(i32, @intCast(r));
                    if (px >= 0 and py >= 0 and px < sw and py < sh) writePx(buf.data, stride, bpp, @intCast(px), @intCast(py), fg);
                }
            }
        }
    }

    fn setCrtcGamma(ptr: *anyopaque, red: []const u16, green: []const u16, blue: []const u16) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        // Ramp arrays are fixed at 256 entries; bound the copy so an
        // over-length caller-supplied ramp can't overrun them.
        const nr = @min(red.len, 256);
        const ng = @min(green.len, 256);
        const nb = @min(blue.len, 256);
        @memcpy(self.gamma_red[0..nr], red[0..nr]);
        @memcpy(self.gamma_green[0..ng], green[0..ng]);
        @memcpy(self.gamma_blue[0..nb], blue[0..nb]);
    }

    fn setCrtcTransform(ptr: *anyopaque, matrix: [9]i32) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        for (&self.transform, matrix) |*t, m| t.* = m;
    }

    /// Apply the per-channel gamma LUT to a packed 0x00RRGGBB(-style) pixel.
    /// Only defined for depth 24/32 (bpp>=3, byte0=B/byte1=G/byte2=R/byte3=pad
    /// or alpha, matching writePx/readPx's little-endian-per-byte packing);
    /// narrower depths pass through unmodified (OUT per spec).
    fn applyGamma(self: *const SoftwareRenderer, pixel: u32, bpp: usize) u32 {
        if (bpp < 3) return pixel;
        const b: u8 = @truncate(pixel);
        const g: u8 = @truncate(pixel >> 8);
        const r: u8 = @truncate(pixel >> 16);
        const a: u8 = @truncate(pixel >> 24);
        // 16-bit ramp -> 8-bit output channel.
        const r2: u32 = self.gamma_red[r] >> 8;
        const g2: u32 = self.gamma_green[g] >> 8;
        const b2: u32 = self.gamma_blue[b] >> 8;
        return (@as(u32, a) << 24) | (r2 << 16) | (g2 << 8) | b2;
    }

    /// Nearest-neighbor resample of `src` through the stored transform into
    /// `out` (a caller-owned out_width*out_height*bpp buffer), then applies
    /// the stored gamma LUT. Reference/CPU implementation of the output
    /// stage a GPU renderer (Prism) would do on scanout.
    fn present(ptr: *anyopaque, src: Surface, out: []u8, out_width: u16, out_height: u16) PresentError!void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        const bpp: usize = src.bpp;
        const needed = @as(usize, out_width) * @as(usize, out_height) * bpp;
        // `out` is a caller-supplied fixed buffer (e.g. a scanout target); a
        // too-small buffer is a caller bug, not something to silently truncate.
        if (out.len < needed) return PresentError.OutOfBounds;
        const buf = bufOf(src);
        const src_w: i64 = src.width;
        const src_h: i64 = src.height;
        const src_stride: usize = src.width;
        const out_stride: usize = out_width;
        var oy: u16 = 0;
        while (oy < out_height) : (oy += 1) {
            var ox: u16 = 0;
            while (ox < out_width) : (ox += 1) {
                // Homogeneous source coord = M * (ox, oy, 1), all terms 16.16
                // fixed (i64 headroom: coordinate * FIXED can reach ~2^32,
                // which overflows i32 but not i64).
                const oxi: i64 = ox;
                const oyi: i64 = oy;
                const sxf = self.transform[0] * oxi + self.transform[1] * oyi + self.transform[2];
                const syf = self.transform[3] * oxi + self.transform[4] * oyi + self.transform[5];
                const wf = self.transform[6] * oxi + self.transform[7] * oyi + self.transform[8];
                var pixel: u32 = 0;
                if (wf != 0) {
                    // Both sxf/syf and wf carry the same 16.16 scale, so the
                    // fixed-point fraction cancels in the divide, leaving an
                    // integer source pixel index directly.
                    const sx = @divTrunc(sxf, wf);
                    const sy = @divTrunc(syf, wf);
                    if (sx >= 0 and sy >= 0 and sx < src_w and sy < src_h) {
                        const raw = readPx(buf.data, src_stride, bpp, @intCast(sx), @intCast(sy));
                        pixel = self.applyGamma(raw, bpp);
                    }
                    // else: source out of bounds -> pixel stays 0.
                }
                writePx(out, out_stride, bpp, ox, oy, pixel);
            }
        }
    }
};

test "createSurface: dims/depth/bpp correct, buffer zeroed, no leak" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 4, 3);
    defer r.destroySurface(surf);

    try std.testing.expectEqual(@as(u16, 4), surf.width);
    try std.testing.expectEqual(@as(u16, 3), surf.height);
    try std.testing.expectEqual(@as(u8, 24), surf.depth);
    try std.testing.expectEqual(@as(u8, 4), surf.bpp);

    // Buffer must be zeroed at creation.
    var out: [4]u8 = undefined;
    r.getImage(surf, 1, 1, 1, 1, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &out);
}

test "fillRect: fills an in-bounds rect and clips a partly-out-of-bounds rect" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    // In-bounds fill.
    r.fillRect(surf, 2, 2, 3, 2, 0x00aabbcc);
    var out: [4]u8 = undefined;
    r.getImage(surf, 2, 2, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0x00aabbcc), std.mem.readInt(u32, &out, .little));
    r.getImage(surf, 4, 3, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0x00aabbcc), std.mem.readInt(u32, &out, .little));
    // Outside the fill rect should remain zero.
    r.getImage(surf, 0, 0, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &out, .little));

    // Partly out-of-bounds fill: clipped to the surface, no OOB writes/crash.
    r.fillRect(surf, 6, 6, 5, 5, 0x00112233);
    r.getImage(surf, 7, 7, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0x00112233), std.mem.readInt(u32, &out, .little));

    // Fully out-of-bounds fill must be a no-op (no crash).
    r.fillRect(surf, 100, 100, 5, 5, 0x00ffffff);
}

test "putImage: uploads a w*h*bpp block and clips out-of-bounds parts" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    // 2x2 block, each pixel distinct.
    const data = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    };
    r.putImage(surf, 3, 3, 2, 2, &data);

    var out: [4]u8 = undefined;
    r.getImage(surf, 3, 3, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &out, .little));
    r.getImage(surf, 4, 3, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, &out, .little));
    r.getImage(surf, 3, 4, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, &out, .little));
    r.getImage(surf, 4, 4, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, &out, .little));

    // Clipped upload: dst pushes half the block out of bounds; only the
    // in-bounds cell should land, no OOB write/crash.
    r.putImage(surf, 7, 7, 2, 2, &data);
    r.getImage(surf, 7, 7, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &out, .little));
}

test "getImage: raw readback matches what was written" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 4, 4);
    defer r.destroySurface(surf);

    r.fillRect(surf, 0, 0, 4, 4, 0x00c0ffee);
    var out: [4 * 4 * 4]u8 = undefined;
    r.getImage(surf, 0, 0, 4, 4, &out);
    var i: usize = 0;
    while (i < out.len) : (i += 4) {
        try std.testing.expectEqual(@as(u32, 0x00c0ffee), std.mem.readInt(u32, out[i..][0..4], .little));
    }
}

test "copyRect: in-bounds blit lands correctly" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const src = try r.createSurface(24, 4, 4);
    defer r.destroySurface(src);
    const dst = try r.createSurface(24, 4, 4);
    defer r.destroySurface(dst);

    r.fillRect(src, 0, 0, 4, 4, 0x00deadbe);
    try r.copyRect(dst, src, 0, 0, 1, 1, 2, 2);

    var out: [4]u8 = undefined;
    r.getImage(dst, 1, 1, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0x00deadbe), std.mem.readInt(u32, &out, .little));
    r.getImage(dst, 2, 2, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0x00deadbe), std.mem.readInt(u32, &out, .little));
    // Untouched corner stays zero.
    r.getImage(dst, 0, 0, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &out, .little));
}

test "copyRect: self-overlap reads original pixels, not the partially-written dst" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 6, 6);
    defer r.destroySurface(surf);

    // Build a gradient so every cell of the 4x4 region-of-interest is distinct.
    var original: [6 * 6]u32 = undefined;
    var y: u16 = 0;
    while (y < 6) : (y += 1) {
        var x: u16 = 0;
        while (x < 6) : (x += 1) {
            const px: u32 = (@as(u32, y) << 8) | @as(u32, x);
            original[@as(usize, y) * 6 + x] = px;
            r.fillRect(surf, @intCast(x), @intCast(y), 1, 1, px);
        }
    }

    // Self-overlapping copy: shift the top-left 4x4 region by (+2,+2).
    try r.copyRect(surf, surf, 0, 0, 2, 2, 4, 4);

    // Expected result at every dst cell must equal the ORIGINAL pixel at
    // (dst_x-2, dst_y-2), proving the temp-buffer snapshot (not a smear of
    // already-overwritten dst pixels).
    var out: [4]u8 = undefined;
    var dy: u16 = 2;
    while (dy < 6) : (dy += 1) {
        var dx: u16 = 2;
        while (dx < 6) : (dx += 1) {
            r.getImage(surf, dx, dy, 1, 1, &out);
            const got = std.mem.readInt(u32, &out, .little);
            const expected = original[@as(usize, dy - 2) * 6 + (dx - 2)];
            try std.testing.expectEqual(expected, got);
        }
    }
}

test "resizeSurface: grows and shrinks, contents zeroed, dims updated" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    var surf = try r.createSurface(24, 4, 4);
    defer r.destroySurface(surf);

    r.fillRect(surf, 0, 0, 4, 4, 0x00abcdef);

    // Grow.
    try r.resizeSurface(&surf, 8, 8);
    try std.testing.expectEqual(@as(u16, 8), surf.width);
    try std.testing.expectEqual(@as(u16, 8), surf.height);
    var out: [4]u8 = undefined;
    r.getImage(surf, 0, 0, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &out, .little));
    r.getImage(surf, 7, 7, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &out, .little));

    r.fillRect(surf, 0, 0, 8, 8, 0x00112233);

    // Shrink.
    try r.resizeSurface(&surf, 2, 2);
    try std.testing.expectEqual(@as(u16, 2), surf.width);
    try std.testing.expectEqual(@as(u16, 2), surf.height);
    r.getImage(surf, 0, 0, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &out, .little));
    r.getImage(surf, 1, 1, 1, 1, &out);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &out, .little));
}

/// Test-only helper: read a single pixel back via getImage and compare.
fn expectPixel(r: Renderer, surf: Surface, x: u16, y: u16, expected: u32) !void {
    var out: [4]u8 = undefined;
    r.getImage(surf, x, y, 1, 1, &out);
    try std.testing.expectEqual(expected, std.mem.readInt(u32, &out, .little));
}

test "drawPoints: sets exactly the listed in-bounds pixels, out-of-bounds skipped" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    const pts = [_]Point{
        .{ .x = 1, .y = 1 },
        .{ .x = 5, .y = 3 },
        .{ .x = -1, .y = 2 }, // out-of-bounds: negative x
        .{ .x = 100, .y = 100 }, // out-of-bounds: past the surface
    };
    r.drawPoints(surf, &pts, 0x00aabbcc);

    try expectPixel(r, surf, 1, 1, 0x00aabbcc);
    try expectPixel(r, surf, 5, 3, 0x00aabbcc);
    // A neighbor of an in-bounds point must stay untouched.
    try expectPixel(r, surf, 2, 1, 0);
    // Out-of-bounds points must not crash and must not stray-write any pixel.
    try expectPixel(r, surf, 0, 0, 0);
}

test "drawLines: horizontal and vertical segments set all cells inclusive" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    // Horizontal: y constant, all x in [1,4] inclusive.
    const horiz = [_]Point{ .{ .x = 1, .y = 2 }, .{ .x = 4, .y = 2 } };
    r.drawLines(surf, &horiz, 0x00111111);
    var x: u16 = 1;
    while (x <= 4) : (x += 1) try expectPixel(r, surf, x, 2, 0x00111111);
    try expectPixel(r, surf, 5, 2, 0); // one past the endpoint stays clear
    try expectPixel(r, surf, 0, 2, 0); // one before the start stays clear

    // Vertical: x constant, all y in [3,6] inclusive.
    const vert = [_]Point{ .{ .x = 6, .y = 3 }, .{ .x = 6, .y = 6 } };
    r.drawLines(surf, &vert, 0x00222222);
    var y: u16 = 3;
    while (y <= 6) : (y += 1) try expectPixel(r, surf, 6, y, 0x00222222);
}

test "drawLines: 45-degree diagonal sets the diagonal cells" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    const diag = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 3 } };
    r.drawLines(surf, &diag, 0x00333333);
    var d: u16 = 0;
    while (d <= 3) : (d += 1) try expectPixel(r, surf, d, d, 0x00333333);
    // Off-diagonal cell must stay untouched.
    try expectPixel(r, surf, 1, 2, 0);
}

test "drawLines: partly off-surface line clips per-pixel, no crash" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    // Endpoint (20,5) lies well past the 8-wide surface; only the in-bounds
    // run of the horizontal line should land.
    const clipped = [_]Point{ .{ .x = 5, .y = 5 }, .{ .x = 20, .y = 5 } };
    r.drawLines(surf, &clipped, 0x00444444);
    try expectPixel(r, surf, 5, 5, 0x00444444);
    try expectPixel(r, surf, 6, 5, 0x00444444);
    try expectPixel(r, surf, 7, 5, 0x00444444);
}

test "drawLines: single-point slice plots one pixel, empty slice is a no-op" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    const single = [_]Point{.{ .x = 2, .y = 2 }};
    r.drawLines(surf, &single, 0x00555555);
    try expectPixel(r, surf, 2, 2, 0x00555555);

    const empty = [_]Point{};
    r.drawLines(surf, &empty, 0x00666666);
    // Nothing should have changed; the single-point pixel above is untouched
    // and no stray pixel was written anywhere else.
    try expectPixel(r, surf, 2, 2, 0x00555555);
    try expectPixel(r, surf, 0, 0, 0);
}

test "fillPolygon: rectangle-as-4-points fills the interior, exterior stays clear" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    // A closed rectangle path (2,2)-(6,2)-(6,5)-(2,5), implicitly closed back
    // to (2,2). Rows y=2..4 fill x=2..6 (the half-open scanline rule leaves
    // the final vertex row y=5 unfilled, which is expected/correct).
    const rect = [_]Point{
        .{ .x = 2, .y = 2 },
        .{ .x = 6, .y = 2 },
        .{ .x = 6, .y = 5 },
        .{ .x = 2, .y = 5 },
    };
    try r.fillPolygon(surf, &rect, 0x00777777);

    try expectPixel(r, surf, 4, 3, 0x00777777); // interior center
    try expectPixel(r, surf, 0, 0, 0); // exterior corner stays clear
    try expectPixel(r, surf, 7, 3, 0); // outside the rectangle stays clear
}

test "fillPolygon: concave polygon leaves its notch unfilled (proves even-odd)" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 10, 10);
    defer r.destroySurface(surf);

    // A "C"-shaped (backward) concave octagon: an outer rectangle
    // (1,1)-(8,9) with a notch cut out of the middle-right, from
    // x=4..8, y=4..6.
    const notched = [_]Point{
        .{ .x = 1, .y = 1 },
        .{ .x = 8, .y = 1 },
        .{ .x = 8, .y = 4 },
        .{ .x = 4, .y = 4 },
        .{ .x = 4, .y = 6 },
        .{ .x = 8, .y = 6 },
        .{ .x = 8, .y = 9 },
        .{ .x = 1, .y = 9 },
    };
    try r.fillPolygon(surf, &notched, 0x00888888);

    try expectPixel(r, surf, 2, 2, 0x00888888); // main body, above the notch
    try expectPixel(r, surf, 2, 5, 0x00888888); // main body, left of the notch
    try expectPixel(r, surf, 6, 5, 0); // inside the notch: must stay unfilled
    try expectPixel(r, surf, 0, 0, 0); // outside the polygon entirely
}

test "fillPolygon: triangle fills its interior" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 10, 10);
    defer r.destroySurface(surf);

    const tri = [_]Point{ .{ .x = 5, .y = 1 }, .{ .x = 9, .y = 9 }, .{ .x = 1, .y = 9 } };
    try r.fillPolygon(surf, &tri, 0x00999999);

    try expectPixel(r, surf, 5, 6, 0x00999999); // interior, near the centroid
    try expectPixel(r, surf, 0, 0, 0); // exterior stays clear
    try expectPixel(r, surf, 9, 0, 0); // exterior stays clear
}

test "fillPolygon: fewer than 3 points is a no-op" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    const two = [_]Point{ .{ .x = 1, .y = 1 }, .{ .x = 5, .y = 5 } };
    try r.fillPolygon(surf, &two, 0x00aaaaaa);
    try expectPixel(r, surf, 1, 1, 0);
    try expectPixel(r, surf, 5, 5, 0);

    const empty = [_]Point{};
    try r.fillPolygon(surf, &empty, 0x00bbbbbb);
    try expectPixel(r, surf, 0, 0, 0);
}

test "fillPolygon: extreme i16 coords do not overflow the x-intercept (regression)" {
    // Before the i64 widening, (y-ay)*(bx-ax) with a vertex spread this wide
    // overflowed i32 and panicked the whole server on protocol-legal input.
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 16, 16);
    defer r.destroySurface(surf);

    const wide = [_]Point{
        .{ .x = -32768, .y = -32768 },
        .{ .x = 32767, .y = 8 },
        .{ .x = -32768, .y = 8 },
    };
    try r.fillPolygon(surf, &wide, 0x00cccccc); // must not panic
    // The triangle covers the top-left region at y<=8; a low row inside the
    // surface gets filled (exact coverage is not asserted, only no-overflow).
    try expectPixel(r, surf, 0, 0, 0x00cccccc);
}

// Arc geometry used by the following tests: inscribed in (1,1,18,18) on a
// 20x20 surface -> center (10,10), semi-axes 9,9 (both integers), so the 4
// axis-extreme samples (angle 0/90/180/270) land exactly on (19,10)/(10,1)/
// (1,10)/(10,19) after clampF's round -> no ambiguity from float rounding.

test "drawArcs: full-circle outline sets circumference pixels, center stays clear" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 20, 20);
    defer r.destroySurface(surf);

    const arcs = [_]Arc{.{ .x = 1, .y = 1, .width = 18, .height = 18, .angle1 = 0, .angle2 = 360 * 64 }};
    try r.drawArcs(surf, &arcs, 0x00aabbcc);

    try expectPixel(r, surf, 19, 10, 0x00aabbcc); // rightmost, angle 0
    try expectPixel(r, surf, 10, 1, 0x00aabbcc); // top, angle 90
    try expectPixel(r, surf, 1, 10, 0x00aabbcc); // leftmost, angle 180
    try expectPixel(r, surf, 10, 19, 0x00aabbcc); // bottom, angle 270
    try expectPixel(r, surf, 10, 10, 0); // center: outline only, not filled
}

test "drawArcs: quarter arc sets an on-curve pixel, leaves the unswept curve clear" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 20, 20);
    defer r.destroySurface(surf);

    // Sweeps angle 0 (rightmost) -> angle 90 (top) only.
    const arcs = [_]Arc{.{ .x = 1, .y = 1, .width = 18, .height = 18, .angle1 = 0, .angle2 = 90 * 64 }};
    try r.drawArcs(surf, &arcs, 0x00112233);

    try expectPixel(r, surf, 19, 10, 0x00112233); // start endpoint, on-curve
    try expectPixel(r, surf, 10, 1, 0x00112233); // end endpoint, on-curve
    try expectPixel(r, surf, 1, 10, 0); // leftmost: not on this quarter
    try expectPixel(r, surf, 10, 19, 0); // bottom: not on this quarter
}

test "fillArcs: PieSlice full circle fills the center, corner stays clear" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 20, 20);
    defer r.destroySurface(surf);

    const arcs = [_]Arc{.{ .x = 1, .y = 1, .width = 18, .height = 18, .angle1 = 0, .angle2 = 360 * 64 }};
    try r.fillArcs(surf, &arcs, .pie_slice, 0x00445566);

    try expectPixel(r, surf, 10, 10, 0x00445566); // center: filled
    try expectPixel(r, surf, 0, 0, 0); // outside the circle entirely
}

test "fillArcs: Chord half-circle fills only the swept half" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 20, 20);
    defer r.destroySurface(surf);

    // angle 0 -> angle 180 sweeps CCW through the top (upper half, smaller y).
    const arcs = [_]Arc{.{ .x = 1, .y = 1, .width = 18, .height = 18, .angle1 = 0, .angle2 = 180 * 64 }};
    try r.fillArcs(surf, &arcs, .chord, 0x00778899);

    try expectPixel(r, surf, 10, 5, 0x00778899); // upper half: filled
    try expectPixel(r, surf, 10, 15, 0); // lower half: clear
}

test "drawArcs/fillArcs: degenerate width/height/extent do not crash" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 20, 20);
    defer r.destroySurface(surf);

    const zero_wh = [_]Arc{.{ .x = 5, .y = 5, .width = 0, .height = 0, .angle1 = 0, .angle2 = 360 * 64 }};
    try r.drawArcs(surf, &zero_wh, 0x00999999);
    try r.fillArcs(surf, &zero_wh, .pie_slice, 0x00999999);

    const zero_ext = [_]Arc{.{ .x = 1, .y = 1, .width = 18, .height = 18, .angle1 = 0, .angle2 = 0 }};
    try r.drawArcs(surf, &zero_ext, 0x00999999);
    try r.fillArcs(surf, &zero_ext, .chord, 0x00999999);

    // No assertion beyond "did not panic"; the empty-arcs slice path too.
    const none = [_]Arc{};
    try r.drawArcs(surf, &none, 0x00999999);
    try r.fillArcs(surf, &none, .pie_slice, 0x00999999);
}

test "drawGlyph: LSB=leftmost bit convention, in-bounds set/clear pixels, off-surface clips" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 8, 8);
    defer r.destroySurface(surf);

    // row 0: only bit 0 (col 0, leftmost) set. row 7: only bit 7 (col 7) set.
    var bits = [_]u8{0} ** 8;
    bits[0] = 0b00000001;
    bits[7] = 0b10000000;
    r.drawGlyph(surf, 0, 0, &bits, 8, 8, 0x00abcdef);

    try expectPixel(r, surf, 0, 0, 0x00abcdef); // row0, col0: set
    try expectPixel(r, surf, 7, 7, 0x00abcdef); // row7, col7: set
    try expectPixel(r, surf, 1, 0, 0); // row0, col1: clear

    // Off-surface glyph: must clip per-pixel, no crash/OOB.
    r.drawGlyph(surf, 5, 5, &bits, 8, 8, 0x00112233);
    try expectPixel(r, surf, 5, 5, 0x00112233); // row0,col0 of this glyph lands in-bounds at (5,5)
}

test "present: identity transform + default (linear) gamma is an exact copy of the src surface" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 3, 2);
    defer r.destroySurface(surf);

    // Distinct per-pixel pattern so a mis-indexed copy would be caught.
    var y: u16 = 0;
    while (y < 2) : (y += 1) {
        var x: u16 = 0;
        while (x < 3) : (x += 1) {
            const px: u32 = (@as(u32, x) << 16) | (@as(u32, y) << 8) | (@as(u32, x) ^ @as(u32, y));
            r.fillRect(surf, @intCast(x), @intCast(y), 1, 1, px);
        }
    }

    const out = try std.testing.allocator.alloc(u8, 3 * 2 * 4);
    defer std.testing.allocator.free(out);
    try r.present(surf, out, 3, 2);

    y = 0;
    while (y < 2) : (y += 1) {
        var x: u16 = 0;
        while (x < 3) : (x += 1) {
            var src_px: [4]u8 = undefined;
            r.getImage(surf, x, y, 1, 1, &src_px);
            const off = (@as(usize, y) * 3 + x) * 4;
            try std.testing.expectEqualSlices(u8, &src_px, out[off..][0..4]);
        }
    }
}

test "present: an inverting gamma ramp inverts each channel, alpha/pad kept" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 1, 1);
    defer r.destroySurface(surf);
    r.fillRect(surf, 0, 0, 1, 1, 0x00112233);

    const out = try std.testing.allocator.alloc(u8, 1 * 1 * 4);
    defer std.testing.allocator.free(out);

    // Sanity: default (linear) gamma leaves the pixel untouched first.
    try r.present(surf, out, 1, 1);
    try std.testing.expectEqual(@as(u32, 0x00112233), std.mem.readInt(u32, out[0..4], .little));

    // ramp[i] = (255-i)*257: inverts an 8-bit channel through the 16-bit ramp.
    var inverted: [256]u16 = undefined;
    for (&inverted, 0..) |*v, i| v.* = @as(u16, @intCast(255 - i)) * 257;
    r.setCrtcGamma(&inverted, &inverted, &inverted);

    try r.present(surf, out, 1, 1);
    // 0x00112233 -> R 0x11->0xEE, G 0x22->0xDD, B 0x33->0xCC, pad/alpha (0x00) kept.
    try std.testing.expectEqual(@as(u32, 0x00eeddcc), std.mem.readInt(u32, out[0..4], .little));
}

test "present: a 2x-scale transform samples src(2*ox, 2*oy)" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 4, 4);
    defer r.destroySurface(surf);

    var y: u16 = 0;
    while (y < 4) : (y += 1) {
        var x: u16 = 0;
        while (x < 4) : (x += 1) {
            const px: u32 = (@as(u32, y) << 8) | @as(u32, x);
            r.fillRect(surf, @intCast(x), @intCast(y), 1, 1, px);
        }
    }

    // m11=m22=0x20000 (2.0 in 16.16 fixed), m33=0x10000 identity, rest 0.
    r.setCrtcTransform(.{ 0x20000, 0, 0, 0, 0x20000, 0, 0, 0, 0x10000 });

    const out = try std.testing.allocator.alloc(u8, 2 * 2 * 4);
    defer std.testing.allocator.free(out);
    try r.present(surf, out, 2, 2);

    var oy: u16 = 0;
    while (oy < 2) : (oy += 1) {
        var ox: u16 = 0;
        while (ox < 2) : (ox += 1) {
            var src_px: [4]u8 = undefined;
            r.getImage(surf, 2 * ox, 2 * oy, 1, 1, &src_px);
            const off = (@as(usize, oy) * 2 + ox) * 4;
            try std.testing.expectEqualSlices(u8, &src_px, out[off..][0..4]);
        }
    }
}

test "present: a region mapping outside the src bounds samples 0" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 2, 2);
    defer r.destroySurface(surf);
    r.fillRect(surf, 0, 0, 2, 2, 0x00ffffff); // non-zero, so a stray sample would be caught

    // sx = ox + 5 (translate right by 5, past the 2-wide surface for every ox in [0,2)).
    r.setCrtcTransform(.{ 0x10000, 0, 5 * 0x10000, 0, 0x10000, 0, 0, 0, 0x10000 });

    const out = try std.testing.allocator.alloc(u8, 2 * 2 * 4);
    defer std.testing.allocator.free(out);
    try r.present(surf, out, 2, 2);

    for (0..out.len / 4) |i| {
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[i * 4 ..][0..4], .little));
    }
}

test "present: out buffer smaller than out_width*out_height*bpp returns OutOfBounds" {
    var sw: SoftwareRenderer = .{ .gpa = std.testing.allocator };
    const r = sw.renderer();
    const surf = try r.createSurface(24, 2, 2);
    defer r.destroySurface(surf);

    const too_small = try std.testing.allocator.alloc(u8, 2 * 2 * 4 - 1);
    defer std.testing.allocator.free(too_small);
    try std.testing.expectError(error.OutOfBounds, r.present(surf, too_small, 2, 2));
}
