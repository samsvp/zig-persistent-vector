/// See https://github.com/mkirchner/hamt
const std = @import("std");
const config = @import("config");

const RefCounter = @import("ref_counter.zig").RefCounter;

pub const bits = 5;
pub const width = 1 << bits;
const bit_mask = width - 1;

pub fn Context(comptime K: type) type {
    return struct {
        eql: *const fn (K, K) bool,
        hash: *const fn (K) u32,
    };
}

pub fn Hamt(comptime K: type, comptime V: type, context: Context(K)) type {
    return struct {
        root: Table,
        size: usize,

        const NodeRef = RefCounter(*Node).Ref;

        const Node = struct {
            kind: NodeKind,

            pub fn deinit(self: *Node, gpa: std.mem.Allocator) void {
                self.kind.deinit(gpa);
                gpa.destroy(self);
            }

            pub fn clone(self: *Node, gpa: std.mem.Allocator) !NodeRef {
                const new_node_ptr = try gpa.create(Node);
                new_node_ptr.* = .{
                    .kind = try self.kind.clone(gpa),
                };
                return RefCounter(*Node).init(gpa, new_node_ptr);
            }
        };

        const NodeKind = union(enum) {
            leaf: Leaf,
            table: Table,

            pub fn deinit(self: *NodeKind, gpa: std.mem.Allocator) void {
                switch (self.*) {
                    .leaf => |*l| l.deinit(gpa),
                    .table => |*t| t.deinit(gpa),
                }
            }

            pub fn clone(self: *NodeKind, gpa: std.mem.Allocator) !NodeKind {
                return switch (self.*) {
                    .leaf => |*l| .{ .leaf = try l.clone(gpa) },
                    .table => |*t| .{ .table = try t.clone(gpa) },
                };
            }
        };

        const Leaf = union(enum) {
            kv: KV,
            collision: HashCollisionNode,

            pub fn deinit(self: *Leaf, gpa: std.mem.Allocator) void {
                switch (self.*) {
                    .kv => {},
                    .collision => |*col| col.deinit(gpa),
                }
            }

            pub fn clone(leaf: *Leaf, gpa: std.mem.Allocator) !Leaf {
                return switch (leaf.*) {
                    .kv => |kv| .{ .kv = .{ .key = kv.key, .value = kv.value } },
                    .collision => |*col| .{ .collision = try col.clone(gpa) },
                };
            }
        };

        const KV = struct {
            key: K,
            value: V,
        };

        const Self = @This();

        pub fn init() Self {
            return .{
                .root = Table.init(),
                .size = 0,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.root.deinit(gpa);
        }

        pub fn get(self: *Self, key: K) ?V {
            return self.root.searchRecursive(key, 0);
        }

        pub fn assoc(self: *Self, gpa: std.mem.Allocator, key: K, value: V) !Self {
            var new_self: Self = .{
                .root = try self.root.clone(gpa),
                .size = self.size,
            };

            try new_self.assocRecursive(gpa, &new_self.root, key, value, 0, true);
            return new_self;
        }

        pub fn dissoc(self: *Self, gpa: std.mem.Allocator, key: K) !Self {
            var new_self: Self = .{
                .root = try self.root.clone(gpa),
                .size = self.size,
            };

            _ = try new_self.dissocRecursive(gpa, &new_self.root, key, 0, true);
            return new_self;
        }

        pub fn assocMut(self: *Self, gpa: std.mem.Allocator, key: K, value: V) !void {
            try self.assocRecursive(gpa, &self.root, key, value, 0, true);
        }

        pub fn dissocMut(self: *Self, gpa: std.mem.Allocator, key: K) !void {
            _ = try self.dissocRecursive(gpa, &self.root, key, 0, false);
        }

        fn assocRecursive(
            self: *Self,
            gpa: std.mem.Allocator,
            table: *Table,
            key: K,
            value: V,
            depth: usize,
            comptime should_clone: bool,
        ) !void {
            const shift: u5 = @intCast(bits * depth);
            const expected_index: u5 = @intCast((context.hash(key) >> shift) & bit_mask);
            if (!table.hasIndex(expected_index)) {
                try table.insertKV(gpa, key, value, expected_index);
                self.size += 1;
                return;
            }

            const pos = Table.getPos(@intCast(expected_index), table.index);
            if (should_clone) {
                var old_ref = table.ptr[pos];
                table.ptr[pos] = try old_ref.getUnwrap().clone(gpa);
                old_ref.release(gpa);
            }
            var next_ref = table.ptr[pos];
            var next_node = next_ref.getUnwrap();

            switch (next_node.kind) {
                .leaf => |*leaf| {
                    const found = switch (leaf.*) {
                        .kv => |*kv| context.eql(key, kv.key),
                        .collision => |col| col.bucket.contains(key),
                    };

                    if (found) {
                        try table.insertKV(gpa, key, value, expected_index);
                        return;
                    }

                    switch (leaf.*) {
                        .collision => |*col| try col.assoc(gpa, key, value),
                        .kv => |kv| try table.insertTable(gpa, kv, key, value, depth),
                    }
                    self.size += 1;
                },
                .table => |*t| {
                    return self.assocRecursive(gpa, t, key, value, depth + 1, should_clone);
                },
            }
        }

        fn dissocRecursive(
            self: *Self,
            gpa: std.mem.Allocator,
            table: *Table,
            key: K,
            depth: usize,
            comptime should_clone: bool,
        ) !bool {
            const shift: u5 = @intCast(bits * depth);
            const expected_index: u5 = @intCast((context.hash(key) >> shift) & bit_mask);
            if (!table.hasIndex(expected_index)) {
                return false;
            }

            const pos = Table.getPos(@intCast(expected_index), table.index);

            if (should_clone) {
                var old_ref = table.ptr[pos];
                table.ptr[pos] = try old_ref.getUnwrap().clone(gpa);
                old_ref.release(gpa);
            }
            var next_ref = table.ptr[pos];
            var next_node = next_ref.getUnwrap();

            switch (next_node.kind) {
                .leaf => |*leaf| {
                    switch (leaf.*) {
                        .kv => try table.shrink(gpa, expected_index, pos),
                        .collision => |*col| {
                            col.dissoc(key);

                            if (col.bucket.count() == 0) {
                                try table.shrink(gpa, expected_index, pos);
                            } else if (col.bucket.count() == 1) {
                                const k = col.bucket.keys()[0];
                                const v = col.bucket.values()[0];
                                try table.insertKV(gpa, k, v, expected_index);
                            }
                        },
                    }
                    self.size -= 1;
                    return table.ptr.len == 0;
                },
                .table => |*t| {
                    const table_removed = try self.dissocRecursive(gpa, t, key, depth + 1, should_clone);
                    if (!table_removed) {
                        return false;
                    }
                    try table.shrink(gpa, expected_index, pos);
                    return table.ptr.len == 0;
                },
            }
        }

        const Table = struct {
            ptr: []NodeRef,
            index: u32,

            pub fn init() Table {
                return .{
                    .ptr = &.{},
                    .index = 0,
                };
            }

            pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
                for (self.ptr) |*ref| {
                    ref.release(gpa);
                }
                gpa.free(self.ptr);
            }

            fn searchRecursive(table: *Table, key: V, depth: usize) ?V {
                const shift: u5 = @intCast(bits * depth);
                const expected_index = (context.hash(key) >> shift) & bit_mask;
                if (!table.hasIndex(@intCast(expected_index))) {
                    return null;
                }

                const pos = Table.getPos(@intCast(expected_index), table.index);
                const next_node = table.ptr[pos].getUnwrap();
                return switch (next_node.kind) {
                    .leaf => |*leaf| switch (leaf.*) {
                        .kv => |*kv| if (context.eql(key, kv.key)) kv.value else null,
                        .collision => |col| col.bucket.get(key),
                    },

                    .table => |*t| searchRecursive(t, key, depth + 1),
                };
            }

            pub fn getPos(sparse_index: u5, bitmap: u32) usize {
                return @popCount(bitmap & ((@as(u32, 1) << sparse_index) - 1));
            }

            pub fn hasIndex(table: Table, index: u5) bool {
                return (table.index & (@as(u32, 1) << index)) > 0;
            }

            pub fn extend(table: *Table, gpa: std.mem.Allocator, index: u5, pos: usize) !void {
                const new_table_ptr = try gpa.alloc(NodeRef, table.ptr.len + 1);
                if (table.ptr.len > 0) {
                    @memcpy(new_table_ptr[0..pos], table.ptr[0..pos]);
                    @memcpy(new_table_ptr[pos + 1 ..], table.ptr[pos..]);
                }

                gpa.free(table.ptr);
                table.ptr = new_table_ptr;
                table.index |= (@as(u32, 1) << index);
            }

            pub fn shrink(table: *Table, gpa: std.mem.Allocator, index: u5, pos: usize) !void {
                if (table.ptr.len == 0) {
                    gpa.free(table.ptr);
                    return;
                }

                var node_to_remove = table.ptr[pos];
                node_to_remove.release(gpa);

                const new_table_ptr = try gpa.alloc(NodeRef, table.ptr.len - 1);

                @memcpy(new_table_ptr[0..pos], table.ptr[0..pos]);
                @memcpy(new_table_ptr[pos..], table.ptr[pos + 1 ..]);

                gpa.free(table.ptr);
                table.ptr = new_table_ptr;
                table.index &= ~(@as(u32, 1) << index);
            }

            pub fn insertKV(table: *Table, gpa: std.mem.Allocator, key: K, value: V, index: u5) !void {
                const new_idx = table.index | (@as(u32, 1) << index);
                const pos = getPos(index, new_idx);

                if (table.hasIndex(index)) {
                    table.ptr[pos].release(gpa);
                } else {
                    try table.extend(gpa, index, pos);
                }

                const new_node_ptr = try gpa.create(Node);
                new_node_ptr.* = Node{
                    .kind = .{
                        .leaf = .{
                            .kv = .{ .key = key, .value = value },
                        },
                    },
                };

                table.ptr[pos] = try RefCounter(*Node).init(gpa, new_node_ptr);
            }

            pub fn createPath(gpa: std.mem.Allocator, kv: KV, key: K, value: V, depth: usize) !NodeRef {
                if (depth >= 5) {
                    var collision = HashCollisionNode.init();
                    try collision.assoc(gpa, key, value);
                    try collision.assoc(gpa, kv.key, kv.value);

                    const node_ptr = try gpa.create(Node);
                    node_ptr.* = Node{ .kind = .{ .leaf = .{ .collision = collision } } };
                    return RefCounter(*Node).init(gpa, node_ptr);
                }

                const shift: u5 = @intCast(bits * depth);
                const new_key_index: u5 = @intCast((context.hash(key) >> shift) & bit_mask);
                const curr_key_index: u5 = @intCast((context.hash(kv.key) >> shift) & bit_mask);

                if (new_key_index == curr_key_index) {
                    const next_node_ref = try createPath(gpa, kv, key, value, depth + 1);

                    const new_ptr = try gpa.alloc(NodeRef, 1);
                    new_ptr[0] = next_node_ref;

                    const table_node_ptr = try gpa.create(Node);
                    table_node_ptr.* = Node{
                        .kind = .{
                            .table = .{
                                .ptr = new_ptr,
                                .index = (@as(u32, 1) << new_key_index),
                            },
                        },
                    };
                    return RefCounter(*Node).init(gpa, table_node_ptr);
                }

                const new_table_ptr = try gpa.alloc(NodeRef, 2);
                const new_bitmap = (@as(u32, 1) << new_key_index) | (@as(u32, 1) << curr_key_index);

                const new_key_pos = getPos(new_key_index, new_bitmap);
                const curr_key_pos = getPos(curr_key_index, new_bitmap);

                const node_key_ptr = try gpa.create(Node);
                node_key_ptr.* = Node{ .kind = .{ .leaf = .{ .kv = .{ .key = key, .value = value } } } };
                new_table_ptr[new_key_pos] = try RefCounter(*Node).init(gpa, node_key_ptr);

                const node_kv_ptr = try gpa.create(Node);
                node_kv_ptr.* = Node{ .kind = .{ .leaf = .{ .kv = kv } } };
                new_table_ptr[curr_key_pos] = try RefCounter(*Node).init(gpa, node_kv_ptr);

                const root_node_ptr = try gpa.create(Node);
                root_node_ptr.* = Node{
                    .kind = .{
                        .table = .{
                            .ptr = new_table_ptr,
                            .index = new_bitmap,
                        },
                    },
                };
                return RefCounter(*Node).init(gpa, root_node_ptr);
            }

            pub fn insertTable(table: *Table, gpa: std.mem.Allocator, kv: KV, key: K, value: V, depth: usize) !void {
                const shift: u5 = @intCast(bits * depth);
                const index: u5 = @intCast((context.hash(kv.key) >> shift) & bit_mask);
                const pos = getPos(index, table.index);

                const new_node_ref = try createPath(gpa, kv, key, value, depth + 1);

                table.ptr[pos].release(gpa);
                table.ptr[pos] = new_node_ref;
            }

            pub fn clone(table: *Table, gpa: std.mem.Allocator) !Table {
                const new_ptr = try gpa.alloc(NodeRef, table.ptr.len);
                for (table.ptr, 0..) |*ref, i| {
                    new_ptr[i] = try ref.borrow();
                }
                return Table{
                    .ptr = new_ptr,
                    .index = table.index,
                };
            }
        };

        pub const HashCollisionNode = struct {
            bucket: Bucket,
            const Bucket = std.ArrayHashMapUnmanaged(K, V, HashCollisionContext, false);

            const HashCollisionContext = struct {
                pub fn hash(_: @This(), _: K) u32 {
                    return 0;
                }
                pub fn eql(_: @This(), a: K, b: K, _: usize) bool {
                    return context.eql(a, b);
                }
            };

            pub fn init() HashCollisionNode {
                return .{ .bucket = .empty };
            }

            pub fn deinit(self: *HashCollisionNode, gpa: std.mem.Allocator) void {
                self.bucket.deinit(gpa);
            }

            pub fn initWithBucket(bucket: Bucket) HashCollisionNode {
                return .{
                    .bucket = bucket,
                };
            }

            pub fn clone(self: HashCollisionNode, gpa: std.mem.Allocator) !HashCollisionNode {
                const bucket = try self.bucket.clone(gpa);
                return HashCollisionNode.initWithBucket(bucket);
            }

            pub fn dissoc(self: *HashCollisionNode, key: K) void {
                _ = self.bucket.swapRemove(key);
            }

            pub fn assoc(self: *HashCollisionNode, gpa: std.mem.Allocator, key: K, value: V) !void {
                try self.bucket.put(gpa, key, value);
            }
        };
    };
}
