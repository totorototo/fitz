const std = @import("std");
const assert = std.debug.assert;
const fitz = @import("fitz");

/// Activity files are usually well under 1 MiB; raise this for long multi-day histories.
const file_size_max = 64 * 1024 * 1024;

const usage =
    \\usage: fitz [--dump] <file.fit>
    \\  --dump  print every data message's decoded fields to stdout
    \\  via build: zig build run -- [--dump] <file.fit>
    \\
;

const Options = struct {
    dump: bool,
    path: []const u8,
};

// Zig 0.16 "Juicy Main": the first `main` parameter can be
// `std.process.Init`, which hands us a general-purpose allocator, an
// `Io` instance, and pre-parsed args/environ — no manual GPA setup and
// no global std.fs/std.os.argv access needed.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const options = options_parse(arguments) orelse {
        // Usage errors are user mistakes, not bugs: exit with the
        // conventional status 2 instead of returning an error, which would
        // print an error-return trace that reads like a crash.
        std.debug.print(usage, .{});
        std.process.exit(2);
    };

    // Zig 0.16 moved file APIs from std.fs to std.Io; readFileAlloc does
    // open+read+close in one call.
    const buffer = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.path,
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

    // The dump goes to stdout so it can be piped or redirected on its own; the header and
    // summary stay on stderr.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const dump_writer: ?*std.Io.Writer = if (options.dump) &stdout_writer.interface else null;

    var data_counts = std.AutoHashMap(u16, u32).init(allocator);
    defer data_counts.deinit();
    const definition_count = try records_process(&parser, dump_writer, &data_counts);
    if (dump_writer) |writer| try writer.flush();

    counts_print(definition_count, &data_counts, buffer.len);
}

/// Accepts exactly `<path>` or `--dump <path>`. Returns null on any other shape.
fn options_parse(arguments: []const [:0]const u8) ?Options {
    const options: Options = switch (arguments.len) {
        2 => .{ .dump = false, .path = arguments[1] },
        3 => if (std.mem.eql(u8, arguments[1], "--dump"))
            .{ .dump = true, .path = arguments[2] }
        else
            return null,
        else => return null,
    };
    // An empty path, or a flag in the path position, is a usage mistake, not a file name.
    if (options.path.len == 0) return null;
    if (std.mem.startsWith(u8, options.path, "--")) return null;
    assert(options.path.ptr == arguments[arguments.len - 1].ptr);
    return options;
}

/// Returns the number of definition messages seen.
fn records_process(
    parser: *fitz.Parser,
    dump_writer: ?*std.Io.Writer,
    data_counts: *std.AutoHashMap(u16, u32),
) !u32 {
    assert(data_counts.count() == 0);
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
                if (dump_writer) |writer| try data_message_write(writer, &data);
            },
        }
    }
    return definition_count;
}

fn counts_print(
    definition_count: u32,
    data_counts: *const std.AutoHashMap(u16, u32),
    buffer_len: usize,
) void {
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
    assert(data_count_total <= buffer_len);
    std.debug.print("{d} data messages total\n", .{data_count_total});
}

/// One line per data message: `DATA local=L global_msg=G number=value ...`.
fn data_message_write(writer: *std.Io.Writer, data: *const fitz.DataMessage) !void {
    try writer.print("DATA local={d} global_msg={d}", .{
        data.local_message_type,
        data.global_message_number,
    });

    var fields_written: usize = 0;
    var iterator = data.fields_iterator();
    // Bounded by the definition's field count, at most 255.
    while (iterator.next()) |field| {
        try writer.writeByte(' ');
        try field_write(writer, &field);
        fields_written += 1;
    }
    assert(fields_written == data.fields.len);
    try writer.writeByte('\n');
}

/// `number=value` for a single element, `number=[a,b,...]` for an array.
fn field_write(writer: *std.Io.Writer, field: *const fitz.Field) !void {
    const element_count = field.element_count();
    assert(element_count >= 1);

    try writer.print("{d}=", .{field.field_definition_number});
    if (element_count == 1) return value_write(writer, field.element(0));

    try writer.writeByte('[');
    var index: u8 = 0;
    while (index < element_count) : (index += 1) {
        if (index > 0) try writer.writeByte(',');
        try value_write(writer, field.element(index));
    }
    try writer.writeByte(']');
}

/// Invalid (sentinel) elements print as `-`, so "no data" never looks like a real number.
fn value_write(writer: *std.Io.Writer, value: ?fitz.Value) !void {
    const present = value orelse return writer.writeByte('-');
    switch (present) {
        .unsigned => |unsigned| try writer.print("{d}", .{unsigned}),
        .signed => |signed| try writer.print("{d}", .{signed}),
        .float => |float| try writer.print("{d}", .{float}),
        .string => |string| try writer.print("\"{s}\"", .{string}),
        .bytes => |bytes| try writer.print("0x{x}", .{bytes}),
    }
}

const testing = std.testing;

test "options_parse" {
    const plain = options_parse(&.{ "fitz", "a.fit" }).?;
    try testing.expect(!plain.dump);
    try testing.expectEqualStrings("a.fit", plain.path);

    const dump = options_parse(&.{ "fitz", "--dump", "a.fit" }).?;
    try testing.expect(dump.dump);
    try testing.expectEqualStrings("a.fit", dump.path);

    try testing.expectEqual(@as(?Options, null), options_parse(&.{"fitz"}));
    try testing.expectEqual(@as(?Options, null), options_parse(&.{ "fitz", "" }));
    try testing.expectEqual(@as(?Options, null), options_parse(&.{ "fitz", "--dump" }));
    try testing.expectEqual(@as(?Options, null), options_parse(&.{ "fitz", "-d", "a.fit" }));
    try testing.expectEqual(@as(?Options, null), options_parse(&.{ "fitz", "a.fit", "--dump" }));
    try testing.expectEqual(
        @as(?Options, null),
        options_parse(&.{ "fitz", "--dump", "a.fit", "b.fit" }),
    );
}

test "value_write: every representation and the invalid marker" {
    var buffer: [64]u8 = undefined;
    const cases = [_]struct { value: ?fitz.Value, expected: []const u8 }{
        .{ .value = null, .expected = "-" },
        .{ .value = .{ .unsigned = std.math.maxInt(u64) }, .expected = "18446744073709551615" },
        .{ .value = .{ .signed = -100 }, .expected = "-100" },
        .{ .value = .{ .float = 0.5 }, .expected = "0.5" },
        .{ .value = .{ .string = "hi" }, .expected = "\"hi\"" },
        .{ .value = .{ .bytes = &.{ 0xDE, 0x01 } }, .expected = "0xde01" },
    };
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buffer);
        try value_write(&writer, case.value);
        try testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "data_message_write: scalars, arrays and invalid elements" {
    const fields = [_]fitz.FieldDefinition{
        .{ .field_definition_number = 253, .size = 4, .base_type = .uint32 },
        .{ .field_definition_number = 5, .size = 3, .base_type = .uint8 },
        .{ .field_definition_number = 7, .size = 2, .base_type = .sint16 },
    };
    const data = fitz.DataMessage{
        .local_message_type = 1,
        .global_message_number = 20,
        .big_endian = false,
        .fields = &fields,
        .raw = &.{ 1, 0, 0, 0, 7, 0xFF, 9, 0xFF, 0x7F },
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data);
    try testing.expectEqualStrings(
        "DATA local=1 global_msg=20 253=1 5=[7,-,9] 7=-\n",
        writer.buffered(),
    );
}

test "data_message_write: a message with no fields" {
    const data = fitz.DataMessage{
        .local_message_type = 0,
        .global_message_number = 0,
        .big_endian = false,
        .fields = &.{},
        .raw = &.{},
    };
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data);
    try testing.expectEqualStrings("DATA local=0 global_msg=0\n", writer.buffered());
}
