const std = @import("std");
const File = std.Io.File;

pub const Config = struct {
    dotfiles_path: []const u8,
    excludes: []const []const u8,
};

pub const ManagedEntry = struct {
    rel_path: []const u8,
    kind: File.Kind,
};

pub const Operation = struct {
    kind: Kind,
    rel_path: []const u8,

    pub const Kind = enum {
        create_home_dir,
        create_home_file,
        create_home_symlink,
        update_home,
        update_dotfiles,
        replace_home_type,
    };
};

pub const ExecuteResult = struct {
    error_count: usize,
    backup_root: []const u8,
};

pub fn operationName(kind: Operation.Kind) []const u8 {
    return switch (kind) {
        .create_home_dir => "create-home-dir",
        .create_home_file => "create-home-file",
        .create_home_symlink => "create-home-symlink",
        .update_home => "update-home",
        .update_dotfiles => "update-dotfiles",
        .replace_home_type => "replace-home-type",
    };
}
