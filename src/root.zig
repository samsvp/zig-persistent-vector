const std = @import("std");
const IVector = @import("pvector.zig").IVector;
const PVector = @import("pvector.zig").PVector;
const RefCounter = @import("ref_counter.zig").RefCounter;

test "basic add functionality" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }

    const allocator = gpa.allocator();

    const vs = [_]i32{1, 2, 3, 4};
    const s = try IVector(i32).init(allocator, &vs);

    var i = try RefCounter(IVector(i32)).init(allocator, s);
    var i_2 = try i.borrow();
    defer i_2.release(allocator);
    defer i.release(allocator);
    const v = try i.get();
    var v2 = try v.update(allocator, 1, 15);
    defer v2.deinit(allocator);
    std.debug.print("i {any}\n", .{v.items});
    std.debug.print("i {any}\n", .{v2.items});
}

test "pvector creation" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.print("WARNING: memory leaked\n", .{});
    }

    const allocator = gpa.allocator();

    const vs = [_]i32{1, 2, 3, 4};
    var pv = try PVector(i32).init(allocator, &vs);
    defer pv.deinit(allocator);

    std.debug.print("vs[0] {}\n", .{pv.get(0)});
}
