const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const discord = @import("../discord.zig");
const Formatter = @import("../formatter/Formatter.zig");

const global = @import("../global.zig");
const config = @import("../config.zig");

pub const MainError =
    error{ FormatterInitFailed, UnsupportedClock } ||
    Allocator.Error;
pub fn main(ally: Allocator, io: Io, queue: *Io.Queue(bool)) !void {
    stop(io, queue);
    var conn_retry_printed: bool = false;

    var details: Formatter, var state: Formatter = blk: {
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&stderr_buf);

        var first = Formatter.init(ally, config.get().details, &global.songinfo, &stderr.interface) catch |err| switch (err) {
            error.BufTooLong, error.ParseError => null,
            error.OutOfMemory => return MainError.OutOfMemory,
        };
        errdefer if (first != null) first.?.deinit(ally);
        var second = Formatter.init(ally, config.get().state, &global.songinfo, &stderr.interface) catch |err| switch (err) {
            error.BufTooLong, error.ParseError => null,
            error.OutOfMemory => return MainError.OutOfMemory,
        };
        errdefer if (second != null) second.?.deinit(ally);

        stderr.interface.flush() catch {};
        if (first == null or second == null) return MainError.FormatterInitFailed;
        break :blk .{ first.?, second.? };
    };
    defer details.deinit(ally);
    defer state.deinit(ally);

    while (true) {
        var client = discord.Client.init(ally, io, config.get().client_id) catch |err| switch (err) {
            discord.ConnectError.OutOfMemory => return MainError.OutOfMemory,
            discord.ConnectError.FileNotFound => {
                if (!conn_retry_printed)
                    std.log.info("connection to discord failed, automatic reconnect every 10 seconds", .{});
                conn_retry_printed = true;
                io.sleep(.fromSeconds(10), .boot) catch |err2| switch (err2) {
                    error.Canceled => return,
                    else => return MainError.UnsupportedClock,
                };
                continue;
            },
        };
        defer client.deinit(io);

        client.start(io) catch {
            if (!conn_retry_printed)
                std.log.info("handshake with discord failed, automatic retry every 10 seconds", .{});
            conn_retry_printed = true;
            io.sleep(.fromSeconds(10), .boot) catch |err2| switch (err2) {
                error.Canceled => return,
                else => return MainError.UnsupportedClock,
            };
            continue;
        };
        conn_retry_printed = false;

        var inner_work = try io.concurrent(innerWork, .{ io, &client, &details, &state, queue });
        defer inner_work.cancel(io) catch {};

        std.log.info("discord rpc connected", .{});

        switch (io.select(.{
            .sender = &client.sender_work.?,
            .inner = &inner_work,
        }) catch return) {
            .sender => {
                std.log.info("discord rpc disconnected", .{});
                continue;
            },
            .inner => |ret| return ret catch MainError.UnsupportedClock,
        }
    }
}

fn innerWork(
    io: Io,
    client: *discord.Client,
    details: *Formatter,
    state: *Formatter,
    queue: *Io.Queue(bool),
) error{ UnsupportedClock, Unexpected }!void {
    while (true) {
        inner(io, client, details, state, queue) catch |err| switch (err) {
            InnerError.UnsupportedClock, InnerError.Unexpected => |e| return e,
            InnerError.NoSpaceLeft => {
                std.log.warn("activity too long to write, skipped", .{});
                continue;
            },
        };
        return; // no error, is peaceful return
    }
}

const InnerError =
    error{ UnsupportedClock, Unexpected } ||
    std.fmt.BufPrintError;
fn inner(
    io: Io,
    client: *discord.Client,
    details: *Formatter,
    state: *Formatter,
    queue: *Io.Queue(bool),
) InnerError!void {
    var details_buf: [1024]u8 = undefined;
    var state_buf: [1024]u8 = undefined;

    while (queue.getOne(io) catch return) {
        const playinfo = blk: {
            global.playinfo_lock(io) catch return;
            defer global.playinfo_unlock(io);

            break :blk global.playinfo;
        };
        global.songinfo_lock(io) catch return;
        defer global.songinfo_unlock(io);

        if (playinfo.state == .stop) {
            client.clearActivity(io);
            continue;
        }

        const now = try std.posix.clock_gettime(.REALTIME);
        const start: u64 = @intCast(now.sec * std.time.ms_per_s - playinfo.elapsed);
        const end: u64 = start + playinfo.duration;

        details.evaluate();
        const details_str = try std.fmt.bufPrint(&details_buf, "{f}", .{details});
        state.evaluate();
        const state_str = try std.fmt.bufPrint(&state_buf, "{f}", .{state});

        const activity: discord.Activity = .{
            .details = details_str,
            .state = state_str,
            .activity_type = .listening,
            .status_display_type = .state,
            .timestamps = .{ .start = start, .end = end },
        };

        try client.updateActivity(io, activity);
    }
}

fn stop(io: Io, queue: *Io.Queue(bool)) void {
    const Handler = struct {
        var _queue: *Io.Queue(bool) = undefined;
        var _io: Io = undefined;

        const quit = if (builtin.os.tag == .windows) quit_windows else quit_posix;

        fn quit_posix(sig: std.c.SIG) callconv(.c) void {
            if (sig == .TERM)
                _queue.putOne(_io, false) catch {};
        }

        fn quit_windows(sig: u32) callconv(.c) c_int {
            const signal: std.posix.SIG = @enumFromInt(sig);
            while (signal != .TERM and signal != .BREAK) {} else {
                _queue.putOne(_io, false) catch {};
                return 0;
            }
        }
    };

    Handler._queue = queue;
    Handler._io = io;

    if (builtin.os.tag == .windows) {
        std.os.windows.SetConsoleCtrlHandler(Handler.quit, true) catch {
            std.log.err("seems like windows cannot handle signals", .{});
            std.process.exit(1);
        };
    } else {
        var handler: std.posix.Sigaction = .{
            .handler = .{ .handler = Handler.quit },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &handler, null);
    }
}
