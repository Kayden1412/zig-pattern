const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Blake3 = std.crypto.hash.Blake3;
const Digest = [32]u8;

const Algo = enum { sha256, blake3 };
const max_iterations = 64;

const VariantResult = struct {
    name: []const u8,
    algo: Algo,
    times: [max_iterations]u64 = undefined,
    n: usize = 0,
    digest: Digest = undefined,
};

var preloaded: []const u8 = &.{};
var persistent_mmap: []const u8 = &.{};
var whole_buffer: []u8 = &.{};

// --- SHA-256 ---------------------------------------------------------------

fn shaStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var hashing: std.Io.Writer.Hashing(Sha256) = .init(buffer);
    _ = try file_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();

    var digest: Digest = undefined;
    hashing.hasher.final(&digest);
    return digest;
}

fn shaManual(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var hasher = Sha256.init(.{});
    while (true) {
        const n = try file_reader.interface.readSliceShort(buffer);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        if (n < buffer.len) break;
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn shaMmapPrefault(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = allocator;
    _ = buffer_size;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const st = try file.stat(io);
    var mm = try file.createMemoryMap(io, .{
        .len = @intCast(st.size),
        .protection = .{ .read = true },
        .populate = true,
    });
    defer mm.destroy(io);

    var digest: Digest = undefined;
    Sha256.hash(mm.memory, &digest, .{});
    return digest;
}

fn shaMmapPersistent(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = io;
    _ = allocator;
    _ = path;
    _ = buffer_size;
    var digest: Digest = undefined;
    Sha256.hash(persistent_mmap, &digest, .{});
    return digest;
}

fn shaPreloaded(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = io;
    _ = allocator;
    _ = path;
    _ = buffer_size;
    var digest: Digest = undefined;
    Sha256.hash(preloaded, &digest, .{});
    return digest;
}

// --- BLAKE3 ----------------------------------------------------------------

fn blake3Stream(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var hashing: std.Io.Writer.Hashing(Blake3) = .init(buffer);
    _ = try file_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();

    var digest: Digest = undefined;
    hashing.hasher.final(&digest);
    return digest;
}

fn blake3Manual(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var hasher = Blake3.init(.{});
    while (true) {
        const n = try file_reader.interface.readSliceShort(buffer);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        if (n < buffer.len) break;
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn blake3MmapPrefault(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = allocator;
    _ = buffer_size;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const st = try file.stat(io);
    var mm = try file.createMemoryMap(io, .{
        .len = @intCast(st.size),
        .protection = .{ .read = true },
        .populate = true,
    });
    defer mm.destroy(io);

    var digest: Digest = undefined;
    Blake3.hash(mm.memory, &digest, .{});
    return digest;
}

fn blake3MmapPersistent(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = io;
    _ = allocator;
    _ = path;
    _ = buffer_size;
    var digest: Digest = undefined;
    Blake3.hash(persistent_mmap, &digest, .{});
    return digest;
}

fn blake3Preloaded(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = io;
    _ = allocator;
    _ = path;
    _ = buffer_size;
    var digest: Digest = undefined;
    Blake3.hash(preloaded, &digest, .{});
    return digest;
}

fn blake3ParallelPreloaded(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = path;
    _ = buffer_size;
    var digest: Digest = undefined;
    try Blake3.hashParallel(preloaded, &digest, .{}, allocator, io);
    return digest;
}

fn blake3ParallelMmapPrefault(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = buffer_size;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const st = try file.stat(io);
    var mm = try file.createMemoryMap(io, .{
        .len = @intCast(st.size),
        .protection = .{ .read = true },
        .populate = true,
    });
    defer mm.destroy(io);

    var digest: Digest = undefined;
    try Blake3.hashParallel(mm.memory, &digest, .{}, allocator, io);
    return digest;
}

fn blake3ParallelWholePrealloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = buffer_size;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    try file_reader.interface.readSliceAll(whole_buffer);

    var digest: Digest = undefined;
    try Blake3.hashParallel(whole_buffer, &digest, .{}, allocator, io);
    return digest;
}

// --- Harness ---------------------------------------------------------------

const Case = struct {
    name: []const u8,
    algo: Algo,
    hash_fn: *const fn (std.Io, std.mem.Allocator, []const u8, usize) anyerror!Digest,
    buffer_size: usize,
};

const max_cases = 16;

fn medianMibPerSecond(times: []const u64, file_size: usize) struct { u64, u64, u64 } {
    var sorted: [max_iterations]u64 = undefined;
    @memcpy(sorted[0..times.len], times);
    std.mem.sort(u64, sorted[0..times.len], {}, std.sort.asc(u64));

    const min_ns = sorted[0];
    const median_ns = sorted[times.len / 2];
    const seconds = @as(f64, @floatFromInt(median_ns)) / std.time.ns_per_s;
    const mib = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);
    const mib_per_s: u64 = @intFromFloat(mib / seconds);
    return .{ median_ns, min_ns, mib_per_s };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "/tmp/opencode/bench.bin";
    var iterations: usize = if (args.len > 2)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        9;
    if (iterations == 0) iterations = 1;
    if (iterations > max_iterations) iterations = max_iterations;

    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    const file_size: usize = @intCast(st.size);

    preloaded = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(preloaded);

    whole_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(whole_buffer);

    var map_file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer map_file.close(io);
    var mm = try map_file.createMemoryMap(io, .{
        .len = file_size,
        .protection = .{ .read = true },
        .populate = true,
    });
    defer mm.destroy(io);
    persistent_mmap = mm.memory;

    const buffer_size = 256 * 1024;

    // Interleaved so each algorithm sees similar thermal conditions.
    const cases = [_]Case{
        .{ .name = "Writer.Hashing", .algo = .sha256, .hash_fn = shaStream, .buffer_size = buffer_size },
        .{ .name = "Writer.Hashing", .algo = .blake3, .hash_fn = blake3Stream, .buffer_size = buffer_size },
        .{ .name = "manual read + update", .algo = .sha256, .hash_fn = shaManual, .buffer_size = buffer_size },
        .{ .name = "manual read + update", .algo = .blake3, .hash_fn = blake3Manual, .buffer_size = buffer_size },
        .{ .name = "mmap (prefault) + hash", .algo = .sha256, .hash_fn = shaMmapPrefault, .buffer_size = 0 },
        .{ .name = "mmap (prefault) + hash", .algo = .blake3, .hash_fn = blake3MmapPrefault, .buffer_size = 0 },
        .{ .name = "mmap (persistent) + hash", .algo = .sha256, .hash_fn = shaMmapPersistent, .buffer_size = 0 },
        .{ .name = "mmap (persistent) + hash", .algo = .blake3, .hash_fn = blake3MmapPersistent, .buffer_size = 0 },
        .{ .name = "hash only (preloaded)", .algo = .sha256, .hash_fn = shaPreloaded, .buffer_size = 0 },
        .{ .name = "hash only (preloaded)", .algo = .blake3, .hash_fn = blake3Preloaded, .buffer_size = 0 },
        .{ .name = "hashParallel (preloaded)", .algo = .blake3, .hash_fn = blake3ParallelPreloaded, .buffer_size = 0 },
        .{ .name = "mmap (prefault) + hashParallel", .algo = .blake3, .hash_fn = blake3ParallelMmapPrefault, .buffer_size = 0 },
        .{ .name = "read prealloc + hashParallel", .algo = .blake3, .hash_fn = blake3ParallelWholePrealloc, .buffer_size = 0 },
    };

    var results: [max_cases]VariantResult = undefined;
    for (cases, 0..) |c, i| {
        results[i] = .{ .name = c.name, .algo = c.algo, .n = iterations };
    }

    for (cases) |c| _ = try c.hash_fn(io, allocator, path, c.buffer_size);

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        var k: usize = 0;
        while (k < cases.len) : (k += 1) {
            const i = (iter + k) % cases.len;
            const c = cases[i];
            const start = std.Io.Clock.awake.now(io);
            const digest = try c.hash_fn(io, allocator, path, c.buffer_size);
            const end = std.Io.Clock.awake.now(io);
            results[i].times[iter] = @intCast(end.nanoseconds - start.nanoseconds);
            results[i].digest = digest;
        }
    }

    std.debug.print("file:  {s}\n", .{path});
    std.debug.print("size:  {d} bytes ({d:.2} MiB), {d} rounds\n\n", .{
        file_size,
        @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0),
        iterations,
    });
    std.debug.print("{s:<8} {s:<26} {s:>13} {s:>13} {s:>10}\n", .{
        "algo", "variant", "median us", "min us", "MiB/s",
    });
    std.debug.print("{s:-<8} {s:-<26} {s:-<13} {s:-<13} {s:-<10}\n", .{
        "", "", "", "", "",
    });

    var expected_sha: ?Digest = null;
    var expected_blake: ?Digest = null;
    for (results[0..cases.len]) |*result| {
        const stat = medianMibPerSecond(result.times[0..result.n], file_size);
        std.debug.print("{s:<8} {s:<26} {d:>13} {d:>13} {d:>10}\n", .{
            @tagName(result.algo),
            result.name,
            stat[0] / std.time.ns_per_us,
            stat[1] / std.time.ns_per_us,
            stat[2],
        });

        const expected = switch (result.algo) {
            .sha256 => &expected_sha,
            .blake3 => &expected_blake,
        };
        if (expected.*) |*e| {
            if (!std.mem.eql(u8, e, &result.digest)) return error.DigestMismatch;
        } else expected.* = result.digest;
    }

    std.debug.print("\nsha256: {x}\n", .{expected_sha.?});
    std.debug.print("blake3: {x}\n", .{expected_blake.?});
}
