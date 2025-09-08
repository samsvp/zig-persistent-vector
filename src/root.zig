const std = @import("std");
const Vector = @import("vector.zig").Vector;

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

    const data_sizes = [_]usize{ 1, 2, 4, 7, 8, 9, 10, 11, 31, 32, 33, 50, 100, 255, 256, 257, 355, 480, 1000 };
    for (data_sizes) |s| {
        const data = try allocator.alloc(i32, s);
        defer allocator.free(data);

        for (0..data.len) |i| {
            data[i] = rand.int(i32);
        }
        var vector = try Vector(i32).init(allocator, data);

        const update_idx = rand.intRangeAtMost(usize, 0, data.len);
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

        const new_val2 = rand.int(i32);
        const new_val3 = rand.int(i32);

        var new_vec2 = try vector.append(allocator, new_val2);
        defer new_vec2.deinit(allocator);

        var new_vec3 = try vector.append(allocator, new_val3);
        defer new_vec3.deinit(allocator);

        vector.deinit(allocator);

        for (0..data.len) |i| {
            const v0 = new_vec2.get(i);
            try std.testing.expect(v0 == data[i]);
        }

        try std.testing.expect(new_vec2.get(new_vec2.len - 1) == new_val2);
        try std.testing.expect(new_vec3.get(new_vec3.len - 1) == new_val3);

        const new_val4 = rand.int(i32);
        var new_vec4 = try new_vec2.append(allocator, new_val4);
        defer new_vec4.deinit(allocator);

        try std.testing.expect(new_vec4.get(new_vec2.len - 1) == new_val2);
        try std.testing.expect(new_vec4.get(new_vec4.len - 1) == new_val4);
    }
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
