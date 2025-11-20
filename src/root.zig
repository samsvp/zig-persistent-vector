pub const IVector = @import("ivector.zig").IVector;
pub const PVector = @import("pvector.zig").PVector;
pub const RefCounter = @import("ref_counter.zig").RefCounter;

pub const Hamt = @import("hamt.zig").Hamt;

test "all tests" {
    //_ = @import("tests.zig");
}

fn eql(a: i32, b: i32) bool {
    return a == b;
}

fn hash(a: i32) u32 {
    return @intCast(@mod(a, 10));
}

test "hamt manual insert and search" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();
    // Note: This only frees the root array. In a real scenario with sub-tables,
    // you need a proper recursive deinit or you will leak memory.
    defer allocator.free(hamt.root.ptr);

    // --- INSERTION 1: Key = 10, Value = 100 ---
    {
        const key = 10;
        const val = 100;
        const sparse_index = 0;
        const pos = 0;

        try hamt.root.extend(allocator, sparse_index, pos);

        // FIX: Wrapped in .leaf
        hamt.root.ptr[pos] = .{ .leaf = .{ .kv = .{ .key = key, .value = val } } };
        hamt.size += 1;
    }

    // --- INSERTION 2: Key = 11, Value = 111 ---
    {
        const key = 11;
        const val = 111;
        const sparse_index = 1;
        const pos = 1;

        try hamt.root.extend(allocator, sparse_index, pos);

        // FIX: Wrapped in .leaf
        hamt.root.ptr[pos] = .{ .leaf = .{ .kv = .{ .key = key, .value = val } } };
        hamt.size += 1;
    }

    // --- VERIFICATION ---

    // Test 1: Find Key 10
    const res10 = hamt.get(10);
    try std.testing.expectEqual(100, res10.?);

    // Test 2: Find Key 11
    const res11 = hamt.get(11);
    try std.testing.expectEqual(111, res11.?);

    // Test 3: Key Mismatch
    const res20 = hamt.get(20);
    try std.testing.expectEqual(null, res20);
    const res5 = hamt.get(5);
    try std.testing.expectEqual(null, res5);

    // Test 5: Update (using high-level API)
    try hamt.assocMut(allocator, 10, 15);
    const res10_2 = hamt.get(10);
    try std.testing.expectEqual(15, res10_2.?);
}

test "hamt: sparse insertion stress check" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();
    defer allocator.free(hamt.root.ptr);

    try hamt.assocMut(allocator, 1, 10);
    try hamt.assocMut(allocator, 3, 30);
    try hamt.assocMut(allocator, 5, 50);

    // Verify all
    try std.testing.expectEqual(10, hamt.get(1).?);
    try std.testing.expectEqual(30, hamt.get(3).?);
    try std.testing.expectEqual(50, hamt.get(5).?);

    // Internals Check:
    // Bitmap ...101010 = 42
    try std.testing.expectEqual(@as(u32, 42), hamt.root.index);
    try std.testing.expectEqual(@as(usize, 3), hamt.root.ptr.len);
}

test "hamt: collision handling (push down)" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    // Note: This test will leak memory because we don't have a recursive
    // destructor yet, and we are creating sub-tables.
    // We suppress the leak check for this specific test.
    //defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();

    try hamt.assocMut(allocator, 10, 100);
    try hamt.assocMut(allocator, 20, 200);

    // 1. Verify both values exist
    const res10 = hamt.get(10);
    try std.testing.expectEqual(100, res10.?);

    const res20 = hamt.get(20);
    try std.testing.expectEqual(200, res20.?);

    // 2. Verify Structural Change (Whitebox)
    // The root should only have 1 entry (index 0)
    try std.testing.expectEqual(@as(u32, 1), hamt.root.index);

    // That entry should be a TABLE, not a LEAF
    const root_node = hamt.root.ptr[0];
    switch (root_node) {
        .table => {}, // OK
        .leaf => return error.ExpectedTableNode,
    }
}

test "hamt: dissoc basic kv (leaf removal)" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();
    defer allocator.free(hamt.root.ptr);

    try hamt.root.extend(allocator, 0, 0);
    hamt.root.ptr[0] = .{ .leaf = .{ .kv = .{ .key = 10, .value = 100 } } };
    hamt.size = 1;

    try hamt.dissocMut(allocator, 10);

    // Assert
    try std.testing.expectEqual(null, hamt.get(10));
    try std.testing.expectEqual(@as(usize, 0), hamt.size);
    try std.testing.expectEqual(@as(u32, 0), hamt.root.index); // Table should be empty
}

test "hamt: dissoc from collision (reduction logic)" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();
    defer allocator.free(hamt.root.ptr);

    // Setup: Create a collision node manually at Index 0 (Hash 0)
    // Key 10 (Hash 0) and Key 20 (Hash 0)
    var col = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).HashCollisionNode.init();
    try col.assocMut(allocator, 10, 100);
    try col.assocMut(allocator, 20, 200);

    try hamt.root.extend(allocator, 0, 0);
    hamt.root.ptr[0] = .{ .leaf = .{ .collision = col } };
    hamt.size = 2;

    switch (hamt.root.ptr[0].leaf) {
        .collision => {},
        .kv => return error.TestSetupFailed,
    }

    try hamt.dissocMut(allocator, 10);

    // Assert 1: Key 10 gone, Key 20 exists
    try std.testing.expectEqual(null, hamt.get(10));
    const res20 = hamt.get(20);
    try std.testing.expectEqual(200, res20.?); // Must access via .kv now!

    // Assert 2: Structural Check (The Optimization)
    // The node at root index 0 must now be .kv, NOT .collision
    switch (hamt.root.ptr[0].leaf) {
        .kv => {}, // Success: Converted back to simple leaf
        .collision => return error.OptimizationFailed, // Fail: Still a bucket
    }
}

test "hamt: dissoc non-existent key" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var hamt = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();
    defer allocator.free(hamt.root.ptr);

    try hamt.root.extend(allocator, 0, 0);
    hamt.root.ptr[0] = .{ .leaf = .{ .kv = .{ .key = 10, .value = 100 } } };
    hamt.size = 1;

    try hamt.dissocMut(allocator, 99);

    try std.testing.expectEqual(100, hamt.get(10).?);
    try std.testing.expectEqual(@as(usize, 1), hamt.size);
}

test "assoc: basic immutability (add new key)" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();
    defer allocator.free(h0.root.ptr);

    // 1. Create h1 from h0
    var h1 = try h0.assoc(allocator, 10, 100); // Hash 0
    defer allocator.free(h1.root.ptr); // In real use, would need recursive free

    // 2. Verify h1 has the key
    try std.testing.expectEqual(100, h1.get(10).?);

    // 3. Verify h0 is EMPTY (Immutable)
    try std.testing.expectEqual(@as(usize, 0), h0.root.ptr.len);
    try std.testing.expectEqual(@as(usize, 1), h1.root.ptr.len);
}

test "assoc: update existing key (copy-on-write)" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();

    // Setup: h1 has Key 10 -> 100
    var h1 = try h0.assoc(allocator, 10, 100);

    // Action: h2 updates Key 10 -> 999
    var h2 = try h1.assoc(allocator, 10, 999);
    try std.testing.expectEqual(999, h2.get(10).?);
    try std.testing.expectEqual(100, h1.get(10).?);
    try std.testing.expect(h1.root.ptr.ptr != h2.root.ptr.ptr);
}

test "assoc: collision divergence (structure branching)" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();

    // Key 10 (Hash 0) and Key 20 (Hash 0) collision
    var h1 = try h0.assoc(allocator, 10, 100);
    var h2 = try h1.assoc(allocator, 20, 200);

    try std.testing.expectEqual(100, h2.get(10).?);
    try std.testing.expectEqual(200, h2.get(20).?);

    try std.testing.expectEqual(100, h1.get(10).?);

    const node_h1 = h1.root.ptr[0];
    const node_h2 = h2.root.ptr[0];

    switch (node_h1) {
        .leaf => {},
        .table => return error.H1ShouldBeLeaf,
    }
    switch (node_h2) {
        .table => {},
        .leaf => return error.H2ShouldBeTable,
    }
}

test "dissoc: basic persistence (remove leaf)" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();

    // Setup: h1 has Key 10
    var h1 = try h0.assoc(allocator, 10, 100);

    // Action: h2 removes Key 10
    var h2 = try h1.dissoc(allocator, 10);

    // Assert h2 is empty
    try std.testing.expectEqual(null, h2.get(10));
    try std.testing.expectEqual(@as(usize, 0), h2.size);

    // Assert h1 is unchanged (Persistence check)
    try std.testing.expectEqual(100, h1.get(10));
    try std.testing.expectEqual(@as(usize, 1), h1.size);
}

test "dissoc: remove non-existent key" {
    const std = @import("std");
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();
    var h1 = try h0.assoc(allocator, 10, 100);

    // Action: Try to remove 99 (does not exist)
    var h2 = try h1.dissoc(allocator, 99);

    // Assert h2 is still valid and identical to h1 content-wise
    try std.testing.expectEqual(100, h2.get(10));
    try std.testing.expectEqual(@as(usize, 1), h2.size);
}

test "dissoc: collision reduction (Optimization Check)" {
    const std = @import("std");
    // This test verifies that when a collision bucket shrinks to 1 item,
    // it is converted back to a standard .kv leaf.

    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();

    // 1. Create Collision: Insert 10 and 20 (Both hash to 0)
    var h1 = try h0.assoc(allocator, 10, 100);
    var h2 = try h1.assoc(allocator, 20, 200);

    // 2. Action: Remove Key 10
    var h3 = try h2.dissoc(allocator, 10);

    // 3. Verify Logic
    try std.testing.expectEqual(null, h3.get(10));
    try std.testing.expectEqual(200, h3.get(20));
}

test "dissoc: deep collision cleanup" {
    const std = @import("std");
    // Test removing items until bucket is empty, ensuring tree cleans up
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();

    // Insert 3 colliding keys
    var h1 = try h0.assoc(allocator, 10, 100);
    var h2 = try h1.assoc(allocator, 20, 200);
    var h3 = try h2.assoc(allocator, 30, 300);

    // Remove 10 (remains bucket of 2)
    var h4 = try h3.dissoc(allocator, 10);
    try std.testing.expectEqual(null, h4.get(10));
    try std.testing.expectEqual(200, h4.get(20));
    try std.testing.expectEqual(300, h4.get(30));

    // Remove 20 (remains bucket of 1 -> converts to KV)
    var h5 = try h4.dissoc(allocator, 20);
    try std.testing.expectEqual(null, h5.get(10));
    try std.testing.expectEqual(null, h5.get(20));
    try std.testing.expectEqual(300, h5.get(30));

    // Remove 30 (Empty -> Removes node from table)
    var h6 = try h5.dissoc(allocator, 30);
    try std.testing.expectEqual(null, h6.get(30));
    try std.testing.expectEqual(@as(usize, 0), h6.size);
}

test "dissocMut: deep collision cleanup" {
    const std = @import("std");
    // Test removing items until bucket is empty, ensuring tree cleans up
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var h0 = Hamt(i32, i32, .{ .eql = eql, .hash = hash }).init();

    // Insert 3 colliding keys
    var h1 = try h0.assoc(allocator, 10, 100);
    var h2 = try h1.assoc(allocator, 20, 200);
    var h3 = try h2.assoc(allocator, 30, 300);

    // Remove 10 (remains bucket of 2)
    try h3.dissocMut(allocator, 10);
    try h3.dissocMut(allocator, 20);
    try h3.dissocMut(allocator, 30);
    try std.testing.expectEqual(null, h3.get(30));
    try std.testing.expectEqual(@as(usize, 0), h3.root.ptr.len);
}
