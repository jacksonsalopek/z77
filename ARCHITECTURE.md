# Architecture Documentation

This document provides an in-depth look at the architecture and design decisions of z77.

## Module Structure

```
src/
├── main.zig       # CLI application entry point
├── root.zig       # Public API and re-exports
├── bitio.zig      # Bit-level I/O operations
└── lz77.zig       # LZ77 compression algorithm
```

## Module Details

### bitio.zig - Bit-Level I/O

**Purpose**: Provide efficient bit-level read/write operations on files.

**Key Types**:
- `BitWriter`: Buffered writer for sub-byte values
- `BitReader`: Buffered reader for sub-byte values

**Design Decisions**:
- Uses 4-bit (`u4`) counter to track bits in buffer (0-8)
- Special case handling for 8-bit writes to avoid shift overflow
- Separate `flush()` for padding partial bytes with zeros
- Helper methods (`writeU16`, `readU32`, etc.) for common operations

**Extracted Helpers**:
- `flushByte()`: Internal helper to write buffer to file
- `readByte()`: Internal helper to read from file
- `extractBits()`: Internal helper for bit extraction logic

### lz77.zig - Compression Algorithm

**Purpose**: Implement the LZ77 sliding window compression algorithm.

**Key Types**:
- `Token`: Represents a compression token (offset, length, next_char)
- `Header`: File header containing metadata
- `Match`: Result from pattern matching in sliding window
- `Compressor`: Main compression/decompression engine

**Design Decisions**:
- Token read/write methods encapsulate serialization logic
- Header read/write methods ensure consistent file format
- Match type provides type-safe return values
- Compressor is stateless between operations (stores config only)

**Extracted Helpers**:
- `Token.write()` / `Token.read()`: Serialize/deserialize tokens
- `Header.write()` / `Header.read()`: Handle file headers
- `Match.none()`: Factory for empty matches
- `countMatchingBytes()`: Extracted from pattern matching
- `copyFromSlidingWindow()`: Extracted from decompression

### root.zig - Public API

**Purpose**: Provide a clean, documented public API.

**Pattern**: Re-export pattern
```zig
pub const bitio = @import("bitio.zig");
pub const lz77 = @import("lz77.zig");

// Convenience re-exports
pub const BitWriter = bitio.BitWriter;
pub const Compressor = lz77.Compressor;
```

**Benefits**:
- Single import point for users: `@import("z77")`
- Can use either namespaced (`z77.bitio.BitWriter`) or direct (`z77.BitWriter`)
- Easy to see entire public API at a glance

### main.zig - CLI Application

**Purpose**: Provide command-line interface for compression/decompression.

**Key Types**:
- `Config`: Parsed command-line configuration
- `Mode`: Enum for compression/decompression mode

**Extracted Functions**:
- `parseArgs()`: Parse command-line arguments
- `validateConfig()`: Validate parsed configuration
- `main()`: Entry point with error handling

**Design Decisions**:
- Separate parsing from validation for better error messages
- Use enum for mode instead of booleans
- Report comprehensive statistics after operations

## Key Refactoring Improvements

### 1. Token Serialization

**Before**: Token encoding/decoding logic scattered in compress/decompress
```zig
// In compress
try bit_writer.writeBits(match.offset, 16);
try bit_writer.writeBits(match.length, 8);
try bit_writer.writeBits(next_char, 8);

// In decompress  
const offset = try bit_reader.readBits(16) orelse break;
const length = try bit_reader.readBits(8) orelse return error.UnexpectedEOF;
const next_char = try bit_reader.readBits(8) orelse return error.UnexpectedEOF;
```

**After**: Encapsulated in Token methods
```zig
// In compress
try token.write(&bit_writer);

// In decompress
const token = try Token.read(&bit_reader) orelse break;
```

**Benefits**: DRY principle, easier to modify format, clearer intent

### 2. Header Management

**Before**: Header fields written/read inline
```zig
try bit_writer.writeBits(@intCast(self.search_buffer_size), 16);
try bit_writer.writeBits(@intCast(self.lookahead_size), 8);
try bit_writer.writeBits(@intCast(data.len), 32);
```

**After**: Encapsulated in Header type
```zig
const header = Header{ ... };
try header.write(&bit_writer);
```

**Benefits**: Type safety, easier versioning, self-documenting

### 3. BitIO Helper Methods

**Before**: Direct bit operations everywhere
```zig
try bit_writer.writeBits(offset, 16);
const value = try bit_reader.readBits(16) orelse ...;
const u16_value: u16 = @intCast(value);
```

**After**: Typed helper methods
```zig
try bit_writer.writeU16(offset);
const value = try bit_reader.readU16() orelse ...;
```

**Benefits**: Less casting, clearer intent, fewer errors

### 4. Pattern Matching Extraction

**Before**: Large inline loop in `findLongestMatch`
```zig
var match_len: usize = 0;
while (match_len < max_match_len and
    data[i + match_len] == data[current_pos + match_len]) : (match_len += 1)
{}
```

**After**: Separate helper method
```zig
const match_len = self.countMatchingBytes(data, i, current_pos, max_match_len);
```

**Benefits**: More testable, reusable, readable

### 5. Sliding Window Copy

**Before**: Inline in decompress loop
```zig
if (length > 0) {
    const start_pos = output_buffer.items.len - offset;
    var i: usize = 0;
    while (i < length and output_buffer.items.len < original_size) : (i += 1) {
        const byte = output_buffer.items[start_pos + i];
        try output_buffer.append(allocator, byte);
    }
}
```

**After**: Extracted function
```zig
if (token.length > 0) {
    try copyFromSlidingWindow(&output_buffer, allocator, token.offset, token.length, header.original_size);
}
```

**Benefits**: More testable, clearer logic, reusable

## Testing Strategy

Each module has its own test suite:

- **bitio.zig**: Tests bit-level read/write operations
- **lz77.zig**: Tests token serialization, headers, and compression
- **root.zig**: Runs all sub-module tests
- **main.zig**: Manual integration testing

This ensures that each component can be tested in isolation.

## Future Enhancements

The modular structure makes it easy to add:

1. **Alternative compression algorithms**: Add `lz78.zig`, `huffman.zig`, etc.
2. **Streaming API**: Add `streaming.zig` for large file handling
3. **Hash-based matching**: Add `hash_table.zig` for faster compression
4. **Custom bit formats**: Extend `bitio.zig` with more helpers
5. **Compression levels**: Add `levels.zig` with presets

## Performance Considerations

- BitIO uses buffering to minimize syscalls
- Token serialization is inlined for performance
- Pattern matching is O(n²) but limited by window size
- Memory allocations are minimal (one buffer for data)

## API Stability

Public API (exported from `root.zig`):
- ✅ Stable: `BitWriter`, `BitReader`, `Compressor`, `Token`
- ⚠️ May change: `Header`, `Match` (internal details may evolve)
- 🔒 Private: Helper functions in each module

## Conclusion

The refactored architecture provides:
- **Modularity**: Clear separation of concerns
- **Maintainability**: Easy to understand and modify
- **Testability**: Each component tested independently  
- **Extensibility**: Easy to add new features
- **Documentation**: Self-documenting code structure

