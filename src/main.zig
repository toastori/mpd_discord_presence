const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const global = @import("global.zig");
const discord = @import("discord.zig");

const Formatter = @import("formatter/Formatter.zig");
const SongInfo = @import("song_state/SongInfo.zig");

pub fn main() !void {
    var debug_ally = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}).init else void{};
    defer if (@TypeOf(debug_ally) == std.heap.DebugAllocator(.{}))
        if (debug_ally.deinit() == .leak) std.debug.print("debug allocator: {d} leaks found\n", .{debug_ally.detectLeaks()});
    const base_ally = if (builtin.mode == .Debug) debug_ally.allocator() else std.heap.smp_allocator;

    var threadsafe_ally = std.heap.ThreadSafeAllocator{ .child_allocator = base_ally };
    const ally = threadsafe_ally.allocator();

    var io = std.Io.Threaded.init(ally);
    defer io.deinit();

    defer global.deinit(ally, io.io());

    return juicy_main(ally, io.io());
}

fn juicy_main(ally: Allocator, io: Io) !void {
    var queue: Io.Queue(bool) = .init(&.{});

    var info_work = try io.concurrent(info, .{ ally, io, &queue });
    defer info_work.cancel(io) catch {};
    var print_work = try io.concurrent(rpc, .{ ally, io, &queue });
    defer print_work.cancel(io) catch {};

    switch (io.select(.{
        .info = &info_work,
        .print = &print_work,
    }) catch unreachable) {
        .info => |ret| try ret,
        .print => |ret| try ret,
    }
    std.debug.print("exit peacefully\n", .{});
}

fn stop(io: Io, queue: *Io.Queue(bool)) !void {
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
        try std.os.windows.SetConsoleCtrlHandler(Handler.quit, true);
    } else {
        var handler: std.posix.Sigaction = .{
            .handler = .{ .handler = Handler.quit },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &handler, null);
    }
}

fn info(ally: Allocator, io: Io, queue: *Io.Queue(bool)) !void {
    var socket = Io.net.UnixAddress.init("/tmp/mpd_socket") catch unreachable;
    var stream = try socket.connect(io);
    defer stream.close(io);

    var reader_buf: [4096]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &reader_buf);
    var writer = stream.writer(io, &.{});
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    if (try reader.interface.takeDelimiter('\n')) |line| {
        if (!std.mem.startsWith(u8, line, "OK MPD"))
            return error.UnexpectedResponse;
    }

    while (true) {
        global.reset(io);

        try writer.interface.writeAll("status\n");
        try writer.interface.flush();
        {
            global.playinfo_lock(io) catch return;
            defer global.playinfo_unlock(io);

            while (try reader.interface.takeDelimiter('\n')) |line| {
                if (std.mem.startsWith(u8, line, "ACK ")) @panic(line);
                if (std.mem.startsWith(u8, line, "OK")) break;
                global.updatePlayInfo(line);
            }
        }

        try writer.interface.writeAll("currentsong\n");
        try writer.interface.flush();
        {
            global.songinfo_lock(io) catch return;
            defer global.songinfo_unlock(io);

            while (try reader.interface.takeDelimiter('\n')) |line| {
                if (std.mem.startsWith(u8, line, "ACK ")) @panic(line);
                if (std.mem.startsWith(u8, line, "OK")) break;
                try global.updateSongInfo(ally, line);
            }
        }
        try stdout.interface.flush();
        queue.putOne(io, true) catch return;

        try writer.interface.writeAll("idle player\n");
        try writer.interface.flush();

        while (try reader.interface.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "OK")) break;
            if (!std.mem.eql(u8, line, "changed: player")) @panic(line);
        }
    }
}

fn rpc(ally: Allocator, io: Io, queue: *Io.Queue(bool)) !void {
    try stop(io, queue);

    var client: discord.Client = try .init(ally, io, discord.CLIENT_ID);
    defer client.deinit(io);
    try client.start(io);

    var stderr_buf: [512]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    var first_line: Formatter = try .init(ally, "[[%discnumber%.]%tracknumber%. ]%title%", &global.songinfo, &stderr.interface);
    defer first_line.deinit(ally);
    var second_line: Formatter = try .init(ally, "[%artist%][ - %album%]", &global.songinfo, &stderr.interface);
    defer second_line.deinit(ally);
    // flush formatter parse errors
    try stderr.interface.flush();

    var firstline_buf: [512]u8 = undefined;
    var secondline_buf: [512]u8 = undefined;

    while (try queue.getOne(io)) {
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

        first_line.evaluate();
        const details = try std.fmt.bufPrint(&firstline_buf, "{f}", .{first_line});
        second_line.evaluate();
        const state = try std.fmt.bufPrint(&secondline_buf, "{f}", .{second_line});

        const activity: discord.Activity = .{
            .details = details,
            .state = state,
            .activity_type = .listening,
            .status_display_type = .state,
            .timestamps = .{ .start = start, .end = end },
        };

        try client.updateActivity(io, activity);
    }
}

test {
    _ = @import("formatter/Formatter.zig");
    _ = @import("formatter/parser.zig");
}
