const std = @import("std");
const assert = std.debug.assert;
const fitz = @import("fitz");

/// Activity files are usually well under 1 MiB; raise this for long multi-day histories.
const file_size_max = 64 * 1024 * 1024;

const usage =
    \\usage: fitz [--dump [--all]] <file.fit>
    \\  --dump  print each data message to stdout as a block, one field per line: the
    \\          fields the built-in profile knows and that hold data, named, scaled, with
    \\          units, dates in ISO 8601 and positions in degrees
    \\  --all   with --dump, print one line per message with every field instead: "no data"
    \\          as -, unknown fields by number, dates and positions as stored, and
    \\          developer fields as dev:<developer_data_index>:<field_number>=0x<bytes>
    \\  via build: zig build run -- [--dump [--all]] <file.fit>
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
    /// Data messages that carry at least one developer field.
    developer_fields: u32 = 0,
};

const DumpDetail = enum {
    /// Known fields with data, converted for reading.
    readable,
    /// Every field, as stored.
    all,
};

const Dump = struct {
    writer: *std.Io.Writer,
    detail: DumpDetail,
};

const Options = struct {
    /// Null when no dump was asked for, so `--all` without `--dump` can't be represented.
    dump: ?DumpDetail,
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
    // Parser.init only succeeds once both CRCs check out, so "ok" is a statement of fact here.
    const header_crc_status: []const u8 = if (header.crc != null) "ok" else "absent";
    std.debug.print(
        "FIT file: header_size={d} protocol_version={d} profile_version={d} " ++
            "data_size={d} header_crc={s} file_crc=ok(0x{x:0>4})\n\n",
        .{
            header.header_size,
            header.protocol_version,
            header.profile_version,
            header.data_size,
            header_crc_status,
            parser.file_crc,
        },
    );

    // The dump goes to stdout so it can be piped or redirected on its own; the header and
    // summary stay on stderr.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const dump: ?Dump = if (options.dump) |detail|
        .{ .writer = &stdout_writer.interface, .detail = detail }
    else
        null;

    var data_counts = std.AutoHashMap(u16, u32).init(allocator);
    defer data_counts.deinit();
    const record_counts = try records_process(&parser, dump, &data_counts);
    if (dump) |active| try active.writer.flush();

    counts_print(&record_counts, &data_counts, buffer.len);
}

/// Accepts `[--dump [--all]] <path>`, with each flag at most once, in either order. Returns
/// null on any other shape.
fn options_parse(arguments: []const [:0]const u8) ?Options {
    if (arguments.len < 2 or arguments.len > 4) return null;
    const path = arguments[arguments.len - 1];

    var dump = false;
    var all = false;
    // Bounded: at most two flags, by the length check above.
    for (arguments[1 .. arguments.len - 1]) |flag| {
        if (std.mem.eql(u8, flag, "--dump") and !dump) {
            dump = true;
        } else if (std.mem.eql(u8, flag, "--all") and !all) {
            all = true;
        } else {
            return null;
        }
    }
    // `--all` only changes what `--dump` prints.
    if (all and !dump) return null;
    // An empty path, or a flag in the path position, is a usage mistake, not a file name.
    if (path.len == 0) return null;
    if (std.mem.startsWith(u8, path, "--")) return null;

    const options = Options{
        .dump = if (!dump) null else if (all) .all else .readable,
        .path = path,
    };
    assert(options.path.ptr == arguments[arguments.len - 1].ptr);
    return options;
}

fn records_process(
    parser: *fitz.Parser,
    dump: ?Dump,
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
                    "DEF  local={d} global_msg={f} fields={d} developer_fields={d} " ++
                        "big_endian={}\n",
                    .{
                        definition.local_message_type,
                        MessageLabel{ .global_message_number = definition.global_message_number },
                        definition.fields.len,
                        definition.developer_fields.len,
                        definition.big_endian,
                    },
                );
            },
            .data => |data| {
                const entry = try data_counts.getOrPutValue(data.global_message_number, 0);
                entry.value_ptr.* += 1;
                if (data.compressed_timestamp != null) record_counts.compressed_timestamp += 1;
                if (data.developer_fields.len > 0) record_counts.developer_fields += 1;
                if (dump) |active| try data_message_write(active.writer, &data, active.detail);
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
    assert(record_counts.developer_fields <= data_count_total);
    std.debug.print(
        "{d} data messages total, {d} with a compressed timestamp, {d} with developer fields\n",
        .{
            data_count_total,
            record_counts.compressed_timestamp,
            record_counts.developer_fields,
        },
    );
}

/// Readable detail prints a block per message; full detail prints one line per message, so
/// the full dump stays easy to grep and to process line by line.
fn data_message_write(
    writer: *std.Io.Writer,
    data: *const fitz.DataMessage,
    detail: DumpDetail,
) !void {
    switch (detail) {
        .readable => try data_message_block_write(writer, data),
        .all => try data_message_line_write(writer, data),
    }
}

/// Every name in the profile fits this column, which a test checks, so values line up.
const name_column_width = 22;

/// A heading with the message name, then one indented `name  value units` line per field
/// the profile knows and that holds data, then a blank line. A message with nothing to show
/// is skipped entirely; the summary still counts it. Developer fields are left out: without
/// their field_description they have no name, type or units to show.
fn data_message_block_write(writer: *std.Io.Writer, data: *const fitz.DataMessage) !void {
    var fields_shown: usize = 0;
    var iterator = data.fields_iterator();
    // Bounded by the definition's field count, at most 255.
    while (iterator.next()) |field| {
        if (field_is_readable(&field, data.global_message_number)) fields_shown += 1;
    }
    assert(fields_shown <= data.fields.len);
    if (fields_shown == 0 and data.compressed_timestamp == null) return;

    const label = MessageLabel{ .global_message_number = data.global_message_number };
    try writer.print("{f}\n", .{label});
    // A compressed header's timestamp isn't one of the message's fields, so it is printed
    // first, where a normal message's field 253 usually is.
    if (data.compressed_timestamp) |timestamp| {
        try writer.print("  {s:<[1]}", .{ "timestamp", name_column_width });
        try date_time_write(writer, timestamp, .utc);
        try writer.writeByte('\n');
    }

    var fields_written: usize = 0;
    iterator = data.fields_iterator();
    while (iterator.next()) |field| {
        if (!field_is_readable(&field, data.global_message_number)) continue;
        const profile = fitz.profile.field_profile(
            data.global_message_number,
            field.field_definition_number,
        ).?;
        assert(profile.name.len < name_column_width);
        try writer.print("  {s:<[1]}", .{ profile.name, name_column_width });
        try field_value_write(writer, &field, &profile, .readable);
        try writer.writeByte('\n');
        fields_written += 1;
    }
    assert(fields_written == fields_shown);
    try writer.writeByte('\n');
}

/// Readable detail shows a field only when the profile knows it and it holds data.
fn field_is_readable(field: *const fitz.Field, global_message_number: u16) bool {
    const known = fitz.profile.field_profile(
        global_message_number,
        field.field_definition_number,
    ) != null;
    return known and field_has_data(field);
}

/// `DATA local=L global_msg=G field=value ... dev:I:N=0x...` with every field, as stored.
fn data_message_line_write(writer: *std.Io.Writer, data: *const fitz.DataMessage) !void {
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
        const field_profile = fitz.profile.field_profile(
            data.global_message_number,
            field.field_definition_number,
        );
        try writer.writeByte(' ');
        if (field_profile) |profile| {
            try writer.writeAll(profile.name);
        } else {
            try writer.print("{d}", .{field.field_definition_number});
        }
        try writer.writeByte('=');
        const profile_pointer = if (field_profile) |*profile| profile else null;
        try field_value_write(writer, &field, profile_pointer, .all);
        fields_written += 1;
    }
    assert(fields_written == data.fields.len);
    try developer_fields_write(writer, data);
    try writer.writeByte('\n');
}

/// Developer fields as their stored bytes, keyed by developer data index then field number.
/// Their base type is in a field_description message, so there is no sentinel to show as `-`
/// and no byte order to apply.
fn developer_fields_write(writer: *std.Io.Writer, data: *const fitz.DataMessage) !void {
    var fields_written: usize = 0;
    var iterator = data.developer_fields_iterator();
    // Bounded by the definition's developer field count, at most 255.
    while (iterator.next()) |field| {
        assert(field.raw.len >= 1);
        try writer.print(" dev:{d}:{d}=0x{x}", .{
            field.developer_data_index,
            field.field_number,
            field.raw,
        });
        fields_written += 1;
    }
    assert(fields_written == data.developer_fields.len);
}

/// True when at least one element isn't the base type's "no data" sentinel.
fn field_has_data(field: *const fitz.Field) bool {
    const element_count = field.element_count();
    assert(element_count >= 1);
    var index: u8 = 0;
    while (index < element_count) : (index += 1) {
        if (field.element(index) != null) return true;
    }
    return false;
}

/// The value for a single element, `[a,b,...]` for an array, then the units: appended
/// directly in full detail (`157bpm`), after a space in readable detail (`157 bpm`). A field
/// the profile doesn't know is printed raw and without units.
fn field_value_write(
    writer: *std.Io.Writer,
    field: *const fitz.Field,
    field_profile: ?*const fitz.profile.FieldProfile,
    detail: DumpDetail,
) !void {
    const element_count = field.element_count();
    assert(element_count >= 1);

    if (element_count == 1) {
        // A single "no data" value gets no units: `heart_rate=-`, not `heart_rate=-bpm`.
        const value = field.element(0) orelse return writer.writeByte('-');
        try element_write(writer, value, field_profile, detail);
    } else {
        try writer.writeByte('[');
        var index: u8 = 0;
        while (index < element_count) : (index += 1) {
            if (index > 0) try writer.writeByte(',');
            try element_write(writer, field.element(index), field_profile, detail);
        }
        try writer.writeByte(']');
    }

    const profile = field_profile orelse return;
    switch (detail) {
        .all => try writer.writeAll(profile.units),
        // A converted date or position carries its own notation instead of the raw units.
        .readable => if (profile.kind == .number and profile.units.len > 0) {
            try writer.print(" {s}", .{profile.units});
        },
    }
}

/// Invalid (sentinel) elements print as `-`, so "no data" never looks like a real number.
/// In readable detail, dates and positions are converted; a scaled field prints its physical
/// value; everything else prints the raw value exactly.
fn element_write(
    writer: *std.Io.Writer,
    value: ?fitz.Value,
    field_profile: ?*const fitz.profile.FieldProfile,
    detail: DumpDetail,
) !void {
    const present = value orelse return writer.writeByte('-');
    if (field_profile) |profile| {
        if (detail == .readable and profile.kind != .number) {
            if (try converted_write(writer, present, profile.kind)) return;
        }
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

/// Writes a date or a position in readable form. Returns false, having written nothing, when
/// the file stored the field with a base type that doesn't fit its kind, so the caller prints
/// the raw value instead of a wrong conversion.
fn converted_write(
    writer: *std.Io.Writer,
    value: fitz.Value,
    kind: fitz.profile.Kind,
) std.Io.Writer.Error!bool {
    switch (kind) {
        .number => unreachable,
        .date_time, .local_date_time => {
            if (value != .unsigned) return false;
            const date_time = std.math.cast(u32, value.unsigned) orelse return false;
            const zone: Zone = if (kind == .date_time) .utc else .local;
            try date_time_write(writer, date_time, zone);
        },
        .semicircles => {
            if (value != .signed) return false;
            const degrees = fitz.profile.semicircles_degrees(@floatFromInt(value.signed));
            try writer.print("{d:.6}°", .{degrees});
        },
    }
    return true;
}

const Zone = enum { utc, local };

/// ISO 8601, with a `Z` suffix for UTC and none for local time. A value below
/// `date_time_absolute_min` is time since power-on, not a date, so it prints as seconds.
fn date_time_write(writer: *std.Io.Writer, date_time: u32, zone: Zone) !void {
    const unix_s = fitz.profile.date_time_unix_s(date_time) orelse
        return writer.print("{d}s", .{date_time});
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = unix_s };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    assert(year_day.year >= 1998 and year_day.year <= 2126);

    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
    switch (zone) {
        .utc => try writer.writeByte('Z'),
        .local => {},
    }
}

const testing = std.testing;

test "options_parse" {
    const plain = options_parse(&.{ "fitz", "a.fit" }).?;
    try testing.expectEqual(@as(?DumpDetail, null), plain.dump);
    try testing.expectEqualStrings("a.fit", plain.path);

    const dump = options_parse(&.{ "fitz", "--dump", "a.fit" }).?;
    try testing.expectEqual(@as(?DumpDetail, .readable), dump.dump);
    try testing.expectEqualStrings("a.fit", dump.path);

    const all = options_parse(&.{ "fitz", "--dump", "--all", "a.fit" }).?;
    try testing.expectEqual(@as(?DumpDetail, .all), all.dump);
    const all_swapped = options_parse(&.{ "fitz", "--all", "--dump", "a.fit" }).?;
    try testing.expectEqual(@as(?DumpDetail, .all), all_swapped.dump);

    // `--all` alone, repeated flags, and a flag as the path.
    try testing.expectEqual(@as(?Options, null), options_parse(&.{ "fitz", "--all", "a.fit" }));
    const dump_twice = options_parse(&.{ "fitz", "--dump", "--dump", "a.fit" });
    try testing.expectEqual(@as(?Options, null), dump_twice);
    const all_twice = options_parse(&.{ "fitz", "--all", "--all", "a.fit" });
    try testing.expectEqual(@as(?Options, null), all_twice);
    const flag_path = options_parse(&.{ "fitz", "--dump", "--all" });
    try testing.expectEqual(@as(?Options, null), flag_path);
    const too_many = options_parse(&.{ "fitz", "--dump", "--all", "--all", "a.fit" });
    try testing.expectEqual(@as(?Options, null), too_many);

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
        try element_write(&writer, case.value, null, .all);
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
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .all);
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
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .all);
    try testing.expectEqualStrings(
        "DATA local=1 global_msg=record timestamp=1s distance=[0.07,-,0.09]m power=- 200=42\n",
        writer.buffered(),
    );
}

test "element_write: scaled values, and a string in a scaled field" {
    const altitude = fitz.profile.field_profile(20, 78).?;
    var buffer: [64]u8 = undefined;

    var writer = std.Io.Writer.fixed(&buffer);
    try element_write(&writer, .{ .unsigned = 6460 }, &altitude, .readable);
    try testing.expectEqualStrings("792", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try element_write(&writer, .{ .string = "odd" }, &altitude, .readable);
    try testing.expectEqualStrings("\"odd\"", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try element_write(&writer, null, &altitude, .readable);
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
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .all);
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
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .all);
    try testing.expectEqualStrings(
        "DATA local=1 global_msg=record timestamp=1147594040s heart_rate=146bpm\n",
        writer.buffered(),
    );
}

test "data_message_write: readable detail hides empty and unknown fields and converts" {
    const fields = [_]fitz.FieldDefinition{
        .{ .field_definition_number = 253, .size = 4, .base_type = .uint32 },
        .{ .field_definition_number = 0, .size = 4, .base_type = .sint32 },
        .{ .field_definition_number = 1, .size = 4, .base_type = .sint32 },
        .{ .field_definition_number = 3, .size = 1, .base_type = .uint8 },
        .{ .field_definition_number = 7, .size = 2, .base_type = .uint16 },
        .{ .field_definition_number = 200, .size = 1, .base_type = .uint8 },
        .{ .field_definition_number = 78, .size = 4, .base_type = .uint32 },
    };
    var raw: [24]u8 = undefined;
    std.mem.writeInt(u32, raw[0..4], 1159179174, .little); // timestamp
    std.mem.writeInt(i32, raw[4..8], 537182079, .little); // position_lat
    std.mem.writeInt(i32, raw[8..12], -9651251, .little); // position_long
    raw[12] = 157; // heart_rate
    std.mem.writeInt(u16, raw[13..15], 0xFFFF, .little); // power: no data, hidden
    raw[15] = 42; // unknown field 200, hidden
    std.mem.writeInt(u32, raw[16..20], 6460, .little); // enhanced_altitude
    std.mem.writeInt(u32, raw[20..24], 0, .little); // Padding outside the message.

    const data = fitz.DataMessage{
        .local_message_type = 3,
        .global_message_number = 20,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = &fields,
        .raw = raw[0..20],
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .readable);
    try testing.expectEqualStrings(
        \\record
        \\  timestamp             2026-09-24T10:12:54Z
        \\  position_lat          45.026082°
        \\  position_long         -0.808959°
        \\  heart_rate            157 bpm
        \\  enhanced_altitude     792 m
        \\
        \\
    , writer.buffered());

    // The same message in full detail keeps every field, raw dates and positions.
    writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .all);
    try testing.expectEqualStrings(
        "DATA local=3 global_msg=record timestamp=1159179174s " ++
            "position_lat=537182079semicircles position_long=-9651251semicircles " ++
            "heart_rate=157bpm power=- 200=42 enhanced_altitude=792m\n",
        writer.buffered(),
    );
}

test "data_message_write: a readable compressed timestamp is a date" {
    const data = fitz.DataMessage{
        .local_message_type = 1,
        .global_message_number = 325,
        .big_endian = false,
        .compressed_timestamp = 1159179174,
        .fields = &.{},
        .raw = &.{},
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .readable);
    try testing.expectEqualStrings(
        \\325
        \\  timestamp             2026-09-24T10:12:54Z
        \\
        \\
    , writer.buffered());
}

test "field_has_data: all, some or none of the elements" {
    const empty = fitz.Field{
        .field_definition_number = 116,
        .base_type = .uint16,
        .endian = .little,
        .raw = &.{ 0xFF, 0xFF, 0xFF, 0xFF },
    };
    try testing.expect(!field_has_data(&empty));
    const partial = fitz.Field{
        .field_definition_number = 116,
        .base_type = .uint16,
        .endian = .little,
        .raw = &.{ 0xFF, 0xFF, 1, 0 },
    };
    try testing.expect(field_has_data(&partial));
    const empty_string = fitz.Field{
        .field_definition_number = 110,
        .base_type = .string,
        .endian = .little,
        .raw = &.{ 0, 0 },
    };
    try testing.expect(!field_has_data(&empty_string));
}

test "date_time_write: UTC, local, bounds and time since power-on" {
    const cases = [_]struct { date_time: u32, zone: Zone, expected: []const u8 }{
        .{ .date_time = 1159179174, .zone = .utc, .expected = "2026-09-24T10:12:54Z" },
        .{ .date_time = 1159179174, .zone = .local, .expected = "2026-09-24T10:12:54" },
        .{ .date_time = 1147594034, .zone = .utc, .expected = "2026-05-13T08:07:14Z" },
        // The first absolute date_time, and the largest valid one (0xFFFFFFFF is "no data").
        .{ .date_time = 0x10000000, .zone = .utc, .expected = "1998-07-03T21:24:16Z" },
        .{ .date_time = 0xFFFFFFFE, .zone = .utc, .expected = "2126-02-06T06:28:14Z" },
        // Just below the threshold: seconds since the device powered on.
        .{ .date_time = 0x0FFFFFFF, .zone = .utc, .expected = "268435455s" },
        .{ .date_time = 0, .zone = .local, .expected = "0s" },
    };
    var buffer: [32]u8 = undefined;
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buffer);
        try date_time_write(&writer, case.date_time, case.zone);
        try testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "converted_write: a base type that doesn't fit the kind falls back to raw" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expect(!try converted_write(&writer, .{ .signed = 5 }, .date_time));
    try testing.expect(!try converted_write(&writer, .{ .unsigned = 1 << 32 }, .date_time));
    try testing.expect(!try converted_write(&writer, .{ .unsigned = 5 }, .semicircles));
    try testing.expect(!try converted_write(&writer, .{ .string = "x" }, .semicircles));
    try testing.expectEqualStrings("", writer.buffered());

    try testing.expect(try converted_write(&writer, .{ .signed = 1 << 30 }, .semicircles));
    try testing.expectEqualStrings("90.000000°", writer.buffered());
}

test "data_message_write: a readable message with nothing to show is skipped" {
    const fields = [_]fitz.FieldDefinition{
        .{ .field_definition_number = 7, .size = 2, .base_type = .uint16 }, // power: no data
        .{ .field_definition_number = 200, .size = 1, .base_type = .uint8 }, // unknown
    };
    const record = fitz.DataMessage{
        .local_message_type = 0,
        .global_message_number = 20,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = &fields,
        .raw = &.{ 0xFF, 0xFF, 42 },
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &record, .readable);
    try testing.expectEqualStrings("", writer.buffered());

    // In full detail the same message is still one line with every field.
    try data_message_write(&writer, &record, .all);
    const line = "DATA local=0 global_msg=record power=- 200=42\n";
    try testing.expectEqualStrings(line, writer.buffered());
}

test "field_value_write: units follow a space in readable detail, but not in full detail" {
    const pair = fitz.Field{
        .field_definition_number = 5,
        .base_type = .uint8,
        .endian = .little,
        .raw = &.{ 7, 0xFF },
    };
    const distance = fitz.profile.field_profile(20, 5).?;
    var buffer: [64]u8 = undefined;

    var writer = std.Io.Writer.fixed(&buffer);
    try field_value_write(&writer, &pair, &distance, .readable);
    try testing.expectEqualStrings("[0.07,-] m", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try field_value_write(&writer, &pair, &distance, .all);
    try testing.expectEqualStrings("[0.07,-]m", writer.buffered());

    // A dimensionless field gets no trailing space.
    const message_index = fitz.profile.field_profile(18, 254).?;
    const index = fitz.Field{
        .field_definition_number = 254,
        .base_type = .uint16,
        .endian = .little,
        .raw = &.{ 0, 0 },
    };
    writer = std.Io.Writer.fixed(&buffer);
    try field_value_write(&writer, &index, &message_index, .readable);
    try testing.expectEqualStrings("0", writer.buffered());
}

test "name_column_width: every profile field name fits, leaving a gap" {
    var message_number: u32 = 0;
    // Bounded: the whole u16 message space times the whole u8 field space.
    while (message_number <= std.math.maxInt(u16)) : (message_number += 1) {
        const global: u16 = @intCast(message_number);
        if (fitz.profile.message_name(global) == null) continue;
        var field_number: u32 = 0;
        while (field_number <= std.math.maxInt(u8)) : (field_number += 1) {
            const profile = fitz.profile.field_profile(global, @intCast(field_number)) orelse
                continue;
            try testing.expect(profile.name.len < name_column_width);
        }
    }
}

test "data_message_write: developer fields print as stored bytes, only in full detail" {
    const fields = [_]fitz.FieldDefinition{
        .{ .field_definition_number = 3, .size = 1, .base_type = .uint8 },
    };
    const developer_fields = [_]fitz.DeveloperFieldDefinition{
        .{ .field_number = 0, .size = 2, .developer_data_index = 0 },
        .{ .field_number = 1, .size = 1, .developer_data_index = 255 },
    };
    const data = fitz.DataMessage{
        .local_message_type = 3,
        .global_message_number = 20,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = &fields,
        .raw = &.{150},
        .developer_fields = &developer_fields,
        .developer_raw = &.{ 0x34, 0x12, 0xFF },
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .all);
    try testing.expectEqualStrings(
        "DATA local=3 global_msg=record heart_rate=150bpm dev:0:0=0x3412 dev:255:1=0xff\n",
        writer.buffered(),
    );

    writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &data, .readable);
    const block = "record\n  heart_rate            150 bpm\n\n";
    try testing.expectEqualStrings(block, writer.buffered());

    // A message with only developer fields has nothing readable to show.
    var developer_only = data;
    developer_only.fields = &.{};
    developer_only.raw = &.{};
    writer = std.Io.Writer.fixed(&buffer);
    try data_message_write(&writer, &developer_only, .readable);
    try testing.expectEqualStrings("", writer.buffered());
    try data_message_write(&writer, &developer_only, .all);
    const line = "DATA local=3 global_msg=record dev:0:0=0x3412 dev:255:1=0xff\n";
    try testing.expectEqualStrings(line, writer.buffered());
}
