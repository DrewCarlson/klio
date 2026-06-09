//! Cycle-aware traversal over the runtime object graph.
//!
//! `publishValue`/`publishEnv` walk the exact reachability graph of a
//! value (or environment) and call `ObjRef.publish()` on every cell they
//! reach, so a reference about to escape to another thread carries a
//! happens-before edge for the whole graph it transitively owns.
//! Publishing is always safe and idempotent; the visited set only bounds
//! recursion over cycles.
//!
//! The visited set keys on `ObjRef.identity()` (the cell's data pointer);
//! `ClassDef` walks additionally key on the class handle's identity so
//! parent/enclosing cycles terminate.

const std = @import("std");
const objcell = @import("objcell.zig");
const value_mod = @import("value.zig");
const class_mod = @import("class.zig");
const env_mod = @import("env.zig");

const ObjRef = objcell.ObjRef;
const Value = value_mod.Value;
const DelegateKind = value_mod.DelegateKind;
const SequenceSource = value_mod.SequenceSource;
const SeqOp = value_mod.SeqOp;
const ClassDef = class_mod.ClassDef;
const InstanceData = class_mod.InstanceData;
const Env = env_mod.Env;

const Seen = std.AutoHashMap(usize, void);

/// Publish (and recurse through) one `ObjRef`. Publishing is always
/// safe and idempotent; the visited set only bounds recursion. Returns
/// `true` when this is the first visit (caller should recurse into the
/// contents), `false` when the cell was already walked.
fn markCell(comptime T: type, r: ObjRef(T), seen: *Seen) bool {
    r.publish();
    const gop = seen.getOrPut(r.identity()) catch return false;
    return !gop.found_existing;
}

pub fn publishEnv(env: *const Env, seen: *Seen) void {
    var it = env.vars.valueIterator();
    while (it.next()) |v| {
        publishValue(v, seen);
    }
    if (env.parent) |parent| {
        if (markCell(Env, parent, seen)) {
            const g = parent.borrow();
            defer g.deinit();
            publishEnv(g.get(), seen);
        }
    }
}

fn publishClassdef(cls: ObjRef(ClassDef), seen: *Seen) void {
    // Key ClassDef walks on the handle identity so parent/enclosing
    // cycles terminate even though the handle itself carries no inner
    // ObjRef cell we would otherwise mark.
    const gop = seen.getOrPut(cls.identity()) catch return;
    if (gop.found_existing) {
        return;
    }
    const cg = cls.borrow();
    defer cg.deinit();
    const c = cg.get();

    if (markCell(?ObjRef(ClassDef), c.parent, seen)) {
        const g = c.parent.borrow();
        defer g.deinit();
        if (g.get().*) |p| {
            publishClassdef(p, seen);
        }
    }
    if (markCell(std.ArrayList(ObjRef(ClassDef)), c.interfaces, seen)) {
        const g = c.interfaces.borrow();
        defer g.deinit();
        for (g.get().items) |iface| {
            publishClassdef(iface, seen);
        }
    }
    if (markCell(std.ArrayList(ClassDef.EnumEntry), c.enum_entries, seen)) {
        const g = c.enum_entries.borrow();
        defer g.deinit();
        for (g.get().items) |*entry| {
            publishValue(&entry.value, seen);
        }
    }
    if (markCell(?ObjRef(InstanceData), c.companion, seen)) {
        const g = c.companion.borrow();
        defer g.deinit();
        if (g.get().*) |comp| {
            if (markCell(InstanceData, comp, seen)) {
                const ig = comp.borrow();
                defer ig.deinit();
                publishInstance(ig.get(), seen);
            }
        }
    }
    if (markCell(?ObjRef(ClassDef), c.enclosing_class, seen)) {
        const g = c.enclosing_class.borrow();
        defer g.deinit();
        if (g.get().*) |e| {
            publishClassdef(e, seen);
        }
    }
    if (markCell(std.ArrayList(ClassDef.NestedClass), c.nested_classes, seen)) {
        const g = c.nested_classes.borrow();
        defer g.deinit();
        for (g.get().items) |nested| {
            publishClassdef(nested.class, seen);
        }
    }
    if (markCell(Env, c.captured_env, seen)) {
        const g = c.captured_env.borrow();
        defer g.deinit();
        publishEnv(g.get(), seen);
    }
    if (markCell(std.ArrayList(class_mod.SupertypeDelegate), c.supertype_delegates, seen)) {
        // SupertypeDelegate carries only resolved ClassDefs and
        // immutable Expr pointers; recurse the resolved interfaces.
        const g = c.supertype_delegates.borrow();
        defer g.deinit();
        for (g.get().items) |d| {
            if (d.interface) |iface| {
                publishClassdef(iface, seen);
            }
        }
    }
    if (markCell(std.ArrayList(class_mod.MethodDef), c.delegate_forwarders, seen)) {
        const g = c.delegate_forwarders.borrow();
        defer g.deinit();
        for (g.get().items) |*m| {
            if (m.sam_lambda) |*v| {
                publishValue(v, seen);
            }
        }
    }
    if (markCell(?ObjRef(InstanceData), c.object_singleton, seen)) {
        const g = c.object_singleton.borrow();
        defer g.deinit();
        if (g.get().*) |s| {
            if (markCell(InstanceData, s, seen)) {
                const ig = s.borrow();
                defer ig.deinit();
                publishInstance(ig.get(), seen);
            }
        }
    }
    // Methods can carry SAM-converted lambda values that close over
    // the graph; publish those too.
    for (c.methods) |*m| {
        if (m.sam_lambda) |*v| {
            publishValue(v, seen);
        }
    }
}

fn publishInstance(inst: *const InstanceData, seen: *Seen) void {
    publishClassdef(inst.class, seen);
    for (inst.fields.items) |*f| {
        publishValue(&f.value, seen);
    }
    if (inst.outer) |*outer| {
        publishValue(outer, seen);
    }
}

fn publishDelegate(kind: *const DelegateKind, seen: *Seen) void {
    switch (kind.*) {
        .Lazy => |*l| {
            publishValue(&l.producer, seen);
            if (l.cached) |*c| {
                publishValue(c, seen);
            }
        },
        .Observable => |*o| {
            publishValue(&o.value, seen);
            publishValue(&o.on_change, seen);
        },
        .NotNull => |*n| {
            if (n.value) |*v| {
                publishValue(v, seen);
            }
        },
    }
}

pub fn publishValue(v: *const Value, seen: *Seen) void {
    switch (v.*) {
        // Scalars / immutable leaves and the coroutine sentinel: no
        // ObjRef, nothing to publish.
        .Unit,
        .Int,
        .Long,
        .Short,
        .Byte,
        .UInt,
        .ULong,
        .UShort,
        .UByte,
        .Double,
        .Float,
        .Bool,
        .String,
        .Char,
        .Null,
        .Range,
        .Intrinsic,
        .BoundMethod,
        .PropertyRef,
        .Regex,
        .Match,
        .MatchGroup,
        .CoroutineSuspended,
        => {},

        .List => |l| {
            if (markCell(std.ArrayList(Value), l.items, seen)) {
                const g = l.items.borrow();
                defer g.deinit();
                for (g.get().items) |*elem| {
                    publishValue(elem, seen);
                }
            }
            if (l.backing) |b| {
                if (markCell(std.ArrayList(value_mod.MapPair), b.entries, seen)) {
                    const g = b.entries.borrow();
                    defer g.deinit();
                    for (g.get().items) |*kv| {
                        publishValue(&kv.key, seen);
                        publishValue(&kv.value, seen);
                    }
                }
            }
        },
        .Set => |s| {
            if (markCell(std.ArrayList(Value), s.items, seen)) {
                const g = s.items.borrow();
                defer g.deinit();
                for (g.get().items) |*elem| {
                    publishValue(elem, seen);
                }
            }
            if (s.backing) |b| {
                if (markCell(std.ArrayList(value_mod.MapPair), b.entries, seen)) {
                    const g = b.entries.borrow();
                    defer g.deinit();
                    for (g.get().items) |*kv| {
                        publishValue(&kv.key, seen);
                        publishValue(&kv.value, seen);
                    }
                }
            }
        },
        .Array => |a| {
            if (markCell(std.ArrayList(Value), a.items, seen)) {
                const g = a.items.borrow();
                defer g.deinit();
                for (g.get().items) |*elem| {
                    publishValue(elem, seen);
                }
            }
        },
        .Iterator => |it| {
            if (markCell(std.ArrayList(Value), it.items, seen)) {
                const g = it.items.borrow();
                defer g.deinit();
                for (g.get().items) |*elem| {
                    publishValue(elem, seen);
                }
            }
            _ = markCell(usize, it.pos, seen);
        },
        // The lazy range iterator's only ObjRef is the `cur` counter
        // (an i64 cell — no nested values to walk). Publish the cell so
        // the cross-thread fence applies.
        .RangeIter => |ri| {
            _ = markCell(i64, ri.cur, seen);
        },
        .Map => |m| {
            if (markCell(std.ArrayList(value_mod.MapPair), m.entries, seen)) {
                const g = m.entries.borrow();
                defer g.deinit();
                for (g.get().items) |*kv| {
                    publishValue(&kv.key, seen);
                    publishValue(&kv.value, seen);
                }
            }
        },

        .Instance => |inst| {
            if (markCell(InstanceData, inst, seen)) {
                const g = inst.borrow();
                defer g.deinit();
                publishInstance(g.get(), seen);
            }
        },
        .BoundUserMethod => |m| {
            if (markCell(InstanceData, m.receiver, seen)) {
                const g = m.receiver.borrow();
                defer g.deinit();
                publishInstance(g.get(), seen);
            }
        },
        .BoundInnerClass => |b| {
            publishClassdef(b.class, seen);
            if (markCell(InstanceData, b.outer, seen)) {
                const g = b.outer.borrow();
                defer g.deinit();
                publishInstance(g.get(), seen);
            }
        },
        .Class => |cls| publishClassdef(cls, seen),

        .Cell => |c| {
            if (markCell(Value, c, seen)) {
                const g = c.borrow();
                defer g.deinit();
                publishValue(g.get(), seen);
            }
        },
        .Delegate => |d| {
            if (markCell(DelegateKind, d, seen)) {
                const g = d.borrow();
                defer g.deinit();
                publishDelegate(g.get(), seen);
            }
        },
        .StringBuilder => |sb| {
            // String leaf: publish the cell, no inner ObjRef.
            _ = markCell(std.ArrayList(u8), sb, seen);
        },

        .Function => |f| {
            if (markCell(Env, f.env, seen)) {
                const g = f.env.borrow();
                defer g.deinit();
                publishEnv(g.get(), seen);
            }
        },
        .Pair => |p| {
            publishValue(p.first, seen);
            publishValue(p.second, seen);
        },
        .Triple => |t| {
            publishValue(t.first, seen);
            publishValue(t.second, seen);
            publishValue(t.third, seen);
        },
        .MapEntry => |e| {
            publishValue(e.key, seen);
            publishValue(e.value, seen);
            if (e.backing) |b| {
                if (markCell(std.ArrayList(value_mod.MapPair), b, seen)) {
                    const g = b.borrow();
                    defer g.deinit();
                    for (g.get().items) |*kv| {
                        publishValue(&kv.key, seen);
                        publishValue(&kv.value, seen);
                    }
                }
            }
        },
        .Result => |r| publishValue(r.payload, seen),
        .Exception => |e| {
            if (e.cause) |c| {
                publishValue(c, seen);
            }
        },

        .IrClosure => |c| {
            const g = c.captures.borrow();
            defer g.deinit();
            for (g.get().*) |*cap| {
                publishValue(cap, seen);
            }
        },
        .Comparator => |cmp| {
            const g = cmp.steps.borrow();
            defer g.deinit();
            for (g.get().*) |*step| {
                publishValue(&step.selector, seen);
            }
        },
        .Sequence => |seq| {
            const sg = seq.borrow();
            defer sg.deinit();
            const data = sg.get();
            switch (data.source) {
                .Items => |items| {
                    const g = items.borrow();
                    defer g.deinit();
                    for (g.get().*) |*elem| {
                        publishValue(elem, seen);
                    }
                },
                .Generate => |gen| {
                    if (gen.seed) |s| {
                        publishValue(s, seen);
                    }
                    publishValue(gen.next, seen);
                },
            }
            for (data.ops) |*op| {
                switch (op.*) {
                    .Map,
                    .Filter,
                    .FilterNot,
                    .OnEach,
                    .MapIndexed,
                    .FilterIndexed,
                    .TakeWhile,
                    .DropWhile,
                    .FlatMap,
                    .DistinctBy,
                    .SortedWith,
                    => |*op_v| publishValue(op_v, seen),
                    .SortedBy => |*sb| publishValue(&sb.selector, seen),
                    .Take, .Drop, .Distinct, .Sorted => {},
                }
            }
        },
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const ValueList = value_mod.ValueList;

test "publishValue on a scalar leaves it unshared and marks nothing" {
    var seen = Seen.init(testing.allocator);
    defer seen.deinit();
    const v = Value{ .Int = 7 };
    publishValue(&v, &seen);
    try testing.expectEqual(@as(usize, 0), seen.count());
}

test "publishValue marks a list cell once and publishes it" {
    var seen = Seen.init(testing.allocator);
    defer seen.deinit();

    const items = try ValueList.init(testing.allocator, .empty);
    // Dropping the last handle runs the inner ArrayList's deinit.
    defer items.deinit();
    {
        const g = items.borrowMut();
        defer g.deinit();
        try g.get().append(testing.allocator, .{ .Int = 1 });
        try g.get().append(testing.allocator, .{ .Int = 2 });
    }
    try testing.expect(!items.isShared());

    const v = Value{ .List = .{ .items = items, .mutable = true, .enum_class = null, .backing = null } };
    publishValue(&v, &seen);

    try testing.expect(items.isShared());
    try testing.expectEqual(@as(usize, 1), seen.count());
    try testing.expect(seen.contains(items.identity()));
}

test "publishValue terminates on a self-referential cell" {
    var seen = Seen.init(testing.allocator);
    defer seen.deinit();

    // A Cell that contains itself: walking must terminate via `seen`.
    const cell = try ObjRef(Value).init(testing.allocator, .Null);
    defer cell.deinit();
    {
        const g = cell.borrowMut();
        defer g.deinit();
        g.get().* = .{ .Cell = cell };
    }

    const v = Value{ .Cell = cell };
    publishValue(&v, &seen);

    try testing.expect(cell.isShared());
    try testing.expectEqual(@as(usize, 1), seen.count());
    try testing.expect(seen.contains(cell.identity()));

    // Break the cycle before the deferred deinit so the cell drops.
    {
        const g = cell.borrowMut();
        defer g.deinit();
        g.get().* = .Null;
    }
}

test "publishValue recurses through a pair into nested cells" {
    var seen = Seen.init(testing.allocator);
    defer seen.deinit();

    const inner = try ValueList.init(testing.allocator, .empty);
    defer inner.deinit();
    var first = Value{ .List = .{ .items = inner, .mutable = false, .enum_class = null, .backing = null } };
    var second = Value{ .Int = 9 };
    const v = Value{ .Pair = .{ .first = &first, .second = &second } };
    publishValue(&v, &seen);

    try testing.expect(inner.isShared());
    try testing.expectEqual(@as(usize, 1), seen.count());
}

test "publishEnv publishes bound values and the parent chain" {
    var seen = Seen.init(testing.allocator);
    defer seen.deinit();

    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();

    const items = try ValueList.init(testing.allocator, .empty);
    defer items.deinit();

    var child = Env.withParent(testing.allocator, parent);
    defer child.deinit();
    try child.define("xs", .{ .List = .{ .items = items, .mutable = true, .enum_class = null, .backing = null } });

    publishEnv(&child, &seen);

    try testing.expect(items.isShared());
    try testing.expect(parent.isShared());
    // The list cell and the parent env cell are both recorded.
    try testing.expect(seen.contains(items.identity()));
    try testing.expect(seen.contains(parent.identity()));
}
