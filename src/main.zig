const std = @import("std");
const z77 = @import("z77");

const usage_text =
    \\Usage: z77 <options>
    \\
    \\Options:
    \\  -c                  Compression mode
    \\  -d                  Decompression mode
    \\  --inspect           Inspect a compressed file (diagnostics)
    \\  -i <filename>       Input file
    \\  -o <filename>       Output file
    \\  -l <value>          Lookahead size (default: 15)
    \\  -s <value>          Search buffer size (default: 4095)
    \\  -h, --help          Show this help message
    \\
    \\Examples:
    \\  Compress:   z77 -c -i input.txt -o output.lz77
    \\  Decompress: z77 -d -i input.lz77 -o output.txt
    \\  Inspect:    z77 --inspect -i file.lz77
    \\
;

const Mode = enum {
    none,
    compress,
    decompress,
    inspect,
};

const Config = struct {
    mode: Mode = .none,
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    lookahead_size: usize = 15,
    search_buffer_size: usize = 4095,
};

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-c")) {
            config.mode = .compress;
        } else if (std.mem.eql(u8, arg, "-d")) {
            config.mode = .decompress;
        } else if (std.mem.eql(u8, arg, "--inspect")) {
            config.mode = .inspect;
        } else if (std.mem.eql(u8, arg, "-i")) {
            config.input_file = args.next() orelse return error.MissingInputFile;
        } else if (std.mem.eql(u8, arg, "-o")) {
            config.output_file = args.next() orelse return error.MissingOutputFile;
        } else if (std.mem.eql(u8, arg, "-l")) {
            const value_str = args.next() orelse return error.MissingLookaheadValue;
            config.lookahead_size = try std.fmt.parseInt(usize, value_str, 10);
            if (config.lookahead_size == 0 or config.lookahead_size > 255) {
                return error.InvalidLookaheadSize;
            }
        } else if (std.mem.eql(u8, arg, "-s")) {
            const value_str = args.next() orelse return error.MissingSearchBufferValue;
            config.search_buffer_size = try std.fmt.parseInt(usize, value_str, 10);
            if (config.search_buffer_size == 0 or config.search_buffer_size > 65535) {
                return error.InvalidSearchBufferSize;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n\n{s}", .{ arg, usage_text });
            return error.InvalidArgument;
        }
    }

    return config;
}

fn validateConfig(config: Config) !void {
    if (config.mode == .none) {
        std.debug.print("Error: Mode (-c, -d, or --inspect) is required\n\n{s}", .{usage_text});
        return error.MissingMode;
    }

    if (config.input_file == null) {
        std.debug.print("Error: Input file (-i) is required\n\n{s}", .{usage_text});
        return error.MissingInputFile;
    }

    if (config.mode != .inspect and config.output_file == null) {
        std.debug.print("Error: Output file (-o) is required for compress/decompress modes\n\n{s}", .{usage_text});
        return error.MissingOutputFile;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator) catch |err| {
        if (err == error.InvalidArgument) {
            std.process.exit(1);
        }
        std.debug.print("Error parsing arguments: {}\n\n{s}", .{ err, usage_text });
        return err;
    };

    validateConfig(config) catch {
        std.process.exit(1);
    };

    const input_path = config.input_file.?;

    switch (config.mode) {
        .inspect => {
            std.debug.print("Inspecting: {s}\n\n", .{input_path});

            const input_file = std.fs.cwd().openFile(input_path, .{}) catch |err| {
                std.debug.print("Error: Cannot open file: {}\n", .{err});
                return err;
            };
            defer input_file.close();

            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
            const stdout = &stdout_writer.interface;
            try z77.diagnostic.inspectFile(input_file, stdout);
            try stdout.flush();
        },
        .compress => {
            const output_path = config.output_file.?;
            std.debug.print("Compressing: {s} -> {s}\n", .{ input_path, output_path });
            std.debug.print("Search buffer: {}, Lookahead: {}\n", .{
                config.search_buffer_size,
                config.lookahead_size,
            });

            const input_file = try std.fs.cwd().openFile(input_path, .{});
            defer input_file.close();

            const output_file = try std.fs.cwd().createFile(output_path, .{});
            defer output_file.close();

            var compressor = z77.Compressor.init(
                allocator,
                config.search_buffer_size,
                config.lookahead_size,
            );

            const start_time = std.time.milliTimestamp();
            try compressor.compress(input_file, output_file);
            const end_time = std.time.milliTimestamp();

            const input_size = try input_file.getEndPos();
            const output_size = try output_file.getEndPos();
            const ratio = if (input_size > 0)
                @as(f64, @floatFromInt(output_size)) / @as(f64, @floatFromInt(input_size)) * 100.0
            else
                0.0;

            std.debug.print("\nCompression complete!\n", .{});
            std.debug.print("Input size:  {} bytes\n", .{input_size});
            std.debug.print("Output size: {} bytes\n", .{output_size});
            std.debug.print("Ratio:       {d:.2}%\n", .{ratio});
            std.debug.print("Time:        {}ms\n", .{end_time - start_time});
        },
        .decompress => {
            const output_path = config.output_file.?;
            std.debug.print("Decompressing: {s} -> {s}\n", .{ input_path, output_path });

            const input_file = try std.fs.cwd().openFile(input_path, .{});
            defer input_file.close();

            // Auto-detect format
            const format = try z77.diagnostic.detectFormat(input_file);
            std.debug.print("Detected format: {s}\n", .{@tagName(format)});

            try input_file.seekTo(0);

            const output_file = try std.fs.cwd().createFile(output_path, .{});
            defer output_file.close();

            const start_time = std.time.milliTimestamp();

            switch (format) {
                .nintendo_lz77 => {
                    try z77.lz11.decompress(allocator, input_file, output_file);
                },
                .standard_lz77 => {
                    try z77.Compressor.decompress(allocator, input_file, output_file);
                },
                .unknown => {
                    std.debug.print("Error: Unknown or unsupported file format\n", .{});
                    std.debug.print("Try using --inspect to diagnose the file\n", .{});
                    return error.UnknownFormat;
                },
            }

            const end_time = std.time.milliTimestamp();

            const output_size = try output_file.getEndPos();

            std.debug.print("\nDecompression complete!\n", .{});
            std.debug.print("Output size: {} bytes\n", .{output_size});
            std.debug.print("Time:        {}ms\n", .{end_time - start_time});
        },
        .none => unreachable,
    }
}
