const std = @import("std");
const Io = std.Io;
const Color = @import("colors.zig");
const types = @import("types.zig");

const Operation = types.Operation;

pub const PlanMode = enum { status, dry_run };

pub fn printPlan(out: *Io.Writer, plan: []const Operation, mode: PlanMode) !void {
    if (plan.len == 0) {
        try out.print("{s}Already synced.{s}\n", .{ Color.green, Color.reset });
        return;
    }

    switch (mode) {
        .status => try out.print("{s}Pending changes:{s}\n", .{ Color.cyan, Color.reset }),
        .dry_run => try out.print("{s}Would perform:{s}\n", .{ Color.cyan, Color.reset }),
    }

    for (plan) |op| {
        try out.print("  {s}{s:<20}{s} {s}\n", .{ Color.yellow, types.operationName(op.kind), Color.reset, op.rel_path });
    }

    try printCounts(out, plan);
}

pub fn printSyncSummary(out: *Io.Writer, operation_count: usize, error_count: usize, backup_root: []const u8) !void {
    if (error_count == 0) {
        try out.print("{s}Sync complete:{s} {d} operations. Backup: {s}\n", .{ Color.green, Color.reset, operation_count, backup_root });
    } else {
        try out.print("{s}Sync finished with errors:{s} {d} operations, {d} errors. Backup: {s}\n", .{ Color.red, Color.reset, operation_count, error_count, backup_root });
    }
}

fn printCounts(out: *Io.Writer, plan: []const Operation) !void {
    try out.print("\n{s}Summary:{s}\n", .{ Color.cyan, Color.reset });
    inline for (@typeInfo(Operation.Kind).@"enum".fields) |field| {
        const kind: Operation.Kind = @enumFromInt(field.value);
        const count = countKind(plan, kind);
        if (count > 0) try out.print("  {d} {s}\n", .{ count, types.operationName(kind) });
    }
    try out.print("  {d} total\n", .{plan.len});
}

fn countKind(plan: []const Operation, kind: Operation.Kind) usize {
    var count: usize = 0;
    for (plan) |op| {
        if (op.kind == kind) count += 1;
    }
    return count;
}
