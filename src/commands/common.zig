const std = @import("std");
pub const assert = std.debug.assert;
pub const Io = std.Io;

pub const heap = @import("../heap.zig");
pub const Value = heap.Value;

pub const memutil = @import("../memutil.zig");
pub const expectErrorOrOom = memutil.expectErrorOrOom;

pub const hashutil = @import("../hashutil.zig");

pub const objects = @import("../objects.zig");
pub const ErrorDetails = objects.ErrorDetails;
pub const Shimmerable = objects.Shimmerable;

pub const Interp = @import("../Interp.zig");

const evaltypes = @import("../evaltypes.zig");
pub const Expression = evaltypes.Expression;

pub const Capability = @import("../Capability.zig");
pub const capabilities = @import("../capabilities.zig");

pub fn registerCommand(
    interp: *Interp,
    name: []const u8,
    to_call: evaltypes.CommandFn,
    description: []const u8,
    min_arity: usize,
    max_arity: ?usize,
) !void {
    try interp.registerCommand(name, .{
        .call_info = .{ .zig = to_call },
        .description = description,
        .min_arity = min_arity,
        .max_arity = max_arity,
    });
}

pub fn registerSafeCoreCommands(interp: *Interp) !void {
    try @import("control_flow.zig").registerCommands(interp);
    try @import("variables.zig").registerCommands(interp);
    try @import("eval.zig").registerSafeCommands(interp);
    try @import("strings.zig").registerCommands(interp);
    try @import("math.zig").registerCommands(interp);
    try @import("misc.zig").registerCommands(interp);
    try @import("dict.zig").registerCommands(interp);
    try @import("list.zig").registerCommands(interp);
    try @import("try_catch.zig").registerCommands(interp);
    try @import("regex.zig").registerCommands(interp);
    try @import("clock.zig").registerCommands(interp);
    try @import("binary.zig").registerCommands(interp);
    try @import("codec.zig").registerCommands(interp);
    try @import("vm.zig").registerCommands(interp);
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try registerSafeCoreCommands(interp);
    try @import("exec.zig").registerCommands(interp);
    try @import("io.zig").registerCommands(interp);
    try @import("load.zig").registerCommands(interp);
}

pub fn testStartSafe(ta: std.mem.Allocator) !Interp {
    _ = try heap.testStart(ta, null);
    errdefer heap.testFinish();
    var interp = try Interp.init(.{});
    errdefer interp.deinit();
    try registerSafeCoreCommands(&interp);
    return interp;
}

pub fn testStart(ta: std.mem.Allocator) !Interp {
    _ = try heap.testStart(ta, null);
    errdefer heap.testFinish();
    var interp = try Interp.init(.{});
    errdefer interp.deinit();
    try registerCoreCommands(&interp);
    return interp;
}

pub fn testFinish(interp: *Interp) void {
    interp.deinit();
    heap.testFinish();
}

/// Runs fuzz inputs so that each one's allocations and frees balance exactly,
/// without reinitializing the interpreter between them. This is _not_ a
/// general-purpose sandbox: it assumes nothing else is evaluating, and only
/// rewinds the state a fuzz input can leave behind.
pub const FuzzSandbox = struct {
    /// The root frame's variables, every registered command among them. Inputs
    /// reach these only through this frozen capture, since resolving a command
    /// shimmers its value in place, and a shimmer that outlived its input would
    /// change the next input's allocations.
    root_scope: *objects.Dictionary,
    no_arg_names: *objects.List,
    cache_id: u64,
    prng: std.Random.DefaultPrng,

    /// Deep recursion grows the frame stacks, and they keep that capacity
    /// afterwards, so they're pinned to this between inputs.
    const frame_stack_capacity = 16;

    pub fn init(interp: *Interp) !FuzzSandbox {
        assert(interp.call_frames.items.len == 1);
        assert(interp.eval_frames.items.len == 1);

        const root_scope = try interp.captureScope(0);
        errdefer root_scope.asHead().dropReference();
        root_scope.asHead().makeCrossthread();
        // Rendering a closure as a string hash-registers its captured scope,
        // which for closures created by inputs is `root_scope`. That happens
        // once and then persists, so it's done here rather than counted against
        // whichever input renders a closure first.
        _ = try root_scope.asHead().getHashRegistering();
        try heap.registered_hashes.shrinkToFit();

        const no_arg_names = try objects.List.new(&.{});
        errdefer no_arg_names.asHead().dropReference();
        no_arg_names.asHead().makeCrossthread();

        try pinCapacity(&interp.call_frames, frame_stack_capacity);
        try pinCapacity(&interp.eval_frames, frame_stack_capacity);

        return .{
            .root_scope = root_scope,
            .no_arg_names = no_arg_names,
            .cache_id = evaltypes.Closure.closure_cache_id.fetchAdd(1, .monotonic),
            .prng = interp.prng,
        };
    }

    pub fn deinit(sandbox: *FuzzSandbox) void {
        sandbox.root_scope.asHead().dropReference();
        sandbox.no_arg_names.asHead().dropReference();
        sandbox.* = undefined;
    }

    /// Evaluates `script` as the body of a closure that takes no arguments,
    /// fenced off from the root frame. Call `reset` afterwards, whether or not
    /// this errors.
    pub fn run(sandbox: *const FuzzSandbox, interp: *Interp, script: []const u8) !void {
        const body = try objects.String.newValue(script);
        defer body.dropReference();

        var content: evaltypes.Closure.Content = .{
            .arg_names = sandbox.no_arg_names,
            .optional_values = null,
            .required_arity = 0,
            .optional_arity = 0,
            .body = body,
            .name = .none,
            .scope = sandbox.root_scope,
            .has_args_parameter = false,
            .is_method = false,
            .cache_id = sandbox.cache_id,
        };
        var args = [_]Shimmerable{.{ .original = heap.InternedString.newValue("fuzz") }};
        defer args[0].discardChanges();
        const cache_key = @as(u256, sandbox.cache_id) ^ try body.getHashNoRegister();

        const previous_fence = interp.call_frame_fence;
        interp.call_frame_fence = interp.callFrame().level + 1;
        defer interp.call_frame_fence = previous_fence;

        try interp.callClosure(&content, null, cache_key, &args);
    }

    pub fn reset(sandbox: *const FuzzSandbox, interp: *Interp) !void {
        // A script that errored or was cancelled still unwinds every frame it
        // pushed, so anything left over is an interpreter bug.
        assert(interp.call_frames.items.len == 1);
        assert(interp.eval_frames.items.len == 1);

        interp.stop_executing.store(false, .release);
        interp.setEmptyResult();
        interp.stack_trace.swapWithNone();
        interp.pending_error_code.swapWithNone();
        interp.pending_error_during.swapWithNone();
        if (interp.pending_tailcall) |*tailcall| {
            tailcall.deinit();
            interp.pending_tailcall = null;
        }
        interp.return_propagate = .{};
        interp.loop_propagate = 0;
        interp.eval_depth = 0;
        interp.unknown_depth = 0;
        interp.clearCachesRetainingCapacity();
        interp.prng = sandbox.prng;

        // Last, since the result and caches cleared above can keep
        // hash-registered objects alive.
        try pinCapacity(&interp.call_frames, frame_stack_capacity);
        try pinCapacity(&interp.eval_frames, frame_stack_capacity);
        // Inputs that keep many hash-registered objects alive at once grow the
        // registry, which otherwise keeps that capacity after they're freed.
        try heap.registered_hashes.shrinkToFit();
    }

    fn pinCapacity(list: anytype, capacity: usize) !void {
        if (list.capacity == capacity) return;
        var pinned = try @TypeOf(list.*).initCapacity(heap.global_gpa, capacity);
        pinned.appendSliceAssumeCapacity(list.items);
        list.deinit(heap.global_gpa);
        list.* = pinned;
    }
};

pub const FuzzWatchdog = struct {
    io: std.Io,
    timeout_us: i64,
    timeout_abort_us: i64,
    /// Process CPU time when the iteration currently executing started, or
    /// `idle` between iterations.
    running_since_us: std.atomic.Value(i64) = .init(idle),
    interp: *Interp,
    thread: ?std.Thread = null,
    thread_stopped: std.atomic.Value(bool) = .init(false),

    const idle: i64 = -1;

    pub fn startIteration(self: *FuzzWatchdog) void {
        const now_us = std.Io.Clock.now(.cpu_process, self.io).toMicroseconds();
        self.running_since_us.store(now_us, .monotonic);
    }

    pub fn stopIteration(self: *FuzzWatchdog) void {
        self.running_since_us.store(idle, .monotonic);
    }

    pub fn spawn(self: *FuzzWatchdog) !void {
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn threadMain(self: *FuzzWatchdog) Io.Cancelable!void {
        // Timeouts count CPU time rather than wall time, since `zig build --fuzz`
        // runs an instance per core, and an instance waiting on a busy core
        // isn't hanging.
        // Only `.cpu_thread` can single out a thread, and only the calling one, so
        // the iteration's time is the whole process's minus the watchdog's own.
        var observed_since_us: i64 = idle;
        var own_cpu_at_observation_us: i64 = 0;

        while (!self.thread_stopped.load(.monotonic)) {
            self.io.sleep(.fromMicroseconds(50), .awake) catch break; // Poll frequency.

            const running_since_us = self.running_since_us.load(.monotonic);
            if (running_since_us == idle) continue;

            const own_cpu_us = std.Io.Clock.now(.cpu_thread, self.io).toMicroseconds();
            if (running_since_us != observed_since_us) {
                observed_since_us = running_since_us;
                own_cpu_at_observation_us = own_cpu_us;
            }
            const process_cpu_us = std.Io.Clock.now(.cpu_process, self.io).toMicroseconds();
            const elapsed = (process_cpu_us - running_since_us) - (own_cpu_us - own_cpu_at_observation_us);
            if (elapsed < self.timeout_us) continue;

            // The watchdog can be descheduled between the load above and reading
            // the clock, so `elapsed` may extend past the end of the iteration it
            // saw. Seeing the same start time again _after_ reading the clock proves
            // an iteration started then has actually been running for `elapsed`.
            if (self.running_since_us.load(.monotonic) != running_since_us) continue;

            self.interp.stop_executing.store(true, .monotonic);

            // If still running after an additional grace period, this is an unexpected true hang
            // (e.g. tokenizer infinite loop, C FFI deadlock, or un-cancellable loop). Abort so the
            // fuzzer captures the crash and reports the unexpected hang.
            if (elapsed >= self.timeout_abort_us) {
                std.debug.print(
                    "\n[WATCHDOG TIMEOUT] Unexpected hang! Fuzz iteration did not respond to cancellation after {} us of CPU time. Aborting.\n",
                    .{elapsed},
                );
                std.process.abort();
            }
        }
    }

    pub fn deinit(self: *FuzzWatchdog) void {
        if (self.thread) |t| {
            self.thread_stopped.store(true, .monotonic);
            t.join();
            self.thread = null;
        }
    }
};

const InterpreterFuzzContext = struct {
    watchdog: *FuzzWatchdog,
    interp: *Interp,
    sandbox: *const FuzzSandbox,
    fuzz_alloc: *memutil.FuzzAllocator,
};

fn testInterpreterFuzzOne(ctx: *InterpreterFuzzContext, smith: *std.testing.Smith) !void {
    var script_buf: [1024]u8 = undefined;
    const len = smith.slice(&script_buf);
    const script = script_buf[0..len];

    // Read after the script, with no failure as the first weight, so an input
    // too short to also supply a fail index runs without failures.
    const no_failure = std.math.maxInt(u16);
    const fail_after = smith.valueWeighted(u16, &.{
        .value(u16, no_failure, 1024),
        .rangeAtMost(u16, 0, 1023, 1),
    });

    const snapshot = ctx.fuzz_alloc.takeSnapshot();

    if (fail_after != no_failure) ctx.fuzz_alloc.failAfter(fail_after);
    ctx.watchdog.startIteration();
    ctx.sandbox.run(ctx.interp, script) catch {};
    // Ahead of `reset`, so the watchdog stops cancelling before `reset` clears
    // `stop_executing`.
    ctx.watchdog.stopIteration();
    // `reset` has to succeed for the allocation check to mean anything.
    ctx.fuzz_alloc.disarm();

    try ctx.sandbox.reset(ctx.interp);

    try ctx.fuzz_alloc.expectMatchesSnapshot(snapshot);
}

const testing = std.testing;
test "Interp fuzz core script execution" {
    const backing_gpa = std.heap.c_allocator;
    var fuzz_alloc = memutil.FuzzAllocator.init(backing_gpa);

    var interp = try testStartSafe(fuzz_alloc.allocator());
    defer testFinish(&interp);
    var sandbox: FuzzSandbox = try .init(&interp);
    defer sandbox.deinit();

    var watchdog: FuzzWatchdog = .{
        .interp = &interp,
        .io = testing.io,
        .timeout_us = 2_000,
        .timeout_abort_us = 20_000,
    };
    defer watchdog.deinit();
    try watchdog.spawn();

    var ctx: InterpreterFuzzContext = .{
        .watchdog = &watchdog,
        .interp = &interp,
        .sandbox = &sandbox,
        .fuzz_alloc = &fuzz_alloc,
    };

    try std.testing.fuzz(&ctx, testInterpreterFuzzOne, .{
        .corpus = &.{
            "set x 1",
            "expr 1 + 2",
            "if {true} {set x 2}",
            "dict set d a 1",
            "list 1 2 3",
            "string length hello",
        },
    });
}

// On failure these skip `reset`, which is fine, since its only purpose is
// keeping allocations balanced, and `testFinish` frees whatever it would have.
fn expectSandboxResult(sandbox: *const FuzzSandbox, interp: *Interp, expected: []const u8, script: []const u8) !void {
    try sandbox.run(interp, script);
    try std.testing.expectEqualStrings(expected, try interp.result.getString());
    try sandbox.reset(interp);
}

fn expectSandboxError(sandbox: *const FuzzSandbox, interp: *Interp, expected: []const u8, script: []const u8) !void {
    try expectErrorOrOom(error.EvalError, sandbox.run(interp, script));
    try std.testing.expectEqualStrings(expected, try interp.result.getString());
    try sandbox.reset(interp);
}

fn testFuzzSandboxFencesOffTheRootFrame(ta: std.mem.Allocator) !void {
    var interp = try testStartSafe(ta);
    defer testFinish(&interp);
    _ = try interp.testRunScript("set x root");

    var sandbox: FuzzSandbox = try .init(&interp);
    defer sandbox.deinit();

    try expectSandboxError(&sandbox, &interp, "bad level: level 0 is behind a call frame fence", "upvar 1 x y");
    try expectSandboxError(&sandbox, &interp, "bad level: level 0 is behind a call frame fence", "uplevel 1 {set x clobbered}");
    try expectSandboxError(&sandbox, &interp, "bad level: level 0 is behind a call frame fence", "vm frame 0");

    // Frames on the input's side of the fence stay reachable.
    try expectSandboxResult(&sandbox, &interp, "2",
        \\ fn bump {} { upvar 1 y y; incr y }
        \\ set y 1; bump; set y
    );
    try expectSandboxResult(&sandbox, &interp, "inner", "fn f {} { uplevel 1 {set z inner} }; f; set z");

    // Root variables are still readable through the lexical scope, but writes
    // land in the input's own frame.
    try expectSandboxResult(&sandbox, &interp, "root", "set x");
    try expectSandboxResult(&sandbox, &interp, "shadowed", "set x shadowed");
    try interp.testExpectScriptResult("root", "set x");
}

test "fuzz sandbox fences off the root frame" {
    try memutil.checkAllocationFailures(.exhaustive, testFuzzSandboxFencesOffTheRootFrame, .{});
}

fn testFuzzSandboxBalancesAllocations(ta: std.mem.Allocator) !void {
    var fuzz_alloc = memutil.FuzzAllocator.init(ta);
    var interp = try testStartSafe(fuzz_alloc.allocator());
    defer testFinish(&interp);

    var sandbox: FuzzSandbox = try .init(&interp);
    defer sandbox.deinit();

    // `[]` evaluates to the previous result, here the closure `fn` returned, and
    // looking that up as a command name fails. The error message renders the
    // closure as a string, which hash-registers its captured scope.
    const snapshot = fuzz_alloc.takeSnapshot();
    try expectErrorOrOom(error.EvalError, sandbox.run(&interp, "fn n x; []"));
    try sandbox.reset(&interp);
    try fuzz_alloc.expectMatchesSnapshot(snapshot);
}

test "fuzz sandbox balances allocations" {
    try memutil.checkAllocationFailures(.exhaustive, testFuzzSandboxBalancesAllocations, .{});
}

test {
    _ = @import("control_flow.zig");
    _ = @import("strings.zig");
    _ = @import("math.zig");
    _ = @import("eval.zig");
    _ = @import("dict.zig");
    _ = @import("misc.zig");
    _ = @import("variables.zig");
    _ = @import("io.zig");
    _ = @import("list.zig");
    _ = @import("try_catch.zig");
    _ = @import("regex.zig");
    _ = @import("load.zig");
    _ = @import("clock.zig");
    _ = @import("exec.zig");
    _ = @import("binary.zig");
    _ = @import("codec.zig");
    _ = @import("vm.zig");
}
