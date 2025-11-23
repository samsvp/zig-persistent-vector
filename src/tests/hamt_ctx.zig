const std = @import("std");
pub const KV = @import("../hamt.zig").KV;
pub const KVContext = @import("../hamt.zig").KVContext;
pub const HashContext = @import("../hamt.zig").HashContext;
pub const Hamt = @import("../hamt.zig").Hamt;

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn strHash(a: []const u8) u32 {
    var h: u32 = 2166136261;
    for (a) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

fn kv_init(gpa: std.mem.Allocator, key: []const u8, value: std.ArrayList(f32)) !KV([]const u8, std.ArrayList(f32)) {
    return .{ .key = try gpa.dupe(u8, key), .value = try value.clone(gpa) };
}

fn kv_deinit(gpa: std.mem.Allocator, kv: *KV([]const u8, std.ArrayList(f32))) void {
    gpa.free(kv.key);
    kv.value.deinit(gpa);
}

fn kv_clone(gpa: std.mem.Allocator, kv: *KV([]const u8, std.ArrayList(f32))) !KV([]const u8, std.ArrayList(f32)) {
    return kv_init(gpa, kv.key, kv.value);
}

const K = []const u8;
const V = std.ArrayList(f32);

const MyHashCtx = HashContext(K){
    .eql = strEql,
    .hash = strHash,
};

const MyKVCtx = KVContext(K, V){
    .init = kv_init,
    .deinit = kv_deinit,
    .clone = kv_clone,
};

const FloatList = std.ArrayList(f32);

const MyHamt = Hamt(K, V, MyHashCtx, MyKVCtx);

test "hamt: custom kv lifecycle (deep copy and free)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h = MyHamt.init();
    defer h.deinit(allocator);

    // Create data on stack (Unmanaged lists default to empty/null)
    var list = FloatList{};
    // Note: Unmanaged lists require passing the allocator to append/deinit
    defer list.deinit(allocator);
    try list.append(allocator, 1.1);
    try list.append(allocator, 2.2);

    // Insert "key1" -> [1.1, 2.2]
    // This triggers kv_init, which clones the list using 'allocator'
    try h.assocMut(allocator, "key1", list);

    // Modify original list to prove deep copy inside HAMT
    try list.append(allocator, 3.3);

    // Verify stored data
    const val = h.get("key1");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(usize, 2), val.?.items.len); // Should stay 2 (internal copy)
    try std.testing.expectEqual(1.1, val.?.items[0]);
    try std.testing.expectEqual(2.2, val.?.items[1]);
}

test "hamt: custom kv persistence (structural sharing with deep data)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h1 = MyHamt.init();
    defer h1.deinit(allocator);

    var list1 = FloatList{};
    defer list1.deinit(allocator);
    try list1.append(allocator, 10.0);

    // h1 = { "a": [10.0] }
    try h1.assocMut(allocator, "a", list1);

    var list2 = FloatList{};
    defer list2.deinit(allocator);
    try list2.append(allocator, 20.0);

    // h2 = h1 + { "b": [20.0] }
    var h2 = try h1.assoc(allocator, "b", list2);
    defer h2.deinit(allocator);

    // Check h2
    try std.testing.expectEqual(10.0, h2.get("a").?.items[0]);
    try std.testing.expectEqual(20.0, h2.get("b").?.items[0]);

    // Check h1 (Immutable)
    try std.testing.expectEqual(10.0, h1.get("a").?.items[0]);
    try std.testing.expect(h1.get("b") == null);
}

test "hamt: deep removal logic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h = MyHamt.init();
    defer h.deinit(allocator);

    var list = FloatList{};
    defer list.deinit(allocator);
    try list.append(allocator, 42.0);

    try h.assocMut(allocator, "remove_me", list);
    try std.testing.expect(h.get("remove_me") != null);

    // Remove
    // This triggers kv_deinit internally for the removed node
    try h.dissocMut(allocator, "remove_me");

    try std.testing.expect(h.get("remove_me") == null);
    try std.testing.expectEqual(@as(usize, 0), h.size);
}

test "hamt: collision handling" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Force collisions
    const BadHashCtx = HashContext(K){
        .eql = strEql,
        .hash = struct {
            fn h(_: K) u32 {
                return 0;
            }
        }.h,
    };
    const BadHamt = Hamt(K, V, BadHashCtx, MyKVCtx);

    var h = BadHamt.init();
    defer h.deinit(allocator);

    var list = FloatList{};
    defer list.deinit(allocator);
    try list.append(allocator, 100.0);

    // Both map to hash 0
    try h.assocMut(allocator, "col1", list);
    try h.assocMut(allocator, "col1", list);
    try h.assocMut(allocator, "col2", list);
    try h.assocMut(allocator, "col3", list);
    try h.assocMut(allocator, "col2", list);

    try std.testing.expectEqual(100.0, h.get("col1").?.items[0]);
    try std.testing.expectEqual(100.0, h.get("col2").?.items[0]);

    try h.dissocMut(allocator, "col1");
    try std.testing.expect(h.get("col1") == null);
    try std.testing.expect(h.get("col2") != null);
}

test "persistent hamt: collision handling 2" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Force collisions
    const BadHashCtx = HashContext(K){
        .eql = strEql,
        .hash = struct {
            fn h(_: K) u32 {
                return 0;
            }
        }.h,
    };
    const BadHamt = Hamt(K, V, BadHashCtx, MyKVCtx);

    var h0 = BadHamt.init();
    defer h0.deinit(allocator);

    var list = FloatList{};
    defer list.deinit(allocator);
    try list.append(allocator, 100.0);

    var list2 = FloatList{};
    defer list2.deinit(allocator);
    try list2.append(allocator, 150.0);

    // Both map to hash 0
    var h1 = try h0.assoc(allocator, "col1", list);
    defer h1.deinit(allocator);
    var h2 = try h1.assoc(allocator, "col1", list2);
    defer h2.deinit(allocator);
    var h3 = try h2.assoc(allocator, "col2", list);
    defer h3.deinit(allocator);
    var h4 = try h3.assoc(allocator, "col3", list);
    defer h4.deinit(allocator);
    var h5 = try h4.assoc(allocator, "col2", list2);
    defer h5.deinit(allocator);

    try std.testing.expectEqual(100.0, h1.get("col1").?.items[0]);
    try std.testing.expectEqual(150.0, h2.get("col1").?.items[0]);
    try std.testing.expectEqual(null, h2.get("col2"));
    try std.testing.expectEqual(100.0, h3.get("col2").?.items[0]);
    try std.testing.expectEqual(100.0, h4.get("col3").?.items[0]);
    try std.testing.expectEqual(100.0, h5.get("col3").?.items[0]);
    try std.testing.expectEqual(150.0, h5.get("col2").?.items[0]);

    var h6 = try h5.dissoc(allocator, "col1");
    defer h6.deinit(allocator);

    try std.testing.expect(h6.get("col1") == null);
    try std.testing.expect(h6.get("col2") != null);
    try std.testing.expect(h6.get("col3") != null);

    try std.testing.expectEqual(100.0, h1.get("col1").?.items[0]);
    try std.testing.expectEqual(150.0, h2.get("col1").?.items[0]);
    try std.testing.expectEqual(null, h2.get("col2"));
    try std.testing.expectEqual(100.0, h3.get("col2").?.items[0]);
    try std.testing.expectEqual(100.0, h4.get("col3").?.items[0]);
    try std.testing.expectEqual(100.0, h5.get("col3").?.items[0]);
    try std.testing.expectEqual(150.0, h5.get("col2").?.items[0]);
}

test "persistent hamt: collision handling" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Force collisions (Hash is always 0)
    const BadHashCtx = HashContext(K){
        .eql = strEql,
        .hash = struct {
            fn h(_: K) u32 {
                return 0;
            }
        }.h,
    };
    const BadHamt = Hamt(K, V, BadHashCtx, MyKVCtx);

    var h0 = BadHamt.init();
    defer h0.deinit(allocator);

    var list100 = FloatList{};
    defer list100.deinit(allocator);
    try list100.append(allocator, 100.0);

    var list150 = FloatList{};
    defer list150.deinit(allocator);
    try list150.append(allocator, 150.0);

    var h1 = try h0.assoc(allocator, "col1", list100);
    defer h1.deinit(allocator);

    var h2 = try h1.assoc(allocator, "col1", list150);
    defer h2.deinit(allocator);

    var h3 = try h2.assoc(allocator, "col2", list100);
    defer h3.deinit(allocator);

    var h4 = try h3.assoc(allocator, "col3", list100);
    defer h4.deinit(allocator);

    var h5 = try h4.assoc(allocator, "col2", list150);
    defer h5.deinit(allocator);

    try std.testing.expectEqual(100.0, h1.get("col1").?.items[0]);
    try std.testing.expect(h1.get("col2") == null);

    try std.testing.expectEqual(150.0, h2.get("col1").?.items[0]);
    try std.testing.expect(h2.get("col2") == null);

    try std.testing.expectEqual(150.0, h3.get("col1").?.items[0]);
    try std.testing.expectEqual(100.0, h3.get("col2").?.items[0]);

    try std.testing.expectEqual(150.0, h4.get("col1").?.items[0]);
    try std.testing.expectEqual(100.0, h4.get("col2").?.items[0]);
    try std.testing.expectEqual(100.0, h4.get("col3").?.items[0]);

    try std.testing.expectEqual(150.0, h5.get("col1").?.items[0]);
    try std.testing.expectEqual(150.0, h5.get("col2").?.items[0]);
    try std.testing.expectEqual(100.0, h5.get("col3").?.items[0]);

    var h6 = try h5.dissoc(allocator, "col1");
    defer h6.deinit(allocator);

    try std.testing.expect(h6.get("col1") == null);
    try std.testing.expectEqual(150.0, h6.get("col2").?.items[0]);
    try std.testing.expectEqual(100.0, h6.get("col3").?.items[0]);

    try std.testing.expectEqual(150.0, h5.get("col1").?.items[0]);
    try std.testing.expectEqual(150.0, h5.get("col2").?.items[0]);
    try std.testing.expectEqual(100.0, h5.get("col3").?.items[0]);
}

test "hamt: strHash basic CRUD" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = MyHamt.init();
    defer h0.deinit(allocator);

    var listA = FloatList.empty;
    defer listA.deinit(allocator);
    try listA.append(allocator, 10.0);

    var listB = FloatList.empty;
    defer listB.deinit(allocator);
    try listB.append(allocator, 20.0);

    var h1 = try h0.assoc(allocator, "alpha", listA);
    defer h1.deinit(allocator);

    try std.testing.expectEqual(10.0, h1.get("alpha").?.items[0]);
    try std.testing.expect(h1.get("beta") == null);

    var h2 = try h1.assoc(allocator, "beta", listB);
    defer h2.deinit(allocator);

    try std.testing.expectEqual(10.0, h2.get("alpha").?.items[0]);
    try std.testing.expectEqual(20.0, h2.get("beta").?.items[0]);

    var h3 = try h2.dissoc(allocator, "alpha");
    defer h3.deinit(allocator);

    try std.testing.expect(h3.get("alpha") == null);
    try std.testing.expectEqual(20.0, h3.get("beta").?.items[0]);

    try std.testing.expectEqual(10.0, h2.get("alpha").?.items[0]);
}

test "hamt: strHash persistence chain (structural sharing)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var roots = std.ArrayList(MyHamt).empty;
    defer {
        for (roots.items) |*r| r.deinit(allocator);
        roots.deinit(allocator);
    }

    try roots.append(allocator, MyHamt.init());

    var data = FloatList.empty;
    defer data.deinit(allocator);
    try data.append(allocator, 1.0);

    {
        const next = try roots.items[0].assoc(allocator, "one", data);
        try roots.append(allocator, next);
    }

    {
        const next = try roots.items[1].assoc(allocator, "two", data);
        try roots.append(allocator, next);
    }

    {
        const next = try roots.items[2].assoc(allocator, "three", data);
        try roots.append(allocator, next);
    }

    {
        var newData = FloatList.empty;
        defer newData.deinit(allocator);
        try newData.append(allocator, 999.0);

        const next = try roots.items[3].assoc(allocator, "one", newData);
        try roots.append(allocator, next);
    }

    try std.testing.expect(roots.items[1].get("one") != null);
    try std.testing.expect(roots.items[1].get("two") == null);

    try std.testing.expectEqual(1.0, roots.items[3].get("one").?.items[0]);
    try std.testing.expect(roots.items[3].get("three") != null);

    try std.testing.expectEqual(999.0, roots.items[4].get("one").?.items[0]);
    try std.testing.expectEqual(1.0, roots.items[4].get("two").?.items[0]);
}

test "hamt: strHash bulk insertion stress test" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h = MyHamt.init();
    defer h.deinit(allocator);

    // Keep track of allocated keys to free them later
    var keys = std.ArrayList([]const u8).empty;
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    var val = FloatList.empty;
    defer val.deinit(allocator);
    try val.append(allocator, 42.0);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "key_{d}", .{i});
        try keys.append(allocator, key);

        try h.assocMut(allocator, key, val);
    }

    try std.testing.expectEqual(@as(usize, 100), h.size);

    // Verify all exist
    for (keys.items) |k| {
        const res = h.get(k);
        try std.testing.expect(res != null);
        try std.testing.expectEqual(42.0, res.?.items[0]);
    }

    // Verify non-existent
    try std.testing.expect(h.get("key_101") == null);

    // Remove the first 50
    i = 0;
    while (i < 50) : (i += 1) {
        try h.dissocMut(allocator, keys.items[i]);
    }

    try std.testing.expectEqual(@as(usize, 50), h.size);

    // Verify remaining 50 exist
    i = 50;
    while (i < 100) : (i += 1) {
        try std.testing.expect(h.get(keys.items[i]) != null);
    }

    // Verify removed 50 are gone
    i = 0;
    while (i < 50) : (i += 1) {
        try std.testing.expect(h.get(keys.items[i]) == null);
    }
}

test "hamt: iterator basic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h = MyHamt.init();
    defer h.deinit(allocator);

    var list = FloatList.empty;
    defer list.deinit(allocator);
    try list.append(allocator, 1.0);

    try h.assocMut(allocator, "A", list);
    try h.assocMut(allocator, "B", list);
    try h.assocMut(allocator, "C", list);

    var it = h.iterator();
    var count: usize = 0;
    while (it.next()) |kv| {
        count += 1;
        // Basic check to ensure we get valid data back
        try std.testing.expect(kv.value.items.len == 1);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "hamt: iterator with collision bucket" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Force collisions
    const BadHashCtx = HashContext(K){
        .eql = strEql,
        .hash = struct {
            fn h(_: K) u32 {
                return 0;
            }
        }.h,
    };
    const BadHamt = Hamt(K, V, BadHashCtx, MyKVCtx);

    var h = BadHamt.init();
    defer h.deinit(allocator);

    var list = FloatList.empty;
    defer list.deinit(allocator); // template
    try list.append(allocator, 42.0);

    // Insert 3 colliding items
    try h.assocMut(allocator, "col1", list);
    try h.assocMut(allocator, "col2", list);
    try h.assocMut(allocator, "col3", list);

    var it = h.iterator();
    var count: usize = 0;
    var found_col1 = false;

    while (it.next()) |kv| {
        count += 1;
        if (std.mem.eql(u8, kv.key, "col1")) found_col1 = true;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(found_col1);
}

test "hamt: iterator massive stress test" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h = MyHamt.init();
    defer h.deinit(allocator);

    // Insert 100 items
    var keys = std.ArrayList([]const u8).empty;
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    var list = FloatList.empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "{d}", .{i});
        try keys.append(allocator, key);
        try h.assocMut(allocator, key, list);
    }

    // Iterate and count
    var it = h.iterator();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 100), count);
}
