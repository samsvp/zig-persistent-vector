const std = @import("std");

pub fn Vector(comptime T: type) type {
    return struct {
        len: usize,
        nodes: Node,
        ref_count: usize = 1,

        const node_size = 2;

        const Node = union(enum) {
            node: [node_size]*Self,
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
            const remainder = data.len % node_size;

            if (depth == current_depth) {
                const start_index = bucket_index * node_size;
                const end_index = if (len / node_size != bucket_index)
                    start_index + node_size
                else
                    start_index + node_size - remainder;

                const owned_data = try gpa.alloc(T, node_size);
                @memcpy(owned_data[0 .. end_index - start_index], data[start_index..end_index]);

                self.* = Self{
                    .nodes = .{ .leaf = owned_data },
                    .len = len,
                };
                return self;
            }

            var placeholder = empty;
            var nodes = [_]*Self{&placeholder} ** node_size;
            for (0..node_size) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, node_size, depth - current_depth - 1);
                if (new_bucket_index >= len / node_size + remainder) {
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
            const depth = std.math.log(usize, node_size, data.len);
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
            const depth = std.math.log(usize, node_size, self.len);
            const r_depth = std.math.pow(usize, node_size, depth);

            var node = self;
            var d: i32 = 0;
            var curr_size = r_depth;
            while (curr_size > 1) : (curr_size /= node_size) {
                node = node.nodes.node[(i / curr_size) % node_size].*;
                d += 1;
            }

            return node.nodes.leaf[i % node_size];
        }
    };
}
