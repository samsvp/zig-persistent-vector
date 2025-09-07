const std = @import("std");

pub fn Vector(comptime T: type) type {
    return struct {
        len: usize,
        nodes: Node,
        ref_count: usize = 1,

        const bits = 1;
        const width = 1 << bits;
        const mask = width - 1;

        const Node = union(enum) {
            node: [width]*Self,
            leaf: []const T,
        };

        const Self = @This();
        const empty = Self{
            .len = 0,
            .nodes = undefined,
            .ref_count = 0,
        };

        fn _init(
            gpa: std.mem.Allocator,
            data: []const T,
            bucket_index: usize,
            depth: usize,
            current_depth: usize,
        ) !*Self {
            const self = try gpa.create(Self);
            const len = data.len;
            const remainder = data.len % width;

            if (depth == current_depth) {
                const start_index = bucket_index * width;
                const end_index = if (len / width != bucket_index)
                    start_index + width
                else
                    start_index + width - remainder;

                const owned_data = try gpa.alloc(T, width);
                @memcpy(owned_data[0 .. end_index - start_index], data[start_index..end_index]);

                self.* = Self{
                    .nodes = .{ .leaf = owned_data },
                    .len = len,
                };
                return self;
            }

            var placeholder = empty;
            var nodes = [_]*Self{&placeholder} ** width;
            for (0..width) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, width, depth - current_depth - 1);
                if (new_bucket_index >= len / width + remainder) {
                    break;
                }
                nodes[i] = try _init(gpa, data, new_bucket_index, depth, current_depth + 1);
            }

            self.* = Self{
                .nodes = .{ .node = nodes },
                .len = len,
            };

            return self;
        }

        pub fn init(gpa: std.mem.Allocator, data: []const T) !*Self {
            const depth = std.math.log(usize, width, data.len);
            return _init(gpa, data, 0, depth, 0);
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            if (self.ref_count == 0) {
                return;
            }

            self.ref_count -= 1;
            if (self.ref_count > 0) {
                return;
            }

            switch (self.nodes) {
                .node => |ns| for (ns) |n| n.deinit(gpa),
                .leaf => |l| gpa.free(l),
            }
            gpa.destroy(self);
        }

        pub fn get(self: Self, i: usize) T {
            var node = self;
            const depth = std.math.log(usize, width, self.len);

            var level: u6 = @intCast(bits * depth);
            while (level > 0) : (level -= bits) {
                node = node.nodes.node[(i >> level) & mask].*;
            }

            return node.nodes.leaf[i % width];
        }
    };
}
