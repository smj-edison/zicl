const std = @import("std");

const common = @import("common.zig");
const heap = common.heap;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const String = objects.String;
const List = objects.List;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;

pub fn refCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const ref = try objects.HashReference.new(try args[1].ensureBoxed());
    interp.setResultOwning(ref.asHead().asValue());
}

pub fn derefCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResult((try interp.resolveHash(&args[1])).ref.asValue());
}

pub fn launderCmd(interp: *Interp, args: []Shimmerable) !void {
    const str = try args[1].getString();
    try interp.setResultString(str);
}

pub fn identityCmd(interp: *Interp, args: []Shimmerable) !void {
    interp.setResult(args[1].current());
}

pub fn breakpointCmd(_: *Interp, _: []Shimmerable) Interp.Error!void {
    @breakpoint();
}

pub fn errorinfoCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const message = args[1];
    const stack_trace = if (args.len == 3) args[2].current() else if (args.len == 2) interp.stack_trace.orEmpty() else unreachable;

    // The stack is a flat list: {name file line args ...} repeated.
    var stack_list: Shimmerable = .{ .original = stack_trace.takeReference() };
    defer stack_list.deinit();
    const as_list = try interp.getList(&stack_list);

    const error_message = Interp.makeErrorMessage(message.current(), as_list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WrongSize => return,
    };
    interp.setResultOwning(error_message);
}

/// [close], closes a capability.
pub fn closeCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var det: ErrorDetails = undefined;
    const cap = try interp.wrapError(&det, common.Capability.shimmerFrom(&det, &args[1]));
    @constCast(cap).close();
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "breakpoint", breakpointCmd, "", 0, 0);
    try registerCommand(interp, "close", closeCmd, "capability", 1, 1);
    try registerCommand(interp, "deref", derefCmd, "hash", 1, 1);
    try registerCommand(interp, "errorinfo", errorinfoCmd, "message ?stackTrace?", 1, 2);
    try registerCommand(interp, "identity", identityCmd, "anything", 1, 1);
    try registerCommand(interp, "launder", launderCmd, "string", 1, 1);
    try registerCommand(interp, "ref", refCmd, "string", 1, 1);
}
