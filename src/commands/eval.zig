const std = @import("std");
const testing = std.testing;
const options = @import("options");

const Tokenizer = @import("../Tokenizer.zig");
const evaltypes = @import("../evaltypes.zig");
const common = @import("common.zig");
const heap = common.heap;
const Object = heap.Object;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const List = objects.List;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

pub fn exprCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const result = try interp.evalExpression(args[1].current());
    interp.setResultOwning(result);
}

pub fn substCmd(interp: *Interp, args: []Shimmerable) !void {
    var flags: Tokenizer.SubstFlags = .{
        .command_subst = true,
        .variable_subst = true,
        .escape_subst = true,
    };

    for (1..(args.len - 1)) |arg_index| {
        if (try args[arg_index].current().equalsString("-nocommands")) {
            flags.command_subst = false;
        } else if (try args[arg_index].current().equalsString("-novariables")) {
            flags.variable_subst = false;
        } else if (try args[arg_index].current().equalsString("-nobackslashes")) {
            flags.escape_subst = false;
        } else {
            try interp.setResultFormatted(
                "bad option \"{s}\": must be -nocommands, -novariables, or -nobackslashes",
                .{try args[arg_index].current().getString()},
            );
            return error.EvalError;
        }
    }

    const to_substitute = &args[args.len - 1];
    interp.setResultOwning(try interp.evalSubstitution(to_substitute.current(), flags));
}

/// [uplevel]
pub fn uplevelCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len < 2) return error.WrongUsage;

    var script_start: usize = 1;
    var levels_up: u32 = 1;

    const first_str = try args[1].current().getString();
    if (first_str.len > 0 and (first_str[0] >= '0' and first_str[0] <= '9')) {
        if (interp.getInteger(&args[1])) |level| {
            if (level >= 0) {
                levels_up = @intCast(level);
                script_start = 2;
            } else {
                try interp.setResultString("bad level");
                return error.EvalError;
            }
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try interp.setResultString("bad level");
                return error.EvalError;
            },
        }
    }

    if (args.len - script_start < 1) return error.WrongUsage;

    const current_frame = interp.callFrameIdx();
    const target_frame = interp.getRelativeCallFrame(current_frame, levels_up) orelse {
        try interp.setResultString("bad level");
        return error.EvalError;
    };

    const script = if (args.len - script_start == 1)
        args[script_start].current().takeReference()
    else
        (try objects.List.newFromShimmerables(args[script_start..])).asHead().asValue();
    defer script.dropReference();

    const cache_key = @as(u256, interp.call_frames.items[target_frame].signature.cache_id) ^ try script.getHashNoRegister();
    return interp.evalValueInner(target_frame, script, cache_key);
}

pub fn evalCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len == 2) {
        try interp.evalValue(args[1].current());
    } else {
        const new = try objects.List.newFromShimmerables(args[1..]);
        defer new.asHead().dropReference();
        try interp.evalValue(new.asHead().asValue());
    }
}

/// [apply]
pub fn applyCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var command = interp.getCommandFromValue(&args[1], false) catch |err| switch (err) {
        error.CommandNotFound => return error.EvalError, // Message already set.
        else => return Interp.narrowError(err),
    };
    defer command.deinit();

    // args[1..] puts the lambda in the name slot (index 0) that callClosure
    // expects, with the actual arguments starting at index 1.
    try interp.invokeCommand(&command, args[1..]);
}

pub fn applymethodCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var command = interp.getCommandFromValue(&args[1], true) catch |err| switch (err) {
        error.CommandNotFound => return error.EvalError, // Message already set.
        else => return Interp.narrowError(err),
    };
    defer command.deinit();

    const valid = switch (command) {
        .closure => |closure| closure.closure.content.is_method,
        .letrec => |letrec| letrec.closure.closure.content.is_method,
        .command => false,
    };
    if (!valid) {
        try interp.setResultString("[applymethod] called with a function");
        return error.EvalError;
    }

    defer args[2].discardChanges(); // Make sure the mutated self value never escapes.
    try interp.invokeCommand(&command, args[1..]);

    const new_self = args[2].shimmered.asValue().?;
    const method_result = interp.result;

    interp.setResultOwning((try objects.List.new(&.{ new_self, method_result })).asHead().asValue());
}

pub fn letrecCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum { select, new };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .select, .usage = "scope function", .min_args = 2, .max_args = 2 },
        .{ .variant = .new, .usage = "scope", .min_args = 1, .max_args = 1 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    _ = try interp.getDict(&args[2]);
    const scope_mut = args[2].current().asType(objects.Dictionary).?;
    scope_mut.asHead().makeCrossthread();

    switch (subcommand) {
        .select => {
            const letrec = try interp.wrapError(&det, evaltypes.Letrec.new(&det, scope_mut, args[3].current()));
            interp.setResultOwning(letrec.asHead().asValue());
        },
        .new => {
            // A dumb wrapper: it wraps every key in `scope`, whether it holds a
            // function or plain data, since it has no way to tell the two apart.
            const result = try objects.Dictionary.newWithCapacity(&.{}, scope_mut.items.len);
            errdefer result.asHead().dropReference();

            var iter = scope_mut.table.iterator();
            while (iter.next()) |pair| {
                if (try pair.key_ptr.equals(objects.interned_tilde_parent)) continue;
                const letrec_entry = try interp.wrapError(&det, evaltypes.Letrec.new(&det, scope_mut, pair.key_ptr.*));
                defer letrec_entry.asHead().dropReference();
                try result.put(pair.key_ptr.*, letrec_entry.asHead().asValue());
            }

            interp.setResultOwning(result.asHead().asValue());
        },
    }
}

pub fn tailcallCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (interp.callFrameIdx() == 0) {
        try interp.setResultString("tailcall can only be called from a proc or lambda");
        return error.EvalError;
    } else if (args.len < 2) {
        try interp.setResultString("no function provided");
        return error.EvalError;
    }

    // Method calling requires writing back `self`, but by returning error.Tailcall,
    // the call frame would be destroyed, deleting `self`. Hence, no [tailcall]
    // within a method.
    if (interp.callFrame().signature.is_method) {
        try interp.setResultString("tailcall cannot be used from within a method");
        return error.EvalError;
    }

    // We need to resolve the command now, since we get it from the current scope.
    {
        // Run this in a block, so when we later return error.Tailcall, we don't
        // trigger the `errdefer command.deinit();`.
        var command = interp.getCommand(interp.callFrameIdx(), &args[1], false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EvalError,
        };
        errdefer command.deinit();

        const tailcall_args = try heap.global_gpa.alloc(Shimmerable, args.len - 1);
        for (args[1..], 0..) |*arg, i| {
            tailcall_args[i] = .{ .original = arg.current().takeReference() };
        }

        if (interp.pending_tailcall) |*prev| prev.deinit();
        interp.pending_tailcall = .{ .args = tailcall_args, .command = command };
    }

    return error.Tailcall;
}

/// `closureHelper` is a helper function that implements [fn] and [method] logic. This function
/// parses the closure, captures the scope, and (if provided) sets the function name in the local
/// scope.
fn closureHelper(interp: *Interp, args: []Shimmerable, mode: enum { function, method }) Interp.Error!void {
    const fn_name: ?*Shimmerable, const arglist, const body = blk: {
        if (args.len == 4) {
            break :blk .{ &args[1], &args[2], args[3] };
        } else {
            break :blk .{ null, &args[1], args[2] };
        }
    };

    const new_closure = blk: {
        // Shimmer to list via the interp helper, which handles the case where
        // the handle can't be shimmered in place.
        var det: ErrorDetails = undefined;
        const args_as_list = try interp.wrapError(&det, objects.List.shimmerFrom(&det, arglist));
        var parsed_args: evaltypes.Closure.ParsedArgList = try interp.wrapError(&det, evaltypes.Closure.parseArgList(&det, args_as_list));
        defer parsed_args.deinit();

        // Capture the current scope.
        const scope: *objects.Dictionary = try Interp.narrowToEvalError(interp.captureCurrentScope());
        errdefer scope.asHead().dropReference();
        // As well as reference it.

        const closure_obj = try Object.newObject(evaltypes.Closure);
        errdefer closure_obj.head.freeBacking();
        const closure_content = try heap.global_gpa.create(evaltypes.Closure.Content);
        errdefer heap.global_gpa.destroy(closure_content);
        const arg_names = try objects.List.new(parsed_args.arg_names);
        errdefer arg_names.asHead().dropReference();
        const optional_values =
            if (parsed_args.optional_values.len > 0) try objects.List.new(parsed_args.optional_values) else null;
        errdefer comptime unreachable; // We now take ownership of everything.

        // This makes sure the values never shimmer away from their current representations.
        arg_names.asHead().makeCrossthread();
        scope.asHead().makeCrossthread();
        if (optional_values) |val| val.asHead().makeCrossthread();

        closure_content.* = .{
            .arg_names = arg_names,
            .body = body.current().takeReference(),
            .name = if (fn_name) |val| val.current().takeReference().asOptional() else .none,
            .scope = scope,
            .required_arity = parsed_args.required_arity,
            .optional_arity = parsed_args.optional_values.len,
            .optional_values = optional_values,
            .has_args_parameter = parsed_args.has_args_parameter,
            .is_method = mode == .method,
            .cache_id = evaltypes.Closure.closure_cache_id.fetchAdd(1, .monotonic),
        };

        closure_obj.body.content = closure_content;
        break :blk closure_obj.head;
    };
    defer new_closure.dropReference();

    if (fn_name) |val| {
        try interp.setVariable(val, new_closure.asValue());
        interp.setResult(new_closure.asValue());
    } else {
        interp.setResult(new_closure.asValue());
    }
}

pub fn fnCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return closureHelper(interp, args, .function);
}

pub fn methodCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return closureHelper(interp, args, .method);
}

pub fn sourceCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    try interp.evalFile(try args[1].current().getString());
}

/// [import] -- reads `fileName` and runs it as a module: it gets a call
/// frame of its own (no access to the caller's locals), and the result is a
/// dict of whatever it bound at its own top level (its `set`/`fn`
/// definitions), not its return value. Pair with [dict assign] to pull
/// specific names into the current scope.
pub fn importCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const module = try interp.evalFileAsModule(try args[1].current().getString());
    interp.setResultOwning(module.asHead().asValue());
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "apply", applyCmd, "fn ?arg ...?", 1, null);
    try registerCommand(interp, "applymethod", applymethodCmd, "self method ?arg ...?", 1, null);
    try registerCommand(interp, "eval", evalCmd, "arg ?arg ...?", 1, null);
    try registerCommand(interp, "expr", exprCmd, "expression", 1, 1);
    try registerCommand(interp, "fn", fnCmd, "?name? argList body", 2, 3);
    try registerCommand(interp, "import", importCmd, "fileName", 1, 1);
    try registerCommand(interp, "letrec", letrecCmd, "subcommand ?arg ...?", 1, null);
    try registerCommand(interp, "method", methodCmd, "?name? argList body", 2, 3);
    try registerCommand(interp, "source", sourceCmd, "fileName", 1, 1);
    try registerCommand(interp, "subst", substCmd, "?options? string", 1, 4);
    try registerCommand(interp, "tailcall", tailcallCmd, "command ?arg ...?", 1, null);
    try registerCommand(interp, "uplevel", uplevelCmd, "?level? script ?arg ...?", 1, null);
}

fn testFnNamed(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("30",
        \\ fn add {a b} { + $a $b }
        \\ add 10 20
    );
}

test "fn named" {
    try memutil.checkAllocationFailures(.exhaustive, testFnNamed, .{});
}

fn testFnAnonymous(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("30",
        \\ apply [fn {a b} { + $a $b }] 10 20
    );
}

test "fn anonymous" {
    try memutil.checkAllocationFailures(.exhaustive, testFnAnonymous, .{});
}

fn testFnScopeCapture(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("15",
        \\ set x 10
        \\ fn addx {a} { + $a $x }
        \\ addx 5
    );
}

test "fn scope capture" {
    try memutil.checkAllocationFailures(.exhaustive, testFnScopeCapture, .{});
}

fn testFnNestedClosureScope(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `bar` is returned from `foo` and captures both `inner` and `outer`.
    try interp.testExpectScriptResult("15",
        \\ set outer 5
        \\ fn foo {} {
        \\   set inner 10
        \\   fn bar {} { + $inner $outer }
        \\   return $bar
        \\ }
        \\ set bar [foo]
        \\ bar
    );
}

test "fn nested closure scope" {
    try memutil.checkAllocationFailures(.exhaustive, testFnNestedClosureScope, .{});
}

fn testFnDeeplyNestedClosure(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Every nesting level adds a `~parent` link, so this fails if capturing a
    // scope drops the link or orders it inconsistently.
    try interp.testExpectScriptResult("111",
        \\ set a 1
        \\ fn one {} {
        \\   set b 10
        \\   fn two {} {
        \\     set c 100
        \\     fn three {} { + $a [+ $b $c] }
        \\     return $three
        \\   }
        \\   return [two]
        \\ }
        \\ set three [one]
        \\ three
    );
}

test "fn deeply nested closure" {
    try memutil.checkAllocationFailures(.exhaustive, testFnDeeplyNestedClosure, .{});
}

fn testFnShadowsCorrectly(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("inner",
        \\ set x outer
        \\ fn shadow {} { set x inner; return $x }
        \\ shadow
    );

    // Shadowing must not disturb the captured scope it shadows.
    try interp.testExpectScriptResult("outer",
        \\ set x outer
        \\ fn shadow {} { set x inner; return $x }
        \\ shadow
        \\ return $x
    );
}

test "fn shadows correctly" {
    try memutil.checkAllocationFailures(.exhaustive, testFnShadowsCorrectly, .{});
}

fn testLetrec(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Self recursion.
    try interp.testExpectScriptResult("55",
        \\ fn scope::fibonacci {n} {
        \\     if {$n <= 1} { return $n }
        \\     return [+ [fibonacci [- $n 1]] [fibonacci [- $n 2]]]
        \\ }
        \\ set fibonacci [letrec select $scope fibonacci]
        \\ fibonacci 10
    );
}

test "letrec" {
    try memutil.checkAllocationFailures(.exhaustive, testLetrec, .{});
}

fn testLetrecMutualRecursion(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Mutual recursion: two closures in the same letrec scope calling each other.
    try interp.testExpectScriptResult("true",
        \\ fn scope::is_even {n} {
        \\     if {$n == 0} { return true }
        \\     return [is_odd [- $n 1]]
        \\ }
        \\ fn scope::is_odd {n} {
        \\     if {$n == 0} { return false }
        \\     return [is_even [- $n 1]]
        \\ }
        \\ set is_even [letrec select $scope is_even]
        \\ is_even 10
    );
}

test "letrec mutual recursion" {
    try memutil.checkAllocationFailures(.exhaustive, testLetrecMutualRecursion, .{});
}

fn testLetrecMethod(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A letrec-selected value resolves through `getCommandFromValue`'s `.letrec`
    // branch, not its `.closure` branch. `[applymethod]` validates methods
    // through both branches separately, so this exercises the `.letrec` one:
    // does `self` write back correctly when the method was reached via letrec?
    try interp.testExpectScriptResult("count 8",
        \\ method scope::bump {self n} {
        \\     dict set self count [+ [dict get $self count] $n]
        \\     return done
        \\ }
        \\ set bump [letrec select $scope bump]
        \\ lindex [applymethod $bump {count 5} 3] 0
    );
}

test "letrec method" {
    try memutil.checkAllocationFailures(.exhaustive, testLetrecMethod, .{});
}

fn testLetrecNew(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `[letrec new $scope]` builds the whole self-dispatch table in one call,
    // instead of a `letrec select` per peer.
    try interp.testExpectScriptResult("ping pong ping",
        \\ method scope::ping {self n} {
        \\     set self::path [concat $self::path ping]
        \\     if {$n <= 0} { return $self::path }
        \\     return [self::pong [- $n 1]]
        \\ }
        \\ method scope::pong {self n} {
        \\     set self::path [concat $self::path pong]
        \\     if {$n <= 0} { return $self::path }
        \\     return [self::ping [- $n 1]]
        \\ }
        \\ set self [dict merge {path {}} [letrec new $scope]]
        \\ self::ping 2
    );
}

test "letrec new" {
    try memutil.checkAllocationFailures(.exhaustive, testLetrecNew, .{});
}

fn testLetrecSelfDictSugar(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("ping pong ping",
        \\ method scope::ping {self n} {
        \\     set self::path [concat $self::path ping]
        \\     if {$n <= 0} { return $self::path }
        \\     return [self::pong [- $n 1]]
        \\ }
        \\ method scope::pong {self n} {
        \\     set self::path [concat $self::path pong]
        \\     if {$n <= 0} { return $self::path }
        \\     return [self::ping [- $n 1]]
        \\ }
        \\ set ping [letrec select $scope ping]
        \\ set pong [letrec select $scope pong]
        \\ set self [dict create path {} ping $ping pong $pong]
        \\ self::ping 2
    );
}

test "letrec self dict sugar" {
    try memutil.checkAllocationFailures(.exhaustive, testLetrecSelfDictSugar, .{});
}

fn testTailcallBasicFactorial(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("3628800",
        \\ fn scope::fac {x {val 1}} {
        \\   if {$x <= 2} {
        \\     expr {$x * $val}
        \\   } else {
        \\     tailcall fac [expr {$x - 1}] [expr {$x * $val}]
        \\   }
        \\ }
        \\ set fac [letrec select $scope fac]
        \\ fac 10
    );
}

test "tailcall basic factorial" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallBasicFactorial, .{});
}

fn testTailcallInTry(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("13",
        \\ set x 0
        \\ fn scope::a {} { upvar x x; incr x }
        \\ fn scope::b {} { upvar x x; incr x 4; try { tailcall a } finally { incr x 8 } }
        \\ set b [letrec select $scope b]
        \\ b
        \\ set x
    );
}

test "tailcall in try" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallInTry, .{});
}

fn testTailcallDoesReturn(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("5",
        \\ set x 0
        \\ fn scope::a {} { upvar x x; incr x }
        \\ fn scope::b {} { upvar x x; incr x 4; tailcall a; incr x 8 }
        \\ set b [letrec select $scope b]
        \\ b
        \\ set x
    );
}

test "tailcall does return" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallDoesReturn, .{});
}

fn testUplevelThroughAnIntermediateCall(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("hello",
        \\ fn inner {} { uplevel { set valueInOuterScope } }
        \\ fn outer {} { uplevel { inner } }
        \\ set valueInOuterScope "hello"
        \\ outer
    );
}

test "uplevel through an intermediate call" {
    try memutil.checkAllocationFailures(.exhaustive, testUplevelThroughAnIntermediateCall, .{});
}

fn testTailcallUplevelInteraction(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("c c",
        \\ fn c {} { return c }
        \\ fn b {} {
        \\   lappend result [uplevel 1 a c]
        \\   lappend result [uplevel 1 a c]
        \\ }
        \\ fn a {cmd} { tailcall $cmd }
        \\ a b
    );
}

test "tailcall uplevel interaction" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallUplevelInteraction, .{});
}

fn testTailcallPassesThroughReturn(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("ok",
        \\ fn a {script} {
        \\   tailcall foreach i {1 2 3} $script
        \\ }
        \\ fn b {} {
        \\   a {return ok}
        \\   return bad
        \\ }
        \\ b
    );
}

test "tailcall passes through return" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallPassesThroughReturn, .{});
}

test "tailcall large number of invocations" {
    // Not an allocation-failure test; the 3000-deep tailcall chain is just
    // slow, and this option is the build's opt-in for slow tests.
    if (!options.full_oom_testing) return;

    const ta = std.testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("1",
        \\ fn scope::a {n} {
        \\   if {$n == 0} { return 1 }
        \\   incr n -1
        \\   tailcall a $n
        \\ }
        \\ set a [letrec select $scope a]
        \\ a 3000
    );
}

fn testTailcallThroughUplevel(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("1",
        \\ fn d {} { return [info level] }
        \\ fn c {} { tailcall d }
        \\ fn b {} { uplevel 1 c }
        \\ fn a {} { tailcall b }
        \\ a
    );
}

test "tailcall through uplevel" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallThroughUplevel, .{});
}

fn testTailcallChained(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("1",
        \\ fn c {} { return [info level] }
        \\ fn b {} { tailcall tailcall c }
        \\ fn a {} { b }
        \\ a
    );
}

test "tailcall chained" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallChained, .{});
}

fn testTailcallUplevel(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("2",
        \\ fn c {} { return [info level] }
        \\ fn b {} { uplevel 1 tailcall c }
        \\ fn a {} { b }
        \\ a
    );
}

test "tailcall uplevel" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallUplevel, .{});
}

fn testTailcallErrorStackTracksReplacementArgs(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true false",
        \\ fn b {z} { error boom }
        \\ fn a {x} { tailcall b REPLACEMENT_ARG }
        \\ catch { a ORIGINAL_ARG } msg opts
        \\ set stack [dict get $opts -errorstack]
        \\ list [string match {*REPLACEMENT_ARG*} $stack] [string match {*ORIGINAL_ARG*} $stack]
    );
}

test "tailcall error stack tracks replacement args" {
    try memutil.checkAllocationFailures(.exhaustive, testTailcallErrorStackTracksReplacementArgs, .{});
}

test "heap arena recycles" {
    const ta = std.testing.allocator;

    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Every `$i` interpolation stringifies an inline integer into the arena, and
    // every command allocates its argument array there, so this loop is the
    // shape that used to grow without bound.
    const loop =
        \\ set total 0
        \\ for {set i 0} {$i < 40} {incr i} {
        \\   set label "value $i"
        \\   set total [+ $total $i]
        \\ }
        \\ return $total
    ;

    // Warm up first: the arena has to reach its steady-state chunk count before
    // the comparison means anything, since early rounds legitimately allocate.
    try interp.testExpectScriptResult("780", loop);
    const warmed = heap.local_arena_instance.queryCapacity();

    // Far more work than the warmup. Without a rewind this grows every round.
    for (0..20) |_| try interp.testExpectScriptResult("780", loop);

    try std.testing.expectEqual(warmed, heap.local_arena_instance.queryCapacity());
}

test "arena scratch does not scale with the work a script does" {
    const ta = std.testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A loop reclaims per iteration, since its body is its own evaluation.
    try interp.testExpectScriptResult("", "for {set i 0} {$i < 10} {incr i} { set s \"v $i\" }");
    const small_loop = heap.local_arena_instance.queryCapacity();
    try interp.testExpectScriptResult("", "for {set i 0} {$i < 400} {incr i} { set s \"v $i\" }");
    try std.testing.expectEqual(small_loop, heap.local_arena_instance.queryCapacity());

    // A long flat script is the case the two reset points differ on: it is one
    // evaluation, so only the per-command reset keeps it from accumulating every
    // command's argument array until the script ends.
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(heap.global_gpa);
    for (0..400) |n| {
        var line: [64]u8 = undefined;
        try flat.appendSlice(heap.global_gpa, try std.fmt.bufPrint(&line, "set v{} {}\n", .{ n, n }));
    }
    _ = try interp.testRunScript(flat.items);
    try std.testing.expectEqual(small_loop, heap.local_arena_instance.queryCapacity());
}

fn testSubstReportsAParseErrorWithoutFaulting(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try memutil.expectErrorOrOom(error.EvalError, interp.testRunScript("subst {[}"));
}

test "subst reports a parse error without faulting" {
    try memutil.checkAllocationFailures(.exhaustive, testSubstReportsAParseErrorWithoutFaulting, .{});
}

fn testSubstBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("$x", "subst {\\$x}");
    try interp.testExpectScriptError(error.EvalError,
        \\wrong # args: should be "subst ?options? string"
    , "subst");
    try interp.testExpectScriptError(error.EvalError,
        \\bad option "a": must be -nocommands, -novariables, or -nobackslashes
    , "subst a b c");

    // The valid options are accepted (not just rejected-as-bad), and each
    // actually suppresses its own kind of substitution while leaving the
    // others alone.
    try interp.testExpectScriptResult("v", "set x v; subst {$x}");
    try interp.testExpectScriptResult("v", "set x v; subst -nocommands {$x}");
    try interp.testExpectScriptResult("$x", "set x v; subst -novariables {$x}");
    try interp.testExpectScriptResult("[set x]", "set x v; subst -nocommands {[set x]}");
    try interp.testExpectScriptResult("v", "set x v; subst -novariables {[set x]}");
    // With backslashes off the `\` stays literal, but `$x` still substitutes.
    try interp.testExpectScriptResult("\\v", "set x v; subst -nobackslashes {\\$x}");
    // Several options at once.
    try interp.testExpectScriptResult("$x[set x]", "set x v; subst -nocommands -novariables {$x[set x]}");
}

test "subst basic" {
    try memutil.checkAllocationFailures(.exhaustive, testSubstBasic, .{});
}

fn testExpressionSugar(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("2", "return $(1 + 1)");
    try interp.testExpectScriptResult("7", "set x 3; return $($x * 2 + 1)");

    // Ends at the balancing paren, not the first one.
    try interp.testExpectScriptResult("9", "return $((1 + 2) * 3)");

    // It substitutes like any other word.
    try interp.testExpectScriptResult("a2b", "return a$(1 + 1)b");
    try interp.testExpectScriptResult("4", "return $([+ 1 1] * 2)");
    try interp.testExpectScriptResult("2", "return \"$(1 + 1)\"");
    try interp.testExpectScriptResult("$(1 + 1)", "return {$(1 + 1)}");

    // Nested in an expression it's just grouping.
    try interp.testExpectScriptResult("8", "return [expr {$(1 + 3) * 2}]");
    try interp.testExpectScriptResult("8", "return [expr {2 * $(1 + 3)}]");
    try interp.testExpectScriptResult("6", "return $($(1 + 1) * 3)");
}

test "expression sugar" {
    try memutil.checkAllocationFailures(.exhaustive, testExpressionSugar, .{});
}

fn testExpressionSugarDoesNotCaptureDictSugar(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // After a name the '(' is ordinary text, so this is `foo` followed by "(bar)".
    try interp.testExpectScriptResult("1(bar)", "set foo 1; return $foo(bar)");
}

test "expression sugar does not capture dict sugar" {
    try memutil.checkAllocationFailures(.exhaustive, testExpressionSugarDoesNotCaptureDictSugar, .{});
}

fn testExpressionSugarErrors(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError, "unmatched \"(\"", "return $(1 + 1");
    try interp.testExpectScriptError(error.EvalError, "unmatched \"(\"", "return $(");

    // Scans to end of input, then reports against the '(' rather than whatever
    // it swallowed on the way.
    try interp.testExpectScriptError(error.EvalError, "unmatched \"(\"",
        \\ set x $(1 + 1
        \\ puts hello
    );

    try memutil.expectErrorOrOom(error.EvalError, interp.testRunScript("return $(1 +)"));

    // Empty is an error, not the empty string. Message is pinned in `expr_parse.zig`.
    try memutil.expectErrorOrOom(error.EvalError, interp.testRunScript("return $()"));
    try memutil.expectErrorOrOom(error.EvalError, interp.testRunScript("return [expr {}]"));
}

test "expression sugar errors" {
    try memutil.checkAllocationFailures(.exhaustive, testExpressionSugarErrors, .{});
}

fn testTernaryPrecedence(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // The condition is the whole comparison, not just its right operand.
    try interp.testExpectScriptResult("-Wall",
        \\ set os linux
        \\ return [expr {$os eq "linux" ? {-Wall} : {}}]
    );
    try interp.testExpectScriptResult("", "set os mac; return [expr {$os eq \"linux\" ? {-Wall} : {}}]");
    try interp.testExpectScriptResult("yes", "return [expr {1 + 1 == 2 ? \"yes\" : \"no\"}]");
}

test "ternary precedence" {
    try memutil.checkAllocationFailures(.exhaustive, testTernaryPrecedence, .{});
}

fn testParsing(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Make sure we handle "character after close brace" correctly. It's fine for
    // a bracket to be after a brace in a script context.
    try interp.testExpectScriptResult("2",
        \\ set x [expr {1 + 1}]
        \\ set x
    );

    // It should also work with argument expansion.
    try interp.testExpectScriptResult("3",
        \\ set items {1 2}
        \\ set x [+ {*}$items]
        \\ set x
    );

    try interp.testExpectScriptResult("hello world",
        \\ set x "hello world"
        \\ # multiple
        \\
        \\ # separated
        \\
        \\ # comments
        \\ set x
    );
}

test "parsing" {
    try memutil.checkAllocationFailures(.exhaustive, testParsing, .{});
}

fn testFnOptionalArgs(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    _ = try interp.testRunScript("fn greet {a {b 3}} { + $a $b }");
    try interp.testExpectScriptResult("3", "greet 0");
    try interp.testExpectScriptResult("7", "greet 3 4");
}

test "fn optional args" {
    try memutil.checkAllocationFailures(.exhaustive, testFnOptionalArgs, .{});
}

fn testFnVarargs(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("10 20 30",
        \\ fn collect {args} { set args }
        \\ collect 10 20 30
    );
}

test "fn varargs" {
    try memutil.checkAllocationFailures(.exhaustive, testFnVarargs, .{});
}

fn testFnInDict(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Exercises the path where a closure lives inside a dict and is retrieved
    // back as a .closure-tagged object, then dispatched.
    try interp.testExpectScriptResult("7",
        \\ fn add {a b} { + $a $b }
        \\ set ops::add $add
        \\ ops::add 3 4
    );
}

test "fn in dict" {
    try memutil.checkAllocationFailures(.exhaustive, testFnInDict, .{});
}

fn testFnParsing(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A manually-constructed fn string exercises parseClosure directly, since
    // there is no .closure tag to shortcut through.
    try interp.testExpectScriptResult("30",
        \\ set foo "fn impl {{a b} {+ \$a \$b}} scope [ref { + {nativefn +}}]"
        \\ foo 10 20
    );
}

test "fn parsing" {
    try memutil.checkAllocationFailures(.exhaustive, testFnParsing, .{});
}

fn testMethodAsFn(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError,
        \\method "greet" cannot be invoked as function
    ,
        \\ method greet {self} { puts "hello" }
        \\ greet
    );
}

test "method as fn" {
    try memutil.checkAllocationFailures(.exhaustive, testMethodAsFn, .{});
}

fn testMethodAnonymousViaApplymethod(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("{counter 8} 8",
        \\ set method [method {self x} {
        \\   incr self::counter $x
        \\   return $self::counter
        \\ }]
        \\ applymethod $method {counter 5} 3
    );
}

test "method anonymous via applymethod" {
    try memutil.checkAllocationFailures(.exhaustive, testMethodAnonymousViaApplymethod, .{});
}

fn testMethodArbitrarySelfName(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("fido",
        \\ set Dog {name fido}
        \\ method Dog::getName {this} { return $this::name }
        \\ Dog::getName
    );
}

test "method arbitrary self name" {
    try memutil.checkAllocationFailures(.exhaustive, testMethodArbitrarySelfName, .{});
}

fn testMethodUpdatesSelf(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("rex",
        \\ set doggo {name fido}
        \\ method doggo::rename {self newName} {
        \\   set self::name $newName
        \\ }
        \\ doggo::rename rex
        \\ dict get $doggo name
    );
}

test "method updates self" {
    try memutil.checkAllocationFailures(.exhaustive, testMethodUpdatesSelf, .{});
}

fn testMethodParseableByApplymethod(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("{x 5} 10",
        \\ set method "method impl {{self y} {+ \$self::x \$y}} scope [ref {+ {nativefn +}}]"
        \\ applymethod $method {x 5} 5
    );
}

test "method parseable by applymethod" {
    try memutil.checkAllocationFailures(.exhaustive, testMethodParseableByApplymethod, .{});
}

fn testMethodLexicalScopeCapture(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("55",
        \\ set multiplier 5
        \\ set scoreboard {base 5}
        \\ method scoreboard::score {self scored} { + $self::base [* $scored $multiplier] }
        \\ scoreboard::score 10
    );
}

test "method lexical scope capture" {
    try memutil.checkAllocationFailures(.exhaustive, testMethodLexicalScopeCapture, .{});
}

fn testMethodInNestedObject(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("15",
        \\ set inner {a 5}
        \\ set outer [dict create inner $inner b 10]
        \\ method outer::inner::frobnicate {self x} {
        \\   return [+ $self::a $x]
        \\ }
        \\ outer::inner::frobnicate 10
    );
}

test "method in nested object" {
    try memutil.checkAllocationFailures(.exhaustive, testMethodInNestedObject, .{});
}

test "method object copying" {
    // This test makes sure that duplicated objects remain immutable.

    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("fido",
        \\ set Dog::rename [method {self newName} {
        \\   dict set self name $newName
        \\ }]
        \\ set doggo [dict merge $Dog {name fido}]
        \\ set doggoClone $doggo
        \\ doggo::rename rex
        \\ dict get $doggoClone name
    );
}

/// Get the full stack trace as a Tcl list string.
fn traceString(interp: *Interp) ![]const u8 {
    const trace = interp.stack_trace.asValue() orelse return error.NoStackTrace;
    return try trace.getString();
}

fn testApplyNamedClosure(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("30",
        \\ fn add {a b} { + $a $b }
        \\ apply $add 10 20
    );
}

test "apply named closure" {
    try memutil.checkAllocationFailures(.exhaustive, testApplyNamedClosure, .{});
}

fn testApplyAnonymousClosure(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("hello world",
        \\ apply [fn {a b} { append a " " $b }] hello world
    );
}

test "apply anonymous closure" {
    try memutil.checkAllocationFailures(.exhaustive, testApplyAnonymousClosure, .{});
}

fn testStackTraceInGlobalFrame(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    const script =
        \\ set x 1
        \\ set y 2
        \\ / 1 0
    ;
    try interp.testExpectScriptError(error.EvalError, "division by zero", script);
    try testing.expectEqualStrings("{} {} 3 {/ 1 0}", try traceString(&interp));
}

test "stack trace in global frame" {
    try memutil.checkAllocationFailures(.exhaustive, testStackTraceInGlobalFrame, .{});
}

fn testStackTraceInNestedClosure(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    const script =
        \\ fn bad {} {
        \\   / 1 0
        \\ }
        \\ bad
    ;
    try interp.testExpectScriptError(error.EvalError, "division by zero", script);
    try testing.expectEqualStrings("bad {} 2 {/ 1 0} {} {} 4 bad", try traceString(&interp));
}

test "stack trace in nested closure" {
    try memutil.checkAllocationFailures(.exhaustive, testStackTraceInNestedClosure, .{});
}

fn testStackTraceInCommandSubstitution(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Both the command-substitution eval frame and the outer eval frame share the same call
    // frame (global), so dedup collapses them to one trace entry. That entry's line comes
    // from source_info on the [/ 1 0] token, which points to where the substitution appears
    // in the outer script — line 2 — even though / 1 0 is line 1 of the inner script.
    const script =
        \\ set x 1
        \\ puts [/ 1 0]
    ;
    try interp.testExpectScriptError(error.EvalError, "division by zero", script);
    try testing.expectEqualStrings("{} {} 2 {/ 1 0}", try traceString(&interp));
}

test "stack trace in command substitution" {
    try memutil.checkAllocationFailures(.exhaustive, testStackTraceInCommandSubstitution, .{});
}

fn testStackTraceLineNumberCorrectDedup(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // foo and bar have identical body text. Each closure has a unique cache_id, so each
    // body gets its own parsed_scripts entry — no sharing. The absolute line for each
    // must be correct, coming from source_info.line_no on the body Handle.
    //
    // foo's { is on line 1 → / 1 0 at relative line 2 → absolute line 2.
    // bar's { is on line 4 → / 1 0 at relative line 2 → absolute line 5.
    const script_foo =
        \\ fn foo {} {
        \\   / 1 0
        \\ }
        \\ fn bar {} {
        \\   / 1 0
        \\ }
        \\ foo
    ;
    const count_before_foo = interp.parsed_scripts.mapping.count();
    try interp.testExpectScriptError(error.EvalError, "division by zero", script_foo);
    try testing.expectEqual(count_before_foo + 2, interp.parsed_scripts.mapping.count());
    try testing.expectEqualStrings("foo {} 2 {/ 1 0} {} {} 7 foo", try traceString(&interp));

    const script_bar =
        \\ fn foo {} {
        \\   / 1 0
        \\ }
        \\ fn bar {} {
        \\   / 1 0
        \\ }
        \\ bar
    ;
    const count_before_bar = interp.parsed_scripts.mapping.count();
    try interp.testExpectScriptError(error.EvalError, "division by zero", script_bar);
    // bar has a distinct cache_id from foo, so it gets its own parsed_scripts entry even
    // though the body text is identical -- the ParsedScript is NOT shared.
    try testing.expectEqual(count_before_bar + 2, interp.parsed_scripts.mapping.count());
    try testing.expectEqualStrings("bar {} 5 {/ 1 0} {} {} 7 bar", try traceString(&interp));
}

test "stack trace line number correct dedup" {
    try memutil.checkAllocationFailures(.exhaustive, testStackTraceLineNumberCorrectDedup, .{});
}

fn testUnknown(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult(
        "foo bar",
        \\ fn unknown {args} { return $args }
        \\ badfunction foo bar
        ,
    );
}

test "unknown" {
    try memutil.checkAllocationFailures(.exhaustive, testUnknown, .{});
}

fn testArgExpansion(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult(
        "bar baz",
        \\ fn foo {args} { return $args }
        \\ foo bar baz
        ,
    );
}

test "arg expansion" {
    try memutil.checkAllocationFailures(.exhaustive, testArgExpansion, .{});
}

fn testExprInNi(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `in`/`ni` match against list *elements*, not substrings of the
    // right-hand side's raw string form. "p" is a substring of "colorMap"
    // but not an element of the one-item list {colorMap}.
    try interp.testExpectScriptResult("false", "expr {\"p\" in {colorMap}}");
    try interp.testExpectScriptResult("false", "expr {\"o\" in {colorMap}}");
    try interp.testExpectScriptResult("true", "expr {\"colorMap\" in {colorMap}}");
    try interp.testExpectScriptResult("true", "expr {\"b\" in {a b c}}");
    try interp.testExpectScriptResult("false", "expr {\"z\" in {a b c}}");
    try interp.testExpectScriptResult("true", "expr {\"z\" ni {a b c}}");
    try interp.testExpectScriptResult("false", "expr {\"b\" ni {a b c}}");
}

test "expr in/ni match list elements, not substrings" {
    try memutil.checkAllocationFailures(.exhaustive, testExprInNi, .{});
}

fn testExprInterpolatedString(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A quoted string inside expr can contain $var substitutions, same as
    // a quoted string anywhere else -- `nextExpressionToken` must resume
    // scanning the same string (not start a new one, and not misparse the
    // resumed literal text as operators) after each one.
    try interp.testExpectScriptResult("bar", "set foo bar; expr {\"$foo\"}");
    try interp.testExpectScriptResult("prebar", "set foo bar; expr {\"pre$foo\"}");
    try interp.testExpectScriptResult("bar post", "set foo bar; expr {\"$foo post\"}");
    try interp.testExpectScriptResult("bar/mid/bar", "set foo bar; expr {\"$foo/mid/$foo\"}");
    try interp.testExpectScriptResult("literal, no vars", "expr {\"literal, no vars\"}");
    try interp.testExpectScriptResult("", "expr {\"\"}");

    // Dict-sugar variable names (containing `::`) inside an interpolated
    // expr string -- the original failing case this was found from.
    try interp.testExpectScriptResult(
        "/home/x/y/bar",
        "set foo bar; set d [dict create HOME /home/x]; expr {\"$d::HOME/y/$foo\"}",
    );

    // The false branch of a ternary is itself an interpolated string.
    try interp.testExpectScriptResult(
        "elsebar",
        "set foo bar; expr {1 == 2 ? \"then\" : \"else$foo\"}",
    );

    // Escapes are processed alongside the substitution.
    try interp.testExpectScriptResult("bar\nbar", "set foo bar; expr {\"$foo\\n$foo\"}");

    // [cmd] substitution works inside a quoted expr string too.
    try interp.testExpectScriptResult("cmd:bar:end", "set foo bar; expr {\"cmd:[set foo]:end\"}");
}

test "expr quoted strings support $var and [cmd] interpolation" {
    try memutil.checkAllocationFailures(.exhaustive, testExprInterpolatedString, .{});
}

fn testExprComparisonIsStrict(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // In normal Tcl, `"hello" == "hello"` is a valid expr script, since
    // it falls back to string comparison if both sides can't be parsed
    // as numbers. I don't like implicit casting, so I've made `==` strict.
    // Use `eq` for string comparison instead.
    try interp.testExpectScriptError(error.EvalError,
        \\error occured when evaluating expression "abc" == "abc": expected float but got "abc", parse tree: (abc .equal abc)
    , "expr {\"abc\" == \"abc\"}");
    try interp.testExpectScriptResult("true", "expr {\"abc\" eq \"abc\"}");
    try interp.testExpectScriptResult("false", "expr {\"abc\" eq \"def\"}");

    // Booleans are not numbers, but `==`/`!=` compare two booleans. Only
    // when *both* sides are booleans, though: a boolean against a number or
    // string keeps hitting the strict failure.
    try interp.testExpectScriptResult("true", "expr {true == true}");
    try interp.testExpectScriptResult("false", "expr {true == false}");
    try interp.testExpectScriptResult("true", "expr {true != false}");

    // String operands shimmer to booleans for `==`/`!=`, the same way
    // numeric strings shimmer to numbers.
    try interp.testExpectScriptResult("true", "expr {\"true\" == true}");
    try interp.testExpectScriptResult("true", "expr {\"true\" != \"false\"}");
    try interp.testExpectScriptResult("true", "set x false; expr {$x == false}");

    // Ordering operators never accept booleans, not even two of them.
    try interp.testExpectScriptError(error.EvalError,
        \\error occured when evaluating expression true < false: expected float but got "true", parse tree: (true .less_than false)
    , "expr {true < false}");

    // Mixed boolean/non-boolean comparisons still fail strictly.
    try interp.testExpectScriptError(error.EvalError,
        \\error occured when evaluating expression true == 1: expected float but got "true", parse tree: (true .equal 1)
    , "expr {true == 1}");
    try interp.testExpectScriptError(error.EvalError,
        \\error occured when evaluating expression 1 == true: expected float but got "true", parse tree: (1 .equal true)
    , "expr {1 == true}");
    try interp.testExpectScriptError(error.EvalError,
        \\error occured when evaluating expression "abc" == true: expected float but got "abc", parse tree: (abc .equal true)
    , "expr {\"abc\" == true}");

    // Still numeric when both sides genuinely are numbers.
    try interp.testExpectScriptResult("true", "expr {1 == 1.0}");
    try interp.testExpectScriptResult("true", "expr {2 > 1}");
}

test "expr comparisons stay strictly numeric, no implicit casting" {
    try memutil.checkAllocationFailures(.exhaustive, testExprComparisonIsStrict, .{});
}
