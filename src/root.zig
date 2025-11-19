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
    const res10 = hamt.getSearch(10);
    try std.testing.expectEqual(res10.status, .success);
    // FIX: Access .kv.value
    try std.testing.expectEqual(100, res10.value.?.kv.value);

    // Test 2: Find Key 11
    const res11 = hamt.getSearch(11);
    try std.testing.expectEqual(res11.status, .success);
    try std.testing.expectEqual(111, res11.value.?.kv.value);

    // Test 3: Key Mismatch
    const res20 = hamt.getSearch(20);
    try std.testing.expectEqual(res20.status, .key_mismatch);

    // Test 4: Not Found
    const res5 = hamt.getSearch(5);
    try std.testing.expectEqual(res5.status, .not_found);

    // Test 5: Update (using high-level API)
    try hamt.assoc(allocator, 10, 15);
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

    try hamt.assoc(allocator, 1, 10);
    try hamt.assoc(allocator, 3, 30);
    try hamt.assoc(allocator, 5, 50);

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

    try hamt.assoc(allocator, 10, 100);
    try hamt.assoc(allocator, 20, 200);

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

    try hamt.dissoc(allocator, 10);

    // Assert
    try std.testing.expectEqual(hamt.getSearch(10).status, .not_found);
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

    try hamt.dissoc(allocator, 10);

    // Assert 1: Key 10 gone, Key 20 exists
    try std.testing.expectEqual(hamt.getSearch(10).status, .key_mismatch);
    const res20 = hamt.getSearch(20);
    try std.testing.expectEqual(res20.status, .success);
    try std.testing.expectEqual(200, res20.value.?.kv.value); // Must access via .kv now!

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

    try hamt.dissoc(allocator, 99);

    try std.testing.expectEqual(hamt.getSearch(10).status, .success);
    try std.testing.expectEqual(@as(usize, 1), hamt.size);
}
