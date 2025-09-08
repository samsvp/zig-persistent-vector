const std = @import("std");

pub fn Vector(comptime T: type) type {
    return struct {
        len: usize,
        nodes: Node,
        depth: usize,
        ref_count: usize = 1,

        pub const bits = 5;
        pub const width = 1 << bits;
        const mask = width - 1;

        const Node = union(enum) {
            branch: [width]?*Self,
            leaf: []T,
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

                var owned_data = try gpa.alloc(T, width);
                for (start_index..end_index) |i| {
                    owned_data[i - start_index] = data[i];
                }

                self.* = Self{
                    .nodes = .{ .leaf = owned_data },
                    .depth = depth - current_depth,
                    .len = data.len,
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
                .nodes = .{ .branch = nodes },
                .depth = depth - current_depth,
                .len = data.len,
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
                .branch => |ns| for (ns) |maybe_n| if (maybe_n) |n| n.deinit(gpa),
                .leaf => |l| gpa.free(l),
            }
            if (self.ref_count == 0) {
                gpa.destroy(self);
            }
        }

        pub fn get(self: Self, i: usize) T {
            var node = self;

            var level: u6 = @intCast(bits * self.depth);
            while (level > 0) : (level -= bits) {
                node = node.nodes.branch[(i >> level) & mask].?.*;
            }

            return node.nodes.leaf[i % width];
        }

        /// Returns a new vector with the passed value at index i. If i == self.len and the depth of the trie
        /// does not need to increase, then the value is added to the end of the new collection.
        pub fn update(self: *Self, gpa: std.mem.Allocator, i: usize, value: T) !*Self {
            const root = try gpa.create(Self);
            root.* = Self{
                .depth = self.depth,
                .nodes = undefined,
                .len = if (i == self.len) self.len + 1 else self.len,
            };

            var r_node = root;
            var node = self;
            var level: u6 = @intCast(bits * self.depth);
            while (level > 0) : (level -= bits) {
                r_node.nodes = node.nodes;

                const target_idx = (i >> level) & mask;
                for (0..width) |w| {
                    if (w != target_idx) {
                        if (node != self) {
                            node.ref_count += 1;
                        }
                        continue;
                    }

                    const new_node = try gpa.create(Self);
                    // create new node if target node is null
                    if (node.nodes.branch[target_idx] == null) {
                        const nodes = if (level - bits > 0)
                            Node{ .branch = [_]?*Self{null} ** width }
                        else
                            Node{ .leaf = undefined };

                        new_node.* = Self{
                            .nodes = nodes,
                            .depth = 0,
                            .len = self.len + 1,
                        };
                        node.nodes.branch[target_idx] = new_node;
                    } else {
                        new_node.* = Self{
                            .depth = node.depth,
                            .nodes = node.nodes,
                            .len = root.len,
                        };
                    }

                    r_node.nodes.branch[w] = new_node;
                }

                node = node.nodes.branch[target_idx].?;
                r_node = r_node.nodes.branch[target_idx].?;
            }

            r_node.nodes = node.nodes;
            r_node.nodes.leaf[i % width] = value;
            return root;
        }

        pub fn append(self: *Self, gpa: std.mem.Allocator, value: T) !*Self {
            // check if we need a new node
            if (self.len < std.math.pow(usize, width, self.depth + 1)) {
                return self.update(gpa, self.len, value);
            }

            var nodes = [_]?*Self{null} ** width;
            nodes[0] = self;
            self.ref_count += 1;

            var root = Self{
                .nodes = .{ .branch = nodes },
                .depth = self.depth + 1,
                .len = self.len,
            };

            return root.update(gpa, self.len, value);
        }
    };
}
