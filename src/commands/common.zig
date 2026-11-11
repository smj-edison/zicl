const std = @import("std");
pub const assert = std.debug.assert;
pub const Io = std.Io;

pub const heap = @import("../heap.zig");
pub const Value = heap.Value;

pub const memutil = @import("../memutil.zig");
pub const expectErrorOrOom = memutil.expectErrorOrOom;

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
    registerSafeCoreCommands(interp);
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

pub fn resetInterpreter(interp: *Interp) void {
    interp.stop_executing.store(false, .release);
    interp.setEmptyResult();
    interp.stack_trace.swapWithNone();
    interp.pending_error_code.swapWithNone();
    interp.pending_error_during.swapWithNone();
    if (interp.pending_tailcall) |*tailcall| {
        tailcall.deinit();
        interp.pending_tailcall = null;
    }
    interp.call_frames.items[0].variables.clearRetainingCapacity();
    _ = interp.nextCallEpoch();
    interp.return_propagate = .{};
    interp.loop_propagate = 0;
    interp.eval_depth = 0;
    interp.unknown_depth = 0;
    interp.clearCachesRetainingCapacity();
}

pub const FuzzWatchdog = struct {
    io: std.Io,
    timeout_us: i64,
    timeout_abort_us: i64,
    start_time_us: std.atomic.Value(i64),
    stop_time_us: std.atomic.Value(i64),
    interp: *Interp,
    thread: ?std.Thread = null,
    thread_stopped: std.atomic.Value(bool) = .init(false),

    pub fn spawn(self: *FuzzWatchdog) !void {
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn threadMain(self: *FuzzWatchdog) Io.Cancelable!void {
        while (!self.thread_stopped.load(.monotonic)) {
            self.io.sleep(.fromMicroseconds(50), .awake) catch break; // Poll frequency.

            const start_time_us = self.start_time_us.load(.monotonic);
            const stop_time_us = self.stop_time_us.load(.monotonic);

            // Only monitor while an iteration is actively executing.
            if (start_time_us > stop_time_us) {
                const now_us = std.Io.Clock.now(.awake, self.io).toMicroseconds();
                const elapsed = now_us - start_time_us;
                if (elapsed >= self.timeout_us) {
                    self.interp.stop_executing.store(true, .monotonic);

                    // If still running after an additional grace period, this is an unexpected true hang
                    // (e.g. tokenizer infinite loop, C FFI deadlock, or un-cancellable loop). Abort so the
                    // fuzzer captures the crash and reports the unexpected hang.
                    if (elapsed >= self.timeout_abort_us) {
                        std.debug.print(
                            "\n[WATCHDOG TIMEOUT] Unexpected hang! Fuzz iteration did not respond to cancellation after {} us. Aborting.\n",
                            .{elapsed},
                        );
                        std.process.abort();
                    }
                }
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
    counting_alloc: *memutil.CountingAllocator,
};

fn testInterpreterFuzzOne(ctx: *InterpreterFuzzContext, smith: *std.testing.Smith) !void {
    var script_buf: [1024]u8 = undefined;
    const len = smith.slice(&script_buf);
    const script = script_buf[0..len];

    const snapshot = ctx.counting_alloc.takeSnapshot();

    const start_us = std.Io.Clock.now(.awake, ctx.watchdog.io).toMicroseconds();
    ctx.watchdog.start_time_us.store(start_us, .monotonic);
    defer {
        const stop_us = std.Io.Clock.now(.awake, ctx.watchdog.io).toMicroseconds();
        ctx.watchdog.stop_time_us.store(stop_us, .monotonic);
    }

    _ = ctx.interp.testRunScript(script) catch {};

    try ctx.counting_alloc.expectMatchesSnapshot(snapshot);
}

const testing = std.testing;
test "Interp fuzz core script execution" {
    const backing_gpa = std.heap.c_allocator;
    var counting_alloc = memutil.CountingAllocator.init(backing_gpa);

    var interp = try testStartSafe(counting_alloc.allocator());
    var watchdog: FuzzWatchdog = .{
        .interp = &interp,
        .io = testing.io,
        .start_time_us = .init(0),
        .stop_time_us = .init(0),
        .timeout_us = 2_000,
        .timeout_abort_us = 20_000,
    };
    defer watchdog.deinit();
    try watchdog.spawn();

    var ctx: InterpreterFuzzContext = .{
        .watchdog = &watchdog,
        .interp = &interp,
        .counting_alloc = &counting_alloc,
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

test "test all hang inputs" {
    const inputs = @import("../fuzz_hang_inputs.zig").hang_inputs;
    for (inputs, 0..) |script, i| {
        std.debug.print("Testing hang input {d} (len {d})...\n", .{ i, script.len });
        var interp = try testStartSafe(std.testing.allocator);
        _ = interp.testRunScript(script) catch {};
        testFinish(&interp);
        std.debug.print("Done input {d}!\n", .{i});
    }
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
