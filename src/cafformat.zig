//! CAF format support module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Dir = std.fs.Dir;
const OsFile = std.fs.File;

pub const current_version = 1;

const log = std.log.scoped(.cafformat);

/// A CAF archive.
pub const Archive = struct {
   allocator: ?*Allocator = null,

   version: u8,
   index: Index,
   files: []const File,

   /// An entry in the `INDEKS` section of the archive.
   pub const IndexEntry = struct {
      kind: enum { directory, file },
      name: []const u8,
   };

   /// The `INDEKS` section.
   pub const Index = struct {
      entries: []const IndexEntry,
   };

   /// File data.
   pub const File = struct {
      data: []const u8,
      allocation: ?[]const u8,
   };

   /// If the `Archive` has an allocator, uses it to free the files from the file table,
   /// the file table itself, and the index's entries.
   pub fn deinit(self: *Archive) void {
      if (self.allocator) |allocator| {
         log.info("deallocating the archive", .{});
         for (self.index.entries) |entry| {
            allocator.free(entry.name);
         }
         allocator.free(self.index.entries);
         for (self.files) |file| {
            if (file.allocation) |allocation| {
               allocator.free(allocation);
            }
         }
         allocator.free(self.files);
      }
   }

   /// Writes the archive to an `std.io.Writer`.
   pub fn write(self: *const Archive, writer: anytype) !void {
      var emitter = Emitter(@TypeOf(writer)) {
         .archive = self,
         .writer = writer,
      };
      try emitter.go();
   }

   /// Reads the archive from an `std.io.Reader`.
   pub fn read(allocator: *Allocator, reader: anytype) !Archive {
      var parser = Parser(@TypeOf(reader)) {
         .allocator = allocator,
         .reader = reader,
      };
      try parser.go();
      return parser.archive;
   }
};

/// Builder for `Archive`s.
pub const ArchiveBuilder = struct {
   allocator: *Allocator,
   entries: ArrayList(Archive.IndexEntry),
   files: ArrayList(Archive.File),

   /// Initializes a new archive builder.
   pub fn init(allocator: *Allocator) ArchiveBuilder {
      return .{
         .allocator = allocator,
         .entries = ArrayList(Archive.IndexEntry).init(allocator),
         .files = ArrayList(Archive.File).init(allocator),
      };
   }

   pub fn deinit(self: *ArchiveBuilder) void {
      self.entries.deinit();
      self.files.deinit();
   }

   fn verifyFilename(name: []const u8) !void {
      if (name.len == 0)
         return error.FilenameIsEmpty;
      if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
         return error.ParentDirectoriesAreNotAllowed;
      for (name) |char| {
         if (char == 0) return error.NullCharInFilename;
         if (char == '/') return error.SlashInFilename;
      }
   }

   fn verifyPath(path: []const u8) !void {
      if (path.len == 0)
         return error.PathIsEmpty;
      var iterator = std.mem.split(path, "/");
      while (iterator.next()) |filename| {
         try verifyFilename(filename);
      }
   }

   /// Sets the directory in which new files should be located.
   pub fn changeDirectory(self: *ArchiveBuilder, path: []const u8) !void {
      try verifyPath(path);
      try self.entries.append(.{
         .kind = .directory,
         .name = path,
      });
   }

   /// Adds a file into the current directory.
   pub fn add(self: *ArchiveBuilder, name: []const u8, data: []const u8) !void {
      try verifyFilename(name);
      try self.entries.append(.{
         .kind = .file,
         .name = name,
      });
      try self.files.append(.{
         .data = data,
         .allocation = data,
      });
   }

   /// Recursively adds files and subdirectories from the given directory.
   pub fn addDirRecursively(self: *ArchiveBuilder, dir: Dir, maybe_path: ?[]const u8) anyerror!void {
      if (maybe_path) |path| {
         try self.changeDirectory(path);
      }
      var iterator = dir.iterate();
      // Subdirectories have to be traversed last.
      var directories = ArrayList(struct {
         dir: Dir,
         name: []const u8,
      }).init(self.allocator);
      defer directories.deinit();

      while (try iterator.next()) |dir_entry| {
         switch (dir_entry.kind) {
            .File => {
               const name = try self.allocator.dupe(u8, dir_entry.name);
               log.info("adding file {s}", .{name});
               const file = try dir.openFile(name, .{});
               defer file.close();
               const data = try file.reader().readAllAlloc(self.allocator, std.math.maxInt(u64));
               try self.add(name, data);
            },
            .Directory => {
               var name: []const u8 = undefined;
               if (maybe_path) |parent| {
                  name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{parent, dir_entry.name});
               } else {
                  name = try self.allocator.dupe(u8, dir_entry.name);
               }
               var subdir = try dir.openDir(dir_entry.name, .{
                  .iterate = true,
               });
               try directories.append(.{
                  .dir = subdir,
                  .name = name,
               });
            },
            else => log.warn("skipping unsupported directory entry kind: {}", .{dir_entry.kind}),
         }
      }

      for (directories.items) |*subdir| {
         log.info("recursing to subdirectory {s}", .{subdir.name});
         try self.addDirRecursively(subdir.dir, subdir.name);
         defer subdir.dir.close();
      }
   }

   /// Finishes building an archive.
   pub fn finish(self: *ArchiveBuilder) Archive {
      return Archive{
         .allocator = self.allocator,
         .version = current_version,
         .index = .{
            .entries = self.entries.toOwnedSlice(),
         },
         .files = self.files.toOwnedSlice(),
      };
   }
};

/// Unpacks an archive to the given destination directory. Creates directories when necessary.
pub fn unpack(archive: *Archive, destination: Dir) !void {
   var cwd = destination;
   var file_index: usize = 0;
   for (archive.index.entries) |entry| {
      switch (entry.kind) {
         .file => {
            var file_data = archive.files[file_index].data;
            log.info("unpacking {s} ({} bytes)", .{entry.name, file_data.len});
            var file = cwd.createFile(entry.name, .{}) catch |err| {
               if (err == error.PathAlreadyExists) continue;
               return err;
            };
            defer file.close();
            try file.writer().writeAll(file_data);
            file_index += 1;
         },
         .directory => {
            log.info("entering directory {s}", .{entry.name});
            try destination.makePath(entry.name);
            cwd = try destination.openDir(entry.name, .{});
         },
      }
   }
}

/// An archive file emitter.
fn Emitter(comptime W: type) type {
   return struct {
      const Self = @This();

      archive: *const Archive,
      writer: W,

      last_octet: ?u64 = null,
      run_length: u64 = 0,

      fn writeHeader(self: *Self) !void {
         try self.writer.writeAll("CAF ");
         try numbers.writeU8(self.writer, self.archive.version);
         try self.writer.writeByte('\n');
      }

      fn writeIndex(self: *Self) !void {
         try self.writer.writeAll("INDEKS ");
         try numbers.writeVU64(self.writer, self.archive.index.entries.len);
         try self.writer.writeByte('\n');
         for (self.archive.index.entries) |entry| {
            try self.writer.writeAll(switch (entry.kind) {
               .directory => "KATALOG ",
               .file => "PLIK ",
            });
            try self.writer.writeAll(entry.name);
            try self.writer.writeByte('\n');
         }
      }

      fn writeOctet(self: *Self, oc: u64) !void {
         if (oc != self.last_octet) {
            if (self.run_length > 1) {
               try self.writer.writeAll(" X ");
               try numbers.writeVU64(self.writer, self.run_length);
            }
            try self.writer.writeByte('\n');
            try numbers.writeVU64(self.writer, oc);
            self.last_octet = oc;
            self.run_length = 1;
         } else {
            self.run_length += 1;
         }
      }

      fn safeIndex(bytes: []const u8, i: usize) u8 {
         if (i >= bytes.len) return 0
         else return bytes[i];
      }

      fn mergeOctet(bytes: [8]u8) u64 {
         return
            @as(u64, bytes[0]) << 56 |
            @as(u64, bytes[1]) << 48 |
            @as(u64, bytes[2]) << 40 |
            @as(u64, bytes[3]) << 32 |
            @as(u64, bytes[4]) << 24 |
            @as(u64, bytes[5]) << 16 |
            @as(u64, bytes[6]) << 8 |
            @as(u64, bytes[7]);
      }

      fn writeFile(self: *Self, file: *const Archive.File) !void {
         try self.writer.writeAll("ROZMIAR ");
         try numbers.writeVU64(self.writer, file.data.len);
         // \n is inserted by writeOctet
         var index: usize = 0;
         while (index + 8 < file.data.len) : (index += 8) {
            const octet = mergeOctet([_]u8{
               file.data[index],
               file.data[index + 1],
               file.data[index + 2],
               file.data[index + 3],
               file.data[index + 4],
               file.data[index + 5],
               file.data[index + 6],
               file.data[index + 7],
            });
            try self.writeOctet(octet);
         }
         if (index < file.data.len) {
            const octet = mergeOctet([_]u8{
               safeIndex(file.data, index),
               safeIndex(file.data, index + 1),
               safeIndex(file.data, index + 2),
               safeIndex(file.data, index + 3),
               safeIndex(file.data, index + 4),
               safeIndex(file.data, index + 5),
               safeIndex(file.data, index + 6),
               safeIndex(file.data, index + 7),
            });
            try self.writeOctet(octet);
         }
         try self.writer.writeByte('\n');
      }

      fn writeFiles(self: *Self) !void {
         for (self.archive.files) |file| {
            try self.writeFile(&file);
         }
      }

      fn go(self: *Self) !void {
         try self.writeHeader();
         try self.writeIndex();
         try self.writeFiles();
         try self.writer.writeByte('\n');
      }
   };
}

const parsing = struct {
   fn matchString(input: []const u8, position: *usize, comptime string: []const u8) bool {
      if (position.* + string.len >= input.len) return false;
      inline for (string) |char, index| {
         if (input[position.* + index] != char) return false;
      }
      position.* += string.len;
      return true;
   }

   fn matchChar(input: []const u8, position: *usize, char: u8) bool {
      if (position.* >= input.len) return false;
      if (input[position.*] == char) {
         position.* += 1;
         return true;
      }
      return false;
   }
};

fn Parser(comptime R: type) type {
   return struct {
      const Self = @This();

      allocator: *Allocator,
      archive: Archive = undefined,
      reader: R,

      input: []const u8 = undefined,
      position: usize = 0,

      fn testChar(self: *Self, char: u8) bool {
         return parsing.matchChar(self.input, &self.position, char);
      }

      fn testString(self: *Self, comptime string: []const u8) bool {
         return parsing.matchString(self.input, &self.position, string);
      }

      fn matchString(self: *Self, comptime string: []const u8) !void {
         if (!self.testString(string)) {
            log.err("could not match string {s} at byte {}", .{string, self.position});
            return error.UnexpectedInput;
         }
      }

      fn matchLineBreak(self: *Self) !void {
         if (!parsing.matchChar(self.input, &self.position, '\n')) {
            log.err("missing line break at byte {}", .{self.position});
            log.info("offending character: '{c}'", .{self.input[self.position]});
            log.info("surrounding characters: {s}", .{self.input[self.position - 5..self.position + 5]});
            return error.MissingLineBreak;
         }
      }

      fn readHeader(self: *Self) !void {
         try self.matchString("CAF ");
         self.archive.version = numbers.readU8(self.input, &self.position);
         try self.matchLineBreak();
      }

      fn readIndexEntry(self: *Self, entry: *Archive.IndexEntry) !void {
         if (self.testString("KATALOG ")) {
            entry.kind = .directory;
         } else if (self.testString("PLIK ")) {
            entry.kind = .file;
         } else {
            return error.InvalidEntryKind;
         }
         const start = self.position;
         while (!self.testChar('\n')) {
            self.position += 1;
         }
         const end = self.position - 1; // ignore \n after filename
         entry.name = try self.allocator.dupe(u8, self.input[start..end]);
      }

      fn readIndex(self: *Self) ![]Archive.File {
         try self.matchString("INDEKS ");
         const n_entries = @as(usize, numbers.readVU64(self.input, &self.position));
         try self.matchLineBreak();

         var n_files: usize = 0;
         var entries = try self.allocator.alloc(Archive.IndexEntry, n_entries);
         for (entries) |*entry| {
            try self.readIndexEntry(entry);
            if (entry.kind == .file) {
               n_files += 1;
            }
         }
         self.archive.index.entries = entries;
         return try self.allocator.alloc(Archive.File, n_files);
      }

      /// Breaks an octet into 8 bytes, big endian.
      fn breakOctet(octet: u64, output: []u8) void {
         output[0] = @truncate(u8, octet >> 56);
         output[1] = @truncate(u8, octet >> 48);
         output[2] = @truncate(u8, octet >> 40);
         output[3] = @truncate(u8, octet >> 32);
         output[4] = @truncate(u8, octet >> 24);
         output[5] = @truncate(u8, octet >> 16);
         output[6] = @truncate(u8, octet >> 8);
         output[7] = @truncate(u8, octet);
      }

      fn readOctet(self: *Self, byte_buffer: []u8) !usize {
         const octet = numbers.readVU64(self.input, &self.position);
         var repeats: usize = 1;
         if (self.testString(" X ")) {
            repeats = numbers.readVU64(self.input, &self.position);
         }
         try self.matchLineBreak();
         var position: usize = 0;
         while (repeats > 0) : (repeats -= 1) {
            breakOctet(octet, byte_buffer[position..byte_buffer.len]);
            position += 8;
         }
         return position;
      }

      fn readFile(self: *Self, file: *Archive.File) !void {
         try self.matchString("ROZMIAR ");
         const file_size = @as(usize, numbers.readVU64(self.input, &self.position));
         try self.matchLineBreak();

         const aligned_file_size = (file_size / 8) * 8;
         var file_data = try self.allocator.alloc(u8, aligned_file_size + 8);
         var position: usize = 0;
         while (position < aligned_file_size) {
            position += try self.readOctet(file_data[position..file_data.len]);
         }
         if (aligned_file_size < file_size) {
            _ = try self.readOctet(file_data[position..file_data.len]);
         }
         file.allocation = file_data;
         file.data = file_data[0..file_size];
      }

      fn readFiles(self: *Self, files: []Archive.File) !void {
         for (files) |*file| {
            try self.readFile(file);
         }
      }

      fn go(self: *Self) !void {
         self.archive.allocator = self.allocator;
         self.input = try self.reader.readAllAlloc(self.allocator, std.math.maxInt(u64));
         defer self.allocator.free(self.input);

         try self.readHeader();
         var files = try self.readIndex();
         try self.readFiles(files);
         self.archive.files = files;
      }
   };
}

/// Number parsing and emission utilities.
const numbers = struct {
   const zero = "zero";

   const ones = [_][]const u8 {
      "jeden",
      "dwa",
      "trzy",
      "cztery",
      "pięć",
      "sześć",
      "siedem",
      "osiem",
      "dziewięć",
   };

   const teens = [_][]const u8 {
      "dziesięć",
      "jedenaście",
      "dwanaście",
      "trzynaście",
      "czternaście",
      "piętnaście",
      "szesnaście",
      "siedemnaście",
      "osiemnaście",
      "dziewiętnaście",
   };

   const irregular_tens = [_][]const u8 {
      "dwadzieścia",
      "trzydzieści",
      "czterdzieści",
   };

   const hundreds = [_][]const u8 {
      "sto",
      "dwieście",
   };

   const regular_tens_suffix = "dziesiąt";

   /// Writes a `u8` (`liczba8`) to the given writer.
   fn writeU8(writer: anytype, number: u8) !void {
      // special case: zero
      if (number == 0) {
         try writer.writeAll(zero);
         return;
      }
      const nones_and_tens = number % 100;
      const nones = number % 10;
      const ntens = number % 100 / 10;
      const nhundreds = number / 100;
      // hundreds
      if (nhundreds > 0)
         try writer.writeAll(hundreds[nhundreds - 1]);
      // separating space
      if (nhundreds > 0 and (ntens > 0 or nones > 0))
         try writer.writeByte(' ');
      // tens
      if (ntens >= 2 and ntens <= 4) {
         try writer.writeAll(irregular_tens[ntens - 2]);
      } else if (ntens > 4) {
         try writer.writeAll(ones[ntens - 1]);
         try writer.writeAll(regular_tens_suffix);
      }
      // separating space
      if (ntens > 1 and nones > 0)
         try writer.writeByte(' ');
      // teens or ones
      if (nones_and_tens >= 10 and nones_and_tens <= 19)
         try writer.writeAll(teens[nones_and_tens - 10])
      else if (nones > 0)
         try writer.writeAll(ones[nones - 1]);
   }

   /// Writes a `u64` (`liczbaZ64`) to the writer.
   fn writeVU64(writer: anytype, number: u64) !void {
      // special case: zero
      if (number == 0) {
         try writeU8(writer, 0);
         return;
      }
      const bytes = [_]u8 {
         @truncate(u8, (number >> 56) & 0xFF),
         @truncate(u8, (number >> 48) & 0xFF),
         @truncate(u8, (number >> 40) & 0xFF),
         @truncate(u8, (number >> 32) & 0xFF),
         @truncate(u8, (number >> 24) & 0xFF),
         @truncate(u8, (number >> 16) & 0xFF),
         @truncate(u8, (number >> 8) & 0xFF),
         @truncate(u8, number & 0xFF),
      };
      var position: usize = 0;
      for (bytes) |byte| {
         if (byte != 0) break;
         position += 1;
      }
      while (position < bytes.len) : (position += 1) {
         try writeU8(writer, bytes[position]);
         if (position < bytes.len - 1)
            try writer.writeAll("<<");
      }
   }

   /// Reads a `u8` (`liczba8`) from the input string.
   fn readU8(input: []const u8, position: *usize) u8 {
      // special case: zero
      if (parsing.matchString(input, position, "zero")) {
         return 0;
      }
      var result: u8 = 0;
      var got_teens = false;
      var got_irregular_tens = false;
      var got_tens = false;
      var got_hundreds = false;
      var got_smaller_than_hundreds = false;
      // hundreds
      inline for (hundreds) |string, index| {
         if (parsing.matchString(input, position, string)) {
            result += (@truncate(u8, index) + 1) * 100;
            got_hundreds = true;
         }
      }
      // skip space after hundreds
      const before_space_before_hundreds = position.*;
      if (got_hundreds and !parsing.matchChar(input, position, ' ')) return result;
      // irregular tens
      inline for (irregular_tens) |string, index| {
         if (parsing.matchString(input, position, string)) {
            result += (@truncate(u8, index) + 2) * 10;
            got_tens = true;
            got_irregular_tens = true;
            got_smaller_than_hundreds = true;
         }
      }
      // regular tens
      if (!got_irregular_tens) {
         inline for (ones[4..9]) |string, index| {
            const previous_position = position.*;
            if (parsing.matchString(input, position, string) and parsing.matchString(input, position, "dziesiąt")) {
               result += (@truncate(u8, index) + 5) * 10;
               got_tens = true;
               got_smaller_than_hundreds = true;
            } else {
               position.* = previous_position;
            }
         }
      }
      // skip space after tens
      if (got_tens and !parsing.matchChar(input, position, ' ')) return result;
      // teens
      inline for (teens) |string, index| {
         if (parsing.matchString(input, position, string)) {
            result += @truncate(u8, index) + 10;
            got_teens = true;
            got_smaller_than_hundreds = true;
         }
      }
      // ones
      if (!got_teens) {
         inline for (ones) |string, index| {
            if (parsing.matchString(input, position, string)) {
               result += @truncate(u8, index) + 1;
               got_smaller_than_hundreds = true;
            }
         }
      }
      if (!got_smaller_than_hundreds)
         position.* = before_space_before_hundreds;
      return result;
   }

   /// Reads a `u64` (`liczbaZ64`) from the input string.
   fn readVU64(input: []const u8, position: *usize) u64 {
      var result: u64 = 0;
      while (true) {
         result = (result << 8) | readU8(input, position);
         if (!parsing.matchString(input, position, "<<")) {
            break;
         }
      }
      return result;
   }
};

const test_archive = blk: {
   const ArFile = Archive.File;
   const IndexEntry = Archive.IndexEntry;
   break :blk Archive {
      .version = 1,
      .index = .{
         .entries = &[_]IndexEntry {
            .{ .kind = .file, .name = "hi.txt" },
         },
      },
      .files = &[_]ArFile{
         .{ .data = "Hello, world!" }
      },
   };
};

fn testDirectory() !std.fs.Dir {
   return std.fs.cwd().openDir("test-output", .{});
}

test "write numbers" {
   const test_dir = try testDirectory();
   const file = try test_dir.createFile("numbers.csv", .{});
   const writer = file.writer();

   var i: usize = 0;
   while (i <= 255) : (i += 1) {
      try numbers.writeU8(writer, @truncate(u8, i));
      try writer.writeByte('\n');
   }
}

test "read numbers" {
   const allocator = std.testing.allocator;
   const test_dir = try testDirectory();
   const file = try test_dir.openFile("numbers.csv", .{});
   const reader = file.reader();
   const input = try reader.readAllAlloc(allocator, std.math.maxInt(u64));
   defer allocator.free(input);

   var position: usize = 0;
   var i: usize = 0;
   while (i <= 255) : (i += 1) {
      const n = numbers.readU8(input, &position);
      position += 1; // skip line break
      try std.testing.expect(i == n);
   }
}

test "emit archive" {
   const test_dir = try testDirectory();
   const file = try test_dir.createFile("hello.caf", .{});
   const writer = file.writer();

   try test_archive.write(&writer);
}

test "parse archive" {
   const test_dir = try testDirectory();
   const input_file = try test_dir.openFile("test.caf", .{});
   const reader = input_file.reader();
   test_dir.deleteTree("hello.caf.unpacked") catch {};
   try test_dir.makeDir("hello.caf.unpacked");
   const output_dir = test_dir.openDir("hello.caf.unpacked", .{});

   var parsed_archive = try Archive.read(std.testing.allocator, &reader);
   defer parsed_archive.deinit();

   std.debug.print("version: {}\n", .{parsed_archive.version});
   std.debug.print("index:\n", .{});
   for (parsed_archive.index.entries) |entry| {
      std.debug.print(" - {} {s}\n", .{entry.kind, entry.name});
   }
   std.debug.print("files:\n", .{});
   for (parsed_archive.files) |file, index| {
      std.debug.print(" - {}: {s}\n", .{index, file.data});
   }
}

