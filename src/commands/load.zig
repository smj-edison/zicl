//! [load]: dynamically load a compiled Zicl extension.
//!
//! Mirrors Jim's `load`: dlopen the file, then call the symbol
//! `Zicl_<pkgname>Init`, where `<pkgname>` is the file's basename up to (not
//! including) its first `.`. This lets one binary hold several extensions,
//! each loadable under its own name, the same way Jim derived `Jim_fooInit`
//! from `foo.so`.
//!
//! `Zicl_<pkgname>Init` does not itself install commands into this interp.
//! Namespaces don't exist here -- a "library" is just a dict -- so it instead
//! calls `Zicl_RegisterLazyFn` for each command it provides (idempotent: see
//! `heap.LazyFnRegistry`, since independent threads may each `load` the same
//! compiled file) and returns a dict of `{cleanName registryName ...}` it
//! registered. The two names differ in purpose: `registryName` is whatever
//! key it registered with `Zicl_RegisterLazyFn` (typically qualified with the
//! library's own package name, so unrelated libraries don't collide in the
//! shared registry), while `cleanName` is what the *result* dict -- what a
//! caller actually sees -- uses as its key. This split matters because dict
//! sugar (`$lib::name`) treats `::` as its own path separator, so a
//! registry-style qualified name could never work as a dict key in the first
//! place. `load` turns the returned `{cleanName registryName ...}` dict into
//! `{cleanName1 {nativefn registryName1} cleanName2 {nativefn registryName2}
//! ...}`, and that is the result: an ordinary Folk value that propagates
//! through envs and closures like any other, so only the thread that
//! actually calls `load` needs to. Any other thread that later receives the
//! dict and dispatches through it (`$lib::cleanName ...`, dict-sugar) drives
//! the exact same per-interp lazy-registration path an already-known
//! `nativefn` name would, materializing its own `Zicl_CreateCommand`s on
//! first real call.
//!
//! The library is never dlclose'd. An extension can hand out raw function
//! pointers (see folk's `lib/c.tcl` `C::extend`) that outlive any particular
//! caller's interest in the library itself, so unloading on interp teardown
//! would leave dangling pointers other threads may still call through.

const std = @import("std");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const Capability = common.Capability;
const capabilities = common.capabilities;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;

/// Returns `{cleanName registryName ...}` for the names it registered via
/// `Zicl_RegisterLazyFn`, or null on failure -- mirroring the rest of Zicl's
/// C API, the interp's result already carries why.
const InitFn = *const fn (*Interp) callconv(.c) ?*objects.Dictionary;

const interned_nativefn = heap.InternedString.newValue("nativefn");

/// Loads `path`, calls its `Zicl_<pkgname>Init`, and returns a DyLib capability.
pub fn loadLibrary(interp: *Interp, path: [:0]const u8) Interp.Error!void {
    var lib = std.DynLib.open(path) catch |err| {
        return interp.setErrorFormatted("error loading extension \"{s}\": {t}", .{ path, err });
    };
    errdefer lib.close();

    const basename = std.Io.Dir.path.basename(path);
    const pkgname = if (std.mem.indexOfScalar(u8, basename, '.')) |dot| basename[0..dot] else basename;

    const symbol = try std.fmt.allocPrintSentinel(heap.local_arena, "Zicl_{s}Init", .{pkgname}, 0);
    const init_fn = lib.lookup(InitFn, symbol) orelse {
        return interp.setErrorFormatted("no {s} symbol found in extension {s}", .{ symbol, path });
    };

    const registered = init_fn(interp) orelse {
        return interp.setErrorString("failed to initialize dynlib");
    };
    defer registered.asHead().dropReference();

    const fns_dict = try objects.Dictionary.newWithCapacity(&.{}, registered.items.len / 2);
    errdefer fns_dict.asHead().dropReference();

    var i: usize = 0;
    while (i < registered.items.len) : (i += 2) {
        const clean_name = registered.items[i];
        const registry_name = registered.items[i + 1];
        const tagged = try objects.List.new(&.{ interned_nativefn, registry_name });
        defer tagged.asHead().dropReference();
        try fns_dict.put(clean_name, tagged.asHead().asValue());
    }

    const dynlib_cap = try capabilities.DynLib.new(lib, fns_dict.asHead().asValue());
    interp.setResultOwning(dynlib_cap.asHead().asValue());
}

pub fn loadCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const path = try args[1].getString();
    try loadLibrary(interp, path);
}

/// [dynlib]: operations on a `DynLib` capability (what `[load]` returns).
///
/// `dynlib fns $cap` -- the `{fnName {nativefn fnName} ...}` dict
/// of commands the library registered at load time; this is what `[load]`
/// itself used to return directly.
///
/// `dynlib lookup $cap $symbolName` -- the address of `symbolName` in the
/// library, as an integer. Errors if the symbol isn't exported, rather than
/// returning some sentinel a caller could mistake for a real address.
pub fn dynlibCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum { fns, lookup };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .fns, .usage = "dynlibCapability", .min_args = 1, .max_args = 1 },
        .{ .variant = .lookup, .usage = "dynlibCapability symbolName", .min_args = 2, .max_args = 2 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    const cap = try interp.wrapError(&det, Capability.shimmerFrom(&det, &args[2]));
    const backing = try interp.wrapError(&det, cap.getBacking(capabilities.DynLib.Backing, &det));
    defer backing.head.dropInFlight();

    switch (subcommand) {
        .fns => interp.setResult(backing.body.fns),
        .lookup => {
            const symbol_name = try args[3].getString();
            const addr = backing.body.lookup(symbol_name) orelse {
                try interp.setResultFormatted("no such symbol \"{s}\"", .{symbol_name});
                return error.EvalError;
            };
            interp.setResultInteger(@intCast(@intFromPtr(addr)));
        },
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "load", loadCmd, "libraryFile", 1, 1);
    try registerCommand(interp, "dynlib", dynlibCmd, "subcommand ?arg ...?", 2, 3);
}
