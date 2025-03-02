const std = @import("std");
const linux = std.os.linux;

pub fn exec_cmd(args: [][]u8) !void {
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // call deinit to free if necessary
    defer _ = gpa.deinit();
    const allocator = gpa.allocator(); // use allocator

    std.process.execv(allocator, args) catch return error.CmdFailed;
}

pub fn cleanup() void {
    _ = linux.umount("proc");
    _ = linux.umount("cgroup2");
}
