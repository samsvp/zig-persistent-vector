const std = @import("std");
const RefCounter = @import("ref_counter.zig").RefCounter;


pub fn IVector(comptime T:type) type {
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
            items[items.len-1] = val;
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

pub fn PVector(comptime T: type) type {
    return struct {
        len: usize,
        depth: usize,
        node: RefCounter(*Node).Ref,

        pub const bits = 5;
        pub const width = 1 << bits;
        const mask = width - 1;

        const Self = @This();
        const Leaf = RefCounter(IVector(T)).Ref;
        const Branch = [width]?RefCounter(*Node).Ref;

        const Node = struct {
            kind: NodeKind,

            pub fn deinit(self: *Node, gpa: std.mem.Allocator) void {
                self.kind.deinit(gpa);
                gpa.destroy(self);
            }
        };

        const NodeKind = union(enum) {
            branch: Branch,
            leaf: Leaf,

            pub fn deinit(self: *NodeKind, gpa: std.mem.Allocator) void {
                switch (self.*) {
                    .branch => |*brs| for (0..brs.len) |i| if (brs[i]) |*b| b.release(gpa),
                    .leaf => |*l| l.release(gpa),
                }
            }
        };

        fn _init(
            gpa: std.mem.Allocator,
            data: []const T,
            bucket_index: usize,
            depth: usize,
            current_depth: usize,
        ) !RefCounter(*Node).Ref {
            const node_ptr = try gpa.create(Node);
            const node_ref = try RefCounter(*Node).init(gpa, node_ptr);

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
                const leaf = try IVector(T).init(gpa, &owned_data);
                const leaf_ref = try RefCounter(IVector(T)).init(gpa, leaf);
                node_ptr.* = Node{
                    .kind = .{ .leaf = leaf_ref },
                };
                return node_ref;
            }

            var nodes = [_]?RefCounter(*Node).Ref{null} ** width;
            for (0..width) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, width, depth - current_depth - 1);
                if (new_bucket_index * width >= len) {
                    break;
                }
                nodes[i] = try _init(gpa, data, new_bucket_index, depth, current_depth + 1);
            }

            node_ptr.* = Node{
                .kind = .{ .branch = nodes },
            };
            return node_ref;
        }

        pub fn init(gpa: std.mem.Allocator, data: []const T) !Self {
            const depth = std.math.log(usize, width, data.len);
            return Self{
                .node = try _init(gpa, data, 0, depth, 0),
                .depth = depth,
                .len = data.len,
            };
        }

        fn getLeaf(self: Self, i: usize) Leaf {
            var node = self.node.getUnwrap();

            var level: u6 = @intCast(bits * self.depth);
            while (level > 0) : (level -= bits) {
                node = node.kind.branch[(i >> level) & mask].?.getUnwrap();
            }

            return node.kind.leaf.getUnwrap();
        }

        pub fn get(self: Self, i: usize) T {
            const leaf = self.getLeaf(i);
            return leaf.items[i % width];
        }

        /// Returns a new vector with the passed value at index i. If i == self.len and the depth of the trie
        /// does not need to increase, then the value is added to the end of the new collection.
        pub fn update(self: *Self, gpa: std.mem.Allocator, i: usize, value: T) !Self {
            const node_ptr = try gpa.create(Node);
            const node_ref = try RefCounter(*Node).init(gpa, node_ptr);

            var nodes = [_]?RefCounter(*Node).Ref{null} ** width;
            const new_self = Self{
                .node = nodes,
                .depth = self.depth,
                .len = self.len,
            };

            var level: u6 = @intCast(bits * self.depth);
            var branch_idx = (i >> level) & mask;
            while (level > 0) : (level -= bits) {
                branch_idx = (i >> level) & mask;

                for (0..width) |w| {
                    const node = nodes[w];
                    if (w != branch_idx) {
                        nodes[w] = if (node) |n| n.borrow() orelse null;
                        continue;
                    }

                    const new_node_ptr = try gpa.create(Node);
                    const kind = switch (node.kind) {
                        .branch => [_]?RefCounter(*Node).Ref{null} ** width,
                        .leaf => |l| l,
                    };
                    new_node_ptr.* = Node{
                        .kind = kind
                    };
                    nodes[w] = new_node_ptr;
                }

                const node = nodes[branch_idx].?.getUnwrap();
                if (node.kind == .branch) {
                    nodes = node.kind.branch;
                }
            }
            const new_leaf = nodes[branch_idx].?.getUnwrap().kind.leaf.getUnwrap().update(gpa, i, value);
            node.kind = .{ .leaf = Leaf.init(gpa, new_leaf) };
            return new_self;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.node.release(gpa);
        }
    };
}
