const std = @import("std");
const config = @import("config");
const IVector = @import("ivector.zig").IVector;
const MultiIVector = @import("ivector.zig").MultiIVector;
const RefCounter = @import("ref_counter.zig").RefCounter;

pub fn PVector(comptime T: type, comptime Vec: fn (type) type) type {
    return struct {
        len: usize,
        depth: usize,
        node: RefCounter(*Node).Ref,

        pub const bits = config.bits;
        pub const width = 1 << bits;
        const mask = width - 1;

        const VecT = Vec(T);
        const Self = @This();
        const Leaf = RefCounter(VecT).Ref;
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

                const leaf = if (start_index < len) blk: {
                    const end_index =
                        if (len / width > bucket_index)
                            start_index + width
                        else if (len / width == bucket_index)
                            start_index + remainder
                        else
                            start_index;

                    break :blk try VecT.init(gpa, data[start_index..end_index]);
                } else VecT.empty;

                const leaf_ref = try RefCounter(VecT).init(gpa, leaf);
                node_ptr.* = Node{ .kind = .{ .leaf = leaf_ref } };
                return node_ref;
            }

            var nodes = newBranch();
            for (0..width) |i| {
                const new_bucket_index = bucket_index + i * std.math.pow(usize, width, depth - current_depth - 1);
                nodes[i] = try _init(gpa, data, new_bucket_index, depth, current_depth + 1);
            }

            node_ptr.* = Node{ .kind = .{ .branch = nodes } };
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

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.node.release(gpa);
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
            const leaf = self.getLeaf(i).getUnwrap();
            return leaf.get(i % width);
        }

        /// Copies the path to the leaf corresponding to the index i.
        fn clonePath(
            self: *Self,
            gpa: std.mem.Allocator,
            i: usize,
        ) !struct {
            self: Self,
            tail_node: *Node,
            leaf: Leaf,
        } {
            var curr_node = try gpa.create(Node);
            const curr_node_ref = try RefCounter(*Node).init(gpa, curr_node);

            const new_self = Self{
                .node = curr_node_ref,
                .depth = self.depth,
                .len = self.len,
            };

            var self_curr_node = self.node.getUnwrap();
            curr_node.* = self_curr_node.*;

            var level: u6 = @intCast(bits * (self.depth + 1));
            var branch_idx = (i >> level) & mask;
            while (curr_node.kind == .branch) {
                level -= bits;
                branch_idx = (i >> level) & mask;

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

                curr_node = curr_node.kind.branch[branch_idx].getUnwrap();
                self_curr_node = self_curr_node.kind.branch[branch_idx].getUnwrap();
            }

            return .{
                .self = new_self,
                .tail_node = curr_node,
                .leaf = self_curr_node.kind.leaf,
            };
        }

        /// Returns a new vector with the passed value at index i. If i == self.len and the depth of the trie
        /// does not need to increase, then the value is added to the end of the new collection.
        pub fn update(self: *Self, gpa: std.mem.Allocator, i: usize, value: T) !Self {
            var clone = try self.clonePath(gpa, i);

            clone.tail_node.* = Node{
                .kind = .{
                    .leaf = try Leaf.init(
                        gpa,
                        try clone.leaf.getUnwrap().update(
                            gpa,
                            i % width,
                            value,
                        ),
                    ),
                },
            };
            return clone.self;
        }

        /// Appends the given value to the vector. Assumes that some tail node has capacity to hold it.
        pub fn appendAssumeCapacity(self: *Self, gpa: std.mem.Allocator, value: T) !Self {
            var clone = try self.clonePath(gpa, self.len);

            clone.tail_node.* = Node{
                .kind = .{
                    .leaf = try Leaf.init(
                        gpa,
                        try clone.leaf.getUnwrap().append(gpa, value),
                    ),
                },
            };

            clone.self.len += 1;
            return clone.self;
        }

        /// Appends the given value to the vector. Increases the vector depth if necessary.
        pub fn append(self: *Self, gpa: std.mem.Allocator, value: T) !Self {
            // check if we need a new node
            if (self.len < std.math.pow(usize, width, self.depth + 1)) {
                return self.appendAssumeCapacity(gpa, value);
            }

            var root = Self{
                .node = try self.grow(gpa, 0, 0),
                .depth = self.depth + 1,
                .len = self.len,
            };
            defer root.deinit(gpa);

            return root.appendAssumeCapacity(gpa, value);
        }

        pub fn pop(self: *Self, gpa: std.mem.Allocator) !Self {
            var clone = try self.clonePath(gpa, self.len - 1);

            const leaf = clone.leaf.getUnwrap();
            clone.tail_node.* = Node{
                .kind = .{
                    .leaf = try Leaf.init(
                        gpa,
                        try leaf.remove(gpa, leaf.len() - 1),
                    ),
                },
            };

            clone.self.len -= 1;
            return clone.self;
        }

        pub fn toArray(self: Self, gpa: std.mem.Allocator) ![]const T {
            const arr = try gpa.alloc(T, self.len);

            var i: usize = 0;
            while (i < self.len) : (i += width) {
                const leaf = self.getLeaf(i).getUnwrap();
                const array = try leaf.toArray(gpa);
                defer gpa.free(array);

                @memcpy(arr[i .. i + array.len], array);
            }

            return arr;
        }

        fn toBuffer(self: Self, buffer: []T) void {
            var i: usize = 0;
            while (i < self.len) : (i += width) {
                const leaf = self.getLeaf(i).getUnwrap();
                leaf.toBuffer(buffer[i .. i + leaf.len()]);
            }
        }

        pub fn concat(self: Self, gpa: std.mem.Allocator, others: []const Self) !Self {
            var len = self.len;
            for (others) |o| {
                len += o.len;
            }

            const buffer = try gpa.alloc(T, len);
            defer gpa.free(buffer);

            self.toBuffer(buffer[0..self.len]);
            var start = self.len;
            for (others) |o| {
                const end = start + o.len;
                defer start = end;

                o.toBuffer(buffer[start..end]);
            }

            return Self.init(gpa, buffer);
        }

        /// Grows the current vector depth by 1.
        fn grow(
            self: *Self,
            gpa: std.mem.Allocator,
            bucket_index: usize,
            current_depth: usize,
        ) !RefCounter(*Node).Ref {
            const node_ptr = try gpa.create(Node);
            const node_ref = try RefCounter(*Node).init(gpa, node_ptr);

            if (self.depth + 1 == current_depth) {
                const leaf = VecT.empty;

                const leaf_ref = try RefCounter(VecT).init(gpa, leaf);
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
                nodes[i] = try self.grow(gpa, new_bucket_index, current_depth + 1);
            }

            node_ptr.* = Node{
                .kind = .{ .branch = nodes },
            };
            return node_ref;
        }

        fn newBranch() Branch {
            return [_]RefCounter(*Node).Ref{undefined} ** width;
        }
    };
}

pub fn MultiPVector(comptime T: type) type {
    return struct {
        vec: VecT,

        const Self = @This();
        const VecT = PVector(T, MultiIVector);
        const Field = MultiIVector(T).Field;

        fn FieldType(comptime field: Field) type {
            return MultiIVector(T).FieldType(field);
        }

        pub fn init(gpa: std.mem.Allocator, data: []const T) !Self {
            return .{ .vec = try VecT.init(gpa, data) };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.vec.node.release(gpa);
        }

        pub fn get(self: Self, i: usize) T {
            return self.vec.get(i);
        }

        /// Returns a new vector with the passed value at index i. If i == self.len and the depth of the trie
        /// does not need to increase, then the value is added to the end of the new collection.
        pub fn update(self: *Self, gpa: std.mem.Allocator, i: usize, value: T) !Self {
            const vec = try self.vec.update(gpa, i, value);
            return .{ .vec = vec };
        }

        /// Appends the given value to the vector. Assumes that some tail node has capacity to hold it.
        pub fn appendAssumeCapacity(self: *Self, gpa: std.mem.Allocator, value: T) !Self {
            const vec = try self.vec.appendAssumeCapacity(gpa, value);
            return .{ .vec = vec };
        }

        /// Appends the given value to the vector. Increases the vector depth if necessary.
        pub fn append(self: *Self, gpa: std.mem.Allocator, value: T) !Self {
            const vec = try self.vec.append(gpa, value);
            return .{ .vec = vec };
        }

        pub fn pop(self: *Self, gpa: std.mem.Allocator) !Self {
            const vec = try self.vec.pop(gpa);
            return .{ .vec = vec };
        }

        pub fn getField(self: Self, i: usize, comptime field: Field) *const FieldType(field) {
            return self.vec.getLeaf(i).getUnwrap().getField(i % VecT.width, field);
        }
    };
}
