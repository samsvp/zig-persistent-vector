/// See https://github.com/mkirchner/hamt
const std = @import("std");
const config = @import("config");

pub const bits = config.bits;
pub const width = 1 << bits;
const bit_mask = width - 1;

pub fn Hamt(comptime K: type, comptime V: type) type {
    return struct {
        const Node = union(enum) {
            kv: KV,
            table: Table,
        };

        const KV = struct {
            key: K,
            value: V,
        };

        const Table = struct {
            ptr: []Node,
            index: u32,

            /// Returns the dense index from the sparse index.
            pub fn getPos(sparse_index: u32, bitmap: u32) usize {
                return @popCount(bitmap & ((1 << sparse_index) - 1));
            }

            /// Returns if the table has a child at the given index.
            pub fn has_index(table: Table, index: usize) bool {
                return (table.index & (1 << index)) > 0;
            }

            /// Adds one row to the table at the given position `pos`.
            pub fn extend(table: *Table, gpa: std.mem.Allocator, index: u32, pos: usize) !void {
                const new_table_ptr = try gpa.alloc(Node, table.ptr.len + 1);
                if (table.ptr.len > 0) {
                    @memcpy(new_table_ptr, table.ptr[0..pos]);
                    @memcpy(new_table_ptr.ptr[pos + 1], table.ptr[pos..]);
                }

                gpa.free(table.ptr);
                table.ptr = new_table_ptr;
                table.index |= (1 << index);
            }

            /// Removes the row at `pos` from the table.
            pub fn shrink(table: *Table, gpa: std.mem.Allocator, index: u32, pos: usize) !void {
                if (table.ptr.len == 0) {
                    gpa.free(table.ptr);
                    return;
                }

                const new_table_ptr = try gpa.alloc(Node, table.ptr.len - 1);

                @memcpy(new_table_ptr, table.ptr[0..pos]);
                @memcpy(new_table_ptr.ptr[pos + 1], table.ptr[pos..]);

                gpa.free(table.ptr);
                table.ptr = new_table_ptr;
                table.index &= ~(1 << index);
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
pub fn HashCollisionNode(comptime K: type, comptime V: type, eqlFn: *const fn (K, K) bool) type {
    return struct {
        bucket: Bucket,
        const Bucket = std.ArrayHashMapUnmanaged(K, V, Context, false);

        const Context = struct {
            pub fn hash(_: Context) u64 {
                return 0;
            }

            pub fn eql(_: Context, a: []const u8, b: []const u8) bool {
                return eqlFn(u8, a, b);
            }
        };

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
