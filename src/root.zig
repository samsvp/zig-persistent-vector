const std = @import("std");
const Vector = @import("vector.zig").Vector;

test "update" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }

    const allocator = gpa.allocator();
    const data = [_]i32{ 1, 2, 3, 4, 5 };

    var vector = try Vector(i32).init(allocator, &data);
    defer vector.deinit(allocator);

    var new_vec = try vector.update(allocator, 3, 15);
    defer new_vec.deinit(allocator);

    for (0..data.len) |i| {
        const v = vector.get(i);
        try std.testing.expect(v == data[i]);
    }

    try std.testing.expect(new_vec.get(3) == 15);
}

test "basic add functionality" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }

    const allocator = gpa.allocator();
    const data_sizes = [_]usize{ 1, 2, 4, 7, 8, 9, 10, 11, 31, 32, 33, 50, 100, 255, 256, 257, 355, 480, 1000 };

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    for (data_sizes) |s| {
        const data = try allocator.alloc(i32, s);
        defer allocator.free(data);

        for (0..data.len) |i| {
            data[i] = rand.int(i32);
        }

        var vector = try Vector(i32).init(allocator, data);
        defer vector.deinit(allocator);
        for (0..data.len) |i| {
            const v = vector.get(i);
            try std.testing.expect(v == data[i]);
        }
    }
}
