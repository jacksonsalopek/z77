//! Bit-level I/O operations for reading and writing sub-byte values
const std = @import("std");

/// BitWriter for writing individual bits to a file
pub const BitWriter = struct {
    file: std.fs.File,
    buffer: u8,
    bits_in_buffer: u4,

    pub fn init(file: std.fs.File) BitWriter {
        return .{
            .file = file,
            .buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    /// Write up to 32 bits to the file
    pub fn writeBits(self: *BitWriter, value: u32, num_bits: u6) !void {
        var val = value;
        var bits = num_bits;

        while (bits > 0) {
            const bits_available: u5 = @as(u5, 8) - self.bits_in_buffer;
            const bits_to_write: u5 = @min(bits, bits_available);
            const shift: u5 = @intCast(bits - bits_to_write);

            const mask: u32 = (@as(u32, 1) << bits_to_write) - 1;
            const bits_value: u8 = @intCast((val >> shift) & mask);

            if (self.bits_in_buffer == 0 and bits_to_write == 8) {
                // Special case: writing a full byte to an empty buffer
                self.buffer = bits_value;
            } else {
                self.buffer = (self.buffer << @intCast(bits_to_write)) | bits_value;
            }
            self.bits_in_buffer += @intCast(bits_to_write);

            if (self.bits_in_buffer == 8) {
                try self.flushByte();
            }

            bits -= bits_to_write;
            val &= (@as(u32, 1) << shift) - 1;
        }
    }

    /// Write a single byte directly
    pub fn writeByte(self: *BitWriter, byte: u8) !void {
        try self.writeBits(byte, 8);
    }

    /// Write a 16-bit value
    pub fn writeU16(self: *BitWriter, value: u16) !void {
        try self.writeBits(value, 16);
    }

    /// Write a 32-bit value
    pub fn writeU32(self: *BitWriter, value: u32) !void {
        try self.writeBits(value, 32);
    }

    /// Flush any remaining bits in the buffer (pads with zeros)
    pub fn flush(self: *BitWriter) !void {
        if (self.bits_in_buffer > 0) {
            const padding: u5 = @as(u5, 8) - self.bits_in_buffer;
            self.buffer <<= @intCast(padding);
            try self.flushByte();
        }
    }

    /// Internal helper to write the current buffer byte to file
    fn flushByte(self: *BitWriter) !void {
        try self.file.writeAll(&[_]u8{self.buffer});
        self.buffer = 0;
        self.bits_in_buffer = 0;
    }
};

/// BitReader for reading individual bits from a file
pub const BitReader = struct {
    file: std.fs.File,
    buffer: u8,
    bits_in_buffer: u4,

    pub fn init(file: std.fs.File) BitReader {
        return .{
            .file = file,
            .buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    /// Read up to 32 bits from the file
    /// Returns null on EOF at the start of the read
    pub fn readBits(self: *BitReader, num_bits: u6) !?u32 {
        var result: u32 = 0;
        var bits_needed = num_bits;

        while (bits_needed > 0) {
            if (self.bits_in_buffer == 0) {
                const byte = try self.readByte() orelse {
                    if (bits_needed == num_bits) {
                        return null; // EOF at start of read
                    }
                    return error.UnexpectedEOF;
                };
                self.buffer = byte;
                self.bits_in_buffer = 8;
            }

            const bits_available = self.bits_in_buffer;
            const bits_to_read: u5 = @min(bits_needed, bits_available);
            const shift: u5 = bits_available - bits_to_read;

            const bits_value = try self.extractBits(bits_to_read, shift);

            result = (result << @intCast(bits_to_read)) | bits_value;
            self.bits_in_buffer -= @intCast(bits_to_read);

            if (self.bits_in_buffer > 0) {
                self.buffer &= (@as(u8, 1) << @intCast(self.bits_in_buffer)) - 1;
            } else {
                self.buffer = 0;
            }

            bits_needed -= bits_to_read;
        }

        return result;
    }

    /// Read a single byte
    pub fn readU8(self: *BitReader) !?u8 {
        const value = try self.readBits(8);
        return if (value) |v| @intCast(v) else null;
    }

    /// Read a 16-bit value
    pub fn readU16(self: *BitReader) !?u16 {
        const value = try self.readBits(16);
        return if (value) |v| @intCast(v) else null;
    }

    /// Read a 32-bit value
    pub fn readU32(self: *BitReader) !?u32 {
        return try self.readBits(32);
    }

    /// Internal helper to read a byte from file
    fn readByte(self: *BitReader) !?u8 {
        var byte: [1]u8 = undefined;
        const bytes_read = try self.file.read(&byte);
        return if (bytes_read == 0) null else byte[0];
    }

    /// Internal helper to extract bits from the buffer
    fn extractBits(self: *const BitReader, bits_to_read: u5, shift: u5) !u8 {
        if (shift == 0 and bits_to_read == 8) {
            // Reading all 8 bits from buffer
            return self.buffer;
        } else {
            const mask: u8 = (@as(u8, 1) << @intCast(bits_to_read)) - 1;
            return (self.buffer >> @intCast(shift)) & mask;
        }
    }
};

test "bit writer and reader basics" {
    const testing = std.testing;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir = tmp_dir.dir;

    // Write some bits
    {
        const file = try dir.createFile("test.bin", .{});
        defer file.close();

        var writer = BitWriter.init(file);
        try writer.writeBits(0b1010, 4);
        try writer.writeBits(0b1100, 4);
        try writer.writeByte(0xFF);
        try writer.flush();
    }

    // Read them back
    {
        const file = try dir.openFile("test.bin", .{});
        defer file.close();

        var reader = BitReader.init(file);
        const val1 = try reader.readBits(4);
        const val2 = try reader.readBits(4);
        const val3 = try reader.readU8();

        try testing.expectEqual(@as(u32, 0b1010), val1.?);
        try testing.expectEqual(@as(u32, 0b1100), val2.?);
        try testing.expectEqual(@as(u8, 0xFF), val3.?);
    }
}

test "bit writer/reader helper methods" {
    const testing = std.testing;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir = tmp_dir.dir;

    // Write using helper methods
    {
        const file = try dir.createFile("test.bin", .{});
        defer file.close();

        var writer = BitWriter.init(file);
        try writer.writeU16(0x1234);
        try writer.writeU32(0xABCDEF01);
        try writer.writeByte(0x42);
        try writer.flush();
    }

    // Read using helper methods
    {
        const file = try dir.openFile("test.bin", .{});
        defer file.close();

        var reader = BitReader.init(file);
        const val1 = try reader.readU16();
        const val2 = try reader.readU32();
        const val3 = try reader.readU8();

        try testing.expectEqual(@as(u16, 0x1234), val1.?);
        try testing.expectEqual(@as(u32, 0xABCDEF01), val2.?);
        try testing.expectEqual(@as(u8, 0x42), val3.?);
    }
}

