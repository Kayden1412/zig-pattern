//! A simple, non-compiler example of a void-keyed ArrayHashMap used as a
//! deduplicating string interner / dictionary encoder.
//!
//! The map itself stores no strings:
//!
//!     map: AutoArrayHashMapUnmanaged(void, void)
//!
//! Its entry indices are the dictionary IDs. The canonical strings live in
//! `bytes`, and `spans` maps an ID to a byte range. The adapter resolves a
//! candidate `[]const u8` against the string at the stored entry index.
//!
//! Run with:
//!     zig run string_interner_example.zig
//!
//! Test with:
//!     zig test string_interner_example.zig

const std = @import("std");

const StringInterner = struct {
    /// All interned bytes, stored back-to-back.
    bytes: std.ArrayList(u8) = .empty,

    /// One span per interned string. The map entry index is the span index
    /// and also the public dictionary ID.
    spans: std.ArrayList(Span) = .empty,

    /// A set with no stored keys or values. `store_hash` is true because
    /// AutoArrayHashMapUnmanaged(void, void) chooses that for `void`.
    map: std.array_hash_map.Auto(void, void) = .empty,

    const Span = struct {
        offset: u32,
        len: u32,
    };

    const Adapter = struct {
        interner: *const StringInterner,

        pub fn hash(_: Adapter, s: []const u8) u32 {
            return @truncate(std.hash.Wyhash.hash(0, s));
        }

        pub fn eql(ctx: Adapter, s: []const u8, _: void, index: usize) bool {
            const span = ctx.interner.spans.items[index];
            const stored = ctx.interner.bytes.items[span.offset..][0..span.len];
            return std.mem.eql(u8, s, stored);
        }
    };

    fn deinit(self: *StringInterner, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.spans.deinit(gpa);
        self.map.deinit(gpa);
    }

    fn intern(self: *StringInterner, gpa: std.mem.Allocator, s: []const u8) !u32 {
        // Reserve all fallible storage before touching the map. Then the map
        // insertion below is infallible, and a later OOM cannot leave a map
        // entry whose backing span does not exist.
        try self.bytes.ensureUnusedCapacity(gpa, s.len);
        try self.spans.ensureUnusedCapacity(gpa, 1);
        try self.map.ensureUnusedCapacity(gpa, 1);

        const gop = self.map.getOrPutAssumeCapacityAdapted(
            s,
            Adapter{ .interner = self },
        );
        if (gop.found_existing) return @intCast(gop.index);

        const offset: u32 = @intCast(self.bytes.items.len);
        self.bytes.appendSliceAssumeCapacity(s);
        self.spans.appendAssumeCapacity(.{
            .offset = offset,
            .len = @intCast(s.len),
        });

        // For a void key there is no key to initialize. `gop.index` is the
        // new entry index, which is the dictionary ID.
        return @intCast(gop.index);
    }

    fn get(self: *const StringInterner, id: u32) []const u8 {
        const span = self.spans.items[id];
        return self.bytes.items[span.offset..][0..span.len];
    }

    fn count(self: *const StringInterner) usize {
        return self.spans.items.len;
    }
};

pub fn main(init: std.process.Init) !void {
    // Zig 0.17's start.zig supplies a default general-purpose allocator.
    const gpa = init.gpa;

    var interner: StringInterner = .{};
    defer interner.deinit(gpa);

    const words = [_][]const u8{
        "apple",
        "banana",
        "apple",
        "cherry",
        "banana",
        "apple",
    };

    for (words) |word| {
        const id = try interner.intern(gpa, word);
        std.debug.print("{s: <8} -> id {d}\n", .{ word, id });
    }

    std.debug.print("\nunique strings: {d}\n", .{interner.count()});
    for (0..interner.count()) |id| {
        std.debug.print("  id {d}: {s}\n", .{ id, interner.get(@intCast(id)) });
    }

    // The repeated words above reuse their existing IDs. This is the same
    // mechanism a columnar database uses for dictionary encoding.
}

test "interner deduplicates and assigns dense IDs" {
    const gpa = std.testing.allocator;

    var interner: StringInterner = .{};
    defer interner.deinit(gpa);

    const us = try interner.intern(gpa, "US");
    const de = try interner.intern(gpa, "DE");
    const us_again = try interner.intern(gpa, "US");
    const fr = try interner.intern(gpa, "FR");

    try std.testing.expectEqual(@as(u32, 0), us);
    try std.testing.expectEqual(@as(u32, 1), de);
    try std.testing.expectEqual(us, us_again);
    try std.testing.expectEqual(@as(u32, 2), fr);
    try std.testing.expectEqual(@as(usize, 3), interner.count());

    try std.testing.expectEqualStrings("US", interner.get(us));
    try std.testing.expectEqualStrings("DE", interner.get(de));
    try std.testing.expectEqualStrings("FR", interner.get(fr));
}

test "interner handles empty and prefix strings" {
    const gpa = std.testing.allocator;

    var interner: StringInterner = .{};
    defer interner.deinit(gpa);

    const empty = try interner.intern(gpa, "");
    const a = try interner.intern(gpa, "a");
    const ab = try interner.intern(gpa, "ab");

    try std.testing.expectEqual(@as(u32, 0), empty);
    try std.testing.expectEqual(@as(u32, 1), a);
    try std.testing.expectEqual(@as(u32, 2), ab);
    try std.testing.expectEqualStrings("", interner.get(empty));
    try std.testing.expectEqualStrings("a", interner.get(a));
    try std.testing.expectEqualStrings("ab", interner.get(ab));
}
