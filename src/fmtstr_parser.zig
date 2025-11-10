const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const fmtstr = @import("fmtstr.zig");
const Node = fmtstr.Node;
const Metadata = @import("SongInfo.zig").Metadata;

pub const Tag = enum {
    l_bracket,
    r_bracket,
    identifier,
    quoted,

    percent,
    single_quote,
    str,

    invalid,
    invalid_identifier,

    unclosed_identifier,
    unclosed_quote,
    end,
};

pub const Token = struct {
    tag: Tag,
    loc: struct { start: u16, end: u16 },
};

pub const Tokenizer = struct {
    buf: [:0]const u8,
    idx: u16, // limit buf.len to 65535

    pub const State = enum {
        start,
        percent,
        single_quote,
        str,

        identifier,
        quoted,

        invalid,
        invalid_identifier,
    };

    pub fn init(buf: [:0]const u8) error{BufTooLong}!Tokenizer {
        if (buf.len > std.math.maxInt(u16)) return error.BufTooLong;
        return .{ .buf = buf, .idx = 0 };
    }

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{ .start = self.idx, .end = undefined },
        };

        state: switch (State.start) {
            .start => switch (self.buf[self.idx]) {
                0 => if (self.buf.len == self.idx) {
                    result.tag = .end;
                } else continue :state .invalid,
                '[' => {
                    result.tag = .l_bracket;
                    self.idx += 1;
                },
                ']' => {
                    result.tag = .r_bracket;
                    self.idx += 1;
                },
                '%' => continue :state .percent,
                '\'' => continue :state .single_quote,
                '\n', '\r' => {
                    self.idx += 1;
                    continue :state .start;
                },
                else => continue :state .str,
            },
            .invalid => {
                self.idx += 1;
                switch (self.buf[self.idx]) {
                    0 => if (self.buf.len == self.idx) {
                        result.tag = .invalid;
                    } else continue :state .invalid,
                    '\n' => {
                        result.tag = .invalid;
                        self.idx += 1;
                    },
                    else => continue :state .invalid,
                }
            },
            .invalid_identifier => {
                self.idx += 1;
                switch (self.buf[self.idx]) {
                    '\t', '\n', '\r', '0' => continue :state .invalid,
                    '%' => {
                        result.tag = .invalid_identifier;
                        self.idx += 1;
                    },
                    else => continue :state .invalid_identifier,
                }
            },
            .percent => {
                self.idx += 1;
                switch (self.buf[self.idx]) {
                    '%' => {
                        result.tag = .percent;
                        self.idx += 1;
                    },
                    'a'...'z', 'A'...'Z', ' ', '_' => continue :state .identifier,
                    0 => result.tag = .unclosed_identifier,
                    '\n', '\r' => result.tag = .unclosed_identifier,
                    else => continue :state .invalid_identifier,
                }
            },
            .single_quote => {
                self.idx += 1;
                switch (self.buf[self.idx]) {
                    '\'' => {
                        result.tag = .single_quote;
                        self.idx += 1;
                    },
                    0 => result.tag = .unclosed_quote,
                    else => continue :state .quoted,
                }
            },
            .str => {
                self.idx += 1;
                switch (self.buf[self.idx]) {
                    0, '[', ']', '%', '\'', '\n', '\r' => result.tag = .str,
                    else => continue :state .str,
                }
            },
            .identifier => {
                self.idx += 1;
                switch (self.buf[self.idx]) {
                    '%' => {
                        result.tag = .identifier;
                        self.idx += 1;
                    },
                    'a'...'z', 'A'...'Z', ' ', '_' => continue :state .identifier,
                    0 => result.tag = .unclosed_identifier,
                    '\n', '\r' => {
                        result.tag = .unclosed_identifier;
                        self.idx += 1;
                    },
                    else => continue :state .invalid_identifier,
                }
            },
            .quoted => {
                self.idx += 1;
                switch (self.buf[self.idx]) {
                    '\'' => {
                        result.tag = .quoted;
                        self.idx += 1;
                    },
                    0 => result.tag = .unclosed_quote,
                    else => continue :state .quoted,
                }
            },
        }
        result.loc.end = self.idx;
        return result;
    }
};

pub const ParseTokensError = error{ParseError} || Allocator.Error;
pub const ParseTokenResult = struct { fmt: []const Node, str: []const u8 };
pub fn parseTokens(ally: Allocator, tok: *Tokenizer, err_w: *Writer) ParseTokensError!ParseTokenResult {
    var fmt: std.ArrayList(Node) = .empty;
    errdefer fmt.deinit(ally);
    var str: std.ArrayList(u8) = .empty;
    errdefer str.deinit(ally);

    { // Process len of result for allocation
        var bracket_depth: u16 = 0;
        var error_count: u16 = 0;
        var token: Token = tok.next();

        const State = enum { start, str, err };
        state: switch (State.start) {
            .start => switch (token.tag) {
                .end => try fmt.append(ally, .end_of_fmt),
                .l_bracket => {
                    try fmt.append(ally, .null);
                    bracket_depth += 1;
                    token = tok.next();
                    continue :state .start;
                },
                .r_bracket => {
                    if (bracket_depth == 0) {
                        err_w.print("error: extra close bracket ']' at char {d}\n", .{token.loc.start}) catch {};
                        continue :state .err;
                    }
                    if (fmt.getLast() == .null) {
                        _ = fmt.pop();
                    } else { // Assign optional
                        var len: u16 = 1;
                        var only_str: bool = true;
                        while (true) : (len += 1) {
                            const idx = fmt.items.len - len;
                            if (fmt.items[idx] == .null) {
                                if (only_str) {
                                    str.shrinkRetainingCapacity(fmt.items[fmt.items.len - (len - 1)].str.start);
                                    fmt.shrinkRetainingCapacity(fmt.items.len - len);
                                } else fmt.items[idx] = .{ .optional = .{ .len = len } };
                                break;
                            }
                            if (fmt.items[idx] != .str) only_str = false;
                        }
                    }
                    bracket_depth -= 1;
                    token = tok.next();
                    continue :state .start;
                },
                .identifier => {
                    const identifier = tok.buf[token.loc.start..token.loc.end];
                    try fmt.append(ally, .{ .tag = Metadata.get(identifier) orelse {
                        err_w.print("error: unknown identifier {s} at char {d}\n", .{ identifier, token.loc.start }) catch {};
                        continue :state .err;
                    } });
                    token = tok.next();
                    continue :state .start;
                },
                .percent, .single_quote, .quoted, .str => {
                    if (error_count != 0) {
                        token = tok.next();
                        continue :state .start;
                    }
                    try fmt.append(ally, .{ .str = .{ .start = @intCast(str.items.len) } });
                    continue :state .str;
                },
                .invalid => {
                    err_w.print("error: invalid character(s) between char {d} and {d}\n", .{ token.loc.start, token.loc.end }) catch {};
                    continue :state .err;
                },
                .invalid_identifier => {
                    const identifier = tok.buf[token.loc.start..token.loc.end];
                    err_w.print("error: invalid character in identifier {s} at char {d}\n", .{ identifier, token.loc.start }) catch {};
                    continue :state .err;
                },
                .unclosed_identifier => {
                    const identifier = tok.buf[token.loc.start..token.loc.end];
                    err_w.print("error: unclosed identifier {s} start at char {d}\n", .{ identifier, token.loc.start }) catch {};
                    continue :state .err;
                },
                .unclosed_quote => {
                    err_w.print("error: unclosed quote start at char {d}\n", .{token.loc.start}) catch {};
                    continue :state .err;
                },
            },
            .err => {
                error_count += 1;
                token = tok.next();
                continue :state .start;
            },
            .str => {
                const string: []const u8 = switch (token.tag) {
                    .percent => "%",
                    .single_quote => "'",
                    .quoted => tok.buf[token.loc.start + 1 .. token.loc.end - 1],
                    .str => tok.buf[token.loc.start..token.loc.end],
                    else => {
                        try str.append(ally, 0);
                        continue :state .start;
                    },
                };
                try str.ensureUnusedCapacity(ally, string.len);
                for (string) |c| {
                    switch (c) {
                        '\r', '\n' => {},
                        else => str.appendAssumeCapacity(c),
                    }
                }
                token = tok.next();
                continue :state .str;
            },
        }
        if (bracket_depth != 0) {
            err_w.print("error: bracket(s) unclosed\n", .{}) catch {};
            error_count += 1;
        }
        if (error_count != 0) { // report error summary
            err_w.print("\nsummary: {d} error(s) found\n", .{error_count}) catch {};
            return ParseTokensError.ParseError;
        }

        fmt.shrinkAndFree(ally, fmt.items.len);
        str.shrinkAndFree(ally, str.items.len);
        return .{
            .fmt = fmt.items,
            .str = str.items,
        };
    }
}

test "parse error handling" {
    const testing = std.testing;

    const allocator = testing.allocator;

    var al: std.ArrayList(u8) = .empty;
    defer al.deinit(allocator);

    const input: []const [:0]const u8 = &.{
        "a[][[]] b []]", // extra close
        "a [a[aa]b]b[a[a[b]a", // unclosed bracket
        "%album%, %al bum%", // unknown identifier
        "%123^%$%", // invalid identifier then invalid character (unclosed %)
        "'[]'b'c''", // unclosed quote
        "abc" ++ .{0} ++ "def", // non ending sentinel
        "[]][%%\n''g", // extra close then unclosed
    };
    const expected: []const []const u8 = &.{
        \\error: extra close bracket ']' at char 12
        \\
        \\summary: 1 error(s) found
        \\
        ,
        \\error: bracket(s) unclosed
        \\
        \\summary: 1 error(s) found
        \\
        ,
        \\error: unknown identifier %al bum% at char 9
        \\
        \\summary: 1 error(s) found
        \\
        ,
        \\error: invalid character in identifier %123^% at char 0
        \\error: unclosed identifier % start at char 7
        \\
        \\summary: 2 error(s) found
        \\
        ,
        \\error: unclosed quote start at char 8
        \\
        \\summary: 1 error(s) found
        \\
        ,
        \\error: invalid character(s) between char 3 and 7
        \\
        \\summary: 1 error(s) found
        \\
        ,
        \\error: extra close bracket ']' at char 2
        \\error: bracket(s) unclosed
        \\
        \\summary: 2 error(s) found
        \\
        ,
    };

    for (input, expected) |in, expect| {
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &al);
        var tok: Tokenizer = try .init(in);
        try testing.expectEqual(ParseTokensError.ParseError, parseTokens(allocator, &tok, &aw.writer));
        al = aw.toArrayList();
        try testing.expectEqualStrings(expect, al.items);
        al.clearRetainingCapacity();
    }
}
