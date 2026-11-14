const std = @import("std");
const aead = std.crypto.aead;

const msg_size = 16 * 1024 * 1024;
const ad = "associated data";

fn benchOne(
    comptime A: type,
    comptime label: []const u8,
    msg: []const u8,
    comptime n_rounds: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const key: [A.key_length]u8 = @splat(0);
    var nonce: [A.nonce_length]u8 = @splat(0);
    var tag: [A.tag_length]u8 = undefined;

    const c = try allocator.alloc(u8, msg.len);
    defer allocator.free(c);
    const m2 = try allocator.alloc(u8, msg.len);
    defer allocator.free(m2);

    A.encrypt(c, &tag, msg, ad, nonce, key);
    try A.decrypt(m2, c, tag, ad, nonce, key);
    if (!std.mem.eql(u8, m2, msg)) return error.RoundtripFailed;

    var times: [n_rounds]u64 = undefined;
    for (0..n_rounds) |i| {
        nonce[0] +%= @intCast(i);
        const t0 = std.Io.Clock.awake.now(io);
        A.encrypt(c, &tag, msg, ad, nonce, key);
        const t1 = std.Io.Clock.awake.now(io);
        times[i] = @intCast(t1.nanoseconds - t0.nanoseconds);
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));

    const median = times[n_rounds / 2];
    const mib_per_s: u64 = @intFromFloat(
        (@as(f64, @floatFromInt(msg.len)) / (1024.0 * 1024.0)) /
            (@as(f64, @floatFromInt(median)) / std.time.ns_per_s),
    );

    std.debug.print("{s:<24} key={d:>2} nonce={d:>2} tag={d:>2} {d:>5.2} MiB  {d:>8.2} ms  {d:>6} MiB/s\n", .{
        label,                                                A.key_length,                                         A.nonce_length, A.tag_length,
        @as(f64, @floatFromInt(msg.len)) / (1024.0 * 1024.0), @as(f64, @floatFromInt(median)) / std.time.ns_per_ms, mib_per_s,
    });
}

/// AES-SIV has no fixed nonce length and takes optional ad/nonce.
fn benchSiv(
    comptime A: type,
    comptime label: []const u8,
    msg: []const u8,
    comptime n_rounds: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const key: [A.key_length]u8 = @splat(0);
    const nonce: [16]u8 = @splat(0);
    var tag: [A.tag_length]u8 = undefined;

    const c = try allocator.alloc(u8, msg.len);
    defer allocator.free(c);
    const m2 = try allocator.alloc(u8, msg.len);
    defer allocator.free(m2);

    A.encrypt(c, &tag, msg, ad, nonce[0..], key);
    try A.decrypt(m2, c, tag, ad, nonce[0..], key);
    if (!std.mem.eql(u8, m2, msg)) return error.RoundtripFailed;

    var times: [n_rounds]u64 = undefined;
    for (0..n_rounds) |i| {
        const t0 = std.Io.Clock.awake.now(io);
        A.encrypt(c, &tag, msg, ad, nonce[0..], key);
        const t1 = std.Io.Clock.awake.now(io);
        times[i] = @intCast(t1.nanoseconds - t0.nanoseconds);
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));

    const median = times[n_rounds / 2];
    const mib_per_s: u64 = @intFromFloat(
        (@as(f64, @floatFromInt(msg.len)) / (1024.0 * 1024.0)) /
            (@as(f64, @floatFromInt(median)) / std.time.ns_per_s),
    );

    std.debug.print("{s:<24} key={d:>2} nonce= ? tag={d:>2} {d:>5.2} MiB  {d:>8.2} ms  {d:>6} MiB/s\n", .{
        label,                                                A.key_length,                                         A.tag_length,
        @as(f64, @floatFromInt(msg.len)) / (1024.0 * 1024.0), @as(f64, @floatFromInt(median)) / std.time.ns_per_ms, mib_per_s,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const msg = try allocator.alloc(u8, msg_size);
    defer allocator.free(msg);
    for (msg, 0..) |*b, i| b.* = @truncate(i);

    std.debug.print("message: {d} MiB, 3 rounds, encrypt only\n", .{msg_size / (1024 * 1024)});
    std.debug.print("aes hw: {}  aarch64.aes: {}  neon: {}\n\n", .{
        std.crypto.core.aes.has_hardware_support,
        @import("builtin").cpu.has(.aarch64, .aes),
        @import("builtin").cpu.has(.aarch64, .neon),
    });

    // Interleaved order: fast and slow variants alternate so thermal drift
    // does not systematically favour one family.
    try benchOne(aead.aes_gcm.Aes128Gcm, "AES-128-GCM", msg, 3, allocator, io);
    try benchOne(aead.chacha_poly.ChaCha20Poly1305, "ChaCha20-Poly1305", msg, 3, allocator, io);
    try benchOne(aead.aes_gcm_siv.Aes128GcmSiv, "AES-128-GCM-SIV", msg, 3, allocator, io);
    try benchOne(aead.aegis.Aegis128X2, "AEGIS-128X2", msg, 3, allocator, io);
    try benchOne(aead.aes_ocb.Aes128Ocb, "AES-128-OCB", msg, 3, allocator, io);
    try benchSiv(aead.aes_siv.Aes128Siv, "AES-128-SIV", msg, 3, allocator, io);
    try benchOne(aead.ascon.AsconAead128, "Ascon-AEAD128", msg, 3, allocator, io);
    try benchOne(aead.chacha_poly.XChaCha20Poly1305, "XChaCha20-Poly1305", msg, 3, allocator, io);
    try benchOne(aead.aegis.Aegis128L, "AEGIS-128L", msg, 3, allocator, io);
    try benchOne(aead.aes_gcm.Aes256Gcm, "AES-256-GCM", msg, 3, allocator, io);
    try benchOne(aead.isap.IsapA128A, "ISAP-A-128A", msg, 3, allocator, io);
    try benchOne(aead.aegis.Aegis256X2, "AEGIS-256X2", msg, 3, allocator, io);
    try benchOne(aead.chacha_poly.ChaCha8Poly1305, "ChaCha8-Poly1305", msg, 3, allocator, io);
    try benchOne(aead.aegis.Aegis128X4, "AEGIS-128X4", msg, 3, allocator, io);
    try benchOne(aead.salsa_poly.XSalsa20Poly1305, "XSalsa20-Poly1305", msg, 3, allocator, io);
    try benchOne(aead.aegis.Aegis256X4, "AEGIS-256X4", msg, 3, allocator, io);
    try benchOne(aead.aes_gcm_siv.Aes256GcmSiv, "AES-256-GCM-SIV", msg, 3, allocator, io);
    try benchOne(aead.aegis.Aegis256, "AEGIS-256", msg, 3, allocator, io);
    try benchOne(aead.aes_ocb.Aes256Ocb, "AES-256-OCB", msg, 3, allocator, io);
    try benchSiv(aead.aes_siv.Aes256Siv, "AES-256-SIV", msg, 3, allocator, io);
    try benchOne(aead.aegis.Aegis128X4_256, "AEGIS-128X4-256tag", msg, 3, allocator, io);

    // AES-CCM in std only exports nonce_len=13, so L=2 and the maximum
    // message is 2^16-1 = 65535 bytes. Bench it at 60 KiB.
    const msg_small = try allocator.alloc(u8, 60 * 1024);
    defer allocator.free(msg_small);
    for (msg_small, 0..) |*b, i| b.* = @truncate(i);

    std.debug.print("\nAES-CCM (nonce=13 limits messages to 65535 bytes):\n", .{});
    try benchOne(aead.aes_ccm.Aes128Ccm16, "AES-128-CCM-16", msg_small, 101, allocator, io);
    try benchOne(aead.aes_ccm.Aes256Ccm16, "AES-256-CCM-16", msg_small, 101, allocator, io);
    try benchOne(aead.aes_ccm.Aes128Ccm8, "AES-128-CCM-8", msg_small, 101, allocator, io);
}
