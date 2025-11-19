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

    defer allocator.free(hamt.root.ptr);

    // --- INSERTION 1: Key = 10, Value = 100 ---
    // Hash(10) is 0 (based on your mock hash: 10 % 10).
    // The sparse index (bit index) for hash 0 at depth 0 is 0.
    // The root is empty, so the physical position (popcount) is 0.
    {
        const key = 10;
        const val = 100;
        const sparse_index = 0;
        const pos = 0;

        // Allocate space
        try hamt.root.extend(allocator, sparse_index, pos);

        // Manually populate the node (extend only creates space, it leaves it undefined)
        hamt.root.ptr[pos] = .{ .kv = .{ .key = key, .value = val } };
        hamt.size += 1;
    }

    // --- INSERTION 2: Key = 11, Value = 111 ---
    // Hash(11) is 1.
    // The sparse index is 1.
    // The root currently has bit 0 set.
    // Mask for index 1 is (1<<1) - 1 = 1.
    // Popcount(bitmap & mask) -> Popcount(1 & 1) -> 1.
    // So physical position is 1.
    {
        const key = 11;
        const val = 111;
        const sparse_index = 1;
        const pos = 1;

        try hamt.root.extend(allocator, sparse_index, pos);
        hamt.root.ptr[pos] = .{ .kv = .{ .key = key, .value = val } };
        hamt.size += 1;
    }

    // --- VERIFICATION ---

    // Test 1: Find Key 10
    const res10 = hamt.get(10);
    try std.testing.expectEqual(res10.status, .success);
    try std.testing.expectEqual(res10.value.?.*, 100);

    // Test 2: Find Key 11
    const res11 = hamt.get(11);
    try std.testing.expectEqual(res11.status, .success);
    try std.testing.expectEqual(res11.value.?.*, 111);

    // Test 3: Key Mismatch (Search for 20, which hashes to 0, same as key 10)
    // This tests that we actually check equality, not just hash presence.
    const res20 = hamt.get(20);
    try std.testing.expectEqual(res20.status, .key_mismatch);

    // Test 4: Not Found (Search for 5, which hashes to 5. Bit 5 is not set in root)
    const res5 = hamt.get(5);
    try std.testing.expectEqual(res5.status, .not_found);
}
