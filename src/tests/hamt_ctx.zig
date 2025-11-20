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
    try h.assocMut(allocator, "col2", list);
    try h.assocMut(allocator, "col3", list);
    try h.assocMut(allocator, "col2", list);

    try std.testing.expectEqual(100.0, h.get("col1").?.items[0]);
    try std.testing.expectEqual(100.0, h.get("col2").?.items[0]);

    try h.dissocMut(allocator, "col1");
    try std.testing.expect(h.get("col1") == null);
    try std.testing.expect(h.get("col2") != null);
}
