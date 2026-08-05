const std = @import("std");
const testing = std.testing;

const Tokenizer = @import("../Tokenizer.zig");
const evaltypes = @import("../evaltypes.zig");
const common = @import("common.zig");
const AlwaysCanBeType = common.AlwaysCanBeType;
const assert = common.assert;
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
        }

        try interp.setResultFormatted(
            "bad option \"{s}\": must be -nocommands, -novariables, or -nobackslashes",
            .{try args[arg_index].current().getString()},
        );
        return error.EvalError;
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
    if (current_frame < levels_up) {
        try interp.setResultString("bad level");
        return error.EvalError;
    }
    const target_frame = current_frame - levels_up;

    const script = if (args.len - script_start == 1)
        args[script_start].current().borrow()
    else
        (try objects.List.newFromShimmerables(args[script_start..])).asHead().asValue();
    defer script.release();

    const cache_key = @as(u256, interp.call_frames.items[target_frame].signature.cache_id) ^ try script.getHashNoRegister();
    return interp.evalObjectInner(target_frame, script, cache_key);
}

pub fn evalCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len == 2) {
        try interp.evalObject(args[1].current());
    } else {
        const new = try objects.List.newFromShimmerables(args[1..]);
        defer new.asHead().release();
        try interp.evalObject(new.asHead().asValue());
    }
}

/// [apply]
pub fn applyCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const closure_and_key = try interp.getClosure(args[1].current(), false);

    closure_and_key.closure.asHead().incrRefCount(); // Pin the closure so it doesn't get freed while we evaluate it.
    defer closure_and_key.closure.asHead().release();

    // args[1..] puts the lambda in the name slot (index 0) that callClosure
    // expects, with the actual arguments starting at index 1.
    try Interp.narrowToEvalError(interp.callClosure(closure_and_key.closure.content, closure_and_key.cache_key, args[1..]));
}

pub fn applymethodCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const closure_and_key = try interp.getClosure(args[1].current(), true);

    if (!closure_and_key.closure.content.is_method) {
        try interp.setResultString("[applymethod] called with a function");
        return error.EvalError;
    }

    closure_and_key.closure.asHead().incrRefCount(); // Pin the closure so it doesn't get freed while we evaluate it.
    defer closure_and_key.closure.asHead().release();

    try Interp.narrowToEvalError(interp.callClosure(closure_and_key.closure.content, closure_and_key.cache_key, args[1..]));

    const new_self = args[2].shimmered.asValue().?;
    args[2].shimmered = .none; // It's bad practice to leave a `Shimmerable` as mutated.
    defer new_self.release();
    const method_result = interp.result;

    interp.setResultOwning((try objects.List.new(&.{ new_self, method_result })).asHead().asValue());
}

pub fn tailcallCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (interp.callFrameIdx() == 0) {
        try interp.setResultString("tailcall can only be called from a proc or lambda");
        return error.EvalError;
    } else if (args.len >= 2) {
        // Make sure that if the command doesn't exist, we throw the error here, so
        // it doesn't mysteriously show up at a untracable spot up the call stack.
        _ = interp.getCommand(interp.callFrameIdx() - 1, &args[1], false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EvalError,
        };

        const tailcall_args = try heap.global_gpa.dupe(Shimmerable, args[1..]);
        errdefer heap.global_gpa.free(tailcall_args);

        // `args[1..]` includes the name of the command to run.
        assert(interp.callFrame().tailcall == null);
        interp.callFrame().tailcall = .{
            .args = tailcall_args,
        };
        return error.Tailcall;
    } else {
        try interp.setResultString("no function provided");
        return error.EvalError;
    }
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
        defer scope.asHead().release();
        // As well as reference it.
        const scope_hash_ref = try objects.HashReference.new(scope.asHead());
        errdefer scope_hash_ref.asHead().release();

        const closure_obj = try Object.newObject(evaltypes.Closure);
        errdefer closure_obj.head.freeBacking();
        const closure_content = try heap.global_gpa.create(evaltypes.Closure.Content);
        errdefer heap.global_gpa.destroy(closure_content);
        const arg_names = try objects.List.new(parsed_args.arg_names);
        errdefer arg_names.asHead().release();
        const optional_values =
            if (parsed_args.optional_values.len > 0) try objects.List.new(parsed_args.optional_values) else null;
        errdefer comptime unreachable; // We now take ownership of everything.

        closure_content.* = .{
            .arg_names = .initOwning(arg_names),
            .body = body.current().borrow(),
            .name = if (fn_name) |val| val.current().borrow().asOptional() else .none,
            .scope_hash_ref = .initOwning(scope_hash_ref),
            .required_arity = parsed_args.required_arity,
            .optional_arity = parsed_args.optional_values.len,
            .optional_values = if (optional_values) |values| AlwaysCanBeType(List).initOwning(values) else null,
            .has_args_parameter = parsed_args.has_args_parameter,
            .is_method = mode == .method,
            .cache_id = evaltypes.Closure.closure_cache_id.fetchAdd(1, .monotonic),
        };

        closure_obj.body.content = closure_content;
        break :blk closure_obj.head;
    };
    defer new_closure.release();

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

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "apply", applyCmd, "fn ?arg ...?", 1, null, null);
    try registerCommand(interp, "applymethod", applymethodCmd, "self method ?arg ...?", 1, null, null);
    try registerCommand(interp, "eval", evalCmd, "arg ?arg ...?", 1, null, null);
    try registerCommand(interp, "expr", exprCmd, "expression", 1, 1, null);
    try registerCommand(interp, "fn", fnCmd, "?name? argList body", 2, 3, null);
    try registerCommand(interp, "method", methodCmd, "?name? argList body", 2, 3, null);
    try registerCommand(interp, "source", sourceCmd, "fileName", 1, 1, null);
    try registerCommand(interp, "subst", substCmd, "?options? string", 1, 4, null);
    try registerCommand(interp, "tailcall", tailcallCmd, "command ?arg ...?", 1, null, null);
    try registerCommand(interp, "uplevel", uplevelCmd, "?level? script ?arg ...?", 1, null, null);
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

fn testFnNestsLexicalScopesThreeLevelsDeep(ta: std.mem.Allocator) !void {
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

test "fn nests lexical scopes three levels deep" {
    try memutil.checkAllocationFailures(.exhaustive, testFnNestsLexicalScopesThreeLevelsDeep, .{});
}

fn testFnShadowsALexicalWithALocalOfTheSameName(ta: std.mem.Allocator) !void {
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

test "fn shadows a lexical with a local of the same name" {
    try memutil.checkAllocationFailures(.exhaustive, testFnShadowsALexicalWithALocalOfTheSameName, .{});
}

fn testEvaluationRecyclesArenaScratchInsteadOfAccumulatingIt(ta: std.mem.Allocator) !void {
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

test "evaluation recycles arena scratch instead of accumulating it" {
    try memutil.checkAllocationFailures(.exhaustive, testEvaluationRecyclesArenaScratchInsteadOfAccumulatingIt, .{});
}

fn testArenaScratchDoesNotScaleWithTheWorkAScriptDoes(ta: std.mem.Allocator) !void {
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

test "arena scratch does not scale with the work a script does" {
    try memutil.checkAllocationFailures(.exhaustive, testArenaScratchDoesNotScaleWithTheWorkAScriptDoes, .{});
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
}

test "subst basic" {
    try memutil.checkAllocationFailures(.exhaustive, testSubstBasic, .{});
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
