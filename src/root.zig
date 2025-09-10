const std = @import("std");
const IVector = @import("ivector.zig").IVector;
const PVector = @import("pvector.zig").PVector;
const RefCounter = @import("ref_counter.zig").RefCounter;

test "ivector" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }

    const allocator = gpa.allocator();

    const vs = [_]i32{ 1, 2, 3, 4 };
    const s = try IVector(i32).init(allocator, &vs);

    var i_1 = try RefCounter(IVector(i32)).init(allocator, s);
    var i_2 = try i_1.borrow();
    defer i_2.release(allocator);
    defer i_1.release(allocator);
    const v = try i_1.get();
    var v2 = try v.update(allocator, 1, 15);
    defer v2.deinit(allocator);
    for (0..vs.len) |i| {
        try std.testing.expect(v.items[i] == vs[i]);
        if (i != 1)
            try std.testing.expect(v2.items[i] == vs[i])
        else
            try std.testing.expect(v2.items[i] == 15);
    }
}

test "update" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }

    const allocator = gpa.allocator();
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    const data_sizes = [_]usize{ 1, 2, 4, 7, 8, 9, 10, 11, 31, 32, 33, 50, 64, 100, 159, 160, 161, 255, 256, 257, 355, 480, 1000, 1023 };
    for (data_sizes) |s| {
        const data = try allocator.alloc(i32, s);
        defer allocator.free(data);

        for (0..data.len) |i| {
            data[i] = rand.int(i32);
        }

        var vector = try PVector(i32).init(allocator, data);
        defer vector.deinit(allocator);

        const update_idx = rand.intRangeAtMost(usize, 0, data.len - 1);
        const new_val = rand.int(i32);

        var new_vec = try vector.update(allocator, update_idx, new_val);
        defer new_vec.deinit(allocator);

        for (0..data.len) |i| {
            const v0 = vector.get(i);
            try std.testing.expect(v0 == data[i]);

            const v1 = new_vec.get(i);
            if (i != update_idx)
                try std.testing.expect(v1 == data[i])
            else
                try std.testing.expect(v1 == new_val);
        }
    }
}
