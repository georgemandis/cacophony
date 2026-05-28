// Cross-platform dispatch layer for sound classification.
// Currently macOS-only (SoundAnalysis + AVFoundation via ObjC runtime bindings).

const std = @import("std");

const platform = switch (@import("builtin").os.tag) {
    .macos => @import("platform/macos.zig"),
    else => @compileError("cacophony: unsupported platform (macOS only)"),
};

pub const SoundError = error{
    FrameworkUnavailable,
    AnalysisFailed,
    MicrophoneUnavailable,
    FileNotFound,
    Timeout,
    OutOfMemory,
};

pub const Classification = struct {
    label: []const u8,
    confidence: f64,
};

/// List all known sound classification categories.
pub fn listCategories(allocator: std.mem.Allocator) SoundError![][]const u8 {
    return platform.listCategories(allocator);
}

/// Classify sounds from a file. Returns top N classifications.
pub fn classifyFile(allocator: std.mem.Allocator, path: []const u8, top_n: usize) SoundError![]Classification {
    return platform.classifyFile(allocator, path, top_n);
}

/// Listen to the microphone and classify sounds in real-time.
/// Calls the callback with classifications at each analysis window.
/// Runs for duration_ms milliseconds (0 = until interrupted).
pub fn listen(allocator: std.mem.Allocator, top_n: usize, duration_ms: u32, threshold: f64) SoundError![]Classification {
    return platform.listen(allocator, top_n, duration_ms, threshold);
}

pub fn freeClassifications(allocator: std.mem.Allocator, results: []Classification) void {
    for (results) |r| allocator.free(r.label);
    allocator.free(results);
}

pub fn freeCategories(allocator: std.mem.Allocator, categories: [][]const u8) void {
    for (categories) |c| allocator.free(c);
    allocator.free(categories);
}
