const std = @import("std");

// Vendored from ziglang/zig master (codeberg), which has `Blake3.updateParallel`.
const Blake3 = @import("blake3_master.zig").Blake3;

const Digest = [32]u8;

const expected_b3sum_digest: Digest = .{
    0x79, 0x46, 0x83, 0x09, 0xc3, 0x90, 0xd0, 0x59,
    0x6a, 0x43, 0xdf, 0x5a, 0xa4, 0x58, 0x0d, 0x7e,
    0xb1, 0xf8, 0xbb, 0xd6, 0x56, 0x28, 0x8a, 0x38,
    0x45, 0x5d, 0x9e, 0x19, 0x6a, 0xd6, 0x80, 0x53,
};

const max_iterations = 64;

var preloaded: []const u8 = &.{};

/// One reusable read buffer for every streaming case, so the benchmark does
/// not pay mmap/page-fault costs on every round.
var read_buffer: []u8 = &.{};

/// Static storage for the fixed-allocator variant. Peak need for a 64 MiB
/// input is cvs (2 MiB) + two tree buffers (1.5 MiB).
var fba_storage: [8 * 1024 * 1024]u8 = undefined;

const VariantResult = struct {
    name: []const u8,
    buffer_label: []const u8,
    times: [max_iterations]u64 = undefined,
    n: usize = 0,
    digest: Digest = undefined,
};

/// Baseline: sequential streaming hash over small read buffers.
fn sequentialUpdate(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = allocator;
    const buffer = read_buffer[0..@min(buffer_size, read_buffer.len)];

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

/// Streaming parallel: bounded read buffer, each full buffer hashed with
/// `updateParallel`. Inputs below 3 MiB fall back to sequential internally.
fn streamingParallel(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const buffer = read_buffer[0..@min(buffer_size, read_buffer.len)];

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var hasher = Blake3.init(.{});

    while (true) {
        const n = try file_reader.interface.readSliceShort(buffer);
        if (n == 0) break;
        try hasher.updateParallel(buffer[0..n], allocator, io);
        if (n < buffer.len) break;
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

/// Same as streamingParallel, but updateParallel's temporary allocations come
/// from a fresh fixed buffer, so malloc/mmap cost is excluded.
fn streamingParallelFixedAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = allocator;
    const buffer = read_buffer[0..@min(buffer_size, read_buffer.len)];

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var hasher = Blake3.init(.{});
    var fba = std.heap.FixedBufferAllocator.init(&fba_storage);

    while (true) {
        const n = try file_reader.interface.readSliceShort(buffer);
        if (n == 0) break;
        // Fresh per call: updateParallel frees everything before returning.
        fba.reset();
        try hasher.updateParallel(buffer[0..n], fba.allocator(), io);
        if (n < buffer.len) break;
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashParallelPreloaded(
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

fn hashSequentialPreloaded(
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

const Case = struct {
    name: []const u8,
    buffer_label: []const u8,
    hash_fn: *const fn (std.Io, std.mem.Allocator, []const u8, usize) anyerror!Digest,
    buffer_size: usize,
};

const Stat = struct {
    median_ns: u64,
    min_ns: u64,
    mib_per_s: u64,
};

fn computeStat(times: []const u64, file_size: usize) Stat {
    var sorted: [max_iterations]u64 = undefined;
    @memcpy(sorted[0..times.len], times);
    std.mem.sort(u64, sorted[0..times.len], {}, std.sort.asc(u64));

    const min_ns = sorted[0];
    const median_ns = sorted[times.len / 2];
    const seconds = @as(f64, @floatFromInt(median_ns)) / std.time.ns_per_s;
    const mib = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);
    const mib_per_s: u64 = @intFromFloat(mib / seconds);

    return .{ .median_ns = median_ns, .min_ns = min_ns, .mib_per_s = mib_per_s };
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

    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    const file_size: usize = @intCast(stat.size);

    preloaded = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(preloaded);

    read_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(read_buffer);

    const mib = 1024 * 1024;
    const cases = [_]Case{
        .{ .name = "update (sequential)", .buffer_label = "256 KiB", .hash_fn = sequentialUpdate, .buffer_size = 256 * 1024 },
        .{ .name = "updateParallel", .buffer_label = "3 MiB", .hash_fn = streamingParallel, .buffer_size = 3 * mib },
        .{ .name = "updateParallel", .buffer_label = "4 MiB", .hash_fn = streamingParallel, .buffer_size = 4 * mib },
        .{ .name = "updateParallel", .buffer_label = "8 MiB", .hash_fn = streamingParallel, .buffer_size = 8 * mib },
        .{ .name = "updateParallel", .buffer_label = "16 MiB", .hash_fn = streamingParallel, .buffer_size = 16 * mib },
        .{ .name = "updateParallel", .buffer_label = "32 MiB", .hash_fn = streamingParallel, .buffer_size = 32 * mib },
        .{ .name = "updateParallel", .buffer_label = "64 MiB", .hash_fn = streamingParallel, .buffer_size = 64 * mib },
        .{ .name = "updateParallel (fixed alloc)", .buffer_label = "16 MiB", .hash_fn = streamingParallelFixedAlloc, .buffer_size = 16 * mib },
        .{ .name = "updateParallel (fixed alloc)", .buffer_label = "64 MiB", .hash_fn = streamingParallelFixedAlloc, .buffer_size = 64 * mib },
        .{ .name = "hashParallel (preloaded)", .buffer_label = "-", .hash_fn = hashParallelPreloaded, .buffer_size = 0 },
        .{ .name = "hash (preloaded)", .buffer_label = "-", .hash_fn = hashSequentialPreloaded, .buffer_size = 0 },
    };

    var results: [cases.len]VariantResult = undefined;
    for (cases, 0..) |c, i| {
        results[i] = .{
            .name = c.name,
            .buffer_label = c.buffer_label,
            .n = iterations,
        };
    }

    // Warmup.
    for (cases) |c| _ = try c.hash_fn(io, allocator, path, c.buffer_size);

    // Round-robin with rotating start index to spread thermal/frequency drift.
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
    std.debug.print("size:  {d} bytes ({d:.2} MiB), {d} rounds\n", .{
        file_size,
        @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0),
        iterations,
    });
    std.debug.print("cores: {d}\n\n", .{try std.Thread.getCpuCount()});

    std.debug.print("{s:<32} {s:>10} {s:>13} {s:>13} {s:>10}\n", .{
        "variant", "buffer", "median us", "min us", "MiB/s",
    });
    std.debug.print("{s:-<32} {s:->10} {s:->13} {s:->13} {s:->10}\n", .{
        "", "", "", "", "",
    });

    for (results[0..cases.len]) |*result| {
        const s = computeStat(result.times[0..result.n], file_size);
        std.debug.print("{s:<32} {s:>10} {d:>13} {d:>13} {d:>10}\n", .{
            result.name,
            result.buffer_label,
            s.median_ns / std.time.ns_per_us,
            s.min_ns / std.time.ns_per_us,
            s.mib_per_s,
        });
    }

    // Verify every variant against b3sum.
    for (results[0..cases.len]) |*result| {
        if (!std.mem.eql(u8, &result.digest, &expected_b3sum_digest)) {
            std.debug.print("\nMISMATCH for {s} ({s}): {x}\n", .{
                result.name, result.buffer_label, result.digest,
            });
            return error.DigestMismatch;
        }
    }

    std.debug.print("\nblake3: {x} (matched b3sum for all variants)\n", .{
        expected_b3sum_digest,
    });
}
