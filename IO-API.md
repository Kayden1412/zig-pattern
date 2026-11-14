# Zig 0.17 `std.Io` — Detailed API Explanations

Environment: Zig `0.17.1`, stdlib at `/data/data/com.termux/files/usr/lib/zig/lib/std` (`Io.zig`, `Io/Reader.zig`, `Io/Writer.zig`, `Io/File.zig`, `Io/File/Reader.zig`, `Io/File/Writer.zig`, `Io/Dir.zig`).

This document explains **every public declaration** (`pub fn`, `pub const`, `pub var`) in those core I/O modules: what each API does, how it behaves, important parameters/errors, and how it relates to others. It is intentionally explanatory (not a signature-only dump). Signatures are summarized in prose; consult the stdlib source for exact types.

---

## 1. `std.Io` (`std/Io.zig`)

`Io` is a cross-platform I/O-and-concurrency *capability object*: `pub const Io = @This();` with fields `userdata: ?*anyopaque` and `vtable: *const VTable`. Code performs operations by calling methods that dispatch through `vtable` function pointers (or by passing `io` into `File`/`Dir`/net/etc. APIs). This lets the same code run on different backends (threaded, io_uring, kqueue, dispatch, etc.) and participate in the runtime’s async/cancel model.

### 1.1 Backend and submodule re-exports
- **`Threaded`** (`const`): Imports `Io/Threaded.zig`, a thread-pool/blocking-style `Io` implementation.
- **`fiber`** (`const`): Imports `Io/fiber.zig` (fiber/context-switch primitives support used by evented backends).
- **`Evented`** (`const`): Selects an evented backend when fibers are supported (`Uring` on Linux, `Kqueue` on BSDs, `Dispatch` on Apple platforms), else `void`. Represents the platform’s async/event-loop backend when available.
- **`Dispatch`** (`const`): Imports `Io/Dispatch.zig` (Apple Grand Central Dispatch-backed implementation).
- **`Kqueue`** (`const`): Imports `Io/Kqueue.zig` (kqueue-backed implementation).
- **`Uring`** (`const`): Imports `Io/Uring.zig` (Linux io_uring-backed implementation).
- **`Reader`** (`const`): Re-export of `Io/Reader.zig`, the generic buffered byte reader interface.
- **`Writer`** (`const`): Re-export of `Io/Writer.zig`, the generic buffered byte writer interface.
- **`net`** (`const`): Re-export of `Io/net.zig` (networking types/ops).
- **`Dir`** (`const`): Re-export of `Io/Dir.zig` (directory handle and path operations).
- **`File`** (`const`): Re-export of `Io/File.zig` (file handle and file operations).
- **`Terminal`** (`const`): Re-export of `Io/Terminal.zig` (terminal/TTY helpers).
- **`RwLock`** (`const`): Re-export of `Io/RwLock.zig` (reader-writer lock).
- **`Semaphore`** (`const`): Re-export of `Io/Semaphore.zig`.

### 1.2 Core vtable and operations
- **`VTable`** (`const struct`): The operation table an `Io` implementation must provide. It contains function pointers (each taking `userdata` first) for: crash handling; async/concurrent task lifecycle (`async`, `concurrent`, `await`, `cancel`); group task lifecycle (`groupAsync`, `groupConcurrent`, `groupAwait`, `groupCancel`); cancel control (`recancel`, `swapCancelProtection`, `checkCancel`); futex (`futexWait`, `futexWaitUncancelable`, `futexWake`); generic/batched operations (`operate`, `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel`); all directory ops (`dirCreateDir*`, `dirOpenDir`, `dirStat*`, `dirAccess`, `dirCreateFile*`, `dirOpenFile`, `dirClose`, `dirRead`, `dirRealPath*`, `dirDelete*`, `dirRename*`, `dirSymLink`, `dirReadLink`, `dirSet*`, `dirHardLink`); all file ops (`fileStat`, `fileLength`, `fileClose`, `fileWritePositional`, `fileWriteFileStreaming`, `fileWriteFilePositional`, `fileReadPositional`, `fileSeekBy/To`, `fileSync`, TTY/ANSI queries, `fileSet*`, locking, `fileRealPath`, `fileHardLink`); memory-map ops; process/stdio/cwd/replace/spawn/child ops; progress/handle inheritance; time (`now`, `clockResolution`, `sleep`); randomness (`random`, `randomSecure`); networking (listen/bind/connect/accept/unix/pairs/send/close/shutdown/interface/lookup). Each method’s contract (thread-safety, when called, error meaning) is defined by its signature and source docs.
- **`Operation`** (`const union(enum)`): Tagged union describing a generic I/O operation submitted via `operate`/batches. Tags include file streaming read/write, device I/O control, and network receive/send/read/write (with per-tag payload structs). Used to express operations uniformly to the backend.
- **`operate(io, operation)`** (`fn`): Submits a single `Operation` to the backend (`vtable.operate`) and returns `Cancelable!Operation.Result`. It is the low-level way to perform operations represented by `Operation` (e.g. `file_read_streaming`, `file_write_streaming`, net I/O). May be canceled depending on cancel state.
- **`OperateTimeoutError`** (`const error set`): Errors for timed operate: `Cancelable || Timeout.Error || ConcurrentError`.
- **`operateTimeout(io, operation, timeout)`** (`fn`): Like `operate` but bounded by a `Timeout`; returns the operation result or timeout/cancel/concurrency errors. Lets callers cap how long an operation may wait.
- **`Batch`** (`const struct`): A collection of operations to submit/await/cancel together via `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel`. Provides efficient multi-operation submission; includes `AwaitConcurrentError` for concurrent await variants. Used when amortizing overhead across many ops matters.

### 1.3 Limits, errors, and cancelation
- **`Limit`** (`const enum(usize)`): Represents an I/O length limit: `.unlimited`, `.nothing`, or `.limited(n)` (with helpers like `limited64`, `slice`, `toInt`, `nonzero`, `min`, `subtract`, `countVec`). Passed through Reader/Writer/File APIs to cap how many bytes may be transferred/read/written in one operation.
- **`Cancelable`** (`const error`): `error{Canceled}` — the standard cancelation error returned by cancelable operations.
- **`UnexpectedError`** (`const error`): `error{Unexpected}` — represents an unexpected system/implementation failure mapped to a generic error.
- **`InheritParentHandleError`** (`const error`): Errors possible when inheriting a file/directory handle from a parent process/environment (used by vtable handle-inheritance hooks).
- **`recancel(io)`** (`fn`): Requests/propagates cancelation again via `vtable.recancel` (reasserts cancel state so subsequent cancelable points observe it). Useful when handling cancelation but needing to keep the task canceled.
- **`CancelProtection`** (`const enum(u1)`): States for temporarily masking/unmasking cancelation (e.g. `.blocked`/`.unblocked` semantics as defined) so critical sections can complete.
- **`swapCancelProtection(io, new)`** (`fn`): Atomically sets cancel-protection state via vtable and returns the previous state. Lets code defer cancelation during sensitive regions then restore it.
- **`checkCancel(io)`** (`fn`): Cancelation checkpoint; returns `Cancelable!void` (errors with `Canceled` if cancel is pending and not protected). Call in long loops/computation to remain responsive to cancelation.

### 1.4 Time
- **`Clock`** (`const enum`): Identifies a clock source (e.g. realtime/monotonic/boottime/process/thread as provided). Used with `now`, `sleep`, `clockResolution`, and time conversions.
- **`Timestamp`** (`const struct`): A point in time for a given clock (with conversions/comparison helpers such as from/to nanoseconds and arithmetic/duration-until as defined). Produced by `Io.now` and used in timeouts/stats.
- **`Duration`** (`const struct`): A time span (nanosecond-based representation with constructors/conversions/arithmetic/saturation helpers). Passed to `sleep` and timeout APIs.
- **`Timeout`** (`const union(enum)`): A deadline/timeout specification: `.none`, `.duration(...)`, or `.deadline(...)` (absolute timestamp) with helpers to evaluate remaining time. Accepted by timed waits/operations.
- **`now(io, clock)`** (via vtable, surfaced conceptually): `VTable.now` returns the current `Timestamp` for `Clock`; exposed through backend time APIs.
- **`clockResolution(io, clock)`** (vtable): Returns clock resolution as a `Duration` or resolution error.
- **`sleep(io, duration, clock)`** (`fn`): Suspends the current task for at least `duration` on `clock` (cancelable). Implemented via `vtable.sleep` with a timeout; yields to the runtime instead of blocking a thread when possible.

### 1.5 Async, futures, groups, and concurrency
- **`AnyFuture`** (`const opaque`): Type-erased handle to an asynchronously running computation returned by `vtable.async`/`concurrent` when not completed eagerly.
- **`Future(Result)`** (`fn type`): Typed future wrapper over `AnyFuture` for a specific `Result`. Provides `await`/`cancel` semantics by calling the corresponding vtable functions to retrieve or cancel the result.
- **`Group`** (`const struct`): A scoped set of spawned tasks (async/concurrent) that can be awaited or canceled together. Tracks membership/token so `groupAwait`/`groupCancel` synchronize completion and propagate results/errors per the group protocol.
- **`async(io, function, args)`** (`fn`): Schedules `function` with `args` to run asynchronously (may complete eagerly). Returns a `Future` of the function’s result type; if the backend runs it inline/eagerly it can avoid allocation/handle overhead, otherwise it yields a handle awaited later.
- **`ConcurrentError`** (`const error`): `error{ConcurrencyUnavailable}` (and related) indicating the backend cannot spawn true concurrency right now; callers can fall back to `async`/serial execution.
- **`concurrent(io, function, args)`** (`fn`): Requests parallel/concurrent execution of `function(args)` (separate execution context when supported). Returns `ConcurrentError!Future` or equivalent; stronger than `async` in that it asks for parallel progress, but may fail with `ConcurrencyUnavailable`.

### 1.6 Synchronization primitives
- **`Mutex`** (`const extern struct`): Mutual-exclusion lock integrated with the `Io` runtime. Provides lock/tryLock/unlock (and cancel-aware waiting as applicable) so tasks block/yield efficiently rather than spinning.
- **`Condition`** (`const struct`): Condition variable associated with a `Mutex` for waiting/signaling state changes (wait, timed wait, signal, broadcast) under the `Io` cancel/wakeup model.
- **`Event`** (`const enum(u32)`/struct form): A one-shot or resettable notification primitive (`wait`, `set`, `reset/isSet` semantics) for signaling completion across tasks.
- **`futexWait(io, T, ptr, expected)`** (`fn`): Blocks the caller (cancelable) until the 32-bit word at `ptr` differs from `expected` or a wake occurs. Low-level primitive backing higher-level locks; type-generic over a `u32`-aligned value.
- **`futexWaitTimeout(io, T, ptr, expected, timeout)`** (`fn`): Like `futexWait` but with a `Timeout`.
- **`futexWaitUncancelable(io, T, ptr, expected)`** (`fn`): Futex wait that cannot be canceled (used in critical teardown paths).
- **`futexWake(io, T, ptr, max_waiters)`** (`fn`): Wakes up to `max_waiters` tasks waiting on the futex word at `ptr`.

### 1.7 Queues and selection
- **`QueueClosedError`** (`const error`): `error{Closed}` produced when operating on a closed queue.
- **`TypeErasedQueue`** (`const struct`): Runtime/type-erased queue implementation underpinning typed queues (manages buffers, waiters, close state).
- **`Queue(Elem)`** (`fn type`): Typed concurrent queue of `Elem`. Supports push/pop (blocking/cancelable or try variants as defined), close, and integration with async waiting so producers/consumers coordinate safely.
- **`Select(U)`** (`fn type`): Helper for waiting on one of multiple async events/sources (select/race over futures/queues/etc.), returning which case completed along with its result.

### 1.8 Standard streams, randomness, and utilities
- **`LockedStderr`** (`const struct`): Represents stderr locked for exclusive, serialized writes (optionally with terminal mode info). Holds a writer/buffer context so formatted diagnostic output is not interleaved across threads/tasks; released via `unlockStderr`.
- **`lockStderr(io, buffer, terminal_mode)`** (`fn`): Locks stderr and returns a `LockedStderr` (cancelable). Ensures atomic/ordered stderr output; `buffer` backs the writer.
- **`tryLockStderr(io, buffer, terminal_mode)`** (`fn`): Non-blocking attempt to lock stderr; returns `null` if unavailable.
- **`unlockStderr(io)`** (`fn`): Releases the stderr lock acquired by `lockStderr`.
- **`random(io, buffer)`** (`fn`): Fills `buffer` with random bytes using the platform’s fast/random source via vtable (not necessarily cryptographically secure unless specified by backend).
- **`RandomSecureError`** (`const error`): `error{EntropyUnavailable} || Cancelable` for secure-random failures.
- **`randomSecure(io, buffer)`** (`fn`): Fills `buffer` with cryptographically secure random bytes or errors if entropy is unavailable/canceled.

### 1.9 The `failing` Io and vtable stub helpers
`std.Io` provides a ready-made inert/failing implementation useful for tests or contexts where I/O must not occur.

- **`failing`** (`const Io`): An `Io` instance wired to stub vtable functions that deterministically fail or no-op: operations report `Unexpected`/`ConcurrencyUnavailable`/`Unseekable`/etc. as appropriate, waits do not block, and unsupported actions are rejected. Useful as a sentinel “no I/O” capability.
- **`noCrashHandler`** (`fn`): Crash-handler stub that does nothing.
- **`noAsync`** (`fn`): `async` stub that runs the start function eagerly and reports completion (returns no future handle), so no background scheduling occurs.
- **`failingConcurrent`** (`fn`): `concurrent` stub that returns `error.ConcurrencyUnavailable`.
- **`unreachableAwait`** (`fn`): Marks `await` as unreachable (used when no future can exist).
- **`unreachableCancel`** (`fn`): Marks `cancel` as unreachable.
- **`noGroupAsync`** (`fn`): Runs group tasks eagerly/inline without spawning.
- **`failingGroupConcurrent`** (`fn`): Returns concurrency-unavailable for group concurrent spawn.
- **`unreachableGroupAwait`** (`fn`): Unreachable group await stub.
- **`unreachableGroupCancel`** (`fn`): Unreachable group cancel stub.
- **`unreachableRecancel`** (`fn`): Unreachable recancel stub.
- **`unreachableSwapCancelProtection`** (`fn`): Unreachable cancel-protection swap stub.
- **`unreachableCheckCancel`** (`fn`): Unreachable cancel-check stub (never canceled).
- **`noFutexWait`** (`fn`): Futex wait that returns immediately/canceled per stub contract (no blocking).
- **`noFutexWaitUncancelable`** (`fn`): No-op uncancelable futex wait.
- **`noFutexWake`** (`fn`): No-op futex wake.
- **`failingOperate`** (`fn`): Generic `operate` stub that fails with an appropriate error for the operation.
- **`unreachableBatchAwaitAsync` / `unreachableBatchAwaitConcurrent` / `unreachableBatchCancel`** (`fn`): Unreachable batch lifecycle stubs.

*Directory vtable stubs (`std.Io`):* each takes `(userdata, ...)` matching `VTable` and provides a deterministic failure/no-op so `Io.failing` can satisfy the interface:
- **`failingDirCreateDir`**: fails to create a directory.
- **`failingDirCreateDirPath`**: fails to create a directory path/status.
- **`failingDirCreateDirPathOpen`**: fails to create-and-open a directory path.
- **`failingDirOpenDir`**: fails to open a directory.
- **`failingDirStat`**: fails to stat a directory handle.
- **`failingDirStatFile`**: fails to stat a file by path relative to a dir.
- **`failingDirAccess`**: fails/reports no access for a path.
- **`failingDirCreateFile`**: fails to create/open a file for writing/creation.
- **`failingDirCreateFileAtomic`**: fails atomic file creation.
- **`failingDirOpenFile`**: fails to open a file.
- **`unreachableDirClose`**: marks closing dir handles as unreachable (no valid handles in failing io).
- **`noDirRead`**: directory iteration returns end/no entries.
- **`failingDirRealPath`**: fails to resolve dir real path.
- **`failingDirRealPathFile`**: fails to resolve a file’s real path relative to dir.
- **`failingDirDeleteFile`**: fails to delete a file.
- **`failingDirDeleteDir`**: fails to delete a directory.
- **`failingDirRename`**: fails to rename.
- **`failingDirRenamePreserve`**: fails to rename with preserve semantics.
- **`failingDirSymLink`**: fails to create symlink.
- **`failingDirReadLink`**: fails to read symlink target.
- **`failingDirSetOwner`**: fails to set directory owner.
- **`failingDirSetFileOwner`**: fails to set file owner by path.
- **`failingDirSetPermissions`**: fails to set directory permissions.
- **`failingDirSetFilePermissions`**: fails to set file permissions by path.
- **`noDirSetTimestamps`**: no-op/fails timestamp set on path as stubbed.
- **`failingDirHardLink`**: fails to create hard link.

*File vtable stubs:*
- **`failingFileStat`**: fails to stat a file.
- **`failingFileLength`**: fails to get file length.
- **`unreachableFileClose`**: unreachable file-close stub.
- **`failingFileWritePositional`**: fails positional write.
- **`noFileWriteFileStreaming`**: reports streaming file-to-file write unsupported/no-op failure.
- **`noFileWriteFilePositional`**: reports positional file-to-file write unsupported.
- **`failingFileReadPositional`**: fails positional read.
- **`failingFileSeekBy`**: fails relative seek.
- **`failingFileSeekTo`**: fails absolute seek.
- **`failingFileSync`**: fails sync.
- **`unreachableFileIsTty`**: unreachable TTY check.
- **`unreachableFileEnableAnsiEscapeCodes`**: unreachable ANSI enable.
- **`unreachableFileSupportsAnsiEscapeCodes`**: unreachable ANSI support check.
- **`failingFileSetLength`**: fails truncation/extension.
- **`failingFileSetOwner`**: fails chown.
- **`failingFileSetPermissions`**: fails chmod.
- **`noFileSetTimestamps`**: stub for setting file timestamps.

*(The `std.Io` vtable in source continues with additional stubs for file locking/realpath/hardlink/mmap, process, time, net, etc., all following the same pattern: provide a complete but inert/failing backend so the interface is implementable and `Io.failing` is safe to pass where operations must not succeed.)*

*File vtable stubs (continued):*
- **`failingFileLock`**: Fails to acquire an advisory lock on a file. Used by `Io.failing` to reject locking.
- **`failingFileTryLock`**: Fails/returns inability to try-lock a file.
- **`noFileUnlock`**: No-op unlock stub (no lock held in the failing backend).
- **`failingFileDowngradeLock`**: Fails to downgrade an exclusive lock to shared.
- **`failingFileRealPath`**: Fails to resolve a file handle’s canonical filesystem path.
- **`failingFileHardLink`**: Fails to create a hard link to an open file in a directory.
- **`failingFileMemoryMapCreate`**: Fails to create a memory mapping for a file (`File.MemoryMap`).
- **`unreachableFileMemoryMapDestroy`**: Unreachable destroy stub (no mapping can exist).
- **`failingFileMemoryMapSetLength`**: Fails to resize a memory mapping.
- **`noFileMemoryMapRead`**: Stub for reading/populating mapping pages (no-op/failing as wired).
- **`failingFileMemoryMapWrite`**: Fails to flush/write mapping changes back.

*Process, stdio, environment, and handle-inheritance stubs:*
- **`failingProcessExecutableOpen`**: Fails to open the current process executable as a file.
- **`failingProcessExecutablePath`**: Fails to retrieve the executable path into a buffer.
- **`failingLockStderr`**: Fails to lock stderr for exclusive access.
- **`noTryLockStderr`**: Reports stderr try-lock as unavailable (`null`/failure path per stub).
- **`noUnlockStderr`**: No-op stderr unlock.
- **`failingProcessCurrentPath`**: Fails to get current working directory path.
- **`failingProcessSetCurrentDir`**: Fails to set cwd from a `Dir` handle.
- **`failingProcessSetCurrentPath`**: Fails to set cwd from a path string.
- **`failingProcessReplace`**: Fails to exec/replace the current process image.
- **`failingProcessSpawn`**: Fails to spawn a child process.
- **`failingChildWait`**: Fails to wait for child termination/status.
- **`noChildKill`**: No-op/unsupported child kill stub.
- **`failingProgressParentFile`**: Fails to obtain a progress-reporting parent file handle.
- **`failingInheritParentDir`**: Fails to adopt an inherited directory handle.
- **`failingInheritParentFile`**: Fails to adopt an inherited file handle.

*Time stubs:*
- **`failingNow`**: Returns a failing/default timestamp behavior for `now` in the failing backend.
- **`failingClockResolution`**: Fails to query clock resolution.
- **`noSleep`**: Sleep returns immediately / is a no-op (or only checks cancel) so `Io.failing` does not block.

*Randomness stubs:*
- **`noRandom`**: Fills buffer with deterministic/no-op data as defined by the stub (or leaves behavior inert) — `Io.failing` does not provide real entropy.
- **`failingRandomSecure`**: Fails secure-random generation (e.g. `EntropyUnavailable`).

*Networking stubs:*
- **`failingNetListenIp`**: Fails to listen on an IP address.
- **`failingNetAccept`**: Fails to accept a connection.
- **`failingNetBindIp`**: Fails to bind an IP socket.
- **`failingNetConnectIp`**: Fails to connect to an IP address.
- **`failingNetListenUnix`**: Fails to listen on a Unix socket.
- **`failingNetConnectUnix`**: Fails to connect to a Unix socket.
- **`failingNetSocketCreatePair`**: Fails to create a socket pair.
- **`noNetWriteFile`**: Reports network file-send unsupported.
- **`unreachableNetClose`**: Unreachable network socket close stub.
- **`failingNetShutdown`**: Fails to shut down a socket.
- **`failingNetInterfaceNameResolve`**: Fails to resolve an interface name to an interface.
- **`failingNetInterfaceName`**: Fails to get the name of an interface.
- **`failingNetLookup`**: Fails hostname/DNS lookup.

**How to use `Io.failing`:** pass it where an API requires an `io: Io` but you intentionally want all real I/O/concurrency to be rejected or inert. It is valuable for pure logic tests, compile-time-adjacent contexts, or ensuring code paths do not perform side effects. Do not expect it to read files, sleep meaningfully, or spawn tasks.

---

## 2. `std.Io.Reader` (`std/Io/Reader.zig`)

`Reader` is a generic, buffered byte *source* with a vtable. Layout: `vtable: *const VTable`, `buffer: []u8`, `seek: usize` (consumed index), `end: usize` (filled index). Invariant: buffered unread bytes are `buffer[seek..end]`. Consumers call high-level methods (`take`, `peek`, `stream*`, `discard*`, parsing helpers); implementations provide `stream` (and optionally `discard/readVec/rebase`).

### 2.1 Types and constants
- **`Limited`** (`const`): Re-export of `Reader/Limited.zig`, a reader adapter that enforces a byte `Limit` (wraps another reader and stops/returns EOF behavior at the limit).
- **`VTable`** (`const struct`): Implementation hooks:
  - `stream(r, w, limit) StreamError!usize` (**required**): Produce bytes from the logical stream into `w` and/or by filling `r.buffer` (updating `seek/end`), advancing logical position by the count returned. May return 0 without signaling EOF; called even when buffer work is needed.
  - `discard(r, limit) Error!usize` (default `defaultDiscard`): Skip/consume up to `limit` bytes without exposing them. Default streams into a discarding writer over `r.buffer`.
  - `readVec(r, data: [][]u8) Error!usize` (default `defaultReadVec`): Scatter-read into `data` vectors (or into `r.buffer`), returning bytes placed for the caller. Default streams into the largest of `data[0]` or `r.buffer`.
  - `rebase(r, capacity) RebaseError!void` (default `defaultRebase`): Ensure `capacity` bytes can be buffered contiguously (typically by memmoving unread bytes to front and setting `seek=0`). Must satisfy capacity or end stream within capacity per contract.
- **`StreamError`** (`error set`): `ReadFailed || WriteFailed || EndOfStream`. `EndOfStream` originates from the reader; `WriteFailed` from the destination writer during streaming.
- **`Error`** (`error set`): `ReadFailed || EndOfStream` for direct read/consume operations.
- **`StreamRemainingError`** (`error set`): `ReadFailed || WriteFailed` (used when EOF is treated as successful completion).
- **`ShortError`** (`error set`): `ReadFailed` only (operations that may return fewer bytes instead of EOF in some forms).
- **`RebaseError`** (`const`): Alias of `Error` for rebasing failures.
- **`failing`** (`const Reader`): A reader whose vtable always fails reads/discards (`ReadFailed`), with empty buffer. Useful to inject read failures.
- **`ending_instance`** (`const Reader`): A reader fixed over an empty slice (`fixed(&.{})`), i.e. immediately at EOF.
- **`ending`** (`*Reader`): Mutable pointer view of `ending_instance` for APIs needing a `*Reader` that always yields EOF.

### 2.2 Construction and adapters
- **`limited(r, limit, buffer)`** (`fn`): Wraps `r` in a `Limited` reader using `buffer`, enforcing `limit` bytes total. Use to cap untrusted streams.
- **`fixed(buffer)`** (`fn`): Constructs a `Reader` backed by `buffer` contents in memory (no I/O). `seek=0`, `end=buffer.len`. Its vtable signals EOF when exhausted; `@constCast` is used internally but mutation is prevented by EOF behavior. Ideal for parsing byte slices.
- **`hashed(r, hasher, buffer)`** (`fn`): Returns a `Hashed(Hasher)` adapter that reads through `r` while updating `hasher` with consumed bytes (see `Hashed`). Useful to compute digests while parsing/streaming.

### 2.3 Streaming and copying to writers
- **`stream(r, w, limit)`** (`fn`): Transfers up to `limit` bytes from `r` to `w`. Fast path: if buffered bytes exist, writes them to `w` and advances `seek`. Otherwise calls `vtable.stream`. Returns bytes written; may return 0; propagates `ReadFailed/WriteFailed/EndOfStream`.
- **`discard(r, limit)`** (`fn`): Consumes up to `limit` bytes without exposing them. Consumes buffered data first, then calls `vtable.discard` for the remainder. Returns total discarded; may be 0; errors on read failure/EOF per `Error`.
- **`defaultDiscard(r, limit)`** (`fn`): Default vtable discard: resets buffer indices and streams into a temporary discarding writer over `r.buffer`, also accounting for bytes an implementation placed directly in `r.buffer`. Bounded by `limit`.
- **`streamExact(r, w, n)`** (`fn`): Loops `stream` until exactly `n` bytes are written to `w` or an error occurs. Fails with `EndOfStream` if stream ends early.
- **`streamExact64(r, w, n)`** (`fn`): 64-bit-count variant of `streamExact` for very large transfers.
- **`streamExactPreserve(r, w, preserve_len, n)`** (`fn`): Like `streamExact` but manages writer buffering so at least `preserve_len` bytes remain buffered in `w` when feasible (useful to keep headers/lookahead). Requires writer buffer capacity >= `preserve_len`; handles large `n` by streaming in chunks and rebasing writer.
- **`streamRemaining(r, w)`** (`fn`): Pumps all remaining bytes until `EndOfStream`, which it treats as success. Returns total bytes written. Propagates `ReadFailed`/`WriteFailed`. Best for “copy everything”.
- **`discardRemaining(r)`** (`fn`): Consumes and counts all remaining bytes until EOF, ignoring data. Returns total discarded; useful to drain a stream.
- **`defaultReadVec(r, data)`** (`fn`): Default `readVec`: streams into the larger of `data[0]` or `r.buffer` to satisfy a vectored read request, updating `r.end` if buffered.

### 2.4 Allocation and appending helpers
- **`LimitedAllocError`** (`error set`): `Allocator.Error || ShortError || error{StreamTooLong}` for bounded allocation reads.
- **`allocRemaining(r, gpa, limit)`** (`fn`): Reads all bytes (up to `limit`) into a newly allocated slice owned by caller. If more than `limit` bytes are available, returns `error.StreamTooLong` (and discards/positions per implementation contract so overrun is detected). Convenience for “read whole stream”.
- **`allocRemainingAlignedSentinel(r, gpa, limit, alignment, sentinel)`** (`fn`): Like `allocRemaining` but returns aligned memory and optionally appends a sentinel byte.
- **`AppendExactError`** (`error set`): `Allocator.Error || Error`.
- **`appendExact(r, gpa, list, n)`** (`fn`): Ensures capacity and appends exactly `n` bytes from `r` into an `ArrayList(u8)`. Fails on EOF/read error/alloc error.
- **`appendRemaining(r, gpa, list, limit)`** (`fn`): Appends stream contents to `list` up to `limit`; returns `StreamTooLong` if limit exceeded. Unbounded when `limit == .unlimited`.
- **`appendRemainingAligned(r, gpa, alignment, list, limit)`** (`fn`): Aligned variant of `appendRemaining`.
- **`UnlimitedAllocError`** (`error set`): `Allocator.Error || ShortError`.
- **`appendRemainingUnlimited(r, gpa, list)`** (`fn`): Appends all remaining bytes with no cap into `list` (grows as needed). Risky on untrusted input (memory exhaustion).

### 2.5 Buffered/vector reads
- **`readVec(r, data)`** (`fn`): Fills provided buffers/vectors from already-buffered bytes first, then calls `vtable.readVec` if more needed. Returns total bytes read; 0 does not imply EOF except when surfaced as `EndOfStream`. Handles partial progress across slices.
- **`buffered(r)`** (`fn`): Returns the unread slice `r.buffer[seek..end]` (mutable view into internal buffer). Valid until next operation that mutates/rebases.
- **`bufferedLen(r)`** (`fn`): Returns number of unread buffered bytes (`end - seek`).
- **`readVecAll(r, data)`** (`fn`): Loops until every byte of every slice in `data` is filled or error (`EndOfStream` if stream ends short). Strong “read fully” contract.
- **`peek(r, n)`** (`fn`): Ensures at least `n` bytes buffered (`fill(n)`) and returns `buffer[seek..][0..n]` without consuming. Asserts reader buffer capacity >= `n`. Invalidated by later peek/fill/take that rebases.
- **`peekGreedy(r, n)`** (`fn`): Ensures at least `n` bytes then returns all currently buffered bytes from `seek` to `end` (may be > `n`). Good for “process as much as available” loops.
- **`toss(r, n)`** (`fn`): Consumes `n` buffered bytes by advancing `seek` (asserts they are buffered). O(1); used after `peek`.
- **`tossBuffered(r)`** (`fn`): Consumes all buffered bytes (`seek = end`).
- **`take(r, n)`** (`fn`): `peek(n)` then `toss(n)`; returns a slice of exactly `n` bytes and advances position. Zero-copy into internal buffer.
- **`takeArray(r, comptime n)`** (`fn`): Like `take` but returns `*[n]u8`.
- **`peekArray(r, comptime n)`** (`fn`): Like `peek` but returns `*[n]u8`.
- **`discardAll(r, n)`** (`fn`): Discards exactly `n` bytes or returns `EndOfStream` if fewer remain.
- **`discardAll64(r, n)`** (`fn`): 64-bit exact discard.
- **`discardShort(r, n)`** (`fn`): Discards up to `n` bytes, returning how many were discarded (less than `n` only on EOF). Never errors with EOF, only `ReadFailed`.
- **`readSliceAll(r, buffer)`** (`fn`): Fills `buffer` completely or errors with `EndOfStream`.
- **`readSliceShort(r, buffer)`** (`fn`): Reads up to `buffer.len`, returning bytes read (may be short on EOF) or `ReadFailed`.
- **`readSliceEndian(r, T, buffer, endian)`** (`fn`, inline): Reads elements into a typed slice and byte-swaps each element to native order if `endian` differs, enabling portable binary decoding.
- **`ReadAllocError`** (`error set`): `Error || Allocator.Error`.
- **`readSliceEndianAlloc(r, allocator, T, len, endian)`** (`fn`, inline): Allocates a slice of `len` elements, reads them with endian conversion, returns owned slice.
- **`readAlloc`** (`const`): Alias for `readAllocAll`.
- **`readAllocAll(r, allocator, len)`** (`fn`): Allocates and reads exactly `len` bytes.
- **`readAllocShort(r, allocator, len)`** (`fn`): Allocates and reads up to `len` bytes, returning actual length (short on EOF).

### 2.6 Delimiters, sentinels, and token reads
- **`DelimiterError`** (`error set`): `ReadFailed || EndOfStream || error{StreamTooLong}` for delimiter searches that may exceed buffer/limits.
- **`takeSentinel(r, comptime sentinel)`** (`fn`): Returns bytes up to but excluding `sentinel`, consuming through the sentinel (result is sentinel-terminated slice type). Fails if sentinel not found within constraints.
- **`peekSentinel(r, comptime sentinel)`** (`fn`): Like `takeSentinel` but does not consume.
- **`takeDelimiterInclusive(r, delimiter)`** (`fn`): Returns slice including the delimiter byte; consumes it.
- **`peekDelimiterInclusive(r, delimiter)`** (`fn`): Peeks through and including delimiter.
- **`takeDelimiterExclusive(r, delimiter)`** (`fn`): Returns slice up to (excluding) delimiter and consumes the delimiter. Common for line/field parsing.
- **`takeDelimiter(r, delimiter)`** (`fn`): Takes up to delimiter; returns `null` on EOF before delimiter in some forms or errors on overflow (`ReadFailed, StreamTooLong` per signature) — a softer variant for optional-delimited streams.
- **`peekDelimiterExclusive(r, delimiter)`** (`fn`): Peeks up to delimiter without consuming.
- **`streamDelimiter(r, w, delimiter)`** (`fn`): Streams bytes to `w` until delimiter (behavior re: including/excluding per impl; returns count) — useful to copy a delimited record.
- **`streamDelimiterEnding(r, w, delimiter, ending)`** (`fn`): Streams a delimited segment and handles/normalizes the ending as specified.
- **`StreamDelimiterLimitError`** (`error set`): Adds limit/overflow errors for bounded delimiter streaming.
- **`streamDelimiterLimit(r, w, delimiter, limit)`** (`fn`): Streams until delimiter or `limit` reached, preventing unbounded consumption.
- **`discardDelimiterInclusive(r, delimiter)`** (`fn`): Skips bytes through delimiter inclusive; returns count.
- **`discardDelimiterExclusive(r, delimiter)`** (`fn`): Skips bytes up to delimiter (delimiter handling per signature/impl), may return short/error forms.
- **`DiscardDelimiterLimitError`** (`error set`): Error set for limited delimiter discard.
- **`discardDelimiterLimit(r, delimiter, limit)`** (`fn`): Discards until delimiter or limit, returning bytes discarded or limit-related error.

### 2.7 Filling, bytes, integers, structs, enums, LEB128
- **`fill(r, n)`** (`fn`): Ensures at least `n` unread bytes are buffered (reading from source as needed) or returns `EndOfStream`/`ReadFailed`. Core primitive behind `peek/take`.
- **`fillMore(r)`** (`fn`): Attempts to buffer more data than currently available (at least one more byte/progress) without requiring a specific `n`.
- **`peekByte(r)`** (`fn`): Ensures 1 byte and returns it without consuming.
- **`takeByte(r)`** (`fn`): Reads and consumes one byte (`u8`).
- **`takeByteSigned(r)`** (`fn`): Reads one byte interpreted as `i8`.
- **`takeInt(r, comptime T, endian)`** (`fn`, inline): Reads `@sizeOf(T)` bytes and decodes an integer of type `T` with given `endian`. Portable binary parsing.
- **`peekInt(r, comptime T, endian)`** (`fn`, inline): Decodes integer without consuming.
- **`takeVarInt(r, comptime Int, endian, n)`** (`fn`): Reads `n` bytes and decodes as a variable-width integer value into `Int`.
- **`takeStructPointer(r, comptime T)`** (`fn`): Returns a pointer (`*align(1) T`) into the buffered bytes reinterpreted as struct `T` (no copy, alignment 1). Consumes it; useful for packed/binary views when layout is controlled.
- **`peekStructPointer(r, comptime T)`** (`fn`): Same as `takeStructPointer` without consuming.
- **`takeStruct(r, comptime T, endian)`** (`fn`, inline): Reads bytes for `T` and returns a value, applying endian conversion as needed. Safe/value copy form for binary deserialization.
- **`peekStruct(r, comptime T, endian)`** (`fn`, inline): Peeks and decodes struct.
- **`TakeEnumError`** (`error set`): `Error || error{InvalidEnumTag}`.
- **`takeEnum(r, comptime Enum, endian)`** (`fn`): Reads enum tag integer and converts to `Enum`, erroring if tag is invalid.
- **`takeEnumNonexhaustive(r, comptime Enum, endian)`** (`fn`): Reads tag into a non-exhaustive enum allowing unknown values (per Zig enum semantics).
- **`TakeLeb128Error`** (`error set`): `Error || error{Overflow}`.
- **`takeLeb128(r, comptime T)`** (`fn`): Decodes an LEB128-encoded integer into `T`; errors on malformed/overflowing encodings or read failure/EOF.

### 2.8 Rebase and advanced internals
- **`rebase(r, capacity)`** (`fn`): Public method to invoke `vtable.rebase`, ensuring space for `capacity` buffered bytes (usually compacts buffer). Called when `peek/fill` needs contiguous room.
- **`defaultRebase(r, capacity)`** (`fn`): Moves `buffer[seek..end]` to `buffer[0..]`, resets `seek=0`, to satisfy capacity if possible.
- **`Hashed(comptime Hasher)`** (`fn type`): Reader wrapper type that mirrors reads from an underlying reader while feeding all consumed bytes into a hasher, exposing both the reader interface and the accumulated hash state. Useful for verified reads (e.g. checksum while parsing).
- **`writableVectorPosix(r, buffer, data)`** (`fn`): Helper to build `iovec` arrays for POSIX vectored reads based on reader buffer space and destination `data` slices; returns counts/sizes for syscalls.
- **`writableVectorWsa(r, ...)`** (`fn`): Windows/WSA vectored-buffer helper analogous to POSIX.
- **`writableVector(r, buffer, data)`** (`fn`): Platform-neutral helper selecting appropriate vectored buffer construction for `readVec`/stream implementations.

---

## 3. `std.Io.Writer` (`std/Io/Writer.zig`)

`Writer` is a generic, buffered byte *sink* with a vtable. Layout: `vtable: *const VTable`, `buffer: []u8`, `end: usize`. Buffered pending bytes are `buffer[0..end]`. Writes append to the buffer when space allows; when not, data (and buffered prefix) is passed to `vtable.drain`. `flush` forces all buffered bytes out.

### 3.1 Types and errors
- **`VTable`** (`const struct`): Sink hooks:
  - `drain(w, data, splat) Error!usize` (**required**): Consume `w.buffer[0..end]` first, then vectors in `data` in order, with `data[last]` logically repeated `splat` times. May mutate `buffer/end` to reflect consumed bytes. Returns bytes consumed from `data` (not counting `buffer`); may return 0 without implying failure/end. Must be called when buffered+new data cannot fit or on flush paths per contract.
  - `sendFile(w, file_reader, limit) FileError!usize` (default `unimplementedSendFile`): Optimized path to transfer up to `limit` bytes from a `File.Reader` to the sink (e.g. sendfile/splice/copy_file_range). Consumes `buffer[0..end]` first. Returns bytes logically written (excluding prior buffer) or `error.Unimplemented` to request fallback to ordinary read+write.
  - `flush(w) Error!void` (default `defaultFlush`): Ensure all buffered data is drained.
  - `rebase(w, preserve, capacity) Error!void` (default `defaultRebase`): Make room for `capacity` more bytes while keeping at least the most recent `preserve` bytes buffered (may drain and/or memmove).
- **`Error`** (`error set`): `error{WriteFailed}`. Concrete writers store detailed causes elsewhere (e.g. `File.Writer.err`).
- **`FileAllError`** (`error set`): `ReadFailed || WriteFailed` for operations transferring a whole file where read or write can fail.
- **`FileReadingError`** (`error set`): `ReadFailed || WriteFailed || EndOfStream` when reading the source file can hit EOF distinctly.
- **`FileError`** (`error set`): `ReadFailed || WriteFailed || EndOfStream || Unimplemented` for `sendFile` paths (allows “not supported” fallback).

### 3.2 Construction and basic state
- **`fixed(buffer)`** (`fn`): Writer that stores bytes into `buffer` only. On overflow/drain it fails with `WriteFailed` (via `fixedDrain`), flush is a no-op, rebase fails. Use for bounded formatting/parsing emission.
- **`hashed(w, hasher, buffer)`** (`fn`): Returns a `Hashed(Hasher)` that forwards bytes to `w` while hashing them (buffering in `buffer`). See `Hashed`/`Hashing`.
- **`failing`** (`const Writer`): Writer whose drain/sendFile/rebase always `WriteFailed`.
- **`buffered(w)`** (`fn`): Returns pending bytes `buffer[0..end]`.
- **`countSplat(data, splat)`** (`fn`): Computes total logical byte count of a vectored+splat write (`sum(data[0..n-1]) + data[n-1].len * splat`).
- **`countSendFileLowerBound(n, file_reader, limit)`** (`fn`): Estimates a lower bound on bytes that would be transferred by a send-file operation given current writer state `n`, file size, and `limit` (returns `null` if size unknown).

### 3.3 Vectored and splat writes
- **`writeVec(w, data)`** (`fn`): Writes all vectors in `data` (splat 1). Fast path: if total fits in unused capacity, memcpy into buffer and return total without vtable call.
- **`writeSplat(w, data, splat)`** (`fn`): Writes `data` with the last element repeated `splat` times. Buffers fully when it fits; otherwise calls `vtable.drain`.
- **`writeSplatHeader(w, header, data, splat)`** (`fn`): Writes `header` followed by `data`/splat (unlimited). Convenience for prefixed records.
- **`writeSplatHeaderLimit(w, header, data, splat, limit)`** (`fn`): Bounded variant that writes at most `limit` bytes total, draining as needed.
- **`flush(w)`** (`fn`): Calls `vtable.flush` to drain all buffered bytes.
- **`defaultFlush(w)`** (`fn`): Repeatedly drains until `end == 0`.
- **`noopFlush(w)`** (`fn`): No-op (used by fixed/allocating-style writers that manage storage differently).

### 3.4 Buffer management and direct access
- **`rebase(w, preserve, unused_capacity_len)`** (`fn`): Ensures `unused_capacity_len` bytes free, keeping `preserve` bytes; fast-returns if already available else calls `vtable.rebase`.
- **`defaultRebase(w, preserve, minimum_len)`** (`fn`): Drains/memmoves to satisfy capacity while preserving the requested tail, asserting the implementation can provide space.
- **`unusedCapacitySlice(w)`** (`fn`): Returns writable tail `buffer[end..]`.
- **`unusedCapacityLen(w)`** (`fn`): Number of free bytes in buffer.
- **`writableArray(w, comptime len)`** (`fn`): Obtains exactly `len` writable bytes (greedy ensure + advance) and returns `*[len]u8`.
- **`writableSlice(w, len)`** (`fn`): Like `writableArray` but runtime length.
- **`writableSliceGreedy(w, minimum_len)`** (`fn`): Returns a slice of at least `minimum_len` writable bytes (possibly entire free capacity) without advancing; caller must `advance`.
- **`writableSliceGreedyPreserve(w, preserve, minimum_len)`** (`fn`): Greedy writable slice while preserving `preserve` buffered bytes across any rebase/drain.
- **`writableSlicePreserve(w, preserve, len)`** (`fn`): Ensures capacity keeping `preserve`, advances by `len`, returns that slice.
- **`ensureUnusedCapacity(w, n)`** (`fn`): Ensures at least `n` free bytes are available (may rebase/drain).
- **`undo(w, n)`** (`fn`): Rewinds `end` by `n` bytes, logically removing them from the buffered output (caller must ensure they were not drained).
- **`advance(w, n)`** (`fn`): Commits `n` bytes written into `unusedCapacitySlice`/`writableSliceGreedy` by increasing `end`.

### 3.5 High-level writes and formatting
- **`writeVecAll(w, data)`** (`fn`): Ensures every byte in every vector is written (loops over partial writes/drains). Temporarily mutates slice views to track progress but restores them.
- **`writeSplatAll(w, data, splat)`** (`fn`): Fully writes vectored+splat data, handling partial progress and remaining splats.
- **`write(w, bytes)`** (`fn`): Writes as much of `bytes` as possible in one step: memcpy into buffer if it fits, else one `drain` call. Returns bytes consumed (may be < len).
- **`writeAll(w, bytes)`** (`fn`): Loops `write` until all bytes are accepted.
- **`print(w, comptime fmt, args)`** (`fn`): Renders Zig’s `std.fmt` format string with `args`, emitting into `w`. Supports standard placeholders `{[arg][specifier]:[fill][align][width].[precision]}` and routes values through `printValue`/type-specific printers. Core formatted-output API.
- **`writeByte(w, byte)`** (`fn`): Appends a single byte (buffer fast path or drain).
- **`writeBytePreserve(w, preserve, byte)`** (`fn`): Writes a byte while ensuring `preserve` bytes remain buffered across rebase.
- **`splatByteAll(w, byte, n)`** (`fn`): Writes byte `byte` repeated `n` times fully.
- **`splatBytePreserve(w, preserve, byte, n)`** (`fn`): Repeated byte write preserving buffered tail.
- **`splatByte(w, byte, n)`** (`fn`): Writes up to `n` repeated bytes in one step, returns count written.
- **`splatBytesAll(w, bytes, splat)`** (`fn`): Repeats pattern `bytes` `splat` times fully.
- **`splatBytes(w, bytes, n)`** (`fn`): Partial/stepwise pattern splat.
- **`writeInt(w, comptime T, value, endian)`** (`fn`, inline): Serializes integer `T` in specified endianness to the stream.
- **`writeStruct(w, value, endian)`** (`fn`, inline): Serializes a struct/value’s memory representation with endian handling as defined (binary output).
- **`writeSliceEndian(w, T, slice, endian)`** (`fn`, inline): Writes each element of a typed slice with endian conversion.
- **`writeSliceSwap(w, Elem, slice)`** (`fn`): Writes elements with byte-swapping as needed.
- **`sendFile(w, file_reader, limit)`** (`fn`): Attempts `vtable.sendFile` to transfer from `file_reader` efficiently; may flush/consume buffer as per implementation. Returns bytes written or `Unimplemented`/errors.
- **`sendFileHeader(w, file_reader, header, limit)`** (`fn`): Sends `header` plus file contents (optimized when supported).
- **`sendFileReading(w, file_reader, limit)`** (`fn`): Send-file variant that surfaces `FileReadingError` distinctions.
- **`sendFileAll(w, file_reader, limit)`** (`fn`): Ensures transfer completes up to limit/EOF per `FileAllError`.
- **`sendFileReadingAll(w, file_reader, limit)`** (`fn`): Fully transfers with read-failure-aware errors.
- **`alignBuffer(w, buffer, options)` / `alignBufferOptions`** (`fn`): Helpers to apply alignment/padding/width when formatting into a buffer/writer per `std.fmt.Options`.

### 3.6 Formatting helpers
- **`printAddress(w, value)`** (`fn`): Formats a pointer/address value.
- **`printValue(w, ...)`** (`fn`): Core dispatcher that formats an arbitrary value according to format specifier/kind (ints, floats, pointers, enums, structs, slices, optionals, errors, etc.), used by `print`.
- **`printStringEscaped(w, bytes)`** (`fn`): Writes a string with escape sequences for non-printable/special characters.
- **`printVector(w, ...)`** (`fn`): Formats SIMD/vector values.
- **`printArray(w, ...)`** (`fn`): Formats array values.
- **`printInt(w, ...)`** (`fn`, inline): Formats an integer with base/options.
- **`printIntAny(w, ...)`** (`fn`): Formats arbitrary integer-like values.
- **`printAsciiChar(w, c, options)`** (`fn`): Formats a single ASCII character with formatting options.
- **`printAscii(w, bytes, options)`** (`fn`): Formats byte slices as ASCII with options.
- **`printUnicodeCodepoint(w, c)`** (`fn`): Encodes and writes a Unicode codepoint `u21` as UTF-8.
- **`printFloat(w, value, options)`** (`fn`): Formats floating-point numbers per `std.fmt.Number` options.
- **`printFloatHexOptions(w, value, options)`** (`fn`): Hex-float formatting with options.
- **`printFloatHex(w, value, case, opt_precision)`** (`fn`): Hexadecimal floating-point representation.
- **`ByteSizeUnits`** (`const enum`): Units/base choices for human-readable byte sizes (e.g. decimal/binary units).
- **`printByteSize(w, ...)`** (`fn`): Formats a byte count as human-readable size (KB/KiB etc.).
- **`invalidFmtError(comptime fmt, value)`** (`fn`): Compile-time error/reporting helper for invalid format usage.
- **`printHex(w, bytes, case)`** (`fn`): Writes raw bytes as hex string in given case.
- **`printBase64(w, bytes)`** (`fn`): Encodes bytes as Base64 to the writer.
- **`writeUleb128(w, value)`** (`fn`): Encodes an unsigned integer as ULEB128.
- **`writeSleb128(w, value)`** (`fn`): Encodes a signed integer as SLEB128.
- **`writeLeb128(w, value)`** (`fn`): Generic LEB128 writer dispatching by signedness.

### 3.7 Low-level vtable helpers and adapters
- **`failingDrain`** (`fn`): Drain implementation that always returns `WriteFailed`.
- **`failingSendFile`** (`fn`): Send-file implementation that always fails.
- **`failingRebase`** (`fn`): Rebase implementation that always fails.
- **`Discarding`** (`const struct`): A sink that counts and drops all bytes. Fields: `count` (drained total) and `writer: Writer`. Methods:
  - `init(buffer)`: Creates a discarding writer using `buffer` for temporary batching.
  - `fullCount()`: Returns total discarded including any bytes still buffered in `writer`.
  - `drain(...)`: Consumes buffered+incoming data, increments `count`, resets `end`.
  - `sendFile(...)`: Efficiently discards file data (may use file size/limit to account bytes without copying) when supported.
- **`consume(w, n)`** (`fn`): After a drain/sendFile reports `n` bytes consumed from `w.buffer` prefix and/or data, advances/removes that many from the buffered front (memmove/adjust `end`) and returns adjusted count for caller bookkeeping.
- **`consumeAll(w)`** (`fn`): Marks all buffered bytes as consumed (`end=0`) returning count.
- **`unimplementedSendFile`** (`fn`): Default `sendFile` returning `error.Unimplemented`.
- **`fixedDrain`** (`fn`): Drain for `fixed` writer: can only accept data if it fits; otherwise `WriteFailed`.
- **`unreachableDrain`** (`fn`): Drain that must never be called (for writers that never drain).
- **`unreachableRebase`** (`fn`): Rebase that must never be called.
- **`fromArrayList(array_list)`** (`fn`): Creates a `Writer` that writes into an `ArrayList(u8)`’s storage (bridging APIs).
- **`toArrayList(w)`** (`fn`): Reconstructs/extracts an `ArrayList(u8)` view from a writer backed by one (when applicable).
- **`Hashed(comptime Hasher)`** (`fn type`): Writer adapter that tees all bytes written into an underlying hasher while forwarding to an inner writer (parameterized in `hashed(w,...)` usage). Provides access to hash state.
- **`Hashing(comptime Hasher)`** (`fn type`): A concrete writer type (used as `Writer.Hashing(T)`) that buffers bytes and updates `hasher` on drain/flush. Fields/methods include: `hasher`, `writer`; `init(buffer)` / `initHasher(hasher, buffer)` to construct; internal `drain` that hashes `writer.buffered()` and each incoming slice/splat. **Important:** call `hashing.writer.flush()` before finalizing the digest so buffered tail bytes are hashed.
- **`Allocating`** (`const struct`): Growable allocating writer that keeps `Writer` state pointed at an allocated buffer so ordinary formatted/vector writes hit fast buffered paths until resize is needed. Key members/behavior:
  - fields: `allocator`, `writer: Writer`, `alignment`.
  - `init(allocator)` / `initAligned(...)`: empty growable writer.
  - `initCapacity(allocator, capacity)`: preallocates.
  - `initOwnedSlice` / `initOwnedSliceAligned`: takes ownership of an existing slice as backing storage.
  - `fromArrayList` / `fromArrayListAligned`: adopts and empties an `ArrayList`, taking its memory.
  - `deinit()`: frees owned buffer.
  - `toArrayList` / `toArrayListAligned`: transfers ownership out as an `ArrayList` and resets writer.
  - `ensureUnusedCapacity` / `ensureTotalCapacity` / `ensureTotalCapacityPrecise`: capacity management (grow policy, remap/realloc+copy).
  - `toOwnedSlice()` / `toOwnedSliceSentinel(...)`: returns owned slice of written bytes (trimming/returning memory appropriately) and resets writer.
  - `written()`: returns the currently written slice view.
  - vtable uses allocating/growing drain/sendFile/rebase behavior; `flush` is effectively a no-op because data lives in the owned buffer (already “emitted” to memory).

---

## 4. `std.Io.File` (`std/Io/File.zig`)

`File` is an OS file handle wrapper plus cross-platform operations dispatched through `Io`. Layout: `handle: Handle`, `flags: Flags`. Most operations take `(file, io, ...)` and call the corresponding `io.vtable.file*` or `io.operate` methods.

### 4.1 Handle, flags, and submodules
- **`Flags`** (`const struct`): Records open/handle mode relevant to I/O behavior; notably `nonblocking: bool` (Windows async/alertable vs synchronous; POSIX O_NONBLOCK state).
- **`Handle`** (`const`): Underlying OS descriptor (`std.posix.fd_t` / platform handle).
- **`Reader`** (`const`): Re-export of `Io/File/Reader.zig` (buffered, stateful reader over a `File`).
- **`Writer`** (`const`): Re-export of `Io/File/Writer.zig` (buffered, stateful writer over a `File`).
- **`Atomic`** (`const`): Re-export of `Io/File/Atomic.zig` (atomic file replacement/write helpers).
- **`MemoryMap`** (`const`): Re-export of `Io/File/MemoryMap.zig` (file-backed memory mapping).
- **`MultiReader`** (`const`): Re-export of `Io/File/MultiReader.zig` (concurrent reads from multiple streams).
- **`INode` / `NLink` / `Uid` / `Gid` / `BlockSize`** (`const`): Platform metadata integer types from `std.posix` for stat/ownership/block sizing.

### 4.2 Metadata and identity types
- **`Kind`** (`const enum`): File type classification: `block_device`, `character_device`, `directory`, `named_pipe`, `sym_link`, `file`, `unix_domain_socket`, `whiteout`, `door`, `event_port`, `unknown`.
- **`Stat`** (`const struct`): File metadata snapshot: `inode`, `nlink`, `size`, `permissions`, `kind`, `atime: ?Io.Timestamp` (nullable because some FSes don’t track/report it reliably), `mtime`, `ctime`, `block_size` (preferred I/O chunk size, 1 if unknown).
- **`stdout()`** (`fn`): Returns a `File` for standard output (Windows handle from PEB or POSIX `STDOUT_FILENO`, nonblocking false).
- **`stderr()`** (`fn`): Returns a `File` for standard error.
- **`stdin()`** (`fn`): Returns a `File` for standard input.
- **`StatError`** (`error set`): Errors from stat: `SystemResources`, `AccessDenied`, `PermissionDenied`, `Streaming` (not a stat-able file stream), plus `Cancelable`/`UnexpectedError`.
- **`stat(file, io)`** (`fn`): Queries and returns `Stat` for the open handle via `vtable.fileStat`.
- **`Lock`** (`const enum`): Advisory lock mode: `none`, `shared`, `exclusive`.

### 4.3 Opening and closing
- **`OpenError`** (`error set`): Comprehensive set of failures when opening files: busy pipe/device/network issues, antivirus interference (Windows), access/permission errors, symlink loops, fd/process limits, not-found, name too long/resource exhaustion, too big, is-a-directory vs file, no space, not-a-dir, already exists (exclusive create), read-only FS, device/file busy/locks unsupported, would-block, plus `Dir.PathNameError`, `Cancelable`, `UnexpectedError`. Returned by open/create operations routed through directory/file APIs.
- **`close(file, io)`** (`fn`): Closes one file handle via `vtable.fileClose`.
- **`closeMany(io, files)`** (`fn`): Closes multiple handles in one call (allows backend batching/efficiency).

### 4.4 Sync, TTY, and basic properties
- **`SyncError`** (`error set`): `InputOutput`, `NoSpaceLeft`, `DiskQuota`, `AccessDenied`, plus cancel/unexpected. For `fsync`-like durability operations.
- **`sync(file, io)`** (`fn`): Flushes pending data and metadata for this file to stable storage (not necessarily directory entry metadata). `vtable.fileSync`.
- **`isTty(file, io)`** (`fn`): Returns whether the handle is a terminal/TTY (cancelable). Used to decide on interactive behavior/ANSI.
- **`EnableAnsiEscapeCodesError`** (`error set`): `NotTerminalDevice` plus cancel/unexpected.
- **`enableAnsiEscapeCodes(file, io)`** (`fn`): Attempts to enable ANSI escape processing on the terminal (platform-specific; on Windows may adjust console mode).
- **`supportsAnsiEscapeCodes(file, io)`** (`fn`): Tests ANSI support without trying to change modes.

### 4.5 Size, permissions, ownership, timestamps
- **`SetLengthError`** (`error set`): `FileTooBig`, `InputOutput`, `FileBusy`, `AccessDenied`, `PermissionDenied`, `NonResizable`, plus cancel/unexpected.
- **`setLength(file, io, new_length)`** (`fn`): Truncates or extends the file to `new_length` (extension zero-fills). Does not change file offset. Operates on an open handle to avoid TOCTOU issues with path-based truncate.
- **`LengthError`** (`const`): Alias of `StatError` (length may be obtained via stat/length path).
- **`length(file, io)`** (`fn`): Returns end-of-file byte index/size, potentially cheaper than full `stat` when only size is needed (`vtable.fileLength`).
- **`SetPermissionsError`** (`error set`): Access/permission/IO/symlink/not-found/resources/read-only FS plus cancel/unexpected.
- **`setPermissions(file, io, new_permissions)`** (`fn`): chmod-like operation on the open file; requires appropriate privileges/ownership.
- **`SetOwnerError`** (`error set`): Similar failure domain for chown-like changes.
- **`setOwner(file, io, owner, group)`** (`fn`): Changes uid/gid on the file (`null` leaves an ID unchanged); privilege rules apply.
- **`Permissions`** (`const`): Cross-platform permission/attribute representation. On POSIX maps to mode bits (`default_file` 0o666, `default_dir` 0o777, helpers `toMode/fromMode`, `readOnly`, `setReadOnly`, `executable_file`/`has_executable_bit`); on Windows maps to file attributes (e.g. read-only) with corresponding helpers; falls back to minimal enums on other platforms. Encodes the semantic “mode vs attributes” difference.
- **`SetTimestampsError`** (`error set`): Access/permission/read-only FS errors per utimensat-like semantics (e.g. setting arbitrary times requires ownership/capabilities; immutable/append-only restrictions).
- **`SetTimestampsOptions`** (`const struct`): Specifies `access_timestamp` and `modify_timestamp` each as a `SetTimestamp`.
- **`SetTimestamp`** (`const union(enum)`): `.unchanged`, `.now` (set to current wall-clock/`Io.Clock.real`), or `.new(timestamp)`. `init(optional)` converts `?Timestamp` to this union.
- **`setTimestamps(file, io, options)`** (`fn`): Sets atime/mtime per options; granularity clamped by OS/FS.
- **`setTimestampsNow(file, io)`** (`fn`): Convenience to set both timestamps to now.

### 4.6 Direct read/write (low-level, handle-based)
- **`ReadStreamingError`** (`error set`): `EndOfStream || Reader.Error`. For streaming (cursor-based) reads.
- **`readStreaming(file, io, buffer)`** (`fn`): Performs a streaming read via `io.operate(.{ .file_read_streaming = ... })` into provided buffers (vectored form). Returns bytes read; may return fewer than available; `EndOfStream` indicates end. Uses/advances the file’s streaming position as modeled by the backend.
- **`ReadPositionalError`** (`error set`): `InputOutput`, `SystemResources`, `IsDir`, `WouldBlock`, `AccessDenied`, `LockViolation`, `Unseekable`, `NotOpenForReading`, plus cancel/unexpected.
- **`readPositional(file, io, buffer, offset)`** (`fn`): Reads at absolute `offset` without relying on shared seek cursor (`vtable.fileReadPositional`). Returns 0 on EOF or empty buffer. Thread-friendlier for random access.
- **`WritePositionalError`** (`error set`): `DiskQuota`, `FileTooBig`, `InputOutput`, `NoSpaceLeft`, `DeviceBusy`, access/permission, `BrokenPipe`, `SystemResources`, `LockViolation`, `WouldBlock`, `NoDevice`, `FileBusy`, `Unseekable`, `NotOpenForWriting`, plus cancel/unexpected.
- **`writePositional(file, io, buffer, offset)`** (`fn`): Writes vectored buffers at `offset` via vtable; returns bytes written.
- **`writePositionalAll(file, io, bytes, offset)`** (`fn`): Loops positional writes until all `bytes` are written at successive offsets. Convenience for complete positional writes.
- **`SeekError`** (`error set`): `Unseekable`, `AccessDenied`, plus cancel/unexpected.
- **`WriteFilePositionalError`** (`const`): `Writer.WriteFileError || error{Unseekable}` for file-to-file positional transfers.

### 4.7 Buffered reader/writer constructors and streaming helpers
- **`reader(file, io, buffer)`** (`fn`): Creates a `File.Reader` in default (positional, with fallback) mode using `buffer` as its internal `Io.Reader` buffer. Preferred for buffered reads/random-access-capable files.
- **`readPositionalAll(file, io, buffer, offset)`** (`fn`): Fills `buffer` by repeated `readPositional` calls starting at `offset`; returns bytes read (< len on EOF).
- **`readerStreaming(file, io, buffer)`** (`fn`): Creates a `File.Reader` forced into streaming mode (avoids a failed positional-syscall probe when known unseekable/streaming).
- **`writer(file, io, buffer)`** (`fn`): Creates a `File.Writer` in default positional mode with `buffer`.
- **`writerStreaming(file, io, buffer)`** (`fn`): Creates a `File.Writer` in streaming mode.
- **`writeStreaming(file, io, header, data, splat)`** (`fn`): Low-level streaming write via `io.operate(.file_write_streaming)`, sending `header`, `data` vectors, and `splat` repetition. Returns bytes written.
- **`writeStreamingAll(file, io, bytes)`** (`fn`): Loops `writeStreaming` until all bytes are written (cursor-based).

### 4.8 Advisory locking and path resolution
- **`LockError`** (`error set`): `SystemResources`, `FileLocksUnsupported`, plus cancel/unexpected.
- **`lock(file, io, l)`** (`fn`): Acquires advisory lock (`shared` or `exclusive`, etc.) blocking if incompatible lock held; assumes unlocked state per contract. Released on process termination/`unlock`.
- **`unlock(file, io)`** (`fn`): Releases advisory lock.
- **`tryLock(file, io, l)`** (`fn`): Attempts to acquire lock without blocking; returns success boolean or error.
- **`DowngradeLockError`** (`const error set`): `Cancelable || UnexpectedError`.
- **`downgradeLock(file, io)`** (`fn`): Converts an exclusive lock to shared (error set as declared).
- **`RealPathError`** (`error set`): Errors resolving canonical path of a handle (name too long, not found, bad handle semantics, permission, symlink loop, etc., as defined in source).
- **`realPath(file, io, out_buffer)`** (`fn`): Writes the canonical absolute path of this file into `out_buffer`, returns length.
- **`HardLinkOptions`** (`const struct`): Options for hard-link creation (e.g. follow-symlink behavior as defined).
- **`HardLinkError`** (`error set`): Failures creating a hard link (cross-device, exists, permission, read-only, etc.).
- **`hardLink(file, io, dir, sub_path, options)`** (`fn`): Creates a directory entry `sub_path` in `dir` referring to this open file’s inode (link-by-handle semantics where supported).
- **`createMemoryMap(file, io, options)`** (`fn`): Creates a `File.MemoryMap` over the file (offset/length/protection/populate per options), returning a mapping object whose memory can be accessed directly and later destroyed/synced per `MemoryMap` API.

---

## 5. `std.Io.File.Reader` (`std/Io/File/Reader.zig`)

A stateful, buffered reader that implements `Io.Reader` semantics for an `Io.File`. It memoizes size, seek state, errors, and I/O mode to choose efficient/compatible syscalls.

**Fields:** `io`, `file`, `err` (sticky read error), `mode`, `pos` (true file cursor/offset), `size`/`size_err` (cached), `seek_err`, `interface: Io.Reader` (embedded generic reader state/buffer).

### 5.1 Types
- **`Error`** (`const error set`): `Io.Operation.FileReadStreaming.UnendingError || Io.Cancelable` — read failures surfaced through the interface.
- **`SizeError`** (`const error set`): `File.StatError || error{Streaming}` — `Streaming` means the handle has no meaningful size (e.g. socket/pipe).
- **`SeekError`** (`const error set`): `File.SeekError || error{EndOfStream, ReadFailed}` — seeking may fall back to reading forward; can hit EOF before target or fail reading.
- **`Mode`** (`const enum`): Controls access strategy:
  - `.positional`: uses positional reads (pread/preadv) at `pos`, preserving thread safety w.r.t. shared cursor; tries fast `sendFile` paths.
  - `.streaming`: uses streaming reads and OS cursor; seeks by `seekTo/By` syscalls or fallback discard.
  - `.positional_simple` / `.streaming_simple`: like above but avoid fd-to-fd fast paths (force plain read/readv/pread).
  - `.failure`: terminal mode after an unrecoverable seek/read setup failure.
  - `toStreaming()` / `toSimple()`: mode transitions on fallbacks (e.g. `Unseekable` or `Unimplemented` sendfile).

### 5.2 Initialization
- **`initInterface(buffer)`** (`fn`): Builds an `Io.Reader` with vtable `{ .stream, .discard, .readVec }` wired to this file reader implementation, using `buffer` for buffering.
- **`init(file, io, buffer)`** (`fn`): Creates a reader defaulting to positional-capable mode with lazy size/error discovery.
- **`initSize(file, io, buffer, size)`** (`fn`): Same but pre-seeds known `size` to avoid an initial stat.
- **`initStreaming(file, io, buffer)`** (`fn`): Initializes directly in streaming mode, pre-marking seek/size as streaming-unavailable to skip positional probes (for pipes/sockets).

### 5.3 Size and position
- **`getSize(r)`** (`fn`): Returns cached `size` or stats the file. If not a regular file, switches toward streaming semantics and caches `error.Streaming`; caches other stat errors. Needed for `sendFile` sizing/limits and EOF logic.
- **`seekBy(r, offset)`** (`fn`): Adjusts logical position by `offset`. Positional modes update logical offset (`pos`) relative to buffered data; streaming modes try `fileSeekBy` and on failure/unseekable fall back to discarding forward bytes (can be slow and may hit EOF).
- **`seekTo(r, offset)`** (`fn`): Sets absolute logical position. In streaming mode, forward seeks may delegate to `seekBy`; backward seeks require a real `fileSeekTo` (and fail if unseekable).
- **`logicalPos(r)`** (`fn`): Returns logical read position = `pos - interface.bufferedLen()` (accounts for bytes already buffered but not consumed).
- **`setLogicalPos(r, offset)`** (`fn`, internal but important): Repositions by tossing buffered bytes if target is within `[logicalPos, pos)`, else resets buffer and sets `pos` to target.

### 5.4 I/O behavior (vtable-driven)
- **`streamMode(r, w, limit, mode)`** (`fn`): Core transfer logic per mode: in non-simple modes attempts `w.sendFile(r, limit)` for zero-copy/fast kernel paths and downgrades to simple on `error.Unimplemented`; in simple modes reads into writable slices of `w` via positional or streaming vectored reads. `failure` yields `ReadFailed`.
- **`stream` / `readVec` / `discard`** (wired via `initInterface`): Implement `Io.Reader` vtable by delegating to positional/streaming vector reads, handling fallbacks (e.g. `Unseekable` -> switch to streaming and retry logic), updating `pos` by bytes consumed, and recording sticky `err/seek_err`.
- **`atEnd(r)`** (`fn`): Reports whether the reader is at end of file (based on known size/position and buffered state as implemented).

**Usage:** create via `file.reader(io, buf)` or `readerStreaming`, then operate on `reader.interface` (`streamRemaining`, `take*`, `peek*`, etc.) or on helper methods (`seekTo`, `getSize`, `logicalPos`).

## 6. `std.Io.File.Writer` (`std/Io/File/Writer.zig`)

A stateful, buffered writer implementing `Io.Writer` for an `Io.File`, tracking position/mode/errors and supporting flush/seek/end.

**Fields:** `io`, `file`, `err`, `mode`, `pos`, `write_file_err` (details from send-file failures), `seek_err`, `interface: Io.Writer`.

### 6.1 Types
- **`Mode`** (`const`): Alias of `File.Reader.Mode` with same positional/streaming/simple/failure semantics for writes.
- **`Error`** (`const error set`): `Io.Operation.FileWriteStreaming.Error || Io.Cancelable` — generic write failure cause category.
- **`WriteFileError`** (`const error set`): Extended errors for file-to-file transfers: adds `Unimplemented`, `CorruptedData` (e.g. FreeBSD copy_file_range cases), `EndOfStream`, `ReadFailed` to `Error`.
- **`SeekError`** (`const`): Alias of `Io.File.SeekError`.

### 6.2 Initialization and conversion
- **`init(file, io, buffer)`** (`fn`): Buffered writer in positional mode.
- **`initStreaming(file, io, buffer)`** (`fn`): Buffered writer in streaming mode.
- **`initDetect(file, io, buffer)`** (`fn`): Detects if file is a TTY (cancelable) and chooses an appropriate initial mode/behavior before returning writer.
- **`initInterface(buffer)`** (`fn`): Builds `Io.Writer` vtable with `drain` and `sendFile` wired to this implementation.
- **`moveToReader(w)`** (`fn`): Consumes the writer (sets `undefined`) and returns a `File.Reader` over the same file reusing `interface.buffer`, carrying over `pos/mode/seek_err`. Useful to switch from writing to reading without reallocating buffers; caller must ensure buffered write data is flushed/consistent as required before moving.

### 6.3 Draining and sending
- **`drain(io_w, data, splat)`** (`fn`): Vtable entry; dispatches to positional or streaming drain based on `mode`.
- **`drainPositional` / `drainStreaming`** (internal): Write `interface.buffered()` plus vectored `data/splat` via `fileWritePositional` or streaming write. On `Unseekable` in positional mode, fall back to streaming (seeking to `pos` if needed). On failure record `err` and return `WriteFailed`; on success advance `pos` and `consume` buffered bytes.
- **`sendFile(io_w, file_reader, limit)`** (`fn`): Vtable entry; dispatches to positional/streaming send-file or returns `Unimplemented` in simple modes, `WriteFailed` in failure mode.
- **`sendFilePositional` / `sendFileStreaming`** (internal): Use `vtable.fileWriteFilePositional/Streaming` to transfer data (optionally consuming buffered header). Handle fallbacks (`Unseekable`), map cancel/read/EOF/unimplemented distinctly, store detailed errors in `write_file_err` or `err`, advance `pos` and consume.

### 6.4 Positioning and finalization
- **`seekTo(w, offset)`** (`fn`): Flushes buffered data then calls `seekToUnbuffered` to reposition logical/physical write position.
- **`logicalPos(w)`** (`fn`): `pos + interface.end` (physical position plus buffered-not-yet-flushed bytes).
- **`seekToUnbuffered(w, offset)`** (`fn`): Asserts buffer empty; in positional modes sets `pos` directly, in streaming modes issues `fileSeekTo` (caching `seek_err` on failure).
- **`EndError`** (`const error set`): `File.SetLengthError || Io.Writer.Error`.
- **`end(w)`** (`fn`): Flushes buffered data and, for positional modes, sets file length to current `pos` (truncate/extend to finalize size). Treats `NonResizable` as no-op. Use when producing a file of known final length.
- **`flush(w)`** (`fn`): Flushes `interface` and, on `WriteFailed`, returns the stored underlying `err` for precise diagnostics.

---

## 7. `std.Io.Dir` (`std/Io/Dir.zig`)

`Dir` represents an open directory handle (`handle: Handle`) and provides path-based filesystem operations relative to that directory (or absolute variants). Most methods take `(dir, io, ...)` and dispatch through `io.vtable.dir*`/file ops.

### 7.1 Handles, path limits, and entries
- **`Handle`** (`const`): OS directory descriptor (`std.posix.fd_t`).
- **`path`** (`const`): Alias to `std.fs.path` utilities (join, basename, separators, etc.).
- **`max_path_bytes`** (`const`): Maximum path byte length the OS accepts (includes null sentinel). Encoding notes: WTF-8 on Windows, UTF-8 on WASI, opaque bytes elsewhere. Derived per-platform (`PATH_MAX`, Windows widened accounting). Paths may be longer in memory but not passable to OS calls.
- **`max_name_bytes`** (`const`): Maximum size of a single path component/name on common filesystems (platform-specific; excludes null). Important for sizing directory iteration buffers.
- **`Entry`** (`const struct`): A directory entry: `name: []const u8`, `kind: File.Kind`, `inode: File.INode`.
- **`cwd()`** (`fn`): Returns a `Dir` for the process current working directory. Not iterable as a freshly guaranteed cursor in all cases, not closeable in the checked-illegal sense per docs; comptime-callable on POSIX. Overridable via `std.Options.cwd` (e.g. for WASI/custom environments).

### 7.2 Directory iteration (`Reader`, `Iterator`, walkers)
- **`Reader`** (`const struct`): Low-level buffered directory reader.
  - Fields: `dir`, `state` (`reset`/`reading`/`finished`), implementation `buffer`, `index`, `end`.
  - **`min_buffer_len`** (`const`): Minimum buffer size required across platforms (accounts for dirent structures + max name, alignment).
  - **`State`** (`enum`): Iteration state; `.reset` means rewind before next read.
  - **`Error`** (`error set`): `AccessDenied`, `PermissionDenied`, `SystemResources`, plus `UnexpectedError`/`Cancelable`.
  - **`init(dir, buffer)`** (`fn`): Initializes with caller-provided aligned buffer (must be >= `min_buffer_len`).
  - **`read(r, io, buffer)`** (`fn`): Fills `buffer` with entries via `vtable.dirRead`, returning count. Entry names are invalidated on next `read/next`.
  - **`next(r, io)`** (`fn`): Returns next single `Entry` or `null` at end.
  - **`reset(r)`** (`fn`): Rewinds iteration to start.
- **`Iterator`** (`const struct`): Higher-level, movable convenience iterator.
  - Owns a fixed `reader_buffer` (>= `min_buffer_len`) and an embedded `Reader`; fetches entries one-by-one through the `Io` interface.
  - **`reader_buffer_len`** / **`Error`**: Buffer size constant and alias of `Reader.Error`.
  - **`init(dir, reader_state)`** (`fn`): Constructs iterator starting in given state.
  - **`next(it, io)`** (`fn`): Binds internal buffer and returns next entry.
- **`iterate(dir)`** (`fn`): Returns an `Iterator` starting at `.reset` (rewinds before first read).
- **`iterateAssumeFirstIteration(dir)`** (`fn`): Returns an `Iterator` starting at `.reading` (skips rewind) — only safe if cursor is known fresh/unmodified.
- **`SelectiveWalker`** (`const struct`): Stack-based recursive traversal that allows selective descent/pruning.
  - Tracks `stack` of `(Iterator, dirname_len)` and a growable `name_buffer` for current path; uses `allocator`.
  - **`Error`**: `Iterator.Error || Allocator.Error`.
  - **`next`**: Yields next `Walker.Entry` (path/kind/etc.), pushing/popping directories; on iteration error it pops the failing directory (closing it if not root) so walking can continue. Returned path memory is invalidated on next call/deinit — copy if needed.
  - (Associated helpers in source manage opening child dirs, path joining, and deinit.)
- **`walkSelectively(dir, allocator)`** (`fn`): Creates a `SelectiveWalker` rooted at `dir`.
- **`Walker`** (`const struct`): Convenience recursive walker (full traversal) built atop iteration/stack management; yields entries with relative paths. **`Error`** as defined.
- **`walk(dir, allocator)`** (`fn`): Creates a `Walker` for recursive traversal.

### 7.3 Path and access checks
- **`PathNameError`** (`error set`): Invalid/unsupported path name issues (e.g. bad UTF/WTF-8 on platforms, empty/invalid components, name too long) surfaced before/alongside syscalls.
- **`AccessError`** (`error set`): Errors from access/existence/permission probes (not found, permission denied, etc.).
- **`AccessOptions`** (`packed struct`): Flags controlling which access aspects to check (exist/read/write/execute semantics as defined per platform).
- **`access(dir, io, sub_path, options)`** (`fn`): Checks accessibility of `sub_path` relative to `dir` without opening it (TOCTOU caveat inherent to path checks).
- **`accessAbsolute(io, absolute_path, options)`** (`fn`): Absolute-path variant.

### 7.4 Opening and closing directories
- **`OpenError`** (`error set`): Failures opening a directory handle (not found, not a dir, permission, symlink loop, etc.).
- **`OpenOptions`** (`const struct`): Options such as whether to follow symlinks, request iteration capability, etc.
- **`openDir(dir, io, sub_path, options)`** (`fn`): Opens `sub_path` relative to `dir` as a `Dir`.
- **`openDirAbsolute(io, absolute_path, options)`** (`fn`): Opens by absolute path.
- **`close(dir, io)`** (`fn`): Closes a directory handle.
- **`closeMany(io, dirs)`** (`fn`): Closes multiple directory handles.

### 7.5 Opening and creating files
- **`OpenFileOptions`** (`const struct`): File open mode/flags: read/write/append, create/truncate/exclusive behaviors, locking hints, nonblocking, allow directory, permissions on create, follow symlinks, etc. (as defined by Zig 0.17 `Dir` API).
- **`openFile(dir, io, sub_path, options)`** (`fn`): Opens an existing or conditionally created file relative to `dir`, returning `Io.File`.
- **`openFileAbsolute(io, absolute_path, options)`** (`fn`): Absolute variant.
- **`CreateFileOptions`** (`const struct`): Options for `createFile` (commonly includes `.truncate`, `.read`, `.exclusive`, permissions/mode). Controls overwrite vs fail-if-exists and initial length.
- **`createFile(dir, io, sub_path, flags)`** (`fn`): Creates/opens a file for writing per flags (typically truncating by default when requested).
- **`createFileAbsolute(io, absolute_path, flags)`** (`fn`): Absolute variant.

### 7.6 Convenience whole-file operations
- **`WriteFileOptions`** (`const struct`): Parameters for writing data to a path (sub_path, data, flags).
- **`WriteFileError`** (`error set`): `File.Writer.Error || File.OpenError`.
- **`writeFile(dir, io, options)`** (`fn`): High-level helper: open/create, write contents, close/flush as needed.
- **`PrevStatus`** (`enum`): Used by update operations to indicate previous state (e.g. existed vs newly created).
- **`UpdateFileError`** (`error set`): `File.OpenError` (and related) for atomic/update flows.
- **`updateFile(...)`** (`fn`): Safely/atomically updates a file’s contents (pattern often: write temp then rename), returning status/details as defined.
- **`ReadFileError`** (`error set`): `File.OpenError || File.Reader.Error`.
- **`readFile(dir, io, file_path, buffer)`** (`fn`): Opens and reads file contents into provided `buffer`, returning the filled slice (bounded by buffer).
- **`ReadFileAllocError`** (`error set`): `File.OpenError || File.Reader.Error || Allocator.Error || error{StreamTooLong}`.
- **`readFileAlloc(dir, io, file_path, allocator, max_bytes)`** (`fn`): Reads entire file into an allocated buffer up to `max_bytes`.
- **`readFileAllocOptions(...)`** (`fn`): Variant with additional allocation/limit options.

### 7.7 Directory creation
- **`CreateDirError`** (`error set`): `PathAlreadyExists`, `NotDir`, `AccessDenied`, `PermissionDenied`, `NoSpaceLeft`, `ReadOnlyFileSystem`, `SymLinkLoop`, `SystemResources`, name errors, etc.
- **`createDir(dir, io, sub_path, permissions)`** (`fn`): Creates a single directory entry (fails if exists, unless specified otherwise by impl contract).
- **`createDirAbsolute(io, absolute_path, permissions)`** (`fn`): Absolute variant.
- **`CreateDirPathError`** (`error set`): `CreateDirError || StatFileError` for recursive/path creation.
- **`createDirPath(dir, io, sub_path)`** (`fn`): Ensures all components exist (like `mkdir -p`).
- **`CreatePathStatus`** (`enum`): `.existed` or `.created` result for path-making operations.
- **`createDirPathStatus(dir, io, sub_path, permissions)`** (`fn`): Like `createDirPath` but reports whether it created or found existing.
- **`CreateDirPathOpenError`** (`error set`): Errors from create-path-and-open.
- **`CreateDirPathOpenOptions`** (`const struct`): Options including open/permission flags.
- **`createDirPathOpen(dir, io, sub_path, options)`** (`fn`): Creates intermediate directories as needed and opens the final directory, returning its `Dir` handle.

### 7.8 Stat and real paths
- **`Stat` / `StatError`** (`const`): Aliases to `File.Stat` / `File.StatError`.
- **`stat(dir, io)`** (`fn`): Stats the directory handle itself.
- **`StatFileError`** (`error set`): `File.OpenError || File.StatError`.
- **`StatFileOptions`** (`const struct`): e.g. follow symlinks.
- **`statFile(dir, io, sub_path, options)`** (`fn`): Stats a filesystem object at `sub_path` relative to `dir`.
- **`RealPathError`** (`const`): Alias to `File.RealPathError`.
- **`realPath(dir, io, out_buffer)`** (`fn`): Canonical path of directory handle.
- **`RealPathFileError`** (`error set`): `RealPathError || PathNameError`.
- **`realPathFile(dir, io, sub_path, out_buffer)`** (`fn`): Resolves canonical path of `sub_path` relative to `dir`.
- **`RealPathFileAllocError`** (`error set`): Adds `Allocator.Error`.
- **`realPathFileAlloc(dir, io, sub_path, allocator)`** (`fn`): Allocates and returns canonical path (often sentinel-terminated).
- **`realPathFileAbsolute(io, absolute_path, out_buffer)`** (`fn`): Absolute variant.
- **`realPathFileAbsoluteAlloc(io, absolute_path, allocator)`** (`fn`): Allocating absolute variant.

### 7.9 Deletion and rename
- **`DeleteFileError`** (`error set`): Not found, is-dir, permission, busy, read-only, etc.
- **`deleteFile(dir, io, sub_path)`** (`fn`): Unlinks/removes a file.
- **`deleteFileAbsolute(io, absolute_path)`** (`fn`): Absolute variant.
- **`DeleteDirError`** (`error set`): Not found, not empty, not dir, permission, busy, etc.
- **`deleteDir(dir, io, sub_path)`** (`fn`): Removes an empty directory.
- **`deleteDirAbsolute(io, absolute_path)`** (`fn`): Absolute variant.
- **`RenameError`** (`error set`): Cross-device, not found, permission, exists/not-empty target constraints, busy, etc.
- **`rename(old_dir, old_sub_path, new_dir, new_sub_path, io)`** (`fn`): Renames/moves within or across directories (same filesystem constraints apply).
- **`renameAbsolute(old_path, new_path, io)`** (`fn`): Absolute rename.
- **`RenamePreserveError`** (`error set`): Errors for rename variant that preserves certain attributes/atomicity guarantees as specified.
- **`renamePreserve(...)`** (`fn`): Rename with stronger preservation semantics.

### 7.10 Links and symlinks
- **`HardLinkOptions`** (`const`): Alias to `File.HardLinkOptions`.
- **`HardLinkError`** (`const`): Alias to `File.HardLinkError`.
- **`hardLink(old_dir, old_sub_path, new_dir, new_sub_path, options, io)`** (`fn`): Creates a hard link at new path pointing to old path’s target (path-based).
- **`SymLinkFlags`** (`const struct`): Flags (e.g. directory symlink hint on Windows).
- **`SymLinkError`** (`error set`): Exists, permission, not supported, no space, read-only, etc.
- **`symLink(dir, target_path, sym_link_path, flags, io)`** (`fn`): Creates symbolic link `sym_link_path` pointing to `target_path`.
- **`symLinkAbsolute(target_path, sym_link_path, flags, io)`** (`fn`): Absolute variant.
- **`symLinkAtomic(...)`** (`fn`): Creates/replaces symlink atomically (temp+rename pattern) where supported.
- **`ReadLinkError`** (`error set`): Not a symlink, not found, permission, name too long, etc.
- **`readLink(dir, io, sub_path, buffer)`** (`fn`): Reads symlink target into `buffer`, returns slice of bytes written.
- **`readLinkAbsolute(io, absolute_path, buffer)`** (`fn`): Absolute variant.

### 7.11 Copying and tree operations
- **`CopyFileOptions`** (`const struct`): Options for file copy (e.g. override mode, permissions handling).
- **`CopyFileError`** (`error set`): Union of open/stat/read/write/create errors possible during copy.
- **`copyFile(source_dir, source_path, dest_dir, dest_path, io, options)`** (`fn`): Copies file contents (and metadata as specified) between paths/dirs.
- **`copyFileAbsolute(source_path, dest_path, io, options)`** (`fn`): Absolute variant.
- **`CreateFileAtomicOptions`** (`const struct`): Options for atomic create (temp naming, permissions, make path, etc.).
- **`CreateFileAtomicError`** (`error set`): Errors from atomic create/replace flows.
- **`createFileAtomic(dir, io, sub_path, options)`** (`fn`): Creates a file atomically (typically by writing to a temp file in same dir then renaming into place) returning `File.Atomic`/handle as defined.
- **`DeleteTreeError`** (`error set`): Aggregated errors from recursive deletion (permission, busy, not found races, etc.).
- **`deleteTree(dir, io, sub_path)`** (`fn`): Recursively deletes a directory tree rooted at `sub_path`.
- **`deleteTreeMinStackSize(dir, io, sub_path)`** (`fn`): Variant tuned for constrained stack environments (iterative/minimal recursion strategy).

### 7.12 Permissions, ownership, timestamps (path-based)
- **`SetPermissionsError` / `Permissions`** (`const`): Aliases to `File` types.
- **`setPermissions(dir, io, new_permissions)`** (`fn`): Sets permissions on the directory handle itself.
- **`SetFilePermissionsError`** (`error set`): `PathNameError || SetPermissionsError || ...`.
- **`SetFilePermissionsOptions`** (`const struct`): e.g. follow symlinks.
- **`setFilePermissions(dir, io, sub_path, permissions, options)`** (`fn`): chmod by path relative to dir.
- **`SetOwnerError`** (`const`): Alias to `File.SetOwnerError`.
- **`setOwner(dir, io, owner, group)`** (`fn`): chown on directory handle.
- **`SetFileOwnerError`** (`error set`): Path-based owner change errors.
- **`SetFileOwnerOptions`** (`const struct`): Follow-symlink behavior, etc.
- **`setFileOwner(dir, io, sub_path, owner, group, options)`** (`fn`): chown by path.
- **`SetTimestampsError`** (`error set`): `File.SetTimestampsError || PathNameError`.
- **`SetTimestampsOptions`** (`const struct`): Path-based timestamp options (atime/mtime as `SetTimestamp`, symlink handling).
- **`setTimestamps(dir, io, sub_path, options)`** (`fn`): Sets timestamps on a path.
- **`SetTimestampsNowOptions`** (`const struct`): Options for “set to now”.
- **`setTimestampsNow(dir, io, sub_path, options)`** (`fn`): Convenience to update timestamps to current time.

---

## 8. Cross-cutting notes (how APIs fit together)

- **Capability passing:** Most filesystem calls require both a handle/dir/file and `io: Io`; the `io` selects backend behavior (threaded vs evented, async/cancel, OS integration).
- **Buffered vs unbuffered:** `File.reader/writer` give buffered `Io.Reader/Writer` interfaces (with `interface` field) for ergonomic streaming; `readPositional/writePositional/writeStreaming*` are lower-level handle calls.
- **Always flush writers:** `File.Writer` and adapters like `Writer.Hashing` buffer data; call `flush()` (and for file writers `end()` if setting final length) before relying on persistence or on derived results (hashes, counts of drained-only paths except helpers like `Discarding.fullCount`).
- **Composability:** Any `Reader` can pump to any `Writer` (`streamRemaining`, `streamExact`), enabling pipelines (file→hasher, file→file, fixed→allocating, reader→discarding).
- **Errors are intentionally coarse at interfaces:** `ReadFailed`/`WriteFailed` hide platform detail at the generic layer; concrete types (e.g. `File.Reader.err`, `File.Writer.err/write_file_err`) retain specifics.
- **Modes and fallbacks:** `File.Reader/Writer` transparently adapt between positional/streaming and fast/slow paths (`Unseekable`, `Unimplemented` sendfile) to work across regular files, pipes, and sockets.

Sources: Zig 0.17 stdlib (`std/Io.zig`, `std/Io/Reader.zig`, `std/Io/Writer.zig`, `std/Io/File.zig`, `std/Io/File/Reader.zig`, `std/Io/File/Writer.zig`, `std/Io/Dir.zig`) and local workspace examples (`IO.zig`, `hash_file.zig`, `hash_file_mmap.zig`).
