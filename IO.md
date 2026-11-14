# Zig 0.17 `std.Io` Reader/Writer Report

Environment inspected:
- `zig version`: `0.17.1`
- `std_dir` (from `zig env`): `/data/data/com.termux/files/usr/lib/zig/lib/std`
- Key sources: `std/Io.zig`, `std/Io/Reader.zig`, `std/Io/Writer.zig`, `std/Io/File.zig`, `std/Io/File/Reader.zig`, `std/Io/File/Writer.zig`

## 1. Big picture: `std.Io` is a capability/vtable interface

`std.Io` (`Io.zig`) is a cross-platform I/O + concurrency interface (files, dirs, net, processes, time/sleep, randomness, async/concurrency primitives, memory maps, etc.). It is implemented as:

```zig
pub const Io = @This();
userdata: ?*anyopaque,
vtable: *const VTable,
```

`Io.VTable` contains function pointers for operations (`fileReadPositional`, `fileWritePositional`, `fileWriteFileStreaming`, `dir*`, `net*`, `now`, `sleep`, async/group/futex, etc.). Callers pass an `io: Io` capability around instead of reaching for global OS calls directly. Concrete backends live under `std/Io/*` (e.g. `Threaded.zig`, `Uring.zig`, `Kqueue.zig`, `Dispatch.zig`).

`Io` also re-exports the core stream types:
- `pub const Reader = @import("Io/Reader.zig");`
- `pub const Writer = @import("Io/Writer.zig");`
- `pub const File = @import("Io/File.zig");`, `Dir`, `net`, etc.

## 2. `std.Io.Reader`: buffered, vtable-driven consumer

Defined in `Io/Reader.zig`:

```zig
vtable: *const VTable,
buffer: []u8,  // backing buffer
seek: usize,   // consumed from buffer
end: usize,    // buffered bytes in buffer[0..end]
```

- `buffered()` returns `buffer[seek..end]`; `toss(n)` advances `seek`.
- Data flow: implementation fills into `Reader.buffer` and/or streams into a `Writer` via vtable hooks.

### VTable (the extension points)
- `stream(r, w: *Writer, limit: Limit) StreamError!usize` (**required**): write from logical stream position into `w` (and/or into `r.buffer`), advance logical position by bytes returned. Not required to indicate EOF by count alone.
- `discard(r, limit) Error!usize = defaultDiscard`: skip bytes without exposing them (default: stream into a discarding writer over `r.buffer`).
- `readVec(r, data: [][]u8) Error!usize = defaultReadVec`: scatter read (may write to `data` or to `r.buffer`).
- `rebase(r, capacity) RebaseError!void = defaultRebase`: make room (default moves buffered data to front, `seek=0`).

Errors: `StreamError = ReadFailed || WriteFailed || EndOfStream` (EOF originates from Reader), `Error = ReadFailed || EndOfStream`, `StreamRemainingError = ReadFailed || WriteFailed`.

### Core consumption patterns
- **Pump to a writer:** `stream`, `streamExact`, `streamExact64`, `streamExactPreserve`, `streamRemaining` (treats `EndOfStream` as success, returns total written).
- **Skip:** `discard`, `discardShort`, `discardAll`, `discardAll64`, `discardRemaining` (returns bytes discarded).
- **Peek/take without copy:** `peek(n)`, `peekGreedy(n)`, `peekArray(n)`, `take(n)`, `takeArray(n)`, `toss(n)`, `tossBuffered()`. `peek*`/`take*` assert buffer capacity >= `n` and return `EndOfStream` if fewer bytes remain.
- **Fill/control:** `fill(n)`, `fillMore()`, `fillUnbuffered(n)`, `rebase`.
- **Read into caller buffers:** `readVec`, `readVecAll`, `readSliceShort`, `readSliceAll`, `readNoEof`.
- **Typed/parsed reads:** `takeByte`, `takeByteSigned`, `takeInt(T,endian)`, `takeVarInt`, `takeLeb128`, fixed/enum sentinels (`takeSentinel`, `takeDelimiter*`, `takeStruct`, `peekStruct`, etc.), and allocating helpers `readAlloc`, `readBoundedBytes`, `readUntilDelimiterAlloc*`.
- **Adapters/utilities:** `Reader.fixed([]const u8)` (read from memory; writes to its buffer return EOF), `Reader.limited(...)` (`Reader.Limited`), `Reader.hashed(...)`.

### Built-in special readers
- `Reader.ending` / `fixed(&.{})`: always EOF.
- `Reader.failing`: always `ReadFailed`.

## 3. `std.Io.Writer`: buffered, vtable-driven producer

Defined in `Io/Writer.zig`:

```zig
vtable: *const VTable,
buffer: []u8,  // if zero-length, writer is unbuffered
end: usize = 0 // buffered bytes in buffer[0..end]
```

- `buffered()` returns `buffer[0..end]`. Buffering avoids calling `drain` for small writes.

### VTable
- `drain(w, data: []const []const u8, splat: usize) Error!usize` (**required**): consume `buffer[0..end]` first, then `data` in order; last element of `data` is logically repeated `splat` times. May modify `end`/`buffer`. Returns bytes consumed from `data` (excludes `buffer`) and may return 0 without meaning EOF.
- `sendFile(w, file_reader: *File.Reader, limit) FileError!usize = unimplementedSendFile`: efficient file-to-sink transfer; `error.Unimplemented` tells caller to fall back to reading+writing.
- `flush(w) Error!void = defaultFlush`: drain until `end == 0`.
- `rebase(w, preserve, capacity) Error!void = defaultRebase`: ensure capacity while keeping `preserve` tail bytes buffered.

Errors: `Error = error{WriteFailed}`; file-transfer variants distinguish `ReadFailed` (from `File.Reader`), `WriteFailed`, `EndOfStream` (source), and `Unimplemented`.

### Core production patterns
- **Write:** `write(bytes)` (fast-path into buffer, else `drain` once), `writeAll`, `writeByte`, `writeByteNTimes`, `print(fmt,args)` (comptime format), `writeStruct`/`writeInt`/`writeSliceEndian`/`writeSliceSwap`, etc.
- **Vectored/splat:** `writeVec`, `writeSplat`, `writeSplatHeader*`, `writeVecAll`, `writeSplatAll`, `writeFileAll` (streams from a `File.Reader`).
- **Buffer management:** `unusedCapacitySlice/Len`, `writableSlice*`/`writableArray`, `writableSliceGreedyPreserve`, `ensureUnusedCapacity`, `advance`, `undo`, `flush`, `rebase`.
- **Adapters:** `Writer.fixed(buffer)` (fills buffer, `WriteFailed` when full, no-op flush), `Writer.failing`, `Writer.hashed(w, hasher, buffer)` / `Hashing` helper, `Writer.Allocating`/`Allocating.init*` (growable sink), `Writer.Discarding`.

### Sentinel/limit errors in this design
`WriteFailed` is generic; concrete implementations stash details on themselves (e.g. `File.Writer.err`, `File.Writer.write_file_err`) to be read after a failed write/flush/end.

## 4. File adapters: `File.Reader` and `File.Writer`

These adapt an `Io.File` handle into the generic `Reader`/`Writer` interfaces and memoize state.

### `Io.File.Reader` (`Io/File/Reader.zig`)
- Embeds `interface: Io.Reader` plus `io`, `file`, `pos` (true seek), `size/size_err`, `seek_err`, `err`, `mode`.
- Constructors: `init(file, io, buffer)`, `initSize(...)`, `initStreaming(...)`; `initInterface(buffer)` wires `.stream/.discard/.readVec`.
- **Modes:** `positional`/`positional_simple` (pread/preadv, thread-friendlier, logical seek adjusts `pos`) vs `streaming`/`streaming_simple` (read/readv, maintains global seek; falls back from positional on `Unseekable`). `*_simple` avoids fd-to-fd/sendfile-style paths. On certain failures mode becomes `.failure`.
- `getSize()` lazily stats (caches `Streaming` for non-regular files). `logicalPos()` = `pos - bufferedLen()`. `seekTo/seekBy` adjust logical position (positional) or issue seeks/fallback reads (streaming).
- `streamMode` tries `w.sendFile(r, limit)` when non-simple (fast fd-to-fd), downgrades to simple on `Unimplemented`, else does vectored positional/streaming reads into writer capacity. This is how `Reader.streamRemaining` / `Writer.sendFile` paths enable efficient copies.

### `Io.File.Writer` (`Io/File/Writer.zig`)
- Embeds `interface: Io.Writer`, `io`, `file`, `pos`, `err`, `write_file_err`, `seek_err`, `mode`.
- Constructors: `init`, `initStreaming`, `initDetect` (TTY-aware), `initInterface`; `moveToReader()` converts while reusing buffer.
- `drain` routes to positional (`fileWritePositional` with `header + data + splat` at `w.pos`) or streaming writes; handles fallback on `Unseekable`. `sendFile` routes to positional/streaming file-to-file ops, mapping errors (`Unimplemented` => caller fallback) and recording underlying failures.
- `seekTo` flushes buffered data then repositions; `logicalPos()` = `pos + interface.end`; `end()` flushes and `setLength` to truncate/extend (no-op on `NonResizable`).

## 5. Patterns visible in this workspace (0.17 style)

`hash_file.zig` — **streaming hash via `Writer.Hashing` adapter**:
```zig
var file = try std.Io.Dir.cwd().openFile(io, path, .{});
defer file.close(io);
var file_reader = file.reader(io, &.{});          // File.Reader, no extra read buffer
var hash_buffer: [64 * 1024]u8 = undefined;
var hashing: std.Io.Writer.Hashing(Sha256) = .init(&hash_buffer);
_ = try file_reader.interface.streamRemaining(&hashing.writer); // pump until EOF
try hashing.writer.flush();                                      // flush tail into hasher
hashing.hasher.final(&digest);
```
- `file.reader(io, &.{})` yields a `File.Reader` whose `interface` (`Io.Reader`) is pumped into any `Io.Writer` sink.
- The hashing writer buffers chunks and feeds the hasher; explicit `flush()` finalizes the tail.

`hash_file_mmap.zig` — **memory-mapped I/O via `Io.File`**:
```zig
const st = try file.stat(io);
var mm = try file.createMemoryMap(io, .{ .len = @intCast(st.size), .protection = .{ .read = true }, .populate = true });
defer mm.destroy(io);
Sha256.hash(mm.memory, &digest, .{});
```
- Uses `io` capability for stat/mmap lifecycle; hashes the mapped slice directly (avoids read-copy path).

Common entry pattern here: `pub fn main(init: std.process.Init) !void { ... init.io ... }` — the runtime supplies the `Io` capability.

## 6. Things you can do with this I/O model

- **Read files efficiently:** `Dir.cwd().openFile(io, path, .{})` + `file.reader(io, buf)` for buffered/positional reads; use `streamRemaining` to pump to any sink, or `readAll/peek/take*` for parsed/structured input. Empty read buffer (`&.{}`) lets data flow straight into the destination writer buffer when streaming.
- **Write files:** `dir.createFile`/`openFile` + `file.writer(io, buf)`; buffer output, `print`/`writeAll`/`writeStruct`, then `flush` or `end()` to set length. `moveToReader` reuses buffers when switching direction.
- **Copy/tee data:** `Reader.streamRemaining(&writer)` or `streamExact*`; `Writer.sendFile`/`File.Reader` fast paths leverage `sendfile`/copy_file_range-like vtable ops when available, with automatic fallback.
- **Hash/transform while streaming:** wrap a sink with `Writer.hashed(...)` / `Writer.Hashing(T)` (or reader-side hashing) to compute digests without extra passes or allocations.
- **In-memory streams:** `Reader.fixed(slice)` to parse from bytes; `Writer.fixed(buffer)` for bounded formatting (fails with `WriteFailed` on overflow); `Writer.Allocating` for growable output.
- **Positional & concurrent reads:** `File.Reader` positional mode uses offset-based reads (no shared cursor), suitable when combined with threads/async; streaming mode tracks file cursor. Seek via `seekTo/seekBy`/`logicalPos`.
- **Memory-mapped files:** `file.createMemoryMap(io, ...)` / `File.MemoryMap` for zero-copy access patterns (as in `hash_file_mmap.zig`).
- **Scatter/gather & vectored I/O:** `Reader.readVec`/`Writer.writeVec`/splat APIs to minimize copies/syscalls.
- **Bounded/limited input:** `Reader.limited`/`Limited` and `Limit` to cap reads (defensive parsing).
- **Parse binary/text:** integer/varint/LEB128/sentinel/line helpers on `Reader`; formatted output via `Writer.print`.
- **Swap backends via `Io`:** because operations go through `io.vtable` and stream vtables, the same code can target different executors/backends (`Threaded`, io_uring, kqueue, etc., per platform/support) and participates in `Io`’s async/cancel model.

## 7. Notable 0.17 characteristics (from these sources)

- Explicit `io: Io` capability parameter is pervasive (files, dirs, stat, mmap, sleep/time/random/concurrency).
- Generic, composable `Reader`/`Writer` interfaces with small vtables and caller-provided buffers (no hidden allocation in core streaming).
- `sendFile` is a first-class fast path but optional (`Unimplemented` fallback).
- Concrete adapters (`File.Reader/Writer`, `fixed`, `Allocating`, `Hashing`, `Limited`, etc.) snap together—e.g. hashing a file is “reader → hashing writer”.
- `WriteFailed`/`ReadFailed` are opaque at the interface; implementations expose detailed error fields.

Sources consulted: `/data/data/com.termux/files/usr/lib/zig/lib/std/Io.zig`, `Io/Reader.zig`, `Io/Writer.zig`, `Io/File/Reader.zig`, `Io/File/Writer.zig`, and local examples `hash_file.zig`, `hash_file_mmap.zig`.

## 8. Detailed concrete use cases

The scenarios below are concrete, end-to-end uses of Zig 0.17 `std.Io` Reader/Writer APIs. Runnable versions of most snippets live in `IO.zig` in this directory (`zig run IO.zig`).

### 8.1 Stream a large file to compute SHA-256 (no full-file allocation)

**Goal:** hash an arbitrarily large file for integrity checking while keeping memory bounded.

**APIs:** `Io.Dir.cwd().openFile`, `Io.File.reader`, `Io.Writer.Hashing(T)`, `Reader.streamRemaining`, `Writer.flush`, `Sha256.final`, `defer file.close`.

```zig
const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn sha256File(io: Io, path: []const u8) ![Sha256.digest_length]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // Empty read buffer: data can flow directly into the destination writer buffer.
    var file_reader = file.reader(io, &.{});

    // Hashing writer buffers incoming bytes and feeds the hasher on drain/flush.
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashing: Io.Writer.Hashing(Sha256) = .init(&hash_buf);

    _ = try file_reader.interface.streamRemaining(&hashing.writer); // pump until EOF
    try hashing.writer.flush(); // IMPORTANT: push the final buffered tail into the hasher

    var digest: [Sha256.digest_length]u8 = undefined;
    hashing.hasher.final(&digest);
    return digest;
}
```

**Data flow:** file bytes → `File.Reader` logical stream → `streamRemaining` loop → `Hashing` writer buffer → `hasher.update` on drain → tail flushed → final digest.

**Why this pattern:**
- Bounded memory: only `hash_buf` (+ adapter state), regardless of file size.
- Composable: the reader does not know the sink is a hasher; any `Io.Writer` works.
- Fast path friendly: `File.Reader.streamMode` may attempt `sendFile` when appropriate, but hashing still works because data is driven through the writer interface.

**Pitfalls/notes:**
- Always `flush()` the hashing writer before `final()`, or the last partial buffer is omitted and the digest is wrong.
- `file.reader(io, &.{})` is fine here because the hashing writer provides the working buffer; if you need `peek/take` parsing on the reader side, give the reader its own buffer.
- Handle errors from `openFile`/`streamRemaining` (e.g. `ReadFailed`, `EndOfStream` treated as success by `streamRemaining`).
- `defer file.close(io)` ensures the handle is released on all paths. (`IO.zig: exampleHashFile`)

**Alternative:** for regular files where zero-copy mapping is preferable, use `file.stat` + `file.createMemoryMap` and hash `mm.memory` in one shot (see `hash_file_mmap.zig` in this workspace). Mmapping avoids read copies but requires the file to be mappable and sized; streaming is the general-purpose choice.

### 8.2 Buffered file copy / backup with byte count

**Goal:** copy `src` to `dst` efficiently, report bytes transferred, and ensure data reaches the destination writer before close.

**APIs:** `openFile`, `createFile(.{ .truncate = true })`, `file.reader`/`file.writer`, `streamRemaining`, `Writer.flush`.

```zig
pub fn copyFile(io: Io, src_path: []const u8, dst_path: []const u8) !u64 {
    var src = try Io.Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);

    var dst = try Io.Dir.cwd().createFile(io, dst_path, .{ .truncate = true });
    defer dst.close(io);

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = src.reader(io, &rbuf);
    var writer = dst.writer(io, &wbuf);

    const n = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush(); // drain buffered tail to the file
    return n;
}
```

**Data flow:** source file → `File.Reader` buffer/interface → `streamRemaining` → `File.Writer` buffer → `drain`/`sendFile` vtable ops → destination file.

**Why this pattern:**
- `streamRemaining` pumps until `EndOfStream`, returning total bytes written to the writer interface.
- `File.Writer`/`File.Reader` may use positional I/O and can participate in `sendFile` fast paths (fd-to-fd) when the backend supports them; on `Unimplemented` it falls back transparently to read+write.
- Explicit buffers (`rbuf`/`wbuf`) amortize syscall overhead; tune sizes (e.g. 16–64 KiB) to workload.

**Pitfalls/notes:**
- `flush()` before `close()`/return is required; buffered writers do not guarantee the tail is persisted without it. For durability guarantees also consider `file.sync(io)` or `File.Writer.end()`.
- `createFile` with `.truncate = true` replaces existing contents (default in `CreateFileOptions` as inspected); choose flags deliberately for backups/overwrites.
- For a pure byte count without a destination file, pump into `Io.Writer.Discarding` and read `fullCount()` (`IO.zig: exampleCountFile`).
- To compute a digest and copy in one pass, fan out each chunk to the destination writer and to a hasher (`IO.zig: exampleHashWhileCopy`) or compose adapters as needed.

### 8.3 Parse a binary record from memory with peek/take (zero-copy reads)

**Goal:** decode a fixed-format packet `[u8 tag][u8 flags][u32 be length][payload bytes]` safely from an in-memory buffer without allocating or copying fields unnecessarily.

**APIs:** `Io.Reader.fixed`, `peekArray`, `takeByte`, `takeInt`, `take`, `toss`, `EndOfStream`.

```zig
const std = @import("std");
const Io = std.Io;

const Header = struct { tag: u8, flags: u8, len: u32 };

pub fn parsePacket(buf: []const u8) !struct { header: Header, payload: []u8 } {
    var r: Io.Reader = .fixed(buf);

    // Peek when you may need to branch before consuming.
    const magic = try r.peekArray(2);
    if (magic[0] != 0x01) return error.BadTag;

    const tag = try r.takeByte();
    const flags = try r.takeByte();
    const len = try r.takeInt(u32, .big);

    // take(n) returns a slice into the reader buffer for n bytes (no copy).
    const payload = try r.take(len);
    return .{ .header = .{ .tag = tag, .flags = flags, .len = len }, .payload = payload };
}
```

**Data flow:** `Reader.fixed(buf)` sets `buffer/end` over the input bytes → `peek*` reads without advancing `seek` → `take*` returns slices/values and advances `seek` (`toss`).

**Why this pattern:**
- Zero-copy: slices returned by `peek`/`take` alias the original buffer; ideal for parsing.
- Explicit cursor: `toss(n)`, `tossBuffered()`, and `bufferedLen()` make consumption obvious.
- Rich primitives: `takeInt(T,endian)`, varints/LEB128, delimiter/sentinel helpers, `takeStruct`/`peekStruct`, etc., for protocol parsing.

**Pitfalls/notes:**
- `peek(n)`/`take(n)` assert the reader’s buffer capacity is >= `n` and return `error.EndOfStream` if not enough data remains; for `Reader.fixed` the “capacity” is the provided slice.
- Slices from `peek/take` are invalidated by operations that refill/rebase/advance the buffer (relevant for non-fixed readers); copy out if you must retain data.
- For untrusted/large inputs, prefer bounded reads (e.g. `Reader.limited`/`Limit` or `readBoundedBytes`) to cap memory/CPU exposure.
- Same API works over files: use `file.reader(io, buf)` and ensure the buffer is large enough for your maximum `peek/take` window, or `fill(n)` as needed. (`IO.zig: examplePeekTakeParse`, `exampleFixedReader`)

### 8.4 Build a dynamic response/report in memory, then emit once

**Goal:** construct variable-sized text/binary output (formatting, concatenation) without precomputing size, then hand it off as a single owned slice.

**APIs:** `Io.Writer.Allocating.init`, `writer.print`/`writeAll`/`writeSplat`, `toOwnedSlice`, `defer aw.deinit`.

```zig
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn buildReport(allocator: Allocator, items: []const []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    try aw.writer.print("items: {d}\n", .{items.len});
    for (items, 0..) |it, i| {
        try aw.writer.print("  {d}. {s}\n", .{ i, it });
    }

    // Allocating flush is a no-op; take ownership of the grown buffer.
    return aw.toOwnedSlice();
}
```

**Why this pattern:**
- Amortized growth: `Allocating` backs the `Writer` buffer with allocator-managed storage and resizes on demand, so hot-path formatted writes use the normal buffered `Writer` fast paths.
- Single allocation/result: `toOwnedSlice()` transfers ownership to the caller (caller frees with the same allocator strategy as returned memory requires).
- Useful for HTTP bodies, generated configs, or assembling data to write to a file/socket in one `writeAll`.

**Pitfalls/notes:**
- Use `errdefer aw.deinit()` if you might error before transferring ownership; after `toOwnedSlice()` ownership moves out.
- For bounded output, `Io.Writer.fixed(buf)` avoids allocation but returns `error.WriteFailed` on overflow—choose based on whether size is known/capped.
- `flush()` is not needed to materialize bytes in `Allocating` (its flush is a no-op); it matters for sink-backed writers like `File.Writer`. (`IO.zig: exampleAllocatingWriter`)

### 8.5 In-place/random-access updates with positional file I/O

**Goal:** patch a fixed-size record inside a larger file without rewriting the whole file or disturbing other readers that rely on independent offsets.

**APIs:** `createFile`/`openFile` with `.read = true`/appropriate mode, `writePositionalAll`, `readPositionalAll`, `sync`, `setLength`/`end` via writer if needed.

```zig
pub fn patchRecord(io: Io, path: []const u8, record_off: u64) ![3]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    // Write exactly at an offset (does not depend on a shared streaming cursor).
    try file.writePositionalAll(io, "XYZ", record_off);
    try file.sync(io); // push content/metadata as required by durability needs

    var out: [3]u8 = undefined;
    _ = try file.readPositionalAll(io, &out, record_off);
    return out;
}
```

**Why this pattern:**
- Positional operations take an explicit offset, which is naturally safer under concurrency than a mutable global file cursor.
- `File.Reader`/`File.Writer` default to positional mode and fall back to streaming when `Unseekable` (e.g. pipes/sockets); for true random access, operate on regular seekable files.

**Pitfalls/notes:**
- `readPositionalAll`/`writePositionalAll` loop until the buffer/bytes are completed or EOF/error; check returned counts/EOF semantics for partial reads at end of file.
- `sync` persists pending data/metadata for the file (not directory metadata). Truncation/extension is separate (`setLength`, or `File.Writer.end()` after flushing buffered writes).
- `createFile`’s `.truncate`/`.read` flags control initial state; open with the minimal capabilities you need. (`IO.zig: examplePositionalAll`)

### 8.6 Composing adapters: vectored output and scatter reads

**Goal:** minimize copies/syscalls by writing multiple buffers in one logical operation or reading into multiple buffers.

**APIs:** `writeVec`/`writeVecAll`/`writeSplat`, `readVec`/`readVecAll`.

```zig
var out: [32]u8 = undefined;
var w: Io.Writer = .fixed(&out);
var parts = [_][]const u8{ "HTTP/1.1 ", "200 OK", "\r\n" };
try w.writeVecAll(&parts); // gather

var a: [8]u8 = undefined;
var b: [8]u8 = undefined;
var dsts = [_][]u8{ &a, &b };
try r.readVecAll(&dsts); // scatter into caller buffers
```

**Notes:** vectored APIs let implementations batch I/O (`readv`/`writev`/vector drains) when possible; `writeSplat` efficiently repeats a pattern (e.g. padding, separators) without materializing it repeatedly. These same methods work on file-backed readers/writers. (`IO.zig: exampleVectoredWrite`, `exampleScatterGather`)
