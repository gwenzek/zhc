//! Build-integration is exported here. When using ZHC build options,
//! it is advised to not use any functionality outside this path.

const std = @import("std");
const build = std.build;
const Builder = build.Builder;
const FileSource = build.FileSource;
const Step = build.Step;
const LibExeObjStep = build.LibExeObjStep;
const OptionsStep = build.OptionsStep;
const Pkg = build.Pkg;
const CrossTarget = std.zig.CrossTarget;

const zhc = @import("zhc.zig");
const KernelConfig = zhc.abi.KernelConfig;

pub const elf = @import("build/elf.zig");
pub const amdgpu = @import("build/amdgpu.zig");

const zhc_pkg_name = "zhc";
const zhc_options_pkg_name = "zhc_build_options";
/// The path to the main file of this library.
const zhc_pkg_path = getZhcPkgPath();

fn getZhcPkgPath() []const u8 {
    const root = comptime std.fs.path.dirname(@src().file).?;
    return root ++ [_]u8{std.fs.path.sep} ++ "zhc.zig";
}

/// Get the configured ZHC package for host compilations
pub fn getHostPkg(b: *Builder) Pkg {
    return configure(b, getCommonZhcOptions(b, .host));
}

fn getCommonZhcOptions(b: *Builder, side: zhc.compilation.Side) *OptionsStep {
    const opts = b.addOptions();
    const out = opts.contents.writer();
    // Manually write the symbol so that we avoid a duplicate definition of `Side`.
    // `zhc.zig` re-exports this value to ascribe it with the right enum type.
    out.print("pub const side = .{s};\n", .{@tagName(side)}) catch unreachable;

    return opts;
}

/// Configure ZHC for compilation. `opts` is an `OptionsStep` that provides
/// `zhc_build_options`.
fn configure(
    b: *Builder,
    opts: *OptionsStep,
) Pkg {
    const deps = b.allocator.dupe(Pkg, &.{
        opts.getPackage(zhc_options_pkg_name),
    }) catch unreachable;

    return .{
        .name = zhc_pkg_name,
        .source = .{ .path = zhc_pkg_path },
        .dependencies = deps,
    };
}

/// This step is used to compile a "device-library" step for a particular architecture.
/// The Zig code associated to this step is compiled in "device-mode", and the produced
/// elf file is to be linked with a host executable or library.
const DeviceLibStep = struct {
    step: Step,
    b: *Builder,
    device_lib: *LibExeObjStep,
    configs_step: *KernelConfigExtractStep,

    fn create(
        b: *Builder,
        /// The main source file for this device lib.
        root_src: FileSource,
        /// The device architecture to compile for.
        // TODO: Perhaps this should be passed via setTarget, but then some form of
        // default needs to be chosen.
        device_target: CrossTarget,
        /// Step which resolves the kernel configurations that this device library
        /// should compile.
        configs_step: *KernelConfigExtractStep,
    ) *DeviceLibStep {
        const self = b.allocator.create(DeviceLibStep) catch unreachable;
        self.* = .{
            // TODO: Better name?
            .step = Step.init(.custom, "extract-kernels", b.allocator, make),
            .b = b,
            .device_lib = b.addObjectSource("device-code", root_src),
            .configs_step = configs_step,
        };
        self.step.dependOn(&self.device_lib.step);
        self.device_lib.setTarget(device_target);
        self.device_lib.addPackage(configure(b, configs_step.device_options_step));
        self.step.dependOn(&self.configs_step.step);
        return self;
    }

    pub fn setBuildMode(self: *DeviceLibStep, mode: std.builtin.Mode) void {
        self.device_lib.setBuildMode(mode);
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(DeviceLibStep, "step", step);
        const target_info = try std.zig.system.NativeTargetInfo.detect(self.device_lib.target);

        const device_object_path = self.device_lib.getOutputSource().getPath(self.b);
        if (self.b.verbose) {
            std.log.debug("Extracting kernels from {s}", .{device_object_path});
        }

        const device_object = try elf.readBinary(self.b.allocator, std.fs.cwd(), device_object_path);

        // TODO: Also use some kind of platform thingy here...
        switch (target_info.target.cpu.arch) {
            .amdgcn => try amdgpu.extractKernels(self.b.allocator, device_object),
            else => return error.UnsupportedPlatform,
        }
    }
};

pub fn addDeviceLib(self: *Builder, root_src: []const u8, device_target: CrossTarget, configs: *KernelConfigExtractStep) *DeviceLibStep {
    return addDeviceLibSource(self, .{ .path = root_src }, device_target, configs);
}

pub fn addDeviceLibSource(builder: *Builder, root_src: FileSource, device_target: CrossTarget, configs: *KernelConfigExtractStep) *DeviceLibStep {
    return DeviceLibStep.create(builder, root_src, device_target, configs);
}

/// This step is used to extract which kernels in a particular binary are present.
const KernelConfigExtractStep = struct {
    step: Step,
    b: *Builder,
    object_src: FileSource,
    /// The final array of kernel configs extracted from the source object's binary.
    /// This value is only valid after make() is called.
    configs: zhc.abi.Overload.Map,
    /// This step is used for `zhc_build_options` for a device, and has the
    /// kernel configs generated by this step.
    /// It is part of this step to save on some complexity, as it is pretty much
    /// always needed by uses of this step.
    device_options_step: *OptionsStep,

    fn create(
        b: *Builder,
        /// The (elf) object to extract kernel configuration symbols from.
        object_src: FileSource,
    ) *KernelConfigExtractStep {
        const self = b.allocator.create(KernelConfigExtractStep) catch unreachable;
        self.* = .{
            .step = Step.init(.custom, "extract-kernel-configs", b.allocator, make),
            .b = b,
            .object_src = object_src,
            .configs = undefined,
            .device_options_step = getCommonZhcOptions(b, .device),
        };
        self.object_src.addStepDependencies(&self.step);
        self.device_options_step.step.dependOn(&self.step);
        return self;
    }

    fn make(step: *Step) !void {
        // TODO: Something with the cache to see if this work is at all neccesary?
        const self = @fieldParentPtr(KernelConfigExtractStep, "step", step);
        const object_path = self.object_src.getPath(self.b);
        const binary = try elf.readBinary(self.b.allocator, std.fs.cwd(), object_path);
        self.configs = try elf.parseKernelConfigs(self.b.allocator, binary);

        if (self.b.verbose) {
            std.log.info("Found {} kernel config(s):", .{self.configs.count()});

            var it = self.configs.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.*) |overload| {
                    std.log.info("  {s}({})", .{ entry.key_ptr.*, overload });
                }
            }
        }

        // Add the generated configs to the options step.
        const out = self.device_options_step.contents.writer();
        try out.writeAll("pub const launch_configurations = struct {\n");

        var it = self.configs.iterator();
        while (it.next()) |entry| {
            try out.print("    pub const {} = &.{{\n", .{std.zig.fmtId(entry.key_ptr.*)});
            for (entry.value_ptr.*) |overload| {
                try out.writeAll(" " ** 8);
                try overload.toStaticInitializer(out);
                try out.writeAll(",\n");
            }
            try out.writeAll("    };\n");
        }

        try out.writeAll("};\n");
    }
};

pub fn extractKernelConfigs(builder: *Builder, object_step: *LibExeObjStep) *KernelConfigExtractStep {
    return extractKernelConfigsSource(builder, object_step.getOutputSource());
}

pub fn extractKernelConfigsSource(builder: *Builder, object_src: FileSource) *KernelConfigExtractStep {
    return KernelConfigExtractStep.create(builder, object_src);
}
