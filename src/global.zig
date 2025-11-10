const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SongInfo = @import("song_state/SongInfo.zig");
const PlayInfo = @import("song_state/PlayInfo.zig");


pub var playinfo: PlayInfo = undefined;
var playinfo_mutex: std.Io.Mutex = .init;


pub var songinfo: SongInfo = .{ .filepath = undefined };
var songinfo_mutex: std.Io.Mutex = .init;
var str_buf: std.ArrayList(u8) = .empty;

/// Reinitialize
pub fn deinit(ally: Allocator, io: Io) void {
    songinfo_mutex.lock(io) catch {};
    defer songinfo_mutex.unlock(io);

    songinfo = .{ .filepath = undefined };
    str_buf.deinit(ally);
}

/// Reset all values
pub fn reset(io: Io) void {
    songinfo_mutex.lock(io) catch {};
    defer songinfo_mutex.unlock(io);
    playinfo_mutex.lock(io) catch {};
    defer playinfo_mutex.unlock(io);


    str_buf.clearRetainingCapacity();
    songinfo = .{ .filepath = undefined };
    playinfo = undefined;
}

pub fn playinfo_lock(io: Io) !void {
    try playinfo_mutex.lock(io);
}
pub fn playinfo_unlock(io: Io) void {
    playinfo_mutex.unlock(io);
}

/// Take mpd output line and update PlayInfo data
pub fn updatePlayInfo(line: []const u8) void {
    const colon = std.mem.findScalarPos(u8, line, 0, ':') orelse
        @panic("unexpected colon not found finding PlayInfo key\n");

    playinfo.assign(line[0..colon], line[colon + 2..]);
}

pub fn songinfo_lock(io: Io) !void {
    try songinfo_mutex.lock(io);
}
pub fn songinfo_unlock(io: Io) void {
    songinfo_mutex.unlock(io);
}

pub fn updateSongInfo(ally: Allocator, line: []const u8) !void {
    const colon = std.mem.findScalarPos(u8, line, 0, ':') orelse
        @panic("unexpected colon not found finding SongInfo key\n");

    try songinfo.assign(ally, &str_buf, line[0..colon], line[colon + 2..]);
}
