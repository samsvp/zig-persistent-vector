/// See https://github.com/mkirchner/hamt
const std = @import("std");
const config = @import("config");

pub const bits = config.bits;
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
            kv: KV,
            table: Table,
        };

        const Self = @This();

        const SearchResult = struct {
            status: Status,
            anchor: Table,
            value: ?*V,

            const Status = enum {
                success,
                not_found,
                key_mismatch,
            };
        };

        pub fn init() Self {
            return .{
                .root = Table.init(),
                .size = 0,
            };
        }

        fn search_recursive(table: Table, key: V, depth: usize) SearchResult {
            const shift: u5 = @intCast(width * depth);
            const expected_index = (context.hash(key) >> shift) & bit_mask;
            if (!table.has_index(@intCast(expected_index))) {
                return .{
                    .status = .not_found,
                    .anchor = table,
                    .value = null,
                };
            }

            const pos = Table.getPos(@intCast(expected_index), table.index);
            var next = table.ptr[pos];
            switch (next) {
                .kv => |*kv| {
                    const status: SearchResult.Status = if (context.eql(key, kv.key)) .success else .key_mismatch;
                    return .{
                        .status = status,
                        .anchor = table,
                        .value = &kv.value,
                    };
                },
                .table => |t| return search_recursive(t, key, depth + 1),
            }
        }

        pub fn get(self: Self, key: K) SearchResult {
            return search_recursive(self.root, key, 0);
        }

        const KV = struct {
            key: K,
            value: V,
        };

        const Table = struct {
            ptr: []Node,
            index: u32,

            pub fn init() Table {
                return .{
                    .ptr = &.{},
                    .index = 0,
                };
            }

            /// Returns the dense index from the sparse index.
            pub fn getPos(sparse_index: u5, bitmap: u32) usize {
                return @popCount(bitmap & ((@as(u32, 1) << sparse_index) - 1));
            }

            /// Returns if the table has a child at the given index.
            pub fn has_index(table: Table, index: u5) bool {
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

                @memcpy(new_table_ptr, table.ptr[0..pos]);
                @memcpy(new_table_ptr.ptr[pos + 1], table.ptr[pos..]);

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
    };
}

/// Handles the case where two different keys have the exact same hash.
/// Stores a simple list of (key, value) tuples.
pub fn HashCollisionNode(comptime K: type, comptime V: type) type {
    return struct {
        bucket: Bucket,
        const Bucket = std.ArrayHashMapUnmanaged(K, V, Context, false);

        const Self = @This();

        fn init(bucket: Bucket) Self {
            return .{
                .bucket = bucket,
            };
        }

        fn find(self: Self, key: K) ?V {
            return self.bucket.get(key);
        }

        fn assoc(self: Self, gpa: std.mem.Allocator, key: K, value: V) !Self {
            const bucket = try self.bucket.clone(gpa);
            var node = init(bucket);
            try node.assocMut(gpa, key, value);
            return node;
        }

        fn assocMut(self: *Self, gpa: std.mem.Allocator, key: K, value: V) !void {
            try self.bucket.put(gpa, key, value);
        }
    };
}
