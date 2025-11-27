const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;

const global = @import("../global.zig");

const mbz_rg = "https://musicbrainz.org/ws/2/release-group/?";
const caa_rg = "https://coverartarchive.org/release-group/";

var client: ?std.http.Client = null;
var uri_buf: [1024]u8 = undefined;
var buffer: [1024]u8 = undefined;

pub fn deinit() void {
    if (client != null) client.?.deinit();
}

pub fn search(ally: Allocator, io: Io, signal_queue: *Io.Queue(bool)) void {
    // Init http client if haven't
    if (client == null) client = .{ .allocator = ally, .io = io };
    std.debug.assert(client != null);

    // Simply avoid musicbrainz rate limit
    io.sleep(.fromSeconds(1), .boot) catch return;

    var writer: FillingWriter = .init(&buffer);

    const uri_raw = blk: {
        global.songinfo_lock(io) catch return;
        defer global.songinfo_unlock(io);

        if (global.songinfo.album == null) return;

        break :blk bufPrint(
            &uri_buf,
            mbz_rg ++ "query={f}+ARTIST%3A\"{f}\"&limit=1&fmt=json",
            .{
                PercentEncoder{ .str = global.songinfo.album },
                PercentEncoder{ .str = global.songinfo.album_artist_fallback() },
            }
        ) catch return;
    };

    const id_fetch = client.?.fetch(.{
        .method = .GET,
        .response_writer = &writer.interface,
        .location = .{ .uri = std.Uri.parse(uri_raw) catch return },
    }) catch return;
    if (id_fetch.status.class() != .success) return;

    const res = writer.written();
    if (std.mem.findPosLinear(u8, res, 0, "\"id\":")) |idx| {
        // hardcoded release-id position after "id":
        // "id":" is len 6, while uuid is 32 + 4 (32 digits + 4 dashes '-')
        global.addMusicBrainzReleaseGroup(ally, io, res[idx + 6..idx + 6 + 32 + 4]) catch return;
        signal_queue.putOne(io, true) catch return;
    }
}

const PercentEncoder = struct {
    str: ?[]const u8,

    pub fn format(self: @This(), w: *Io.Writer) Io.Writer.Error!void {
        if (self.str == null) return;
        for (self.str.?) |c| {
            switch (c) {
                'a'...'z',
                'A'...'Z',
                '0'...'9',
                '-',
                '_',
                '.',
                '~',
                => |char| try w.writeByte(char),
                ' ' => try w.writeByte('+'),
                else => try w.print("%{x:0>2}", .{c}),
            }
        }
    }
};

const MbzResult = struct {
    @"release-groups": []const struct {
        id: []const u8,
    },

    pub fn deinit(self: @This(), ally: Allocator) void {
        for (self.@"release-group") |rg| {
            ally.free(rg.id);
        }
        ally.free(self.@"release-group");
    }
};

const FillingWriter = struct {
    buffer: []u8,
    end: usize = 0,
    interface: Io.Writer = .{
        .buffer = &.{},
        .vtable = &.{
            .drain = drain,
        },
    },

    pub fn init(buf: []u8) FillingWriter {
        return .{ .buffer = buf };
    }

    pub fn written(self: FillingWriter) []const u8 {
        return self.buffer[0..self.end];
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const filling: *FillingWriter = @alignCast(@fieldParentPtr("interface", w));

        if (filling.end != filling.buffer.len) {
            // w.buffer.len is always 0, so dont care
            // data
            for (data[0 .. data.len - 1]) |line| {
                if (filling.buffer.len >= filling.end + line.len) {
                    @memcpy(filling.buffer[filling.end..][0..line.len], line);
                    filling.end += line.len;
                } else {
                    @memcpy(filling.buffer[filling.end..], line[0 .. filling.buffer.len - filling.end]);
                    filling.end = filling.buffer.len;
                }
            }
                // splat
            const line = data[data.len - 1];
                for (0..splat) |_| {
                    if (filling.buffer.len >= filling.end + line.len) {
                        @memcpy(filling.buffer[filling.end..][0..line.len], line);
                        filling.end += line.len;
                    } else {
                        @memcpy(filling.buffer[filling.end..], line[0 .. filling.buffer.len - filling.end]);
                        filling.end = filling.buffer.len;
                    }
            }
        }

        var size: usize = 0;
        for (data[0..data.len - 1]) |line| {
            size += line.len;
        }
        size += data[data.len - 1].len * splat;
        return size;
    }
};