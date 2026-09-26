//! Minimal streaming parser for the FIT (Flexible and Interoperable Data
//! Transfer) binary format. FIT was authored by Garmin but is an open,
//! widely-adopted protocol — plenty of other devices (Suunto, Coros,
//! Wahoo, etc.) read and write it too, so nothing here assumes a
//! Garmin-specific file.
//!
//! Scope for v0.1: file header, record headers (normal + compressed
//! timestamp), definition messages, and data messages as raw bytes.
//! No semantic field decoding, no developer fields, no CRC checks yet.
//!
//! Errors are for invalid external bytes; assertions are for invariants
//! the parser itself guarantees. A failed assertion is a bug in this file.

const std = @import("std");
const assert = std.debug.assert;

pub const FitError = error{
    InvalidSignature,
    UnexpectedEof,
    InvalidHeaderSize,
    InvalidArchitecture,
    UnknownLocalMessageType,
    DeveloperFieldsUnsupported,
    OutOfMemory,
};

const signature = ".FIT";
const signature_offset = 8;
const header_size_short = 12;
const header_size_long = 14;

/// Reserved byte, architecture byte, global message number (2), field count.
const definition_fixed_size = 5;
/// Field definition number, size, base type.
const field_definition_size = 3;
const local_message_type_count = 16;

const record_header_compressed_mask: u8 = 0x80;
const record_header_definition_mask: u8 = 0x40;
const record_header_developer_mask: u8 = 0x20;

pub const FileHeader = struct {
    header_size: u8,
    protocol_version: u8,
    profile_version: u16,
    data_size: u32,
    /// Null when the 12-byte header form is used, or when a 14-byte
    /// header's CRC field was 0 ("not calculated" per spec). Either way
    /// there's nothing to check — one optional instead of a bool that
    /// has to be kept in sync with the value.
    crc: ?u16,

    pub fn data_start(self: FileHeader) usize {
        assert(self.header_size == header_size_short or self.header_size == header_size_long);
        return self.header_size;
    }

    pub fn data_end(self: FileHeader) usize {
        const end = self.data_start() + @as(usize, self.data_size);
        assert(end >= self.data_start());
        return end;
    }
};

fn parse_file_header(buffer: []const u8) FitError!FileHeader {
    if (buffer.len < header_size_short) return FitError.UnexpectedEof;
    const header_size = buffer[0];
    if (header_size != header_size_short and header_size != header_size_long) {
        return FitError.InvalidHeaderSize;
    }
    if (buffer.len < header_size) return FitError.UnexpectedEof;

    const signature_bytes = buffer[signature_offset..][0..signature.len];
    if (!std.mem.eql(u8, signature_bytes, signature)) return FitError.InvalidSignature;

    var crc: ?u16 = null;
    if (header_size == header_size_long) {
        const crc_raw = std.mem.readInt(u16, buffer[12..14], .little);
        if (crc_raw != 0) crc = crc_raw;
    }

    const header = FileHeader{
        .header_size = header_size,
        .protocol_version = buffer[1],
        .profile_version = std.mem.readInt(u16, buffer[2..4], .little),
        .data_size = std.mem.readInt(u32, buffer[4..8], .little),
        .crc = crc,
    };
    assert(header.data_start() <= buffer.len);
    assert(header.crc == null or header.header_size == header_size_long);
    return header;
}

pub const NormalRecordHeader = struct {
    is_definition: bool,
    /// We don't support developer fields yet — read_definition_message
    /// errors out if this is set.
    developer_fields: bool,
    local_message_type: u4,
};

pub const CompressedTimestampHeader = struct {
    /// Only 2 bits are available in this header form, unlike the normal
    /// header's 4 — u2 makes the other 12 local-message-type values
    /// unrepresentable instead of merely unused.
    local_message_type: u2,
    time_offset: u5,
};

/// A tagged union instead of a flat struct with "only meaningful if…"
/// fields: there is no bit pattern that produces, say, a compressed
/// header with is_definition set, because that field doesn't exist on
/// that branch.
pub const RecordHeader = union(enum) {
    normal: NormalRecordHeader,
    compressed_timestamp: CompressedTimestampHeader,
};

fn parse_record_header(byte: u8) RecordHeader {
    if (byte & record_header_compressed_mask != 0) {
        return RecordHeader{ .compressed_timestamp = .{
            .local_message_type = @truncate(byte >> 5),
            .time_offset = @truncate(byte),
        } };
    }
    return RecordHeader{ .normal = .{
        .is_definition = byte & record_header_definition_mask != 0,
        .developer_fields = byte & record_header_developer_mask != 0,
        .local_message_type = @truncate(byte),
    } };
}

pub const FieldDefinition = struct {
    field_definition_number: u8,
    size: u8,
    base_type: u8,
};

pub const DefinitionMessage = struct {
    local_message_type: u4,
    big_endian: bool,
    global_message_number: u16,
    /// Owned by the Parser's allocator; valid until that local message
    /// type is redefined or the Parser is deinitialized.
    fields: []FieldDefinition,

    pub fn message_size(self: DefinitionMessage) u32 {
        assert(self.fields.len <= std.math.maxInt(u8));
        var total: u32 = 0;
        for (self.fields) |field| total += field.size;
        assert(total <= std.math.maxInt(u8) * std.math.maxInt(u8));
        return total;
    }
};

pub const DataMessage = struct {
    local_message_type: u4,
    global_message_number: u16,
    /// View into the original input buffer — not owned, not copied.
    raw: []const u8,
};

pub const Record = union(enum) {
    definition: DefinitionMessage,
    data: DataMessage,
};

/// After `next` returns an error the parser's position is unspecified;
/// stop iterating and call `deinit`.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,
    position: usize,
    end: usize,
    header: FileHeader,
    definitions: [local_message_type_count]?DefinitionMessage = .{null} ** local_message_type_count,

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) FitError!Parser {
        const header = try parse_file_header(buffer);
        // Rejecting a data section that overruns the buffer up front means every later read only
        // has to be bounded by `end`, and a truncated file fails at init, not midway through.
        if (header.data_end() > buffer.len) return FitError.UnexpectedEof;

        const parser = Parser{
            .allocator = allocator,
            .buffer = buffer,
            .position = header.data_start(),
            .end = header.data_end(),
            .header = header,
        };
        parser.assert_invariants();
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        for (&self.definitions) |*definition_slot| {
            if (definition_slot.*) |definition| self.allocator.free(definition.fields);
            definition_slot.* = null;
        }
    }

    /// Returns the next record, or null once the data section (as sized
    /// by the file header) is exhausted.
    pub fn next(self: *Parser) FitError!?Record {
        self.assert_invariants();
        if (self.position == self.end) return null;

        const position_before = self.position;
        const header_byte = self.buffer[self.position];
        self.position += 1;

        const record = switch (parse_record_header(header_byte)) {
            // Timestamp reconstruction from the 5-bit offset isn't
            // implemented yet — this just routes to the matching
            // definition and returns the raw data message.
            .compressed_timestamp => |header| try self.read_data_message(header.local_message_type),
            .normal => |header| if (header.is_definition)
                try self.read_definition_message(header)
            else
                try self.read_data_message(header.local_message_type),
        };

        // Every record consumes at least its header byte, so iteration is bounded by data_size.
        assert(self.position > position_before);
        self.assert_invariants();
        return record;
    }

    fn assert_invariants(self: *const Parser) void {
        assert(self.end == self.header.data_end());
        assert(self.end <= self.buffer.len);
        assert(self.position >= self.header.data_start());
        assert(self.position <= self.end);
    }

    /// Bytes left in the data section. Comparing against this, rather than `position + n > end`,
    /// cannot overflow.
    fn remaining(self: *const Parser) usize {
        assert(self.position <= self.end);
        return self.end - self.position;
    }

    fn read_definition_message(self: *Parser, record_header: NormalRecordHeader) FitError!Record {
        assert(record_header.is_definition);
        if (record_header.developer_fields) return FitError.DeveloperFieldsUnsupported;
        if (self.remaining() < definition_fixed_size) return FitError.UnexpectedEof;

        // fixed[0] is a reserved byte, ignored.
        const fixed = self.buffer[self.position..][0..definition_fixed_size];
        const endian: std.builtin.Endian = switch (fixed[1]) {
            0 => .little,
            1 => .big,
            else => return FitError.InvalidArchitecture,
        };
        const global_message_number = std.mem.readInt(u16, fixed[2..4], endian);
        const field_count = fixed[4];
        self.position += definition_fixed_size;

        const fields_size = @as(usize, field_count) * field_definition_size;
        if (self.remaining() < fields_size) return FitError.UnexpectedEof;

        const fields = try self.allocator.alloc(FieldDefinition, field_count);
        for (fields, 0..) |*field, index| {
            const offset = self.position + index * field_definition_size;
            const field_bytes = self.buffer[offset..][0..field_definition_size];
            field.* = .{
                .field_definition_number = field_bytes[0],
                .size = field_bytes[1],
                .base_type = field_bytes[2],
            };
        }
        self.position += fields_size;

        const definition = DefinitionMessage{
            .local_message_type = record_header.local_message_type,
            .big_endian = endian == .big,
            .global_message_number = global_message_number,
            .fields = fields,
        };
        const slot = &self.definitions[record_header.local_message_type];
        if (slot.*) |previous| self.allocator.free(previous.fields);
        slot.* = definition;

        assert(definition.fields.len == field_count);
        return Record{ .definition = definition };
    }

    fn read_data_message(self: *Parser, local_message_type: u4) FitError!Record {
        const definition = self.definitions[local_message_type] orelse
            return FitError.UnknownLocalMessageType;
        assert(definition.local_message_type == local_message_type);

        const size = definition.message_size();
        if (self.remaining() < size) return FitError.UnexpectedEof;

        const raw = self.buffer[self.position..][0..size];
        self.position += size;

        assert(raw.len == size);
        return Record{ .data = DataMessage{
            .local_message_type = local_message_type,
            .global_message_number = definition.global_message_number,
            .raw = raw,
        } };
    }
};

const testing = std.testing;

/// Builds a 12-byte-header FIT file around `data`. Caller owns the result.
fn test_file_build(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const file = try allocator.alloc(u8, header_size_short + data.len);
    file[0] = header_size_short;
    file[1] = 0x10; // Protocol version.
    std.mem.writeInt(u16, file[2..4], 100, .little); // Profile version.
    std.mem.writeInt(u32, file[4..8], @intCast(data.len), .little);
    @memcpy(file[signature_offset..][0..signature.len], signature);
    @memcpy(file[header_size_short..], data);
    return file;
}

/// Definition: local type 0, little endian, global message 20, one 4-byte field.
const test_definition_local_0 = [_]u8{ 0x40, 0, 0, 20, 0, 1, 253, 4, 0x86 };

test "parse_file_header: 12-byte header" {
    const file = try test_file_build(testing.allocator, &.{ 1, 2, 3 });
    defer testing.allocator.free(file);

    const header = try parse_file_header(file);
    try testing.expectEqual(@as(u8, 12), header.header_size);
    try testing.expectEqual(@as(u8, 0x10), header.protocol_version);
    try testing.expectEqual(@as(u16, 100), header.profile_version);
    try testing.expectEqual(@as(u32, 3), header.data_size);
    try testing.expectEqual(@as(?u16, null), header.crc);
    try testing.expectEqual(@as(usize, 12), header.data_start());
    try testing.expectEqual(@as(usize, 15), header.data_end());
}

test "parse_file_header: 14-byte header with and without CRC" {
    var buffer = [_]u8{ 14, 0x10, 100, 0, 0, 0, 0, 0, '.', 'F', 'I', 'T', 0x34, 0x12 };
    const with_crc = try parse_file_header(&buffer);
    try testing.expectEqual(@as(?u16, 0x1234), with_crc.crc);
    try testing.expectEqual(@as(usize, 14), with_crc.data_start());

    // A zero CRC means "not calculated", not "CRC equals zero".
    buffer[12] = 0;
    buffer[13] = 0;
    const without_crc = try parse_file_header(&buffer);
    try testing.expectEqual(@as(?u16, null), without_crc.crc);
}

test "parse_file_header: rejects invalid headers" {
    var buffer = [_]u8{ 12, 0, 0, 0, 0, 0, 0, 0, '.', 'F', 'I', 'T', 0, 0 };

    try testing.expectError(FitError.UnexpectedEof, parse_file_header(buffer[0..0]));
    try testing.expectError(FitError.UnexpectedEof, parse_file_header(buffer[0..11]));

    buffer[0] = 13;
    try testing.expectError(FitError.InvalidHeaderSize, parse_file_header(&buffer));
    buffer[0] = 0;
    try testing.expectError(FitError.InvalidHeaderSize, parse_file_header(&buffer));

    // A 14-byte header size in a 12-byte buffer.
    buffer[0] = 14;
    try testing.expectError(FitError.UnexpectedEof, parse_file_header(buffer[0..12]));

    buffer[0] = 12;
    buffer[9] = 'X';
    try testing.expectError(FitError.InvalidSignature, parse_file_header(&buffer));
}

test "parse_record_header: normal and compressed forms" {
    const definition = parse_record_header(0x40 | 0x20 | 0x0F).normal;
    try testing.expect(definition.is_definition);
    try testing.expect(definition.developer_fields);
    try testing.expectEqual(@as(u4, 15), definition.local_message_type);

    const data = parse_record_header(0x03).normal;
    try testing.expect(!data.is_definition);
    try testing.expect(!data.developer_fields);
    try testing.expectEqual(@as(u4, 3), data.local_message_type);

    // 1 | 11 | 10101: compressed, local type 3, time offset 21.
    const compressed = parse_record_header(0b1_11_10101).compressed_timestamp;
    try testing.expectEqual(@as(u2, 3), compressed.local_message_type);
    try testing.expectEqual(@as(u5, 21), compressed.time_offset);

    try testing.expect(parse_record_header(0x80) == .compressed_timestamp);
    try testing.expect(parse_record_header(0x7F) == .normal);
}

test "DefinitionMessage.message_size" {
    var fields = [_]FieldDefinition{
        .{ .field_definition_number = 0, .size = 1, .base_type = 0 },
        .{ .field_definition_number = 1, .size = 4, .base_type = 0 },
        .{ .field_definition_number = 2, .size = 255, .base_type = 0 },
    };
    var definition = DefinitionMessage{
        .local_message_type = 0,
        .big_endian = false,
        .global_message_number = 0,
        .fields = &fields,
    };
    try testing.expectEqual(@as(u32, 260), definition.message_size());

    definition.fields = fields[0..0];
    try testing.expectEqual(@as(u32, 0), definition.message_size());
}

test "Parser: definition then data message" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++ [_]u8{
        0x00, 1, 2, 3, 4, // Data message, local type 0.
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();

    const definition = (try parser.next()).?.definition;
    try testing.expectEqual(@as(u16, 20), definition.global_message_number);
    try testing.expect(!definition.big_endian);
    try testing.expectEqual(@as(usize, 1), definition.fields.len);
    try testing.expectEqual(@as(u8, 253), definition.fields[0].field_definition_number);
    try testing.expectEqual(@as(u8, 4), definition.fields[0].size);
    try testing.expectEqual(@as(u8, 0x86), definition.fields[0].base_type);

    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(u16, 20), data.global_message_number);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, data.raw);

    try testing.expectEqual(@as(?Record, null), try parser.next());
    // Exhaustion is stable, not a one-shot.
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: empty data section" {
    const file = try test_file_build(testing.allocator, &.{});
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: big-endian definition" {
    const file = try test_file_build(testing.allocator, &.{ 0x41, 0, 1, 0x01, 0x02, 0 });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();

    const definition = (try parser.next()).?.definition;
    try testing.expect(definition.big_endian);
    try testing.expectEqual(@as(u4, 1), definition.local_message_type);
    try testing.expectEqual(@as(u16, 0x0102), definition.global_message_number);
    try testing.expectEqual(@as(usize, 0), definition.fields.len);
}

test "Parser: redefinition replaces the previous definition" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++ [_]u8{
        0x40, 0, 0, 21, 0, 2, 0, 1, 0, 1, 1, 0, // Local type 0 again: global 21, two 1-byte fields.
        0x00, 7, 8, // Data sized by the new definition.
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();

    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.definition;
    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(u16, 21), data.global_message_number);
    try testing.expectEqualSlices(u8, &.{ 7, 8 }, data.raw);
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: compressed timestamp header routes to its local type" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++ [_]u8{
        0b1_00_00101, 9, 9, 9, 9, // Compressed header, local type 0, offset 5.
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();

    _ = (try parser.next()).?.definition;
    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(u4, 0), data.local_message_type);
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, data.raw);
}

test "Parser: rejects a bad signature" {
    var bad = [_]u8{0} ** 12;
    bad[0] = 12;
    try testing.expectError(FitError.InvalidSignature, Parser.init(testing.allocator, &bad));
}

test "Parser: rejects a data size larger than the buffer" {
    const file = try test_file_build(testing.allocator, &.{ 0, 0 });
    defer testing.allocator.free(file);
    std.mem.writeInt(u32, file[4..8], 3, .little);
    try testing.expectError(FitError.UnexpectedEof, Parser.init(testing.allocator, file));
}

test "Parser: rejects malformed records" {
    const cases = [_]struct { data: []const u8, expected: FitError }{
        .{ .data = &.{0x00}, .expected = FitError.UnknownLocalMessageType },
        .{ .data = &.{0x80}, .expected = FitError.UnknownLocalMessageType },
        .{ .data = &.{ 0x60, 0, 0, 0, 0, 0 }, .expected = FitError.DeveloperFieldsUnsupported },
        .{ .data = &.{ 0x40, 0, 2, 0, 0, 0 }, .expected = FitError.InvalidArchitecture },
        .{ .data = &.{ 0x40, 0, 0, 0 }, .expected = FitError.UnexpectedEof },
        .{ .data = &.{ 0x40, 0, 0, 0, 0, 1, 0, 1 }, .expected = FitError.UnexpectedEof },
        .{
            .data = &test_definition_local_0 ++ [_]u8{ 0x00, 1, 2, 3 },
            .expected = FitError.UnexpectedEof,
        },
    };
    for (cases) |case| {
        const file = try test_file_build(testing.allocator, case.data);
        defer testing.allocator.free(file);

        var parser = try Parser.init(testing.allocator, file);
        defer parser.deinit();
        while (true) {
            const record = parser.next() catch |err| {
                try testing.expectEqual(case.expected, err);
                break;
            };
            try testing.expect(record != null);
        }
    }
}

test "Parser: records never read past the data section into the file CRC" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++
        [_]u8{ 0x00, 1, 2, 3, 0xAA, 0xBB });
    defer testing.allocator.free(file);
    // The data section ends after byte 3; the last two bytes stand in for the trailing file CRC.
    const data_size: u32 = @intCast(file.len - header_size_short - 2);
    std.mem.writeInt(u32, file[4..8], data_size, .little);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    try testing.expectError(FitError.UnexpectedEof, parser.next());
}
