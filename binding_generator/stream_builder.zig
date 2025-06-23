const std = @import("std");

pub fn StreamBuilder(comptime T: type) type {
    return struct {
        pub const Slice = []const T;
        pub const List = std.ArrayListUnmanaged(T);

        const Self = @This();

        pub const indent_width = 4;

        list: List,
        allocator: std.mem.Allocator,
        last_write_pos: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .list = .empty,
                .last_write_pos = 0,
            };
        }

        fn writer(self: *Self) List.Writer {
            return self.list.writer(self.allocator);
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
        }

        pub fn reset(self: *Self) void {
            self.list.clearAndFree(self.allocator);
            self.list = .empty;
        }

        pub fn getWritten(self: *Self) Slice {
            return self.list.items;
        }

        pub fn getLastWritten(self: *Self) Slice {
            return self.list.items[self.last_write_pos..self.list.items.len];
        }

        pub fn bufPrint(self: *Self, comptime format: []const u8, args: anytype) !Slice {
            self.last_write_pos = self.list.items.len;
            try self.writer().print(format, args);
            return self.getLastWritten();
        }

        pub fn print(self: *Self, indent_level: u8, comptime line: []const u8, args: anytype) !void {
            self.last_write_pos = self.list.items.len;
            for (0..indent_level * indent_width) |_| {
                try self.writer().writeAll(" ");
            }
            try self.writer().print(line, args);
        }

        pub fn printLine(self: *Self, indent_level: u8, comptime line: []const u8, args: anytype) !void {
            try self.print(indent_level, line, args);
            try self.writer().writeAll("\n");
        }

        pub fn write(self: *Self, indent_level: u8, line: []const u8) !void {
            self.last_write_pos = self.list.items.len;
            for (0..indent_level * indent_width) |_| {
                try self.writer().writeAll(" ");
            }
            try self.writer().writeAll(line);
        }

        pub fn writeLine(self: *Self, indent_level: u8, line: []const u8) !void {
            try self.write(indent_level, line);
            try self.writer().writeAll("\n");
        }

        pub fn writeComments(self: *Self, comments: []const u8) !void {
            var lines = std.mem.splitSequence(u8, comments, "\n");
            while (lines.next()) |line| {
                try self.write(0, "/// ");
                try self.writeLine(0, line);
            }
        }
    };
}

pub const DefaultStreamBuilder = StreamBuilder(u8);
