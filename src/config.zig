const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const Config = types.Config;

pub fn parse(allocator: Allocator, contents: []const u8) !Config {
    var dotfiles_path: ?[]const u8 = null;
    var excludes: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, line, '#')) |comment_idx| {
            line = std.mem.trim(u8, line[0..comment_idx], " \t\r");
            if (line.len == 0) continue;
        }

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t\r");
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r");

        if (std.mem.eql(u8, key, "dotfiles-path")) {
            dotfiles_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "excludes")) {
            var parts = std.mem.splitScalar(u8, value, ',');
            while (parts.next()) |part_raw| {
                const part = std.mem.trim(u8, part_raw, " \t\r");
                if (part.len == 0) continue;
                try excludes.append(allocator, try allocator.dupe(u8, part));
            }
        } else {
            return error.UnknownConfigKey;
        }
    }

    return .{
        .dotfiles_path = dotfiles_path orelse return error.MissingDotfilesPath,
        .excludes = try excludes.toOwnedSlice(allocator),
    };
}

pub fn load(allocator: Allocator, io: Io, home: []const u8, override_path: ?[]const u8) !Config {
    const config_path = if (override_path) |path|
        try expandTilde(allocator, home, path)
    else
        try std.fmt.allocPrint(allocator, "{s}/.config/dm/config", .{home});

    const contents = try Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1024 * 1024));
    const parsed = try parse(allocator, contents);
    const expanded_dotfiles_path = try expandTilde(allocator, home, parsed.dotfiles_path);

    const stat = try Dir.cwd().statFile(io, expanded_dotfiles_path, .{ .follow_symlinks = true });
    if (stat.kind != .directory) return error.DotfilesPathIsNotDirectory;

    return .{
        .dotfiles_path = expanded_dotfiles_path,
        .excludes = parsed.excludes,
    };
}

pub fn expandTilde(allocator: Allocator, home: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, path[2..] });
    }
    return allocator.dupe(u8, path);
}

test "parse config" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator,
        \\# dm config
        \\dotfiles-path = ~/gh/dotfiles/home # inline comments are allowed
        \\excludes = README.md, .config/ghostty
        \\
    );
    defer allocator.free(parsed.dotfiles_path);
    defer allocator.free(parsed.excludes);
    defer for (parsed.excludes) |exclude| allocator.free(exclude);

    try std.testing.expectEqualStrings("~/gh/dotfiles/home", parsed.dotfiles_path);
    try std.testing.expectEqual(@as(usize, 2), parsed.excludes.len);
    try std.testing.expectEqualStrings("README.md", parsed.excludes[0]);
    try std.testing.expectEqualStrings(".config/ghostty", parsed.excludes[1]);
}

test "parse config supports no spaces around equals" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator,
        \\dotfiles-path=~/dots/home
        \\excludes=README.md,.config/ghostty
        \\
    );
    defer allocator.free(parsed.dotfiles_path);
    defer allocator.free(parsed.excludes);
    defer for (parsed.excludes) |exclude| allocator.free(exclude);

    try std.testing.expectEqualStrings("~/dots/home", parsed.dotfiles_path);
    try std.testing.expectEqual(@as(usize, 2), parsed.excludes.len);
    try std.testing.expectEqualStrings("README.md", parsed.excludes[0]);
    try std.testing.expectEqualStrings(".config/ghostty", parsed.excludes[1]);
}

test "parse config requires dotfiles path" {
    try std.testing.expectError(error.MissingDotfilesPath, parse(std.testing.allocator, "# no dotfiles path\n"));
}

test "expand tilde" {
    const allocator = std.testing.allocator;
    const expanded = try expandTilde(allocator, "/Users/me", "~/gh/dotfiles/home");
    defer allocator.free(expanded);

    try std.testing.expectEqualStrings("/Users/me/gh/dotfiles/home", expanded);
}
