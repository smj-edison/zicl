//! Tests for task cancelation in `Threaded.zig` (`startTask`, `finishTask`, `cancelId`).
//! They live outside the vendored file so that rebasing it onto a newer `std.Io.Threaded` stays a
//! clean merge.
//!
//! Every test stands up its own `Threaded`. Note that `Threaded.init` installs process-wide
//! `SIGIO`/`SIGPIPE` handlers on top of the ones the test runner's own `std.Io.Threaded`
//! installed; both are the same no-op handler and `deinit` restores, so the overlap is benign.
//!
//! These sit below the object system and allocate nothing on the paths under test, so they use
//! plain `std.testing` rather than `memutil.checkAllocationFailures` or `common.testStart`.
//!
//! A `*Threaded.Thread` points at its thread's threadlocal storage, so every worker here waits for
//! a release flag before unwinding. Otherwise a canceler still holding that pointer would race the
//! worker's exit.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Threaded = @import("Threaded.zig");

/// Long enough that a task stays blocked until canceled, short enough that a test which fails to
/// cancel terminates on its own instead of hanging the suite.
const block_duration: Io.Duration = .fromSeconds(10);

/// Minimal cross-thread signal. `std.Thread.ResetEvent` does not exist in this Zig version and the
/// futex primitives now live on `Io`, so a spin is the least machinery that sequences a test.
const Flag = struct {
    value: std.atomic.Value(bool) = .init(false),

    fn set(flag: *Flag) void {
        flag.value.store(true, .release);
    }

    fn isSet(flag: *Flag) bool {
        return flag.value.load(.acquire);
    }

    fn wait(flag: *Flag) void {
        while (!flag.isSet()) std.Thread.yield() catch {};
    }
};

/// A worker that blocks in one cancelable operation. `run` publishes `thread` and `id`, posts
/// `ready`, blocks, and then waits for `release` before letting its threadlocal storage go.
const Task = struct {
    threaded: *Threaded,
    thread: ?*Threaded.Thread = null,
    id: Threaded.AwaitableId = .null,
    ready: Flag = .{},
    release: Flag = .{},
    canceled: std.atomic.Value(bool) = .init(false),
    /// Shortened by tests that repeat the scenario, so that a cancel which fails to land costs a
    /// brief wait rather than the full timeout.
    duration: Io.Duration = block_duration,

    /// On Linux this sleep goes through `clock_nanosleep` under a `Syscall` guard, so it reaches
    /// .blocked and exercises the `pthread_kill` path rather than only the status CAS.
    fn run(task: *Task) void {
        task.thread = Threaded.initThread();
        defer Threaded.deinitThread();

        task.id = Threaded.startTask();
        task.ready.set();

        if (Io.sleep(task.threaded.io(), task.duration, .awake)) |_| {
            task.canceled.store(false, .release);
        } else |err| switch (err) {
            error.Canceled => task.canceled.store(true, .release),
        }

        Threaded.finishTask();
        task.release.wait();
    }
};

test "cancelId interrupts a blocked task and finishTask returns" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var task: Task = .{ .threaded = &threaded };
    const worker = try std.Thread.spawn(.{}, Task.run, .{&task});
    task.ready.wait();

    Threaded.cancelId(&threaded, task.thread.?, task.id);

    // `cancelId` has returned, so it no longer holds the word. Whether `finishTask` has taken it
    // back yet is a race, so both of the remaining states are correct here.
    switch (task.thread.?.cancelable_task.load(.acquire).cancel) {
        .task_canceling_done, .task_cancelable => {},
        .task_being_canceled => return error.CancelerStillHoldsTask,
    }
    task.release.set();
    worker.join();

    try testing.expect(task.canceled.load(.acquire));
}

/// Runs one short task, then starts a second and blocks in it. Both run on the same thread, so the
/// second id genuinely follows the first: a worker per task would restart the per-thread counter
/// and hand both tasks the same id.
const TwoTaskWorker = struct {
    threaded: *Threaded,
    thread: ?*Threaded.Thread = null,
    retired_id: Threaded.AwaitableId = .null,
    live_id: Threaded.AwaitableId = .null,
    ready: Flag = .{},
    release: Flag = .{},
    canceled: std.atomic.Value(bool) = .init(false),

    fn run(worker: *TwoTaskWorker) void {
        worker.thread = Threaded.initThread();
        defer Threaded.deinitThread();

        worker.retired_id = Threaded.startTask();
        Threaded.finishTask();

        worker.live_id = Threaded.startTask();
        worker.ready.set();

        if (Io.sleep(worker.threaded.io(), block_duration, .awake)) |_| {
            worker.canceled.store(false, .release);
        } else |err| switch (err) {
            error.Canceled => worker.canceled.store(true, .release),
        }

        Threaded.finishTask();
        worker.release.wait();
    }
};

test "an id that already finished cannot start a cancelation" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var worker: TwoTaskWorker = .{ .threaded = &threaded };
    const worker_thread = try std.Thread.spawn(.{}, TwoTaskWorker.run, .{&worker});
    worker.ready.wait();

    // Without this the test passes for the wrong reason: if the two ids collided, the "retired"
    // cancel below would be canceling the live task.
    try testing.expect(worker.retired_id != worker.live_id);

    // `finishTask` retired the first id, and the word now names the second task, so a request for
    // the retired id has nothing to match and leaves the word untouched.
    Threaded.cancelId(&threaded, worker.thread.?, worker.retired_id);
    try testing.expectEqual(
        Threaded.CancelableTask.CancelState.task_cancelable,
        worker.thread.?.cancelable_task.load(.acquire).cancel,
    );

    Threaded.cancelId(&threaded, worker.thread.?, worker.live_id);
    worker.release.set();
    worker_thread.join();

    try testing.expect(worker.canceled.load(.acquire));
}

test "cancelId with a mismatched id cancels nothing" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var task: Task = .{ .threaded = &threaded };
    const worker = try std.Thread.spawn(.{}, Task.run, .{&task});
    task.ready.wait();

    // Ids are minted per thread starting at 1, so the task's own id plus one is an id that has not
    // been issued yet. Aiming a request at it must leave the running task untouched.
    const stale: Threaded.AwaitableId = .fromInt(task.id.toInt() + 1);
    Threaded.cancelId(&threaded, task.thread.?, stale);

    // `ready` is posted before the sleep begins, so the worker may or may not have entered the
    // syscall yet. Either is fine; what must not have happened is a cancel request landing.
    switch (task.thread.?.status.load(.monotonic).cancelation) {
        .none, .blocked, .parked, .blocked_alertable => {},
        .canceling, .canceled, .blocked_canceling, .blocked_alertable_canceling => {
            return error.MismatchedIdCanceledTask;
        },
    }

    Threaded.cancelId(&threaded, task.thread.?, task.id);
    task.release.set();
    worker.join();

    try testing.expect(task.canceled.load(.acquire));
}

test "concurrent cancelId callers are idempotent" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var task: Task = .{ .threaded = &threaded };
    const worker = try std.Thread.spawn(.{}, Task.run, .{&task});
    task.ready.wait();

    const Canceler = struct {
        fn run(t: *Threaded, target: *Task, start: *Flag) void {
            start.wait();
            Threaded.cancelId(t, target.thread.?, target.id);
        }
    };

    // Release both at once so one of them loses the race to start the request.
    var start: Flag = .{};
    const first = try std.Thread.spawn(.{}, Canceler.run, .{ &threaded, &task, &start });
    const second = try std.Thread.spawn(.{}, Canceler.run, .{ &threaded, &task, &start });
    start.set();
    first.join();
    second.join();

    // `cancelId` has returned, so it no longer holds the word. Whether `finishTask` has taken it
    // back yet is a race, so both of the remaining states are correct here.
    switch (task.thread.?.cancelable_task.load(.acquire).cancel) {
        .task_canceling_done, .task_cancelable => {},
        .task_being_canceled => return error.CancelerStillHoldsTask,
    }
    task.release.set();
    worker.join();

    try testing.expect(task.canceled.load(.acquire));
}

/// Hammers a thread with an id that was never issued, one past the live task. Starting a request
/// requires the word to already hold that task id, so every one of these has to lose the exchange
/// and leave the live cancelation request alone. `running` is posted after the first call, since a spammer
/// that has not started yet creates no race at all.
const Spammer = struct {
    threaded: *Threaded,
    target: *Task,
    unissued: Threaded.AwaitableId,
    running: Flag = .{},
    stop: Flag = .{},

    fn run(spammer: *Spammer) void {
        while (!spammer.stop.isSet()) {
            Threaded.cancelId(spammer.threaded, spammer.target.thread.?, spammer.unissued);
            spammer.running.set();
        }
    }
};

test "an id the thread is not running cannot start a cancelation" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // The overlap lasts only as long as one `cancelId` call, so a single collision is unlikely and
    // the scenario has to repeat. The short block keeps a cancel that fails to land cheap: the task
    // simply runs to completion and the count comes up short.
    const iterations = 300;
    var canceled: usize = 0;
    for (0..iterations) |_| {
        var task: Task = .{ .threaded = &threaded, .duration = .fromMilliseconds(20) };
        const worker = try std.Thread.spawn(.{}, Task.run, .{&task});
        task.ready.wait();

        var spammer: Spammer = .{
            .threaded = &threaded,
            .target = &task,
            .unissued = .fromInt(task.id.toInt() + 1),
        };
        const spam_thread = try std.Thread.spawn(.{}, Spammer.run, .{&spammer});
        spammer.running.wait();

        Threaded.cancelId(&threaded, task.thread.?, task.id);
        spammer.stop.set();
        spam_thread.join();

        task.release.set();
        worker.join();
        if (task.canceled.load(.acquire)) canceled += 1;
    }

    try testing.expectEqual(iterations, canceled);
}

/// Runs many short tasks back to back while another thread cancels whichever task it last saw. A
/// request that lands late must cancel its own task or nothing, never the task that follows.
const RacingWorker = struct {
    threaded: *Threaded,
    thread: ?*Threaded.Thread = null,
    iterations: usize,
    ready: Flag = .{},
    finished: Flag = .{},
    release: Flag = .{},
    /// The id currently running, or 0 between tasks.
    live_id: std.atomic.Value(usize) = .init(0),

    fn run(worker: *RacingWorker) void {
        worker.thread = Threaded.initThread();
        defer Threaded.deinitThread();
        worker.ready.set();

        for (0..worker.iterations) |_| {
            const id = Threaded.startTask();
            worker.live_id.store(id.toInt(), .release);

            // Short enough to keep the test quick, long enough that the canceler usually finds the
            // thread genuinely blocked in the syscall rather than between tasks.
            Io.sleep(worker.threaded.io(), .fromMicroseconds(50), .awake) catch |err| switch (err) {
                error.Canceled => {},
            };

            worker.live_id.store(0, .release);
            Threaded.finishTask();
        }

        worker.finished.set();
        worker.release.wait();
    }
};

test "cancelId racing the task boundary never leaks into the next task" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // This is the case a single unacknowledged `pthread_kill` gets wrong: it either misses the
    // signal and hangs, or lands on the following task. Either shows up as a test that does not
    // terminate, so give it the longest run.
    var worker: RacingWorker = .{ .threaded = &threaded, .iterations = 3000 };
    const worker_thread = try std.Thread.spawn(.{}, RacingWorker.run, .{&worker});
    worker.ready.wait();

    while (!worker.finished.isSet()) {
        const observed = worker.live_id.load(.acquire);
        if (observed == 0) continue;
        Threaded.cancelId(&threaded, worker.thread.?, .fromInt(observed));
    }

    // `finished` is posted after the worker's last `finishTask`, and the loop above has stopped
    // issuing cancels, so the word has settled.
    try testing.expectEqual(Threaded.CancelableTask.CancelState.task_cancelable, worker.thread.?.cancelable_task.load(.acquire).cancel);
    worker.release.set();
    worker_thread.join();
}

/// Exercises id minting on a spawned thread, so the test runner's own thread is left without a
/// `Thread.current` that outlives this test.
fn checkIdMinting() !void {
    const thread = Threaded.initThread();
    defer Threaded.deinitThread();

    var previous: Threaded.AwaitableId = .null;
    for (0..64) |_| {
        try testing.expectEqual(null, Threaded.getCurrentId());
        const id = Threaded.startTask();
        try testing.expect(id != .null);
        try testing.expect(id != previous);
        try testing.expectEqual(id, Threaded.AwaitableId.fromInt(id.toInt()));
        try testing.expectEqual(id, Threaded.getCurrentId());
        previous = id;
        Threaded.finishTask();
    }
    try testing.expectEqual(null, Threaded.getCurrentId());

    // Park the counter one short of its maximum and mint across the wrap. This is the only way the
    // skip-zero branch in `CancelableTask.Id.next` is ever executed.
    const Id = Threaded.CancelableTask.Id;
    const IdInt = @typeInfo(Id).@"enum".tag_type;
    thread.task_counter = @enumFromInt(std.math.maxInt(IdInt));
    const wrapped = Threaded.startTask();
    try testing.expect(wrapped != .null);
    try testing.expectEqual(@as(Id, @enumFromInt(1)), thread.task_counter);
    Threaded.finishTask();
}

test "startTask ids are distinct, never null, and skip zero on wrap" {
    const Runner = struct {
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = checkIdMinting();
        }
    };

    var runner: Runner = .{};
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    thread.join();
    try runner.result;
}

test "a second cancelId is dropped once a cancelation has completed" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var task: Task = .{ .threaded = &threaded };
    const worker = try std.Thread.spawn(.{}, Task.run, .{&task});
    task.ready.wait();

    Threaded.cancelId(&threaded, task.thread.?, task.id);

    // Once a cancelation completes the word is either still parked at .task_canceling_done, or the
    // task has taken it back and retired the id. It must never be .task_cancelable while still
    // naming the live task, since that would let a second cancelation claim a task whose
    // cancelation already ran. Phrased as what must not hold, because which of the two permitted
    // states we catch is a race.
    const after = task.thread.?.cancelable_task.load(.acquire);
    if (after.cancel == .task_cancelable and after.id != .null) return error.TaskLeftClaimable;

    // So a second request finds nothing to claim. Re-checking the same invariant is the
    // observable form of that, since a claim could only have succeeded from a word that was
    // .task_cancelable while still naming this task. Comparing against `after` instead would
    // race the worker taking the word back between the two loads.
    Threaded.cancelId(&threaded, task.thread.?, task.id);
    const after_second = task.thread.?.cancelable_task.load(.acquire);
    if (after_second.cancel == .task_cancelable and after_second.id != .null) return error.TaskLeftClaimable;

    task.release.set();
    worker.join();
    try testing.expect(task.canceled.load(.acquire));
}

/// Runs tasks back to back that never block, so task boundaries arrive as fast as they can while a
/// canceler runs alongside. Every other test here puts a sleep inside the task, which spaces the
/// boundaries out by at least that sleep.
///
/// The target is the window after `finishTask` reads .task_cancelable but before it retires the
/// id, which is the only reason that retire is an exchange rather than a store. Measured at 0 to
/// 15 hits per 20000 iterations, so read this as a stress test that sometimes reaches the window
/// rather than as coverage of it: breaking the exchange into a store does not reliably fail here,
/// and the exchange is justified by construction instead.
const NonBlockingWorker = struct {
    thread: ?*Threaded.Thread = null,
    iterations: usize,
    ready: Flag = .{},
    finished: Flag = .{},
    release: Flag = .{},
    live_id: std.atomic.Value(usize) = .init(0),

    fn run(worker: *NonBlockingWorker) void {
        worker.thread = Threaded.initThread();
        defer Threaded.deinitThread();
        worker.ready.set();

        for (0..worker.iterations) |_| {
            const id = Threaded.startTask();
            worker.live_id.store(id.toInt(), .release);
            // Kept live across `finishTask`, unlike `RacingWorker`, so a canceler can still be
            // calling `cancelId` while `finishTask` runs. Clearing it first would close the
            // window this test exists to open.
            Threaded.finishTask();
            worker.live_id.store(0, .release);
        }

        worker.finished.set();
        worker.release.wait();
    }
};

test "a cancelation claiming during finishTask is not erased" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var worker: NonBlockingWorker = .{ .iterations = 20000 };
    const worker_thread = try std.Thread.spawn(.{}, NonBlockingWorker.run, .{&worker});
    worker.ready.wait();

    while (!worker.finished.isSet()) {
        const observed = worker.live_id.load(.acquire);
        if (observed == 0) continue;
        Threaded.cancelId(&threaded, worker.thread.?, .fromInt(observed));
    }

    try testing.expectEqual(
        Threaded.CancelableTask{ .cancel = .task_cancelable, .id = .null },
        worker.thread.?.cancelable_task.load(.acquire),
    );
    worker.release.set();
    worker_thread.join();
}
