const std = @import("std");
const assert = std.debug.assert;
const fitz = @import("fitz");

/// Activity files are usually well under 1 MiB; raise this for long multi-day histories.
const file_size_max = 64 * 1024 * 1024;

// Zig 0.16 "Juicy Main": the first `main` parameter can be
// `std.process.Init`, which hands us a general-purpose allocator, an
// `Io` instance, and pre-parsed args/environ — no manual GPA setup and
// no global std.fs/std.os.argv access needed.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) {
        // Usage errors are user mistakes, not bugs: exit with the
        // conventional status 2 instead of returning an error, which would
        // print an error-return trace that reads like a crash.
        std.debug.print(
            "usage: fitz <file.fit>\n  via build: zig build run -- <file.fit>\n",
            .{},
        );
        std.process.exit(2);
    }
    const path = arguments[1];

    // Zig 0.16 moved file APIs from std.fs to std.Io; readFileAlloc does
    // open+read+close in one call.
    const buffer = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(file_size_max),
    );
    defer allocator.free(buffer);
    assert(buffer.len <= file_size_max);

    var parser = try fitz.Parser.init(allocator, buffer);
    defer parser.deinit();

    const header = parser.header;
    std.debug.print(
        "FIT file: header_size={d} protocol_version={d} profile_version={d} " ++
            "data_size={d} has_crc={}\n\n",
        .{
            header.header_size,
            header.protocol_version,
            header.profile_version,
            header.data_size,
            header.crc != null,
        },
    );

    var data_counts = std.AutoHashMap(u16, u32).init(allocator);
    defer data_counts.deinit();
    var definition_count: u32 = 0;

    // Bounded: every record consumes at least one byte of a data section of at most
    // file_size_max bytes.
    while (try parser.next()) |record| {
        switch (record) {
            .definition => |definition| {
                definition_count += 1;
                std.debug.print(
                    "DEF  local={d} global_msg={d} fields={d} big_endian={}\n",
                    .{
                        definition.local_message_type,
                        definition.global_message_number,
                        definition.fields.len,
                        definition.big_endian,
                    },
                );
            },
            .data => |data| {
                const entry = try data_counts.getOrPutValue(data.global_message_number, 0);
                entry.value_ptr.* += 1;
            },
        }
    }

    std.debug.print("\n{d} definition messages\n", .{definition_count});
    var data_count_total: u64 = 0;
    var iterator = data_counts.iterator();
    while (iterator.next()) |entry| {
        assert(entry.value_ptr.* > 0);
        std.debug.print(
            "global_msg={d}: {d} messages\n",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
        data_count_total += entry.value_ptr.*;
    }
    assert(data_count_total <= buffer.len);
    std.debug.print("{d} data messages total\n", .{data_count_total});
}
