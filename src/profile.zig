//! The FIT profile: names for global message numbers, name, units, scale and offset for their
//! fields, and names for the values of enumerated fields. The tables are generated from
//! Garmin's FIT SDK into profile_generated.zig; this file holds the lookups and conversions.
//! Subfields and components are not applied yet. Pure lookups, no allocation.
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

/// Returns null when the message or the field isn't in the profile.
pub fn field_profile(global_message_number: u16, field_definition_number: u8) ?FieldProfile {
    const message = message_find(global_message_number) orelse return null;
    const index = std.sort.binarySearch(
        generated.Field,
        message.fields,
        field_definition_number,
        field_order,
    ) orelse return null;
    const field = &message.fields[index];
    assert(field.number == field_definition_number);
    const profile = FieldProfile{
        .name = field.name,
        .kind = field.kind,
        .units = field.units,
        .scale = field.scale,
        .offset = field.offset,
        .type_index = field.type_index,
    };
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
        }
    }
    for (generated.types) |value_type| {
        try testing.expect(value_type.values.len > 0);
        for (value_type.values[1..], 1..) |entry, index| {
            try testing.expect(value_type.values[index - 1].value < entry.value);
        }
    }
}

fn field_expect_well_formed(field: *const generated.Field) !void {
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
