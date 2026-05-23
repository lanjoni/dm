const std = @import("std");
const Io = std.Io;

const dm = @import("dm");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse {
        std.debug.print("dm: HOME is not set\n", .{});
        std.process.exit(1);
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    const code = dm.run(arena, .{
        .args = args,
        .home = home,
        .io = init.io,
        .out = stdout_writer,
    }) catch |err| {
        std.debug.print("dm: unexpected error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    try stdout_writer.flush();
    std.process.exit(code);
}
