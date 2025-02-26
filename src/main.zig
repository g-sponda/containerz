const c = @cImport({
    @cInclude("unistd.h");
});
const std = @import("std");
const linux = std.os.linux;

pub fn main() !void {
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // call deinit to free if if necessary
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
    std.debug.print("Run execution.\n\tRunning command: {s} args: {s}", .{ args[0], args[1..] });
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // call deinit to free if if necessary
    defer _ = gpa.deinit();
    const allocator = gpa.allocator(); // use allocator

    var proc = std.process.Child.init(args, allocator);
    proc.stdin = std.io.getStdIn();
    proc.stdout = std.io.getStdOut();
    proc.stderr = std.io.getStdErr();

    try isolate();
    try setup_user_ns();

    _ = try proc.spawnAndWait(); // start child process and wait
}

// create
fn child(args: [][]u8) !void {
    std.debug.print("Child execution.\nRunning command: {s} args: {s}", .{ args[0], args[1..] });

    defer cleanup();

    try set_hostname();
    try setup_fs();
    try setup_Cgroups();
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
    // try std.posix.sethostname("containerz");
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
    // Change the root fs
    _ = linux.chroot("/home/containerz");
    _ = linux.chdir("/");

    // Mount new procfs inside the container
    _ = linux.mount("proc", "proc", "proc", 0, 0);
}

// Configure User Namespace (non-root)
// map UID 0 inside the container to your real user outside(UID 1000)
// disable setgroups before modifying user/group mapping
fn setup_user_ns() !void {
    // Require for setting UID mapping
    try std.fs.cwd().writeFile(.{ .sub_path = "/proc/self/setgroups", .data = "deny" });
    try std.fs.cwd().writeFile(.{ .sub_path = "/proc/self/uid_map", .data = "0 1000 1" });
    try std.fs.cwd().writeFile(.{ .sub_path = "/proc/self/gid_map", .data = "0 1000 1" });
}

// Configure Cgroups to limit resources, and protect the container from
// for example a fork bomb
fn setup_Cgroups() !void {
    const cgroup_path = "/sys/fs/cgroup/pids/containerz";

    // Create Cgroup
    _ = linux.mkdir(cgroup_path, 0o755);

    // limit the number of processes to 20
    try std.fs.cwd().writeFile(.{ .sub_path = cgroup_path ++ "/pids.max", .data = "50" });

    // automatically remove the cgroup when empty
    try std.fs.cwd().writeFile(.{ .sub_path = cgroup_path ++ "/notify_on_release", .data = "1" });

    // add the current process to the cgroup
    var pid_buf: [10]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{}", .{linux.getpid()});

    try std.fs.cwd().writeFile(.{ .sub_path = cgroup_path ++ "/cgroup.procs", .data = pid_str });
}

fn exec_cmd(args: [][]u8) !void {
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // call deinit to free if if necessary
    defer _ = gpa.deinit();
    const allocator = gpa.allocator(); // use allocator

    std.process.execv(allocator, args) catch unreachable;
}

fn cleanup() void {
    _ = linux.umount("proc");
}
