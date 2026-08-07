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
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;

/// Returns `{cleanName registryName ...}` for the names it registered via
/// `Zicl_RegisterLazyFn`, or null on failure -- mirroring the rest of Zicl's
/// C API, the interp's result already carries why.
const InitFn = *const fn (*Interp) callconv(.c) ?*objects.Dictionary;

const interned_nativefn = heap.InternedString.newValue("nativefn");

/// Loads `path` and calls its `Zicl_<pkgname>Init`, leaving the resulting
/// `{cleanName {nativefn registryName} ...}` dict as the interp's result.
pub fn loadLibrary(interp: *Interp, path: [:0]const u8) Interp.Error!void {
    var lib = std.DynLib.open(path) catch |err| {
        return interp.setErrorFormatted("error loading extension \"{s}\": {t}", .{ path, err });
    };
    // Not closed: see module doc comment.

    const basename = std.Io.Dir.path.basename(path);
    const pkgname = if (std.mem.indexOfScalar(u8, basename, '.')) |dot| basename[0..dot] else basename;

    const symbol = try std.fmt.allocPrintSentinel(heap.local_arena, "Zicl_{s}Init", .{pkgname}, 0);
    const init_fn = lib.lookup(InitFn, symbol) orelse {
        return interp.setErrorFormatted("no {s} symbol found in extension {s}", .{ symbol, path });
    };

    const registered = init_fn(interp) orelse return error.EvalError;
    defer registered.asHead().release();

    const dict = try objects.Dictionary.newWithCapacity(&.{}, registered.items.len / 2);
    errdefer dict.asHead().release();

    var i: usize = 0;
    while (i < registered.items.len) : (i += 2) {
        const clean_name = registered.items[i];
        const registry_name = registered.items[i + 1];
        const tagged = try objects.List.new(&.{ interned_nativefn, registry_name });
        defer tagged.asHead().release();
        try dict.put(clean_name, tagged.asHead().asValue());
    }

    interp.setResultOwning(dict.asHead().asValue());
}

pub fn loadCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const path = try args[1].getString();
    try loadLibrary(interp, path);
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "load", loadCmd, "libraryFile", 1, 1);
}
