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
const field_description_message = 206;
/// The two bytes after the data section.
const file_crc_size = 2;

const Counts = struct {
    definition: u32 = 0,
    data: u32 = 0,
    compressed_timestamp: u32 = 0,
    developer_fields: u32 = 0,
};

/// Counts the records of the first FIT file in `buffer`. Chained files after it are left out.
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

/// The size of the first FIT file in `buffer`: header, data section and file CRC.
fn file_size(buffer: []const u8) !usize {
    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    const size = parser.header.data_end() + file_crc_size;
    assert(size <= buffer.len);
    return size;
}

/// The base type a field_description message (206) gives one developer field. It is found the
/// way a caller of `DeveloperField.field` would find it: by reading the file's own descriptions.
const Description = struct {
    developer_data_index: u8,
    field_number: u8,
    base_type: fitz.BaseType,
};

const description_count_max = 64;

const Descriptions = struct {
    items: [description_count_max]Description = undefined,
    count: u8 = 0,

    /// Reads developer_data_index (0), field_definition_number (1) and fit_base_type_id (2).
    fn add(self: *Descriptions, data: *const fitz.DataMessage) !void {
        assert(data.global_message_number == field_description_message);
        assert(self.count < description_count_max);
        var description: Description = undefined;
        var found: u8 = 0;
        var iterator = data.fields_iterator();
        while (iterator.next()) |field| {
            if (field.field_definition_number > 2) continue;
            const value = field.element(0).?.unsigned;
            switch (field.field_definition_number) {
                0 => description.developer_data_index = @intCast(value),
                1 => description.field_number = @intCast(value),
                2 => description.base_type = try fitz.BaseType.from_byte(@intCast(value)),
                else => unreachable,
            }
            found += 1;
        }
        try testing.expectEqual(@as(u8, 3), found);
        self.items[self.count] = description;
        self.count += 1;
    }

    fn base_type(self: *const Descriptions, field: *const fitz.DeveloperField) ?fitz.BaseType {
        for (self.items[0..self.count]) |description| {
            if (description.developer_data_index == field.developer_data_index and
                description.field_number == field.field_number) return description.base_type;
        }
        return null;
    }
};

test "DeveloperData.fit: developer fields decode through their field_description" {
    const buffer = @embedFile("DeveloperData.fit");
    const counts = try counts_read(buffer);
    try testing.expectEqual(Counts{ .definition = 4, .data = 6, .developer_fields = 3 }, counts);

    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    var descriptions = Descriptions{};
    const heart_rates = [_]u64{ 140, 143, 144 };
    var records: u8 = 0;
    while (try parser.next()) |record| {
        const data = switch (record) {
            .definition => continue,
            .data => |data| data,
        };
        if (data.global_message_number == field_description_message) try descriptions.add(&data);
        if (data.global_message_number != record_message) continue;

        // The file's description says "doughnuts_earned", sint8; the three records count 1-3.
        var iterator = data.developer_fields_iterator();
        const developer = iterator.next().?;
        try testing.expectEqual(@as(?fitz.DeveloperField, null), iterator.next());
        const base_type = descriptions.base_type(&developer).?;
        try testing.expectEqual(fitz.BaseType.sint8, base_type);
        const doughnuts = try developer.field(base_type);
        try testing.expectEqual(fitz.Value{ .signed = records + 1 }, doughnuts.element(0).?);

        var standard = data.fields_iterator();
        const heart_rate = standard.next().?;
        try testing.expectEqual(@as(u8, 3), heart_rate.field_definition_number);
        const heart_rate_expected = fitz.Value{ .unsigned = heart_rates[records] };
        try testing.expectEqual(heart_rate_expected, heart_rate.element(0).?);
        records += 1;
    }
    try testing.expectEqual(@as(u8, 3), records);
}

test "20170518-191602-1740899583.fit: every developer field fits its described base type" {
    const buffer = @embedFile("20170518-191602-1740899583.fit");
    const counts = try counts_read(buffer);
    try testing.expectEqual(@as(u32, 1717), counts.data);
    try testing.expectEqual(@as(u32, 1650), counts.developer_fields);

    var parser = try fitz.Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    var descriptions = Descriptions{};
    var values: u32 = 0;
    while (try parser.next()) |record| {
        const data = switch (record) {
            .definition => continue,
            .data => |data| data,
        };
        if (data.global_message_number == field_description_message) try descriptions.add(&data);
        var iterator = data.developer_fields_iterator();
        while (iterator.next()) |developer| {
            // `field` fails with InvalidFieldSize if the size doesn't fit the described type.
            const field = try developer.field(descriptions.base_type(&developer).?);
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

/// Parses each chained FIT file in `buffer` in turn, as fitz can't yet do on its own. Returns
/// the data message count per file, or the error of the first file that fails.
fn chained_data_counts(buffer: []const u8, counts: []u32) !usize {
    var offset: usize = 0;
    var files: usize = 0;
    // Bounded by the size of `counts`.
    while (offset < buffer.len) : (files += 1) {
        assert(files < counts.len);
        const rest = buffer[offset..];
        counts[files] = (try counts_read(rest)).data;
        offset += try file_size(rest);
    }
    assert(offset == buffer.len);
    return files;
}

test "chained files: fitz reads only the first one, the rest is still valid FIT" {
    var counts: [8]u32 = undefined;

    const settings = @embedFile("activity-settings.fit");
    try testing.expectEqual(@as(usize, 771), try file_size(settings));
    try testing.expectEqual(@as(usize, 2), try chained_data_counts(settings, &counts));
    try testing.expectEqual(@as(u32, 22), counts[0]);

    // python-fitparse counts 3023 messages over all the chained files.
    const multiple = @embedFile("sample_mulitple_header.fit");
    try testing.expectEqual(@as(u32, 1862), (try counts_read(multiple)).data);
    const files = try chained_data_counts(multiple, &counts);
    var total: u32 = 0;
    for (counts[0..files]) |count| total += count;
    try testing.expectEqual(@as(u32, 3023), total);
}

test "activity-settings-corruptheader.fit: the second file's header is corrupt" {
    // fitz reads the first file and doesn't look past it, so today this parses. fitparse
    // rejects the whole buffer; chained-file support should too.
    const buffer = @embedFile("activity-settings-corruptheader.fit");
    try testing.expectEqual(@as(u32, 22), (try counts_read(buffer)).data);
    const size = try file_size(buffer);
    try testing.expect(size < buffer.len);
    // Its signature reads ".GIT".
    const second = fitz.Parser.init(testing.allocator, buffer[size..]);
    try testing.expectError(fitz.FitError.InvalidSignature, second);
}
