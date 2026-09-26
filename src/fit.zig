//! Minimal streaming parser for the FIT (Flexible and Interoperable Data
//! Transfer) binary format. FIT was authored by Garmin but is an open,
//! widely-adopted protocol — plenty of other devices (Suunto, Coros,
//! Wahoo, etc.) read and write it too, so nothing here assumes a
//! Garmin-specific file.
//!
//! Scope: file header, record headers (normal + compressed timestamp),
//! definition messages, and data messages with base-type value decoding.
//! No profile (message/field names), no developer fields, no CRC checks yet.
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
    InvalidBaseType,
    InvalidFieldSize,
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

/// The 17 FIT base types, tagged with their canonical on-disk byte: bit 7 is the "endian
/// ability" flag (set for multi-byte types), bits 0-4 are the base type number, and bits 5-6
/// are reserved as zero. Only the canonical bytes are accepted, so a reserved bit or a wrong
/// endian-ability flag is rejected at definition time instead of being silently masked off.
pub const BaseType = enum(u8) {
    @"enum" = 0x00,
    sint8 = 0x01,
    uint8 = 0x02,
    sint16 = 0x83,
    uint16 = 0x84,
    sint32 = 0x85,
    uint32 = 0x86,
    string = 0x07,
    float32 = 0x88,
    float64 = 0x89,
    uint8z = 0x0A,
    uint16z = 0x8B,
    uint32z = 0x8C,
    byte = 0x0D,
    sint64 = 0x8E,
    uint64 = 0x8F,
    uint64z = 0x90,

    pub fn from_byte(byte: u8) FitError!BaseType {
        const base_type = std.enums.fromInt(BaseType, byte) orelse
            return FitError.InvalidBaseType;
        assert(@intFromEnum(base_type) == byte);
        return base_type;
    }

    /// Size in bytes of one element. A string or byte field is a single element that spans
    /// the whole field, so its unit size is 1 and any field size is a valid multiple of it.
    pub fn size(self: BaseType) u8 {
        const result: u8 = switch (self) {
            .@"enum", .sint8, .uint8, .string, .uint8z, .byte => 1,
            .sint16, .uint16, .uint16z => 2,
            .sint32, .uint32, .float32, .uint32z => 4,
            .float64, .sint64, .uint64, .uint64z => 8,
        };
        // The endian-ability bit is set exactly on the multi-byte types.
        assert((result > 1) == (@intFromEnum(self) & 0x80 != 0));
        return result;
    }
};

pub const FieldDefinition = struct {
    field_definition_number: u8,
    /// Nonzero multiple of `base_type.size()`, checked when the definition is parsed.
    size: u8,
    base_type: BaseType,
};

fn parse_field_definition(bytes: *const [field_definition_size]u8) FitError!FieldDefinition {
    const base_type = try BaseType.from_byte(bytes[2]);
    const size = bytes[1];
    // The FIT SDK decodes a mis-sized field as a byte array; rejecting it instead keeps every
    // later element read aligned by construction, with no fallback path to test.
    if (size == 0 or size % base_type.size() != 0) return FitError.InvalidFieldSize;

    const field = FieldDefinition{
        .field_definition_number = bytes[0],
        .size = size,
        .base_type = base_type,
    };
    assert(field.size >= field.base_type.size());
    return field;
}

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
    big_endian: bool,
    /// Borrowed from the matching definition, with the same lifetime: valid until that local
    /// message type is redefined or the Parser is deinitialized.
    fields: []const FieldDefinition,
    /// View into the original input buffer — not owned, not copied.
    raw: []const u8,

    pub fn fields_iterator(self: *const DataMessage) FieldIterator {
        return FieldIterator{
            .fields = self.fields,
            .raw = self.raw,
            .endian = if (self.big_endian) .big else .little,
        };
    }
};

/// Walks a data message's fields in definition order. It copies the slices out of the
/// DataMessage, so it stays valid even if that DataMessage was a temporary.
pub const FieldIterator = struct {
    fields: []const FieldDefinition,
    raw: []const u8,
    endian: std.builtin.Endian,
    index: usize = 0,
    offset: usize = 0,

    pub fn next(self: *FieldIterator) ?Field {
        assert(self.index <= self.fields.len);
        assert(self.offset <= self.raw.len);
        if (self.index == self.fields.len) {
            // The definition's sizes must add up to exactly the message's bytes.
            assert(self.offset == self.raw.len);
            return null;
        }

        const definition = self.fields[self.index];
        const field = Field{
            .field_definition_number = definition.field_definition_number,
            .base_type = definition.base_type,
            .endian = self.endian,
            .raw = self.raw[self.offset..][0..definition.size],
        };
        self.index += 1;
        self.offset += definition.size;
        return field;
    }
};

/// One field of a data message. Base types carry an "invalid" sentinel meaning "no data", so
/// `element` returns null for it rather than handing the caller a magic number.
pub const Field = struct {
    field_definition_number: u8,
    base_type: BaseType,
    endian: std.builtin.Endian,
    raw: []const u8,

    /// A numeric field whose size is a multiple of its base type size is an array; a string
    /// or byte field is always one element.
    pub fn element_count(self: *const Field) u8 {
        const size = self.element_size();
        assert(self.raw.len >= 1);
        assert(self.raw.len % size == 0);
        return @intCast(self.raw.len / size);
    }

    pub fn element(self: *const Field, index: u8) ?Value {
        assert(index < self.element_count());
        const size = self.element_size();
        const bytes = self.raw[@as(usize, index) * size ..][0..size];
        return value_decode(self.base_type, bytes, self.endian);
    }

    fn element_size(self: *const Field) u8 {
        assert(self.raw.len <= std.math.maxInt(u8));
        return switch (self.base_type) {
            .string, .byte => @intCast(self.raw.len),
            // Every other base type is fixed-size.
            else => self.base_type.size(),
        };
    }
};

/// A decoded element, grouped by representation. The exact width lives on `Field.base_type`,
/// so widening here loses nothing and keeps callers' switches to five cases instead of 17.
pub const Value = union(enum) {
    /// enum, uint8/16/32/64 and their `z` variants.
    unsigned: u64,
    /// sint8/16/32/64.
    signed: i64,
    /// float32/64.
    float: f64,
    /// Bytes up to the first null terminator, which is excluded. A view into the input buffer.
    string: []const u8,
    /// The whole field. A view into the input buffer.
    bytes: []const u8,
};

/// Returns null when `bytes` holds the base type's invalid sentinel.
fn value_decode(base_type: BaseType, bytes: []const u8, endian: std.builtin.Endian) ?Value {
    assert(bytes.len >= 1);
    assert(bytes.len % base_type.size() == 0);
    return switch (base_type) {
        .@"enum", .uint8 => unsigned_decode(u8, bytes, endian, std.math.maxInt(u8)),
        .uint16 => unsigned_decode(u16, bytes, endian, std.math.maxInt(u16)),
        .uint32 => unsigned_decode(u32, bytes, endian, std.math.maxInt(u32)),
        .uint64 => unsigned_decode(u64, bytes, endian, std.math.maxInt(u64)),
        .uint8z => unsigned_decode(u8, bytes, endian, 0),
        .uint16z => unsigned_decode(u16, bytes, endian, 0),
        .uint32z => unsigned_decode(u32, bytes, endian, 0),
        .uint64z => unsigned_decode(u64, bytes, endian, 0),
        .sint8 => signed_decode(i8, bytes, endian),
        .sint16 => signed_decode(i16, bytes, endian),
        .sint32 => signed_decode(i32, bytes, endian),
        .sint64 => signed_decode(i64, bytes, endian),
        .float32 => float_decode(f32, bytes, endian),
        .float64 => float_decode(f64, bytes, endian),
        .string => string_decode(bytes),
        .byte => if (std.mem.allEqual(u8, bytes, 0xFF)) null else Value{ .bytes = bytes },
    };
}

fn unsigned_decode(
    comptime T: type,
    bytes: []const u8,
    endian: std.builtin.Endian,
    comptime invalid: T,
) ?Value {
    assert(bytes.len == @sizeOf(T));
    const value = std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
    if (value == invalid) return null;
    return Value{ .unsigned = value };
}

/// Signed types use the maximum positive value as their sentinel, not -1.
fn signed_decode(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) ?Value {
    assert(bytes.len == @sizeOf(T));
    const value = std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
    if (value == std.math.maxInt(T)) return null;
    return Value{ .signed = value };
}

/// The float sentinel is the all-ones bit pattern, which is a NaN. It must be compared as
/// bits, because NaN never compares equal as a float.
fn float_decode(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) ?Value {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
    assert(bytes.len == @sizeOf(T));
    const bits = std.mem.readInt(Bits, bytes[0..@sizeOf(T)], endian);
    if (bits == std.math.maxInt(Bits)) return null;
    const value: T = @bitCast(bits);
    return Value{ .float = value };
}

/// An empty string is the string sentinel. A string that fills its field has no terminator,
/// which the spec allows.
fn string_decode(bytes: []const u8) ?Value {
    assert(bytes.len >= 1);
    const length = std.mem.findScalar(u8, bytes, 0) orelse bytes.len;
    assert(length <= bytes.len);
    if (length == 0) return null;
    return Value{ .string = bytes[0..length] };
}

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
        errdefer self.allocator.free(fields);
        for (fields, 0..) |*field, index| {
            const offset = self.position + index * field_definition_size;
            field.* = try parse_field_definition(self.buffer[offset..][0..field_definition_size]);
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
            .big_endian = definition.big_endian,
            .fields = definition.fields,
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
        .{ .field_definition_number = 0, .size = 1, .base_type = .byte },
        .{ .field_definition_number = 1, .size = 4, .base_type = .byte },
        .{ .field_definition_number = 2, .size = 255, .base_type = .byte },
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
    try testing.expectEqual(BaseType.uint32, definition.fields[0].base_type);

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

test "BaseType.from_byte: accepts exactly the 17 canonical bytes" {
    var accepted: u32 = 0;
    var byte: u32 = 0;
    while (byte <= std.math.maxInt(u8)) : (byte += 1) {
        const base_type = BaseType.from_byte(@intCast(byte)) catch |err| {
            try testing.expectEqual(FitError.InvalidBaseType, err);
            continue;
        };
        try testing.expectEqual(@as(u8, @intCast(byte)), @intFromEnum(base_type));
        accepted += 1;
    }
    try testing.expectEqual(@as(u32, 17), accepted);

    // A multi-byte type without its endian-ability bit, or with a reserved bit set, is invalid.
    try testing.expectError(FitError.InvalidBaseType, BaseType.from_byte(0x04));
    try testing.expectError(FitError.InvalidBaseType, BaseType.from_byte(0x82));
    try testing.expectError(FitError.InvalidBaseType, BaseType.from_byte(0x22));
    try testing.expectError(FitError.InvalidBaseType, BaseType.from_byte(0x11));
}

test "BaseType.size" {
    try testing.expectEqual(@as(u8, 1), BaseType.@"enum".size());
    try testing.expectEqual(@as(u8, 1), BaseType.string.size());
    try testing.expectEqual(@as(u8, 1), BaseType.byte.size());
    try testing.expectEqual(@as(u8, 2), BaseType.sint16.size());
    try testing.expectEqual(@as(u8, 4), BaseType.float32.size());
    try testing.expectEqual(@as(u8, 8), BaseType.uint64z.size());
}

test "parse_field_definition: size must be a nonzero multiple of the base type size" {
    const valid = try parse_field_definition(&.{ 3, 4, 0x84 });
    try testing.expectEqual(@as(u8, 3), valid.field_definition_number);
    try testing.expectEqual(@as(u8, 4), valid.size);
    try testing.expectEqual(BaseType.uint16, valid.base_type);

    _ = try parse_field_definition(&.{ 0, 1, 0x02 });
    _ = try parse_field_definition(&.{ 0, 255, 0x07 });
    _ = try parse_field_definition(&.{ 0, 248, 0x89 });

    try testing.expectError(FitError.InvalidFieldSize, parse_field_definition(&.{ 0, 0, 0x02 }));
    try testing.expectError(FitError.InvalidFieldSize, parse_field_definition(&.{ 0, 3, 0x84 }));
    try testing.expectError(FitError.InvalidFieldSize, parse_field_definition(&.{ 0, 255, 0x89 }));
    try testing.expectError(FitError.InvalidBaseType, parse_field_definition(&.{ 0, 1, 0xFF }));
}

test "value_decode: unsigned and z variants" {
    const little = std.builtin.Endian.little;
    try testing.expectEqual(Value{ .unsigned = 0 }, value_decode(.uint8, &.{0x00}, little).?);
    try testing.expectEqual(Value{ .unsigned = 0xFE }, value_decode(.@"enum", &.{0xFE}, little).?);
    try testing.expectEqual(@as(?Value, null), value_decode(.uint8, &.{0xFF}, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint8z, &.{0x00}, little));
    try testing.expectEqual(Value{ .unsigned = 0xFF }, value_decode(.uint8z, &.{0xFF}, little).?);

    const uint16_little = value_decode(.uint16, &.{ 2, 1 }, little).?;
    try testing.expectEqual(Value{ .unsigned = 0x0102 }, uint16_little);
    try testing.expectEqual(Value{ .unsigned = 0x0102 }, value_decode(.uint16, &.{ 1, 2 }, .big).?);
    try testing.expectEqual(@as(?Value, null), value_decode(.uint16, &.{ 0xFF, 0xFF }, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint16z, &.{ 0, 0 }, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint32, &(.{0xFF} ** 4), little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint32z, &(.{0} ** 4), little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint64, &(.{0xFF} ** 8), little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint64z, &(.{0} ** 8), little));

    const max_valid = std.math.maxInt(u64) - 1;
    const bytes = [_]u8{0xFE} ++ [_]u8{0xFF} ** 7;
    const uint64_max = value_decode(.uint64, &bytes, little).?;
    try testing.expectEqual(Value{ .unsigned = max_valid }, uint64_max);
}

test "value_decode: signed uses the maximum positive value as its sentinel" {
    const little = std.builtin.Endian.little;
    try testing.expectEqual(Value{ .signed = -1 }, value_decode(.sint8, &.{0xFF}, little).?);
    try testing.expectEqual(Value{ .signed = -128 }, value_decode(.sint8, &.{0x80}, little).?);
    try testing.expectEqual(Value{ .signed = 126 }, value_decode(.sint8, &.{0x7E}, little).?);
    try testing.expectEqual(@as(?Value, null), value_decode(.sint8, &.{0x7F}, little));

    try testing.expectEqual(Value{ .signed = -2 }, value_decode(.sint16, &.{ 0xFF, 0xFE }, .big).?);
    try testing.expectEqual(@as(?Value, null), value_decode(.sint16, &.{ 0xFF, 0x7F }, little));
    const sint32_invalid = [_]u8{ 0x7F, 0xFF, 0xFF, 0xFF };
    try testing.expectEqual(@as(?Value, null), value_decode(.sint32, &sint32_invalid, .big));
    const sint64_invalid = [_]u8{0xFF} ** 7 ++ [_]u8{0x7F};
    try testing.expectEqual(@as(?Value, null), value_decode(.sint64, &sint64_invalid, little));
    const sint64_min = [_]u8{0} ** 7 ++ [_]u8{0x80};
    const min = std.math.minInt(i64);
    try testing.expectEqual(Value{ .signed = min }, value_decode(.sint64, &sint64_min, little).?);
}

test "value_decode: floats compare the sentinel as bits" {
    const little = std.builtin.Endian.little;
    const one_float32 = [_]u8{ 0x00, 0x00, 0x80, 0x3F };
    try testing.expectEqual(Value{ .float = 1.0 }, value_decode(.float32, &one_float32, little).?);
    const half_float64 = [_]u8{ 0x3F, 0xE0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(Value{ .float = 0.5 }, value_decode(.float64, &half_float64, .big).?);
    try testing.expectEqual(@as(?Value, null), value_decode(.float32, &(.{0xFF} ** 4), little));
    try testing.expectEqual(@as(?Value, null), value_decode(.float64, &(.{0xFF} ** 8), little));

    // A NaN other than the all-ones pattern is data, not the sentinel.
    const nan = value_decode(.float32, &.{ 0xFE, 0xFF, 0xFF, 0xFF }, little).?;
    try testing.expect(std.math.isNan(nan.float));
}

test "value_decode: string and byte" {
    const little = std.builtin.Endian.little;
    try testing.expectEqualStrings("ab", value_decode(.string, "ab\x00\x00", little).?.string);
    try testing.expectEqualStrings("abc", value_decode(.string, "abc", little).?.string);
    try testing.expectEqualStrings("a", value_decode(.string, "a", little).?.string);
    try testing.expectEqual(@as(?Value, null), value_decode(.string, "\x00", little));
    try testing.expectEqual(@as(?Value, null), value_decode(.string, "\x00ab", little));

    const partial = value_decode(.byte, &.{ 0xFF, 0 }, little).?;
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0 }, partial.bytes);
    try testing.expectEqualSlices(u8, &.{0}, value_decode(.byte, &.{0}, little).?.bytes);
    try testing.expectEqual(@as(?Value, null), value_decode(.byte, &.{0xFF}, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.byte, &(.{0xFF} ** 255), little));
}

test "Field: arrays, strings and invalid elements" {
    const array = Field{
        .field_definition_number = 0,
        .base_type = .uint16,
        .endian = .little,
        .raw = &.{ 1, 0, 0xFF, 0xFF, 3, 0 },
    };
    try testing.expectEqual(@as(u8, 3), array.element_count());
    try testing.expectEqual(Value{ .unsigned = 1 }, array.element(0).?);
    try testing.expectEqual(@as(?Value, null), array.element(1));
    try testing.expectEqual(Value{ .unsigned = 3 }, array.element(2).?);

    const text = Field{
        .field_definition_number = 1,
        .base_type = .string,
        .endian = .little,
        .raw = "edge\x00\x00",
    };
    try testing.expectEqual(@as(u8, 1), text.element_count());
    try testing.expectEqualStrings("edge", text.element(0).?.string);

    const bytes_max = [_]u8{0} ** 255;
    const blob = Field{
        .field_definition_number = 2,
        .base_type = .byte,
        .endian = .little,
        .raw = &bytes_max,
    };
    try testing.expectEqual(@as(u8, 1), blob.element_count());
    try testing.expectEqual(@as(usize, 255), blob.element(0).?.bytes.len);
}

test "Parser: data message fields decode through the iterator" {
    const file = try test_file_build(testing.allocator, &[_]u8{
        // Local type 2, big endian, global 20, three fields: sint16, string[4], uint8[2].
        0x42, 0,    1,    0,   20,  3, 5, 2,    0x83, 6, 4, 0x07, 7, 2, 0x02,
        0x02, 0xFF, 0x9C, 'h', 'i', 0, 0, 0xFF, 42,
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    const data = (try parser.next()).?.data;
    try testing.expect(data.big_endian);
    try testing.expectEqual(@as(usize, 3), data.fields.len);

    var iterator = data.fields_iterator();
    const altitude = iterator.next().?;
    try testing.expectEqual(@as(u8, 5), altitude.field_definition_number);
    try testing.expectEqual(Value{ .signed = -100 }, altitude.element(0).?);

    const name = iterator.next().?;
    try testing.expectEqual(BaseType.string, name.base_type);
    try testing.expectEqualStrings("hi", name.element(0).?.string);

    const pair = iterator.next().?;
    try testing.expectEqual(@as(u8, 2), pair.element_count());
    try testing.expectEqual(@as(?Value, null), pair.element(0));
    try testing.expectEqual(Value{ .unsigned = 42 }, pair.element(1).?);

    try testing.expectEqual(@as(?Field, null), iterator.next());
    try testing.expectEqual(@as(?Field, null), iterator.next());
}

test "Parser: a data message with no fields yields an empty iterator" {
    const file = try test_file_build(testing.allocator, &.{ 0x40, 0, 0, 0, 0, 0, 0x00 });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(usize, 0), data.raw.len);
    var iterator = data.fields_iterator();
    try testing.expectEqual(@as(?Field, null), iterator.next());
}

test "Parser: rejects invalid field definitions without leaking" {
    const cases = [_]struct { data: []const u8, expected: FitError }{
        // Second field has an unknown base type; the first was already parsed.
        .{
            .data = &.{ 0x40, 0, 0, 0, 0, 2, 0, 1, 0x02, 1, 1, 0x11 },
            .expected = FitError.InvalidBaseType,
        },
        .{ .data = &.{ 0x40, 0, 0, 0, 0, 1, 0, 3, 0x84 }, .expected = FitError.InvalidFieldSize },
        .{ .data = &.{ 0x40, 0, 0, 0, 0, 1, 0, 0, 0x02 }, .expected = FitError.InvalidFieldSize },
    };
    for (cases) |case| {
        const file = try test_file_build(testing.allocator, case.data);
        defer testing.allocator.free(file);

        var parser = try Parser.init(testing.allocator, file);
        defer parser.deinit();
        try testing.expectError(case.expected, parser.next());
    }
}
