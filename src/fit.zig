//! Minimal streaming parser for the FIT (Flexible and Interoperable Data
//! Transfer) binary format. FIT was authored by Garmin but is an open,
//! widely-adopted protocol — plenty of other devices (Suunto, Coros,
//! Wahoo, etc.) read and write it too, so nothing here assumes a
//! Garmin-specific file.
//!
//! Scope: file header, record headers (normal + compressed timestamp, with the
//! timestamp reconstructed), definition messages, and data messages with base-type
//! value decoding. Chained FIT files in one buffer are read in turn. Every file's header
//! CRC (when present) and file CRC are verified up front. Developer fields are split out of
//! each data message as raw bytes, and each file's field_description messages are collected so
//! a caller can look up a developer field's base type, name, units and scale. Names and scaling
//! of standard fields live in profile.zig.
//!
//! Errors are for invalid external bytes; assertions are for invariants
//! the parser itself guarantees. A failed assertion is a bug in this file.

const std = @import("std");
const assert = std.debug.assert;

pub const FitError = error{
    InvalidSignature,
    UnexpectedEof,
    InvalidHeaderSize,
    /// The 14-byte header's CRC is nonzero and doesn't match header bytes 0-11.
    HeaderCrcMismatch,
    /// The 2-byte CRC after the data section doesn't match the header and data bytes.
    FileCrcMismatch,
    InvalidArchitecture,
    UnknownLocalMessageType,
    InvalidBaseType,
    InvalidFieldSize,
    /// A compressed-timestamp header appeared before any full timestamp to anchor it.
    CompressedTimestampWithoutReference,
    /// A compressed-timestamp message's definition also has a timestamp field (253), so the
    /// message would carry two timestamps that may disagree.
    CompressedTimestampWithTimestampField,
    /// Reconstructing a compressed timestamp would pass the largest u32 timestamp.
    TimestampOverflow,
    /// A field_description message (206) lacks its developer data index, field number or base
    /// type, or holds a field of the wrong type or size, or a zero scale.
    InvalidFieldDescription,
    OutOfMemory,
};

const signature = ".FIT";
const signature_offset = 8;
const header_size_short = 12;
const header_size_long = 14;
/// Both the header CRC and the trailing file CRC are little-endian u16s.
const crc_size = 2;

/// Reserved byte, architecture byte, global message number (2), field count.
const definition_fixed_size = 5;
/// Field definition number, size, base type. A developer field definition is also 3 bytes:
/// field number, size, developer data index.
const field_definition_size = 3;
const local_message_type_count = 16;

const record_header_compressed_mask: u8 = 0x80;
const record_header_definition_mask: u8 = 0x40;
const record_header_developer_mask: u8 = 0x20;

/// Field 253 is the timestamp in every FIT message: a uint32 count of seconds since the FIT
/// epoch (1989-12-31 00:00:00 UTC). It is protocol-level, not profile data.
pub const timestamp_field_number: u8 = 253;
/// A compressed header carries only the low 5 bits of the timestamp.
const compressed_timestamp_mask: u32 = 0x1F;
const compressed_timestamp_rollover: u32 = 0x20;

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
        // The header CRC covers the 12 bytes of the short header form, i.e. all but itself.
        const crc_raw = std.mem.readInt(u16, buffer[header_size_short..][0..crc_size], .little);
        if (crc_raw != 0) {
            if (crc_compute(buffer[0..header_size_short]) != crc_raw) {
                return FitError.HeaderCrcMismatch;
            }
            crc = crc_raw;
        }
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

/// The smallest possible file: a 12-byte header, no data and the file CRC.
const file_size_min = header_size_short + crc_size;

/// Checks the one file that starts `bytes`: its header, that its data section and file CRC fit,
/// and the file CRC. Returns the file's size. Bytes after it are the caller's.
fn file_verify(bytes: []const u8) FitError!usize {
    const header = try parse_file_header(bytes);
    // Rejecting a data section that overruns the buffer up front means every later read only
    // has to be bounded by the data section's end, and a truncated file fails at init.
    if (header.data_end() > bytes.len) return FitError.UnexpectedEof;
    if (bytes.len - header.data_end() < crc_size) return FitError.UnexpectedEof;
    const size = header.data_end() + crc_size;
    _ = try file_crc_verify(bytes[0..size]);
    assert(size >= file_size_min);
    assert(size <= bytes.len);
    return size;
}

/// Checks every chained file in `buffer`, in order. Every byte must belong to a file, so bytes
/// after the last one that don't form a whole valid file are an error, not ignored. Returns the
/// number of files.
fn files_verify(buffer: []const u8) FitError!u32 {
    const file_count_max = buffer.len / file_size_min;
    var offset: usize = 0;
    var file_count: u32 = 0;
    // Bounded: every file consumes at least file_size_min bytes.
    while (true) {
        assert(file_count <= file_count_max);
        offset += try file_verify(buffer[offset..]);
        file_count += 1;
        if (offset == buffer.len) break;
    }
    assert(offset == buffer.len);
    assert(file_count >= 1 and file_count <= file_count_max);
    return file_count;
}

/// FIT's CRC is CRC-16/ARC: polynomial 0x8005, reflected, initial value 0, no final XOR.
fn crc_compute(bytes: []const u8) u16 {
    return std.hash.crc.@"CRC-16/ARC".hash(bytes);
}

/// Checks the file CRC: the last two bytes of `file` against everything before them, header
/// included. Returns the verified CRC.
fn file_crc_verify(file: []const u8) FitError!u16 {
    assert(file.len >= header_size_short + crc_size);
    const content = file[0 .. file.len - crc_size];
    const crc_stored = std.mem.readInt(u16, file[content.len..][0..crc_size], .little);

    var crc = std.hash.crc.@"CRC-16/ARC".init();
    crc.update(content);
    if (crc.final() != crc_stored) return FitError.FileCrcMismatch;

    // Paired check: running a reflected CRC on through its own little-endian value always
    // leaves a zero remainder, so the stored bytes and the computed value really agree.
    crc.update(file[content.len..]);
    assert(crc.final() == 0);
    return crc_stored;
}

pub const NormalRecordHeader = struct {
    is_definition: bool,
    /// Set on a definition message whose standard fields are followed by developer fields.
    /// Reserved on a data message, whose layout comes from its definition.
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
        assert(@backingInt(base_type) == byte);
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
        assert((result > 1) == (@backingInt(self) & 0x80 != 0));
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

/// A developer field carries no base type: that comes from the field_description message (206)
/// with the same developer data index and field number, so the size can only be checked against
/// it once the caller decodes the field (`DeveloperField.field`).
pub const DeveloperFieldDefinition = struct {
    field_number: u8,
    /// Nonzero, checked when the definition is parsed.
    size: u8,
    /// Links the field to a developer_data_id message (207) and its field_description messages.
    developer_data_index: u8,
};

fn parse_developer_field_definition(
    bytes: *const [field_definition_size]u8,
) FitError!DeveloperFieldDefinition {
    if (bytes[1] == 0) return FitError.InvalidFieldSize;
    const field = DeveloperFieldDefinition{
        .field_number = bytes[0],
        .size = bytes[1],
        .developer_data_index = bytes[2],
    };
    assert(field.size >= 1);
    return field;
}

pub const DefinitionMessage = struct {
    local_message_type: u4,
    big_endian: bool,
    global_message_number: u16,
    /// Owned by the Parser; valid until `Parser.deinit`, even after a redefinition.
    fields: []FieldDefinition,
    /// Empty unless the record header had the developer-fields bit. Same ownership as `fields`.
    developer_fields: []DeveloperFieldDefinition,

    /// Bytes of a data message: the standard fields, then the developer fields.
    pub fn message_size(self: *const DefinitionMessage) u32 {
        const total = self.fields_size() + self.developer_fields_size();
        assert(total <= 2 * std.math.maxInt(u8) * std.math.maxInt(u8));
        return total;
    }

    pub fn fields_size(self: *const DefinitionMessage) u32 {
        assert(self.fields.len <= std.math.maxInt(u8));
        var total: u32 = 0;
        for (self.fields) |field| total += field.size;
        assert(total >= self.fields.len);
        return total;
    }

    pub fn developer_fields_size(self: *const DefinitionMessage) u32 {
        assert(self.developer_fields.len <= std.math.maxInt(u8));
        var total: u32 = 0;
        for (self.developer_fields) |field| total += field.size;
        assert(total >= self.developer_fields.len);
        return total;
    }
};

pub const DataMessage = struct {
    local_message_type: u4,
    global_message_number: u16,
    big_endian: bool,
    /// Non-null exactly when the record used a compressed-timestamp header: the timestamp
    /// rebuilt from its 5-bit offset. A normal message's timestamp, if any, is field 253.
    compressed_timestamp: ?u32,
    /// Borrowed from the matching definition, with the same lifetime: valid until that local
    /// message type is redefined or the Parser is deinitialized.
    fields: []const FieldDefinition,
    /// The standard fields' bytes. View into the original input buffer — not owned, not copied.
    raw: []const u8,
    /// Borrowed from the matching definition, like `fields`. Empty for most messages.
    developer_fields: []const DeveloperFieldDefinition,
    /// The developer fields' bytes, which follow `raw` in the input buffer.
    developer_raw: []const u8,

    pub fn fields_iterator(self: *const DataMessage) FieldIterator {
        return FieldIterator{
            .fields = self.fields,
            .raw = self.raw,
            .endian = if (self.big_endian) .big else .little,
        };
    }

    pub fn developer_fields_iterator(self: *const DataMessage) DeveloperFieldIterator {
        return DeveloperFieldIterator{
            .fields = self.developer_fields,
            .raw = self.developer_raw,
            .endian = if (self.big_endian) .big else .little,
        };
    }
};

/// Walks a data message's developer fields in definition order, like `FieldIterator`.
pub const DeveloperFieldIterator = struct {
    fields: []const DeveloperFieldDefinition,
    raw: []const u8,
    endian: std.builtin.Endian,
    index: usize = 0,
    offset: usize = 0,

    pub fn next(self: *DeveloperFieldIterator) ?DeveloperField {
        assert(self.index <= self.fields.len);
        assert(self.offset <= self.raw.len);
        if (self.index == self.fields.len) {
            assert(self.offset == self.raw.len);
            return null;
        }

        const definition = self.fields[self.index];
        const field = DeveloperField{
            .field_number = definition.field_number,
            .developer_data_index = definition.developer_data_index,
            .endian = self.endian,
            .raw = self.raw[self.offset..][0..definition.size],
        };
        self.index += 1;
        self.offset += definition.size;
        return field;
    }
};

/// One developer field of a data message, as bytes. Its base type, name, units and scale are in
/// the field_description message (206) with the same developer data index and field number.
pub const DeveloperField = struct {
    field_number: u8,
    developer_data_index: u8,
    endian: std.builtin.Endian,
    raw: []const u8,

    /// Views the bytes as `base_type`, the type the field's description gives, so they decode
    /// like a standard field. The size is checked here because this is the first point where
    /// the base type is known; the file, not fitz, is wrong when it doesn't fit.
    pub fn field(self: *const DeveloperField, base_type: BaseType) FitError!Field {
        assert(self.raw.len >= 1);
        assert(self.raw.len <= std.math.maxInt(u8));
        if (self.raw.len % base_type.size() != 0) return FitError.InvalidFieldSize;
        const result = Field{
            .field_definition_number = self.field_number,
            .base_type = base_type,
            .endian = self.endian,
            .raw = self.raw,
        };
        assert(result.element_count() >= 1);
        return result;
    }
};

/// Global message number of field_description, which gives a developer field its base type,
/// name, units, scale and offset.
pub const field_description_message: u16 = 206;

/// The field_description fields fitz reads. The others (array, components, bits, accumulate,
/// base unit, native message and field numbers) are ignored.
const FieldDescriptionField = enum(u8) {
    developer_data_index = 0,
    field_definition_number = 1,
    fit_base_type_id = 2,
    field_name = 3,
    scale = 6,
    offset = 7,
    units = 8,
    _,
};

/// What a field_description message (206) says about one developer field. The strings are
/// views into the input buffer.
pub const DeveloperFieldDescription = struct {
    developer_data_index: u8,
    field_number: u8,
    base_type: BaseType,
    /// As the file writes it, which is often not snake_case ("Heart Rate"). Null when absent.
    name: ?[]const u8 = null,
    /// Empty when absent.
    units: []const u8 = "",
    /// Nonzero. As for a profile field, physical value = raw / scale - offset.
    scale: u8 = 1,
    offset: i8 = 0,
};

/// Reads a field_description message. Fields 0-2 (which developer field, and its base type)
/// are required; the rest default to an unnamed, unitless, unscaled field when absent or when
/// they hold the invalid sentinel.
fn parse_developer_field_description(
    data: *const DataMessage,
) FitError!DeveloperFieldDescription {
    assert(data.global_message_number == field_description_message);
    var developer_data_index: ?u8 = null;
    var field_number: ?u8 = null;
    var base_type_byte: ?u8 = null;
    var description = DeveloperFieldDescription{
        .developer_data_index = undefined,
        .field_number = undefined,
        .base_type = undefined,
    };
    var iterator = data.fields_iterator();
    // Bounded by the definition's field count, at most 255.
    while (iterator.next()) |field| {
        switch (@as(FieldDescriptionField, @fromBackingInt(field.field_definition_number))) {
            .developer_data_index => developer_data_index = try description_unsigned(&field),
            .field_definition_number => field_number = try description_unsigned(&field),
            .fit_base_type_id => base_type_byte = try description_unsigned(&field),
            .field_name => description.name = try description_string(&field),
            .units => description.units = try description_string(&field) orelse "",
            .scale => description.scale = try description_unsigned(&field) orelse 1,
            .offset => description.offset = try description_signed(&field) orelse 0,
            _ => {},
        }
    }
    description.developer_data_index = developer_data_index orelse
        return FitError.InvalidFieldDescription;
    description.field_number = field_number orelse return FitError.InvalidFieldDescription;
    const byte = base_type_byte orelse return FitError.InvalidFieldDescription;
    description.base_type = try BaseType.from_byte(byte);
    // A zero scale would divide by zero when the field is scaled.
    if (description.scale == 0) return FitError.InvalidFieldDescription;

    assert(description.scale >= 1);
    assert(description.name == null or description.name.?.len >= 1);
    return description;
}

/// One uint8 of a field_description, or null for the invalid sentinel. The file is wrong if
/// the field is an array, isn't unsigned, or holds a value above 255.
fn description_unsigned(field: *const Field) FitError!?u8 {
    assert(field.raw.len >= 1);
    if (field.element_count() != 1) return FitError.InvalidFieldDescription;
    const value = field.element(0) orelse return null;
    const unsigned = switch (value) {
        .unsigned => |unsigned| unsigned,
        .signed, .float, .string, .bytes => return FitError.InvalidFieldDescription,
    };
    const result = std.math.cast(u8, unsigned) orelse return FitError.InvalidFieldDescription;
    assert(result == unsigned);
    return result;
}

/// One sint8 of a field_description (the offset), or null for the invalid sentinel.
fn description_signed(field: *const Field) FitError!?i8 {
    assert(field.raw.len >= 1);
    if (field.element_count() != 1) return FitError.InvalidFieldDescription;
    const value = field.element(0) orelse return null;
    const signed = switch (value) {
        .signed => |signed| signed,
        .unsigned, .float, .string, .bytes => return FitError.InvalidFieldDescription,
    };
    const result = std.math.cast(i8, signed) orelse return FitError.InvalidFieldDescription;
    assert(result == signed);
    return result;
}

/// A string of a field_description, or null when it is empty.
fn description_string(field: *const Field) FitError!?[]const u8 {
    assert(field.raw.len >= 1);
    if (field.base_type != .string) return FitError.InvalidFieldDescription;
    const value = field.element(0) orelse return null;
    assert(value.string.len >= 1);
    return value.string;
}

/// The descriptions read so far in the current file, keyed by developer data index and field
/// number. A later description of the same field replaces the earlier one. At most 65,536
/// entries, one per key.
pub const DeveloperFieldDescriptions = struct {
    map: std.AutoHashMapUnmanaged(u16, DeveloperFieldDescription) = .empty,

    /// The description of `field`, or null when its file hasn't described it (yet).
    pub fn get(
        self: *const DeveloperFieldDescriptions,
        field: *const DeveloperField,
    ) ?DeveloperFieldDescription {
        const description = self.map.get(key(field.developer_data_index, field.field_number)) orelse
            return null;
        assert(description.developer_data_index == field.developer_data_index);
        assert(description.field_number == field.field_number);
        return description;
    }

    pub fn put(
        self: *DeveloperFieldDescriptions,
        allocator: std.mem.Allocator,
        description: DeveloperFieldDescription,
    ) error{OutOfMemory}!void {
        assert(description.scale >= 1);
        const description_key = key(description.developer_data_index, description.field_number);
        try self.map.put(allocator, description_key, description);
        assert(self.map.count() >= 1);
        assert(self.map.count() <= std.math.maxInt(u16) + 1);
    }

    pub fn count(self: *const DeveloperFieldDescriptions) u32 {
        const result = self.map.count();
        assert(result <= std.math.maxInt(u16) + 1);
        return result;
    }

    /// Only for tables built outside a Parser, whose own table lives in its arena.
    pub fn deinit(self: *DeveloperFieldDescriptions, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = undefined;
    }

    fn clear(self: *DeveloperFieldDescriptions) void {
        self.map.clearRetainingCapacity();
        assert(self.map.count() == 0);
    }

    fn key(developer_data_index: u8, field_number: u8) u16 {
        const result = @as(u16, developer_data_index) << 8 | field_number;
        assert(result >> 8 == developer_data_index);
        return result;
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

/// Rebuilds a full timestamp from a compressed header's 5-bit offset. The offset replaces the
/// reference's low 5 bits; when it is smaller than them, the 5-bit counter wrapped, so the
/// result moves into the next 32-second window.
fn timestamp_reconstruct(reference: u32, time_offset: u5) FitError!u32 {
    const reference_offset = reference & compressed_timestamp_mask;
    const base = reference & ~compressed_timestamp_mask;
    const rollover: u32 = if (time_offset < reference_offset) compressed_timestamp_rollover else 0;
    const timestamp = std.math.add(u32, base, @as(u32, time_offset) + rollover) catch
        return FitError.TimestampOverflow;

    // The result never goes backwards and never skips a whole window.
    assert(timestamp >= reference);
    assert(timestamp - reference < compressed_timestamp_rollover);
    assert(timestamp & compressed_timestamp_mask == time_offset);
    return timestamp;
}

/// Returns the message's timestamp field if it can anchor compressed timestamps: field 253,
/// a single uint32, and not the invalid sentinel. A field 253 of any other shape is left as an
/// ordinary field and is deliberately not used as a reference.
fn timestamp_field_read(
    fields: []const FieldDefinition,
    raw: []const u8,
    endian: std.builtin.Endian,
) ?u32 {
    var iterator = FieldIterator{ .fields = fields, .raw = raw, .endian = endian };
    // Bounded by the field count, at most 255.
    while (iterator.next()) |field| {
        if (field.field_definition_number != timestamp_field_number) continue;
        if (field.base_type != .uint32 or field.raw.len != 4) return null;
        const value = field.element(0) orelse return null;
        assert(value.unsigned <= std.math.maxInt(u32));
        return @intCast(value.unsigned);
    }
    return null;
}

fn fields_contain(fields: []const FieldDefinition, field_definition_number: u8) bool {
    assert(fields.len <= std.math.maxInt(u8));
    for (fields) |field| {
        if (field.field_definition_number == field_definition_number) return true;
    }
    return false;
}

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
    const Bits = @Int(.unsigned, @bitSizeOf(T));
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

/// Reads every FIT file chained in the buffer, in order. `header`, `file_crc`, `file_index` and
/// `developer_field_descriptions` describe the file the latest record came from. Each file
/// starts with no definitions, no timestamp reference and no descriptions, as a separate file
/// would.
///
/// A record's slices point into the buffer or into the parser's arena, so they stay valid until
/// `deinit`, across redefinitions and files.
/// After `next` returns an error the parser's position is unspecified;
/// stop iterating and call `deinit`.
pub const Parser = struct {
    /// Holds every definition's field tables and the descriptions table until `deinit`. Nothing
    /// is freed on redefinition, so records stay valid. The total stays bounded: each definition
    /// allocates at most the 3 bytes per field definition it consumed from the buffer, and the
    /// descriptions table has at most 65,536 entries, reused across files.
    arena: std.heap.ArenaAllocator,
    buffer: []const u8,
    position: usize,
    end: usize,
    /// Where the current file's header starts in `buffer`.
    file_start: usize,
    /// 0 for the first file, up to `file_count - 1`.
    file_index: u32,
    file_count: u32,
    header: FileHeader,
    /// The current file's trailing CRC, already verified by `init`.
    file_crc: u16,
    definitions: [local_message_type_count]?DefinitionMessage = @splat(null),
    /// The latest full timestamp, from field 253 of a normal message or from a reconstructed
    /// compressed one. Compressed headers are resolved against it.
    timestamp_reference: ?u32 = null,
    /// The current file's field_description messages, read so far. Look up a developer field of
    /// the record `next` just returned; a later description, or the next file, can change the
    /// answer.
    developer_field_descriptions: DeveloperFieldDescriptions = .{},

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) FitError!Parser {
        // Verifying every file before the first record means no record is ever returned from a
        // buffer with a corrupted or truncated file anywhere in it, even a later chained one.
        // It costs one pass over bytes that are already in memory.
        const file_count = try files_verify(buffer);
        var parser = Parser{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .buffer = buffer,
            .position = undefined,
            .end = undefined,
            .file_start = 0,
            .file_index = 0,
            .file_count = file_count,
            .header = undefined,
            .file_crc = undefined,
        };
        parser.file_load(0);
        assert(parser.file_count >= 1);
        parser.assert_invariants();
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Points the parser at the file whose header starts at `file_start`. `init` has verified
    /// it, so its header can't fail to parse here.
    fn file_load(self: *Parser, file_start: usize) void {
        assert(file_start < self.buffer.len);
        const file = self.buffer[file_start..];
        const header = parse_file_header(file) catch unreachable;
        self.file_start = file_start;
        self.header = header;
        self.position = file_start + header.data_start();
        self.end = file_start + header.data_end();
        self.file_crc = std.mem.readInt(u16, self.buffer[self.end..][0..crc_size], .little);
        assert(self.end + crc_size <= self.buffer.len);
    }

    /// Moves to the next chained file once `next_in_file` has returned null for this one, and
    /// returns false, staying put, after the last file. The next file's local message types,
    /// timestamps and developer field descriptions are its own. Calling it with records left in
    /// the current file is a bug in the caller.
    pub fn file_advance(self: *Parser) bool {
        self.assert_invariants();
        assert(self.position == self.end);
        if (self.file_index + 1 == self.file_count) return false;
        self.definitions = @splat(null);
        self.timestamp_reference = null;
        self.developer_field_descriptions.clear();
        self.file_index += 1;
        self.file_load(self.end + crc_size);
        assert(self.position == self.file_start + self.header.data_start());
        self.assert_invariants();
        return true;
    }

    /// Returns the next record of every chained file in turn, or null after the last file.
    /// A caller that needs to see each file, an empty one included, uses `next_in_file` and
    /// `file_advance` instead.
    pub fn next(self: *Parser) FitError!?Record {
        // Bounded: each pass either returns or moves to a later file.
        while (true) {
            if (try self.next_in_file()) |record| return record;
            if (!self.file_advance()) return null;
        }
    }

    /// Returns the next record of the current file, or null once its data section is exhausted.
    pub fn next_in_file(self: *Parser) FitError!?Record {
        self.assert_invariants();
        if (self.position == self.end) return null;

        const position_before = self.position;
        const header_byte = self.buffer[self.position];
        self.position += 1;

        const record = switch (parse_record_header(header_byte)) {
            .compressed_timestamp => |header| try self.read_data_message(
                header.local_message_type,
                header.time_offset,
            ),
            .normal => |header| if (header.is_definition)
                try self.read_definition_message(header)
            else
                try self.read_data_message(header.local_message_type, null),
        };

        // Every record consumes at least its header byte, so iteration is bounded by data_size.
        assert(self.position > position_before);
        self.assert_invariants();
        return record;
    }

    fn assert_invariants(self: *const Parser) void {
        assert(self.file_index < self.file_count);
        assert(self.end == self.file_start + self.header.data_end());
        assert(self.end <= self.buffer.len);
        assert(self.buffer.len - self.end >= crc_size);
        assert(self.position >= self.file_start + self.header.data_start());
        assert(self.position <= self.end);
        // Negative space: the last file ends the buffer, and no other file does.
        const last = self.file_index + 1 == self.file_count;
        assert(last == (self.end + crc_size == self.buffer.len));
    }

    /// Bytes left in the data section. Comparing against this, rather than `position + n > end`,
    /// cannot overflow.
    fn remaining(self: *const Parser) usize {
        assert(self.position <= self.end);
        return self.end - self.position;
    }

    fn read_definition_message(self: *Parser, record_header: NormalRecordHeader) FitError!Record {
        assert(record_header.is_definition);
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

        const fields = try self.read_field_definitions(
            FieldDefinition,
            field_count,
            parse_field_definition,
        );

        // Without the header bit there is no count byte, which is the same as a count of 0.
        var developer_field_count: u8 = 0;
        if (record_header.developer_fields) {
            if (self.remaining() < 1) return FitError.UnexpectedEof;
            developer_field_count = self.buffer[self.position];
            self.position += 1;
        }
        const developer_fields = try self.read_field_definitions(
            DeveloperFieldDefinition,
            developer_field_count,
            parse_developer_field_definition,
        );

        const definition = DefinitionMessage{
            .local_message_type = record_header.local_message_type,
            .big_endian = endian == .big,
            .global_message_number = global_message_number,
            .fields = fields,
            .developer_fields = developer_fields,
        };
        // The previous definition's tables stay in the arena, for records that still use them.
        self.definitions[record_header.local_message_type] = definition;

        assert(definition.fields.len == field_count);
        assert(definition.developer_fields.len == developer_field_count);
        return Record{ .definition = definition };
    }

    /// Reads `count` 3-byte definitions of either kind into the arena. Nothing is allocated when
    /// the bytes are missing.
    fn read_field_definitions(
        self: *Parser,
        comptime Definition: type,
        count: u8,
        comptime parse: fn (*const [field_definition_size]u8) FitError!Definition,
    ) FitError![]Definition {
        const size = @as(usize, count) * field_definition_size;
        if (self.remaining() < size) return FitError.UnexpectedEof;

        // The arena's bound: never more bytes allocated than consumed from the buffer.
        comptime assert(@sizeOf(Definition) <= field_definition_size);
        const definitions = try self.arena.allocator().alloc(Definition, count);
        for (definitions, 0..) |*definition, index| {
            const offset = self.position + index * field_definition_size;
            definition.* = try parse(self.buffer[offset..][0..field_definition_size]);
        }
        self.position += size;

        assert(definitions.len == count);
        assert(self.position <= self.end);
        return definitions;
    }

    /// `time_offset` is set for a compressed-timestamp header and null for a normal one.
    fn read_data_message(self: *Parser, local_message_type: u4, time_offset: ?u5) FitError!Record {
        const definition = self.definitions[local_message_type] orelse
            return FitError.UnknownLocalMessageType;
        assert(definition.local_message_type == local_message_type);

        const size = definition.message_size();
        if (self.remaining() < size) return FitError.UnexpectedEof;

        const raw = self.buffer[self.position..][0..definition.fields_size()];
        const developer_raw = self.buffer[self.position + raw.len ..][0..definition
            .developer_fields_size()];
        const endian: std.builtin.Endian = if (definition.big_endian) .big else .little;
        var compressed_timestamp: ?u32 = null;
        if (time_offset) |offset| {
            if (fields_contain(definition.fields, timestamp_field_number)) {
                return FitError.CompressedTimestampWithTimestampField;
            }
            const reference = self.timestamp_reference orelse
                return FitError.CompressedTimestampWithoutReference;
            compressed_timestamp = try timestamp_reconstruct(reference, offset);
            self.timestamp_reference = compressed_timestamp;
        } else if (timestamp_field_read(definition.fields, raw, endian)) |timestamp| {
            self.timestamp_reference = timestamp;
        }
        self.position += size;

        assert(raw.len + developer_raw.len == size);
        assert(raw.ptr + raw.len == developer_raw.ptr);
        assert((compressed_timestamp != null) == (time_offset != null));
        const data = DataMessage{
            .local_message_type = local_message_type,
            .global_message_number = definition.global_message_number,
            .big_endian = definition.big_endian,
            .compressed_timestamp = compressed_timestamp,
            .fields = definition.fields,
            .raw = raw,
            .developer_fields = definition.developer_fields,
            .developer_raw = developer_raw,
        };
        if (data.global_message_number == field_description_message) {
            const description = try parse_developer_field_description(&data);
            try self.developer_field_descriptions.put(self.arena.allocator(), description);
        }
        return Record{ .data = data };
    }
};

const testing = std.testing;

/// Builds a 12-byte-header FIT file around `data`, with a valid trailing file CRC. Caller owns
/// the result.
fn test_file_build(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const file = try allocator.alloc(u8, header_size_short + data.len + crc_size);
    file[0] = header_size_short;
    file[1] = 0x10; // Protocol version.
    std.mem.writeInt(u16, file[2..4], 100, .little); // Profile version.
    std.mem.writeInt(u32, file[4..8], @intCast(data.len), .little);
    @memcpy(file[signature_offset..][0..signature.len], signature);
    @memcpy(file[header_size_short..][0..data.len], data);
    test_file_crc_write(file);
    return file;
}

/// Rewrites the trailing file CRC, e.g. after a test edits the header or data.
fn test_file_crc_write(file: []u8) void {
    const content_size = file.len - crc_size;
    const crc = crc_compute(file[0..content_size]);
    std.mem.writeInt(u16, file[content_size..][0..crc_size], crc, .little);
}

/// The FIT SDK's reference CRC: a 16-entry table applied to each byte's low then high nibble.
/// Kept only as a test oracle for `crc_compute`.
fn test_crc_fit_sdk(bytes: []const u8) u16 {
    const table = [16]u16{
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    };
    var crc: u16 = 0;
    for (bytes) |byte| {
        var temporary = table[crc & 0xF];
        crc = (crc >> 4) & 0x0FFF;
        crc = crc ^ temporary ^ table[byte & 0xF];
        temporary = table[crc & 0xF];
        crc = (crc >> 4) & 0x0FFF;
        crc = crc ^ temporary ^ table[(byte >> 4) & 0xF];
    }
    return crc;
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
    var buffer = [_]u8{ 14, 0x10, 100, 0, 0, 0, 0, 0, '.', 'F', 'I', 'T', 0, 0 };
    const crc = crc_compute(buffer[0..12]);
    std.mem.writeInt(u16, buffer[12..14], crc, .little);
    const with_crc = try parse_file_header(&buffer);
    try testing.expectEqual(@as(?u16, crc), with_crc.crc);
    try testing.expectEqual(@as(usize, 14), with_crc.data_start());

    // A nonzero CRC that doesn't match, whether the CRC or a covered byte is wrong.
    buffer[12] ^= 0x01;
    try testing.expectError(FitError.HeaderCrcMismatch, parse_file_header(&buffer));
    buffer[12] ^= 0x01;
    buffer[1] = 0x20;
    try testing.expectError(FitError.HeaderCrcMismatch, parse_file_header(&buffer));

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
        .developer_fields = &.{},
    };
    try testing.expectEqual(@as(u32, 260), definition.message_size());
    try testing.expectEqual(@as(u32, 260), definition.fields_size());
    try testing.expectEqual(@as(u32, 0), definition.developer_fields_size());

    // The largest message: 255 standard and 255 developer fields of 255 bytes each.
    var fields_max: [255]FieldDefinition = @splat(.{
        .field_definition_number = 0,
        .size = 255,
        .base_type = .byte,
    });
    var developer_fields_max: [255]DeveloperFieldDefinition = @splat(.{
        .field_number = 0,
        .size = 255,
        .developer_data_index = 0,
    });
    definition.fields = &fields_max;
    definition.developer_fields = &developer_fields_max;
    try testing.expectEqual(@as(u32, 2 * 255 * 255), definition.message_size());

    definition.fields = fields[0..0];
    definition.developer_fields = developer_fields_max[0..1];
    try testing.expectEqual(@as(u32, 255), definition.message_size());
    definition.developer_fields = developer_fields_max[0..0];
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

/// Definition: local type 1, little endian, global message 20, one uint8 field (heart rate),
/// and no timestamp field, as a compressed-timestamp message's definition must be.
const test_definition_local_1_compressed = [_]u8{ 0x41, 0, 0, 20, 0, 1, 3, 1, 0x02 };

test "Parser: compressed timestamps are rebuilt against the latest full timestamp" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++
        test_definition_local_1_compressed ++ [_]u8{
        0x00, 0x1B, 0x00, 0x00, 0x00, // Normal message, timestamp 27 (low 5 bits 27).
        0b1_01_11110, 60, // Offset 30 >= 27: same window, timestamp 30.
        0b1_01_00010, 61, // Offset 2 < 30: the counter wrapped, timestamp 34.
        0b1_01_00010, 62, // Same offset again: no time passed, timestamp 34.
        0x00, 0x00, 0x01, 0x00, 0x00, // Normal message resets the reference to 256.
        0b1_01_00001, 63, // Timestamp 257.
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.definition;

    const anchor = (try parser.next()).?.data;
    try testing.expectEqual(@as(?u32, null), anchor.compressed_timestamp);

    const expected = [_]u32{ 30, 34, 34 };
    for (expected) |timestamp| {
        const data = (try parser.next()).?.data;
        try testing.expectEqual(@as(u4, 1), data.local_message_type);
        try testing.expectEqual(@as(?u32, timestamp), data.compressed_timestamp);
    }

    _ = (try parser.next()).?.data;
    const last = (try parser.next()).?.data;
    try testing.expectEqual(@as(?u32, 257), last.compressed_timestamp);
    try testing.expectEqualSlices(u8, &.{63}, last.raw);
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: an invalid or non-uint32 field 253 is not a timestamp reference" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++
        test_definition_local_1_compressed ++ [_]u8{
        0x00, 0x10, 0x00, 0x00, 0x00, // Timestamp 16.
        0x00, 0xFF, 0xFF, 0xFF, 0xFF, // Timestamp "no data": the reference stays 16.
        0x42, 0, 0, 20, 0, 1, 253, 2, 0x84, // Local type 2: field 253 as a uint16.
        0x02, 0x00, 0x01, // Field 253 = 256 as uint16: not a reference either.
        0b1_01_10001, 1, // Offset 17 against 16: timestamp 17.
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    var count: u32 = 0;
    // Bounded: 7 records in the file.
    while (count < 6) : (count += 1) _ = (try parser.next()).?;
    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(?u32, 17), data.compressed_timestamp);
}

test "Parser: rejects compressed timestamps it cannot anchor" {
    const cases = [_]struct { data: []const u8, expected: FitError }{
        .{
            .data = &test_definition_local_1_compressed ++ [_]u8{ 0b1_01_00000, 0 },
            .expected = FitError.CompressedTimestampWithoutReference,
        },
        .{
            // Local type 0's definition has field 253, so a compressed header for it conflicts.
            .data = &test_definition_local_0 ++ [_]u8{ 0x00, 1, 0, 0, 0, 0b1_00_00001, 1, 0, 0, 0 },
            .expected = FitError.CompressedTimestampWithTimestampField,
        },
        .{
            // The largest valid timestamp, 0xFFFFFFFE, then an offset that must wrap past it.
            .data = &test_definition_local_0 ++ test_definition_local_1_compressed ++
                [_]u8{ 0x00, 0xFE, 0xFF, 0xFF, 0xFF, 0b1_01_00000, 0 },
            .expected = FitError.TimestampOverflow,
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

test "timestamp_reconstruct: windows, rollover and bounds" {
    try testing.expectEqual(@as(u32, 0), try timestamp_reconstruct(0, 0));
    try testing.expectEqual(@as(u32, 31), try timestamp_reconstruct(0, 31));
    try testing.expectEqual(@as(u32, 32), try timestamp_reconstruct(31, 0));
    try testing.expectEqual(@as(u32, 63), try timestamp_reconstruct(32, 31));
    try testing.expectEqual(@as(u32, 1000), try timestamp_reconstruct(1000, 1000 & 0x1F));

    // The largest reachable result: the last window of u32, with no rollover needed.
    const max = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, max), try timestamp_reconstruct(max - 31, 31));
    try testing.expectError(FitError.TimestampOverflow, timestamp_reconstruct(max - 1, 0));

    // Every (reference low bits, offset) pair stays within one rollover window.
    var reference: u32 = 64;
    while (reference < 96) : (reference += 1) {
        var offset: u32 = 0;
        while (offset <= 31) : (offset += 1) {
            const timestamp = try timestamp_reconstruct(reference, @intCast(offset));
            try testing.expect(timestamp >= reference and timestamp - reference < 32);
        }
    }
}

test "timestamp_field_read and fields_contain" {
    const fields = [_]FieldDefinition{
        .{ .field_definition_number = 3, .size = 1, .base_type = .uint8 },
        .{ .field_definition_number = 253, .size = 4, .base_type = .uint32 },
    };
    const raw = [_]u8{ 90, 0, 0, 1, 2 };
    try testing.expectEqual(@as(?u32, 0x02010000), timestamp_field_read(&fields, &raw, .little));
    try testing.expectEqual(@as(?u32, 0x00000102), timestamp_field_read(&fields, &raw, .big));
    const without_timestamp = timestamp_field_read(fields[0..1], raw[0..1], .little);
    try testing.expectEqual(@as(?u32, null), without_timestamp);
    try testing.expectEqual(@as(?u32, null), timestamp_field_read(&.{}, &.{}, .little));

    try testing.expect(fields_contain(&fields, 253));
    try testing.expect(!fields_contain(&fields, 4));
    try testing.expect(!fields_contain(&.{}, 253));
}

test "Parser: rejects a bad signature" {
    var bad: [12]u8 = @splat(0);
    bad[0] = 12;
    try testing.expectError(FitError.InvalidSignature, Parser.init(testing.allocator, &bad));
}

test "Parser: rejects a data size larger than the buffer" {
    const file = try test_file_build(testing.allocator, &.{ 0, 0 });
    defer testing.allocator.free(file);

    // The data section overruns the buffer.
    std.mem.writeInt(u32, file[4..8], 5, .little);
    try testing.expectError(FitError.UnexpectedEof, Parser.init(testing.allocator, file));
    // The data section fits, but leaves only one byte for the two-byte file CRC.
    std.mem.writeInt(u32, file[4..8], 3, .little);
    try testing.expectError(FitError.UnexpectedEof, Parser.init(testing.allocator, file));
    // The data section fits exactly, with no room for the file CRC at all.
    std.mem.writeInt(u32, file[4..8], 4, .little);
    try testing.expectError(FitError.UnexpectedEof, Parser.init(testing.allocator, file));
}

test "crc_compute: matches the CRC-16/ARC check value and the FIT SDK algorithm" {
    try testing.expectEqual(@as(u16, 0xBB3D), crc_compute("123456789"));
    try testing.expectEqual(@as(u16, 0), crc_compute(""));

    var byte: u32 = 0;
    while (byte <= std.math.maxInt(u8)) : (byte += 1) {
        const single = [_]u8{@intCast(byte)};
        try testing.expectEqual(test_crc_fit_sdk(&single), crc_compute(&single));
    }
    const header = [_]u8{ 14, 0x20, 0x6C, 0x08, 0x10, 0x27, 0, 0, '.', 'F', 'I', 'T' };
    try testing.expectEqual(test_crc_fit_sdk(&header), crc_compute(&header));
    const long: [1000]u8 = @splat(0xA5);
    try testing.expectEqual(test_crc_fit_sdk(&long), crc_compute(&long));
}

test "Parser: verifies the file CRC over the header and data" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0);
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    try testing.expectEqual(crc_compute(file[0 .. file.len - 2]), parser.file_crc);
    parser.deinit();

    // Any flipped bit, in the header, the data or the CRC itself, is a mismatch.
    const positions = [_]usize{ 1, header_size_short, file.len - 3, file.len - 2, file.len - 1 };
    for (positions) |position| {
        file[position] ^= 0x10;
        const result = Parser.init(testing.allocator, file);
        try testing.expectError(FitError.FileCrcMismatch, result);
        file[position] ^= 0x10;
    }
}

test "Parser: a 14-byte header's CRC is part of the file CRC" {
    const data = test_definition_local_0;
    var file: [header_size_long + data.len + crc_size]u8 = @splat(0);
    file[0] = header_size_long;
    std.mem.writeInt(u32, file[4..8], data.len, .little);
    @memcpy(file[signature_offset..][0..signature.len], signature);
    std.mem.writeInt(u16, file[12..14], crc_compute(file[0..12]), .little);
    @memcpy(file[header_size_long..][0..data.len], &data);
    test_file_crc_write(&file);

    var parser = try Parser.init(testing.allocator, &file);
    defer parser.deinit();
    try testing.expect(parser.header.crc != null);
    _ = (try parser.next()).?.definition;
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: rejects malformed records" {
    const cases = [_]struct { data: []const u8, expected: FitError }{
        .{ .data = &.{0x00}, .expected = FitError.UnknownLocalMessageType },
        .{ .data = &.{0x80}, .expected = FitError.UnknownLocalMessageType },
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
    // The data message needs 4 bytes but the data section ends after 3. The file CRC follows,
    // and it must not be read as the missing fourth byte.
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++
        [_]u8{ 0x00, 1, 2, 3 });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    try testing.expectError(FitError.UnexpectedEof, parser.next());
}

/// Chains the files built around each of `data_sections` into one buffer. Caller owns it.
fn test_files_chain(allocator: std.mem.Allocator, data_sections: []const []const u8) ![]u8 {
    assert(data_sections.len >= 1);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    for (data_sections) |data| {
        const file = try test_file_build(allocator, data);
        defer allocator.free(file);
        try buffer.appendSlice(allocator, file);
    }
    return buffer.toOwnedSlice(allocator);
}

const test_data_local_0 = [_]u8{ 0x00, 0xE8, 0x03, 0x00, 0x00 }; // Timestamp 1000.

test "Parser: reads chained files in order, an empty one included" {
    const second = [_]u8{ 0x00, 0xE9, 0x03, 0x00, 0x00 }; // Timestamp 1001.
    const buffer = try test_files_chain(testing.allocator, &.{
        &test_definition_local_0 ++ test_data_local_0,
        &.{},
        &test_definition_local_0 ++ second,
    });
    defer testing.allocator.free(buffer);

    var parser = try Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    try testing.expectEqual(@as(u32, 3), parser.file_count);
    try testing.expectEqual(@as(u32, 0), parser.file_index);
    const first_crc = parser.file_crc;

    _ = (try parser.next()).?.definition;
    const data_first = (try parser.next()).?.data;
    try testing.expectEqualSlices(u8, test_data_local_0[1..], data_first.raw);
    try testing.expectEqual(@as(u32, 0), parser.file_index);

    // The empty second file is passed over: the next record is the third file's definition.
    _ = (try parser.next()).?.definition;
    try testing.expectEqual(@as(u32, 2), parser.file_index);
    try testing.expect(parser.file_crc != first_crc);
    const data_third = (try parser.next()).?.data;
    try testing.expectEqualSlices(u8, second[1..], data_third.raw);
    try testing.expectEqual(@as(?Record, null), try parser.next());
    try testing.expectEqual(@as(?Record, null), try parser.next());
    try testing.expectEqual(@as(u32, 2), parser.file_index);
}

test "Parser: next_in_file and file_advance stop at every file, an empty one included" {
    const buffer = try test_files_chain(testing.allocator, &.{
        &test_definition_local_0 ++ test_data_local_0,
        &.{},
        &test_definition_local_0,
    });
    defer testing.allocator.free(buffer);

    var parser = try Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    var records_per_file: [3]u32 = .{ 0, 0, 0 };
    // Bounded by the file count.
    while (true) {
        while (try parser.next_in_file()) |_| records_per_file[parser.file_index] += 1;
        // The file stays exhausted until the caller moves on.
        try testing.expectEqual(@as(?Record, null), try parser.next_in_file());
        if (!parser.file_advance()) break;
    }
    try testing.expectEqualSlices(u32, &.{ 2, 0, 1 }, &records_per_file);

    // After the last file, nothing moves.
    try testing.expectEqual(@as(u32, 2), parser.file_index);
    try testing.expect(!parser.file_advance());
    try testing.expectEqual(@as(u32, 2), parser.file_index);
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: a chained file doesn't inherit definitions or the timestamp reference" {
    const cases = [_]struct { second: []const u8, expected: FitError }{
        // Local type 0 was defined only in the first file.
        .{ .second = &test_data_local_0, .expected = FitError.UnknownLocalMessageType },
        // The first file's timestamp 1000 can't anchor a compressed header in the second.
        .{
            .second = &test_definition_local_1_compressed ++ [_]u8{ 0b1_01_00101, 60 },
            .expected = FitError.CompressedTimestampWithoutReference,
        },
    };
    for (cases) |case| {
        const buffer = try test_files_chain(testing.allocator, &.{
            &test_definition_local_0 ++ test_data_local_0,
            case.second,
        });
        defer testing.allocator.free(buffer);

        var parser = try Parser.init(testing.allocator, buffer);
        defer parser.deinit();
        _ = (try parser.next()).?.definition;
        _ = (try parser.next()).?.data;
        if (case.expected == FitError.CompressedTimestampWithoutReference) {
            _ = (try parser.next()).?.definition;
        }
        try testing.expectError(case.expected, parser.next());
        try testing.expectEqual(@as(u32, 1), parser.file_index);
    }
}

test "Parser: a record stays valid after a redefinition and a file switch" {
    const buffer = try test_files_chain(testing.allocator, &.{
        &test_definition_local_0 ++ test_data_local_0 ++ [_]u8{
            0x40, 0, 0, 21, 0, 1, 0, 1, 0, // Local type 0 again: global 21, one 1-byte field.
        },
        &test_definition_local_0,
    });
    defer testing.allocator.free(buffer);

    var parser = try Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    const held = (try parser.next()).?.data;
    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.definition;
    try testing.expectEqual(@as(u32, 1), parser.file_index);
    try testing.expectEqual(@as(?Record, null), try parser.next());

    // The first definition was replaced, then the whole table was reset for the second file.
    try testing.expectEqual(@as(usize, 1), held.fields.len);
    try testing.expectEqual(timestamp_field_number, held.fields[0].field_definition_number);
    try testing.expectEqual(BaseType.uint32, held.fields[0].base_type);
    var iterator = held.fields_iterator();
    try testing.expectEqual(Value{ .unsigned = 1000 }, iterator.next().?.element(0));
}

test "Parser.init: any bad chained file rejects the whole buffer" {
    const valid = try test_files_chain(testing.allocator, &.{ &test_definition_local_0, &.{} });
    defer testing.allocator.free(valid);
    // The second file is exactly file_size_min bytes, the smallest valid file.
    try testing.expectEqual(file_size_min, valid.len - header_size_short -
        test_definition_local_0.len - crc_size);
    var parser = try Parser.init(testing.allocator, valid);
    try testing.expectEqual(@as(u32, 2), parser.file_count);
    parser.deinit();

    // Truncated anywhere in the second file: its header, or its CRC.
    const first_size = valid.len - file_size_min;
    for ([_]usize{ 1, header_size_short - 1, header_size_short, file_size_min - 1 }) |size| {
        const truncated = Parser.init(testing.allocator, valid[0 .. first_size + size]);
        try testing.expectError(FitError.UnexpectedEof, truncated);
    }

    const buffer = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(buffer);
    buffer[buffer.len - 1] ^= 0x10;
    try testing.expectError(FitError.FileCrcMismatch, Parser.init(testing.allocator, buffer));
    buffer[buffer.len - 1] ^= 0x10;
    buffer[first_size + signature_offset] = 'G';
    try testing.expectError(FitError.InvalidSignature, Parser.init(testing.allocator, buffer));
    buffer[first_size + signature_offset] = '.';
    buffer[first_size] = 0;
    try testing.expectError(FitError.InvalidHeaderSize, Parser.init(testing.allocator, buffer));
}

test "BaseType.from_byte: accepts exactly the 17 canonical bytes" {
    var accepted: u32 = 0;
    var byte: u32 = 0;
    while (byte <= std.math.maxInt(u8)) : (byte += 1) {
        const base_type = BaseType.from_byte(@intCast(byte)) catch |err| {
            try testing.expectEqual(FitError.InvalidBaseType, err);
            continue;
        };
        try testing.expectEqual(@as(u8, @intCast(byte)), @backingInt(base_type));
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
    const ones_4: [4]u8 = @splat(0xFF);
    const zeros_4: [4]u8 = @splat(0);
    const ones_8: [8]u8 = @splat(0xFF);
    const zeros_8: [8]u8 = @splat(0);
    try testing.expectEqual(@as(?Value, null), value_decode(.uint32, &ones_4, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint32z, &zeros_4, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint64, &ones_8, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.uint64z, &zeros_8, little));

    const max_valid = std.math.maxInt(u64) - 1;
    const bytes = [_]u8{0xFE} ++ @as([7]u8, @splat(0xFF));
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
    const sint64_invalid = @as([7]u8, @splat(0xFF)) ++ [_]u8{0x7F};
    try testing.expectEqual(@as(?Value, null), value_decode(.sint64, &sint64_invalid, little));
    const sint64_min = @as([7]u8, @splat(0)) ++ [_]u8{0x80};
    const min = std.math.minInt(i64);
    try testing.expectEqual(Value{ .signed = min }, value_decode(.sint64, &sint64_min, little).?);
}

test "value_decode: floats compare the sentinel as bits" {
    const little = std.builtin.Endian.little;
    const one_float32 = [_]u8{ 0x00, 0x00, 0x80, 0x3F };
    try testing.expectEqual(Value{ .float = 1.0 }, value_decode(.float32, &one_float32, little).?);
    const half_float64 = [_]u8{ 0x3F, 0xE0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(Value{ .float = 0.5 }, value_decode(.float64, &half_float64, .big).?);
    const ones_4: [4]u8 = @splat(0xFF);
    const ones_8: [8]u8 = @splat(0xFF);
    try testing.expectEqual(@as(?Value, null), value_decode(.float32, &ones_4, little));
    try testing.expectEqual(@as(?Value, null), value_decode(.float64, &ones_8, little));

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
    const ones_max: [255]u8 = @splat(0xFF);
    try testing.expectEqual(@as(?Value, null), value_decode(.byte, &ones_max, little));
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

    const bytes_max: [255]u8 = @splat(0);
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

/// Definition: local type 3, little endian, global message 20, one uint8 standard field
/// (heart rate), then two developer fields: index 0 field 1 (2 bytes) and index 1 field 253
/// (4 bytes). The second is numbered like a timestamp, but developer numbers are their own space.
const test_definition_local_3_developer = [_]u8{
    0x63, 0, 0, 20, 0, 1, 3, 1, 0x02, // Header, fixed part, heart rate.
    2, 1, 2, 0, 253, 4, 1, // Developer field count, then the two developer fields.
};

test "Parser: developer fields follow the standard fields" {
    const file = try test_file_build(testing.allocator, &test_definition_local_3_developer ++
        [_]u8{ 0x03, 150, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    const definition = (try parser.next()).?.definition;
    try testing.expectEqual(@as(usize, 1), definition.fields.len);
    try testing.expectEqual(@as(usize, 2), definition.developer_fields.len);
    try testing.expectEqual(@as(u32, 7), definition.message_size());
    const second = definition.developer_fields[1];
    try testing.expectEqual(@as(u8, 253), second.field_number);
    try testing.expectEqual(@as(u8, 4), second.size);
    try testing.expectEqual(@as(u8, 1), second.developer_data_index);

    const data = (try parser.next()).?.data;
    try testing.expectEqualSlices(u8, &.{150}, data.raw);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF }, data.developer_raw);
    var standard = data.fields_iterator();
    try testing.expectEqual(Value{ .unsigned = 150 }, standard.next().?.element(0).?);
    try testing.expectEqual(@as(?Field, null), standard.next());

    var iterator = data.developer_fields_iterator();
    const counter = iterator.next().?;
    try testing.expectEqual(@as(u8, 0), counter.developer_data_index);
    try testing.expectEqual(@as(u8, 1), counter.field_number);
    const counter_field = try counter.field(.uint16);
    try testing.expectEqual(Value{ .unsigned = 0x1234 }, counter_field.element(0).?);
    // Developer field 253 isn't the timestamp: it is raw bytes whose type only 206 knows.
    const other = iterator.next().?;
    try testing.expectEqual(@as(?Value, null), (try other.field(.uint32)).element(0));
    try testing.expectEqual(@as(?DeveloperField, null), iterator.next());
    try testing.expectEqual(@as(?DeveloperField, null), iterator.next());
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: developer fields are big endian with their message, and count 0 is valid" {
    // Local type 1, big endian, global 20, no standard fields, one 2-byte developer field.
    const big_endian = [_]u8{ 0x61, 0, 1, 0, 20, 0, 1, 7, 2, 0 };
    // Local type 2 with the developer-fields bit set, but no fields of either kind.
    const empty = [_]u8{ 0x62, 0, 0, 20, 0, 0, 0 };
    const file = try test_file_build(
        testing.allocator,
        &big_endian ++ [_]u8{ 0x01, 0x12, 0x34 } ++ empty ++ [_]u8{0x02},
    );
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(usize, 0), data.raw.len);
    var iterator = data.developer_fields_iterator();
    const field = try iterator.next().?.field(.uint16);
    try testing.expectEqual(Value{ .unsigned = 0x1234 }, field.element(0).?);

    const empty_definition = (try parser.next()).?.definition;
    try testing.expectEqual(@as(usize, 0), empty_definition.developer_fields.len);
    const empty_data = (try parser.next()).?.data;
    try testing.expectEqual(@as(usize, 0), empty_data.developer_raw.len);
    iterator = empty_data.developer_fields_iterator();
    try testing.expectEqual(@as(?DeveloperField, null), iterator.next());
}

test "Parser: a compressed-timestamp message can carry developer fields" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0 ++
        test_definition_local_3_developer ++ [_]u8{
        0x00, 0x10, 0x00, 0x00, 0x00, // Timestamp 16.
        0b1_11_10010, 150, 1, 0, 2, 0, 0, 0, // Local type 3, offset 18: timestamp 18.
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.data;
    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(?u32, 18), data.compressed_timestamp);
    try testing.expectEqual(@as(usize, 6), data.developer_raw.len);
}

test "Parser: redefining a type with developer fields frees them" {
    const file = try test_file_build(testing.allocator, &test_definition_local_3_developer ++
        test_definition_local_3_developer ++ [_]u8{ 0x43, 0, 0, 20, 0, 0 });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.definition;
    const last = (try parser.next()).?.definition;
    try testing.expectEqual(@as(usize, 0), last.developer_fields.len);
    // The testing allocator fails the test if either replaced definition leaked.
}

test "Parser: rejects malformed developer field definitions without leaking" {
    const cases = [_]struct { data: []const u8, expected: FitError }{
        // The count byte is missing after one standard field.
        .{ .data = &.{ 0x60, 0, 0, 0, 0, 1, 0, 1, 0x02 }, .expected = FitError.UnexpectedEof },
        // Two developer fields announced, one present.
        .{ .data = &.{ 0x60, 0, 0, 0, 0, 0, 2, 0, 1, 0 }, .expected = FitError.UnexpectedEof },
        // A zero-size developer field, after a valid standard field and a valid developer one.
        .{
            .data = &.{ 0x60, 0, 0, 0, 0, 1, 0, 1, 0x02, 2, 0, 1, 0, 1, 0, 0 },
            .expected = FitError.InvalidFieldSize,
        },
        // The data message is one byte short of its developer fields.
        .{
            .data = &test_definition_local_3_developer ++ [_]u8{ 0x03, 150, 1, 2, 3, 4, 5 },
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

test "parse_developer_field_definition: size must be nonzero" {
    const field = try parse_developer_field_definition(&.{ 9, 255, 3 });
    try testing.expectEqual(@as(u8, 9), field.field_number);
    try testing.expectEqual(@as(u8, 255), field.size);
    try testing.expectEqual(@as(u8, 3), field.developer_data_index);
    _ = try parse_developer_field_definition(&.{ 0, 1, 0 });
    _ = try parse_developer_field_definition(&.{ 255, 1, 255 });
    const zero = parse_developer_field_definition(&.{ 0, 0, 0 });
    try testing.expectError(FitError.InvalidFieldSize, zero);
}

test "DeveloperField.field: the size must fit the described base type" {
    const bytes_max: [255]u8 = @splat(0x41);
    var developer = DeveloperField{
        .field_number = 0,
        .developer_data_index = 0,
        .endian = .little,
        .raw = &.{ 1, 0, 2, 0 },
    };
    const pair = try developer.field(.uint16);
    try testing.expectEqual(@as(u8, 2), pair.element_count());
    try testing.expectEqual(Value{ .unsigned = 2 }, pair.element(1).?);
    try testing.expectEqual(@as(u8, 1), (try developer.field(.uint32)).element_count());
    try testing.expectError(FitError.InvalidFieldSize, developer.field(.float64));

    developer.raw = bytes_max[0..3];
    try testing.expectError(FitError.InvalidFieldSize, developer.field(.uint16));
    try testing.expectEqual(@as(u8, 3), (try developer.field(.uint8)).element_count());
    developer.raw = &bytes_max;
    const text = try developer.field(.string);
    try testing.expectEqual(@as(usize, 255), text.element(0).?.string.len);
    try testing.expectEqual(@as(u8, 1), (try developer.field(.byte)).element_count());
    developer.raw = bytes_max[0..1];
    try testing.expectError(FitError.InvalidFieldSize, developer.field(.sint16));
}

/// Reads a field_description built from `fields` and their little-endian `raw` bytes.
fn test_description_parse(
    fields: []const FieldDefinition,
    raw: []const u8,
) FitError!DeveloperFieldDescription {
    const data = DataMessage{
        .local_message_type = 0,
        .global_message_number = field_description_message,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = fields,
        .raw = raw,
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
    return parse_developer_field_description(&data);
}

fn test_field(number: u8, size: u8, base_type: BaseType) FieldDefinition {
    return .{ .field_definition_number = number, .size = size, .base_type = base_type };
}

/// Developer data index, field number and base type, each a uint8.
const test_description_required = [_]FieldDefinition{
    test_field(0, 1, .uint8), test_field(1, 1, .uint8), test_field(2, 1, .uint8),
};

test "parse_developer_field_description: every field read, the others ignored" {
    const fields = test_description_required ++ [_]FieldDefinition{
        test_field(3, 8, .string), test_field(6, 1, .uint8),  test_field(7, 1, .sint8),
        test_field(8, 4, .string), test_field(15, 1, .uint8), test_field(4, 1, .uint8),
    };
    // 254 is the largest index: 255 is the uint8 invalid sentinel, so it means "absent".
    const raw = [_]u8{ 254, 7, 0x84 } ++ "Power\x00\x00\x00".* ++ [_]u8{ 10, 0xFB } ++
        "W\x00\x00\x00".* ++ [_]u8{ 3, 1 };
    const description = try test_description_parse(&fields, &raw);
    try testing.expectEqual(@as(u8, 254), description.developer_data_index);
    try testing.expectEqual(@as(u8, 7), description.field_number);
    try testing.expectEqual(BaseType.uint16, description.base_type);
    try testing.expectEqualStrings("Power", description.name.?);
    try testing.expectEqualStrings("W", description.units);
    try testing.expectEqual(@as(u8, 10), description.scale);
    try testing.expectEqual(@as(i8, -5), description.offset);
}

test "parse_developer_field_description: absent or invalid optional fields take defaults" {
    const minimal = try test_description_parse(&test_description_required, &.{ 0, 0, 0x07 });
    try testing.expectEqual(DeveloperFieldDescription{
        .developer_data_index = 0,
        .field_number = 0,
        .base_type = .string,
    }, minimal);

    const fields = test_description_required ++ [_]FieldDefinition{
        test_field(3, 2, .string), test_field(6, 1, .uint8),
        test_field(7, 1, .sint8),  test_field(8, 1, .string),
    };
    const sentinels = try test_description_parse(&fields, &.{ 0, 0, 0x07, 0, 'x', 0xFF, 0x7F, 0 });
    try testing.expectEqual(minimal, sentinels);
}

test "parse_developer_field_description: rejects a description it can't use" {
    const required = &test_description_required;
    const u8_scale = [_]FieldDefinition{test_field(6, 1, .uint8)};
    const u8_name = [_]FieldDefinition{test_field(3, 1, .uint8)};
    const u8_offset = [_]FieldDefinition{test_field(7, 1, .uint8)};
    const sint8_index = test_field(0, 1, .sint8);
    const uint16_number = test_field(1, 2, .uint16);
    const array_number = test_field(1, 2, .uint8);
    const Case = struct { fields: []const FieldDefinition, raw: []const u8 };
    const cases = [_]Case{
        // Each required field missing in turn, or holding its invalid sentinel.
        .{ .fields = required[1..], .raw = &.{ 0, 0x02 } },
        .{ .fields = &.{ required[0], required[2] }, .raw = &.{ 0, 0x02 } },
        .{ .fields = required[0..2], .raw = &.{ 0, 0 } },
        .{ .fields = required, .raw = &.{ 0xFF, 0, 0x02 } },
        .{ .fields = required, .raw = &.{ 0, 0, 0xFF } },
        // Zero scale.
        .{ .fields = required ++ &u8_scale, .raw = &.{ 0, 0, 0x02, 0 } },
        // A name that isn't a string, an offset that isn't signed, an index that is.
        .{ .fields = required ++ &u8_name, .raw = &.{ 0, 0, 0x02, 1 } },
        .{ .fields = required ++ &u8_offset, .raw = &.{ 0, 0, 0x02, 1 } },
        .{ .fields = &.{ sint8_index, required[1], required[2] }, .raw = &.{ 0, 0, 2 } },
        // A field number of 256, or given as an array.
        .{ .fields = &.{ required[0], uint16_number, required[2] }, .raw = &.{ 0, 0, 1, 2 } },
        .{ .fields = &.{ required[0], array_number, required[2] }, .raw = &.{ 0, 1, 1, 2 } },
    };
    for (cases) |case| {
        const result = test_description_parse(case.fields, case.raw);
        try testing.expectError(FitError.InvalidFieldDescription, result);
    }
    // A base type byte that isn't canonical.
    const uint16_without_flag = test_description_parse(required, &.{ 0, 0, 0x04 });
    try testing.expectError(FitError.InvalidBaseType, uint16_without_flag);
    // A uint16 field number of 255 fits a u8: the boundary below the one rejected above.
    const wide = [_]FieldDefinition{ required[0], uint16_number, required[2] };
    const description = try test_description_parse(&wide, &.{ 0, 255, 0, 0x02 });
    try testing.expectEqual(@as(u8, 255), description.field_number);
}

/// Local type 0 as field_description: developer data index, field number, base type, then a
/// 4-byte name.
const test_definition_local_0_description = [_]u8{
    0x40, 0, 0, 206, 0, 4, 0, 1, 0x02, 1, 1, 0x02, 2, 1, 0x02, 3, 4, 0x07,
};

test "Parser: developer fields are looked up in the file's field_description messages" {
    const file = try test_file_build(testing.allocator, &test_definition_local_0_description ++
        test_definition_local_3_developer ++
        [_]u8{ 0x03, 150, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF } ++ // Before the description.
        [_]u8{ 0x00, 0, 1, 0x84, 'r', 'p', 'm', 0 } ++ // Index 0, field 1: uint16 "rpm".
        [_]u8{ 0x03, 150, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF } ++
        [_]u8{ 0x00, 0, 1, 0x02, 'r', 0, 0, 0 } ++ // Described again: uint8 "r".
        [_]u8{ 0x03, 150, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    const descriptions = &parser.developer_field_descriptions;
    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.definition;
    var data = (try parser.next()).?.data;
    var iterator = data.developer_fields_iterator();
    try testing.expectEqual(null, descriptions.get(&iterator.next().?));

    _ = (try parser.next()).?.data;
    try testing.expectEqual(@as(u32, 1), descriptions.count());
    data = (try parser.next()).?.data;
    iterator = data.developer_fields_iterator();
    const developer = iterator.next().?;
    const description = descriptions.get(&developer).?;
    try testing.expectEqualStrings("rpm", description.name.?);
    const field = try developer.field(description.base_type);
    try testing.expectEqual(Value{ .unsigned = 0x1234 }, field.element(0).?);
    // Index 1, field 253 was never described.
    try testing.expectEqual(null, descriptions.get(&iterator.next().?));

    _ = (try parser.next()).?.data;
    try testing.expectEqual(@as(u32, 1), descriptions.count());
    data = (try parser.next()).?.data;
    iterator = data.developer_fields_iterator();
    const replaced = descriptions.get(&iterator.next().?).?;
    try testing.expectEqual(BaseType.uint8, replaced.base_type);
    try testing.expectEqualStrings("r", replaced.name.?);
    try testing.expectEqual(@as(?Record, null), try parser.next());
}

test "Parser: a chained file doesn't inherit developer field descriptions" {
    const buffer = try test_files_chain(testing.allocator, &.{
        &test_definition_local_0_description ++ [_]u8{ 0x00, 0, 1, 0x84, 'r', 0, 0, 0 },
        &test_definition_local_3_developer ++ [_]u8{ 0x03, 150, 0x34, 0x12, 1, 2, 3, 4 },
    });
    defer testing.allocator.free(buffer);

    var parser = try Parser.init(testing.allocator, buffer);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    _ = (try parser.next()).?.data;
    try testing.expectEqual(@as(u32, 1), parser.developer_field_descriptions.count());
    _ = (try parser.next()).?.definition;
    const data = (try parser.next()).?.data;
    try testing.expectEqual(@as(u32, 1), parser.file_index);
    try testing.expectEqual(@as(u32, 0), parser.developer_field_descriptions.count());
    var iterator = data.developer_fields_iterator();
    const developer = iterator.next().?;
    const description = parser.developer_field_descriptions.get(&developer);
    try testing.expectEqual(@as(?DeveloperFieldDescription, null), description);
}

test "Parser: a field_description without a base type fails the record" {
    // Local type 0 as field_description with only fields 0 and 1.
    const file = try test_file_build(testing.allocator, &[_]u8{
        0x40, 0, 0, 206, 0, 2, 0, 1, 0x02, 1, 1, 0x02, 0x00, 0, 1,
    });
    defer testing.allocator.free(file);

    var parser = try Parser.init(testing.allocator, file);
    defer parser.deinit();
    _ = (try parser.next()).?.definition;
    try testing.expectError(FitError.InvalidFieldDescription, parser.next());
    try testing.expectEqual(@as(u32, 0), parser.developer_field_descriptions.count());
}

test "DeveloperFieldDescriptions: keys by developer data index and field number" {
    var descriptions = DeveloperFieldDescriptions{};
    defer descriptions.deinit(testing.allocator);
    const corners = [_][2]u8{ .{ 0, 0 }, .{ 0, 255 }, .{ 255, 0 }, .{ 255, 255 } };
    for (corners) |corner| {
        try descriptions.put(testing.allocator, .{
            .developer_data_index = corner[0],
            .field_number = corner[1],
            .base_type = .uint8,
        });
    }
    try testing.expectEqual(@as(u32, 4), descriptions.count());
    for (corners) |corner| {
        const developer = DeveloperField{
            .developer_data_index = corner[0],
            .field_number = corner[1],
            .endian = .little,
            .raw = &.{0},
        };
        try testing.expect(descriptions.get(&developer) != null);
    }
    const other = DeveloperField{
        .developer_data_index = 1,
        .field_number = 0,
        .endian = .little,
        .raw = &.{0},
    };
    try testing.expectEqual(@as(?DeveloperFieldDescription, null), descriptions.get(&other));
    descriptions.clear();
    try testing.expectEqual(@as(u32, 0), descriptions.count());
}
