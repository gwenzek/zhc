//! This file contains some information and helpers related to the current
//! compilation.

const zhc = @import("zhc.zig");
const build_options = @import("zhc_build_options");
const builtin = @import("builtin");

/// Indicates a side of compilation.
/// The value of this enum for the current build is made visible through
/// `zhc.compilation.side`.
pub const Side = enum {
    /// Indicates "host" code: Code which runs the driver program,
    /// that interfaces with accelerators and launches kernels
    /// (typically the CPU).
    host,
    /// Indicates "device" code: Code which implements actual kernels, and
    /// is meant to run on an accelerator (typically a GPU).
    device,
};

/// The side code is currently being compiled for.
pub const side = @intToEnum(Side, @enumToInt(build_options.side));

/// The architecture of the device currently compiling for.
// Note: uses stage2_arch because referencing builtin.cpu causes a compile error.
// TODO: fix.
pub const device_arch = blk: {
    deviceOnly();
    break :blk builtin.stage2_arch;
};

/// Ensure that the compilation of a scope is at `required_side`.
/// Produces a compile error otherwise.
pub fn sideOnly(comptime required_side: Side) void {
    if (required_side != side) {
        @compileError("cannot compile " ++ @tagName(required_side) ++ " code on " ++ @tagName(side) ++ " side");
    }
}

/// Ensure that the compilation of a scope is targetted at host-side execution.
pub fn hostOnly() void {
    sideOnly(.host);
}

/// Ensure that the compilation of a scope is targetted at device-side execution.
pub fn deviceOnly() void {
    sideOnly(.device);
}

/// Returns true if we're currently compiling for device-side execution.
pub fn isDevice() bool {
    return side == .device;
}

/// Returns true if we're currently compiling for host-side execution.
pub fn isHost() bool {
    return side == .host;
}
