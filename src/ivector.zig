const std = @import("std");
const RefCounter = @import("ref_counter.zig").RefCounter;

pub fn IVector(comptime T: type) type {
    return struct {
        items: []const T,

        const Self = @This();

        pub const empty = Self{ .items = &[_]T{} };

        pub fn init(gpa: std.mem.Allocator, items: []const T) !Self {
            const owned_items = try gpa.dupe(T, items);
            return .{ .items = owned_items };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }

        pub fn len(self: Self) usize {
            return self.items.len;
        }

        pub fn get(self: Self, i: usize) T {
            return self.items[i];
        }

        pub fn update(self: Self, gpa: std.mem.Allocator, i: usize, val: T) !Self {
            var items = try gpa.dupe(T, self.items);
            items[i] = val;
            return .{ .items = items };
        }

        pub fn append(self: Self, gpa: std.mem.Allocator, val: T) !Self {
            const items = try gpa.alloc(T, self.items.len + 1);
            @memcpy(items[0..self.items.len], self.items);
            items[items.len - 1] = val;
            return .{ .items = items };
        }

        pub fn remove(self: Self, gpa: std.mem.Allocator, idx: usize) !Self {
            var items = try gpa.alloc(T, self.items.len - 1);

            var items_idx: usize = 0;
            for (0..self.items.len) |i| {
                if (i == idx) {
                    continue;
                }

                items[items_idx] = self.items[i];
                items_idx += 1;
            }

            return .{ .items = items };
        }

        pub fn swapRemove(self: Self, gpa: std.mem.Allocator, idx: usize) !Self {
            var items = try gpa.alloc(T, self.items.len - 1);

            for (0..self.items.len) |i| {
                const item = if (i == idx) self.items[items.len] else self.items[i];
                items[i] = item;
            }

            return .{ .items = items };
        }
    };
}

pub fn MultiIVector(comptime T: type) type {
    return struct {
        array: std.MultiArrayList(T),

        const Self = @This();

        pub const empty = Self{ .array = .empty };

        pub const Field = std.MultiArrayList(T).Field;
        pub fn FieldType(comptime field: Field) type {
            return @FieldType(T, @tagName(field));
        }

        pub fn init(gpa: std.mem.Allocator, items: []const T) !Self {
            var array: std.MultiArrayList(T) = .empty;
            try array.ensureUnusedCapacity(gpa, items.len);
            for (items) |i| {
                array.appendAssumeCapacity(i);
            }
            return .{ .array = array };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.array.deinit(gpa);
        }

        pub fn len(self: Self) usize {
            return self.array.len;
        }

        pub fn update(self: Self, gpa: std.mem.Allocator, i: usize, val: T) !Self {
            var clone_array = try self.array.clone(gpa);
            clone_array.set(i, val);
            return .{ .array = clone_array };
        }

        pub fn get(self: Self, i: usize) T {
            return self.array.slice().get(i);
        }

        pub fn getField(self: Self, i: usize, comptime field: Field) *const FieldType(field) {
            return &self.array.items(field)[i];
        }

        pub fn append(self: Self, gpa: std.mem.Allocator, val: T) !Self {
            var clone_array = try self.array.clone(gpa);
            try clone_array.append(gpa, val);
            return .{ .array = clone_array };
        }

        pub fn remove(self: Self, gpa: std.mem.Allocator, idx: usize) !Self {
            var clone_array = try self.array.clone(gpa);
            clone_array.orderedRemove(idx);
            return .{ .array = clone_array };
        }

        pub fn swapRemove(self: Self, gpa: std.mem.Allocator, idx: usize) !Self {
            var clone_array = try self.array.clone(gpa);
            clone_array.swapRemove(idx);
            return .{ .array = clone_array };
        }
    };
}
