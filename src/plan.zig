const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const paths = @import("paths.zig");

const Config = types.Config;
const ManagedEntry = types.ManagedEntry;
const Operation = types.Operation;

pub fn build(allocator: Allocator, io: Io, home: []const u8, config: Config) ![]Operation {
    var entries: std.ArrayList(ManagedEntry) = .empty;
    try discoverEntries(allocator, io, config, "", &entries);

    var operations: std.ArrayList(Operation) = .empty;

    for (entries.items) |entry| {
        const dot_path = try paths.join(allocator, config.dotfiles_path, entry.rel_path);
        const home_path = try paths.join(allocator, home, entry.rel_path);

        const dot_stat = try statPath(io, dot_path);
        const home_stat = statPath(io, home_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        if (home_stat == null) {
            switch (entry.kind) {
                .directory => try operations.append(allocator, .{ .kind = .create_home_dir, .rel_path = entry.rel_path }),
                .sym_link => try operations.append(allocator, .{ .kind = .create_home_symlink, .rel_path = entry.rel_path }),
                else => try operations.append(allocator, .{ .kind = .create_home_file, .rel_path = entry.rel_path }),
            }
            continue;
        }

        const hstat = home_stat.?;
        const dstat = dot_stat.?;

        if (hstat.kind != dstat.kind) {
            // The dotfiles tree is authoritative for path structure. If a
            // managed path has a different type in $HOME, replace the $HOME
            // path regardless of modification time.
            try operations.append(allocator, .{ .kind = .replace_home_type, .rel_path = entry.rel_path });
            continue;
        }

        if (dstat.kind == .directory) continue;

        if (dstat.mtime.nanoseconds > hstat.mtime.nanoseconds) {
            try operations.append(allocator, .{ .kind = .update_home, .rel_path = entry.rel_path });
        } else if (hstat.mtime.nanoseconds > dstat.mtime.nanoseconds) {
            try operations.append(allocator, .{ .kind = .update_dotfiles, .rel_path = entry.rel_path });
        }
    }

    sortOperations(operations.items);
    return operations.toOwnedSlice(allocator);
}

fn statPath(io: Io, path: []const u8) !?File.Stat {
    return Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
}

fn discoverEntries(
    allocator: Allocator,
    io: Io,
    config: Config,
    rel_dir: []const u8,
    entries: *std.ArrayList(ManagedEntry),
) !void {
    const abs_dir = if (rel_dir.len == 0)
        config.dotfiles_path
    else
        try paths.join(allocator, config.dotfiles_path, rel_dir);

    var dir = try Dir.openDirAbsolute(io, abs_dir, .{ .iterate = true, .access_sub_paths = true, .follow_symlinks = false });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |dir_entry| {
        const rel = if (rel_dir.len == 0)
            try allocator.dupe(u8, dir_entry.name)
        else
            try paths.join(allocator, rel_dir, dir_entry.name);

        if (isExcluded(config.excludes, rel)) continue;

        const abs = try paths.join(allocator, config.dotfiles_path, rel);
        const stat = try Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false });
        try entries.append(allocator, .{ .rel_path = rel, .kind = stat.kind });

        if (stat.kind == .directory) {
            try discoverEntries(allocator, io, config, rel, entries);
        }
    }
}

fn isExcluded(excludes: []const []const u8, rel_path: []const u8) bool {
    for (excludes) |exclude| {
        if (hasStar(exclude)) {
            if (globExcludesPath(exclude, rel_path)) return true;
            continue;
        }

        if (std.mem.eql(u8, rel_path, exclude)) return true;
        if (rel_path.len > exclude.len and std.mem.startsWith(u8, rel_path, exclude) and rel_path[exclude.len] == '/') return true;
    }
    return false;
}

fn hasStar(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '*') != null;
}

fn globExcludesPath(pattern: []const u8, rel_path: []const u8) bool {
    var candidate = rel_path;
    while (true) {
        if (matchGlobPattern(pattern, candidate)) return true;
        candidate = paths.parent(candidate) orelse return false;
    }
}

fn matchGlobPattern(pattern: []const u8, rel_path: []const u8) bool {
    if (!isValidGlobPattern(pattern)) return false;
    return matchGlobSegments(pattern, rel_path);
}

fn isValidGlobPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    var remaining = pattern;
    while (true) {
        const split = splitFirstSegment(remaining);
        if (split.segment.len == 0) return false;
        if (hasStar(split.segment) and !std.mem.eql(u8, split.segment, "*")) return false;

        remaining = split.rest orelse return true;
    }
}

const SegmentSplit = struct {
    segment: []const u8,
    rest: ?[]const u8,
};

fn splitFirstSegment(path: []const u8) SegmentSplit {
    if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
        return .{ .segment = path[0..slash], .rest = path[slash + 1 ..] };
    }
    return .{ .segment = path, .rest = null };
}

fn matchGlobSegments(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;

    const pattern_split = splitFirstSegment(pattern);
    const pattern_rest = pattern_split.rest orelse "";

    if (std.mem.eql(u8, pattern_split.segment, "*")) {
        if (pattern_split.rest == null) return true;
        if (matchGlobSegments(pattern_rest, path)) return true;

        var path_remaining = path;
        while (path_remaining.len != 0) {
            const path_split = splitFirstSegment(path_remaining);
            if (path_split.segment.len == 0) return false;
            path_remaining = path_split.rest orelse "";
            if (matchGlobSegments(pattern_rest, path_remaining)) return true;
        }

        return false;
    }

    if (path.len == 0) return false;

    const path_split = splitFirstSegment(path);
    if (path_split.segment.len == 0) return false;
    if (!std.mem.eql(u8, pattern_split.segment, path_split.segment)) return false;

    return matchGlobSegments(pattern_rest, path_split.rest orelse "");
}

fn sortOperations(ops: []Operation) void {
    std.mem.sort(Operation, ops, {}, struct {
        fn lessThan(_: void, a: Operation, b: Operation) bool {
            const ar = rank(a.kind);
            const br = rank(b.kind);
            if (ar != br) return ar < br;
            return std.mem.lessThan(u8, a.rel_path, b.rel_path);
        }

        fn rank(kind: Operation.Kind) u8 {
            return switch (kind) {
                .replace_home_type => 0,
                .create_home_dir => 1,
                .create_home_file, .create_home_symlink => 2,
                .update_home, .update_dotfiles => 3,
            };
        }
    }.lessThan);
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

fn setMtime(io: Io, absolute_path: []const u8, nanoseconds: i96) !void {
    const file = try Dir.cwd().openFile(io, absolute_path, .{ .mode = .read_only, .follow_symlinks = false });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = Io.Timestamp.fromNanoseconds(nanoseconds) } });
}

test "isExcluded keeps exact relative exclude behavior" {
    try std.testing.expect(isExcluded(&.{".config/ghostty"}, ".config/ghostty"));
    try std.testing.expect(isExcluded(&.{".config/ghostty"}, ".config/ghostty/config"));
    try std.testing.expect(!isExcluded(&.{".config/ghostty"}, "foo/.config/ghostty"));
}

test "isExcluded supports star segment excludes at any depth" {
    const excludes = &.{"*/.cpcache"};

    try std.testing.expect(isExcluded(excludes, ".cpcache"));
    try std.testing.expect(isExcluded(excludes, ".clojure/.cpcache"));
    try std.testing.expect(isExcluded(excludes, ".clj/something/.cpcache"));
    try std.testing.expect(isExcluded(excludes, "something/cool/.cpcache"));
    try std.testing.expect(isExcluded(excludes, ".clj/something/.cpcache/cache.edn"));

    try std.testing.expect(!isExcluded(excludes, ".cpcache-old"));
    try std.testing.expect(!isExcluded(excludes, ".clj/.cpcache-old"));
}

test "isExcluded star segment matches zero or more path segments" {
    try std.testing.expect(isExcluded(&.{".config/*"}, ".config"));
    try std.testing.expect(isExcluded(&.{".config/*"}, ".config/nvim"));
    try std.testing.expect(isExcluded(&.{".config/*"}, ".config/nvim/init.lua"));
    try std.testing.expect(isExcluded(&.{"foo/*/bar"}, "foo/bar"));
    try std.testing.expect(isExcluded(&.{"foo/*/bar"}, "foo/x/bar"));
    try std.testing.expect(isExcluded(&.{"foo/*/bar"}, "foo/x/y/bar"));
}

test "isExcluded ignores unsupported embedded star patterns" {
    try std.testing.expect(!isExcluded(&.{"foo*/bar"}, "foo123/bar"));
    try std.testing.expect(!isExcluded(&.{"foo*/bar"}, "foo*/bar"));
    try std.testing.expect(!isExcluded(&.{"*.edn"}, "deps.edn"));
    try std.testing.expect(!isExcluded(&.{"*/.clj-*"}, ".clj-kondo"));
}

test "isExcluded ignores glob patterns with empty segments" {
    try std.testing.expect(!isExcluded(&.{"*/foo/"}, "foo"));
    try std.testing.expect(!isExcluded(&.{"foo//*/bar"}, "foo/x/bar"));
    try std.testing.expect(!isExcluded(&.{"/*/bar"}, "foo/bar"));
}

test "build plan creates missing home files and updates older dotfiles" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dot/home/.config/nvim");
    try tmp.dir.createDirPath(io, "home/.config/nvim");
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.zshrc", .data = "repo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.config/nvim/init.lua", .data = "repo-old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/nvim/init.lua", .data = "home-new\n" });

    const p = try tmpPaths(allocator, &tmp);
    defer allocator.free(p.root);
    defer allocator.free(p.dotfiles_home);
    defer allocator.free(p.home);

    const dot_init = try paths.join(allocator, p.dotfiles_home, ".config/nvim/init.lua");
    const home_init = try paths.join(allocator, p.home, ".config/nvim/init.lua");
    defer allocator.free(dot_init);
    defer allocator.free(home_init);
    try setMtime(io, dot_init, 100);
    try setMtime(io, home_init, 200);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const operations = try build(arena.allocator(), io, p.home, .{ .dotfiles_path = p.dotfiles_home, .excludes = &.{} });

    try std.testing.expectEqual(@as(usize, 2), operations.len);
    try std.testing.expectEqual(Operation.Kind.create_home_file, operations[0].kind);
    try std.testing.expectEqualStrings(".zshrc", operations[0].rel_path);
    try std.testing.expectEqual(Operation.Kind.update_dotfiles, operations[1].kind);
    try std.testing.expectEqualStrings(".config/nvim/init.lua", operations[1].rel_path);
}

test "build plan respects exact relative excludes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dot/home/.config/ghostty");
    try tmp.dir.createDirPath(io, "home/.config");
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.zshrc", .data = "repo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.config/ghostty/config", .data = "ignored\n" });

    const p = try tmpPaths(allocator, &tmp);
    defer allocator.free(p.root);
    defer allocator.free(p.dotfiles_home);
    defer allocator.free(p.home);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const operations = try build(arena.allocator(), io, p.home, .{
        .dotfiles_path = p.dotfiles_home,
        .excludes = &.{".config/ghostty"},
    });

    try std.testing.expectEqual(@as(usize, 1), operations.len);
    try std.testing.expectEqual(Operation.Kind.create_home_file, operations[0].kind);
    try std.testing.expectEqualStrings(".zshrc", operations[0].rel_path);
}

test "build plan respects star segment glob excludes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dot/home/.cpcache");
    try tmp.dir.createDirPath(io, "dot/home/.clojure/.cpcache");
    try tmp.dir.createDirPath(io, "dot/home/.clj/something/.cpcache");
    try tmp.dir.createDirPath(io, "dot/home/something/cool/.cpcache");
    try tmp.dir.createDirPath(io, "home/.clojure");
    try tmp.dir.createDirPath(io, "home/.clj/something");
    try tmp.dir.createDirPath(io, "home/something/cool");
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.zshrc", .data = "repo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.cpcache/cache.edn", .data = "ignored\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.clojure/.cpcache/cache.edn", .data = "ignored\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.clj/something/.cpcache/cache.edn", .data = "ignored\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/something/cool/.cpcache/cache.edn", .data = "ignored\n" });

    const p = try tmpPaths(allocator, &tmp);
    defer allocator.free(p.root);
    defer allocator.free(p.dotfiles_home);
    defer allocator.free(p.home);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const operations = try build(arena.allocator(), io, p.home, .{
        .dotfiles_path = p.dotfiles_home,
        .excludes = &.{"*/.cpcache"},
    });

    try std.testing.expectEqual(@as(usize, 1), operations.len);
    try std.testing.expectEqual(Operation.Kind.create_home_file, operations[0].kind);
    try std.testing.expectEqualStrings(".zshrc", operations[0].rel_path);
}

test "build plan replaces home path when dotfiles type differs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dot/home/.config/nvim");
    try tmp.dir.createDirPath(io, "home/.config");
    try tmp.dir.writeFile(io, .{ .sub_path = "dot/home/.config/nvim/init.lua", .data = "repo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/nvim", .data = "file where directory should be\n" });

    const p = try tmpPaths(allocator, &tmp);
    defer allocator.free(p.root);
    defer allocator.free(p.dotfiles_home);
    defer allocator.free(p.home);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const operations = try build(arena.allocator(), io, p.home, .{ .dotfiles_path = p.dotfiles_home, .excludes = &.{} });

    try std.testing.expectEqual(Operation.Kind.replace_home_type, operations[0].kind);
    try std.testing.expectEqualStrings(".config/nvim", operations[0].rel_path);
}
