//! Nintendo LZ77 compression format (LZ10/LZ11)
//! Commonly used in Nintendo DS and 3DS games
//!
//! Format:
//! - Header: 4 bytes
//!   - Byte 0: Compression type (0x10 = LZ10, 0x11 = LZ11)
//!   - Bytes 1-3: Decompressed size (24-bit little-endian)
//! - Data: Flag-based compression blocks
//!   - Each flag byte controls 8 blocks
//!   - 0 bit = uncompressed byte (literal)
//!   - 1 bit = compressed (length/offset pair)

const std = @import("std");

/// Compression type identifier
pub const CompressionType = enum(u8) {
    lz10 = 0x10,
    lz11 = 0x11,
    _,
};

/// Header for Nintendo LZ77 files
pub const Header = struct {
    compression_type: CompressionType,
    decompressed_size: u32,

    pub fn read(file: std.fs.File) !Header {
        var header_bytes: [4]u8 = undefined;
        const bytes_read = try file.read(&header_bytes);
        if (bytes_read != 4) return error.InvalidHeader;

        const compression_type: CompressionType = @enumFromInt(header_bytes[0]);

        // Size is stored in little-endian 24-bit format
        const decompressed_size: u32 = @as(u32, header_bytes[1]) |
            (@as(u32, header_bytes[2]) << 8) |
            (@as(u32, header_bytes[3]) << 16);

        return Header{
            .compression_type = compression_type,
            .decompressed_size = decompressed_size,
        };
    }

    pub fn write(self: Header, file: std.fs.File) !void {
        var header_bytes: [4]u8 = undefined;
        header_bytes[0] = @intFromEnum(self.compression_type);
        header_bytes[1] = @intCast(self.decompressed_size & 0xFF);
        header_bytes[2] = @intCast((self.decompressed_size >> 8) & 0xFF);
        header_bytes[3] = @intCast((self.decompressed_size >> 16) & 0xFF);
        try file.writeAll(&header_bytes);
    }

    pub fn isValid(self: Header) bool {
        return switch (self.compression_type) {
            .lz10, .lz11 => self.decompressed_size > 0 and self.decompressed_size < 100 * 1024 * 1024,
            else => false,
        };
    }
};

/// Check if a file is a Nintendo LZ77 file
pub fn isNintendoLZ77(file: std.fs.File) !bool {
    const original_pos = try file.getPos();
    defer file.seekTo(original_pos) catch {};

    try file.seekTo(0);

    var header_bytes: [4]u8 = undefined;
    const bytes_read = try file.read(&header_bytes);
    if (bytes_read != 4) return false;

    const compression_type: CompressionType = @enumFromInt(header_bytes[0]);
    return compression_type == .lz10 or compression_type == .lz11;
}

/// Decode a compressed block based on compression type
fn decodeCompressedBlock(
    file: std.fs.File,
    compression_type: CompressionType,
) !struct { length: usize, offset: usize } {
    var first_byte: [1]u8 = undefined;
    if (try file.read(&first_byte) == 0) return error.UnexpectedEOF;

    var length: usize = 0;
    var offset: usize = 0;

    switch (compression_type) {
        .lz10 => {
            // LZ10: Simple 2-byte format
            var second_byte: [1]u8 = undefined;
            if (try file.read(&second_byte) == 0) return error.UnexpectedEOF;

            length = (@as(usize, first_byte[0]) >> 4) + 3;
            offset = ((@as(usize, first_byte[0]) & 0x0F) << 8) | @as(usize, second_byte[0]);
        },
        .lz11 => {
            // LZ11: Extended format with multiple modes
            const indicator = first_byte[0] >> 4;

            if (indicator == 0) {
                // Extended length (3 bytes total)
                var extra: [2]u8 = undefined;
                if (try file.read(&extra) != 2) return error.UnexpectedEOF;

                length = ((@as(usize, first_byte[0]) & 0x0F) << 4) | (@as(usize, extra[0]) >> 4);
                length += 0x11; // Minimum length for this mode
                offset = ((@as(usize, extra[0]) & 0x0F) << 8) | @as(usize, extra[1]);
            } else if (indicator == 1) {
                // Very extended length (4 bytes total)
                var extra: [3]u8 = undefined;
                if (try file.read(&extra) != 3) return error.UnexpectedEOF;

                length = ((@as(usize, first_byte[0]) & 0x0F) << 12) |
                    (@as(usize, extra[0]) << 4) |
                    (@as(usize, extra[1]) >> 4);
                length += 0x111; // Minimum length for this mode
                offset = ((@as(usize, extra[1]) & 0x0F) << 8) | @as(usize, extra[2]);
            } else {
                // Normal length (2 bytes total, like LZ10)
                var second_byte: [1]u8 = undefined;
                if (try file.read(&second_byte) == 0) return error.UnexpectedEOF;

                length = (@as(usize, first_byte[0]) >> 4) + 1;
                offset = ((@as(usize, first_byte[0]) & 0x0F) << 8) | @as(usize, second_byte[0]);
            }
        },
        else => return error.UnsupportedFormat,
    }

    return .{ .length = length, .offset = offset };
}

/// Unified decompression for Nintendo LZ10/LZ11 formats
fn decompressNintendo(
    file: std.fs.File,
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    target_size: u32,
    compression_type: CompressionType,
) !void {
    while (output.items.len < target_size) {
        // Read flag byte (controls next 8 blocks)
        var flag_byte: [1]u8 = undefined;
        const bytes_read = try file.read(&flag_byte);
        if (bytes_read == 0) break;

        var flag = flag_byte[0];
        var i: usize = 0;

        while (i < 8 and output.items.len < target_size) : (i += 1) {
            if ((flag & 0x80) == 0) {
                // Uncompressed byte (literal)
                var byte: [1]u8 = undefined;
                if (try file.read(&byte) == 0) return;
                try output.append(allocator, byte[0]);
            } else {
                // Compressed block - decode based on compression type
                const block = try decodeCompressedBlock(file, compression_type);

                if (block.offset >= output.items.len) {
                    std.log.err("Invalid offset {} in {s} data (buffer size: {})", .{
                        block.offset,
                        @tagName(compression_type),
                        output.items.len,
                    });
                    return error.InvalidOffset;
                }

                // Copy from sliding window
                const start_pos = output.items.len - block.offset - 1;
                var j: usize = 0;
                while (j < block.length and output.items.len < target_size) : (j += 1) {
                    const byte = output.items[start_pos + j];
                    try output.append(allocator, byte);
                }
            }

            flag <<= 1;
        }
    }
}

/// Decompress a Nintendo LZ77 file
pub fn decompress(allocator: std.mem.Allocator, input_file: std.fs.File, output_file: std.fs.File) !void {
    try input_file.seekTo(0);

    const header = try Header.read(input_file);

    if (!header.isValid()) {
        std.log.err("Invalid Nintendo LZ77 header: type=0x{X:0>2}, size={}", .{
            @intFromEnum(header.compression_type),
            header.decompressed_size,
        });
        return error.InvalidHeader;
    }

    std.log.info("Nintendo LZ77 format detected: {s}, decompressed size: {} bytes", .{
        @tagName(header.compression_type),
        header.decompressed_size,
    });

    var output_buffer: std.ArrayList(u8) = .empty;
    defer output_buffer.deinit(allocator);

    try output_buffer.ensureTotalCapacity(allocator, header.decompressed_size);

    // Use unified decompression function with compression type
    try decompressNintendo(
        input_file,
        &output_buffer,
        allocator,
        header.decompressed_size,
        header.compression_type,
    );

    if (output_buffer.items.len != header.decompressed_size) {
        std.log.warn("Decompression size mismatch: expected {}, got {}", .{
            header.decompressed_size,
            output_buffer.items.len,
        });
    }

    try output_file.writeAll(output_buffer.items);
}

/// Compress data using Nintendo LZ10 format
pub fn compressLZ10(allocator: std.mem.Allocator, input_file: std.fs.File, output_file: std.fs.File) !void {
    const max_size = 100 * 1024 * 1024;
    const data = try input_file.readToEndAlloc(allocator, max_size);
    defer allocator.free(data);

    // Write header
    const header = Header{
        .compression_type = .lz10,
        .decompressed_size = @intCast(data.len),
    };
    try header.write(output_file);

    // Simple compression implementation
    var pos: usize = 0;
    while (pos < data.len) {
        var flag_byte: u8 = 0;
        var flag_bit: u3 = 0;
        var block_buffer = std.ArrayList(u8).init(allocator);
        defer block_buffer.deinit();

        while (flag_bit < 8 and pos < data.len) : (flag_bit += 1) {
            // Find best match in previous 4096 bytes
            const search_start = if (pos >= 4096) pos - 4096 else 0;
            var best_length: usize = 0;
            var best_offset: usize = 0;

            var i = search_start;
            while (i < pos) : (i += 1) {
                var len: usize = 0;
                while (len < 18 and pos + len < data.len and data[i + len] == data[pos + len]) {
                    len += 1;
                }
                if (len >= 3 and len > best_length) {
                    best_length = len;
                    best_offset = pos - i - 1;
                }
            }

            if (best_length >= 3) {
                // Compressed
                flag_byte |= (@as(u8, 1) << @intCast(7 - flag_bit));
                const length_code: u8 = @intCast(best_length - 3);
                const offset_code: u16 = @intCast(best_offset);
                try block_buffer.append((length_code << 4) | @as(u8, @intCast(offset_code >> 8)));
                try block_buffer.append(@intCast(offset_code & 0xFF));
                pos += best_length;
            } else {
                // Uncompressed
                try block_buffer.append(data[pos]);
                pos += 1;
            }
        }

        try output_file.writeAll(&[_]u8{flag_byte});
        try output_file.writeAll(block_buffer.items);
    }
}

test "Nintendo LZ77 header format" {
    const testing = std.testing;

    const header = Header{
        .compression_type = .lz11,
        .decompressed_size = 0x123456,
    };

    try testing.expect(header.isValid());
    try testing.expectEqual(@as(u8, 0x11), @intFromEnum(header.compression_type));
}
