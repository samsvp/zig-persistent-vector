/// See https://github.com/mkirchner/hamt
const std = @import("std");
const config = @import("config");

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

        const Node = union(enum) {
            leaf: Leaf,
            table: Table,

            pub fn clone(self: *Node, gpa: std.mem.Allocator) !Node {
                return switch (self.*) {
                    .leaf => |*leaf| .{ .leaf = try leaf.clone(gpa) },
                    .table => |*t| .{ .table = try t.clone(gpa) },
                };
            }
        };

        const Leaf = union(enum) {
            kv: KV,
            collision: HashCollisionNode,

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
                table.ptr[pos] = try table.ptr[pos].clone(gpa);
            }
            const next = &table.ptr[pos];
            switch (next.*) {
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
                        .collision => |*col| try col.assocMut(gpa, key, value),
                        .kv => |kv| try table.insertTable(gpa, kv, key, value, depth),
                    }
                    self.size += 1;
                },
                .table => |*t| {
                    if (should_clone) {
                        const new_table = try t.clone(gpa);
                        table.ptr[pos] = .{ .table = new_table };
                    }
                    return self.assocRecursive(gpa, &table.ptr[pos].table, key, value, depth + 1, should_clone);
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
                table.ptr[pos] = try table.ptr[pos].clone(gpa);
            }

            const next = &table.ptr[pos];
            switch (next.*) {
                .leaf => |*leaf| {
                    switch (leaf.*) {
                        .kv => {
                            try table.shrink(gpa, expected_index, pos);
                        },
                        .collision => |*col| {
                            col.dissocMut(key);

                            if (col.bucket.count() == 0) {
                                try table.shrink(gpa, expected_index, pos);
                            } else if (col.bucket.count() == 1) {
                                const first = col.bucket.entries.get(0);
                                table.ptr[pos] = .{ .leaf = .{ .kv = .{ .key = first.key, .value = first.value } } };
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
            ptr: []Node,
            index: u32,

            pub fn init() Table {
                return .{
                    .ptr = &.{},
                    .index = 0,
                };
            }

            fn searchRecursive(table: *Table, key: V, depth: usize) ?V {
                const shift: u5 = @intCast(bits * depth);
                const expected_index = (context.hash(key) >> shift) & bit_mask;
                if (!table.hasIndex(@intCast(expected_index))) {
                    return null;
                }

                const pos = Table.getPos(@intCast(expected_index), table.index);
                const next = &table.ptr[pos];
                return switch (next.*) {
                    .leaf => |*leaf| switch (leaf.*) {
                        .kv => |*kv| if (context.eql(key, kv.key)) kv.value else null,
                        .collision => |col| col.bucket.get(key),
                    },

                    .table => |*t| searchRecursive(t, key, depth + 1),
                };
            }

            /// Returns the dense index from the sparse index.
            pub fn getPos(sparse_index: u5, bitmap: u32) usize {
                return @popCount(bitmap & ((@as(u32, 1) << sparse_index) - 1));
            }

            /// Returns if the table has a child at the given index.
            pub fn hasIndex(table: Table, index: u5) bool {
                return (table.index & (@as(u32, 1) << index)) > 0;
            }

            /// Adds one row to the table at the given position `pos`.
            pub fn extend(table: *Table, gpa: std.mem.Allocator, index: u5, pos: usize) !void {
                const new_table_ptr = try gpa.alloc(Node, table.ptr.len + 1);
                if (table.ptr.len > 0) {
                    @memcpy(new_table_ptr[0..pos], table.ptr[0..pos]);
                    @memcpy(new_table_ptr[pos + 1 ..], table.ptr[pos..]);
                }

                gpa.free(table.ptr);
                table.ptr = new_table_ptr;
                table.index |= (@as(u32, 1) << index);
            }

            /// Removes the row at `pos` from the table.
            pub fn shrink(table: *Table, gpa: std.mem.Allocator, index: u5, pos: usize) !void {
                if (table.ptr.len == 0) {
                    gpa.free(table.ptr);
                    return;
                }

                const new_table_ptr = try gpa.alloc(Node, table.ptr.len - 1);

                @memcpy(new_table_ptr[0..pos], table.ptr[0..pos]);
                @memcpy(new_table_ptr[pos..], table.ptr[pos + 1 ..]);

                gpa.free(table.ptr);
                table.ptr = new_table_ptr;
                table.index &= ~(@as(u32, 1) << index);
            }

            /// Converts a table into a leaf (key/value) node.
            pub fn gather(table: *Table, gpa: std.mem.Allocator, pos: usize) !KV {
                const kv: KV = .{
                    .key = table.ptr[pos].kv.key,
                    .value = table.ptr[pos].kv.value,
                };
                gpa.free(table.ptr);
                return kv;
            }

            pub fn insertKV(table: *Table, gpa: std.mem.Allocator, key: K, value: V, index: u5) !void {
                const new_idx = table.index | (@as(u32, 1) << index);
                const pos = getPos(index, new_idx);

                try table.extend(gpa, index, pos);
                table.ptr[pos] = .{
                    .leaf = .{
                        .kv = .{ .key = key, .value = value },
                    },
                };
            }

            pub fn createPath(gpa: std.mem.Allocator, kv: KV, key: K, value: V, depth: usize) !Node {
                if (depth >= 5) {
                    var collision = HashCollisionNode.init();
                    try collision.assocMut(gpa, key, value);
                    try collision.assocMut(gpa, kv.key, kv.value);
                    return .{ .leaf = .{ .collision = collision } };
                }

                const shift: u5 = @intCast(bits * depth);
                const new_key_index: u5 = @intCast((context.hash(key) >> shift) & bit_mask);
                const curr_key_index: u5 = @intCast((context.hash(kv.key) >> shift) & bit_mask);

                // hash collision
                if (new_key_index == curr_key_index) {
                    const next_node = try createPath(gpa, kv, key, value, depth + 1);

                    const new_ptr = try gpa.alloc(Node, 1);
                    new_ptr[0] = next_node;

                    return Node{
                        .table = .{
                            .ptr = new_ptr,
                            .index = (@as(u32, 1) << new_key_index),
                        },
                    };
                }

                const new_table: Table = .{
                    .ptr = try gpa.alloc(Node, 2),
                    .index = (@as(u32, 1) << new_key_index) | (@as(u32, 1) << curr_key_index),
                };

                const new_key_pos = getPos(new_key_index, new_table.index);
                const curr_key_pos = getPos(curr_key_index, new_table.index);

                new_table.ptr[new_key_pos] = .{ .leaf = .{ .kv = .{ .key = key, .value = value } } };
                new_table.ptr[curr_key_pos] = .{ .leaf = .{ .kv = kv } };

                return .{
                    .table = new_table,
                };
            }

            pub fn insertTable(table: *Table, gpa: std.mem.Allocator, kv: KV, key: K, value: V, depth: usize) !void {
                const shift: u5 = @intCast(bits * depth);
                const index: u5 = @intCast((context.hash(kv.key) >> shift) & bit_mask);
                const pos = getPos(index, table.index);

                const new_node = try createPath(gpa, kv, key, value, depth + 1);

                table.ptr[pos] = new_node;
            }

            /// clones the given table.
            pub fn clone(table: *Table, gpa: std.mem.Allocator) !Table {
                const new_ptr = try gpa.dupe(Node, table.ptr);
                const new_table: Table = .{
                    .ptr = new_ptr,
                    .index = table.index,
                };
                return new_table;
            }
        };

        /// Handles the case where two different keys have the exact same hash.
        /// Stores a simple list of (key, value) tuples.
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

            pub fn initWithBucket(bucket: Bucket) HashCollisionNode {
                return .{
                    .bucket = bucket,
                };
            }

            pub fn clone(self: HashCollisionNode, gpa: std.mem.Allocator) !HashCollisionNode {
                const bucket = try self.bucket.clone(gpa);
                return HashCollisionNode.initWithBucket(bucket);
            }

            pub fn dissocMut(self: *HashCollisionNode, key: K) void {
                _ = self.bucket.swapRemove(key);
            }

            pub fn assocMut(self: *HashCollisionNode, gpa: std.mem.Allocator, key: K, value: V) !void {
                try self.bucket.put(gpa, key, value);
            }
        };
    };
}
