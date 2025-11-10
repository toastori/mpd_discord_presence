const std = @import("std");

state: State,
/// In millis
elapsed: u32,
/// In millis
duration: u32,

pub fn assign(self: *@This(), key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "state")) {
        self.state = State.get(value) orelse {
            std.debug.print("state: {s}\n", .{value});
            @panic("unexpected state in status.state");
        };
    } else if (std.mem.eql(u8, key, "elapsed")) {
        const colon = std.mem.findScalarPos(u8, value, 0, '.') orelse
            @panic("unexpected colon not found in status.elapsed");

        const sec = std.fmt.parseInt(u32, value[0..colon], 10) catch
            @panic("unexpected unparsable number in status.elapsed");
        const millis = std.fmt.parseInt(u32, value[colon + 1 ..], 10) catch
            @panic("unexpected unparsable number in status.elapsed");

        self.elapsed = (sec * std.time.ms_per_s) + millis;
    } else if (std.mem.eql(u8, key, "duration")) {
        const colon = std.mem.findScalarPos(u8, value, 0, '.') orelse
            @panic("unexpected colon not found in status.duration");

        const sec = std.fmt.parseInt(u32, value[0..colon], 10) catch
            @panic("unexpected unparsable number in status.duration");
        const millis = std.fmt.parseInt(u32, value[colon + 1 ..], 10) catch
            @panic("unexpected unparsable number in status.duration");

        self.duration = (sec * std.time.ms_per_s) + millis;
    }
}

pub const State = enum {
    play,
    stop,
    pause,

    const str_map: std.StaticStringMap(State) = .initComptime(.{
        .{ "play", .play },
        .{ "stop", .stop },
        .{ "pause", .pause },
    });

    pub fn get(str: []const u8) ?State {
        return str_map.get(str);
    }
};
