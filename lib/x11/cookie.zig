const std = @import("std");

pub fn Cookie(comptime Reply: type) type {
    return struct {
        sequence: u64,
        pub const ReplyType = Reply;
    };
}

pub const VoidCookie = struct { sequence: u64 };

pub const SequenceTracker = struct {
    /// Last widened value handed out by next() (the send counter).
    sent: u64 = 0,
    /// Last inbound wire value seen by widen().
    last_wire: u16 = 0,
    /// Epoch (high bits) for inbound widening.
    epoch: u64 = 0,

    pub fn init() SequenceTracker {
        return .{};
    }

    /// Next sequence for an outbound request (X's first request is 1).
    pub fn next(self: *SequenceTracker) u64 {
        self.sent += 1;
        return self.sent;
    }

    /// Widen an inbound 16-bit wire sequence to 64 bits, tracking wraparound.
    pub fn widen(self: *SequenceTracker, wire: u16) u64 {
        if (wire < self.last_wire) {
            self.epoch += 0x1_0000;
        }
        self.last_wire = wire;
        return self.epoch + wire;
    }
};

test "SequenceTracker.next counts from 1" {
    var t = SequenceTracker.init();
    try std.testing.expectEqual(@as(u64, 1), t.next());
    try std.testing.expectEqual(@as(u64, 2), t.next());
    try std.testing.expectEqual(@as(u64, 3), t.next());
}

test "SequenceTracker.widen handles wraparound" {
    var t = SequenceTracker.init();
    try std.testing.expectEqual(@as(u64, 0xFFFE), t.widen(0xFFFE));
    try std.testing.expectEqual(@as(u64, 0xFFFF), t.widen(0xFFFF));
    try std.testing.expectEqual(@as(u64, 0x10000), t.widen(0x0000));
    try std.testing.expectEqual(@as(u64, 0x10001), t.widen(0x0001));
}

test "Cookie carries reply type and sequence" {
    const R = struct { x: u32 };
    const C = Cookie(R);
    const c: C = .{ .sequence = 42 };
    try std.testing.expectEqual(@as(u64, 42), c.sequence);
    try std.testing.expect(C.ReplyType == R);
}
