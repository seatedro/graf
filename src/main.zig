const std = @import("std");
const surface = @import("surface");

pub fn main(init: std.process.Init) !u8 {
    return surface.cli.run(init);
}
