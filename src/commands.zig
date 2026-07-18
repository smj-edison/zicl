const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;

const Tokenizer = @import("Tokenizer.zig");
const strutil = @import("strutil.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Shimmerable = objutil.Shimmerable;
const Mutable = objutil.Mutable;
const Interp = @import("Interp.zig");
const ioutil = @import("ioutil.zig");
const pcre2 = @import("pcre2");
const regex = @import("regex.zig");

fn commandMatch(interp: *Interp, command: Handle, pattern: Handle, string: Handle) !bool {
    const script = try objutil.newList(&.{ command, pattern, string });
    defer script.decrRefCount();
    try interp.evalObject(script);
    return try interp.getBooleanInPlace(&interp.result);
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try registerCommand(interp, "*", mulCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "+", addCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "-", subCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "/", divCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "append", appendCmd, "varName ?value ...?", 1, null, null);
    try registerCommand(interp, "apply", applyCmd, "fn ?arg ...?", 1, null, null);
    try registerCommand(interp, "applymethod", applymethodCmd, "self method ?arg ...?", 1, null, null);
    try registerCommand(interp, "break", breakCmd, "?level?", 0, 1, null);
    try registerCommand(interp, "breakpoint", breakpointCmd, "", 0, 0, null);
    try registerCommand(interp, "catch", catchCmd, "script ?resultVar? ?optsVar?", 1, 3, null);
    try registerCommand(interp, "concat", concatCmd, "?arg ...?", 0, null, null);
    try registerCommand(interp, "continue", continueCmd, "?level?", 0, 1, null);
    try registerCommand(interp, "dict", dictCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "error", errorCmd, "message ?errorCode?", 1, 2, null);
    try registerCommand(interp, "errorinfo", errorinfoCmd, "optsDict", 1, 1, null);
    try registerCommand(interp, "eval", evalCmd, "arg ?arg ...?", 1, null, null);
    try registerCommand(interp, "expr", exprCmd, "expression", 1, 1, null);
    try registerCommand(interp, "file", fileCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "fn", fnCmd, "?name? argList body", 2, 3, null);
    try registerCommand(interp, "hash", hashCmd, "string", 1, 1, null);
    try registerCommand(interp, "hashlookup", hashlookupCmd, "hash", 1, 1, null);
    try registerCommand(interp, "method", methodCmd, "?name? argList body", 2, 3, null);
    try registerCommand(interp, "for", forCmd, "start test next body", 4, 4, null);
    try registerCommand(interp, "foreach", foreachCmd, "varList list ?varList list ...? body", 3, null, 2);
    try registerCommand(interp, "lmap", lmapCmd, "varList list ?varList list ...? body", 3, null, 2);
    try registerCommand(interp, "if", ifCmd, "condition trueBody ?elseif ...? ?else falseBody?", 2, null, null);
    try registerCommand(interp, "incr", incrCmd, "varName ?increment?", 1, 2, null);
    try registerCommand(interp, "info", infoCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "lappend", lappendCmd, "varName ?value value ...?", 1, null, null);
    try registerCommand(interp, "lassign", lassignCmd, "list ?varName ...?", 1, null, null);
    try registerCommand(interp, "launder", launderCmd, "string", 1, 1, null);
    try registerCommand(interp, "list", listCmd, "?arg ...?", 0, null, null);
    try registerCommand(interp, "join", joinCmd, "list ?joinString?", 1, 2, null);
    try registerCommand(interp, "llength", llengthCmd, "list", 1, 1, null);
    try registerCommand(interp, "pid", pidCmd, "", 0, 0, null);
    try registerCommand(interp, "puts", putsCmd, "?-nonewline? string", 1, 2, null);
    try registerCommand(interp, "regexp", regex.regexpCmd, "?switches? exp string ?matchVar ...?", 2, null, null);
    try registerCommand(interp, "regsub", regex.regsubCmd, "?switches? exp string subSpec ?varName?", 3, null, null);
    try registerCommand(interp, "return", returnCmd, "?-option value ...? ?result?", 0, null, null);
    try registerCommand(interp, "set", setCmd, "varName ?newValue?", 1, 2, null);
    try registerCommand(interp, "string", stringCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "source", sourceCmd, "fileName", 1, 1, null);
    try registerCommand(interp, "subst", substCmd, "?options? string", 1, 4, null);
    try registerCommand(interp, "switch", switchCmd, "?options? string pattern body ... ?default body? or pattern body ?pattern body ...?", 2, null, null);
    try registerCommand(interp, "tailcall", tallcallCommand, "command ?arg ...?", 1, null, null);
    try registerCommand(interp, "try", tryCmd, "script ?handler ...? ?finally body?", 1, null, null);
    try registerCommand(interp, "unset", unsetCmd, "?-nocomplain? ?--? ?varName ...?", 0, null, null);
    try registerCommand(interp, "uplevel", uplevelCmd, "?level? script ?arg ...?", 1, null, null);
    try registerCommand(interp, "upvar", upvarCmd, "?level? otherVar myVar ?otherVar myVar ...?", 2, null, null);
}

pub fn testStart(ta: std.mem.Allocator) !Interp {
    errdefer Heap.testFinish();
    _ = try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    errdefer interp.deinit();
    try registerCoreCommands(&interp);
    return interp;
}

pub fn testFinish(interp: *Interp) void {
    interp.deinit();
    Heap.testFinish();
}

test "commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    var script = try objutil.newString(
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    );
    defer script.decrRefCount();
    interp.evalObject(script) catch {};
}
