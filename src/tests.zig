const std = @import("std");
const IVector = @import("ivector.zig").IVector;
const MultiIVector = @import("ivector.zig").MultiIVector;
const PVector = @import("pvector.zig").PVector;
const RefCounter = @import("ref_counter.zig").RefCounter;

test "multi ivector" {
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

    const S2 = struct {
        field1: i32,
        field2: f32,
    };

    const S = struct {
        field1: i32,
        field2: f32,
        field3: S2,
    };

    var vs = [_]S{
        .{ .field1 = 1, .field2 = 10, .field3 = undefined },
        .{ .field1 = 5, .field2 = 125.155, .field3 = undefined },
        .{ .field1 = 89, .field2 = 95.5, .field3 = undefined },
        .{ .field1 = 102, .field2 = 10.0, .field3 = undefined },
        .{ .field1 = 4, .field2 = 257.0, .field3 = undefined },
    };
    for (0..vs.len) |i| {
        const update_val = S2{
            .field1 = rand.int(i32),
            .field2 = rand.float(f32),
        };
        vs[i].field3 = update_val;
    }

    var s = try MultiIVector(S).init(allocator, &vs);
    defer s.deinit(allocator);

    for (0..vs.len) |i| {
        try std.testing.expectEqual(vs[i].field1, s.getField(i, .field1));
        try std.testing.expectEqual(vs[i].field3.field1, s.getField(i, .field3).field1);
    }

    // update
    for (0..15) |_| {
        const update_index = rand.intRangeAtMost(usize, 0, vs.len - 1);
        const update_val_s = S2{
            .field1 = rand.int(i32),
            .field2 = rand.float(f32),
        };
        const update_val = S{
            .field1 = rand.int(i32),
            .field2 = rand.float(f32),
            .field3 = update_val_s,
        };
        var new_s = try s.update(allocator, update_index, update_val);
        defer new_s.deinit(allocator);
        for (0..vs.len) |i| {
            try std.testing.expectEqual(vs[i].field1, s.getField(i, .field1));
            const gt_new = if (i == update_index) update_val else vs[i];
            try std.testing.expectEqual(gt_new.field1, new_s.getField(i, .field1));
        }
    }

    // remove
    for (0..15) |_| {
        const remove_index = rand.intRangeAtMost(usize, 0, vs.len - 1);
        var new_s = try s.remove(allocator, remove_index);
        defer new_s.deinit(allocator);
        for (0..vs.len) |i| {
            try std.testing.expectEqual(vs[i].field1, s.getField(i, .field1));
        }

        for (0..vs.len - 1) |i| {
            const idx = if (i >= remove_index) i + 1 else i;
            try std.testing.expectEqual(vs[idx].field1, new_s.getField(i, .field1));
        }
    }

    // append
    for (0..15) |_| {
        const update_val_s = S2{
            .field1 = rand.int(i32),
            .field2 = rand.float(f32),
        };
        const update_val = S{
            .field1 = rand.int(i32),
            .field2 = rand.float(f32),
            .field3 = update_val_s,
        };
        var new_s = try s.append(allocator, update_val);
        defer new_s.deinit(allocator);
        for (0..vs.len) |i| {
            try std.testing.expectEqual(vs[i].field1, s.getField(i, .field1));
            try std.testing.expectEqual(vs[i].field1, new_s.getField(i, .field1));
        }
        try std.testing.expectEqual(update_val_s.field1, new_s.getField(vs.len, .field3).field1);
        try std.testing.expectEqual(new_s.len() - 1, s.len());
    }
}

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

test "ivector append remove" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }

    const allocator = gpa.allocator();

    const vs = [_]i32{ 1, 2, 3, 4 };
    var s = try IVector(i32).init(allocator, &vs);
    defer s.deinit(allocator);

    for (0..vs.len) |i| {
        const val: i32 = @intCast(i);
        var new_s = try s.append(allocator, val);
        defer new_s.deinit(allocator);

        try std.testing.expectEqual(4, s.items.len);

        for (0..new_s.items.len) |j| {
            const gt = if (j < vs.len) s.items[j] else val;
            try std.testing.expectEqual(gt, new_s.items[j]);
        }
    }

    for (0..vs.len) |i| {
        var new_s = try s.remove(allocator, i);
        defer new_s.deinit(allocator);

        try std.testing.expectEqual(4, s.items.len);

        var old_i: usize = 0;
        for (0..new_s.items.len) |j| {
            if (j == i) {
                old_i += 1;
            }

            const gt = s.items[old_i];
            try std.testing.expectEqual(gt, new_s.items[j]);
            old_i += 1;
        }
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

        const update_idx = rand.intRangeAtMost(usize, 0, data.len - 1);
        const new_val = rand.int(i32);

        var new_vec = try vector.update(allocator, update_idx, new_val);
        defer new_vec.deinit(allocator);

        for (0..data.len) |i| {
            const v0 = vector.get(i).*;
            try std.testing.expect(v0 == data[i]);

            const v1 = new_vec.get(i).*;
            const ground_truth = if (i != update_idx) data[i] else new_val;
            try std.testing.expect(v1 == ground_truth);
        }

        vector.deinit(allocator);

        for (0..data.len) |i| {
            const v1 = new_vec.get(i).*;
            const ground_truth = if (i != update_idx) data[i] else new_val;
            try std.testing.expect(v1 == ground_truth);
        }
    }
}

test "append" {
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

    const data_sizes = [_]usize{
        1,
        2,
        4,
        5,
        7,
        8,
        9,
        10,
        11,
        31,
        32,
        33,
        50,
        64,
        100,
        159,
        160,
        161,
        255,
        256,
        257,
        355,
        480,
        1000,
        1023,
        2560,
        32767,
        32768,
        32769,
        32799,
        32800,
        32801,
        32860,
        50000,
    };
    for (data_sizes) |s| {
        const data = try allocator.alloc(i32, s);
        defer allocator.free(data);

        for (0..data.len) |i| {
            data[i] = rand.int(i32);
        }

        var new_vec = try PVector(i32).init(allocator, data);
        defer new_vec.deinit(allocator);

        var new_vals: [5]i32 = undefined;
        for (0..5) |j| {
            new_vals[j] = rand.int(i32);
            const new_vec_tmp = try new_vec.append(allocator, new_vals[j]);
            new_vec.deinit(allocator);
            new_vec = new_vec_tmp;
        }

        for (0..data.len) |i| {
            const v1 = new_vec.get(i).*;
            const ground_truth = data[i];
            try std.testing.expect(v1 == ground_truth);
        }

        for (0..new_vals.len) |j| {
            const v1 = new_vec.get(s + j).*;
            const gt = new_vals[j];
            try std.testing.expect(v1 == gt);
        }
        try std.testing.expectEqual(s + 5, new_vec.len);
    }
}

test "remove" {
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

    const data_sizes = [_]usize{
        5,
        7,
        8,
        9,
        10,
        11,
        31,
        32,
        33,
        50,
        64,
        100,
        159,
        160,
        161,
        255,
        256,
        257,
        355,
        480,
        1000,
        1023,
        2560,
        32767,
        32768,
        32769,
        32799,
        32800,
        32801,
        32860,
        50000,
    };
    for (data_sizes) |s| {
        const data = try allocator.alloc(i32, s);
        defer allocator.free(data);

        for (0..data.len) |i| {
            data[i] = rand.int(i32);
        }

        var new_vec = try PVector(i32).init(allocator, data);
        defer new_vec.deinit(allocator);

        for (0..5) |_| {
            const new_vec_tmp = try new_vec.pop(allocator);
            new_vec.deinit(allocator);
            new_vec = new_vec_tmp;
        }

        for (0..data.len - 5) |i| {
            const v1 = new_vec.get(i).*;
            const ground_truth = data[i];
            try std.testing.expectEqual(v1, ground_truth);
        }

        try std.testing.expectEqual(s - 5, new_vec.len);
    }
}
