const std = @import("std");
const uucode = @import("uucode");
const zigtcl = @import("zigtcl.c");

pub fn main() void {
    var cp: u21 = undefined;

    var buffer: [1]u21 = undefined;
    cp = 0x00DF; // ß
    const res = uucode.get(.uppercase_mapping, cp).with(&buffer, cp);

    ioutil.debug("res: {any}.", .{res});
}
