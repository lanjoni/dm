const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const paths = @import("paths.zig");

const Config = types.Config;
const Operation = types.Operation;
const ExecuteResult = types.ExecuteResult;

pub fn execute(allocator: Allocator, io: Io, home: []const u8, config: Config, plan: []const Operation) !ExecuteResult {
    const timestamp = Io.Clock.real.now(io).toNanoseconds();
    const backup_root = try std.fmt.allocPrint(allocator, "/tmp/dm/{d}", .{timestamp});
    var error_count: usize = 0;

    for (plan) |op| {
        executeOperation(allocator, io, home, config, backup_root, op) catch |err| {
            error_count += 1;
            std.debug.print("dm: failed {s} {s}: {s}\n", .{ types.operationName(op.kind), op.rel_path, @errorName(err) });
        };
    }

    return .{ .error_count = error_count, .backup_root = backup_root };
}

fn executeOperation(allocator: Allocator, io: Io, home: []const u8, config: Config, backup_root: []const u8, op: Operation) !void {
    const dot_path = try paths.join(allocator, config.dotfiles_path, op.rel_path);
    const home_path = try paths.join(allocator, home, op.rel_path);

    switch (op.kind) {
        .create_home_dir => try ensureDir(io, home_path),
        .create_home_file => try copyFilePreserve(io, dot_path, home_path, false),
        .create_home_symlink => try copySymlink(io, dot_path, home_path, false),
        .update_home => {
            try backupExisting(allocator, io, backup_root, "home", home_path, op.rel_path);
            try copyAny(allocator, io, dot_path, home_path, true);
        },
        .replace_home_type => {
            try backupExisting(allocator, io, backup_root, "home", home_path, op.rel_path);
            const dot_stat = try Dir.cwd().statFile(io, dot_path, .{ .follow_symlinks = false });
            if (dot_stat.kind == .directory) {
                try ensureDir(io, home_path);
            } else {
                try copyAny(allocator, io, dot_path, home_path, true);
            }
        },
        .update_dotfiles => {
            try backupExisting(allocator, io, backup_root, "dotfiles", dot_path, op.rel_path);
            try copyAny(allocator, io, home_path, dot_path, true);
        },
    }
}

fn backupExisting(allocator: Allocator, io: Io, backup_root: []const u8, side: []const u8, existing_path: []const u8, rel_path: []const u8) !void {
    const side_root = try paths.join(allocator, backup_root, side);
    const backup_path = try paths.join(allocator, side_root, rel_path);
    if (paths.parent(backup_path)) |parent| try ensureDir(io, parent);
    try Dir.renameAbsolute(existing_path, backup_path, io);
}

fn copyAny(allocator: Allocator, io: Io, source: []const u8, dest: []const u8, replace: bool) anyerror!void {
    const stat = try Dir.cwd().statFile(io, source, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .directory => try copyDirectory(allocator, io, source, dest),
        .sym_link => try copySymlink(io, source, dest, replace),
        else => try copyFilePreserve(io, source, dest, replace),
    }
}

fn copyDirectory(allocator: Allocator, io: Io, source: []const u8, dest: []const u8) anyerror!void {
    try ensureDir(io, dest);

    var dir = try Dir.openDirAbsolute(io, source, .{ .iterate = true, .access_sub_paths = true, .follow_symlinks = false });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const source_child = try paths.join(allocator, source, entry.name);
        const dest_child = try paths.join(allocator, dest, entry.name);
        try copyAny(allocator, io, source_child, dest_child, true);
    }
}

fn copyFilePreserve(io: Io, source: []const u8, dest: []const u8, replace: bool) !void {
    if (paths.parent(dest)) |parent| try ensureDir(io, parent);
    const stat = try Dir.cwd().statFile(io, source, .{ .follow_symlinks = false });
    try Dir.copyFileAbsolute(source, dest, io, .{ .permissions = stat.permissions, .make_path = true, .replace = replace });

    const dest_file = try Dir.cwd().openFile(io, dest, .{ .mode = .read_only, .follow_symlinks = false });
    defer dest_file.close(io);
    try dest_file.setTimestamps(io, .{ .access_timestamp = File.SetTimestamp.init(stat.atime), .modify_timestamp = .{ .new = stat.mtime } });
}

fn copySymlink(io: Io, source: []const u8, dest: []const u8, replace: bool) !void {
    if (paths.parent(dest)) |parent| try ensureDir(io, parent);
    if (replace) {
        try Dir.cwd().deleteTree(io, dest);
    }
    var target_buf: [Dir.max_path_bytes]u8 = undefined;
    const len = try Dir.cwd().readLink(io, source, &target_buf);
    const target = target_buf[0..len];
    try Dir.cwd().symLink(io, target, dest, .{});
}

fn ensureDir(io: Io, path: []const u8) !void {
    try Dir.cwd().createDirPath(io, path);
}

const TestPaths = struct {
    root: []const u8,
    dotfiles_home: []const u8,
    home: []const u8,
};

fn tmpPaths(allocator: Allocator, tmp: *std.testing.TmpDir) !TestPaths {
    var root_buf: [Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = try allocator.dupe(u8, root_buf[0..root_len]);
    return .{
        .root = root,
        .dotfiles_home = try paths.join(allocator, root, "dot/home"),
        .home = try paths.join(allocator, root, "home"),
    };
}

test "execute updates dotfiles and backs up previous destination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dot/home");
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.zshrc", .data = "repo-old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "home-new\n" });

    const p = try tmpPaths(allocator, &tmp);
    defer allocator.free(p.root);
    defer allocator.free(p.dotfiles_home);
    defer allocator.free(p.home);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const operations = [_]Operation{.{ .kind = .update_dotfiles, .rel_path = ".zshrc" }};
    const result = try execute(arena.allocator(), io, p.home, .{ .dotfiles_path = p.dotfiles_home, .excludes = &.{} }, &operations);

    const dot_zshrc = try paths.join(allocator, p.dotfiles_home, ".zshrc");
    defer allocator.free(dot_zshrc);
    const backup_zshrc = try paths.join(allocator, result.backup_root, "dotfiles/.zshrc");
    defer allocator.free(backup_zshrc);

    const updated = try Dir.cwd().readFileAlloc(io, dot_zshrc, allocator, .limited(1024));
    defer allocator.free(updated);
    const backup = try Dir.cwd().readFileAlloc(io, backup_zshrc, allocator, .limited(1024));
    defer allocator.free(backup);

    try std.testing.expectEqual(@as(usize, 0), result.error_count);
    try std.testing.expectEqualStrings("home-new\n", updated);
    try std.testing.expectEqualStrings("repo-old\n", backup);
}

test "execute preserves symlinks as symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dot/home/.config");
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.symLink(io, "../target", "dot/home/.config/link", .{});

    const p = try tmpPaths(allocator, &tmp);
    defer allocator.free(p.root);
    defer allocator.free(p.dotfiles_home);
    defer allocator.free(p.home);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const operations = [_]Operation{ .{ .kind = .create_home_dir, .rel_path = ".config" }, .{ .kind = .create_home_symlink, .rel_path = ".config/link" } };
    const result = try execute(arena.allocator(), io, p.home, .{ .dotfiles_path = p.dotfiles_home, .excludes = &.{} }, &operations);

    const home_link = try paths.join(allocator, p.home, ".config/link");
    defer allocator.free(home_link);
    const stat = try Dir.cwd().statFile(io, home_link, .{ .follow_symlinks = false });
    var target_buf: [Dir.max_path_bytes]u8 = undefined;
    const target_len = try Dir.cwd().readLink(io, home_link, &target_buf);

    try std.testing.expectEqual(@as(usize, 0), result.error_count);
    try std.testing.expectEqual(File.Kind.sym_link, stat.kind);
    try std.testing.expectEqualStrings("../target", target_buf[0..target_len]);
}
