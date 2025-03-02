const std = @import("std");
const linux = std.os.linux;
const dir = std.fs.cwd();

pub fn setup_cgroups_v2() !void {
    const cgroup_path = "/sys/fs/cgroup/containerz";
    // Create the cgroup directory
    _ = dir.statFile(cgroup_path) catch {
        std.debug.print("Directory does not exist: {s}\n", .{cgroup_path});
        try dir.makePath(cgroup_path);
    };
    std.debug.print("Directory exists: {s}\n", .{cgroup_path});

    //
    // Enable the "pids" controller
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/cgroup.subtree_control", .data = "+pids" });

    // Limit process count
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/pids.max", .data = "50" });

    // Add current process
    var pid_buf: [10]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{}", .{linux.getpid()});
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/cgroup.procs", .data = pid_str });

    _ = linux.mount("cgroup2", "/sys/fs/cgroup/containerz", "cgroup2", 0, 0);
}
