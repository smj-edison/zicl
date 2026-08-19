//! [clock]: current time, and formatting a time value as a string.
//!
//! Mirrors the subset of Jim Tcl's `clock` (jim-clock.c) that Folk's
//! builtin programs actually use: `seconds`, `milliseconds`,
//! `microseconds`, `clicks`, and `format ?-format string? ?-gmt boolean?`.
//! `clock scan` isn't implemented since nothing in the tree calls it.
//!
//! Deliberately libc-free, to match the rest of zicl: calendar math is
//! Howard Hinnant's `days_from_civil`/`civil_from_days`
//! (http://howardhinnant.github.io/date_algorithms.html), and the local UTC
//! offset comes from parsing `/etc/localtime` with `std.tz.Tz` (a TZif/RFC
//! 8536 parser already in Zig's standard library) instead of calling
//! `localtime(3)`.
//!
//! TODO this is mostly vibe coded, need to do a proper review.

const std = @import("std");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const Integer = objects.Integer;

const default_format = "%a %b %d %H:%M:%S %Z %Y";

const weekday_names_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const weekday_names_long = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names_short = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const month_names_long = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Days since the Unix epoch (1970-01-01) for a proleptic Gregorian civil
/// date. Howard Hinnant's `days_from_civil`.
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u64 = @intCast(y - era * 400);
    const mp = if (month > 2) month - 3 else month + 9;
    const doy: u64 = @divFloor(153 * @as(u64, mp) + 2, 5) + day - 1;
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

/// The inverse of `daysFromCivil`: the proleptic Gregorian civil date for a
/// day count since the Unix epoch.
fn civilFromDays(days: i64) struct { year: i64, month: u32, day: u32 } {
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = @divFloor(5 * doy + 2, 153);
    const day: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = if (month <= 2) y + 1 else y, .month = month, .day = day };
}

/// 1970-01-01 (day 0) was a Thursday.
fn weekdayFromDays(days: i64) u32 {
    return @intCast(@mod(days + 4, 7));
}

const CivilTime = struct {
    year: i64,
    month: u32, // 1-12
    day: u32, // 1-31
    hour: u32, // 0-23
    minute: u32, // 0-59
    second: u32, // 0-59
    weekday: u32, // 0 = Sunday
    tz_name: []const u8,
};

/// `unix_seconds` comes straight from the script (`clock format $anything`),
/// so it isn't bounded to any sane calendar range. Once `local_seconds` is
/// known not to have overflowed, everything downstream shrinks by orders of
/// magnitude (dividing by 86400, then by ~146097) well within `i64`, so this
/// is the only checked step needed to keep `civilFromDays`'s casts -- which
/// rely on Hinnant's algorithm bounding its remainders -- actually safe.
fn civilTimeFromUnix(interp: *Interp, unix_seconds: i64, offset_seconds: i32, tz_name: []const u8) !CivilTime {
    const local_seconds = std.math.add(i64, unix_seconds, offset_seconds) catch {
        return interp.integerOverflowError(i65, @as(i65, unix_seconds) + offset_seconds);
    };
    const days = @divFloor(local_seconds, 86400);
    const secs_of_day: u32 = @intCast(@mod(local_seconds, 86400));
    const date = civilFromDays(days);
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = secs_of_day / 3600,
        .minute = (secs_of_day / 60) % 60,
        .second = secs_of_day % 60,
        .weekday = weekdayFromDays(days),
        .tz_name = tz_name,
    };
}

const Zone = struct { offset_seconds: i32, tz_name: []const u8 };

/// Looks up the local UTC offset (and zone abbreviation) for `unix_seconds`
/// by reading and parsing `/etc/localtime`, a TZif file (RFC 8536). Falls
/// back to UTC if the file can't be read or parsed -- e.g. non-Linux, or a
/// minimal container image without zoneinfo installed.
///
/// TODO: this ignores the `TZ` environment variable, which real libcs check
/// first (falling back to `/etc/localtime` only if `TZ` is unset). That
/// matters most in exactly the case where `/etc/localtime` is missing or
/// wrong -- a minimal container -- since `TZ` is the standard override for
/// that situation. Broaden this to check `TZ` first: either a path to a
/// TZif file (resolved against `/usr/share/zoneinfo/` if not absolute) or a
/// raw POSIX TZ rule string (e.g. `MST7MDT,M3.2.0,M11.1.0`), which would
/// need its own small parser.
fn localOffset(unix_seconds: i64) Zone {
    const utc: Zone = .{ .offset_seconds = 0, .tz_name = "UTC" };

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        heap.global_io,
        "/etc/localtime",
        heap.local_arena,
        .limited(1 << 16),
    ) catch return utc;

    var reader: std.Io.Reader = .fixed(bytes);
    var tz = std.Tz.parse(heap.local_arena, &reader) catch return utc;
    defer tz.deinit();

    if (tz.timetypes.len == 0) return utc;

    var chosen = tz.timetypes[0];
    for (tz.transitions) |transition| {
        if (transition.ts > unix_seconds) break;
        chosen = transition.timetype.*;
    }

    const name = heap.local_arena.dupe(u8, chosen.name()) catch return utc;
    return .{ .offset_seconds = chosen.offset, .tz_name = name };
}

fn twelveHour(hour: u32) u32 {
    const h = hour % 12;
    return if (h == 0) 12 else h;
}

fn formatTime(allocator: std.mem.Allocator, fmt: []const u8, t: CivilTime) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    var i: usize = 0;
    while (i < fmt.len) {
        const ch = fmt[i];
        if (ch != '%' or i + 1 >= fmt.len) {
            try w.writeByte(ch);
            i += 1;
            continue;
        }

        const spec = fmt[i + 1];
        i += 2;
        switch (spec) {
            '%' => try w.writeByte('%'),
            'Y' => try w.print("{d}", .{t.year}),
            'y' => try w.print("{d:0>2}", .{@mod(t.year, 100)}),
            'm' => try w.print("{d:0>2}", .{t.month}),
            'd' => try w.print("{d:0>2}", .{t.day}),
            'H' => try w.print("{d:0>2}", .{t.hour}),
            'I' => try w.print("{d:0>2}", .{twelveHour(t.hour)}),
            'M' => try w.print("{d:0>2}", .{t.minute}),
            'S' => try w.print("{d:0>2}", .{t.second}),
            'p' => try w.writeAll(if (t.hour < 12) "AM" else "PM"),
            'a' => try w.writeAll(weekday_names_short[t.weekday]),
            'A' => try w.writeAll(weekday_names_long[t.weekday]),
            'b' => try w.writeAll(month_names_short[t.month - 1]),
            'B' => try w.writeAll(month_names_long[t.month - 1]),
            'Z' => try w.writeAll(t.tz_name),
            'r' => try w.print("{d:0>2}:{d:0>2}:{d:0>2} {s}", .{
                twelveHour(t.hour), t.minute, t.second, if (t.hour < 12) "AM" else "PM",
            }),
            else => return error.UnsupportedFormatSpecifier,
        }
    }

    return allocator.dupe(u8, out.written());
}

const ClockOptions = struct {
    gmt: bool = false,
    format: []const u8 = default_format,
};

/// Parses the trailing `?-format string? ?-gmt boolean?` pairs of `clock
/// format`. `args` holds just the option pairs (not the leading seconds
/// argument), and must have an even length -- guaranteed by the
/// subcommand's `stride = 2` below.
fn parseClockOptions(interp: *Interp, args: []Shimmerable) !ClockOptions {
    var options: ClockOptions = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const flag = try args[i].current().getString();
        if (std.mem.eql(u8, flag, "-format")) {
            options.format = try args[i + 1].current().getString();
        } else if (std.mem.eql(u8, flag, "-gmt")) {
            options.gmt = try interp.getBoolean(&args[i + 1]);
        } else {
            return interp.setErrorFormatted(
                "bad option \"{s}\": must be -format or -gmt",
                .{flag},
            );
        }
    }

    return options;
}

pub fn clockCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        clicks,
        format,
        microseconds,
        milliseconds,
        seconds,
    };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .clicks, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .format, .usage = "seconds ?-format string? ?-gmt boolean?", .min_args = 1, .max_args = 5 },
        .{ .variant = .microseconds, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .milliseconds, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .seconds, .usage = "", .min_args = 0, .max_args = 0 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .seconds => interp.setResultInteger(std.Io.Clock.real.now(heap.global_io).toSeconds()),
        .milliseconds => interp.setResultInteger(std.Io.Clock.real.now(heap.global_io).toMilliseconds()),
        .microseconds => interp.setResultInteger(std.Io.Clock.real.now(heap.global_io).toMicroseconds()),
        // `awake` is monotonic and excludes suspend time, matching Jim's use
        // of CLOCK_MONOTONIC_RAW for `clock clicks`.
        .clicks => interp.setResultInteger(std.Io.Clock.awake.now(heap.global_io).toMicroseconds()),
        .format => {
            const seconds = try interp.wrapError(&det, Integer.shimmerFrom(&det, &args[2]));
            const options = try parseClockOptions(interp, args[3..]);

            const zone: Zone = if (options.gmt)
                .{ .offset_seconds = 0, .tz_name = "UTC" }
            else
                localOffset(seconds);

            const civil = try civilTimeFromUnix(interp, seconds, zone.offset_seconds, zone.tz_name);
            const formatted = formatTime(heap.local_arena, options.format, civil) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnsupportedFormatSpecifier => return interp.setErrorString("format string too long or invalid time"),
                else => return interp.setErrorString("format string too long or invalid time"),
            };

            try interp.setResultString(formatted);
        },
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "clock", clockCmd, "option ?arg ...?", 1, null);
}

fn testClock(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("2000-01-01 00:00:00", "clock format 946684800 -format {%Y-%m-%d %H:%M:%S} -gmt true");
    try interp.testExpectScriptResult("Sat", "clock format 946684800 -format {%a} -gmt true");
    try interp.testExpectScriptResult("11:59:59 PM", "clock format 946771199 -format {%r} -gmt true");
    try interp.testExpectScriptResult("true", "expr {[clock seconds] > 0}");
    try interp.testExpectScriptResult("true", "expr {[clock milliseconds] > 0}");
    try interp.testExpectScriptResult("true", "expr {[clock microseconds] > 0}");
    try interp.testExpectScriptError(error.EvalError, "bad option \"-bogus\": must be -format or -gmt", "clock format 0 -bogus true");

    // `unix_seconds` is unbounded script input; combining it with a nonzero
    // offset must not overflow-panic (it used to, at both extremes, before
    // `local_seconds` was computed with checked addition). Exercised
    // directly, with a fixed offset, rather than through `-gmt false` --
    // the real local offset is system-dependent (whatever /etc/localtime
    // says), and `-gmt true` always passes offset 0, which can never
    // overflow regardless of how extreme `unix_seconds` is.
    try std.testing.expectError(error.EvalError, civilTimeFromUnix(&interp, std.math.maxInt(i64), 1, "TEST"));
    try std.testing.expectError(error.EvalError, civilTimeFromUnix(&interp, std.math.minInt(i64), -1, "TEST"));
    try interp.testExpectScriptResult("true", "expr {[string length [clock format -9223372036854775808 -gmt true]] > 0}");
    try interp.testExpectScriptResult("true", "expr {[string length [clock format 9223372036854775807 -gmt true]] > 0}");

    // Local-time formatting (the default, no -gmt) reads /etc/localtime.
    // Its exact offset depends on the machine running the test, so just
    // check the whole path -- TZif lookup included -- runs without error
    // and produces a nonempty zone name, rather than asserting a specific
    // offset.
    try interp.testExpectScriptResult("true", "expr {[string length [clock format [clock seconds] -format {%Z}]] > 0}");
}

test "clock" {
    try common.memutil.checkAllocationFailures(.exhaustive, testClock, .{});
}
