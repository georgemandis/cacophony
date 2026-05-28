const std = @import("std");
const builtin = @import("builtin");
const sound = @import("sound");

const version = "0.1.0";

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: cacophony <command> [options]
        \\
        \\Sound classification CLI powered by native macOS SoundAnalysis.
        \\Classify 300+ sound types from audio files or live microphone input.
        \\Version {s} ({s})
        \\
        \\Commands:
        \\  classify <file>    Classify sounds in an audio file
        \\  listen             Classify sounds from the microphone
        \\  categories         List all recognized sound categories
        \\  help               Show this help message
        \\
        \\Options:
        \\  --top=N            Show top N classifications (default: 5)
        \\  --threshold=N      Minimum confidence 0.0-1.0 (default: 0.0)
        \\  --duration=MS      Listen duration in ms (default: 5000)
        \\  --json             Output as JSON
        \\  --help, -h         Show this help message
        \\  --version, -v      Show version
        \\
        \\Examples:
        \\  cacophony classify recording.wav
        \\  cacophony classify song.mp3 --top=10 --json
        \\  cacophony listen --duration=3000
        \\  cacophony listen --threshold=0.5 --top=3
        \\  cacophony categories
        \\  cacophony categories --json
        \\
        \\Created by George Mandis <george@mand.is>
        \\
    , .{ version, @tagName(builtin.os.tag) });
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.print("{c}", .{c}),
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(init.io, &stdout_buf);

    const stderr_file = std.Io.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(init.io, &stderr_buf);

    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    // Get command
    const command = args_iter.next() orelse {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try stdout.interface.print("cacophony " ++ version ++ " (" ++ @tagName(builtin.os.tag) ++ ")\n", .{});
        try stdout.interface.flush();
        return;
    }

    // Parse flags
    var json_mode = false;
    var top_n: usize = 5;
    var threshold: f64 = 0.0;
    var duration_ms: u32 = 5000;
    var file_path: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--top=")) {
            top_n = std.fmt.parseInt(usize, arg["--top=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --top value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
            if (top_n == 0) top_n = 1;
        } else if (std.mem.startsWith(u8, arg, "--threshold=")) {
            threshold = std.fmt.parseFloat(f64, arg["--threshold=".len..]) catch {
                try stderr.interface.print("Error: invalid --threshold value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            duration_ms = std.fmt.parseInt(u32, arg["--duration=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --duration value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.interface.print("Error: unknown flag: {s}\n", .{arg});
            try stderr.interface.flush();
            std.process.exit(2);
        } else {
            if (file_path == null) {
                file_path = arg;
            }
        }
    }

    // Dispatch commands
    if (std.mem.eql(u8, command, "categories")) {
        try cmdCategories(&stdout.interface, allocator, json_mode);
    } else if (std.mem.eql(u8, command, "classify")) {
        const path = file_path orelse {
            try stderr.interface.print("Error: no file path provided\n", .{});
            try stderr.interface.flush();
            std.process.exit(1);
        };
        try cmdClassify(&stdout.interface, allocator, path, top_n, json_mode);
    } else if (std.mem.eql(u8, command, "listen")) {
        try cmdListen(&stdout.interface, &stderr.interface, allocator, top_n, duration_ms, threshold, json_mode);
    } else {
        try stderr.interface.print("Error: unknown command '{s}'\n\n", .{command});
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(2);
    }

    try stdout.interface.flush();
}

fn cmdCategories(writer: *std.Io.Writer, allocator: std.mem.Allocator, json_mode: bool) !void {
    const categories = sound.listCategories(allocator) catch |err| {
        return printSoundError(writer, err);
    };
    defer sound.freeCategories(allocator, categories);

    if (json_mode) {
        try writer.print("[", .{});
        for (categories, 0..) |cat, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("\"", .{});
            try writeJsonString(writer, cat);
            try writer.print("\"", .{});
        }
        try writer.print("]\n", .{});
    } else {
        for (categories) |cat| {
            try writer.print("{s}\n", .{cat});
        }
    }
}

fn cmdClassify(writer: *std.Io.Writer, allocator: std.mem.Allocator, path: []const u8, top_n: usize, json_mode: bool) !void {
    const results = sound.classifyFile(allocator, path, top_n) catch |err| {
        return printSoundError(writer, err);
    };
    defer sound.freeClassifications(allocator, results);

    printClassifications(writer, results, json_mode) catch return;
}

fn cmdListen(writer: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, top_n: usize, duration_ms: u32, threshold: f64, json_mode: bool) !void {
    if (!json_mode) {
        try stderr.print("Listening for {d:.1}s...\n", .{@as(f64, @floatFromInt(duration_ms)) / 1000.0});
        try stderr.flush();
    }

    const results = sound.listen(allocator, top_n, duration_ms, threshold) catch |err| {
        return printSoundError(writer, err);
    };
    defer sound.freeClassifications(allocator, results);

    printClassifications(writer, results, json_mode) catch return;
}

fn printClassifications(writer: *std.Io.Writer, results: []const sound.Classification, json_mode: bool) !void {
    if (json_mode) {
        try writer.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"label\":\"", .{});
            try writeJsonString(writer, r.label);
            try writer.print("\",\"confidence\":{d:.4}}}", .{r.confidence});
        }
        try writer.print("]\n", .{});
    } else {
        for (results) |r| {
            try writer.print("{d:.4}\t{s}\n", .{ r.confidence, r.label });
        }
    }
}

fn printSoundError(writer: *std.Io.Writer, err: sound.SoundError) !void {
    const msg: []const u8 = switch (err) {
        sound.SoundError.FrameworkUnavailable => "SoundAnalysis framework not available",
        sound.SoundError.AnalysisFailed => "Sound analysis failed",
        sound.SoundError.MicrophoneUnavailable => "Microphone not available or access denied",
        sound.SoundError.FileNotFound => "Audio file not found or unsupported format",
        sound.SoundError.Timeout => "Analysis timed out",
        sound.SoundError.OutOfMemory => "Out of memory",
    };
    try writer.print("Error: {s}\n", .{msg});
}
