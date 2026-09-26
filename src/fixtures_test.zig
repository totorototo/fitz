//! Tests against real FIT files in testdata/, written by other tools and devices. Unlike the
//! hand-built bytes in fit.zig, these check fitz against files it didn't make. The expected
//! values come from outside fitz: python-fitparse's own tests and CSV, or other messages in the
//! same file. See testdata/README.md for where each file comes from.
//!
//! The files are embedded at compile time (build.zig names each one), so the tests do no I/O
//! and don't depend on the working directory.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fitz = @import("fitz");

const record_message = 20;

const Counts = struct {
    definition: u32 = 0,
    data: u32 = 0,
    compressed_timestamp: u32 = 0,
    developer_fields: u32 = 0,
};

/// Counts the records of every chained FIT file in `buffer`.
fn counts_read(buffer: []const u8) !Counts {
    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();

    var counts = Counts{};
    // Bounded: every record consumes at least one byte of the buffer.
    while (try parser.next()) |record| {
        switch (record) {
            .definition => counts.definition += 1,
            .data => |data| {
                counts.data += 1;
                if (data.compressed_timestamp != null) counts.compressed_timestamp += 1;
                if (data.developer_fields.len > 0) counts.developer_fields += 1;
            },
        }
    }
    assert(counts.data + counts.definition <= buffer.len);
    return counts;
}

test "DeveloperData.fit: developer fields decode through their field_description" {
    const buffer = @embedFile("DeveloperData.fit");
    const counts = try counts_read(buffer);
    try testing.expectEqual(Counts{ .definition = 4, .data = 6, .developer_fields = 3 }, counts);

    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    const heart_rates = [_]u64{ 140, 143, 144 };
    var records: u8 = 0;
    while (try parser.next()) |record| {
        const data = switch (record) {
            .definition => continue,
            .data => |data| data,
        };
        if (data.global_message_number != record_message) continue;

        // The file describes "doughnuts_earned", sint8, in "doughnuts"; the records count 1-3.
        var iterator = data.developer_fields_iterator();
        const developer = iterator.next().?;
        try testing.expectEqual(@as(?fitz.DeveloperField, null), iterator.next());
        const description = parser.developer_field_descriptions.get(&developer).?;
        try testing.expectEqualStrings("doughnuts_earned", description.name.?);
        try testing.expectEqualStrings("doughnuts", description.units);
        try testing.expectEqual(fitz.BaseType.sint8, description.base_type);
        const doughnuts = try developer.field(description.base_type);
        try testing.expectEqual(fitz.Value{ .signed = records + 1 }, doughnuts.element(0).?);

        var standard = data.fields_iterator();
        const heart_rate = standard.next().?;
        try testing.expectEqual(@as(u8, 3), heart_rate.field_definition_number);
        const heart_rate_expected = fitz.Value{ .unsigned = heart_rates[records] };
        try testing.expectEqual(heart_rate_expected, heart_rate.element(0).?);
        records += 1;
    }
    try testing.expectEqual(@as(u8, 3), records);
    try testing.expectEqual(@as(u32, 1), parser.developer_field_descriptions.count());
}

test "20170518-191602-1740899583.fit: every developer field fits its described base type" {
    const buffer = @embedFile("20170518-191602-1740899583.fit");
    const counts = try counts_read(buffer);
    try testing.expectEqual(@as(u32, 1717), counts.data);
    try testing.expectEqual(@as(u32, 1650), counts.developer_fields);

    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    var values: u32 = 0;
    while (try parser.next()) |record| {
        const data = switch (record) {
            .definition => continue,
            .data => |data| data,
        };
        var iterator = data.developer_fields_iterator();
        while (iterator.next()) |developer| {
            // Every developer field is described before use, with a name. `field` fails with
            // InvalidFieldSize if the size doesn't fit the described type.
            const description = parser.developer_field_descriptions.get(&developer).?;
            try testing.expect(description.name != null);
            const field = try developer.field(description.base_type);
            try testing.expect(field.element_count() >= 1);
            values += 1;
        }
    }
    try testing.expectEqual(@as(u32, 8317), values);
}

test "compressed-speed-distance.fit: rebuilt timestamps match python-fitparse's CSV" {
    const buffer = @embedFile("compressed-speed-distance.fit");
    const counts = try counts_read(buffer);
    try testing.expectEqual(@as(u32, 780), counts.data);
    try testing.expectEqual(@as(u32, 755), counts.compressed_timestamp);

    // Columns: timestamp, heart rate, speed, distance, cadence. The first record, which only
    // sets the timestamp, isn't in the CSV.
    const csv = @embedFile("compressed-speed-distance-records.csv");
    var lines = std.mem.tokenizeScalar(u8, csv, '\n');
    _ = lines.next().?; // Header.

    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    var records: u32 = 0;
    while (try parser.next()) |record| {
        const data = switch (record) {
            .definition => continue,
            .data => |data| data,
        };
        if (data.global_message_number != record_message) continue;
        records += 1;
        const timestamp = data.compressed_timestamp.?;
        if (records == 1) {
            try testing.expectEqual(@as(u32, 17217864), timestamp);
            continue;
        }

        var columns = std.mem.splitScalar(u8, lines.next().?, ',');
        const timestamp_expected = try std.fmt.parseInt(u32, columns.next().?, 10);
        const heart_rate_expected = fitz.Value{
            .unsigned = try std.fmt.parseInt(u64, columns.next().?, 10),
        };
        try testing.expectEqual(timestamp_expected, timestamp);
        var heart_rates: u8 = 0;
        var iterator = data.fields_iterator();
        while (iterator.next()) |field| {
            if (field.field_definition_number != 3) continue;
            try testing.expectEqual(heart_rate_expected, field.element(0).?);
            heart_rates += 1;
        }
        try testing.expectEqual(@as(u8, 1), heart_rates);
    }
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
    try testing.expectEqual(@as(u32, 755), records);
}

test "Activity.fit: a plain SDK example activity" {
    const counts = try counts_read(@embedFile("Activity.fit"));
    try testing.expectEqual(Counts{ .definition = 10, .data = 22 }, counts);
}

test "activity-filecrc.fit and activity-unexpected-eof.fit are rejected before any record" {
    const crc = fitz.Parser.init(testing.allocator, @embedFile("activity-filecrc.fit"));
    try testing.expectError(fitz.FitError.FileCrcMismatch, crc);
    const eof = fitz.Parser.init(testing.allocator, @embedFile("activity-unexpected-eof.fit"));
    try testing.expectError(fitz.FitError.UnexpectedEof, eof);
}

test "coros-pace-2-cycling-misaligned-fields.fit: the strict base-type policy rejects it" {
    // An event message (21) defines field 3 as a uint32 of size 1. The FIT SDK and fitparse fall
    // back to bytes and read 11293 messages; fitz rejects the definition. If the policy is
    // relaxed, this test turns into a count check.
    var parser = try fitz.Parser.init(testing.allocator, @embedFile(
        "coros-pace-2-cycling-misaligned-fields.fit",
    ));
    defer parser.deinit();
    var records: u32 = 0;
    const result = while (true) {
        const record = parser.next() catch |err| break err;
        try testing.expect(record != null);
        records += 1;
    };
    try testing.expectEqual(fitz.FitError.InvalidFieldSize, result);
    try testing.expect(records > 0);
}

const file_count_max = 8;

/// The data message count of each chained file in `buffer`, told apart by `file_index`.
fn file_data_counts(buffer: []const u8, counts: *[file_count_max]u32) !u32 {
    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    assert(parser.file_count <= file_count_max);
    @memset(counts, 0);
    while (try parser.next()) |record| {
        if (record == .data) counts[parser.file_index] += 1;
    }
    // Every file was reached, the last one included.
    assert(parser.file_index + 1 == parser.file_count);
    return parser.file_count;
}

test "chained files: every file is read, each with its own definitions" {
    var counts: [file_count_max]u32 = undefined;

    const settings = @embedFile("activity-settings.fit");
    try testing.expectEqual(@as(u32, 2), try file_data_counts(settings, &counts));
    try testing.expectEqualSlices(u32, &.{ 22, 3 }, counts[0..2]);

    // python-fitparse counts 3023 messages over all the chained files.
    const multiple = @embedFile("sample_mulitple_header.fit");
    const files = try file_data_counts(multiple, &counts);
    try testing.expect(files > 1);
    var total: u32 = 0;
    for (counts[0..files]) |count| {
        try testing.expect(count > 0);
        total += count;
    }
    try testing.expectEqual(@as(u32, 3023), total);
    try testing.expectEqual(@as(u32, 3023), (try counts_read(multiple)).data);
}

test "activity-settings-corruptheader.fit: a corrupt second header rejects the whole buffer" {
    // The second file's signature reads ".GIT". fitparse rejects the whole buffer too, and
    // Parser.init fails before the first file's records are returned.
    const buffer = @embedFile("activity-settings-corruptheader.fit");
    const result = fitz.Parser.init(testing.allocator, buffer);
    try testing.expectError(fitz.FitError.InvalidSignature, result);
}
