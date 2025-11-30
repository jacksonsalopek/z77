# z77

A Zig implementation of the LZ77 lossless data compression algorithm, inspired by the [C implementation](https://github.com/cstdvd/lz77).

## Description

LZ77 is a lossless data compression algorithm published by Abraham Lempel and Jacob Ziv in 1977. It uses a sliding window technique to replace repeated occurrences of data with references to earlier occurrences.

### How It Works

The algorithm maintains a sliding window divided into two parts:
- **Search Buffer**: Previously encoded data (dictionary)
- **Lookahead Buffer**: Data yet to be compressed

Data is encoded as tokens containing:
- **Offset**: Distance back to a previous match
- **Length**: Number of matching characters
- **Next Character**: First character after the match

## Features

- ✅ Bit-level I/O for efficient storage
- ✅ Configurable search buffer size (default: 4095 bytes)
- ✅ Configurable lookahead buffer size (default: 15 bytes)
- ✅ Fast compression and decompression
- ✅ Comprehensive test suite

## Building

Requires Zig 0.15.2 or later.

```bash
zig build
```

## Usage

### Compression

```bash
./zig-out/bin/z77 -c -i input.txt -o output.lz77
```

### Decompression

```bash
./zig-out/bin/z77 -d -i input.lz77 -o output.txt
```

### Options

```
-c                  Compression mode
-d                  Decompression mode
-i <filename>       Input file
-o <filename>       Output file
-l <value>          Lookahead size (default: 15, max: 255)
-s <value>          Search buffer size (default: 4095, max: 65535)
-h, --help          Show help message
```

### Custom Buffer Sizes

For better compression of specific types of data, you can adjust the buffer sizes:

```bash
# Larger search buffer for better compression ratio (slower)
./zig-out/bin/z77 -c -i input.txt -o output.lz77 -s 32768 -l 127

# Smaller buffers for faster compression (lower ratio)
./zig-out/bin/z77 -c -i input.txt -o output.lz77 -s 1024 -l 8
```

## Running Tests

```bash
zig build test
```

The test suite includes:
- Bit-level I/O operations
- Token structure validation
- Compression and decompression round-trip tests

## Architecture

The codebase is organized into clean, modular components:

### Core Modules

1. **bitio.zig** - Bit-level I/O operations
   - `BitWriter`: Write individual bits to files with buffering
   - `BitReader`: Read individual bits from files
   - Helper methods: `writeU16()`, `writeU32()`, `readU8()`, etc.
   - Efficient handling of sub-byte operations

2. **lz77.zig** - Compression algorithm
   - `Token`: Represents LZ77 encoding units (offset, length, next_char)
   - `Header`: File header with metadata
   - `Match`: Result from pattern matching
   - `Compressor`: Main compression/decompression logic
   - Helper functions for sliding window operations

3. **root.zig** - Public API
   - Re-exports all public types and functions
   - Single import point for library consumers
   - Comprehensive documentation

4. **main.zig** - CLI application
   - Argument parsing with validation
   - File I/O handling
   - Performance statistics and reporting

### Design Principles

- **Separation of Concerns**: Each module has a single, well-defined responsibility
- **Encapsulation**: Internal helpers are private, public API is minimal
- **Reusability**: BitIO can be used independently for other projects
- **Testability**: Each module has its own comprehensive test suite
- **Type Safety**: Leverages Zig's strong type system throughout

## Performance

The implementation is optimized for simplicity and correctness. For very large files or production use, consider:

- Increasing the search buffer size for better compression
- Using parallel processing for multiple files
- Implementing hash-based matching for faster compression

## Comparison with Original C Implementation

This Zig implementation follows the same algorithmic approach as [cstdvd/lz77](https://github.com/cstdvd/lz77) but takes advantage of Zig's features:

- Memory safety without garbage collection
- Compile-time guarantees
- Modern error handling
- Better integer overflow protection
- Integrated build system and testing

## License

This is a educational/reference implementation. Feel free to use it as you see fit.

## References

- [LZ77 and LZ78 on Wikipedia](https://en.wikipedia.org/wiki/LZ77_and_LZ78)
- [Original C implementation](https://github.com/cstdvd/lz77)
- [Data Compression Explained](http://mattmahoney.net/dc/dce.html)

## Contributing

Suggestions and improvements are welcome! Some potential enhancements:

- [ ] Hash-based matching for faster compression
- [ ] Streaming mode for large files
- [ ] Multiple compression levels
- [ ] Benchmarking suite
- [ ] DEFLATE-compatible output format

