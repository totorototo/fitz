//! The FIT profile: names for global message numbers, name, units, scale and offset for their
//! fields, and names for the values of enumerated fields. The tables are generated from
//! Garmin's FIT SDK into profile_generated.zig; this file holds the lookups and conversions.
//! A field can have subfields, other meanings selected by another field of the same message:
//! `data_field_profile` applies them. Components are not applied yet. Pure lookups, no
//! allocation.
//!
//! FIT scaling: physical value = raw / scale - offset. Dates and positions are not scaled but
//! converted, and `FieldProfile.kind` says which conversion applies.

const std = @import("std");
const assert = std.debug.assert;
const fit = @import("fit.zig");
const generated = @import("profile_generated.zig");

/// The FIT SDK profile version the tables were generated from.
pub const version = generated.version;

/// Seconds from the Unix epoch to the FIT epoch, 1989-12-31 00:00:00 UTC.
pub const fit_epoch_unix_s: u64 = 631065600;
/// A FIT date_time below this counts seconds since the device powered on, not since the FIT
/// epoch, so it is not a calendar date.
pub const date_time_absolute_min: u32 = 0x10000000;
/// 2^31 semicircles make 180 degrees.
const semicircles_per_180_degrees: f64 = 2147483648.0;

/// number: a plain number, scaled when the entry has a scale or offset. date_time: uint32
/// seconds since the FIT epoch, in UTC, units "s". local_date_time: the same in the device's
/// local time zone. semicircles: a sint32 angle, units "semicircles".
pub const Kind = generated.Kind;

/// Converts a FIT date_time to Unix seconds. Returns null for a value below
/// `date_time_absolute_min`, which is time since power-on and has no calendar date.
pub fn date_time_unix_s(date_time: u32) ?u64 {
    if (date_time < date_time_absolute_min) return null;
    const unix_s = fit_epoch_unix_s + date_time;
    assert(unix_s > fit_epoch_unix_s);
    return unix_s;
}

pub fn semicircles_degrees(semicircles: f64) f64 {
    const degrees = semicircles * 180.0 / semicircles_per_180_degrees;
    // A sint32 can't hold more than half a turn either way.
    assert(@abs(degrees) <= 180.0 or @abs(semicircles) > semicircles_per_180_degrees);
    return degrees;
}

/// A masked type has at most this many flags; the generator checks it.
const masked_flag_count_max = 4;

pub const MaskedValue = struct {
    number: u64,
    flag_names: [masked_flag_count_max][]const u8 = undefined,
    flag_count: u8 = 0,

    /// The set flags, in increasing bit order.
    pub fn flags(self: *const MaskedValue) []const []const u8 {
        assert(self.flag_count <= masked_flag_count_max);
        return self.flag_names[0..self.flag_count];
    }
};

pub const FieldProfile = struct {
    /// snake_case, as in the FIT profile.
    name: []const u8,
    kind: Kind = .number,
    /// Empty when the field is dimensionless (an enum, an index, a count).
    units: []const u8 = "",
    /// Positive, and not always a whole number (e.g. 10430.38).
    scale: f64 = 1,
    offset: i16 = 0,
    /// Index into the generated types when the field's values have names.
    type_index: ?u16 = null,

    pub fn is_scaled(self: *const FieldProfile) bool {
        assert(self.scale > 0);
        return self.scale != 1 or self.offset != 0;
    }

    /// The profile's name for an unsigned value (`sport` 1 is "running"), or null when the
    /// field has no named values or this value isn't one of them. A bit-field type names only
    /// its single bits, so a combination of them has no name. A masked type's values are
    /// numbers, not names: see `masked`.
    pub fn value_name(self: *const FieldProfile, value: fit.Value) ?[]const u8 {
        const type_index = self.type_index orelse return null;
        assert(self.kind == .number);
        if (generated.types[type_index].mask != 0) return null;
        const unsigned = switch (value) {
            .unsigned => |unsigned| unsigned,
            .signed, .float, .string, .bytes => return null,
        };
        const values = generated.types[type_index].values;
        const index = std.sort.binarySearch(
            generated.ValueName,
            values,
            unsigned,
            value_order,
        ) orelse return null;
        assert(values[index].value == unsigned);
        return values[index].name;
    }

    /// Splits a value of a masked type (message_index, left_right_balance) into the number under
    /// the mask and the names of the flags set above it. Null when the field's type isn't
    /// masked, or when a bit is set that is neither under the mask nor a known flag, so no bit
    /// is silently dropped.
    pub fn masked(self: *const FieldProfile, value: fit.Value) ?MaskedValue {
        const type_index = self.type_index orelse return null;
        const value_type = &generated.types[type_index];
        if (value_type.mask == 0) return null;
        assert(value_type.values.len <= masked_flag_count_max);
        const unsigned = switch (value) {
            .unsigned => |unsigned| unsigned,
            .signed, .float, .string, .bytes => return null,
        };

        var result = MaskedValue{ .number = unsigned & value_type.mask };
        var bits_named: u64 = value_type.mask;
        for (value_type.values) |flag| {
            if (unsigned & flag.value == 0) continue;
            result.flag_names[result.flag_count] = flag.name;
            result.flag_count += 1;
            bits_named |= flag.value;
        }
        if (unsigned & ~bits_named != 0) return null;
        assert(result.number <= value_type.mask);
        return result;
    }

    /// Applies scale and offset to one element. Returns null for a string or byte value: the
    /// file chose a base type the profile doesn't expect for this field, and there is no
    /// number to scale.
    pub fn scaled(self: *const FieldProfile, value: fit.Value) ?f64 {
        assert(self.scale > 0);
        const raw: f64 = switch (value) {
            .unsigned => |unsigned| @floatFromInt(unsigned),
            .signed => |signed| @floatFromInt(signed),
            .float => |float| float,
            .string, .bytes => return null,
        };
        const scale = self.scale;
        const offset: f64 = @floatFromInt(self.offset);
        // (raw - offset * scale) / scale rather than raw / scale - offset: for integer raw
        // values the subtraction is exact, so the one division is the only rounding, and the
        // result prints as its shortest decimal (24.2, not 24.200000000000045).
        return (raw - offset * scale) / scale;
    }
};

/// A developer field's profile, from its field_description: the same units, scale and offset
/// rules as a built-in field. The name is the file's own, not necessarily snake_case, and is
/// empty when the description has none.
pub fn developer_field_profile(description: *const fit.DeveloperFieldDescription) FieldProfile {
    assert(description.scale >= 1);
    const profile = FieldProfile{
        .name = description.name orelse "",
        .units = description.units,
        .scale = @floatFromInt(description.scale),
        .offset = description.offset,
    };
    assert(profile.kind == .number);
    return profile;
}

fn value_order(value: u64, entry: generated.ValueName) std.math.Order {
    return std.math.order(value, entry.value);
}

fn message_order(number: u16, message: generated.Message) std.math.Order {
    return std.math.order(number, message.number);
}

fn field_order(number: u8, field: generated.Field) std.math.Order {
    return std.math.order(number, field.number);
}

fn message_find(global_message_number: u16) ?*const generated.Message {
    const messages = &generated.messages;
    const index = std.sort.binarySearch(
        generated.Message,
        messages,
        global_message_number,
        message_order,
    ) orelse return null;
    assert(messages[index].number == global_message_number);
    return &messages[index];
}

/// Returns null for a message number the profile doesn't define.
pub fn message_name(global_message_number: u16) ?[]const u8 {
    const message = message_find(global_message_number) orelse return null;
    assert(message.name.len > 0);
    return message.name;
}

fn field_find(global_message_number: u16, field_definition_number: u8) ?*const generated.Field {
    const message = message_find(global_message_number) orelse return null;
    const index = std.sort.binarySearch(
        generated.Field,
        message.fields,
        field_definition_number,
        field_order,
    ) orelse return null;
    const field = &message.fields[index];
    assert(field.number == field_definition_number);
    return field;
}

/// A field's own profile, without its subfields: the name the profile gives the field number
/// whatever the rest of the message holds. Returns null when the message or the field isn't in
/// the profile.
pub fn field_profile(global_message_number: u16, field_definition_number: u8) ?FieldProfile {
    const field = field_find(global_message_number, field_definition_number) orelse return null;
    return profile_make(field);
}

/// The profile of one of a data message's fields, with the subfield the message selects applied
/// (`event.data` is `timer_trigger` when `event` is `timer`). When several subfields match, the
/// first in profile order applies, as in Garmin's decoders. The field's own profile when none
/// matches: a referenced field is missing, holds no data or holds another value. Returns null
/// when the message or the field isn't in the profile.
pub fn data_field_profile(data: *const fit.DataMessage, field_definition_number: u8) ?FieldProfile {
    const field = field_find(data.global_message_number, field_definition_number) orelse
        return null;
    // Bounded by the profile: at most 23 subfields, each with at most 8 references.
    for (field.subfields) |*subfield| {
        assert(subfield.references.len >= 1);
        for (subfield.references) |reference| {
            // A field never selects its own meaning.
            assert(reference.field_number != field_definition_number);
            const value = reference_value(data, reference.field_number) orelse continue;
            if (value == reference.value) return profile_make(subfield);
        }
    }
    return profile_make(field);
}

/// The raw value of a data message's field, when it is present, holds one element and that
/// element is unsigned and not the "no data" sentinel. A reference is always an enum, uint8 or
/// uint16 field, so any other shape can't match one.
fn reference_value(data: *const fit.DataMessage, field_definition_number: u8) ?u64 {
    var iterator = data.fields_iterator();
    // Bounded by the definition's field count, at most 255.
    while (iterator.next()) |field| {
        if (field.field_definition_number != field_definition_number) continue;
        if (field.element_count() != 1) return null;
        const value = field.element(0) orelse return null;
        return switch (value) {
            .unsigned => |unsigned| unsigned,
            .signed, .float, .string, .bytes => null,
        };
    }
    return null;
}

/// `generated.Field` and `generated.Subfield` share the profile's fields but are distinct
/// types, so one generic constructor keeps the two mappings from drifting apart.
fn profile_make(entry: anytype) FieldProfile {
    comptime assert(@TypeOf(entry) == *const generated.Field or
        @TypeOf(entry) == *const generated.Subfield);
    const profile = FieldProfile{
        .name = entry.name,
        .kind = entry.kind,
        .units = entry.units,
        .scale = entry.scale,
        .offset = entry.offset,
        .type_index = entry.type_index,
    };
    assert(profile.name.len > 0);
    assert(profile.scale > 0);
    return profile;
}

const testing = std.testing;

test "message_name: known and unknown numbers" {
    try testing.expectEqualStrings("file_id", message_name(0).?);
    try testing.expectEqualStrings("record", message_name(20).?);
    try testing.expectEqualStrings("developer_data_id", message_name(207).?);
    // The first and last messages, then gaps: between them, past the last, and the
    // manufacturer-specific range from 0xFF00.
    try testing.expectEqualStrings("file_id", message_name(generated.messages[0].number).?);
    try testing.expectEqualStrings("sleep_disruption_overnight_severity", message_name(471).?);
    try testing.expectEqual(@as(?[]const u8, null), message_name(325));
    try testing.expectEqual(@as(?[]const u8, null), message_name(472));
    try testing.expectEqual(@as(?[]const u8, null), message_name(0xFF00));
    try testing.expectEqual(@as(?[]const u8, null), message_name(std.math.maxInt(u16)));
}

test "field_profile: lookups, including edge field numbers" {
    const heart_rate = field_profile(20, 3).?;
    try testing.expectEqualStrings("heart_rate", heart_rate.name);
    try testing.expectEqualStrings("bpm", heart_rate.units);
    try testing.expect(!heart_rate.is_scaled());

    const altitude = field_profile(20, 78).?;
    try testing.expectEqual(@as(f64, 5), altitude.scale);
    try testing.expectEqual(@as(i16, 500), altitude.offset);
    try testing.expect(altitude.is_scaled());

    try testing.expectEqualStrings("type", field_profile(0, 0).?.name);
    try testing.expectEqualStrings("message_index", field_profile(18, 254).?.name);

    // A scale that isn't a whole number.
    try testing.expectEqual(@as(f64, 10430.38), field_profile(178, 2).?.scale);

    // Unknown field (between known ones, and the largest number), and unknown message.
    try testing.expectEqual(@as(?FieldProfile, null), field_profile(20, 14));
    try testing.expectEqual(@as(?FieldProfile, null), field_profile(20, 255));
    try testing.expectEqual(@as(?FieldProfile, null), field_profile(325, 0));
}

test "generated tables: sorted, unique and well-formed" {
    for (generated.messages, 0..) |message, index| {
        if (index > 0) try testing.expect(generated.messages[index - 1].number < message.number);
        // A message can have no fields: pad (105) only fills space.
        try name_expect_snake_case(message.name);
        for (message.fields, 0..) |field, field_index| {
            if (field_index > 0) {
                try testing.expect(message.fields[field_index - 1].number < field.number);
            }
            try field_expect_well_formed(&field);
            for (message.fields[field_index + 1 ..]) |other| {
                try testing.expect(!std.mem.eql(u8, field.name, other.name));
            }
            try subfields_expect_well_formed(&message, &field);
        }
    }
    for (generated.types) |value_type| {
        try testing.expect(value_type.values.len > 0);
        for (value_type.values[1..], 1..) |entry, index| {
            try testing.expect(value_type.values[index - 1].value < entry.value);
        }
    }
}

/// A subfield's name is unique in its message, among fields and other subfields, and each of
/// its references names another field of the same message.
fn subfields_expect_well_formed(
    message: *const generated.Message,
    field: *const generated.Field,
) !void {
    for (field.subfields) |subfield| {
        try field_expect_well_formed(&subfield);
        try testing.expect(subfield.references.len >= 1);
        for (subfield.references) |reference| {
            try testing.expect(reference.field_number != field.number);
            try testing.expect(field_find(message.number, reference.field_number) != null);
        }
        var name_count: u32 = 0;
        for (message.fields) |other| {
            if (std.mem.eql(u8, subfield.name, other.name)) name_count += 1;
            for (other.subfields) |other_subfield| {
                if (std.mem.eql(u8, subfield.name, other_subfield.name)) name_count += 1;
            }
        }
        try testing.expectEqual(@as(u32, 1), name_count);
    }
}

fn field_expect_well_formed(field: anytype) !void {
    try name_expect_snake_case(field.name);
    try testing.expect(field.scale > 0);
    // A converted field is never also scaled, and its units describe the raw value.
    switch (field.kind) {
        .number => if (field.type_index) |type_index| {
            try testing.expect(type_index < generated.types.len);
        },
        .date_time, .local_date_time => {
            try testing.expect(field.scale == 1 and field.offset == 0);
            try testing.expectEqualStrings("s", field.units);
            try testing.expectEqual(@as(?u16, null), field.type_index);
        },
        .semicircles => {
            try testing.expect(field.scale == 1 and field.offset == 0);
            try testing.expectEqualStrings("semicircles", field.units);
            try testing.expectEqual(@as(?u16, null), field.type_index);
        },
    }
}

fn name_expect_snake_case(name: []const u8) !void {
    try testing.expect(name.len > 0);
    for (name) |character| {
        try testing.expect(std.ascii.isLower(character) or
            std.ascii.isDigit(character) or character == '_');
    }
}

test "FieldProfile.value_name: named values, bits, and values without a name" {
    const sport = field_profile(18, 5).?;
    try testing.expectEqualStrings("generic", sport.value_name(.{ .unsigned = 0 }).?);
    try testing.expectEqualStrings("running", sport.value_name(.{ .unsigned = 1 }).?);
    try testing.expectEqualStrings("all", sport.value_name(.{ .unsigned = 254 }).?);
    try testing.expectEqual(@as(?[]const u8, null), sport.value_name(.{ .unsigned = 253 }));
    try testing.expectEqual(@as(?[]const u8, null), sport.value_name(.{ .signed = 1 }));
    try testing.expectEqual(@as(?[]const u8, null), sport.value_name(.{ .string = "x" }));

    // file_id.manufacturer is a uint16 type; 1 is garmin, 255 development.
    const manufacturer = field_profile(0, 1).?;
    try testing.expectEqualStrings("garmin", manufacturer.value_name(.{ .unsigned = 1 }).?);
    const development = manufacturer.value_name(.{ .unsigned = 255 }).?;
    try testing.expectEqualStrings("development", development);
    // Past the last value of a type.
    const past = manufacturer.value_name(.{ .unsigned = 1 << 32 });
    try testing.expectEqual(@as(?[]const u8, null), past);

    // A plain number and a date have no names; heart rate 1 isn't "running".
    const heart_rate = field_profile(20, 3).?;
    try testing.expectEqual(@as(?[]const u8, null), heart_rate.value_name(.{ .unsigned = 1 }));
    try testing.expectEqual(@as(?u16, null), field_profile(20, 253).?.type_index);
}

test "FieldProfile.scaled: scale, offset and non-numeric values" {
    const altitude = FieldProfile{ .name = "altitude", .scale = 5, .offset = 500 };
    try testing.expectEqual(@as(?f64, 792), altitude.scaled(.{ .unsigned = 6460 }));
    try testing.expectEqual(@as(?f64, -500), altitude.scaled(.{ .unsigned = 0 }));
    // 2621 / 5 - 500 in that order gives 24.200000000000045.
    try testing.expectEqual(@as(?f64, 24.2), altitude.scaled(.{ .unsigned = 2621 }));

    const grade = FieldProfile{ .name = "grade", .scale = 100 };
    try testing.expectEqual(@as(?f64, -2.5), grade.scaled(.{ .signed = -250 }));
    try testing.expectEqual(@as(?f64, 0.5), grade.scaled(.{ .float = 50 }));

    const unscaled = FieldProfile{ .name = "heart_rate" };
    try testing.expectEqual(@as(?f64, 91), unscaled.scaled(.{ .unsigned = 91 }));

    try testing.expectEqual(@as(?f64, null), grade.scaled(.{ .string = "x" }));
    try testing.expectEqual(@as(?f64, null), grade.scaled(.{ .bytes = &.{1} }));
}

test "field_profile: dates and positions carry their kind" {
    try testing.expectEqual(Kind.date_time, field_profile(20, 253).?.kind);
    try testing.expectEqual(Kind.date_time, field_profile(0, 4).?.kind);
    try testing.expectEqual(Kind.date_time, field_profile(18, 2).?.kind);
    try testing.expectEqual(Kind.local_date_time, field_profile(34, 5).?.kind);
    try testing.expectEqual(Kind.semicircles, field_profile(20, 0).?.kind);
    try testing.expectEqual(Kind.semicircles, field_profile(18, 39).?.kind);
    // A duration in seconds is a number, not a date.
    try testing.expectEqual(Kind.number, field_profile(18, 7).?.kind);
    try testing.expectEqual(Kind.number, field_profile(20, 3).?.kind);
}

test "date_time_unix_s: absolute dates and time since power-on" {
    try testing.expectEqual(@as(?u64, 631065600 + 1159179174), date_time_unix_s(1159179174));
    try testing.expectEqual(@as(?u64, 631065600 + 0x10000000), date_time_unix_s(0x10000000));
    try testing.expectEqual(@as(?u64, null), date_time_unix_s(0x0FFFFFFF));
    try testing.expectEqual(@as(?u64, null), date_time_unix_s(0));
    const max = std.math.maxInt(u32);
    try testing.expectEqual(@as(?u64, 631065600 + max), date_time_unix_s(max));
}

test "semicircles_degrees" {
    try testing.expectEqual(@as(f64, 0), semicircles_degrees(0));
    try testing.expectEqual(@as(f64, 90), semicircles_degrees(1 << 30));
    try testing.expectEqual(@as(f64, -180), semicircles_degrees(-(1 << 31)));
    try testing.expectApproxEqAbs(@as(f64, 45.026082), semicircles_degrees(537182079), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -0.808959), semicircles_degrees(-9651251), 1e-6);
}

test "developer_field_profile: carries the description's name, units, scale and offset" {
    const description = fit.DeveloperFieldDescription{
        .developer_data_index = 0,
        .field_number = 1,
        .base_type = .uint16,
        .name = "Heart Rate",
        .units = "bpm",
        .scale = 10,
        .offset = -5,
    };
    const profile = developer_field_profile(&description);
    try std.testing.expectEqualStrings("Heart Rate", profile.name);
    try std.testing.expectEqualStrings("bpm", profile.units);
    try std.testing.expect(profile.is_scaled());
    // (1234 - (-5) * 10) / 10.
    try std.testing.expectEqual(@as(?f64, 128.4), profile.scaled(.{ .unsigned = 1234 }));

    const unnamed = developer_field_profile(&.{
        .developer_data_index = 255,
        .field_number = 255,
        .base_type = .uint8,
    });
    try std.testing.expectEqualStrings("", unnamed.name);
    try std.testing.expectEqualStrings("", unnamed.units);
    try std.testing.expect(!unnamed.is_scaled());
}

test "FieldProfile.masked: the number under the mask, and the flags above it" {
    const message_index = field_profile(19, 254).?; // lap.message_index
    const plain = message_index.masked(.{ .unsigned = 3 }).?;
    try testing.expectEqual(@as(u64, 3), plain.number);
    try testing.expectEqual(@as(usize, 0), plain.flags().len);
    const selected = message_index.masked(.{ .unsigned = 0x8000 | 0xFFF }).?;
    try testing.expectEqual(@as(u64, 0xFFF), selected.number);
    try testing.expectEqualStrings("selected", selected.flags()[0]);
    // The reserved bits 0x7000 are neither number nor flag.
    try testing.expectEqual(null, message_index.masked(.{ .unsigned = 0x1000 }));
    try testing.expectEqual(null, message_index.masked(.{ .signed = 3 }));
    // A masked type's values are numbers: 0xFFF isn't "mask".
    try testing.expectEqual(null, message_index.value_name(.{ .unsigned = 0xFFF }));

    const balance = field_profile(20, 30).?; // record.left_right_balance, uint8
    const right = balance.masked(.{ .unsigned = 0x80 | 52 }).?;
    try testing.expectEqual(@as(u64, 52), right.number);
    try testing.expectEqualStrings("right", right.flags()[0]);
    try testing.expectEqual(@as(u64, 0x7F), balance.masked(.{ .unsigned = 0x7F }).?.number);

    // Not a masked type.
    try testing.expectEqual(null, field_profile(18, 5).?.masked(.{ .unsigned = 1 }));
    try testing.expectEqual(null, field_profile(20, 3).?.masked(.{ .unsigned = 1 }));
}

/// A data message holding `bytes` for `fields`, little-endian, for subfield tests.
fn test_data_message(
    global_message_number: u16,
    fields: []const fit.FieldDefinition,
    bytes: []const u8,
) fit.DataMessage {
    return .{
        .local_message_type = 0,
        .global_message_number = global_message_number,
        .big_endian = false,
        .compressed_timestamp = null,
        .fields = fields,
        .raw = bytes,
        .developer_fields = &.{},
        .developer_raw = &.{},
    };
}

test "data_field_profile: the referenced field's value selects the subfield" {
    // event (21): field 0 event (enum), field 3 data (uint32).
    const fields = [_]fit.FieldDefinition{
        .{ .field_definition_number = 0, .size = 1, .base_type = .@"enum" },
        .{ .field_definition_number = 3, .size = 4, .base_type = .uint32 },
    };
    // event 0 (timer): data is timer_trigger, a named value.
    const timer = test_data_message(21, &fields, &.{ 0, 1, 0, 0, 0 });
    const trigger = data_field_profile(&timer, 3).?;
    try testing.expectEqualStrings("timer_trigger", trigger.name);
    try testing.expectEqualStrings("auto", trigger.value_name(.{ .unsigned = 1 }).?);
    // fitparse's tests expect a timer event's data 2 to read as fitness_equipment.
    const equipment = trigger.value_name(.{ .unsigned = 2 }).?;
    try testing.expectEqualStrings("fitness_equipment", equipment);
    // event 11 (battery): data is battery_level, scaled to volts.
    const battery = test_data_message(21, &fields, &.{ 11, 0xB8, 0x0B, 0, 0 });
    const level = data_field_profile(&battery, 3).?;
    try testing.expectEqualStrings("battery_level", level.name);
    try testing.expectEqualStrings("V", level.units);
    try testing.expectEqual(@as(?f64, 3), level.scaled(.{ .unsigned = 3000 }));
    // The last event data subfield, radar_threat_alert (75), holds components: unscaled.
    const radar = data_field_profile(&test_data_message(21, &fields, &.{ 75, 0, 0, 0, 0 }), 3).?;
    try testing.expectEqualStrings("radar_threat_alert", radar.name);
    try testing.expect(!radar.is_scaled());

    // The reference field itself, and a field without subfields, keep their own profile.
    try testing.expectEqualStrings("event", data_field_profile(&timer, 0).?.name);
    try testing.expectEqualStrings("event", field_profile(21, 0).?.name);
    // field_profile ignores the message: data is data.
    try testing.expectEqualStrings("data", field_profile(21, 3).?.name);
}

test "data_field_profile: no subfield matches, so the field keeps its own profile" {
    const fields = [_]fit.FieldDefinition{
        .{ .field_definition_number = 0, .size = 1, .base_type = .@"enum" },
        .{ .field_definition_number = 3, .size = 4, .base_type = .uint32 },
    };
    // event 3 (workout) selects no subfield; 255 is the enum's "no data" sentinel.
    const workout = test_data_message(21, &fields, &.{ 3, 0, 0, 0, 0 });
    try testing.expectEqualStrings("data", data_field_profile(&workout, 3).?.name);
    const invalid = test_data_message(21, &fields, &.{ 0xFF, 0, 0, 0, 0 });
    try testing.expectEqualStrings("data", data_field_profile(&invalid, 3).?.name);

    // The referenced field is missing.
    const data_only = [_]fit.FieldDefinition{
        .{ .field_definition_number = 3, .size = 4, .base_type = .uint32 },
    };
    const missing = test_data_message(21, &data_only, &.{ 0, 0, 0, 0 });
    try testing.expectEqualStrings("data", data_field_profile(&missing, 3).?.name);

    // The referenced field is an array, or signed: neither can hold an enum's raw value.
    const array_fields = [_]fit.FieldDefinition{
        .{ .field_definition_number = 0, .size = 2, .base_type = .@"enum" },
        .{ .field_definition_number = 3, .size = 4, .base_type = .uint32 },
    };
    const array = test_data_message(21, &array_fields, &.{ 0, 0, 0, 0, 0, 0 });
    try testing.expectEqualStrings("data", data_field_profile(&array, 3).?.name);
    const signed_fields = [_]fit.FieldDefinition{
        .{ .field_definition_number = 0, .size = 1, .base_type = .sint8 },
        .{ .field_definition_number = 3, .size = 4, .base_type = .uint32 },
    };
    const signed = test_data_message(21, &signed_fields, &.{ 0, 0, 0, 0, 0 });
    try testing.expectEqualStrings("data", data_field_profile(&signed, 3).?.name);

    // Unknown field and unknown message.
    try testing.expectEqual(null, data_field_profile(&workout, 200));
    const unknown = test_data_message(325, &fields, &.{ 0, 0, 0, 0, 0 });
    try testing.expectEqual(null, data_field_profile(&unknown, 3));
}

test "data_field_profile: any reference selects, and the first matching subfield wins" {
    // file_id (0): field 1 manufacturer (uint16), field 2 product (uint16). garmin_product is
    // selected by any of four manufacturers: garmin (1), dynastream (15), dynastream_oem (13)
    // and tacx (89); favero_product by favero_electronics (263).
    const fields = [_]fit.FieldDefinition{
        .{ .field_definition_number = 1, .size = 2, .base_type = .uint16 },
        .{ .field_definition_number = 2, .size = 2, .base_type = .uint16 },
    };
    for ([_]u8{ 1, 15, 13, 89 }) |manufacturer| {
        const data = test_data_message(0, &fields, &.{ manufacturer, 0, 0, 0 });
        try testing.expectEqualStrings("garmin_product", data_field_profile(&data, 2).?.name);
    }
    const favero = test_data_message(0, &fields, &.{ 0x07, 0x01, 0, 0 });
    try testing.expectEqualStrings("favero_product", data_field_profile(&favero, 2).?.name);
    const other = test_data_message(0, &fields, &.{ 2, 0, 0, 0 });
    try testing.expectEqualStrings("product", data_field_profile(&other, 2).?.name);
    // fitparse's tests expect garmin product 1036 to read as edge500.
    const edge = test_data_message(0, &fields, &.{ 1, 0, 0x0C, 0x04 });
    const edge_product = data_field_profile(&edge, 2).?;
    try testing.expectEqualStrings("edge500", edge_product.value_name(.{ .unsigned = 1036 }).?);

    // session (18): field 5 sport, 6 sub_sport, 10 total_cycles. A running (1) session with
    // sub_sport strength_training (20) matches total_reps and total_strides; total_reps comes
    // first in the profile.
    const session_fields = [_]fit.FieldDefinition{
        .{ .field_definition_number = 5, .size = 1, .base_type = .@"enum" },
        .{ .field_definition_number = 6, .size = 1, .base_type = .@"enum" },
        .{ .field_definition_number = 10, .size = 4, .base_type = .uint32 },
    };
    const both = test_data_message(18, &session_fields, &.{ 1, 20, 0, 0, 0, 0 });
    try testing.expectEqualStrings("total_reps", data_field_profile(&both, 10).?.name);
    const running = test_data_message(18, &session_fields, &.{ 1, 0, 0, 0, 0, 0 });
    const strides = data_field_profile(&running, 10).?;
    try testing.expectEqualStrings("total_strides", strides.name);
    try testing.expectEqualStrings("strides", strides.units);
}

test "data_field_profile: a date subfield keeps its conversion" {
    // event (21) 54 (auto_activity_detect) makes start_timestamp (15) a date_time subfield.
    const fields = [_]fit.FieldDefinition{
        .{ .field_definition_number = 0, .size = 1, .base_type = .@"enum" },
        .{ .field_definition_number = 15, .size = 4, .base_type = .uint32 },
    };
    const data = test_data_message(21, &fields, &.{ 54, 0, 0, 0, 0x40 });
    const profile = data_field_profile(&data, 15).?;
    try testing.expectEqualStrings("auto_activity_detect_start_timestamp", profile.name);
    try testing.expectEqual(Kind.date_time, profile.kind);
    try testing.expectEqualStrings("s", profile.units);
}
