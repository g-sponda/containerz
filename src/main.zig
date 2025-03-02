const c = @cImport({
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const dir = std.fs.cwd();
const cgroups = @import("cgroups.zig");
const helpers = @import("helpers.zig");

const STACK_SIZE = 1024 * 1024;

fn child(arg: usize) callconv(.C) u8 {
    // Convert `arg` back into a proper pointer to the argument slice
    const args_ptr: *[][]u8 = @ptrFromInt(arg);
    const args: [][]u8 = args_ptr.*;

    std.debug.print("Child execution.\n\tRunning command: {s} args: {s}\n", .{ args[0], args[1..] });

    defer helpers.cleanup();
    // std.debug.print("Configuring Cgroups\n", .{});
    // cgroups.setup_cgroups_v2() catch |err| {
    //     std.log.err("Error setting up cgroups: {}\n", .{err});
    //     return 1;
    // };

    std.debug.print("Configuring hostname\n", .{});
    set_hostname() catch |err| {
        std.log.err("Error setting hostname: {}\n", .{err});
        return 1;
    };

    std.debug.print("Configuring fylesystem\n", .{});
    set_container_fs() catch |err| {
        std.log.err("Error setting container filesystem: {}\n", .{err});
        return 1;
    };

    std.debug.print("executing command!!!\n", .{});
    helpers.exec_cmd(args) catch |err| {
        std.log.err("Error executing command: {}\n", .{err});
        return 1;
    };

    std.debug.print("Exiting child process, bye\n", .{});
    return 0;
}

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

    const flags = linux.CLONE.NEWUTS | linux.CLONE.NEWPID | linux.CLONE.NEWNS | linux.CLONE.NEWUSER;

    // Initialize the PID and ptid for the clone call.
    var child_pid: i32 = 0;
    var ptid: i32 = undefined;

    // Allocate the child stack and ensure it's correctly initialized.
    const child_stack: [STACK_SIZE]u8 align(16) = undefined;

    // Call clone to create the child process
    const pid = linux.clone(&child, @intFromPtr(&child_stack[0]) + child_stack.len, flags, @intFromPtr(&args), &ptid, 0, &child_pid);

    // Check if the clone was successful
    if (pid < 0) {
        std.debug.print("Error: clone failed with errno: {}\n", .{posix.errno(pid)});
        return;
    }

    std.debug.print("Clone successful, PID: {}\n", .{pid});

    const unshare_result = linux.unshare(flags); // Need to check if this unshare will be needed, after fixing parent process to close when child exit bash
    switch (posix.errno(unshare_result)) {
        .SUCCESS => std.debug.print("Unshare successful\n", .{}),
        .PERM => std.debug.print("Error: Operation not permitted\n", .{}),
        .INVAL => std.debug.print("Error: Invalid argument\n", .{}),
        .NOMEM => std.debug.print("Error: Insufficient kernel memory\n", .{}),
        else => |err| std.debug.print("Unexpected error: {}\n", .{err}),
    }

    // Now that the child is cloned, we can configure user namespaces if necessary
    try setup_user_ns();

    // Parent waits for the child process to exit
    var status: i32 = 0;

    // Wait for the child to exit, without WNOHANG flag (we want to block until it exits)
    const ret = c.waitpid(@intCast(pid), &status, 0); // TODO: fix `Error: waitpid failed, errno: os.linux.E__enum_4178.CHILD`
    if (ret < 0) {
        std.debug.print("Error: waitpid failed, errno: {}\n", .{posix.errno(ret)});
        return;
    }

    // Print the exit status of the child
    std.debug.print("Child process exited with status: {}\n", .{status});

    // Optionally, exit the parent process after the child has exited.
    // std.process.exit(0); // Uncomment if you want to exit the parent after the child.
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

fn set_container_fs() !void {
    // // Change the root fylesystem to the one created beforehand at the defined value on the chroot bellow
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
