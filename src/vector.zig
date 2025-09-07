const std = @import("std");

pub fn Vector(comptime T: type) type {
    return struct {
        len: usize,
        node: Node,
        ref_count: usize = 1,

        const node_size = 2;

        const Node = union {
            node: [node_size]*const Node,
            leaf: []const T,
        };

        const Self = @This();

        fn _init(
            gpa: std.mem.Allocator,
            data: []const T,
            bucket_index: usize,
            len: usize,
            depth: usize,
            current_depth: usize,
        ) !*Self {
            const self = try gpa.create(Self);
            if (depth == current_depth) {
                const start_index = bucket_index * node_size;
                self.* = Self{
                    .node = .{ .leaf = data[start_index .. start_index + node_size] },
                    .len = len,
                };
                return self;
            }

            var nodes: [node_size]*Node = undefined;
            for (0..node_size) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, node_size, depth - current_depth - 1);
                if (new_bucket_index >= len / node_size) {
                    break;
                }
                const node = try _init(gpa, data, new_bucket_index, len, depth, current_depth + 1);
                nodes[i] = &node.node;
            }

            self.* = Self{
                .node = .{ .node = nodes },
                .len = len,
            };

            return self;
        }

        pub fn init(gpa: std.mem.Allocator, _data: []const T) !*Self {
            // pad data to contain the right number of nodes
            const remainder = _data.len % node_size;
            const len = if (remainder > 0) _data.len + node_size - remainder else _data.len;
            const data = try gpa.alloc(T, len);
            @memcpy(data[0.._data.len], _data);

            // init
            const depth = std.math.log(usize, node_size, data.len);
            return _init(gpa, data, 0, data.len, depth, 0);
        }

        pub fn get(self: Self, i: usize) T {
            var node = self.node;
            const depth = std.math.log(usize, node_size, self.len);
            const r_depth = std.math.pow(usize, node_size, depth);

            var d: i32 = 0;
            var curr_size = r_depth;
            while (curr_size > 1) : (curr_size /= node_size) {
                node = node.node[(i / curr_size) % node_size].*;
                d += 1;
            }

            return node.leaf[i % node_size];
        }
    };
}
