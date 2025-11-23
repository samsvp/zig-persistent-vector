/// See https://github.com/mkirchner/hamt
const std = @import("std");
const config = @import("config");

const RefCounter = @import("ref_counter.zig").RefCounter;

pub const bits = 5;
pub const width = 1 << bits;
const bit_mask = width - 1;

pub fn KV(comptime K: type, comptime V: type) type {
    return struct {
        key: K,
        value: V,
    };
}

pub fn HashContext(comptime K: type) type {
    return struct {
        eql: *const fn (K, K) bool,
        hash: *const fn (K) u32,
    };
}

pub fn KVContext(
    comptime K: type,
    comptime V: type,
) type {
    return struct {
        init: *const fn (std.mem.Allocator, K, V) anyerror!KV(K, V),
        deinit: *const fn (std.mem.Allocator, *KV(K, V)) void,
        clone: *const fn (std.mem.Allocator, *KV(K, V)) anyerror!KV(K, V),

        const Self = @This();

        pub fn default() Self {
            return .{ .init = defaultInit, .deinit = defaultDeinit, .clone = defaultClone };
        }

        fn defaultInit(_: std.mem.Allocator, key: K, value: V) !KV(K, V) {
            return .{ .key = key, .value = value };
        }

        fn defaultDeinit(_: std.mem.Allocator, _: *KV(K, V)) void {}

        fn defaultClone(_: std.mem.Allocator, self: *KV(K, V)) !KV(K, V) {
            return self.*;
        }
    };
}

pub fn AutoHamt(
    comptime K: type,
    comptime V: type,
    hash_context: HashContext(K),
) type {
    return Hamt(K, V, hash_context, KVContext(K, V).default());
}

pub fn Hamt(
    comptime K: type,
    comptime V: type,
    hash_context: HashContext(K),
    kv_context: KVContext(K, V),
) type {
    return struct {
        root: Table,
        size: usize,

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

        pub fn clone(self: *Self, gpa: std.mem.Allocator) !Self {
            return .{
                .root = try self.root.clone(gpa),
                .size = self.size,
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

            const kv = try kv_context.init(gpa, key, value);
            try new_self.assocRecursive(gpa, &new_self.root, kv, 0, true);
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
            const kv = try kv_context.init(gpa, key, value);
            try self.assocRecursive(gpa, &self.root, kv, 0, false);
        }

        pub fn dissocMut(self: *Self, gpa: std.mem.Allocator, key: K) !void {
            _ = try self.dissocRecursive(gpa, &self.root, key, 0, false);
        }

        fn assocRecursive(
            self: *Self,
            gpa: std.mem.Allocator,
            table: *Table,
            kv: KV(K, V),
            depth: usize,
            comptime should_clone: bool,
        ) !void {
            const shift: u5 = @intCast(bits * depth);
            const expected_index: u5 = @intCast((hash_context.hash(kv.key) >> shift) & bit_mask);
            if (!table.hasIndex(expected_index)) {
                try table.insertKV(gpa, kv, expected_index);
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
                        .collision => |*col| try col.assoc(gpa, kv),
                        .kv => |*other_kv| blk: {
                            const found = hash_context.eql(kv.key, other_kv.key);
                            if (found) {
                                try table.insertKV(gpa, kv, expected_index);
                            } else {
                                const preserved_kv = try kv_context.clone(gpa, other_kv);
                                try table.insertTable(gpa, preserved_kv, kv, depth);
                            }
                            break :blk found;
                        },
                    };

                    if (!found) {
                        self.size += 1;
                    }
                },
                .table => |*t| {
                    return self.assocRecursive(gpa, t, kv, depth + 1, should_clone);
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
            const expected_index: u5 = @intCast((hash_context.hash(key) >> shift) & bit_mask);
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
                            col.dissoc(gpa, key);

                            if (col.bucket.items.len == 0) {
                                try table.shrink(gpa, expected_index, pos);
                            } else if (col.bucket.items.len == 1) {
                                const kv = try kv_context.clone(gpa, &col.bucket.items[0]);
                                try table.insertKV(gpa, kv, expected_index);
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

        pub fn iterator(self: Self) Iterator {
            return Iterator.init(self);
        }

        pub const Iterator = struct {
            depth: usize = 0,
            stack: [MAX_DEPTH]StackFrame = undefined,
            collision_bucket: ?HashCollisionNode = null,

            const StackFrame = struct {
                kind: Kind,
                index: usize = 0,

                const Kind = union(enum) {
                    table: Table,
                    collision: HashCollisionNode,
                };
            };

            const MAX_DEPTH = 8;

            pub fn init(trie: Self) Iterator {
                var iter: Iterator = .{};

                iter.stack[0] = .{
                    .kind = .{ .table = trie.root },
                    .index = 0,
                };

                return iter;
            }

            pub fn next(iter: *Iterator) ?KV(K, V) {
                var stack = &iter.stack[iter.depth];
                switch (stack.kind) {
                    .table => |table| if (stack.index >= table.ptr.len) {
                        // finished table
                        if (iter.depth == 0) {
                            // finished iter
                            return null;
                        }

                        iter.depth -= 1;
                        // move upwards from the stack
                        return iter.next();
                    },
                    .collision => |col| {
                        if (stack.index >= col.bucket.items.len) {
                            iter.depth -= 1;
                            return iter.next();
                        }

                        const kv = col.bucket.items[stack.index];
                        stack.index += 1;
                        return kv;
                    },
                }

                const node = stack.kind.table.ptr[stack.index].get() catch return null;
                stack.index += 1;
                switch (node.kind) {
                    .leaf => |leaf| switch (leaf) {
                        .kv => |kv| return kv,
                        .collision => |col| {
                            iter.depth += 1;
                            iter.stack[iter.depth] = .{ .kind = .{ .collision = col } };
                            return iter.next();
                        },
                    },
                    .table => |table| {
                        iter.depth += 1;
                        iter.stack[iter.depth] = .{ .kind = .{ .table = table } };
                        return iter.next();
                    },
                }
            }
        };

        const NodeRef = RefCounter(*Node).Ref;

        const Node = struct {
            kind: Node.Kind,

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

            const Kind = union(enum) {
                leaf: Leaf,
                table: Table,

                pub fn deinit(self: *Kind, gpa: std.mem.Allocator) void {
                    switch (self.*) {
                        .leaf => |*l| l.deinit(gpa),
                        .table => |*t| t.deinit(gpa),
                    }
                }

                pub fn clone(self: *Kind, gpa: std.mem.Allocator) !Kind {
                    return switch (self.*) {
                        .leaf => |*l| .{ .leaf = try l.clone(gpa) },
                        .table => |*t| .{ .table = try t.clone(gpa) },
                    };
                }
            };
        };

        const Leaf = union(enum) {
            kv: KV(K, V),
            collision: HashCollisionNode,

            pub fn deinit(self: *Leaf, gpa: std.mem.Allocator) void {
                switch (self.*) {
                    .kv => |*kv| kv_context.deinit(gpa, kv),
                    .collision => |*col| col.deinit(gpa),
                }
            }

            pub fn clone(leaf: *Leaf, gpa: std.mem.Allocator) !Leaf {
                return switch (leaf.*) {
                    .kv => |*kv| .{ .kv = try kv_context.clone(gpa, kv) },
                    .collision => |*col| .{ .collision = try col.clone(gpa) },
                };
            }
        };

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

            fn searchRecursive(table: *Table, key: K, depth: usize) ?V {
                const shift: u5 = @intCast(bits * depth);
                const expected_index = (hash_context.hash(key) >> shift) & bit_mask;
                if (!table.hasIndex(@intCast(expected_index))) {
                    return null;
                }

                const pos = Table.getPos(@intCast(expected_index), table.index);
                const next_node = table.ptr[pos].getUnwrap();
                return switch (next_node.kind) {
                    .leaf => |*leaf| switch (leaf.*) {
                        .kv => |*kv| if (hash_context.eql(key, kv.key)) kv.value else null,
                        .collision => |col| col.get(key),
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

            pub fn insertKV(table: *Table, gpa: std.mem.Allocator, kv: KV(K, V), index: u5) !void {
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
                        .leaf = .{ .kv = kv },
                    },
                };

                table.ptr[pos] = try RefCounter(*Node).init(gpa, new_node_ptr);
            }

            pub fn createPath(gpa: std.mem.Allocator, other_kv: KV(K, V), kv: KV(K, V), depth: usize) !NodeRef {
                if (depth >= 5) {
                    var collision = HashCollisionNode.init();
                    _ = try collision.assoc(gpa, kv);
                    _ = try collision.assoc(gpa, other_kv);

                    const node_ptr = try gpa.create(Node);
                    node_ptr.* = Node{ .kind = .{ .leaf = .{ .collision = collision } } };
                    return RefCounter(*Node).init(gpa, node_ptr);
                }

                const shift: u5 = @intCast(bits * depth);
                const new_key_index: u5 = @intCast((hash_context.hash(kv.key) >> shift) & bit_mask);
                const curr_key_index: u5 = @intCast((hash_context.hash(other_kv.key) >> shift) & bit_mask);

                if (new_key_index == curr_key_index) {
                    const next_node_ref = try createPath(gpa, other_kv, kv, depth + 1);

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
                node_key_ptr.* = Node{ .kind = .{ .leaf = .{ .kv = kv } } };
                new_table_ptr[new_key_pos] = try RefCounter(*Node).init(gpa, node_key_ptr);

                const node_kv_ptr = try gpa.create(Node);
                node_kv_ptr.* = Node{ .kind = .{ .leaf = .{ .kv = other_kv } } };
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

            pub fn insertTable(table: *Table, gpa: std.mem.Allocator, other_kv: KV(K, V), kv: KV(K, V), depth: usize) !void {
                const shift: u5 = @intCast(bits * depth);
                const index: u5 = @intCast((hash_context.hash(other_kv.key) >> shift) & bit_mask);
                const pos = getPos(index, table.index);

                const new_node_ref = try createPath(gpa, other_kv, kv, depth + 1);

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
            const Bucket = std.ArrayList(KV(K, V));

            pub fn init() HashCollisionNode {
                return .{ .bucket = .empty };
            }

            pub fn deinit(self: *HashCollisionNode, gpa: std.mem.Allocator) void {
                for (self.bucket.items) |*kv| {
                    kv_context.deinit(gpa, kv);
                }
                self.bucket.deinit(gpa);
            }

            pub fn initWithBucket(bucket: Bucket) HashCollisionNode {
                return .{
                    .bucket = bucket,
                };
            }

            pub fn contains(self: HashCollisionNode, key: K) bool {
                for (self.bucket.items) |kv| {
                    if (hash_context.eql(kv.key, key)) {
                        return true;
                    }
                }
                return false;
            }

            pub fn get(self: HashCollisionNode, key: K) ?V {
                for (self.bucket.items) |kv| {
                    if (hash_context.eql(kv.key, key)) {
                        return kv.value;
                    }
                }
                return null;
            }

            pub fn clone(self: HashCollisionNode, gpa: std.mem.Allocator) !HashCollisionNode {
                var bucket: Bucket = try .initCapacity(gpa, self.bucket.items.len);
                for (self.bucket.items) |*kv| {
                    bucket.appendAssumeCapacity(try kv_context.clone(gpa, kv));
                }
                return HashCollisionNode.initWithBucket(bucket);
            }

            pub fn dissoc(self: *HashCollisionNode, gpa: std.mem.Allocator, key: K) void {
                for (0..self.bucket.items.len) |i| {
                    const kv = &self.bucket.items[i];
                    if (!hash_context.eql(kv.key, key)) {
                        continue;
                    }

                    kv_context.deinit(gpa, kv);
                    _ = self.bucket.swapRemove(i);
                    break;
                }
            }

            pub fn assoc(self: *HashCollisionNode, gpa: std.mem.Allocator, kv: KV(K, V)) !bool {
                const found = for (0..self.bucket.items.len) |i| {
                    const other_kv = &self.bucket.items[i];
                    if (!hash_context.eql(other_kv.key, kv.key)) {
                        continue;
                    }
                    kv_context.deinit(gpa, other_kv);
                    _ = self.bucket.swapRemove(i);
                    break true;
                } else false;

                try self.bucket.append(gpa, kv);

                return found;
            }
        };
    };
}
