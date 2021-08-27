const std = @import("std");

pub fn build(b: *std.build.Builder) void {
   // Standard target options allows the person running `zig build` to choose
   // what target to build for. Here we do not override the defaults, which
   // means any target is allowed, and the default is native. Other options
   // for restricting supported target set are available.
   const target = b.standardTargetOptions(.{});

   // Standard release options allow the person running `zig build` to select
   // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
   const mode = b.standardReleaseOptions();

   const caf = b.addExecutable("caf", "src/caf.zig");
   caf.setTarget(target);
   caf.setBuildMode(mode);
   caf.install();

   const uncaf = b.addExecutable("uncaf", "src/uncaf.zig");
   uncaf.setTarget(target);
   uncaf.setBuildMode(mode);
   uncaf.install();

   const caf_cmd = caf.run();
   caf_cmd.step.dependOn(b.getInstallStep());
   if (b.args) |args| {
      caf_cmd.addArgs(args);
   }

   const uncaf_cmd = uncaf.run();
   uncaf_cmd.step.dependOn(b.getInstallStep());
   if (b.args) |args| {
      uncaf_cmd.addArgs(args);
   }

   const caf_step = b.step("caf", "Run caf");
   caf_step.dependOn(&caf_cmd.step);

   const uncaf_step = b.step("uncaf", "Run uncaf");
   uncaf_step.dependOn(&uncaf_cmd.step);
}
