//! CAF archiver CLI.

const std = @import("std");

const caf = @import("cafformat.zig");
const Archive = caf.Archive;
const ArchiveBuilder = caf.ArchiveBuilder;

const help_text =
   \\caf - COMES Archive Format archiver
   \\copyright (C) liquidev, 2021
   \\
   \\USAGE:
   \\  caf <input directory> <output-file.caf>
   \\
   \\
   ;

pub fn main() anyerror!void {
   const stdout = std.io.getStdOut().writer();

   var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
   defer std.debug.assert(!gpa.deinit());

   const allocator = &gpa.allocator;

   var args = std.process.args();
   _ = args.skip(); // skip over process name

   const input_directory_name = try args.next(allocator) orelse {
      try stdout.writeAll(help_text);
      return error.MissingInputDirectory;
   };
   defer allocator.free(input_directory_name);
   const output_file_name = try args.next(allocator) orelse return error.MissingOutputFile;
   defer allocator.free(output_file_name);

   const cwd = std.fs.cwd();
   var input_directory = try cwd.openDir(input_directory_name, .{
      .iterate = true,
   });
   defer input_directory.close();
   var output_file = try cwd.createFile(output_file_name, .{});
   defer output_file.close();

   var builder = ArchiveBuilder.init(allocator);
   defer builder.deinit();
   try builder.addDirRecursively(input_directory, null);
   var archive = builder.finish();
   defer archive.deinit();

   std.log.info("writing archive", .{});
   var file_writer = output_file.writer();
   var buffered_writer = std.io.BufferedWriter(32768, @TypeOf(file_writer)) {
      .unbuffered_writer = file_writer,
   };
   try archive.write(buffered_writer.writer());
   try buffered_writer.flush();
}
