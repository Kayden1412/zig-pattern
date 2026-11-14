const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Blake3 = std.crypto.hash.Blake3;
const Digest = [Sha256.digest_length]u8;

const Algo = enum { sha256, blake3 };

const max_iterations = 64;

const VariantResult = struct {
    name: []const u8,
    buffer_label: []const u8,
    algo: Algo = .sha256,
    times: [max_iterations]u64 = undefined,
    n: usize = 0,
    digest: Digest = undefined,
};

/// Direct pipeline: File.Reader -> Writer.Hashing -> Sha256.
fn hashStreaming(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const hash_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(hash_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // Empty reader buffer: File.Reader reads directly into the writer buffer.
    var file_reader = file.reader(io, &.{});

    var hashing: std.Io.Writer.Hashing(Sha256) = .init(hash_buffer);
    _ = try file_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();

    var digest: Digest = undefined;
    hashing.hasher.final(&digest);
    return digest;
}

/// Manual baseline: read into a buffer, call `Sha256.update` per chunk.
fn hashManualUpdate(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const read_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(read_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // Empty reader buffer: `readSliceShort` reads directly into `read_buffer`.
    var file_reader = file.reader(io, &.{});

    var hasher = Sha256.init(.{});
    while (true) {
        const n = try file_reader.interface.readSliceShort(read_buffer);
        if (n == 0) break;
        hasher.update(read_buffer[0..n]);
        if (n < read_buffer.len) break;
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

/// Reader wrapper: `Reader.Hashed` updates the hasher as bytes are consumed.
/// `discardRemaining` then throws the plaintext away.
fn hashReaderHashed(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const read_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(read_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // The wrapper's `discard` path peeks from the underlying reader, so give
    // the underlying File.Reader the buffer here.
    var file_reader = file.reader(io, read_buffer);

    var hashed_reader = std.Io.Reader.hashed(
        &file_reader.interface,
        Sha256.init(.{}),
        &.{},
    );

    _ = try hashed_reader.reader.discardRemaining();

    var digest: Digest = undefined;
    hashed_reader.hasher.final(&digest);
    return digest;
}

/// Manual read/update with a page-aligned buffer.
fn hashManualAligned(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const read_buffer = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        buffer_size,
    );
    defer allocator.free(read_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});

    var hasher = Sha256.init(.{});
    while (true) {
        const n = try file_reader.interface.readSliceShort(read_buffer);
        if (n == 0) break;
        hasher.update(read_buffer[0..n]);
        if (n < read_buffer.len) break;
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

/// Hash-on-read wrapper streaming into a discarding writer.
fn hashReaderHashedStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const discard_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(discard_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // Empty file-reader buffer; the wrapper reads into the writer buffer.
    var file_reader = file.reader(io, &.{});

    var hashed_reader = std.Io.Reader.hashed(
        &file_reader.interface,
        Sha256.init(.{}),
        &.{},
    );

    var discarding: std.Io.Writer.Discarding = .init(discard_buffer);
    _ = try hashed_reader.reader.streamRemaining(&discarding.writer);

    var digest: Digest = undefined;
    hashed_reader.hasher.final(&digest);
    return digest;
}

/// Memory-map the file and hash the mapping directly, with no read copy.
/// `prefault` controls whether the mapping is populated up front.
fn hashMmapImpl(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
    comptime prefault: bool,
) anyerror!Digest {
    _ = allocator;
    _ = buffer_size;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const st = try file.stat(io);
    var mm = try file.createMemoryMap(io, .{
        .len = @intCast(st.size),
        .protection = .{ .read = true },
        .populate = prefault,
    });
    defer mm.destroy(io);

    var digest: Digest = undefined;
    Sha256.hash(mm.memory, &digest, .{});
    return digest;
}

fn hashMmapPrefault(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    return hashMmapImpl(io, allocator, path, buffer_size, true);
}

fn hashMmapLazy(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    return hashMmapImpl(io, allocator, path, buffer_size, false);
}

/// Read the entire file into memory, then make one direct `Sha256.hash` call.
fn hashWholeFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = buffer_size;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);

    var digest: Digest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn blake3Streaming(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const hash_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(hash_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    var hashing: std.Io.Writer.Hashing(Blake3) = .init(hash_buffer);
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
    const read_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(read_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});

    var hasher = Blake3.init(.{});
    while (true) {
        const n = try file_reader.interface.readSliceShort(read_buffer);
        if (n == 0) break;
        hasher.update(read_buffer[0..n]);
        if (n < read_buffer.len) break;
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn blake3ReaderHashed(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    const read_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(read_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, read_buffer);
    var hashed_reader = std.Io.Reader.hashed(
        &file_reader.interface,
        Blake3.init(.{}),
        &.{},
    );

    _ = try hashed_reader.reader.discardRemaining();

    var digest: Digest = undefined;
    hashed_reader.hasher.final(&digest);
    return digest;
}

fn blake3MmapImpl(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
    comptime prefault: bool,
) anyerror!Digest {
    _ = allocator;
    _ = buffer_size;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const st = try file.stat(io);
    var mm = try file.createMemoryMap(io, .{
        .len = @intCast(st.size),
        .protection = .{ .read = true },
        .populate = prefault,
    });
    defer mm.destroy(io);

    var digest: Digest = undefined;
    Blake3.hash(mm.memory, &digest, .{});
    return digest;
}

fn blake3MmapPrefault(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    return blake3MmapImpl(io, allocator, path, buffer_size, true);
}

fn blake3MmapLazy(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    return blake3MmapImpl(io, allocator, path, buffer_size, false);
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
    Blake3.hash(persistent_mmap_memory, &digest, .{});
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
    Blake3.hash(preloaded_bytes, &digest, .{});
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
    try Blake3.hashParallel(preloaded_bytes, &digest, .{}, allocator, io);
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

const Stat = struct {
    median_ns: u64,
    min_ns: u64,
    mib_per_s: u64,
};

fn computeStat(result: *const VariantResult, file_size: usize) Stat {
    var sorted: [max_iterations]u64 = undefined;
    @memcpy(sorted[0..result.n], result.times[0..result.n]);
    std.mem.sort(u64, sorted[0..result.n], {}, std.sort.asc(u64));

    const min_ns = sorted[0];
    const median_ns = sorted[result.n / 2];
    const seconds = @as(f64, @floatFromInt(median_ns)) / std.time.ns_per_s;
    const mib = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);
    const mib_per_s: u64 = @intFromFloat(mib / seconds);
    return .{
        .median_ns = median_ns,
        .min_ns = min_ns,
        .mib_per_s = mib_per_s,
    };
}

fn printHeader() void {
    std.debug.print(
        "{s:<38} {s:>9} {s:>13} {s:>13} {s:>10}\n",
        .{ "variant", "buffer", "median us", "min us", "MiB/s" },
    );
    std.debug.print(
        "{s:-<38} {s:-<9} {s:-<13} {s:-<13} {s:-<10}\n",
        .{ "", "", "", "", "" },
    );
}

fn printResult(result: *const VariantResult, file_size: usize) void {
    const stat = computeStat(result, file_size);
    std.debug.print(
        "{s:<38} {s:>9} {d:>13} {d:>13} {d:>10}\n",
        .{
            result.name,
            result.buffer_label,
            stat.median_ns / std.time.ns_per_us,
            stat.min_ns / std.time.ns_per_us,
            stat.mib_per_s,
        },
    );
}

const max_cases = 40;

const Case = struct {
    name: []const u8,
    buffer_label: []const u8,
    algo: Algo = .sha256,
    hash_fn: *const fn (std.Io, std.mem.Allocator, []const u8, usize) anyerror!Digest,
    buffer_size: usize,
};

var preloaded_bytes: []const u8 = &.{};
var persistent_mmap_memory: []const u8 = &.{};
var whole_buffer: []u8 = &.{};

fn hashWholePrealloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    buffer_size: usize,
) anyerror!Digest {
    _ = allocator;
    _ = buffer_size;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    try file_reader.interface.readSliceAll(whole_buffer);

    var digest: Digest = undefined;
    Sha256.hash(whole_buffer, &digest, .{});
    return digest;
}

fn hashMmapPersistent(
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
    Sha256.hash(persistent_mmap_memory, &digest, .{});
    return digest;
}

fn hashPreloaded(
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
    Sha256.hash(preloaded_bytes, &digest, .{});
    return digest;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "/tmp/opencode/bench.bin";

    var iterations: usize = if (args.len > 2)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        7;
    if (iterations == 0) iterations = 1;
    if (iterations > max_iterations) iterations = max_iterations;

    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    const file_size: usize = @intCast(stat.size);

    preloaded_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(preloaded_bytes);

    whole_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(whole_buffer);

    var map_file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer map_file.close(io);
    var persistent_map = try map_file.createMemoryMap(io, .{
        .len = file_size,
        .protection = .{ .read = true },
        .populate = true,
    });
    defer persistent_map.destroy(io);
    persistent_mmap_memory = persistent_map.memory;

    std.debug.print("file:  {s}\n", .{path});
    std.debug.print("size:  {d} bytes ({d:.2} MiB)\n", .{
        file_size,
        @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0),
    });
    std.debug.print("iters: {d} recorded + 1 warmup (all cases per round)\n\n", .{iterations});

    const buffer_sizes = [_]usize{
        64 * 1024,
        256 * 1024,
        1024 * 1024,
    };
    const buffer_labels = [_][]const u8{
        "64 KiB",
        "256 KiB",
        "1 MiB",
    };

    var cases: [max_cases]Case = undefined;
    var case_count: usize = 0;

    for (buffer_sizes, buffer_labels) |buffer_size, label| {
        cases[case_count] = .{
            .name = "File.Reader -> Writer.Hashing",
            .buffer_label = label,
            .hash_fn = hashStreaming,
            .buffer_size = buffer_size,
        };
        case_count += 1;
        cases[case_count] = .{
            .name = "manual read + Sha256.update",
            .buffer_label = label,
            .hash_fn = hashManualUpdate,
            .buffer_size = buffer_size,
        };
        case_count += 1;
        cases[case_count] = .{
            .name = "Reader.Hashed + discardRemaining",
            .buffer_label = label,
            .hash_fn = hashReaderHashed,
            .buffer_size = buffer_size,
        };
        case_count += 1;
    }

    cases[case_count] = .{
        .name = "manual read + update (page-aligned)",
        .buffer_label = "256 KiB",
        .hash_fn = hashManualAligned,
        .buffer_size = 256 * 1024,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "Reader.Hashed -> stream to Discarding",
        .buffer_label = "256 KiB",
        .hash_fn = hashReaderHashedStream,
        .buffer_size = 256 * 1024,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "mmap (persistent) + Sha256.hash",
        .buffer_label = "-",
        .hash_fn = hashMmapPersistent,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "mmap (prefault) + Sha256.hash",
        .buffer_label = "-",
        .hash_fn = hashMmapPrefault,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "mmap (lazy) + Sha256.hash",
        .buffer_label = "-",
        .hash_fn = hashMmapLazy,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "read into preallocated buffer + hash",
        .buffer_label = "-",
        .hash_fn = hashWholePrealloc,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "read entire file + Sha256.hash",
        .buffer_label = "-",
        .hash_fn = hashWholeFile,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "Sha256.hash only (preloaded)",
        .buffer_label = "-",
        .hash_fn = hashPreloaded,
        .buffer_size = 0,
    };
    case_count += 1;

    for (buffer_sizes, buffer_labels) |buffer_size, label| {
        cases[case_count] = .{
            .name = "BLAKE3: File.Reader -> Writer.Hashing",
            .buffer_label = label,
            .algo = .blake3,
            .hash_fn = blake3Streaming,
            .buffer_size = buffer_size,
        };
        case_count += 1;
        cases[case_count] = .{
            .name = "BLAKE3: manual read + update",
            .buffer_label = label,
            .algo = .blake3,
            .hash_fn = blake3Manual,
            .buffer_size = buffer_size,
        };
        case_count += 1;
        cases[case_count] = .{
            .name = "BLAKE3: Reader.Hashed + discard",
            .buffer_label = label,
            .algo = .blake3,
            .hash_fn = blake3ReaderHashed,
            .buffer_size = buffer_size,
        };
        case_count += 1;
    }

    cases[case_count] = .{
        .name = "BLAKE3: mmap (persistent) + hash",
        .buffer_label = "-",
        .algo = .blake3,
        .hash_fn = blake3MmapPersistent,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "BLAKE3: mmap (prefault) + hash",
        .buffer_label = "-",
        .algo = .blake3,
        .hash_fn = blake3MmapPrefault,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "BLAKE3: mmap (lazy) + hash",
        .buffer_label = "-",
        .algo = .blake3,
        .hash_fn = blake3MmapLazy,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "BLAKE3: hash only (preloaded)",
        .buffer_label = "-",
        .algo = .blake3,
        .hash_fn = blake3Preloaded,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "BLAKE3: hashParallel (preloaded)",
        .buffer_label = "-",
        .algo = .blake3,
        .hash_fn = blake3ParallelPreloaded,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "BLAKE3: mmap (prefault) + hashParallel",
        .buffer_label = "-",
        .algo = .blake3,
        .hash_fn = blake3ParallelMmapPrefault,
        .buffer_size = 0,
    };
    case_count += 1;
    cases[case_count] = .{
        .name = "BLAKE3: read prealloc + hashParallel",
        .buffer_label = "-",
        .algo = .blake3,
        .hash_fn = blake3ParallelWholePrealloc,
        .buffer_size = 0,
    };
    case_count += 1;

    var results: [max_cases]VariantResult = undefined;
    for (cases[0..case_count], 0..) |c, i| {
        results[i] = .{
            .name = c.name,
            .buffer_label = c.buffer_label,
            .algo = c.algo,
            .n = iterations,
        };
    }

    // Warm up every case once.
    for (cases[0..case_count]) |c| {
        _ = try c.hash_fn(io, allocator, path, c.buffer_size);
    }

    // Round-robin with a rotating start index: every case runs once per
    // round, and no case is always first or last. This averages out thermal
    // and frequency drift across all cases.
    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        var k: usize = 0;
        while (k < case_count) : (k += 1) {
            const i = (iter + k) % case_count;
            const c = cases[i];

            const start = std.Io.Clock.awake.now(io);
            const digest = try c.hash_fn(io, allocator, path, c.buffer_size);
            const end = std.Io.Clock.awake.now(io);

            results[i].times[iter] = @intCast(end.nanoseconds - start.nanoseconds);
            results[i].digest = digest;
        }
    }

    printHeader();

    var expected_sha256: ?Digest = null;
    var expected_blake3: ?Digest = null;
    for (results[0..case_count]) |*result| {
        const expected = switch (result.algo) {
            .sha256 => &expected_sha256,
            .blake3 => &expected_blake3,
        };
        if (expected.*) |*e| {
            if (!std.mem.eql(u8, e, &result.digest)) return error.DigestMismatch;
        } else expected.* = result.digest;
        printResult(result, file_size);
    }

    std.debug.print("\nsha256: {x}\n", .{expected_sha256.?});
    std.debug.print("blake3: {x}\n", .{expected_blake3.?});
}
