const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn join(allocator: Allocator, left: []const u8, right: []const u8) ![]const u8 {
    if (left.len == 0) return allocator.dupe(u8, right);
    if (right.len == 0) return allocator.dupe(u8, left);
    return std.fs.path.join(allocator, &.{ left, right });
}

pub fn parent(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}
