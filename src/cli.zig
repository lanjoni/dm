const std = @import("std");
const Io = std.Io;
const Color = @import("colors.zig");

pub const Cli = struct {
    command: Command,
    config_path: ?[]const u8 = null,
    dry_run: bool = false,

    pub const Command = enum { help, sync, status };
};

pub fn parse(args: []const []const u8) !Cli {
    if (args.len <= 1) return .{ .command = .help };

    const command_arg = args[1];
    var cli: Cli = if (std.mem.eql(u8, command_arg, "help") or std.mem.eql(u8, command_arg, "--help") or std.mem.eql(u8, command_arg, "-h"))
        .{ .command = .help }
    else if (std.mem.eql(u8, command_arg, "sync"))
        .{ .command = .sync }
    else if (std.mem.eql(u8, command_arg, "status"))
        .{ .command = .status }
    else
        return error.UnknownCommand;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            if (cli.command != .sync and cli.command != .status) return error.FlagNotAllowed;
            i += 1;
            if (i >= args.len) return error.MissingConfigPath;
            cli.config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            if (cli.command != .sync) return error.FlagNotAllowed;
            cli.dry_run = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return cli;
}

pub fn printHelp(out: *Io.Writer) !void {
    try out.print(
        \\{s}dm{s} - dotfiles manager
        \\
        \\Usage:
        \\  dm
        \\  dm help
        \\  dm status [--config <path>]
        \\  dm sync [--config <path>] [--dry-run]
        \\
        \\Commands:
        \\  help      Show this help
        \\  status    Show current sync status
        \\  sync      Sync managed dotfiles
        \\
        \\Config:
        \\  default: ~/.config/dm/config
        \\
    , .{ Color.cyan, Color.reset });
}

test "parse no args shows help" {
    const parsed = try parse(&.{"dm"});
    try std.testing.expectEqual(Cli.Command.help, parsed.command);
    try std.testing.expect(!parsed.dry_run);
    try std.testing.expect(parsed.config_path == null);
}

test "parse sync flags" {
    const parsed = try parse(&.{ "dm", "sync", "--config", "./config", "--dry-run" });
    try std.testing.expectEqual(Cli.Command.sync, parsed.command);
    try std.testing.expect(parsed.dry_run);
    try std.testing.expectEqualStrings("./config", parsed.config_path.?);
}

test "reject dry run on status" {
    try std.testing.expectError(error.FlagNotAllowed, parse(&.{ "dm", "status", "--dry-run" }));
}

test "reject missing config path" {
    try std.testing.expectError(error.MissingConfigPath, parse(&.{ "dm", "sync", "--config" }));
}
