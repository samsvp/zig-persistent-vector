const std = @import("std");
const config = @import("config");

const Tuple = std.meta.Tuple;

pub const bits = config.bits;
pub const width = 1 << bits;
const bit_mask = width - 1;

/// Calculates the physical index in the compressed array.
/// This is the number of set bits to the right of the target bit.
pub fn getIndexInSparseArray(bitmap: usize, bitpos: usize) usize {
    const mask = bitpos - 1;
    return @popCount(bitmap & mask);
}

/// Handles the case where two different keys have the exact same hash.
/// Stores a simple list of (key, value) tuples.
pub fn HashCollisionNode(comptime K: type, comptime V: type, eqlFn: *const fn (K, K) bool) type {
    return struct {
        bucket: std.ArrayHashMapUnmanaged(K, V, Context, false),

        const Context = struct {
            pub fn hash(_: Context) u64 {
                return 0;
            }

            pub fn eql(_: Context, a: []const u8, b: []const u8) bool {
                return eqlFn(u8, a, b);
            }
        };

        const Self = @This();
        const KVPair = Tuple(.{ K, V });

        fn init(bucket: std.ArrayList(KVPair)) Self {
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
