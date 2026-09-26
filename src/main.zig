const std = @import("std");
const assert = std.debug.assert;
const fitz = @import("fitz");

/// Activity files are usually well under 1 MiB; raise this for long multi-day histories.
const file_size_max = 64 * 1024 * 1024;

const usage =
    \\usage: fitz [--dump] <file.fit>
    \\  --dump  print every data message's decoded fields to stdout; well-known
    \\          messages and fields are named, scaled and given units
    \\  via build: zig build run -- [--dump] <file.fit>
    \\
;

/// Prints a global message number as its profile name when one is known, else as the number.
/// It is a `format` method, used through `{f}`, so the stderr summary and the stdout dump
/// share one rule instead of branching at every print site.
const MessageLabel = struct {
    global_message_number: u16,

    pub fn format(self: MessageLabel, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const name = fitz.profile.message_name(self.global_message_number) orelse
            return writer.print("{d}", .{self.global_message_number});
        assert(name.len > 0);
        try writer.writeAll(name);
    }
};

const RecordCounts = struct {
    definition: u32 = 0,
    /// Data messages whose timestamp was rebuilt from a compressed header.
    compressed_timestamp: u32 = 0,
};

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
    const record_counts = try records_process(&parser, dump_writer, &data_counts);
    if (dump_writer) |writer| try writer.flush();

    counts_print(&record_counts, &data_counts, buffer.len);
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

fn records_process(
    parser: *fitz.Parser,
    dump_writer: ?*std.Io.Writer,
    data_counts: *std.AutoHashMap(u16, u32),
) !RecordCounts {
    assert(data_counts.count() == 0);
    var record_counts = RecordCounts{};

    // Bounded: every record consumes at least one byte of a data section of at most
    // file_size_max bytes.
    while (try parser.next()) |record| {
        switch (record) {
            .definition => |definition| {
                record_counts.definition += 1;
                std.debug.print(
                    "DEF  local={d} global_msg={f} fields={d} big_endian={}\n",
                    .{
                        definition.local_message_type,
                        MessageLabel{ .global_message_number = definition.global_message_number },
                        definition.fields.len,
                        definition.big_endian,
                    },
                );
            },
            .data => |data| {
                const entry = try data_counts.getOrPutValue(data.global_message_number, 0);
                entry.value_ptr.* += 1;
                if (data.compressed_timestamp != null) record_counts.compressed_timestamp += 1;
                if (dump_writer) |writer| try data_message_write(writer, &data);
            },
        }
    }
    // The parser rejects a data message whose local type was never defined.
    assert(record_counts.definition > 0 or data_counts.count() == 0);
    return record_counts;
}

fn counts_print(
    record_counts: *const RecordCounts,
    data_counts: *const std.AutoHashMap(u16, u32),
    buffer_len: usize,
) void {
    std.debug.print("\n{d} definition messages\n", .{record_counts.definition});
    var data_count_total: u64 = 0;
    var iterator = data_counts.iterator();
    while (iterator.next()) |entry| {
        assert(entry.value_ptr.* > 0);
        std.debug.print(
            "global_msg={f}: {d} messages\n",
            .{ MessageLabel{ .global_message_number = entry.key_ptr.* }, entry.value_ptr.* },
        );
        data_count_total += entry.value_ptr.*;
    }
    assert(data_count_total <= buffer_len);
    assert(record_counts.compressed_timestamp <= data_count_total);
    std.debug.print(
        "{d} data messages total, {d} with a compressed timestamp\n",
        .{ data_count_total, record_counts.compressed_timestamp },
    );
}

/// One line per data message: `DATA local=L global_msg=G field=value ...`, where G and each
/// field are named when the profile knows them.
fn data_message_write(writer: *std.Io.Writer, data: *const fitz.DataMessage) !void {
    try writer.print("DATA local={d} global_msg={f}", .{
        data.local_message_type,
        MessageLabel{ .global_message_number = data.global_message_number },
    });
    // A compressed header's timestamp isn't one of the message's fields, so it is printed
    // first, the way a normal message's field 253 would be.
    if (data.compressed_timestamp) |timestamp| try writer.print(" timestamp={d}s", .{timestamp});

    var fields_written: usize = 0;
    var iterator = data.fields_iterator();
    // Bounded by the definition's field count, at most 255.
    while (iterator.next()) |field| {
        try writer.writeByte(' ');
        try field_write(writer, &field, data.global_message_number);
        fields_written += 1;
    }
    assert(fields_written == data.fields.len);
    try writer.writeByte('\n');
}

/// `name=value` for a single element, `name=[a,b,...]` for an array, followed by the units.
/// A field the profile doesn't know is printed by number, raw and without units.
fn field_write(writer: *std.Io.Writer, field: *const fitz.Field, global_message_number: u16) !void {
    const element_count = field.element_count();
    assert(element_count >= 1);
    const field_profile = fitz.profile.field_profile(
        global_message_number,
        field.field_definition_number,
    );
    const profile_pointer: ?*const fitz.profile.FieldProfile =
        if (field_profile) |*profile| profile else null;

    if (field_profile) |profile| {
        try writer.writeAll(profile.name);
    } else {
        try writer.print("{d}", .{field.field_definition_number});
    }
    try writer.writeByte('=');

    if (element_count == 1) {
        // A single "no data" value gets no units: `heart_rate=-`, not `heart_rate=-bpm`.
        const value = field.element(0) orelse return writer.writeByte('-');
        try element_write(writer, value, profile_pointer);
    } else {
        try writer.writeByte('[');
        var index: u8 = 0;
        while (index < element_count) : (index += 1) {
            if (index > 0) try writer.writeByte(',');
            try element_write(writer, field.element(index), profile_pointer);
        }
        try writer.writeByte(']');
    }
    if (field_profile) |profile| try writer.writeAll(profile.units);
}

/// Invalid (sentinel) elements print as `-`, so "no data" never looks like a real number.
/// A scaled field prints its physical value; everything else prints the raw value exactly.
fn element_write(
    writer: *std.Io.Writer,
    value: ?fitz.Value,
    field_profile: ?*const fitz.profile.FieldProfile,
) !void {
    const present = value orelse return writer.writeByte('-');
    if (field_profile) |profile| {
        if (profile.is_scaled()) {
            // A string or byte value has nothing to scale, so it falls through to the raw form.
            if (profile.scaled(present)) |scaled| return writer.print("{d}", .{scaled});
        }
    }
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

test "element_write: every representation and the invalid marker" {
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
        try element_write(&writer, case.value, null);
        try testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

const test_fields = [_]fitz.FieldDefinition{
    .{ .field_definition_number = 253, .size = 4, .base_type = .uint32 },
    .{ .field_definition_number = 5, .size = 3, .base_type = .uint8 },
    .{ .field_definition_number = 7, .size = 2, .base_type = .sint16 },
    .{ .field_definition_number = 200, .size = 1, .base_type = .uint8 },
};
const test_raw = [_]u8{ 1, 0, 0, 0, 7, 0xFF, 9, 0xFF, 0x7F, 42 };

test "data_message_write: an unknown message prints numbers and raw values" {
    const data = fitz.DataMessage{
        .local_message_type = 1,
        .global_message_number = 325,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = &test_fields,
        .raw = &test_raw,
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data);
    try testing.expectEqualStrings(
        "DATA local=1 global_msg=325 253=1 5=[7,-,9] 7=- 200=42\n",
        writer.buffered(),
    );
}

test "data_message_write: a known message prints names, scaled values and units" {
    // Same bytes as a record message: 253 is timestamp (s), 5 is distance (scale 100, m),
    // 7 is power (W, here "no data"), and 200 is not in the table.
    const data = fitz.DataMessage{
        .local_message_type = 1,
        .global_message_number = 20,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = &test_fields,
        .raw = &test_raw,
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data);
    try testing.expectEqualStrings(
        "DATA local=1 global_msg=record timestamp=1s distance=[0.07,-,0.09]m power=- 200=42\n",
        writer.buffered(),
    );
}

test "element_write: scaled values, and a string in a scaled field" {
    const altitude = fitz.profile.field_profile(20, 78).?;
    var buffer: [64]u8 = undefined;

    var writer = std.Io.Writer.fixed(&buffer);
    try element_write(&writer, .{ .unsigned = 6460 }, &altitude);
    try testing.expectEqualStrings("792", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try element_write(&writer, .{ .string = "odd" }, &altitude);
    try testing.expectEqualStrings("\"odd\"", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try element_write(&writer, null, &altitude);
    try testing.expectEqualStrings("-", writer.buffered());
}

test "MessageLabel: name when known, number otherwise" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f} {f}", .{
        MessageLabel{ .global_message_number = 18 },
        MessageLabel{ .global_message_number = std.math.maxInt(u16) },
    });
    try testing.expectEqualStrings("session 65535", writer.buffered());
}

test "data_message_write: a message with no fields" {
    const data = fitz.DataMessage{
        .local_message_type = 0,
        .global_message_number = 0,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = &.{},
        .raw = &.{},
    };
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data);
    try testing.expectEqualStrings("DATA local=0 global_msg=file_id\n", writer.buffered());
}

test "data_message_write: a compressed timestamp is printed before the fields" {
    const fields = [_]fitz.FieldDefinition{
        .{ .field_definition_number = 3, .size = 1, .base_type = .uint8 },
    };
    const data = fitz.DataMessage{
        .local_message_type = 1,
        .global_message_number = 20,
        .big_endian = false,
        .compressed_timestamp = 1147594040,
        .fields = &fields,
        .raw = &.{146},
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data);
    try testing.expectEqualStrings(
        "DATA local=1 global_msg=record timestamp=1147594040s heart_rate=146bpm\n",
        writer.buffered(),
    );
}
