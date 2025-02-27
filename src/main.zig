const c = @cImport({
    @cInclude("unistd.h");
});
const std = @import("std");
const linux = std.os.linux;
const dir = std.fs.cwd();

pub fn main() !void {
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // call deinit to free if necessary
    defer _ = gpa.deinit();
    const allocator = gpa.allocator(); // use allocator

    // Parse args into string array (error union needs 'try')
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("Usage: containerz run <cmd> <args>", .{});
        std.process.exit(1);
    }

    const cmd = args[1];

    std.debug.print("cmd is: {c}\n", .{cmd[0]});
    switch (cmd[0]) {
        'r' => try run(
            args[2..],
        ),
        'c' => try child(args[2..]),

        else => std.debug.print("Unkown command: {s}\n", .{cmd}),
    }
}

// We need to keep in mind some principles that make the container processes isolated from the ones running in the host machine
//    *namespaces* are used to group kernel objects into different sets that can be accessed by specific process trees.
//    For example, pid namespaces limit the view of the process list to the processes within the namespace.
//
//    *cgroups* is a mechanism to limit usage of resources like memory, disk io, and cpu-time.
//
//    *capabilities* are used here to set some coarse limits on what uid 0 can do.

// Create a container and run <cmd> inside it.
fn run(args: [][]u8) !void {
    std.debug.print("Run execution.\n\tRunning command: {s} args: {s}\n", .{ args[0], args[1..] });
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // call deinit to free if necessary
    defer _ = gpa.deinit();
    const allocator = gpa.allocator(); // use allocator

    const child_args = try build_child_args(args);
    std.debug.print("Child args: {s}\n", .{child_args});
    var proc = std.process.Child.init(child_args, allocator);
    proc.stdin = std.io.getStdIn();
    proc.stdout = std.io.getStdOut();
    proc.stderr = std.io.getStdErr();

    try isolate();
    try setup_user_ns();

    try proc.spawn(); // start child process and wait
    _ = try proc.wait();
}

fn build_child_args(args: [][]u8) ![][]u8 {
    const arrayllocator = std.heap.page_allocator;
    var child_args = std.ArrayList([]u8).init(arrayllocator);
    defer child_args.deinit();

    try child_args.append(@constCast("/proc/self/exe"));
    try child_args.append(@constCast("child"));
    for (args) |arg| {
        try (child_args.append(arg));
    }
    return try child_args.toOwnedSlice();
}

// Setup the container and run the command specified as argument
fn child(args: [][]u8) !void {
    std.debug.print("Child execution.\n\tRunning command: {s} args: {s}\n", .{ args[0], args[1..] });

    defer cleanup();

    try set_hostname();
    try setup_fs();
    try setup_cgroups_v2();
    try exec_cmd(args);
}

// Isolate namespaces
fn isolate() !void {
    // We use pipes here to combine multiple bitmask flags into one integer,
    // so all these namespaces are isolated together.
    const flags = linux.CLONE.NEWUSER | linux.CLONE.NEWPID | linux.CLONE.NEWUTS | linux.CLONE.NEWNS;
    _ = linux.unshare(flags);
}

fn set_hostname() !void {
    const container_hostname = "containerz";
    const result = c.sethostname(container_hostname.ptr, container_hostname.len);

    if (result != 0) {
        const err = std.posix.errno(result);
        switch (err) {
            .ACCES => std.debug.print("Permission denied. Try running as root.\n", .{}),
            .FAULT => std.debug.print("Invalid address space.\n", .{}),
            .INVAL => std.debug.print("Invalid hostname length.\n", .{}),
            else => std.debug.print("Failed to change hostname {s}.\n", .{@tagName(err)}),
        }
        return error.SetHostnameFailed;
    }
}

fn setup_fs() !void {
    // Change the root fylesystem to the one created beforehand at the defined value on the chroot bellow
    _ = linux.chroot("/home/containerz/genericfs");
    _ = linux.chdir("/");

    // Mount new procfs inside the container
    _ = linux.mount("proc", "proc", "proc", 0, 0);
}

// Configure User Namespace (non-root)
// map UID 0 inside the container to your real user outside(UID 1000)
// disable setgroups before modifying user/group mapping
fn setup_user_ns() !void {
    // Require for setting UID mapping
    try dir.writeFile(.{ .sub_path = "/proc/self/setgroups", .data = "deny" });
    try dir.writeFile(.{ .sub_path = "/proc/self/uid_map", .data = "0 1000 1" });
    try dir.writeFile(.{ .sub_path = "/proc/self/gid_map", .data = "0 1000 1" });
}

fn is_cgroups_v2() bool {
    const path_cgroup_file_cgroup_v2 = "/sys/fs/cgroup/cgroup.controllers";

    // check if the call didn't returned error, so it was a success and the file exists,
    // this file is a file that exists on cgroup v2, so if it exists we now the cgroup is the v2,
    // otherwise if we get an error it might be v1
    dir.access(path_cgroup_file_cgroup_v2, .{}) catch return false;

    return true;
}

fn setup_cgroups() !void {
    if (is_cgroups_v2()) {
        std.debug.print("cgroups V2", .{});
        try setup_cgroups_v2();
    } else {
        std.debug.print("cgroups V1", .{});
        try setup_cgroups_v1();
    }
}

// Configure Cgroups to limit resources, and protect the container from
// for example a fork bomb
fn setup_cgroups_v1() !void {
    const cgroup_path = "/sys/fs/cgroup/pids/containerz";

    // Create Cgroup
    try dir.makePath(cgroup_path);

    // limit the number of processes to 20
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/pids.max", .data = "50" });

    // automatically remove the cgroup when empty
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/notify_on_release", .data = "1" });

    // add the current process to the cgroup
    var pid_buf: [10]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{}", .{linux.getpid()});

    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/cgroup.procs", .data = pid_str });
}

fn setup_cgroups_v2() !void {
    const cgroup_path = "/sys/fs/cgroup/containerz";

    // Create the cgroup directory
    try dir.makePath(cgroup_path);
    //TODO: fix: `thread 1 panic: reached unreachable code`
    var cgroup_dir = try dir.openDir(cgroup_path, .{ .iterate = true });
    defer cgroup_dir.close();

    // Change ownership to allow non-root access (optional, but safer)
    const uid = 1000; // Change to your user ID
    const gid = 1000; // Change to your group ID
    try cgroup_dir.chown(uid, gid);
    std.debug.print("Chown gaven", .{});

    // Enable the "pids" controller
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/cgroup.subtree_control", .data = "+pids" });

    // Limit process count
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/pids.max", .data = "50" });

    // Add current process
    var pid_buf: [10]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{}", .{linux.getpid()});
    try dir.writeFile(.{ .sub_path = cgroup_path ++ "/cgroup.procs", .data = pid_str });
}

fn exec_cmd(args: [][]u8) !void {
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // call deinit to free if necessary
    defer _ = gpa.deinit();
    const allocator = gpa.allocator(); // use allocator

    std.process.execv(allocator, args) catch unreachable;
}

fn cleanup() void {
    _ = linux.umount("proc");
}
