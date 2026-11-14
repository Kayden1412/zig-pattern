const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Basic: write formatted text into a fixed buffer (no allocation, fails if full).
pub fn exampleFixedWriter() !void {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    try w.print("hello {s} {d}\n", .{ "zig", 17 });
    try w.writeAll("buffered in-memory");
    // fixed writer has no backing sink; contents are in w.buffered()
    std.debug.print("fixed: {s}\n", .{w.buffered()});
}

/// Basic: read from an in-memory byte slice using Reader.fixed.
pub fn exampleFixedReader() !void {
    const input = "foo,42,bar\n";
    var r: Io.Reader = .fixed(input);

    const a = try r.takeDelimiterExclusive(','); // "foo"
    r.toss(1); // skip ','
    // parse integer bytes manually for demo
    const num_bytes = try r.takeDelimiterExclusive(',');
    r.toss(1);
    const rest = try r.takeDelimiterExclusive('\n');

    std.debug.print("fields: {s} | {s} | {s}\n", .{ a, num_bytes, rest });
}

/// Basic: read a whole file by streaming it into a discarding writer (count bytes).
pub fn exampleCountFile(io: Io, path: []const u8) !u64 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var sink_buf: [8 * 1024]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&sink_buf);

    _ = try file_reader.interface.streamRemaining(&discarding.writer);
    // discarding.count tracks drained bytes; buffered() may hold a tail in writer
    return discarding.fullCount();
}

/// Basic: stream a file into a hashing writer (digest while reading).
pub fn exampleHashFile(io: Io, path: []const u8) ![Sha256.digest_length]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});

    var hash_buf: [64 * 1024]u8 = undefined;
    var hashing: Io.Writer.Hashing(Sha256) = .init(&hash_buf);

    _ = try file_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();

    var digest: [Sha256.digest_length]u8 = undefined;
    hashing.hasher.final(&digest);
    return digest;
}

/// Intermediate: write a file with buffered File.Writer (positional by default).
pub fn exampleWriteFile(io: Io, path: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);

    try fw.interface.print("line {d}\n", .{1});
    try fw.interface.writeAll("hello from Io.Writer\n");
    try fw.interface.flush();
}

/// Intermediate: copy file to file by pumping Reader -> Writer.
/// sendFile fast paths may be used by the implementation when available.
pub fn exampleCopyFile(io: Io, src_path: []const u8, dst_path: []const u8) !u64 {
    var src = try Io.Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);
    var dst = try Io.Dir.cwd().createFile(io, dst_path, .{ .truncate = true });
    defer dst.close(io);

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = src.reader(io, &rbuf);
    var writer = dst.writer(io, &wbuf);

    const n = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
    return n;
}

/// Intermediate: allocating/growable output with Writer.Allocating.
pub fn exampleAllocatingWriter(allocator: Allocator) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    try aw.writer.print("dynamic {s} ", .{"buffer"});
    try aw.writer.writeAll("grows as needed");
    // flush is a no-op for Allocating; take ownership of bytes
    return aw.toOwnedSlice();
}

/// Intermediate: vectored write (writeVec/writeSplat) and buffered access.
pub fn exampleVectoredWrite() !void {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var parts = [_][]const u8{ "one", "-", "two" };
    _ = try w.writeVec(&parts);
    std.debug.print("vec: {s}\n", .{w.buffered()});

    // writeSplat: last element is repeated `splat` times
    var w2: Io.Writer = .fixed(&buf);
    const slices = [_][]const u8{ "ab", "Z" };
    _ = try w2.writeSplat(&slices, 3); // "ab" + "Z"*3 => "abZZZ"
    std.debug.print("splat: {s}\n", .{w2.buffered()});
}

/// Advanced: tee into hasher while writing to a file (compose writers conceptually by
/// manually updating hasher on buffered chunks, or by streaming reader to both sinks).
/// Here: stream a reader into a File.Writer and hash the same bytes via Hashing writer.
pub fn exampleHashWhileCopy(io: Io, src_path: []const u8, dst_path: []const u8) ![Sha256.digest_length]u8 {
    // Read source into memory-sized chunks and fan out: update hasher, write to dest.
    var src = try Io.Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);
    var dst = try Io.Dir.cwd().createFile(io, dst_path, .{ .truncate = true });
    defer dst.close(io);

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = src.reader(io, &rbuf);
    var writer = dst.writer(io, &wbuf);

    var hasher = Sha256.init(.{});
    while (true) {
        // peekGreedy/fill via take pattern: get whatever is buffered/available
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        hasher.update(chunk);
        try writer.interface.writeAll(chunk);
        reader.interface.toss(chunk.len);
    }

    try writer.interface.flush();
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Advanced: bounded/limited read and peek/take parsing helpers on a fixed reader.
pub fn examplePeekTakeParse() !void {
    const data = "\x01\x02\x00\x00\x00\x2aREST";
    var r: Io.Reader = .fixed(data);

    // peek without consuming
    const first = try r.peekArray(2);
    std.debug.print("peeked: {d},{d}\n", .{ first[0], first[1] });

    // take/consume typed values
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    const n = try r.takeInt(u32, .big); // bytes 00 00 00 2a => 42
    const rest = try r.take(4); // "REST"
    std.debug.print("parsed: {d} {d} {d} {s}\n", .{ b0, b1, n, rest });
}

/// Advanced: read into caller-provided buffers (readVecAll) and write from slices.
pub fn exampleScatterGather() !void {
    var r: Io.Reader = .fixed("abcdef");
    var a: [2]u8 = undefined;
    var b: [4]u8 = undefined;
    var bufs = [_][]u8{ &a, &b };
    try r.readVecAll(&bufs);
    std.debug.print("scatter: {s} {s}\n", .{ a, b[0..4] });

    var out: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var slices = [_][]const u8{ "hi", " ", "there" };
    try w.writeVecAll(&slices);
    std.debug.print("gather: {s}\n", .{w.buffered()});
}

/// Advanced: positional write/read helpers on File (no explicit writer object).
pub fn examplePositionalAll(io: Io, path: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .read = true });
    defer file.close(io);

    try file.writePositionalAll(io, "ABCDEF", 0);
    try file.sync(io);

    var read_back: [3]u8 = undefined;
    const n = try file.readPositionalAll(io, &read_back, 2); // read "CDE"
    std.debug.print("positional read: {s} ({d} bytes)\n", .{ read_back[0..n], n });
}

/// Demo main: runs safe in-memory examples and a small /tmp file roundtrip.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    try exampleFixedWriter();
    try exampleFixedReader();
    try exampleVectoredWrite();
    try examplePeekTakeParse();
    try exampleScatterGather();

    const owned = try exampleAllocatingWriter(allocator);
    std.debug.print("allocating: {s}\n", .{owned});

    const tmp_path = "/tmp/kilo_io_example.txt";
    const tmp_copy = "/tmp/kilo_io_example_copy.txt";

    try exampleWriteFile(io, tmp_path);
    const bytes_copied = try exampleCopyFile(io, tmp_path, tmp_copy);
    const digest = try exampleHashFile(io, tmp_copy);
    const counted = try exampleCountFile(io, tmp_copy);
    const digest2 = try exampleHashWhileCopy(io, tmp_path, tmp_copy);

    std.debug.print("copied={d} counted={d} digest={x} digest2={x}\n", .{
        bytes_copied,
        counted,
        digest,
        digest2,
    });

    _ = try examplePositionalAll(io, "/tmp/kilo_io_positional.txt");
}
