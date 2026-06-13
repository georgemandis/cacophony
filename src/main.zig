const std = @import("std");
const builtin = @import("builtin");
const sound = @import("sound");

const version = "0.1.1";

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
        \\  completions <shell> Generate shell completions (bash, zsh, fish)
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

    if (std.mem.eql(u8, command, "completions")) {
        try cmdCompletions(&args_iter, &stdout.interface, &stderr.interface);
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

fn cmdCompletions(
    args_iter: anytype,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    const shell = args_iter.next() orelse {
        try stderr_writer.print("Error: 'completions' requires a shell: bash, zsh, or fish\n", .{});
        try stderr_writer.flush();
        std.process.exit(2);
        unreachable;
    };

    if (std.mem.eql(u8, shell, "bash")) {
        try stdout_writer.print(
            \\# cacophony completions for bash
            \\# Install: eval "$(cacophony completions bash)"
            \\# Persist: cacophony completions bash > /etc/bash_completion.d/cacophony
            \\
            \\_cacophony() {{
            \\    local cur prev words cword
            \\    _init_completion || return
            \\
            \\    local commands="classify listen categories completions help"
            \\
            \\    if [[ $cword -eq 1 ]]; then
            \\        COMPREPLY=($(compgen -W "$commands --help -h --version -v" -- "$cur"))
            \\        return
            \\    fi
            \\
            \\    local cmd="${{words[1]}}"
            \\
            \\    case "$cmd" in
            \\        classify)
            \\            COMPREPLY=($(compgen -W "--top= --threshold= --json" -- "$cur"))
            \\            ;;
            \\        listen)
            \\            COMPREPLY=($(compgen -W "--top= --threshold= --duration= --json" -- "$cur"))
            \\            ;;
            \\        categories)
            \\            COMPREPLY=($(compgen -W "--json" -- "$cur"))
            \\            ;;
            \\        completions)
            \\            COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
            \\            ;;
            \\    esac
            \\}}
            \\
            \\complete -F _cacophony cacophony
            \\
        , .{});
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try stdout_writer.print(
            \\#compdef cacophony
            \\# cacophony completions for zsh
            \\# Install: cacophony completions zsh | source /dev/stdin
            \\# Persist: cacophony completions zsh > ~/.zfunc/_cacophony && fpath+=(~/.zfunc)
            \\
            \\_cacophony() {{
            \\    local -a commands
            \\    commands=(
            \\        'classify:Classify sounds in an audio file'
            \\        'listen:Classify sounds from the microphone'
            \\        'categories:List all recognized sound categories'
            \\        'completions:Generate shell completions'
            \\        'help:Show help message'
            \\    )
            \\
            \\    _arguments -C \
            \\        '1:command:->command' \
            \\        '*::arg:->args'
            \\
            \\    case "$state" in
            \\        command)
            \\            _describe 'command' commands
            \\            ;;
            \\        args)
            \\            case "$words[1]" in
            \\                classify)
            \\                    _arguments \
            \\                        '--top=[Show top N classifications]:N:' \
            \\                        '--threshold=[Minimum confidence 0.0-1.0]:N:' \
            \\                        '--json[Output as JSON]' \
            \\                        '1:file:_files'
            \\                    ;;
            \\                listen)
            \\                    _arguments \
            \\                        '--top=[Show top N classifications]:N:' \
            \\                        '--threshold=[Minimum confidence 0.0-1.0]:N:' \
            \\                        '--duration=[Listen duration in ms]:MS:' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                categories)
            \\                    _arguments '--json[Output as JSON]'
            \\                    ;;
            \\                completions)
            \\                    _arguments '1:shell:(bash zsh fish)'
            \\                    ;;
            \\            esac
            \\            ;;
            \\    esac
            \\}}
            \\
            \\_cacophony "$@"
            \\
        , .{});
    } else if (std.mem.eql(u8, shell, "fish")) {
        try stdout_writer.print(
            \\# cacophony completions for fish
            \\# Install: cacophony completions fish | source
            \\# Persist: cacophony completions fish > ~/.config/fish/completions/cacophony.fish
            \\
            \\complete -e -c cacophony
            \\complete -c cacophony -f
            \\complete -c cacophony -n "__fish_use_subcommand" -a "classify" -d "Classify sounds in an audio file"
            \\complete -c cacophony -n "__fish_use_subcommand" -a "listen" -d "Classify sounds from the microphone"
            \\complete -c cacophony -n "__fish_use_subcommand" -a "categories" -d "List all recognized sound categories"
            \\complete -c cacophony -n "__fish_use_subcommand" -a "completions" -d "Generate shell completions"
            \\complete -c cacophony -n "__fish_use_subcommand" -a "help" -d "Show help message"
            \\complete -c cacophony -n "__fish_use_subcommand" -l help -s h -d "Show help"
            \\complete -c cacophony -n "__fish_use_subcommand" -l version -s v -d "Show version"
            \\
            \\# classify options
            \\complete -c cacophony -n "__fish_seen_subcommand_from classify" -l top -r -d "Show top N classifications"
            \\complete -c cacophony -n "__fish_seen_subcommand_from classify" -l threshold -r -d "Minimum confidence 0.0-1.0"
            \\complete -c cacophony -n "__fish_seen_subcommand_from classify" -l json -d "Output as JSON"
            \\
            \\# listen options
            \\complete -c cacophony -n "__fish_seen_subcommand_from listen" -l top -r -d "Show top N classifications"
            \\complete -c cacophony -n "__fish_seen_subcommand_from listen" -l threshold -r -d "Minimum confidence 0.0-1.0"
            \\complete -c cacophony -n "__fish_seen_subcommand_from listen" -l duration -r -d "Listen duration in ms"
            \\complete -c cacophony -n "__fish_seen_subcommand_from listen" -l json -d "Output as JSON"
            \\
            \\# categories options
            \\complete -c cacophony -n "__fish_seen_subcommand_from categories" -l json -d "Output as JSON"
            \\
            \\# completions sub-targets
            \\complete -c cacophony -n "__fish_seen_subcommand_from completions" -a "bash zsh fish" -d "Shell type"
            \\
        , .{});
    } else {
        try stderr_writer.print("Error: unsupported shell '{s}'. Use bash, zsh, or fish\n", .{shell});
        try stderr_writer.flush();
        std.process.exit(2);
        unreachable;
    }

    try stdout_writer.flush();
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
