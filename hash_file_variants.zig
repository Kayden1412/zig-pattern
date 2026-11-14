const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

/// Terminal hashing writer: file reader -> Writer.Hashing -> digest.
fn hashTerminal(io: std.Io, path: []const u8) !Digest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});

    var hash_buffer: [64 * 1024]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(Sha256) = .init(&hash_buffer);

    _ = try file_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();

    var digest: Digest = undefined;
    hashing.hasher.final(&digest);
    return digest;
}

/// Tee: hash everything while forwarding it to another writer.
fn hashTee(io: std.Io, path: []const u8, out: *std.Io.Writer) !Digest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});

    var hash_buffer: [4 * 1024]u8 = undefined;
    // `Writer.Hashed.init` assumes `Hasher{}` is valid. Sha256 needs
    // `Sha256.init(.{})`, so use `initHasher` instead.
    var hashed: std.Io.Writer.Hashed(Sha256) =
        .initHasher(out, Sha256.init(.{}), &hash_buffer);

    _ = try file_reader.interface.streamRemaining(&hashed.writer);
    try hashed.writer.flush();

    var digest: Digest = undefined;
    hashed.hasher.final(&digest);
    return digest;
}

/// Hash-on-read: wrap the reader, then discard the data.
fn hashOnRead(io: std.Io, path: []const u8) !Digest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buffer: [4 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);

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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const path = if (args.len > 1) args[1] else "hash_file.zig";

    const terminal = try hashTerminal(init.io, path);

    var discard_buffer: [4 * 1024]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);
    const tee = try hashTee(init.io, path, &discarding.writer);

    const on_read = try hashOnRead(init.io, path);

    std.debug.print("terminal: {x}\ntee:      {x}\non-read:  {x}\n", .{
        terminal,
        tee,
        on_read,
    });
}
