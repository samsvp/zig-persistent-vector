const std = @import("std");
pub const KVContext = @import("../hamt.zig").KVContext;
pub const Hamt = @import("../hamt.zig").Hamt;

fn eql(a: i32, b: i32) bool {
    return a == b;
}

fn hash(a: i32) u32 {
    return @intCast(@mod(a, 10));
}

const default_kv_ctx = KVContext(i32, i32).default();

test "hamt: manual insert and search" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer hamt.deinit(allocator);

    try hamt.assocMut(allocator, 10, 100);
    try hamt.assocMut(allocator, 11, 111);

    const res10 = hamt.get(10);
    try std.testing.expectEqual(100, res10.?);

    const res11 = hamt.get(11);
    try std.testing.expectEqual(111, res11.?);

    const res20 = hamt.get(20);
    try std.testing.expectEqual(null, res20);
    const res5 = hamt.get(5);
    try std.testing.expectEqual(null, res5);

    try hamt.assocMut(allocator, 10, 15);
    const res10_2 = hamt.get(10);
    try std.testing.expectEqual(15, res10_2.?);
}

test "hamt: sparse insertion stress check" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer hamt.deinit(allocator);

    try hamt.assocMut(allocator, 1, 10);
    try hamt.assocMut(allocator, 3, 30);
    try hamt.assocMut(allocator, 5, 50);

    try std.testing.expectEqual(10, hamt.get(1).?);
    try std.testing.expectEqual(30, hamt.get(3).?);
    try std.testing.expectEqual(50, hamt.get(5).?);

    try std.testing.expectEqual(42, hamt.root.index);
    try std.testing.expectEqual(3, hamt.root.ptr.len);
}

test "hamt: collision handling (push down)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer hamt.deinit(allocator);

    try hamt.assocMut(allocator, 10, 100);
    try hamt.assocMut(allocator, 20, 200);

    const res10 = hamt.get(10);
    try std.testing.expectEqual(100, res10.?);

    const res20 = hamt.get(20);
    try std.testing.expectEqual(200, res20.?);

    try std.testing.expectEqual(1, hamt.root.index);

    const root_node_kind = hamt.root.ptr[0].getUnwrap().kind;
    switch (root_node_kind) {
        .table => {},
        .leaf => return error.ExpectedTableNode,
    }
}

test "hamt: dissoc basic kv (leaf removal)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer hamt.deinit(allocator);

    try hamt.assocMut(allocator, 10, 100);

    try hamt.dissocMut(allocator, 10);

    try std.testing.expectEqual(null, hamt.get(10));
    try std.testing.expectEqual(0, hamt.size);
    try std.testing.expectEqual(0, hamt.root.index);
}

test "hamt: dissoc from collision (reduction logic)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer hamt.deinit(allocator);

    // Setup: Create collision
    try hamt.assocMut(allocator, 10, 100);
    try hamt.assocMut(allocator, 20, 200);

    try hamt.dissocMut(allocator, 10);

    try std.testing.expectEqual(null, hamt.get(10));
    const res20 = hamt.get(20);
    try std.testing.expectEqual(200, res20.?);
}

test "hamt: dissoc non-existent key" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer hamt.deinit(allocator);

    try hamt.assocMut(allocator, 10, 100);

    try hamt.dissocMut(allocator, 99);

    try std.testing.expectEqual(100, hamt.get(10).?);
    try std.testing.expectEqual(@as(usize, 1), hamt.size);
}

test "assoc: basic immutability (add new key)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h0.deinit(allocator);

    var h1 = try h0.assoc(allocator, 10, 100);
    defer h1.deinit(allocator); // REQUIRED: Release h1's references

    try std.testing.expectEqual(100, h1.get(10).?);

    try std.testing.expectEqual(@as(usize, 0), h0.root.ptr.len);
    try std.testing.expectEqual(@as(usize, 1), h1.root.ptr.len);
}

test "assoc: update existing key (copy-on-write)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h0.deinit(allocator);

    var h1 = try h0.assoc(allocator, 10, 100);
    defer h1.deinit(allocator);

    var h2 = try h1.assoc(allocator, 10, 999);
    defer h2.deinit(allocator);

    try std.testing.expectEqual(999, h2.get(10).?);
    try std.testing.expectEqual(100, h1.get(10).?);

    try std.testing.expect(h1.root.ptr.ptr != h2.root.ptr.ptr);
}

test "assoc: collision divergence (structure branching)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h0.deinit(allocator);

    // Key 10 (Hash 0) and Key 20 (Hash 0) collision
    var h1 = try h0.assoc(allocator, 10, 100);
    defer h1.deinit(allocator);

    var h2 = try h1.assoc(allocator, 20, 200);
    defer h2.deinit(allocator);

    try std.testing.expectEqual(100, h2.get(10).?);
    try std.testing.expectEqual(200, h2.get(20).?);

    try std.testing.expectEqual(100, h1.get(10).?);

    const node_h1_kind = h1.root.ptr[0].getUnwrap().kind;
    const node_h2_kind = h2.root.ptr[0].getUnwrap().kind;

    switch (node_h1_kind) {
        .table => {},
        .leaf => {},
    }
    switch (node_h2_kind) {
        .table => {},
        .leaf => {},
    }
}

test "dissoc: basic persistence (remove leaf)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h0.deinit(allocator);

    // Setup: h1 has Key 10
    var h1 = try h0.assoc(allocator, 10, 100);
    defer h1.deinit(allocator);

    // Action: h2 removes Key 10
    var h2 = try h1.dissoc(allocator, 10);
    defer h2.deinit(allocator);

    // Assert h2 is empty
    try std.testing.expectEqual(null, h2.get(10));
    try std.testing.expectEqual(@as(usize, 0), h2.size);

    // Assert h1 is unchanged (Persistence check)
    try std.testing.expectEqual(100, h1.get(10));
    try std.testing.expectEqual(@as(usize, 1), h1.size);
}

test "dissoc: remove non-existent key" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h0.deinit(allocator);

    var h1 = try h0.assoc(allocator, 10, 100);
    defer h1.deinit(allocator);

    // Action: Try to remove 99 (does not exist)
    var h2 = try h1.dissoc(allocator, 99);
    defer h2.deinit(allocator);

    // Assert h2 is still valid and identical to h1 content-wise
    try std.testing.expectEqual(100, h2.get(10));
    try std.testing.expectEqual(@as(usize, 1), h2.size);
}

test "dissoc: collision reduction (Optimization Check)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h0.deinit(allocator);

    var h1 = try h0.assoc(allocator, 10, 100);
    defer h1.deinit(allocator);

    var h2 = try h1.assoc(allocator, 20, 200);
    defer h2.deinit(allocator);

    var h3 = try h2.dissoc(allocator, 10);
    defer h3.deinit(allocator);

    try std.testing.expectEqual(null, h3.get(10));
    try std.testing.expectEqual(200, h3.get(20));
}

test "dissoc: deep collision cleanup" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h0.deinit(allocator);

    // Insert 3 colliding keys
    var h1 = try h0.assoc(allocator, 10, 100);
    defer h1.deinit(allocator);

    var h2 = try h1.assoc(allocator, 20, 200);
    defer h2.deinit(allocator);

    var h3 = try h2.assoc(allocator, 30, 300);
    defer h3.deinit(allocator);

    var h4 = try h3.dissoc(allocator, 10);
    defer h4.deinit(allocator);
    try std.testing.expectEqual(null, h4.get(10));
    try std.testing.expectEqual(200, h4.get(20));
    try std.testing.expectEqual(300, h4.get(30));

    var h5 = try h4.dissoc(allocator, 20);
    defer h5.deinit(allocator);
    try std.testing.expectEqual(null, h5.get(10));
    try std.testing.expectEqual(null, h5.get(20));
    try std.testing.expectEqual(300, h5.get(30));

    // Remove 30 (Empty)
    var h6 = try h5.dissoc(allocator, 30);
    defer h6.deinit(allocator);
    try std.testing.expectEqual(null, h6.get(30));
    try std.testing.expectEqual(@as(usize, 0), h6.size);
    // Root should be empty table
    try std.testing.expectEqual(@as(usize, 0), h6.root.ptr.len);
}

test "dissocMut: deep collision cleanup" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h3 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    defer h3.deinit(allocator);

    // Insert 3 colliding keys
    try h3.assocMut(allocator, 10, 100);
    try h3.assocMut(allocator, 20, 200);
    try h3.assocMut(allocator, 30, 300);

    try h3.dissocMut(allocator, 10);
    try h3.dissocMut(allocator, 20);
    try h3.dissocMut(allocator, 30);

    try std.testing.expectEqual(null, h3.get(30));
    try std.testing.expectEqual(@as(usize, 0), h3.root.ptr.len);
}

test "ref_counting: data survives parent deinit (shared leaf)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var h1 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    try h1.assocMut(allocator, 10, 100); // Hash 0

    // h2 should share the node for Key 10 with h1
    var h2 = try h1.assoc(allocator, 11, 111); // Hash 1
    defer h2.deinit(allocator);

    // If reference counting is broken, this might free the node for Key 10
    h1.deinit(allocator);

    // It should still be able to access Key 10 (shared) and Key 11 (new)
    try std.testing.expectEqual(100, h2.get(10).?);
    try std.testing.expectEqual(111, h2.get(11).?);
}

test "ref_counting: structural sharing stress test" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Create Root (h1) with keys in different slots
    var h1 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }, default_kv_ctx).init();
    try h1.assocMut(allocator, 1, 10);
    try h1.assocMut(allocator, 2, 20);
    try h1.assocMut(allocator, 3, 30);

    // 2. Create Branch A (h2) -> Modifies Key 1
    // Should clone path to 1, but share branches for 2 and 3
    var h2 = try h1.assoc(allocator, 1, 999);

    // 3. Create Branch B (h3) -> Adds Key 4
    // Should share branches 1, 2, 3 with h1
    var h3 = try h1.assoc(allocator, 4, 40);
    defer h3.deinit(allocator);

    h1.deinit(allocator);

    try std.testing.expectEqual(999, h2.get(1).?);
    try std.testing.expectEqual(20, h2.get(2).?);
    try std.testing.expectEqual(30, h2.get(3).?);
    try std.testing.expectEqual(null, h2.get(4));

    h2.deinit(allocator);

    // 6. Verify Branch B (h3)
    // Key 1 should be the OLD value (shared from h1)
    try std.testing.expectEqual(10, h3.get(1).?);
    try std.testing.expectEqual(40, h3.get(4).?);
}
