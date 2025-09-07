const std = @import("std");

pub fn Vector(comptime T: type) type {
    return struct {
        nodes: Node,
        depth: usize,
        ref_count: usize = 1,

        const bits = 1;
        const width = 1 << bits;
        const mask = width - 1;

        const Node = union(enum) {
            node: [width]?*Self,
            leaf: [width]T,
        };

        const Self = @This();

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
                    start_index + remainder;

                var owned_data: [width]T = undefined;
                for (start_index..end_index) |i| {
                    owned_data[i - start_index] = data[i];
                }

                self.* = Self{
                    .nodes = .{ .leaf = owned_data },
                    .depth = depth - current_depth,
                };
                return self;
            }

            var nodes = [_]?*Self{null} ** width;
            for (0..width) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, width, depth - current_depth - 1);
                if (new_bucket_index * width >= len) {
                    break;
                }
                nodes[i] = try _init(gpa, data, new_bucket_index, depth, current_depth + 1);
            }

            self.* = Self{
                .nodes = .{ .node = nodes },
                .depth = depth - current_depth,
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
            switch (self.nodes) {
                .node => |ns| for (ns) |maybe_n| if (maybe_n) |n| n.deinit(gpa),
                .leaf => {},
            }
            gpa.destroy(self);
        }

        pub fn get(self: Self, i: usize) T {
            var node = self;

            var level: u6 = @intCast(bits * self.depth);
            while (level > 0) : (level -= bits) {
                node = node.nodes.node[(i >> level) & mask].?.*;
            }

            return node.nodes.leaf[i % width];
        }

        pub fn update(self: *Self, gpa: std.mem.Allocator, i: usize, value: T) !*Self {
            const root = try gpa.create(Self);
            root.* = Self{
                .depth = self.depth,
                .nodes = .{ .node = [_]?*Self{null} ** width },
            };

            var r_node = root;
            var node = self;
            var level: u6 = @intCast(bits * self.depth);
            while (level > 0) : (level -= bits) {
                const target_idx = (i >> level) & mask;
                r_node.nodes = switch (node.nodes) {
                    .node => .{ .node = [_]?*Self{null} ** width },
                    .leaf => .{ .leaf = undefined },
                };
                for (0..width) |w| {
                    if (w == target_idx) {
                        const n = try gpa.create(Self);
                        var new_nodes: Node = undefined;
                        switch (node.nodes) {
                            .leaf => |leaf| {
                                new_nodes = Node{ .leaf = undefined };
                                for (0..leaf.len) |idx| {
                                    new_nodes.leaf[idx] = leaf[idx];
                                }
                            },
                            .node => |old_node| {
                                new_nodes = Node{ .node = undefined };
                                for (0..old_node.len) |idx| {
                                    new_nodes.node[idx] = old_node[idx];
                                }
                            },
                        }
                        n.* = Self{
                            .depth = node.depth,
                            .nodes = new_nodes,
                        };
                        r_node.nodes.node[w] = n;

                        continue;
                    }

                    switch (node.nodes) {
                        .node => |n| r_node.nodes.node[w] = n[w],
                        .leaf => |l| r_node.nodes.leaf[w] = l[w],
                    }
                    node.ref_count += 1;
                }
                node = node.nodes.node[target_idx].?;
                r_node = r_node.nodes.node[target_idx].?;
            }

            r_node.nodes = node.nodes;
            r_node.nodes.leaf[i % width] = value;
            return root;
        }
    };
}
