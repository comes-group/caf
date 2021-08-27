//! CAF unarchiver CLI.

const std = @import("std");

const caf = @import("cafformat.zig");
const Archive = caf.Archive;

const help_text =
   \\uncaf - COMES Archive Format unarchiver
   \\copyright (C) liquidev, 2021
   \\
   \\USAGE:
   \\  caf <input-file.caf> <output directory>
   \\  If the output directory doesn't exist, it will be created.
   \\
   \\
   ;

pub fn main() anyerror!void {
   const stdout = std.io.getStdOut().writer();

   var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
   // defer std.debug.assert(!gpa.deinit());

   const allocator = &gpa.allocator;

   var args = std.process.args();
   _ = args.skip(); // skip over process name

   const input_file_name = try args.next(allocator) orelse {
      try stdout.writeAll(help_text);
      return error.MissingInputFile;
   };
   defer allocator.free(input_file_name);
   const output_directory_name = try args.next(allocator) orelse return error.MissingOutputDirectory;
   defer allocator.free(output_directory_name);

   const cwd = std.fs.cwd();
   var input_file = try cwd.openFile(input_file_name, .{});
   defer input_file.close();
   try cwd.makePath(output_directory_name);
   var output_directory = try cwd.openDir(output_directory_name, .{
      .access_sub_paths = true,
   });
   defer output_directory.close();

   std.log.info("unpacking archive", .{});
   var archive = try Archive.read(allocator, input_file.reader());
   defer archive.deinit();
   try caf.unpack(&archive, output_directory);
}
