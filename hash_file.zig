const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

/// Stream a file into a terminal hashing writer.
pub fn hashFile(io: std.Io, path: []const u8) !Digest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // The reader does not need its own buffer here: File.Reader reads
    // directly into the writer's buffer through `stream`.
    var file_reader = file.reader(io, &.{});

    var hash_buffer: [64 * 1024]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(Sha256) = .init(&hash_buffer);

    // Pump until EOF. `streamRemaining` handles error.EndOfStream.
    _ = try file_reader.interface.streamRemaining(&hashing.writer);

    // The hashing writer buffers; flush the tail into the hasher.
    try hashing.writer.flush();

    var digest: Digest = undefined;
    hashing.hasher.final(&digest);
    return digest;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const path = if (args.len > 1) args[1] else "hash_file.zig";

    const digest = try hashFile(init.io, path);
    std.debug.print("{x}  {s}\n", .{ digest, path });
}
