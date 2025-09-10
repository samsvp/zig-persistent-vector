const std = @import("std");
const IVector = @import("ivector.zig").IVector;
const RefCounter = @import("ref_counter.zig").RefCounter;

pub fn PVector(comptime T: type) type {
    return struct {
        len: usize,
        depth: usize,
        node: RefCounter(*Node).Ref,

        pub const bits = 1;
        pub const width = 1 << bits;
        const mask = width - 1;

        const Self = @This();
        const Leaf = RefCounter(IVector(T)).Ref;
        const Branch = [width]RefCounter(*Node).Ref;

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
                    .branch => |*brs| for (0..brs.len) |i| brs[i].release(gpa),
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

                const end_index = if (len / width > bucket_index)
                    start_index + width
                else if (len / width < bucket_index)
                    start_index
                else
                    start_index + remainder;

                const leaf = if (start_index < len)
                    try IVector(T).init(gpa, data[start_index..end_index])
                else
                    IVector(T).empty;

                const leaf_ref = try RefCounter(IVector(T)).init(gpa, leaf);
                node_ptr.* = Node{
                    .kind = .{ .leaf = leaf_ref },
                };
                return node_ref;
            }

            var nodes = newBranch();
            for (0..width) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, width, depth - current_depth - 1);
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

        fn newBranch() Branch {
            return [_]RefCounter(*Node).Ref{undefined} ** width;
        }

        pub fn getLeaf(self: Self, i: usize) Leaf {
            var node = self.node.getUnwrap();

            var level: u6 = @intCast(bits * self.depth);
            while (level > 0) : (level -= bits) {
                node = node.kind.branch[(i >> level) & mask].getUnwrap();
            }

            return node.kind.leaf;
        }
        pub fn get(self: Self, i: usize) T {
            const leaf = self.getLeaf(i);
            return leaf.getUnwrap().items[i % width];
        }

        /// Returns a new vector with the passed value at index i. If i == self.len and the depth of the trie
        /// does not need to increase, then the value is added to the end of the new collection.
        pub fn update(self: *Self, gpa: std.mem.Allocator, i: usize, value: T) !Self {
            var curr_node = try gpa.create(Node);
            const curr_node_ref = try RefCounter(*Node).init(gpa, curr_node);

            const new_self = Self{
                .node = curr_node_ref,
                .depth = self.depth,
                .len = self.len,
            };

            var self_curr_node = self.node.getUnwrap();
            curr_node.* = self_curr_node.*;

            var level: u6 = @intCast(bits * self.depth);
            var branch_idx = (i >> level) & mask;
            while (curr_node.kind == .branch) : ({
                curr_node = curr_node.kind.branch[branch_idx].getUnwrap();
                self_curr_node = self_curr_node.kind.branch[branch_idx].getUnwrap();

                level -= bits;
                branch_idx = (i >> level) & mask;
            }) {
                var nodes = newBranch();
                for (0..width) |w| {
                    const branch = self_curr_node.kind.branch;
                    var node = branch[w];
                    if (w != branch_idx) {
                        nodes[w] = try node.borrow();
                        continue;
                    }

                    const new_node_ptr = try gpa.create(Node);
                    const kind = switch (node.getUnwrap().kind) {
                        .branch => NodeKind{ .branch = newBranch() },
                        .leaf => |l| NodeKind{ .leaf = l },
                    };
                    new_node_ptr.* = Node{ .kind = kind };
                    nodes[w] = try RefCounter(*Node).init(gpa, new_node_ptr);
                }
                curr_node.* = Node{ .kind = .{ .branch = nodes } };
            }

            const leaf = self_curr_node.kind.leaf;
            curr_node.* = Node{
                .kind = .{
                    .leaf = try Leaf.init(
                        gpa,
                        try leaf.getUnwrap().update(
                            gpa,
                            i % width,
                            value,
                        ),
                    ),
                },
            };
            return new_self;
        }

        pub fn appendAssumeCapacity(self: *Self, gpa: std.mem.Allocator, value: T) !Self {
            var curr_node = try gpa.create(Node);
            const curr_node_ref = try RefCounter(*Node).init(gpa, curr_node);

            const new_self = Self{
                .node = curr_node_ref,
                .depth = self.depth,
                .len = self.len + 1,
            };

            var self_curr_node = self.node.getUnwrap();
            curr_node.* = self_curr_node.*;

            var level: u6 = @intCast(bits * self.depth);
            const i = self.len;
            var branch_idx = (i >> level) & mask;
            while (curr_node.kind == .branch) : ({
                curr_node = curr_node.kind.branch[branch_idx].getUnwrap();
                self_curr_node = self_curr_node.kind.branch[branch_idx].getUnwrap();

                level -= bits;
                branch_idx = (i >> level) & mask;
            }) {
                var nodes = newBranch();
                for (0..width) |w| {
                    const branch = self_curr_node.kind.branch;
                    var node = branch[w];
                    if (w != branch_idx) {
                        nodes[w] = try node.borrow();
                        continue;
                    }

                    const new_node_ptr = try gpa.create(Node);
                    const kind = switch (node.getUnwrap().kind) {
                        .branch => NodeKind{ .branch = newBranch() },
                        .leaf => |l| NodeKind{ .leaf = l },
                    };
                    new_node_ptr.* = Node{ .kind = kind };
                    nodes[w] = try RefCounter(*Node).init(gpa, new_node_ptr);
                }
                curr_node.* = Node{ .kind = .{ .branch = nodes } };
            }

            const leaf = self_curr_node.kind.leaf;
            curr_node.* = Node{
                .kind = .{
                    .leaf = try Leaf.init(
                        gpa,
                        try leaf.getUnwrap().append(
                            gpa,
                            value,
                        ),
                    ),
                },
            };
            return new_self;
        }

        pub fn _grow(
            self: *Self,
            gpa: std.mem.Allocator,
            bucket_index: usize,
            current_depth: usize,
        ) !RefCounter(*Node).Ref {
            const node_ptr = try gpa.create(Node);
            const node_ref = try RefCounter(*Node).init(gpa, node_ptr);

            if (self.depth + 1 == current_depth) {
                const leaf = IVector(T).empty;

                const leaf_ref = try RefCounter(IVector(T)).init(gpa, leaf);
                node_ptr.* = Node{
                    .kind = .{ .leaf = leaf_ref },
                };
                return node_ref;
            }

            var nodes = newBranch();
            if (current_depth == 0) {
                nodes[0] = try self.node.borrow();
            }
            const start_idx: usize = if (current_depth == 0) 1 else 0;
            for (start_idx..width) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, width, self.depth - current_depth);
                nodes[i] = try self._grow(gpa, new_bucket_index, current_depth + 1);
            }

            node_ptr.* = Node{
                .kind = .{ .branch = nodes },
            };
            return node_ref;
        }

        pub fn append(self: *Self, gpa: std.mem.Allocator, value: T) !Self {
            // check if we need a new node
            if (self.len < std.math.pow(usize, width, self.depth + 1)) {
                return self.appendAssumeCapacity(gpa, value);
            }

            var root = Self{
                .node = try self._grow(gpa, 0, 0),
                .depth = self.depth + 1,
                .len = self.len,
            };
            defer root.deinit(gpa);

            return root.appendAssumeCapacity(gpa, value);
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.node.release(gpa);
        }
    };
}
