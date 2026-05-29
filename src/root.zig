const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const build_options = @import("build_options");
const cli = @import("cli.zig");
const Color = @import("colors.zig");
const config = @import("config.zig");
const output = @import("output.zig");
const plan = @import("plan.zig");
const sync = @import("sync.zig");
const types = @import("types.zig");

pub const Config = types.Config;
pub const Operation = types.Operation;
pub const RunOptions = struct {
    args: []const []const u8,
    home: []const u8,
    io: Io,
    out: *Io.Writer,
};

pub const parseConfig = config.parse;
pub const version = build_options.version;

pub fn run(allocator: Allocator, options: RunOptions) !u8 {
    const parsed_cli = cli.parse(options.args) catch |err| {
        try options.out.print("{s}error:{s} {s}\n\n", .{ Color.red, Color.reset, @errorName(err) });
        try cli.printHelp(options.out);
        return 2;
    };

    switch (parsed_cli.command) {
        .help => {
            try cli.printHelp(options.out);
            return 0;
        },
        .version => {
            try options.out.print("dm {s}\n", .{version});
            return 0;
        },
        .status => {
            const loaded_config = config.load(allocator, options.io, options.home, parsed_cli.config_path) catch |err| {
                try options.out.print("{s}error:{s} failed to load config: {s}\n", .{ Color.red, Color.reset, @errorName(err) });
                return 1;
            };
            const planned_operations = plan.build(allocator, options.io, options.home, loaded_config) catch |err| {
                try options.out.print("{s}error:{s} failed to build status: {s}\n", .{ Color.red, Color.reset, @errorName(err) });
                return 1;
            };
            try output.printPlan(options.out, planned_operations, .status);
            return 0;
        },
        .sync => {
            const loaded_config = config.load(allocator, options.io, options.home, parsed_cli.config_path) catch |err| {
                try options.out.print("{s}error:{s} failed to load config: {s}\n", .{ Color.red, Color.reset, @errorName(err) });
                return 1;
            };
            const planned_operations = plan.build(allocator, options.io, options.home, loaded_config) catch |err| {
                try options.out.print("{s}error:{s} failed to build sync plan: {s}\n", .{ Color.red, Color.reset, @errorName(err) });
                return 1;
            };

            if (parsed_cli.dry_run) {
                try output.printPlan(options.out, planned_operations, .dry_run);
                return 0;
            }

            const result = try sync.execute(allocator, options.io, options.home, loaded_config, planned_operations);
            try output.printSyncSummary(options.out, planned_operations.len, result.error_count, result.backup_root);
            return if (result.error_count == 0) 0 else 1;
        },
    }
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "run version prints current version" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const code = try run(std.testing.allocator, .{
        .args = &.{ "dm", "version" },
        .home = "/tmp",
        .io = undefined,
        .out = &out.writer,
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("dm " ++ version ++ "\n", out.written());
}

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("plan.zig");
    _ = @import("sync.zig");
}
