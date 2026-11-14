const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

/// Hash a regular file by mapping it read-only and hashing the mapping.
/// This avoids the page-cache-to-user-buffer copy that `read` performs.
pub fn hashFileMmap(io: std.Io, path: []const u8) !Digest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind != .file) return error.NotRegularFile;

    if (st.size == 0) {
        var digest: Digest = undefined;
        Sha256.hash(&.{}, &digest, .{});
        return digest;
    }

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

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "hash_file_mmap.zig";

    const digest = try hashFileMmap(init.io, path);
    std.debug.print("{x}  {s}\n", .{ digest, path });
}
