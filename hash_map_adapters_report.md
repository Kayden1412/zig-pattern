# Hash Map Adapters in Zig's Standard Library

**Investigated version:** Zig `0.17.0`  
**Standard library location:** `/data/data/com.termux/files/usr/lib/zig/lib/std`  
**Relevant sources:** `std/hash_map.zig`, `std/array_hash_map.zig`  
**Method:** `zig env` to locate `std_dir`, then ripgrep for `*Adapted` methods and `Adapter` declarations across `lib/std` and the compiler sources under `lib/compiler`.

---

## 1. Executive summary

Zig's standard library has two distinct things that can be called a "hash map adapter":

1. **The managed/unmanaged wrapper adapter**  
   `std.HashMap` is a thin managed wrapper around `std.HashMapUnmanaged`. It adds an `Allocator` and a stored `Context`, and forwards operations to the unmanaged implementation.

2. **Lookup adapters via `*Adapted` methods**  
   Both `HashMap`/`HashMapUnmanaged` and `ArrayHashMap` provide *adapted* variants of lookup, insertion, and removal operations. These accept a **pseudo-key** plus an ad-hoc context object that knows how to hash/compare that pseudo-key against the map's real key type.

The second meaning is the interesting one in actual std usage. Across `lib/std` and `lib/compiler` there are **50 adapted call sites outside the map implementation files**, of which **34 are in `std/zig/llvm/Builder.zig`**. They are used for:

- string interning and lookup by borrowed `[]const u8`;
- looking up maps keyed by integer indices using the logical key (e.g. symbol name, address, module ID);
- composite/borrowed keys without constructing an owned key;
- projection keys where the stored key is rich but lookup only needs one field;
- bulk structural deduplication in the LLVM IR builder.

The most important semantic rules are:

- The adapter's `hash` must agree with the map's canonical `Context.hash` for equivalent keys.
- `eql(adapted_key, stored_key)` receives the borrowed key first and the stored key second.
- On a new insertion, `getOrPutAdapted`/`getOrPutAssumeCapacityAdapted` **leave `key_ptr` undefined**; the caller must write the canonical key.
- Adapted lookups are allocation-free; `getOrPutAdapted` may allocate because it can grow the map.
- There is no `putAdapted`, `fetchPutAdapted`, or `getOrPutValueAdapted`. Insertion-by-adapted-key is done with `getOrPutAdapted` plus manual key initialization.

---

## 2. Adapter vs. Context

A hash map is parameterized by a `Context` type:

```zig
std.HashMap(K, V, Context, max_load_percentage)
std.HashMapUnmanaged(K, V, Context, max_load_percentage)
std.array_hash_map.Custom(K, V, Context, store_hash)
```

`Context` must provide:

```zig
// HashMap
fn hash(ctx: Context, key: K) u64
fn eql(ctx: Context, a: K, b: K) bool

// ArrayHashMap
fn hash(ctx: Context, key: K) u32
fn eql(ctx: Context, a: K, b: K, b_index: usize) bool
```

An **adapter** is just another type, usually a small struct, that provides the same functions but for a different key type:

```zig
// HashMap adapter
fn hash(ctx: Adapter, key: AdaptedKey) u64
fn eql(ctx: Adapter, key: AdaptedKey, stored_key: K) bool

// ArrayHashMap adapter
fn hash(ctx: Adapter, key: AdaptedKey) u32
fn eql(ctx: Adapter, key: AdaptedKey, stored_key: K, stored_index: usize) bool
```

The adapter is passed as a runtime argument to an `*Adapted` function. The map's `Context` remains the type parameter used for the real stored keys.

Std provides several ready-made contexts:

- `std.hash_map.AutoContext(K)` / `std.array_hash_map.AutoContext(K)` use `std.hash.autoHash` and `std.meta.eql`.
- `std.hash_map.StringContext` and `std.array_hash_map.StringContext` hash and compare `[]const u8` by contents.
- `std.hash_map.StringIndexContext` treats `u32` offsets into a byte buffer as keys, hashing the referenced NUL-terminated string.
- `std.hash_map.getAutoHashFn` / `std.hash_map.getAutoEqlFn` (and the `std.array_hash_map` equivalents) produce the functions used by `AutoContext` and can be reused in custom contexts.

The main ready-made *lookup adapter* is `std.hash_map.StringIndexAdapter`, which pairs with `StringIndexContext`.

### Naming caveat

Not every std type named `Adapter` is a lookup adapter. For example:

- `std.Build.Cache.Path.TableAdapter` is used as the **map Context** (`std.array_hash_map.Custom(Path, ..., Path.TableAdapter, ...)`), not as a lookup adapter.
- `FileHandle.Adapter` in `lib/compiler/Maker/Watch.zig` is also a map Context.
- `std.hash_map.StringIndexAdapter` **is** a real lookup adapter, intended to be passed to `*Adapted` methods.

A quick check: if the type is the third type parameter to `HashMap`/`Custom`, it is the Context. If it is passed as a value to `getAdapted`, `getOrPutAdapted`, etc., it is a lookup adapter.

---

## 3. Adapted API surface

### 3.1 `HashMapUnmanaged`

From `std/hash_map.zig`:

```zig
pub fn getOrPutAdapted(self: *Self, allocator: Allocator, key: anytype, key_ctx: anytype) !GetOrPutResult
pub fn getOrPutContextAdapted(self: *Self, allocator: Allocator, key: anytype, key_ctx: anytype, ctx: Context) !GetOrPutResult
pub fn getOrPutAssumeCapacityAdapted(self: *Self, key: anytype, ctx: anytype) GetOrPutResult

pub fn getAdapted(self: Self, key: anytype, ctx: anytype) ?V
pub fn getPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*V
pub fn getKeyAdapted(self: Self, key: anytype, ctx: anytype) ?K
pub fn getKeyPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*K
pub fn getEntryAdapted(self: Self, key: anytype, ctx: anytype) ?Entry
pub fn containsAdapted(self: Self, key: anytype, ctx: anytype) bool
pub fn fetchRemoveAdapted(self: *Self, key: anytype, ctx: anytype) ?KV
pub fn removeAdapted(self: *Self, key: anytype, ctx: anytype) bool
```

`std.HashMap` exposes the same adapted methods but supplies its stored `self.ctx` as the real context, so it does not expose `getOrPutContextAdapted`.

### 3.2 `ArrayHashMap` (`std.array_hash_map.Custom`)

From `std/array_hash_map.zig`:

```zig
pub fn getOrPutAdapted(self: *Self, gpa: Allocator, key: anytype, key_ctx: anytype) !GetOrPutResult
pub fn getOrPutContextAdapted(self: *Self, gpa: Allocator, key: anytype, key_ctx: anytype, ctx: Context) !GetOrPutResult
pub fn getOrPutAssumeCapacityAdapted(self: *Self, key: anytype, ctx: anytype) GetOrPutResult

pub fn getAdapted(self: Self, key: anytype, ctx: anytype) ?V
pub fn getPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*V
pub fn getKeyAdapted(self: Self, key: anytype, ctx: anytype) ?K
pub fn getKeyPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*K
pub fn getEntryAdapted(self: Self, key: anytype, ctx: anytype) ?Entry
pub fn getIndexAdapted(self: Self, key: anytype, ctx: anytype) ?usize
pub fn containsAdapted(self: Self, key: anytype, ctx: anytype) bool

pub fn fetchSwapRemoveAdapted(self: *Self, key: anytype, ctx: anytype) ?KV
pub fn fetchOrderedRemoveAdapted(self: *Self, key: anytype, ctx: anytype) ?KV
pub fn swapRemoveAdapted(self: *Self, key: anytype, ctx: anytype) bool
pub fn orderedRemoveAdapted(self: *Self, key: anytype, ctx: anytype) bool
```

Array-map-specific details:

- `getIndexAdapted` returns the index into the `entries` array, not just a value/key pointer. This is useful as an integer handle.
- The adapter's `eql` receives `stored_index`, allowing it to resolve the stored key indirectly through a parallel array (used by `aro`'s `Interner`).
- Removal adapted variants that may need to re-index moved entries require the real `Context` when `store_hash == false` and the context is non-zero-sized. The short `*Adapted` forms compile-error in that case and direct you to the `*ContextAdapted` forms.

---

## 4. Rules and semantics that matter

1. **Adapter hashes must match the canonical hash.**
   - For `HashMap`, the real `Context.hash` is used when rehashing on growth, while the adapter hash is used to probe. If they disagree for equivalent keys, lookups fail.
   - For `ArrayHashMap`, the adapter hash is used for probing and, with `store_hash = true`, is stored per entry. Keep the function stable and consistent with the canonical context.
   - Hash widths differ: `HashMap` uses `u64`; `ArrayHashMap` uses `u32`.

2. **`eql` argument order is `(adapted_key, stored_key)`**, optionally followed by `stored_index` for array maps.

3. **`getOrPutAdapted` does not initialize the key.**
   - On `!found_existing`, `key_ptr` points to undefined storage. The caller must assign the canonical key.
   - For zero-sized keys such as `void`, assigning `{}` is harmless but not meaningful.
   - Forgetting this is undefined behavior, not a compile error.

4. **`getOrPutContextAdapted` needs two contexts.**
   - `key_ctx`: adapter for the borrowed key used during probing.
   - `ctx`: the map's real `Context`, used when growing/rehashing existing entries. The array-map `*ContextAdapted` removal variants also use it to re-index entries shifted by removal.
   - The managed `HashMap` wrapper hides this by supplying its stored context.

5. **Lookup is allocation-free; insertion may allocate.**
   - `getAdapted`, `getKeyAdapted`, `getIndexAdapted`, `containsAdapted`, etc. do not allocate.
   - `getOrPutAdapted` may grow the map before probing, so it can invalidate existing pointers even when the key already exists.
   - `getOrPutAssumeCapacityAdapted` does not allocate, but asserts capacity. Reserve first with `ensureUnusedCapacity`/`ensureTotalCapacity`.

6. **There is no `putAdapted`.**
   - Adapted insertion is `getOrPutAdapted` (or `getOrPutAssumeCapacityAdapted`) followed by writing `key_ptr` and `value_ptr`.
   - This is deliberate: the map must store the canonical key, not the temporary borrowed key.

7. **Adapter lifetime is only the duration of the call.**
   - The adapter may hold pointers/slices into external buffers.
   - Those buffers must remain valid and must not reallocate during the call.
   - If a buffer may grow, store a pointer to the container (e.g. `*std.ArrayList(u8)`) and recompute the slice inside the adapter rather than capturing a stale slice.

8. **Context requirements for the shorter forms.**
   - On `HashMapUnmanaged` and `ArrayHashMap` (which is always unmanaged), `getOrPutAdapted` compile-errors when `@sizeOf(Context) != 0`, directing you to `getOrPutContextAdapted`. The managed `std.HashMap` wrapper instead supplies its stored context, so its `getOrPutAdapted` has no such restriction.
   - The short array-map removal variants require `@sizeOf(ByIndexContext) == 0`, where `ByIndexContext` is `void` when `store_hash == true` and `Context` otherwise. With `store_hash == false` and a non-zero-sized context, use the `*ContextAdapted` removal variants.
   - Read-only `getAdapted` does not require the real context and works even when the context is non-zero-sized.

9. **Indices returned by `getIndexAdapted` are not stable across reordering.**
   - They are indices into `entries`. Insertion can reallocate, and `swapRemove`/`orderedRemove` can reorder or shift entries.
   - The std usages that rely on indices are grow-only maps where insertion order is preserved and entries are never removed.

10. **Void-keyed maps are adapter-only.**
    - With `K = void`, the stored key carries no information; only the adapter's hash and `eql` can distinguish entries.
    - `ArrayHashMap` must use `store_hash = true` for this (the `Auto` context does so for `void`) and the adapter uses the stored entry index to resolve the real key. `HashMap` cannot support this pattern because it does not pass the stored index to `eql`.
    - The ARO interner is the std example of this technique.

---

## 5. Use cases found in std

### 5.1 String interning with `StringIndexAdapter`

This is the canonical adapter use case and the only reusable lookup adapter exported by `std.hash_map`.

`StringIndexAdapter` (`std/hash_map.zig:105`) adapts a borrowed `[]const u8` to a map whose stored key is a `u32` offset into a byte buffer:

```zig
pub const StringIndexContext = struct {
    bytes: *const std.ArrayList(u8),

    pub fn eql(_: @This(), a: u32, b: u32) bool {
        return a == b;
    }

    pub fn hash(ctx: @This(), key: u32) u64 {
        return hashString(mem.sliceTo(ctx.bytes.items[key..], 0));
    }
};

pub const StringIndexAdapter = struct {
    bytes: *const std.ArrayList(u8),

    pub fn eql(ctx: @This(), a: []const u8, b: u32) bool {
        return mem.eql(u8, a, mem.sliceTo(ctx.bytes.items[b..], 0));
    }

    pub fn hash(_: @This(), adapted_key: []const u8) u64 {
        assert(mem.findScalar(u8, adapted_key, 0) == null);
        return hashString(adapted_key);
    }
};
```

The stored key is an offset; the adapter lets callers look up by borrowed string without allocating a temporary key. On a miss, the caller appends the string once, records its offset, and writes that offset into `key_ptr`.

**`AstGen.zig`** (`std/zig/AstGen.zig:11018`, `11046`):

```zig
const gop = try astgen.string_table.getOrPutContextAdapted(gpa, key, StringIndexAdapter{
    .bytes = string_bytes,
}, StringIndexContext{
    .bytes = string_bytes,
});
if (gop.found_existing) {
    string_bytes.shrinkRetainingCapacity(str_index);
    return @fromBackingInt(@intCast(gop.key_ptr.*));
} else {
    gop.key_ptr.* = str_index;
    try string_bytes.append(gpa, 0);
    return @fromBackingInt(@intCast(str_index));
}
```

`AstGen` appends the candidate identifier to `string_bytes` before lookup, then shrinks it back on a hit. This avoids allocating a separate lookup string and avoids copying the identifier twice. `ZonGen.zig` uses the same pattern at lines `585` and `605`.

**`resinator/source_mapping.zig:943`** wraps the same idea in a `StringTable`:

```zig
const result = try self.map.getOrPutContextAdapted(
    allocator,
    value,
    std.hash_map.StringIndexAdapter{ .bytes = &self.data },
    .{ .bytes = &self.data },
);
if (result.found_existing) return result.key_ptr.*;

try self.data.ensureUnusedCapacity(allocator, value.len + 1);
const offset: u32 = @intCast(self.data.items.len);
self.data.appendSliceAssumeCapacity(value);
self.data.appendAssumeCapacity(0);
result.key_ptr.* = offset;
```

**`std/Build/Configuration.zig:186`** uses an equivalent local `StringTableIndexAdapter` for the serialized build configuration string table.

**Why this pattern is useful:**
- Keys are compact `u32` offsets instead of slices.
- Lookup requires no allocation and no temporary owned string.
- Interning prevents duplicate strings from being stored: lookup is by content, a hit reuses the canonical offset, and a miss appends the string once.
- `getKeyAdapted` returns the stored offset, so the caller can recover the canonical interned key.

Deduplication here is not a cleanup pass over an existing buffer; it only applies to strings routed through the adapter. For example, `AstGen.strLitAsString` deliberately skips interning for string literals containing an embedded NUL and returns a raw slice into `string_bytes`, so duplicate embedded-NUL literals can still exist in the buffer.

The std test `test "getOrPutAdapted"` (`std/hash_map.zig:2018`) demonstrates the same shape with a numeric key: the map stores `u64`, while the adapter parses a borrowed decimal string to `u64`. The test explicitly writes `result.key_ptr.* = real_keys[i]` on each miss and then verifies `getKeyAdapted` returns the canonical `u64`.

**Pitfall:** the adapter asserts that the borrowed key contains no embedded NUL. Stored strings are NUL-terminated and compared with `mem.sliceTo`; an embedded NUL would make the prefix comparison ambiguous.

---

### 5.2 Borrowed lookup in a certificate bundle

`std/crypto/Certificate/Bundle.zig` stores certificates as DER slices and maps the subject name to a `u32` index:

```zig
map: std.HashMapUnmanaged(der.Element.Slice, u32, MapContext, default_max_load_percentage),
```

`MapContext` needs a pointer to the bundle and its byte buffer. `find` does a read-only lookup by a plain `[]const u8` using `getAdapted`:

```zig
pub fn find(cb: Bundle, subject_name: []const u8) ?u32 {
    const Adapter = struct {
        cb: Bundle,

        pub fn hash(ctx: @This(), k: []const u8) u64 {
            _ = ctx;
            return std.hash_map.hashString(k);
        }

        pub fn eql(ctx: @This(), a: []const u8, b_key: der.Element.Slice) bool {
            const b = ctx.cb.bytes.items[b_key.start..b_key.end];
            return mem.eql(u8, a, b);
        }
    };
    return cb.map.getAdapted(subject_name, Adapter{ .cb = cb });
}
```

This is a good example of `getAdapted` bypassing a non-zero-sized map context: the adapter carries everything needed for the lookup, so no temporary `der.Element.Slice` or `MapContext` is required.

---

### 5.3 Index-keyed maps with indirect resolution

Several std components store map keys as compact integer indices and use the adapter to expose the *logical* key.

#### Mach-O symbols: `std/debug/MachOFile.zig`

```zig
symbols_by_name: std.array_hash_map.Custom(u32, void, void, true),
```

The real key is the index into `symtab_raw`; the logical key is the symbol name. The adapter resolves the stored index through `strtab`/`symtab_raw`:

```zig
const SymbolAdapter = struct {
    strtab: []const u8,
    symtab_raw: []align(1) const macho.nlist_64,

    pub fn hash(ctx: SymbolAdapter, sym_name: []const u8) u32 {
        _ = ctx;
        return @truncate(std.hash.Wyhash.hash(0, sym_name));
    }

    pub fn eql(ctx: SymbolAdapter, a_sym_name: []const u8, b_sym_index: u32, b_index: usize) bool {
        _ = b_index;
        var b_sym = ctx.symtab_raw[b_sym_index];
        if (builtin.cpu.arch.endian() != .little) std.mem.byteSwapAllFields(macho.nlist_64, &b_sym);
        const b_sym_name = std.mem.sliceTo(ctx.strtab[b_sym.n_strx..], 0);
        return mem.eql(u8, a_sym_name, b_sym_name);
    }
};
```

Insertion uses `getOrPutAssumeCapacityAdapted` after reserving capacity, and explicitly writes the canonical index:

```zig
const gop = symbols_by_name.getOrPutAssumeCapacityAdapted(
    @as([]const u8, sym_name),
    @as(OFile.SymbolAdapter, .{ .strtab = strtab, .symtab_raw = symtab_raw }),
);
if (gop.found_existing) return error.InvalidMachO;
gop.key_ptr.* = @intCast(sym_index);
```

Lookup uses `getKeyAdapted` to return the symbol table index.

#### ARO interner: `lib/compiler/aro/backend/Interner.zig`

This is the most unusual adapter. The map has `void` keys and `void` values:

```zig
map: std.AutoArrayHashMapUnmanaged(void, void) = .empty,
```

The adapter uses the stored entry index (`b_map_index`) to retrieve the actual interned item and compare it against the candidate `Key`:

```zig
const KeyAdapter = struct {
    interner: *const Interner,

    pub fn eql(adapter: KeyAdapter, a: Key, b_void: void, b_map_index: usize) bool {
        _ = b_void;
        return adapter.interner.get(@as(Ref, @fromBackingInt(@intCast(b_map_index)))).eql(a);
    }

    pub fn hash(adapter: KeyAdapter, a: Key) u32 {
        _ = adapter;
        return a.hash();
    }
};
```

`put` then uses `gop.index` as the interned `Ref`:

```zig
const adapter: KeyAdapter = .{ .interner = i };
const gop = try i.map.getOrPutAdapted(gpa, key, adapter);
if (gop.found_existing) return @fromBackingInt(@intCast(gop.index));
// ... append to i.items ...
return @fromBackingInt(@intCast(gop.index));
```

This works because `AutoArrayHashMapUnmanaged(void, void)` uses `store_hash = true` (void equality is not considered "cheap"), so each entry's hash is stored. The adapter's `hash(Key)` distinguishes entries even though the stored key type has only one value. Stored keys are never compared directly; the adapter uses `b_index` to reach the real interned data. This pattern is only possible with `ArrayHashMap`, because `HashMap` does not pass the stored index to `eql`.

#### Mach-O modules: `std/debug/SelfInfo/MachO.zig`

The map is keyed by a full `Module` struct, but lookup is by `text_base: usize`:

```zig
modules: std.array_hash_map.Custom(Module, void, Module.Context, false),
```

```zig
const Adapter = struct {
    pub fn hash(_: Adapter, text_base: usize) u32 {
        return @truncate(std.hash.int(text_base));
    }
    pub fn eql(_: Adapter, a_text_base: usize, b_module: Module, b_index: usize) bool {
        _ = b_index;
        return a_text_base == b_module.text_base;
    }
};
```

This avoids constructing a dummy `Module` containing error unions and optional file handles just to perform a lookup.

---

### 5.4 Composite borrowed keys

`std/debug/Coverage.zig` interns directory and file names into a string buffer while using `ArrayHashMap` keys that contain interned string handles:

```zig
directories: std.array_hash_map.Custom(String, void, String.MapContext, false),
files: std.array_hash_map.Custom(File, void, File.MapContext, false),
```

For lookup, it uses borrowed keys:

- `String.SliceAdapter` adapts `[]const u8` to an interned `String` handle.
- `File.SliceAdapter` adapts `{ directory_index, basename: []const u8 }` to a stored `File`.

```zig
const dir_gop = try cov.directories.getOrPutContextAdapted(gpa, dir_path, String.SliceAdapter{
    .string_bytes = cov.string_bytes.items,
}, String.MapContext{
    .string_bytes = cov.string_bytes.items,
});
if (!dir_gop.found_existing)
    dir_gop.key_ptr.* = addStringAssumeCapacity(cov, dir_path);

const file_gop = try cov.files.getOrPutContextAdapted(gpa, File.SliceAdapter.Entry{
    .directory_index = @intCast(dir_gop.index),
    .basename = file_entry.path,
}, File.SliceAdapter{
    .string_bytes = cov.string_bytes.items,
}, File.MapContext{
    .string_bytes = cov.string_bytes.items,
});
if (!file_gop.found_existing) file_gop.key_ptr.* = .{
    .directory_index = @intCast(dir_gop.index),
    .basename = addStringAssumeCapacity(cov, file_entry.path),
};
```

Two details are important:

- The code reserves `cov.string_bytes` capacity before the lookup, so the borrowed slices passed through the adapters cannot be invalidated by a reallocation during the operation.
- The adapter key for `files` is a composite struct, not just a string. It avoids constructing a full `File` (which contains interned handles and an enum) until the key is actually needed.

---

### 5.5 Projection keys: look up a rich object by a lightweight ID

`lib/compiler/Maker/Fetch.zig` stores `Fork` structs in a set, but looks them up by `Package.ProjectId`:

```zig
pub const ForkSet = std.array_hash_map.Custom(Fork, void, Fork.Context, false);

pub const Fork = struct {
    path: Path,
    manifest_ast: std.zig.Ast,
    manifest: Package.Manifest,
    uses: usize,

    pub const Context = struct {
        pub fn hash(_: @This(), a: Fork) u32 {
            const project_id: Package.ProjectId = .init(a.manifest.name, a.manifest.id);
            return @truncate(project_id.hash());
        }

        pub fn eql(_: @This(), a: Fork, b: Fork, _: usize) bool {
            const a_project_id: Package.ProjectId = .init(a.manifest.name, a.manifest.id);
            const b_project_id: Package.ProjectId = .init(b.manifest.name, b.manifest.id);
            return a_project_id.eql(&b_project_id);
        }
    };

    pub const Adapter = struct {
        pub fn hash(_: @This(), a: Package.ProjectId) u32 {
            return @truncate(a.hash());
        }

        pub fn eql(_: @This(), a_project_id: Package.ProjectId, b: Fork, _: usize) bool {
            const b_project_id: Package.ProjectId = .init(b.manifest.name, b.manifest.id);
            return a_project_id.eql(&b_project_id);
        }
    };
};
```

Lookup:

```zig
if (job_queue.fork_set.getKeyPtrAdapted(
    expected_project_id,
    @as(JobQueue.Fork.Adapter, .{}),
)) |fork| { ... }
```

The adapter projects the stored `Fork` down to its project ID. No temporary `Fork` (with AST, manifest, path) is constructed.

`lib/compiler/Maker/Step/Compile.zig` uses the same idea. `ModuleGraph` is keyed by a whole `ModuleList`, but lookup is by the root module index:

```zig
pub const ModuleGraph = std.array_hash_map.Custom(ModuleList, void, ModuleListContext, false);

const ModuleListContext = struct {
    pub fn eql(ctx: @This(), a: ModuleList, b: ModuleList) bool {
        _ = ctx;
        return a.keys()[0] == b.keys()[0];
    }

    pub fn hash(ctx: @This(), key: ModuleList) u32 {
        _ = ctx;
        return std.hash.int(@backingInt(key.keys()[0]));
    }

    const Adapter = struct {
        pub fn eql(ctx: @This(), a: Configuration.Module.Index, b: ModuleList, b_index: usize) bool {
            _ = ctx;
            _ = b_index;
            return a == b.keys()[0];
        }

        pub fn hash(ctx: @This(), key: Configuration.Module.Index) u32 {
            _ = ctx;
            return std.hash.int(@backingInt(key));
        }
    };
};
```

```zig
const gop = try module_graph.getOrPutAdapted(
    arena,
    root_module,
    @as(ModuleListContext.Adapter, .{}),
);
const modules = gop.key_ptr;
if (gop.found_existing) return modules;
modules.* = .empty;
try modules.putNoClobber(arena, root_module, .root);
```

Here the stored key is a `ModuleList` that is expensive to build; the adapter lets the map check whether that list is already present using only its first module index. On a miss, `key_ptr` is initialized with the full list.

**Notable observation:** `ModuleListContext.eql` above has the signature `eql(ctx, a, b)` and omits the `b_index` parameter that `ArrayHashMap`'s normal `Context` contract requires. It compiles because `ModuleGraph` is *only* accessed through `getOrPutAdapted`; Zig's lazy analysis never instantiates the non-conforming method. This is a reminder that adapted-only access can hide a broken canonical context until a non-adapted operation (such as `get`, `put`, or `remove`) is used.

---

### 5.6 Bulk structural deduplication in the LLVM builder

`std/zig/llvm/Builder.zig` accounts for 34 of the 50 adapted call sites and about 32 local `Adapter` declarations. The maps are keyed by small index wrapper types (e.g. `String`, `StrtabString`, `Type`, `Constant`, `Attribute`, `Metadata.String`) and the adapters accept the underlying structural data directly.

Representative example:

```zig
const Key = struct { ret: Type, params: []const Type };

const Adapter = struct {
    builder: *const Builder,

    pub fn hash(_: @This(), key: Key) u32 {
        var hasher = std.hash.Wyhash.init(comptime std.hash.int(@backingInt(tag)));
        hasher.update(std.mem.asBytes(&key.ret));
        hasher.update(std.mem.sliceAsBytes(key.params));
        return @truncate(hasher.final());
    }

    pub fn eql(ctx: @This(), lhs_key: Key, _: void, rhs_index: usize) bool {
        const rhs_data = ctx.builder.type_items.items[rhs_index];
        if (rhs_data.tag != tag) return false;
        var rhs_extra = ctx.builder.typeExtraDataTrail(Type.Function, rhs_data.data);
        const rhs_params = rhs_extra.trail.next(rhs_extra.data.params_len, Type, ctx.builder);
        return lhs_key.ret == rhs_extra.data.ret and
            std.mem.eql(Type, lhs_key.params, rhs_params);
    }
};

const gop = self.type_map.getOrPutAssumeCapacityAdapted(
    Key{ .ret = ret, .params = params },
    Adapter{ .builder = self },
);
if (!gop.found_existing) {
    gop.key_ptr.* = {};
    gop.value_ptr.* = {};
    self.type_items.appendAssumeCapacity(...);
    ...
}
return @fromBackingInt(@intCast(gop.index));
```

Common pattern in this file:

- Pre-reserve capacity for the map and all parallel arrays.
- Use `getOrPutAssumeCapacityAdapted` in hot paths; it cannot fail and cannot allocate.
- Hash with a tag seed so different structural key kinds do not collide.
- In `eql`, resolve the stored index through `builder`'s parallel arrays.
- On a miss, write `{}` to the void key and append the canonical data to the backing arrays.
- Use `gop.index` as the stable small integer handle returned to callers.
- Use `getIndexAdapted` for lookup-only paths such as `stringIfExists`/`strtabStringIfExists`.

This is essentially a "structural interning" layer: the adapter lets the builder probe by the structure it already has, without constructing the canonical index wrapper first.

---

### 5.7 The managed wrapper itself

`std.HashMap` is an adapter in the broader sense:

```zig
pub fn HashMap(K, V, Context, max_load_percentage) type {
    return struct {
        unmanaged: Unmanaged,
        allocator: Allocator,
        ctx: Context,
        ...
    };
}
```

It stores the allocator and context, then forwards every operation to `HashMapUnmanaged`. `std.AutoHashMap`, `std.StringHashMap`, `std.AutoHashMapUnmanaged`, etc. are thin aliases over this wrapper plus a specific context. This is separate from the `*Adapted` lookup feature, but both are part of the same layering strategy: keep the core table unmanaged and generic, then add policy/ergonomics in adapters.

---

### 5.8 Runnable non-compiler example: dictionary encoding

`string_interner_example.zig` in this directory is a complete, runnable example of the void-key interning pattern outside a compiler. It deduplicates repeated strings and assigns dense `u32` IDs, with the canonical bytes stored in a separate `ArrayList(u8)`.

```sh
zig run string_interner_example.zig
zig test string_interner_example.zig
```

Sample output:

```text
apple    -> id 0
banana   -> id 1
apple    -> id 0
cherry   -> id 2
banana   -> id 1
apple    -> id 0

unique strings: 3
  id 0: apple
  id 1: banana
  id 2: cherry
```

The map is `std.array_hash_map.Auto(void, void)`, so each entry stores only a hash and an index. The adapter resolves the candidate string through the entry index, and the entry index is the returned ID. This is the same shape used for dictionary-encoded columns, term dictionaries, token vocabularies, and asset registries.

---

### 5.9 Real dictionary: TMW frequency dictionary

`tmw_dictionary.zig` applies the same void-key interner to the 43.9 MB uncompressed `tmw-freq-dict.zip` in this directory. It reads the archive directly with `std.zip.Iterator`, so no manual extraction step is required.

```sh
zig run -O ReleaseFast tmw_dictionary.zig
zig run -O ReleaseFast tmw_dictionary.zig -- 何 東京 私
zig test tmw_dictionary.zig
```

The archive contains 25 parallel `term_bank_N.json` / `term_meta_bank_N.json` pairs. The loader collects both sets first because zip entry order is not guaranteed, then parses each pair in a reusable arena. Results are written through a 64 KiB buffered `std.Io.File.stdout()` writer and flushed once at the end, so normal output is pipe-friendly and nothing is written to stderr.

Two independent void-key interners are used:

```zig
terms:    StringInterner   // written forms, e.g. 何
readings: StringInterner   // readings, e.g. なに, なん
```

Each `Entry` stores only two string IDs plus a frequency and a linked-list index:

```zig
const Entry = struct {
    term: u32,
    reading: u32,
    frequency: u32,
    next: u32,
};
```

`heads` and `tails` are indexed by term ID, so all readings of a homograph stay grouped without a second hash map:

```text
heads[term_id] -> entry 0 -> entry 5 -> entry 9 -> no_entry
```

Observed results on the bundled archive:

```text
loaded 25 bank files from tmw-freq-dict.zip
entries: 243796
unique terms: 231415
unique readings: 211274
terms with multiple readings: 10541
max readings for one term: 9
```

Lookup output:

```text
何: 何
  なに                   frequency 62
  なん                   frequency 123
  か                      frequency 99999
  が                      frequency 99999
```

The important invariants are the same as the smaller example:

- The map entry index is the dense string ID.
- `bytes` can grow and reallocate without invalidating stored keys, because the map stores no slices.
- All fallible capacity reservations happen before `getOrPutAssumeCapacityAdapted`.
- The dictionary is append-only; no entry is ever removed, so IDs remain stable.
- Lookup uses `getIndexAdapted`; a `void` key makes `getKeyAdapted` useless because it would return `?void`.

---

## 6. Usage inventory

Search terms: `getAdapted`, `getPtrAdapted`, `getKeyAdapted`, `getKeyPtrAdapted`, `getEntryAdapted`, `getIndexAdapted`, `containsAdapted`, `getOrPutAdapted`, `getOrPutContextAdapted`, `getOrPutAssumeCapacityAdapted`, `removeAdapted`, `fetchRemoveAdapted`, `fetchSwapRemoveAdapted`, `fetchOrderedRemoveAdapted`, `swapRemoveAdapted`, `orderedRemoveAdapted`.

The table below excludes the method definitions and unit tests inside `std/hash_map.zig` and `std/array_hash_map.zig`. Those files contain additional test-only calls, e.g. the `test "getOrPutAdapted"` block at `std/hash_map.zig:2018`. The table covers all other `.zig` files under `lib/`.

| File | Adapted call sites | Primary role |
|---|---:|---|
| `std/zig/llvm/Builder.zig` | 34 | Structural dedup/interning; borrowed structural keys resolved through builder arrays |
| `std/zig/AstGen.zig` | 2 | String interning with `StringIndexAdapter` |
| `std/zig/ZonGen.zig` | 2 | String interning with `StringIndexAdapter` |
| `compiler/resinator/source_mapping.zig` | 2 | String table interning and lookup |
| `std/debug/Coverage.zig` | 2 | Composite borrowed directory/file keys |
| `std/debug/MachOFile.zig` | 2 | Symbol name lookup by symtab index |
| `std/Build/Configuration.zig` | 1 | Serialized string table interning |
| `std/crypto/Certificate/Bundle.zig` | 1 | Borrowed subject-name lookup |
| `std/debug/SelfInfo/MachO.zig` | 1 | Module lookup by text base |
| `compiler/aro/backend/Interner.zig` | 1 | Void-keyed intern table resolved by entry index |
| `compiler/Maker/Fetch.zig` | 1 | Fork lookup by project ID |
| `compiler/Maker/Step/Compile.zig` | 1 | Module graph lookup by root module index |
| **Total** | **50** | |

### Representative line numbers

- `std/zig/llvm/Builder.zig`: `3226`, `3236`, `3261`, `10071`, `10085`, `10110`, `11949`, `12007`, `12036`, `12066`, `12104`, `12143`, `12195`, `12282`, `12341`, `12398`, `12430`, `12464`, `12497`, `12632`, `12735`, `12865`, `12952`, `13004`, `13046`, `13088`, `13125`, `13289`, `13342`, `13795`, `14255`, `14314`, `14357`, `14468`
- `std/zig/AstGen.zig`: `11018`, `11046`
- `std/zig/ZonGen.zig`: `585`, `605`
- `compiler/resinator/source_mapping.zig`: `943`, `970`
- `std/debug/Coverage.zig`: `215`, `222`
- `std/debug/MachOFile.zig`: `262`, `549`
- `std/Build/Configuration.zig`: `186`
- `std/crypto/Certificate/Bundle.zig`: `60`
- `std/debug/SelfInfo/MachO.zig`: `486`
- `compiler/aro/backend/Interner.zig`: `584`
- `compiler/Maker/Fetch.zig`: `597`
- `compiler/Maker/Step/Compile.zig`: `1205`

---

## 7. Recommendations and review checklist

When adding a hash map adapter to Zig code:

- **Use `getAdapted` for read-only borrowed lookups.** It is allocation-free and does not require passing the real context, which is useful when the context is non-zero-sized or awkward to construct.
- **Use `getKeyAdapted` when you need the canonical stored key.** This is how interning code recovers the stored offset/handle after a hit.
- **Use `getIndexAdapted` only for grow-only array maps.** Treat the index as an unstable entry handle if removals can occur.
- **Use `getOrPutContextAdapted` when the map's Context is non-zero-sized.** Provide both the borrowed-key adapter and the real context.
- **Prefer `ensureUnusedCapacity` + `getOrPutAssumeCapacityAdapted` for bulk insertion.** It avoids per-entry growth, allocation failure, and pointer invalidation, and is the dominant pattern in the LLVM builder.
- **Always initialize `key_ptr` on a miss.** Even if the adapter is only used for lookup, `getOrPut` paths can insert. For `void` keys, `key_ptr.* = {}` is a harmless explicit initialization.
- **Keep the adapter's hash consistent with the context's hash.** If the canonical key hashes a projection, the adapter must hash the same projection with the same algorithm/seed.
- **Use the same hash width as the map.** `HashMap` adapters return `u64`; `ArrayHashMap` adapters return `u32`.
- **Do not capture slices that may be invalidated during the call.** Capture a pointer to the container or ensure capacity before the call.
- **Check NUL/terminator conventions.** The built-in `StringIndexAdapter` assumes the borrowed key has no embedded NUL and stored strings are NUL-terminated.
- **Remember that `getOrPutAdapted` may grow the map even on a hit.** Do not hold `Entry`/key/value pointers across the call.
- **Do not assume a `putAdapted` exists.** Insert by adapted key requires `getOrPutAdapted` plus canonical key assignment.
- **For array maps with `store_hash = false` and a non-zero-sized context, use the `*ContextAdapted` removal variants.** The short forms compile-error because reindexing moved entries needs the real context.
- **Use `ArrayHashMap`, not `HashMap`, when the adapter needs the stored entry index.** Only `ArrayHashMap` passes `stored_index` to `eql`; this enables void-keyed pseudo-key maps and index-resolved interning.

---

## 8. Minimal verification

The following adapter patterns were compiled and run with `zig test` against Zig 0.17.0:

1. A string-interner map using `StringIndexAdapter`-style semantics (`u32` offsets, borrowed `[]const u8` lookup, `getKeyAdapted`).
2. An `ArrayHashMap` with an adapter that receives the stored entry index and resolves the logical key indirectly.

Both tests passed. This confirms the core workflow:

```zig
const gop = try map.getOrPutContextAdapted(
    allocator,
    borrowed_key,
    adapter,
    canonical_context,
);
if (!gop.found_existing) {
    // gop.key_ptr is undefined here
    gop.key_ptr.* = canonical_key;
    gop.value_ptr.* = value;
}
```

---

## 9. Bottom line

Zig's adapted hash map API is a small, low-level facility that solves a recurring systems-programming problem: **look up a map by a cheap borrowed representation without constructing or allocating the canonical key**.

The std library uses it in three broad ways:

1. **Interning**: stored offsets/indices, borrowed strings or structures as lookup keys.
2. **Indirection**: stored compact index keys, adapter resolves the logical key through a parallel table.
3. **Projection/composition**: stored rich objects, adapter looks up by one field or a borrowed composite.

The implementation cost is low: an adapter is usually a 10–30 line struct with `hash` and `eql`. The payoff is allocation-free lookups, compact keys, and the ability to deduplicate structural data without building temporary canonical keys.

The main hazards are all semantic rather than syntactic: hash/context consistency, `key_ptr` initialization, adapter/buffer lifetime, and the `store_hash`-dependent removal API on `ArrayHashMap`.
