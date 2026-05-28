const std = @import("std");
const objc = @import("../objc.zig");
const sound = @import("../sound.zig");

// ---------------------------------------------------------------------------
// CoreMedia time struct
// ---------------------------------------------------------------------------
const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
};

// ---------------------------------------------------------------------------
// CoreFoundation run loop externs
// ---------------------------------------------------------------------------
extern "c" fn CFRunLoopGetCurrent() *anyopaque;
extern "c" fn CFRunLoopStop(rl: *anyopaque) void;
extern "c" fn CFRunLoopRunInMode(mode: objc.id, seconds: f64, returnAfterSourceHandled: bool) i32;
extern "c" var kCFRunLoopDefaultMode: objc.id;

// ---------------------------------------------------------------------------
// ObjC block ABI (for AVAudioEngine installTap block)
// ---------------------------------------------------------------------------
extern var _NSConcreteStackBlock: [1]usize;

const BlockDescriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
};

// Block for installTap:onBus:bufferSize:format:block:
// Block signature: (AVAudioPCMBuffer, AVAudioTime) -> Void
const TapBlockLiteral = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*TapBlockLiteral, objc.id, objc.id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

const tap_block_descriptor = BlockDescriptor{
    .reserved = 0,
    .size = @sizeOf(TapBlockLiteral),
};

// ---------------------------------------------------------------------------
// Module-level state
// ---------------------------------------------------------------------------
var observer_class: ?objc.Class = null;
var analysis_completed: bool = false;
var analysis_error: bool = false;
var current_run_loop: ?*anyopaque = null;

// Classification results collected by the observer
var result_classifications: std.ArrayList(sound.Classification) = .empty;
var result_allocator: std.mem.Allocator = undefined;
var result_top_n: usize = 5;
var result_threshold: f64 = 0.0;

// Stream analyzer reference for tap block callback
var stream_analyzer_ref: ?objc.id = null;

// Static tap block — must be module-level so it survives across threads.
// The .isa field is initialized at runtime in listen() since _NSConcreteStackBlock
// is an extern var whose address isn't known at comptime.
var static_tap_block: TapBlockLiteral = undefined;


// ---------------------------------------------------------------------------
// SNResultsObserving callbacks
// ---------------------------------------------------------------------------

fn requestDidProduceResult(_self: objc.id, _sel: objc.SEL, request: objc.id, result: objc.id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = request;

    // Check if this is an SNClassificationResult
    const SNClassificationResult = objc.getClass("SNClassificationResult") orelse return;
    const is_classification = objc.msgSend(bool, result, objc.sel("isKindOfClass:"), .{@as(objc.id, @ptrCast(SNClassificationResult))});
    if (!is_classification) return;

    // Get classifications array
    const classifications = objc.msgSend(objc.id, result, objc.sel("classifications"), .{});
    const count = objc.nsArrayCount(classifications);

    const limit = @min(count, result_top_n);
    for (0..limit) |i| {
        const classification = objc.nsArrayObjectAtIndex(classifications, i);

        // Get identifier string
        const identifier = objc.msgSend(objc.id, classification, objc.sel("identifier"), .{});
        const id_cstr = objc.fromNSString(identifier) orelse continue;
        const id_slice = std.mem.sliceTo(id_cstr, 0);

        // Get confidence (double)
        const confidence = objc.msgSend(f64, classification, objc.sel("confidence"), .{});

        // Filter by threshold
        if (confidence < result_threshold) continue;

        // For listen mode, replace existing results each time (latest window)
        // For file mode, accumulate
        result_classifications.append(result_allocator, .{
            .label = result_allocator.dupe(u8, id_slice) catch continue,
            .confidence = confidence,
        }) catch continue;
    }
}

fn requestDidFailWithError(_self: objc.id, _sel: objc.SEL, request: objc.id, err: objc.id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = request;
    _ = err;

    analysis_error = true;
    analysis_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

fn requestDidComplete(_self: objc.id, _sel: objc.SEL, request: objc.id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = request;

    analysis_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

// ---------------------------------------------------------------------------
// Audio tap block callback (for live mic)
// ---------------------------------------------------------------------------

fn tapBlockInvoke(block: *TapBlockLiteral, buffer: objc.id, when: objc.id) callconv(.c) void {
    _ = block;

    // Feed buffer to the stream analyzer
    if (stream_analyzer_ref) |analyzer| {
        // Get the frame position from AVAudioTime
        const frame_pos = objc.msgSend(i64, when, objc.sel("sampleTime"), .{});
        // analyzeAudioBuffer:atAudioFramePosition:
        objc.msgSend(void, analyzer, objc.sel("analyzeAudioBuffer:atAudioFramePosition:"), .{ buffer, frame_pos });
    }
}

// ---------------------------------------------------------------------------
// Observer class registration
// ---------------------------------------------------------------------------

fn ensureObserverClass() void {
    if (observer_class != null) return;

    const NSObject = objc.getClass("NSObject") orelse unreachable;
    const cls = objc.allocateClassPair(NSObject, "CacophonyObserver") orelse unreachable;

    // Add SNResultsObserving protocol
    _ = objc.addProtocol(cls, "SNResultsObserving");

    // request:didProduceResult: — "v@:@@"
    _ = objc.addMethod(
        cls,
        objc.sel("request:didProduceResult:"),
        @ptrCast(&requestDidProduceResult),
        "v@:@@",
    );

    // request:didFailWithError: — "v@:@@"
    _ = objc.addMethod(
        cls,
        objc.sel("request:didFailWithError:"),
        @ptrCast(&requestDidFailWithError),
        "v@:@@",
    );

    // requestDidComplete: — "v@:@"
    _ = objc.addMethod(
        cls,
        objc.sel("requestDidComplete:"),
        @ptrCast(&requestDidComplete),
        "v@:@",
    );

    objc.registerClassPair(cls);
    observer_class = cls;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn createClassifyRequest(window_duration_secs: f64) ?objc.id {
    const SNClassifySoundRequest = objc.getClass("SNClassifySoundRequest") orelse return null;
    const alloc_req = objc.msgSend(objc.id, SNClassifySoundRequest, objc.sel("alloc"), .{});

    // initWithClassifierIdentifier:error:
    const classifier_id = objc.nsString("com.apple.SoundAnalysis.classifier.v1");
    var err: ?objc.id = null;

    const request = objc.msgSend(?objc.id, alloc_req, objc.sel("initWithClassifierIdentifier:error:"), .{ classifier_id, &err }) orelse return null;

    // Set windowDuration (CMTime) — required for stream analysis to produce results.
    // CMTimeMakeWithSeconds(seconds, preferredTimescale)
    const CMTimeMakeWithSeconds = @extern(*const fn (f64, i32) callconv(.c) CMTime, .{ .name = "CMTimeMakeWithSeconds" });
    const window_time = CMTimeMakeWithSeconds(window_duration_secs, 48000);
    objc.msgSend(void, request, objc.sel("setWindowDuration:"), .{window_time});

    return request;
}

fn createObserver() objc.id {
    ensureObserverClass();
    const cls = observer_class.?;
    const alloc_obs = objc.msgSend(objc.id, cls, objc.sel("alloc"), .{});
    return objc.msgSend(objc.id, alloc_obs, objc.sel("init"), .{});
}

// ---------------------------------------------------------------------------
// Public API: list categories
// ---------------------------------------------------------------------------

pub fn listCategories(allocator: std.mem.Allocator) sound.SoundError![][]const u8 {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const request = createClassifyRequest(1.0) orelse return sound.SoundError.FrameworkUnavailable;

    // knownClassifications returns NSArray<NSString>
    const known = objc.msgSend(objc.id, request, objc.sel("knownClassifications"), .{});
    const count = objc.nsArrayCount(known);

    var categories = allocator.alloc([]const u8, count) catch return sound.SoundError.OutOfMemory;
    var valid: usize = 0;

    for (0..count) |i| {
        const ns_str = objc.nsArrayObjectAtIndex(known, i);
        const cstr = objc.fromNSString(ns_str) orelse continue;
        const slice = std.mem.sliceTo(cstr, 0);
        categories[valid] = allocator.dupe(u8, slice) catch return sound.SoundError.OutOfMemory;
        valid += 1;
    }

    return allocator.realloc(categories, valid) catch categories[0..valid];
}

// ---------------------------------------------------------------------------
// Public API: classify file
// ---------------------------------------------------------------------------

pub fn classifyFile(allocator: std.mem.Allocator, path: []const u8, top_n: usize) sound.SoundError![]sound.Classification {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    // Reset state
    analysis_completed = false;
    analysis_error = false;
    result_classifications = .empty;
    result_allocator = allocator;
    result_top_n = top_n;
    result_threshold = 0.0;

    // Create NSURL from file path
    const ns_path = objc.nsStringFromSlice(path.ptr, path.len) orelse
        return sound.SoundError.FileNotFound;
    const NSURL = objc.getClass("NSURL") orelse return sound.SoundError.FrameworkUnavailable;
    const file_url = objc.msgSend(objc.id, NSURL, objc.sel("fileURLWithPath:"), .{ns_path});

    // Create SNAudioFileAnalyzer
    const SNAudioFileAnalyzer = objc.getClass("SNAudioFileAnalyzer") orelse
        return sound.SoundError.FrameworkUnavailable;
    const analyzer_alloc = objc.msgSend(objc.id, SNAudioFileAnalyzer, objc.sel("alloc"), .{});

    var init_err: ?objc.id = null;
    const analyzer = objc.msgSend(?objc.id, analyzer_alloc, objc.sel("initWithURL:error:"), .{ file_url, &init_err }) orelse
        return sound.SoundError.FileNotFound;

    // Create classification request
    const request = createClassifyRequest(1.0) orelse return sound.SoundError.FrameworkUnavailable;

    // Create observer
    const observer = createObserver();

    // Add request with observer
    var add_err: ?objc.id = null;
    const added = objc.msgSend(bool, analyzer, objc.sel("addRequest:withObserver:error:"), .{ request, observer, &add_err });
    if (!added) return sound.SoundError.AnalysisFailed;

    // analyze blocks until complete, calling observer callbacks during analysis
    current_run_loop = CFRunLoopGetCurrent();
    objc.msgSend(void, analyzer, objc.sel("analyze"), .{});
    current_run_loop = null;

    if (analysis_error) {
        // Clean up any partial results
        for (result_classifications.items[0..result_classifications.items.len]) |r| allocator.free(r.label);
        result_classifications.deinit(allocator);
        return sound.SoundError.AnalysisFailed;
    }

    // Deduplicate: aggregate by label, keeping highest confidence
    var deduped = std.ArrayList(sound.Classification).empty;
    for (result_classifications.items) |item| {
        var found = false;
        for (deduped.items) |*existing| {
            if (std.mem.eql(u8, existing.label, item.label)) {
                if (item.confidence > existing.confidence) {
                    existing.confidence = item.confidence;
                }
                allocator.free(item.label);
                found = true;
                break;
            }
        }
        if (!found) {
            deduped.append(allocator, item) catch continue;
        }
    }
    result_classifications.deinit(allocator);

    // Sort by confidence descending
    const owned = deduped.toOwnedSlice(allocator) catch return sound.SoundError.OutOfMemory;
    std.mem.sort(sound.Classification, owned, {}, struct {
        fn lessThan(_: void, a: sound.Classification, b: sound.Classification) bool {
            return a.confidence > b.confidence;
        }
    }.lessThan);

    // Return top N
    if (owned.len > top_n) {
        for (owned[top_n..]) |r| allocator.free(r.label);
        return allocator.realloc(owned, top_n) catch owned[0..top_n];
    }

    return owned;
}

// ---------------------------------------------------------------------------
// Public API: listen (live mic)
// ---------------------------------------------------------------------------

pub fn listen(allocator: std.mem.Allocator, top_n: usize, duration_ms: u32, threshold: f64) sound.SoundError![]sound.Classification {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    // Reset state
    analysis_completed = false;
    analysis_error = false;
    result_classifications = .empty;
    result_allocator = allocator;
    result_top_n = top_n;
    result_threshold = threshold;

    // Create AVAudioEngine
    const AVAudioEngine = objc.getClass("AVAudioEngine") orelse
        return sound.SoundError.FrameworkUnavailable;
    const engine_alloc = objc.msgSend(objc.id, AVAudioEngine, objc.sel("alloc"), .{});
    const engine = objc.msgSend(objc.id, engine_alloc, objc.sel("init"), .{});

    // Get input node and its format
    const input_node = objc.msgSend(objc.id, engine, objc.sel("inputNode"), .{});
    const format = objc.msgSend(objc.id, input_node, objc.sel("outputFormatForBus:"), .{@as(objc.NSUInteger, 0)});

    // Create SNAudioStreamAnalyzer with the mic format
    const SNAudioStreamAnalyzer = objc.getClass("SNAudioStreamAnalyzer") orelse
        return sound.SoundError.FrameworkUnavailable;
    const stream_alloc = objc.msgSend(objc.id, SNAudioStreamAnalyzer, objc.sel("alloc"), .{});
    const stream_analyzer = objc.msgSend(objc.id, stream_alloc, objc.sel("initWithFormat:"), .{format});
    stream_analyzer_ref = stream_analyzer;

    // Create classification request with 1-second analysis windows
    const request = createClassifyRequest(1.0) orelse return sound.SoundError.FrameworkUnavailable;
    const observer = createObserver();

    var add_err: ?objc.id = null;
    const added = objc.msgSend(bool, stream_analyzer, objc.sel("addRequest:withObserver:error:"), .{ request, observer, &add_err });
    if (!added) return sound.SoundError.AnalysisFailed;

    // Install tap on input node to feed audio to the stream analyzer.
    // The block must be module-level (static) because the audio engine calls
    // it from a background thread after this function's stack frame is gone.
    static_tap_block = .{
        .isa = @ptrCast(&_NSConcreteStackBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &tapBlockInvoke,
        .descriptor = &tap_block_descriptor,
    };
    // installTapOnBus:bufferSize:format:block:
    objc.msgSend(void, input_node, objc.sel("installTapOnBus:bufferSize:format:block:"), .{
        @as(objc.NSUInteger, 0),
        @as(u32, 4096),
        format,
        @as(objc.id, @ptrCast(&static_tap_block)),
    });

    // Start the audio engine
    var start_err: ?objc.id = null;
    const started = objc.msgSend(bool, engine, objc.sel("startAndReturnError:"), .{&start_err});
    if (!started) {
        stream_analyzer_ref = null;
        return sound.SoundError.MicrophoneUnavailable;
    }

    // Run for specified duration. The audio engine feeds buffers on background
    // threads, and the observer callbacks also fire on background threads.
    // CFRunLoopRunInMode blocks the main thread for the duration while the
    // background threads do their work and write to module-level state.
    const duration_seconds: f64 = if (duration_ms > 0)
        @as(f64, @floatFromInt(duration_ms)) / 1000.0
    else
        5.0;

    current_run_loop = CFRunLoopGetCurrent();
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, duration_seconds, false);

    // Stop engine
    objc.msgSend(void, input_node, objc.sel("removeTapOnBus:"), .{@as(objc.NSUInteger, 0)});
    objc.msgSend(void, engine, objc.sel("stop"), .{});

    // Call completeAnalysis to flush remaining results, then wait briefly
    objc.msgSend(void, stream_analyzer, objc.sel("completeAnalysis"), .{});
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    current_run_loop = null;

    stream_analyzer_ref = null;

    if (analysis_error) {
        for (result_classifications.items) |r| allocator.free(r.label);
        result_classifications.deinit(allocator);
        return sound.SoundError.AnalysisFailed;
    }

    // Deduplicate: keep highest confidence per label
    var deduped = std.ArrayList(sound.Classification).empty;
    for (result_classifications.items) |item| {
        var found = false;
        for (deduped.items) |*existing| {
            if (std.mem.eql(u8, existing.label, item.label)) {
                if (item.confidence > existing.confidence) {
                    existing.confidence = item.confidence;
                }
                allocator.free(item.label);
                found = true;
                break;
            }
        }
        if (!found) {
            deduped.append(allocator, item) catch continue;
        }
    }
    result_classifications.deinit(allocator);

    // Sort by confidence descending
    const owned = deduped.toOwnedSlice(allocator) catch return sound.SoundError.OutOfMemory;
    std.mem.sort(sound.Classification, owned, {}, struct {
        fn lessThan(_: void, a: sound.Classification, b: sound.Classification) bool {
            return a.confidence > b.confidence;
        }
    }.lessThan);

    // Return top N
    if (owned.len > top_n) {
        for (owned[top_n..]) |r| allocator.free(r.label);
        return allocator.realloc(owned, top_n) catch owned[0..top_n];
    }

    return owned;
}
