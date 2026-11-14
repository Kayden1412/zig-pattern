const std = @import("std");

// ---------------------------------------------------------------------------
// A JS-Array-style higher-order-function demo using the "trait" pattern from
// https://www.axelmagn.com/blog/202610-zig-traits/:
//
//   * a trait is a comptime struct of functions/constants
//   * an implementation is a value of that struct
//   * consumers take the implementation as an explicit parameter
//
// The callbacks are trait values, not `*const fn` pointers. Zig monomorphizes
// each method per callback, so there is no indirect-call overhead.
// ---------------------------------------------------------------------------

pub fn impl(comptime Trait: type, comptime Impl: type) Trait {
    comptime {
        var result: Trait = undefined;
        for (@typeInfo(Trait).@"struct".field_names) |name| {
            @field(result, name) = @field(Impl, name);
        }
        return result;
    }
}

// Callback traits ----------------------------------------------------------

pub fn Consumer(comptime T: type) type {
    return struct {
        accept: fn (T) void,
    };
}

pub fn Mapper(comptime In: type, comptime Out: type) type {
    return struct {
        map: fn (In) Out,
    };
}

pub fn Predicate(comptime T: type) type {
    return struct {
        check: fn (T) bool,
    };
}

pub fn Reducer(comptime Acc: type, comptime Elem: type) type {
    return struct {
        combine: fn (Acc, Elem) Acc,
    };
}

// A trait functor: build a new Mapper by composing two existing ones.
pub fn compose(
    comptime A: type,
    comptime B: type,
    comptime C: type,
    comptime f: Mapper(A, B),
    comptime g: Mapper(B, C),
) Mapper(A, C) {
    return impl(Mapper(A, C), struct {
        pub fn map(x: A) C {
            return g.map(f.map(x));
        }
    });
}

// JS-like array wrapper ----------------------------------------------------

pub fn JsArray(comptime T: type) type {
    return struct {
        items: []const T,

        const Self = @This();

        pub fn init(items: []const T) Self {
            return .{ .items = items };
        }

        pub fn forEach(self: Self, comptime consumer: Consumer(T)) void {
            for (self.items) |x| consumer.accept(x);
        }

        pub fn map(
            self: Self,
            comptime Out: type,
            comptime mapper: Mapper(T, Out),
            out: []Out,
        ) []Out {
            std.debug.assert(out.len >= self.items.len);
            for (self.items, 0..) |x, i| out[i] = mapper.map(x);
            return out[0..self.items.len];
        }

        pub fn filter(
            self: Self,
            comptime pred: Predicate(T),
            out: []T,
        ) []T {
            std.debug.assert(out.len >= self.items.len);
            var n: usize = 0;
            for (self.items) |x| {
                if (pred.check(x)) {
                    out[n] = x;
                    n += 1;
                }
            }
            return out[0..n];
        }

        pub fn reduce(
            self: Self,
            comptime Acc: type,
            comptime reducer: Reducer(Acc, T),
            init_value: Acc,
        ) Acc {
            var acc = init_value;
            for (self.items) |x| acc = reducer.combine(acc, x);
            return acc;
        }

        pub fn find(self: Self, comptime pred: Predicate(T)) ?T {
            for (self.items) |x| {
                if (pred.check(x)) return x;
            }
            return null;
        }

        pub fn some(self: Self, comptime pred: Predicate(T)) bool {
            for (self.items) |x| {
                if (pred.check(x)) return true;
            }
            return false;
        }

        pub fn every(self: Self, comptime pred: Predicate(T)) bool {
            for (self.items) |x| {
                if (!pred.check(x)) return false;
            }
            return true;
        }
    };
}

// Concrete callbacks -------------------------------------------------------

const printElem = impl(Consumer(i32), struct {
    pub fn accept(x: i32) void {
        std.debug.print("{d} ", .{x});
    }
});

const double = impl(Mapper(i32, i32), struct {
    pub fn map(x: i32) i32 {
        return x * 2;
    }
});

const square = impl(Mapper(i32, i32), struct {
    pub fn map(x: i32) i32 {
        return x * x;
    }
});

const doubleThenSquare = compose(i32, i32, i32, double, square);

const parityLabel = impl(Mapper(i32, []const u8), struct {
    pub fn map(x: i32) []const u8 {
        return if (@mod(x, 2) == 0) "even" else "odd";
    }
});

const isEven = impl(Predicate(i32), struct {
    pub fn check(x: i32) bool {
        return @mod(x, 2) == 0;
    }
});

const isPositive = impl(Predicate(i32), struct {
    pub fn check(x: i32) bool {
        return x > 0;
    }
});

const sum = impl(Reducer(i32, i32), struct {
    pub fn combine(acc: i32, x: i32) i32 {
        return acc + x;
    }
});

const countEvens = impl(Reducer(usize, i32), struct {
    pub fn combine(acc: usize, x: i32) usize {
        return if (@mod(x, 2) == 0) acc + 1 else acc;
    }
});

// Demo ---------------------------------------------------------------------

pub fn main() void {
    const xs = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const arr = JsArray(i32).init(&xs);

    std.debug.print("forEach:        ", .{});
    arr.forEach(printElem);
    std.debug.print("\n", .{});

    var doubled_buf: [xs.len]i32 = undefined;
    const doubled = arr.map(i32, double, &doubled_buf);
    std.debug.print("map:            ", .{});
    for (doubled) |x| std.debug.print("{d} ", .{x});
    std.debug.print("\n", .{});

    var labels_buf: [xs.len][]const u8 = undefined;
    const labels = arr.map([]const u8, parityLabel, &labels_buf);
    std.debug.print("map<[]const u8>: ", .{});
    for (labels) |s| std.debug.print("{s} ", .{s});
    std.debug.print("\n", .{});

    var composed_buf: [xs.len]i32 = undefined;
    const composed = arr.map(i32, doubleThenSquare, &composed_buf);
    std.debug.print("compose:        ", .{});
    for (composed) |x| std.debug.print("{d} ", .{x});
    std.debug.print("\n", .{});

    var evens_buf: [xs.len]i32 = undefined;
    const evens = arr.filter(isEven, &evens_buf);
    std.debug.print("filter:         ", .{});
    for (evens) |x| std.debug.print("{d} ", .{x});
    std.debug.print("\n", .{});

    // HOF chaining: filter(...) -> JsArray -> map(...)
    const even_arr = JsArray(i32).init(evens);
    var squared_buf: [xs.len]i32 = undefined;
    const squared = even_arr.map(i32, square, &squared_buf);
    std.debug.print("filter + map:   ", .{});
    for (squared) |x| std.debug.print("{d} ", .{x});
    std.debug.print("\n", .{});

    std.debug.print("reduce sum:     {d}\n", .{arr.reduce(i32, sum, 0)});
    std.debug.print("reduce count:   {d}\n", .{arr.reduce(usize, countEvens, 0)});

    if (arr.find(isEven)) |v| {
        std.debug.print("find even:      {d}\n", .{v});
    } else {
        std.debug.print("find even:      null\n", .{});
    }

    std.debug.print("some even:      {}\n", .{arr.some(isEven)});
    std.debug.print("every positive: {}\n", .{arr.every(isPositive)});
    std.debug.print("every even:     {}\n", .{arr.every(isEven)});
}
