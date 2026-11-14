const std = @import("std");
const crypto = std.crypto;
const hmac = crypto.auth.hmac;
const cmac = crypto.auth.cmac;
const cbc_mac = crypto.auth.cbc_mac;
const siphash = crypto.auth.siphash;
const aegis = crypto.auth.aegis;

const msg_size = 64 * 1024 * 1024;
const n_rounds = 5;
const timeout_ns: u64 = 30 * std.time.ns_per_ms;

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sizeLabel(buf: []u8, n: usize) []const u8 {
    if (n >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d} MiB", .{n / (1024 * 1024)}) catch "?";
    if (n >= 1024) return std.fmt.bufPrint(buf, "{d} KiB", .{n / 1024}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

fn report(comptime label: []const u8, key_len: usize, msg_len: usize, median_ns: u64, min_ns: u64) void {
    var sbuf: [32]u8 = undefined;
    const sz = sizeLabel(&sbuf, msg_len);
    const ops_s: f64 = if (median_ns == 0) 0 else @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(median_ns));
    const mib_s = (@as(f64, @floatFromInt(msg_len)) / (1024.0 * 1024.0)) * ops_s;
    std.debug.print(
        "{s:<26} key={d:>3} {s:>7}  {d:>11.1} ns/op (min {d:>11.1})  {d:>12.0} ops/s  {d:>8.1} MiB/s\n",
        .{
            label,
            key_len,
            sz,
            @as(f64, @floatFromInt(median_ns)),
            @as(f64, @floatFromInt(min_ns)),
            ops_s,
            mib_s,
        },
    );
}

fn benchHmac(
    comptime H: type,
    comptime label: []const u8,
    msg: []const u8,
    key: []const u8,
    io: std.Io,
) !void {
    var tag: [H.mac_length]u8 = undefined;

    // For small messages, calibrate the inner iteration count so each timed
    // round lasts roughly `timeout_ns`.
    var iters: u64 = 1;
    if (msg.len < 1024 * 1024) {
        const cal: u64 = 128;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < cal) : (i += 1) {
            @call(.never_inline, H.create, .{ &tag, msg, key });
            std.mem.doNotOptimizeAway(&tag);
        }
        const per = @max((nowNs(io) - t0) / cal, 1);
        iters = std.math.clamp(timeout_ns / per, 1, 10_000_000);
    }

    @call(.never_inline, H.create, .{ &tag, msg, key });
    std.mem.doNotOptimizeAway(&tag);

    var times: [n_rounds]u64 = undefined;
    for (&times) |*t| {
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            @call(.never_inline, H.create, .{ &tag, msg, key });
            std.mem.doNotOptimizeAway(&tag);
        }
        t.* = (nowNs(io) - t0) / iters;
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    report(label, key.len, msg.len, times[n_rounds / 2], times[0]);
}

fn hmacStream(
    comptime H: type,
    tag: *[H.mac_length]u8,
    msg: []const u8,
    key: []const u8,
    comptime chunk: usize,
) void {
    var ctx = H.init(key);
    var off: usize = 0;
    while (off < msg.len) : (off += chunk) {
        ctx.update(msg[off..@min(off + chunk, msg.len)]);
    }
    ctx.final(tag);
}

fn benchHmacStream(
    comptime H: type,
    comptime label: []const u8,
    msg: []const u8,
    key: []const u8,
    comptime chunk: usize,
    io: std.Io,
) !void {
    var tag: [H.mac_length]u8 = undefined;
    @call(.never_inline, hmacStream, .{ H, &tag, msg, key, chunk });
    std.mem.doNotOptimizeAway(&tag);

    var times: [n_rounds]u64 = undefined;
    for (&times) |*t| {
        const t0 = nowNs(io);
        @call(.never_inline, hmacStream, .{ H, &tag, msg, key, chunk });
        std.mem.doNotOptimizeAway(&tag);
        t.* = nowNs(io) - t0;
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    report(label, key.len, msg.len, times[n_rounds / 2], times[0]);
}

fn benchMac(
    comptime M: type,
    comptime label: []const u8,
    msg: []const u8,
    key: *const [M.key_length]u8,
    io: std.Io,
) !void {
    var tag: [M.mac_length]u8 = undefined;

    var iters: u64 = 1;
    if (msg.len < 1024 * 1024) {
        const cal: u64 = 128;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < cal) : (i += 1) {
            @call(.never_inline, M.create, .{ &tag, msg, key });
            std.mem.doNotOptimizeAway(&tag);
        }
        const per = @max((nowNs(io) - t0) / cal, 1);
        iters = std.math.clamp(timeout_ns / per, 1, 10_000_000);
    }

    @call(.never_inline, M.create, .{ &tag, msg, key });
    std.mem.doNotOptimizeAway(&tag);

    var times: [n_rounds]u64 = undefined;
    for (&times) |*t| {
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            @call(.never_inline, M.create, .{ &tag, msg, key });
            std.mem.doNotOptimizeAway(&tag);
        }
        t.* = (nowNs(io) - t0) / iters;
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    report(label, M.key_length, msg.len, times[n_rounds / 2], times[0]);
}

fn macStream(
    comptime M: type,
    tag: *[M.mac_length]u8,
    msg: []const u8,
    key: *const [M.key_length]u8,
    comptime chunk: usize,
) void {
    var ctx = M.init(key);
    var off: usize = 0;
    while (off < msg.len) : (off += chunk) {
        ctx.update(msg[off..@min(off + chunk, msg.len)]);
    }
    ctx.final(tag);
}

fn benchMacStream(
    comptime M: type,
    comptime label: []const u8,
    msg: []const u8,
    key: *const [M.key_length]u8,
    comptime chunk: usize,
    io: std.Io,
) !void {
    var tag: [M.mac_length]u8 = undefined;
    @call(.never_inline, macStream, .{ M, &tag, msg, key, chunk });
    std.mem.doNotOptimizeAway(&tag);

    var times: [n_rounds]u64 = undefined;
    for (&times) |*t| {
        const t0 = nowNs(io);
        @call(.never_inline, macStream, .{ M, &tag, msg, key, chunk });
        std.mem.doNotOptimizeAway(&tag);
        t.* = nowNs(io) - t0;
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    report(label, M.key_length, msg.len, times[n_rounds / 2], times[0]);
}

fn expectHex(comptime label: []const u8, comptime expected: []const u8, bytes: anytype) !void {
    const hex = std.fmt.bytesToHex(bytes.*, .lower);
    if (!std.mem.eql(u8, hex[0..], expected)) {
        std.debug.print("verify FAIL {s}\n  got      {s}\n  expected {s}\n", .{ label, hex[0..], expected });
        return error.VerificationFailed;
    }
    std.debug.print("verify OK   {s}\n", .{label});
}

fn verifyHmac(
    comptime H: type,
    comptime label: []const u8,
    msg: []const u8,
    key: []const u8,
    comptime expected: []const u8,
) !void {
    var tag: [H.mac_length]u8 = undefined;
    @call(.never_inline, H.create, .{ &tag, msg, key });
    try expectHex(label, expected, &tag);
}

fn verify(msg: []const u8, keys: []const u8) !void {
    var raw: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(msg, &raw, .{});
    try expectHex("SHA-256 pattern", "281e519df3077b557c6b03f5da83c4e8d397219259615dd7c3308f89cae8f2a6", &raw);

    try verifyHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k32", msg, keys[0..32], "d66ae82bb011487244e98bd45599cb6a009684aa1e2aae15a56c89f1c634bf12");
    try verifyHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k64", msg, keys[0..64], "31d974754c7547c4a50bf413fb770475ecd2add8575d60bd00bcc0ef6d1afc71");
    try verifyHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k100", msg, keys[0..100], "f46caaab837ac6f4ee6f933288d31d4edb9362b0daca8e39748fcdf7532b6002");
    try verifyHmac(hmac.sha2.HmacSha512, "HMAC-SHA512 k64", msg, keys[0..64], "3fef17afe072bcd9e4d37e78e1c0466aca46ac29c75351daf4a5a1f63f972bd7e411d8507aa9c12b82172c7570d71bc8da28975c0ee14c7ef045abb32fab6527");
    try verifyHmac(hmac.sha2.HmacSha384, "HMAC-SHA384 k48", msg, keys[0..48], "d65f9eef42766abf0fa0b634eee015d9dd575c44eea0cdc75b25456797e867be8a3719e1337b7fd4efd58a8d668fc522");
    try verifyHmac(hmac.sha2.HmacSha224, "HMAC-SHA224 k28", msg, keys[0..28], "596e2418ec5fc41d8b23ad517fd1c990441087daed76a2ce84470f2d");
    try verifyHmac(hmac.HmacSha1, "HMAC-SHA1 k20", msg, keys[0..20], "af27ed96dc993bb94faa20eb5f3db30101ea130f");
    try verifyHmac(hmac.HmacMd5, "HMAC-MD5 k16", msg, keys[0..16], "462f3a21e6c7ac9baf041d11581048a3");
    try verifyHmac(hmac.Hmac(crypto.hash.Blake3), "HMAC-BLAKE3 k32", msg, keys[0..32], "bdc8f5904b7d62e5bfd091a1cd75a1d6f79f9921bb0a89f164dabb5f41d2b2e4");
    try verifyHmac(hmac.Hmac(crypto.hash.blake2.Blake2b512), "HMAC-BLAKE2b512 k64", msg, keys[0..64], "f3bef8ac66f3702106e75dc8bb0e4527b1638188952cb5129c41006effa77b79032b021ff61d4762688620748b3a48cde9138975253d535c19f6866e1025c719");
    try verifyHmac(hmac.Hmac(crypto.hash.blake2.Blake2s256), "HMAC-BLAKE2s256 k32", msg, keys[0..32], "0f685f6402eab22e0eb20c5340491b7de5c8e55d46780cb8eb56d15a183ceb5c");

    {
        const key = [_]u8{ 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c };
        var tag: [16]u8 = undefined;
        cmac.CmacAes128.create(&tag, "", &key);
        try expectHex("CMAC-AES128 empty (RFC 4493)", "bb1d6929e95937287fa37d129b756746", &tag);
        cmac.CmacAes128.create(&tag, &[_]u8{ 0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a }, &key);
        try expectHex("CMAC-AES128 16B (RFC 4493)", "070a16b46b4d4144f79bdd9dd04a287c", &tag);

        cbc_mac.CbcMacAes128.create(&tag, "", &key);
        try expectHex("CBC-MAC-AES128 empty", "7df76b0c1ab899b33e42f047b91b546f", &tag);
        cbc_mac.CbcMacAes128.create(&tag, &[_]u8{ 0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a }, &key);
        try expectHex("CBC-MAC-AES128 16B", "3ad77bb40d7a3660a89ecaf32466ef97", &tag);
    }

    {
        const key: [16]u8 = @splat(0);
        var tag: [32]u8 = undefined;
        aegis.Aegis128LMac.create(&tag, msg[0..64], &key);
        try expectHex("AEGIS-128L-MAC 64B vector", "f5eb88d90b7d31c9a679eb94ed1374cd14816b19cdb77930d1a5158f8595983b", &tag);
    }
    {
        var key: [16]u8 = @splat(0);
        key[0] = 0x10;
        key[1] = 0x01;
        var nonce: [16]u8 = @splat(0);
        nonce[0] = 0x10;
        nonce[1] = 0x00;
        nonce[2] = 0x02;
        var m: [35]u8 = undefined;
        for (&m, 0..) |*b, i| b.* = @truncate(i);
        var tag: [16]u8 = undefined;
        aegis.Aegis128LMac_128.createWithNonce(&tag, &m, &key, &nonce);
        try expectHex("AEGIS-128L-MAC-128 vector", "d3f09b2842ad301687d6902c921d7818", &tag);
    }
    {
        var key: [32]u8 = @splat(0);
        key[0] = 0x10;
        key[1] = 0x01;
        var nonce: [32]u8 = @splat(0);
        nonce[0] = 0x10;
        nonce[1] = 0x00;
        nonce[2] = 0x02;
        var m: [35]u8 = undefined;
        for (&m, 0..) |*b, i| b.* = @truncate(i);
        var tag: [16]u8 = undefined;
        aegis.Aegis256Mac_128.createWithNonce(&tag, &m, &key, &nonce);
        try expectHex("AEGIS-256-MAC-128 vector", "c08e20cfc56f27195a46c9cef5c162d4", &tag);
    }

    {
        const Sip64 = siphash.SipHash64(2, 4);
        const key = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
        var tag: [8]u8 = undefined;
        Sip64.create(&tag, "", &key);
        try expectHex("SipHash64-2-4 empty vector", "310e0edd47db6f72", &tag);

        const Sip128 = siphash.SipHash128(2, 4);
        var tag128: [16]u8 = undefined;
        Sip128.create(&tag128, "", &key);
        try expectHex("SipHash128-2-4 empty vector", "a3817f04ba25a8e66df67214c7550293", &tag128);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const msg = try allocator.alloc(u8, msg_size);
    defer allocator.free(msg);
    for (msg, 0..) |*b, i| b.* = @truncate(i);

    var keys: [100]u8 = undefined;
    for (&keys, 0..) |*b, i| b.* = @truncate(i);

    std.debug.print("HMAC + MAC benchmark\n", .{});
    std.debug.print("message: {d} MiB, {d} rounds, median, single-threaded\n", .{ msg_size / (1024 * 1024), n_rounds });
    std.debug.print("aes hw: {}  aarch64.aes: {}  neon: {}\n\n", .{
        crypto.core.aes.has_hardware_support,
        @import("builtin").cpu.has(.aarch64, .aes),
        @import("builtin").cpu.has(.aarch64, .neon),
    });

    try verify(msg, keys[0..]);
    std.debug.print("\n", .{});

    const z16: [16]u8 = @splat(0);
    const z32: [32]u8 = @splat(0);

    std.debug.print("=== HMAC, 64 MiB ===\n", .{});
    try benchHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k32", msg, keys[0..32], io);
    try benchHmac(hmac.sha2.HmacSha512, "HMAC-SHA512 k64", msg, keys[0..64], io);
    try benchHmac(hmac.Hmac(crypto.hash.Blake3), "HMAC-BLAKE3 k32", msg, keys[0..32], io);
    try benchHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k64", msg, keys[0..64], io);
    try benchHmac(hmac.sha2.HmacSha384, "HMAC-SHA384 k48", msg, keys[0..48], io);
    try benchHmac(hmac.Hmac(crypto.hash.blake2.Blake2b512), "HMAC-BLAKE2b512 k64", msg, keys[0..64], io);
    try benchHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k100", msg, keys[0..100], io);
    try benchHmac(hmac.sha2.HmacSha224, "HMAC-SHA224 k28", msg, keys[0..28], io);
    try benchHmac(hmac.Hmac(crypto.hash.blake2.Blake2s256), "HMAC-BLAKE2s256 k32", msg, keys[0..32], io);
    try benchHmac(hmac.HmacSha1, "HMAC-SHA1 k20", msg, keys[0..20], io);
    try benchHmac(hmac.HmacMd5, "HMAC-MD5 k16", msg, keys[0..16], io);
    try benchHmacStream(hmac.sha2.HmacSha256, "HMAC-SHA256 stream 64K", msg, keys[0..32], 64 * 1024, io);

    std.debug.print("\n=== MAC, 64 MiB ===\n", .{});
    try benchMac(aegis.Aegis128LMac_128, "AEGIS-128L-MAC-128", msg, &z16, io);
    try benchMac(aegis.Aegis128X2Mac_128, "AEGIS-128X2-MAC-128", msg, &z16, io);
    try benchMac(aegis.Aegis128X4Mac_128, "AEGIS-128X4-MAC-128", msg, &z16, io);
    try benchMac(aegis.Aegis256Mac_128, "AEGIS-256-MAC-128", msg, &z32, io);
    try benchMac(aegis.Aegis256X2Mac_128, "AEGIS-256X2-MAC-128", msg, &z32, io);
    try benchMac(aegis.Aegis256X4Mac_128, "AEGIS-256X4-MAC-128", msg, &z32, io);
    try benchMac(aegis.Aegis128LMac, "AEGIS-128L-MAC-256", msg, &z16, io);
    try benchMac(aegis.Aegis256Mac, "AEGIS-256-MAC-256", msg, &z32, io);
    try benchMac(cmac.CmacAes128, "CMAC-AES128", msg, &z16, io);
    try benchMac(cmac.Cmac(crypto.core.aes.Aes256), "CMAC-AES256", msg, &z32, io);
    try benchMac(cbc_mac.CbcMacAes128, "CBC-MAC-AES128", msg, &z16, io);
    try benchMac(cbc_mac.CbcMac(crypto.core.aes.Aes256), "CBC-MAC-AES256", msg, &z32, io);
    try benchMac(siphash.SipHash64(2, 4), "SipHash64-2-4", msg, &z16, io);
    try benchMac(siphash.SipHash128(2, 4), "SipHash128-2-4", msg, &z16, io);
    try benchMac(siphash.SipHash64(4, 8), "SipHash64-4-8", msg, &z16, io);
    try benchMacStream(aegis.Aegis128LMac_128, "AEGIS-128L-MAC-128 stream64K", msg, &z16, 64 * 1024, io);

    const small1k = msg[0..1024];
    const small64 = msg[0..64];

    std.debug.print("\n=== HMAC, 1 KiB ===\n", .{});
    try benchHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k32", small1k, keys[0..32], io);
    try benchHmac(hmac.sha2.HmacSha512, "HMAC-SHA512 k64", small1k, keys[0..64], io);
    try benchHmac(hmac.Hmac(crypto.hash.Blake3), "HMAC-BLAKE3 k32", small1k, keys[0..32], io);
    try benchHmac(hmac.Hmac(crypto.hash.blake2.Blake2b512), "HMAC-BLAKE2b512 k64", small1k, keys[0..64], io);
    try benchHmac(hmac.sha2.HmacSha224, "HMAC-SHA224 k28", small1k, keys[0..28], io);
    try benchHmac(hmac.HmacSha1, "HMAC-SHA1 k20", small1k, keys[0..20], io);
    try benchHmac(hmac.HmacMd5, "HMAC-MD5 k16", small1k, keys[0..16], io);

    std.debug.print("\n=== HMAC, 64 B ===\n", .{});
    try benchHmac(hmac.sha2.HmacSha256, "HMAC-SHA256 k32", small64, keys[0..32], io);
    try benchHmac(hmac.sha2.HmacSha512, "HMAC-SHA512 k64", small64, keys[0..64], io);
    try benchHmac(hmac.Hmac(crypto.hash.Blake3), "HMAC-BLAKE3 k32", small64, keys[0..32], io);
    try benchHmac(hmac.Hmac(crypto.hash.blake2.Blake2b512), "HMAC-BLAKE2b512 k64", small64, keys[0..64], io);
    try benchHmac(hmac.sha2.HmacSha224, "HMAC-SHA224 k28", small64, keys[0..28], io);
    try benchHmac(hmac.HmacSha1, "HMAC-SHA1 k20", small64, keys[0..20], io);
    try benchHmac(hmac.HmacMd5, "HMAC-MD5 k16", small64, keys[0..16], io);

    std.debug.print("\n=== MAC, 1 KiB ===\n", .{});
    try benchMac(aegis.Aegis128LMac_128, "AEGIS-128L-MAC-128", small1k, &z16, io);
    try benchMac(aegis.Aegis128LMac, "AEGIS-128L-MAC-256", small1k, &z16, io);
    try benchMac(aegis.Aegis256Mac_128, "AEGIS-256-MAC-128", small1k, &z32, io);
    try benchMac(cmac.CmacAes128, "CMAC-AES128", small1k, &z16, io);
    try benchMac(cmac.Cmac(crypto.core.aes.Aes256), "CMAC-AES256", small1k, &z32, io);
    try benchMac(cbc_mac.CbcMacAes128, "CBC-MAC-AES128", small1k, &z16, io);
    try benchMac(cbc_mac.CbcMac(crypto.core.aes.Aes256), "CBC-MAC-AES256", small1k, &z32, io);
    try benchMac(siphash.SipHash64(2, 4), "SipHash64-2-4", small1k, &z16, io);
    try benchMac(siphash.SipHash128(2, 4), "SipHash128-2-4", small1k, &z16, io);

    std.debug.print("\n=== MAC, 64 B ===\n", .{});
    try benchMac(aegis.Aegis128LMac_128, "AEGIS-128L-MAC-128", small64, &z16, io);
    try benchMac(aegis.Aegis128LMac, "AEGIS-128L-MAC-256", small64, &z16, io);
    try benchMac(aegis.Aegis256Mac_128, "AEGIS-256-MAC-128", small64, &z32, io);
    try benchMac(cmac.CmacAes128, "CMAC-AES128", small64, &z16, io);
    try benchMac(cmac.Cmac(crypto.core.aes.Aes256), "CMAC-AES256", small64, &z32, io);
    try benchMac(cbc_mac.CbcMacAes128, "CBC-MAC-AES128", small64, &z16, io);
    try benchMac(cbc_mac.CbcMac(crypto.core.aes.Aes256), "CBC-MAC-AES256", small64, &z32, io);
    try benchMac(siphash.SipHash64(2, 4), "SipHash64-2-4", small64, &z16, io);
    try benchMac(siphash.SipHash128(2, 4), "SipHash128-2-4", small64, &z16, io);
}
