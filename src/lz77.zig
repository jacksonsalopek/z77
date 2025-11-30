//! LZ77 compression and decompression algorithm implementation
const std = @import("std");
const bitio = @import("bitio.zig");

/// Token representing a match in the LZ77 algorithm
pub const Token = struct {
    offset: u16, // Distance back in the buffer
    length: u8, // Length of the match
    next_char: u8, // Next character after the match

    /// Write this token to a bit writer
    pub fn write(self: Token, writer: *bitio.BitWriter) !void {
        try writer.writeU16(self.offset);
        try writer.writeBits(self.length, 8);
        try writer.writeBits(self.next_char, 8);
    }

    /// Read a token from a bit reader
    pub fn read(reader: *bitio.BitReader) !?Token {
        const offset = try reader.readU16() orelse return null;
        const length = try reader.readU8() orelse return error.UnexpectedEOF;
        const next_char = try reader.readU8() orelse return error.UnexpectedEOF;

        return Token{
            .offset = offset,
            .length = length,
            .next_char = next_char,
        };
    }

    pub fn format(
        self: Token,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Token{{offset={}, length={}, next_char={c}}}", .{
            self.offset,
            self.length,
            self.next_char,
        });
    }
};

/// Header for compressed files
pub const Header = struct {
    search_buffer_size: u16,
    lookahead_size: u8,
    original_size: u32,

    /// Write header to bit writer
    pub fn write(self: Header, writer: *bitio.BitWriter) !void {
        try writer.writeU16(self.search_buffer_size);
        try writer.writeBits(self.lookahead_size, 8);
        try writer.writeU32(self.original_size);
    }

    /// Read header from bit reader
    pub fn read(reader: *bitio.BitReader) !Header {
        const search_buffer_size = try reader.readU16() orelse return error.InvalidHeader;
        const lookahead_size = try reader.readU8() orelse return error.InvalidHeader;
        const original_size = try reader.readU32() orelse return error.InvalidHeader;

        return Header{
            .search_buffer_size = search_buffer_size,
            .lookahead_size = lookahead_size,
            .original_size = original_size,
        };
    }
};

/// Match result from searching the sliding window
pub const Match = struct {
    offset: u16,
    length: u8,

    pub fn none() Match {
        return .{ .offset = 0, .length = 0 };
    }
};

/// LZ77 Compressor
pub const Compressor = struct {
    allocator: std.mem.Allocator,
    search_buffer_size: usize,
    lookahead_size: usize,

    pub fn init(allocator: std.mem.Allocator, search_buffer_size: usize, lookahead_size: usize) Compressor {
        return .{
            .allocator = allocator,
            .search_buffer_size = search_buffer_size,
            .lookahead_size = lookahead_size,
        };
    }

    /// Find the longest match in the search buffer
    fn findLongestMatch(
        self: *const Compressor,
        data: []const u8,
        current_pos: usize,
    ) Match {
        const data_len = data.len;
        var best_match = Match.none();

        const search_start = if (current_pos >= self.search_buffer_size)
            current_pos - self.search_buffer_size
        else
            0;

        const lookahead_end = @min(current_pos + self.lookahead_size, data_len);
        const max_match_len = lookahead_end - current_pos;

        if (max_match_len == 0) {
            return best_match;
        }

        var i = search_start;
        while (i < current_pos) : (i += 1) {
            const match_len = self.countMatchingBytes(data, i, current_pos, max_match_len);

            if (match_len > best_match.length and match_len <= std.math.maxInt(u8)) {
                const offset = current_pos - i;
                if (offset <= std.math.maxInt(u16)) {
                    best_match.length = @intCast(match_len);
                    best_match.offset = @intCast(offset);
                }
            }
        }

        return best_match;
    }

    /// Count matching bytes between two positions
    fn countMatchingBytes(
        self: *const Compressor,
        data: []const u8,
        pos1: usize,
        pos2: usize,
        max_len: usize,
    ) usize {
        _ = self;
        var len: usize = 0;
        while (len < max_len and data[pos1 + len] == data[pos2 + len]) : (len += 1) {}
        return len;
    }

    /// Compress data from input file to output file
    pub fn compress(self: *Compressor, input_file: std.fs.File, output_file: std.fs.File) !void {
        // Read entire input file
        const max_size = 100 * 1024 * 1024; // 100MB limit
        const data = try input_file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(data);

        var bit_writer = bitio.BitWriter.init(output_file);

        // Write header
        const header = Header{
            .search_buffer_size = @intCast(self.search_buffer_size),
            .lookahead_size = @intCast(self.lookahead_size),
            .original_size = @intCast(data.len),
        };
        try header.write(&bit_writer);

        // Compress data
        var pos: usize = 0;
        while (pos < data.len) {
            const match = self.findLongestMatch(data, pos);

            const next_char: u8 = if (pos + match.length < data.len)
                data[pos + match.length]
            else
                0;

            const token = Token{
                .offset = match.offset,
                .length = match.length,
                .next_char = next_char,
            };
            try token.write(&bit_writer);

            pos += if (match.length > 0) match.length + 1 else 1;
        }

        try bit_writer.flush();
    }

    /// Decompress data from input file to output file
    pub fn decompress(allocator: std.mem.Allocator, input_file: std.fs.File, output_file: std.fs.File) !void {
        var bit_reader = bitio.BitReader.init(input_file);

        // Read and validate header
        const header = try Header.read(&bit_reader);

        // Sanity check header values
        if (header.search_buffer_size == 0 or header.lookahead_size == 0) {
            std.log.err("Invalid header: search_buffer_size={}, lookahead_size={}. File may not be a valid z77 file.", .{ header.search_buffer_size, header.lookahead_size });
            return error.InvalidHeader;
        }

        if (header.original_size > 100 * 1024 * 1024) { // 100MB sanity check
            std.log.warn("Large original size: {} bytes. This may take a while...", .{header.original_size});
        }

        // Decompress data
        var output_buffer: std.ArrayList(u8) = .empty;
        defer output_buffer.deinit(allocator);

        var tokens_processed: usize = 0;
        while (output_buffer.items.len < header.original_size) {
            const token = try Token.read(&bit_reader) orelse break;
            tokens_processed += 1;

            // Copy from sliding window
            if (token.length > 0) {
                try copyFromSlidingWindow(&output_buffer, allocator, token.offset, token.length, header.original_size);
            }

            // Append next character if we haven't reached the target size
            if (output_buffer.items.len < header.original_size) {
                try output_buffer.append(allocator, token.next_char);
            }
        }

        if (output_buffer.items.len != header.original_size) {
            std.log.err("Decompression incomplete: expected {} bytes, got {}. File may be corrupted.", .{ header.original_size, output_buffer.items.len });
            return error.IncompleteDecode;
        }

        try output_file.writeAll(output_buffer.items);
    }
};

/// Helper function to copy bytes from the sliding window
fn copyFromSlidingWindow(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    offset: u16,
    length: u8,
    max_size: u32,
) !void {
    // Validate that offset is within bounds
    if (offset > buffer.items.len) {
        std.log.err("Invalid offset: {} exceeds buffer size: {}. File may be corrupted or in wrong format.", .{ offset, buffer.items.len });
        return error.InvalidOffset;
    }

    if (offset == 0) {
        std.log.err("Invalid offset: cannot be zero. File may be corrupted.", .{});
        return error.InvalidOffset;
    }

    const start_pos = buffer.items.len - offset;
    var i: usize = 0;
    while (i < length and buffer.items.len < max_size) : (i += 1) {
        const byte = buffer.items[start_pos + i];
        try buffer.append(allocator, byte);
    }
}

test "token write and read" {
    const testing = std.testing;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir = tmp_dir.dir;

    const original_token = Token{
        .offset = 42,
        .length = 5,
        .next_char = 'X',
    };

    // Write token
    {
        const file = try dir.createFile("test.bin", .{});
        defer file.close();

        var writer = bitio.BitWriter.init(file);
        try original_token.write(&writer);
        try writer.flush();
    }

    // Read token
    {
        const file = try dir.openFile("test.bin", .{});
        defer file.close();

        var reader = bitio.BitReader.init(file);
        const token = try Token.read(&reader);

        try testing.expectEqual(original_token.offset, token.?.offset);
        try testing.expectEqual(original_token.length, token.?.length);
        try testing.expectEqual(original_token.next_char, token.?.next_char);
    }
}

test "header write and read" {
    const testing = std.testing;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir = tmp_dir.dir;

    const original_header = Header{
        .search_buffer_size = 4095,
        .lookahead_size = 15,
        .original_size = 12345,
    };

    // Write header
    {
        const file = try dir.createFile("test.bin", .{});
        defer file.close();

        var writer = bitio.BitWriter.init(file);
        try original_header.write(&writer);
        try writer.flush();
    }

    // Read header
    {
        const file = try dir.openFile("test.bin", .{});
        defer file.close();

        var reader = bitio.BitReader.init(file);
        const header = try Header.read(&reader);

        try testing.expectEqual(original_header.search_buffer_size, header.search_buffer_size);
        try testing.expectEqual(original_header.lookahead_size, header.lookahead_size);
        try testing.expectEqual(original_header.original_size, header.original_size);
    }
}

test "compress and decompress round trip" {
    const testing = std.testing;
    const test_data = "hello hello world world world! compression test data with repeating patterns.";

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir = tmp_dir.dir;

    // Write test data
    {
        const file = try dir.createFile("input.txt", .{});
        defer file.close();
        try file.writeAll(test_data);
    }

    // Compress
    {
        const input = try dir.openFile("input.txt", .{});
        defer input.close();
        const output = try dir.createFile("compressed.lz77", .{});
        defer output.close();

        var compressor = Compressor.init(testing.allocator, 4095, 15);
        try compressor.compress(input, output);
    }

    // Decompress
    {
        const input = try dir.openFile("compressed.lz77", .{});
        defer input.close();
        const output = try dir.createFile("output.txt", .{});
        defer output.close();

        try Compressor.decompress(testing.allocator, input, output);
    }

    // Verify
    {
        const file = try dir.openFile("output.txt", .{});
        defer file.close();
        const content = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(content);

        try testing.expectEqualStrings(test_data, content);
    }
}
