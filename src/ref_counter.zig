const std = @import("std");

const borrow_errors = error {
    AccessFreedReference,
    BorrowOfFreedReference,
};

pub fn RefCounter(comptime T: type) type {
    return struct {
        value: T,
        count: usize = 1,

        const Self = @This();

        pub const Ref = struct {
            value: *Self,
            released: bool = false,

            pub fn init(gpa: std.mem.Allocator, value: T) !Ref {
                return RefCounter(T).init(gpa, value);
            }

            pub fn get(self: Ref) !T {
                if (self.released) {
                    return borrow_errors.AccessFreedReference;
                }

                return self.value.value;
            }

            pub fn getUnwrap(self: Ref) T {
                if (self.released) {
                    @panic("Trying to get released reference.");
                }
                return self.value.value;
            }

            pub fn borrow(self: *Ref) !Ref {
                return Ref{ .value = try _borrow(self.value) };
            }

            pub fn release(self: *Ref, gpa: std.mem.Allocator) void {
                if (self.released) {
                    return;
                }

                self.value._release(gpa);
                self.released = true;
            }
        };

        pub fn init(gpa: std.mem.Allocator, value: T) !Ref {
            const U = switch (@typeInfo(T)) {
                .pointer => |info| info.child,
                else => T,
            };

            if (!std.meta.hasFn(U, "deinit")) {
                @compileError("Value must have deinit function.");
            }

            const method = @field(U, "deinit");
            const expected_signature = fn(*U, std.mem.Allocator) void;
            if (@TypeOf(method) != expected_signature) {
                @compileError("deinit function must accept a self pointer and an allocator");
            }

            const self = try gpa.create(Self);
            self.* = Self{ .value = value };
            return Ref{ .value = self };
        }

        fn _borrow(self: *Self) !*Self {
            if (self.count == 0) {
                return error.BorrowOfFreedReference;
            }
            self.count += 1;
            return self;
        }

        fn _release(self: *Self, gpa: std.mem.Allocator) void {
            if (self.count == 0) {
                return;
            }

            self.count -= 1;
            if (self.count == 0) {
                self.value.deinit(gpa);
                gpa.destroy(self);
            }
        }
    };
}
