//! The rpc client
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

const Activity = @import("Activity.zig");
const Socket = if (builtin.os.tag == .windows) Io.File else Io.net.Stream;

const Client = @This();

/// io stream to rpc server
conn: Socket,
/// client_id
client_id: u64,
/// Process id
pid: std.posix.pid_t,
/// msg Queue
msg_queue: Io.Queue(MsgQueueItem),

/// Message Sending Loop future
sender_work: ?Io.Future(Writer.Error!void),

/// Initialize Client members and connection
pub fn init(ally: Allocator, io: Io, client_id: u64) Allocator.Error!Client {
    return .{
        .conn = try connect_rpc(ally, io),
        .client_id = client_id,
        .pid = std.posix.getpid(),
        .msg_queue = .init(&.{}),
        .sender_work = undefined,
    };
}

pub const StartError = error{HandshakeFailed};
pub fn start(self: *Client, io: Io) StartError!void {
    self.handshake(io) catch return StartError.HandshakeFailed;

    self.sender_work = io.concurrent(sender, .{ io, self.conn, &self.msg_queue }) catch
        @panic("Unable to run concurrent work");
}

pub fn deinit(self: *Client, io: Io) void {
    if (self.sender_work != null) self.sender_work.?.cancel(io) catch {};
    self.conn.close(io);
}

/// Queue an activity update
pub fn updateActivity(self: *Client, io: Io, activity: Activity) error{NoSpaceLeft}!void {
    var msg: [1024]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 1, .little);
    const slice = try std.fmt.bufPrint(msg[8..],
        \\{{"cmd":"SET_ACTIVITY","nonce":"{b:032}","args":{{"pid":{d},"activity":{f}}}}}
    , .{ nonce(io), self.pid, activity });
    std.mem.writeInt(u32, msg[4..8], @intCast(slice.len), .little);
    self.msg_queue.putOne(io, .{ .msg = msg, .len = @intCast(slice.len + 8) }) catch {};
}

/// Queue an activity clear
pub fn clearActivity(self: *Client, io: Io) void {
    var msg: [1024]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 1, .little);
    const slice = std.fmt.bufPrint(msg[8..],
        \\{{"cmd":"SET_ACTIVITY","nonce":"{b:032}","args":{{"pid":{d}}}}}
    , .{ nonce(io), self.pid}) catch unreachable;
    std.mem.writeInt(u32, msg[4..8], @intCast(slice.len), .little);
    self.msg_queue.putOne(io, .{ .msg = msg, .len = @intCast(slice.len + 8) }) catch {};
}

/// Find the file descriptor and connect
fn connect_rpc(ally: Allocator, io: Io) Allocator.Error!Socket {
    if (builtin.os.tag == .windows) Socket.openAbsolute(
        \\\\.\pipe\
    ); // TODO

    // Unix
    var env = std.process.getEnvMap(ally) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("Unexpected error"),
    };
    defer env.deinit();

    const tmp = env.get("XDG_RUNTIME_DIR") orelse
        env.get("TMPDIR") orelse
        env.get("TMP") orelse
        env.get("TEMP") orelse
        "/tmp";

    var path_buffer: [108]u8 = undefined;
    for (0..10) |i| {
        const ua = Io.net.UnixAddress.init(
            std.fmt.bufPrint(&path_buffer, "{s}/discord-ipc-{d}", .{ tmp, i }) catch
                @panic("runtime path too long"),
        ) catch unreachable;
        return ua.connect(io) catch continue;
    }
    @panic("no valid discord ipc pipe found");
}

/// Handshake with discord ipc (right after connection)
fn handshake(self: Client, io: Io) Writer.Error!void {
    var buf: [128]u8 = undefined;
    var conn_writer = self.conn.writer(io, &buf);
    const w = &conn_writer.interface;

    try w.writeInt(u32, 0, .little);
    try w.writeInt(
        u32,
        @intCast(
            \\{"v":1,"client_id":""}

            .len + (if (self.client_id == 0) 1 else (std.math.log10(self.client_id) + 1))),
        .little,
    );
    try w.print(
        \\{{"v":1,"client_id":"{d}"}}
    , .{self.client_id});
    try w.flush();
}

/// Separate loop sending activity updates
fn sender(io: Io, conn: Socket, queue: *Io.Queue(MsgQueueItem)) Writer.Error!void {
    var w_buf: [1024]u8 = undefined;
    var conn_writer = conn.writer(io, &w_buf);
    const w = &conn_writer.interface;

    while (true) {
        const data = queue.getOne(io) catch return;
        try w.writeAll(data.msg[0..data.len]);
        try w.flush();
    }
}

fn nonce(io: Io) u32 {
    const Static = struct {
        var nonce: u32 = 0;
        var mutex: Io.Mutex = .init;
    };

    Static.mutex.lock(io) catch {};
    defer Static.mutex.unlock(io);

    const result = Static.nonce;
    Static.nonce += 1;
    return result;
}

const MsgQueueItem = struct { msg: [1024]u8, len: u16 };
