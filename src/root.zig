//! LZ77 compression and decompression library
//!
//! This library provides a complete implementation of the LZ77 lossless
//! compression algorithm, including bit-level I/O operations.
//!
//! Example usage:
//!
//! ```zig
//! const z77 = @import("z77");
//!
//! // Compression
//! var compressor = z77.Compressor.init(allocator, 4095, 15);
//! try compressor.compress(input_file, output_file);
//!
//! // Decompression
//! try z77.Compressor.decompress(allocator, input_file, output_file);
//! ```

const std = @import("std");

// Re-export public API
pub const bitio = @import("bitio.zig");
pub const lz77 = @import("lz77.zig");
pub const lz11 = @import("lz11.zig");
pub const diagnostic = @import("diagnostic.zig");

// Convenience re-exports for common types
pub const BitWriter = bitio.BitWriter;
pub const BitReader = bitio.BitReader;
pub const Token = lz77.Token;
pub const Header = lz77.Header;
pub const Match = lz77.Match;
pub const Compressor = lz77.Compressor;

// Run all tests from submodules
test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("bitio.zig");
    _ = @import("lz77.zig");
}
