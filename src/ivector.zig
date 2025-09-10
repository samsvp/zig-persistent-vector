const std = @import("std");
const RefCounter = @import("ref_counter.zig").RefCounter;

pub fn IVector(comptime T: type) type {
    return struct {
        items: []const T,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator, items: []const T) !Self {
            const owned_items = try gpa.dupe(T, items);
            return .{ .items = owned_items };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }

        pub fn update(self: Self, gpa: std.mem.Allocator, i: usize, val: T) !Self {
            var items = try gpa.dupe(T, self.items);
            items[i] = val;
            return .{ .items = items };
        }

        pub fn append(self: Self, gpa: std.mem.Allocator, val: T) !Self {
            const items = try gpa.alloc(T, self.items.len);
            @memcpy(items[0..self.items.len], self.items);
            items[items.len - 1] = val;
            return .{ .items = items };
        }

        pub fn remove(self: Self, gpa: std.mem.Allocator, idx: usize) !Self {
            const items = try gpa.alloc(T, self.items.len - 1);

            var i = 0;
            for (self.items) |item| {
                defer i += 1;
                if (i == idx) {
                    continue;
                }

                self.items[i] = item;
            }

            return .{ .items = items };
        }
    };
}
