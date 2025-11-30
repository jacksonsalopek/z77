//! Diagnostic utilities for debugging compressed files
const std = @import("std");
const bitio = @import("bitio.zig");
const lz77 = @import("lz77.zig");
const lz11 = @import("lz11.zig");

/// Detect file format
pub const FileFormat = enum {
    nintendo_lz77,
    standard_lz77,
    unknown,
};

pub fn detectFormat(file: std.fs.File) !FileFormat {
    try file.seekTo(0);
    
    // Check for Nintendo LZ77 first
    if (try lz11.isNintendoLZ77(file)) {
        return .nintendo_lz77;
    }
    
    // Check for standard LZ77
    try file.seekTo(0);
    var bit_reader = bitio.BitReader.init(file);
    const header = lz77.Header.read(&bit_reader) catch return .unknown;
    
    if (header.search_buffer_size > 0 and header.search_buffer_size <= 65535 and
        header.lookahead_size > 0 and header.lookahead_size <= 255 and
        header.original_size > 0 and header.original_size < 1024 * 1024 * 1024)
    {
        return .standard_lz77;
    }
    
    return .unknown;
}

/// Inspect a compressed file and print diagnostic information
pub fn inspectFile(file: std.fs.File, writer: anytype) !void {
    try writer.print("=== LZ77 File Inspector ===\n\n", .{});
    
    // Detect format first
    const format = try detectFormat(file);
    try writer.print("Format detected: {s}\n\n", .{@tagName(format)});
    
    try file.seekTo(0);
    
    switch (format) {
        .nintendo_lz77 => try inspectNintendoLZ77(file, writer),
        .standard_lz77 => try inspectStandardLZ77(file, writer),
        .unknown => {
            try writer.print("❌ Unknown or invalid file format\n", .{});
            return error.UnknownFormat;
        },
    }
}

fn inspectNintendoLZ77(file: std.fs.File, writer: anytype) !void {
    const header = try lz11.Header.read(file);
    
    try writer.print("✓ Nintendo LZ77 header:\n", .{});
    try writer.print("  Compression type: {s} (0x{X:0>2})\n", .{
        @tagName(header.compression_type),
        @intFromEnum(header.compression_type),
    });
    try writer.print("  Decompressed size: {} bytes\n", .{header.decompressed_size});
    
    if (!header.isValid()) {
        try writer.print("⚠️  Header values look suspicious\n", .{});
    } else {
        try writer.print("✓ Header appears valid\n", .{});
    }
}

fn inspectStandardLZ77(file: std.fs.File, writer: anytype) !void {
    var bit_reader = bitio.BitReader.init(file);
    
    // Try to read header
    try writer.print("Reading header...\n", .{});
    const header = lz77.Header.read(&bit_reader) catch |err| {
        try writer.print("❌ Failed to read header: {}\n", .{err});
        try writer.print("\nThis file is likely not a valid z77 compressed file.\n", .{});
        return err;
    };
    
    try writer.print("✓ Header read successfully:\n", .{});
    try writer.print("  Search buffer size: {}\n", .{header.search_buffer_size});
    try writer.print("  Lookahead size:     {}\n", .{header.lookahead_size});
    try writer.print("  Original size:      {} bytes\n", .{header.original_size});
    
    // Validate header values
    var warnings: usize = 0;
    if (header.search_buffer_size == 0 or header.search_buffer_size > 65535) {
        try writer.print("⚠️  Unusual search buffer size\n", .{});
        warnings += 1;
    }
    if (header.lookahead_size == 0 or header.lookahead_size > 255) {
        try writer.print("⚠️  Unusual lookahead size\n", .{});
        warnings += 1;
    }
    if (header.original_size == 0) {
        try writer.print("⚠️  Original size is zero\n", .{});
        warnings += 1;
    }
    if (header.original_size > 100 * 1024 * 1024) {
        try writer.print("⚠️  Very large original size (>100MB)\n", .{});
        warnings += 1;
    }
    
    // Try to read first few tokens
    try writer.print("\nReading tokens...\n", .{});
    var token_count: usize = 0;
    var max_offset_seen: u16 = 0;
    var max_length_seen: u8 = 0;
    
    while (token_count < 10) {
        const token = lz77.Token.read(&bit_reader) catch |err| {
            try writer.print("❌ Error reading token {}: {}\n", .{ token_count, err });
            break;
        } orelse break;
        
        if (token_count < 5) {
            try writer.print("  Token {}: offset={:4}, length={:3}, next_char=0x{X:0>2}\n", .{
                token_count,
                token.offset,
                token.length,
                token.next_char,
            });
        }
        
        max_offset_seen = @max(max_offset_seen, token.offset);
        max_length_seen = @max(max_length_seen, token.length);
        token_count += 1;
    }
    
    try writer.print("\n✓ Read {} tokens\n", .{token_count});
    try writer.print("  Max offset seen: {}\n", .{max_offset_seen});
    try writer.print("  Max length seen: {}\n", .{max_length_seen});
    
    if (warnings > 0) {
        try writer.print("\n⚠️  {} warning(s) found\n", .{warnings});
    } else {
        try writer.print("\n✓ File appears to be valid\n", .{});
    }
}

/// Check if a file looks like a valid z77 file (quick check)
pub fn isLikelyValid(file: std.fs.File) bool {
    var bit_reader = bitio.BitReader.init(file);
    const header = lz77.Header.read(&bit_reader) catch return false;
    
    // Basic sanity checks
    if (header.search_buffer_size == 0 or header.search_buffer_size > 65535) return false;
    if (header.lookahead_size == 0 or header.lookahead_size > 255) return false;
    if (header.original_size == 0 or header.original_size > 1024 * 1024 * 1024) return false; // 1GB limit
    
    return true;
}

