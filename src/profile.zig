//! A small, hand-written slice of the FIT profile: names for well-known global message
//! numbers, and name, units, scale and offset for the common fields of the messages an
//! activity file is built from. It is not the full generated profile, which has thousands of
//! fields and belongs in a code generator. Pure lookups, no allocation.
//!
//! FIT scaling: physical value = raw / scale - offset. Dates and positions are not scaled but
//! converted, and `FieldProfile.kind` says which conversion applies.

const std = @import("std");
const assert = std.debug.assert;
const fit = @import("fit.zig");

/// Seconds from the Unix epoch to the FIT epoch, 1989-12-31 00:00:00 UTC.
pub const fit_epoch_unix_s: u64 = 631065600;
/// A FIT date_time below this counts seconds since the device powered on, not since the FIT
/// epoch, so it is not a calendar date.
pub const date_time_absolute_min: u32 = 0x10000000;
/// 2^31 semicircles make 180 degrees.
const semicircles_per_180_degrees: f64 = 2147483648.0;

pub const Kind = enum {
    /// A plain number, scaled when the entry has a scale or offset.
    number,
    /// uint32 seconds since the FIT epoch, in UTC. Units are "s".
    date_time,
    /// The same encoding in the device's local time zone. Units are "s".
    local_date_time,
    /// sint32 angle. Units are "semicircles".
    semicircles,
};

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

pub const FieldProfile = struct {
    /// snake_case, as in the FIT profile.
    name: []const u8,
    kind: Kind = .number,
    /// Empty when the field is dimensionless (an enum, an index, a count).
    units: []const u8 = "",
    scale: u16 = 1,
    offset: i16 = 0,

    pub fn is_scaled(self: *const FieldProfile) bool {
        assert(self.scale >= 1);
        return self.scale != 1 or self.offset != 0;
    }

    /// Applies scale and offset to one element. Returns null for a string or byte value: the
    /// file chose a base type the profile doesn't expect for this field, and there is no
    /// number to scale.
    pub fn scaled(self: *const FieldProfile, value: fit.Value) ?f64 {
        assert(self.scale >= 1);
        const raw: f64 = switch (value) {
            .unsigned => |unsigned| @floatFromInt(unsigned),
            .signed => |signed| @floatFromInt(signed),
            .float => |float| float,
            .string, .bytes => return null,
        };
        const scale: f64 = @floatFromInt(self.scale);
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
        .scale = description.scale,
        .offset = description.offset,
    };
    assert(profile.kind == .number);
    return profile;
}

/// Returns null for a message number outside this curated subset.
pub fn message_name(global_message_number: u16) ?[]const u8 {
    return switch (global_message_number) {
        0 => "file_id",
        2 => "device_settings",
        3 => "user_profile",
        7 => "zones_target",
        12 => "sport",
        18 => "session",
        19 => "lap",
        20 => "record",
        21 => "event",
        23 => "device_info",
        34 => "activity",
        49 => "file_creator",
        206 => "field_description",
        207 => "developer_data_id",
        else => null,
    };
}

/// Returns null when the message has no field table here, or the field isn't in it.
pub fn field_profile(global_message_number: u16, field_definition_number: u8) ?FieldProfile {
    const profile: FieldProfile = switch (global_message_number) {
        0 => file_id(field_definition_number),
        18 => session(field_definition_number),
        19 => lap(field_definition_number),
        20 => record(field_definition_number),
        21 => event(field_definition_number),
        23 => device_info(field_definition_number),
        34 => activity(field_definition_number),
        49 => file_creator(field_definition_number),
        else => null,
    } orelse return null;
    // A field table only exists for a message that has a name.
    assert(message_name(global_message_number) != null);
    assert(profile.scale >= 1);
    return profile;
}

fn file_id(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        0 => .{ .name = "type" },
        1 => .{ .name = "manufacturer" },
        2 => .{ .name = "product" },
        3 => .{ .name = "serial_number" },
        4 => .{ .name = "time_created", .kind = .date_time, .units = "s" },
        5 => .{ .name = "number" },
        8 => .{ .name = "product_name" },
        else => null,
    };
}

fn file_creator(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        0 => .{ .name = "software_version" },
        1 => .{ .name = "hardware_version" },
        else => null,
    };
}

fn device_info(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        253 => .{ .name = "timestamp", .kind = .date_time, .units = "s" },
        0 => .{ .name = "device_index" },
        1 => .{ .name = "device_type" },
        2 => .{ .name = "manufacturer" },
        3 => .{ .name = "serial_number" },
        4 => .{ .name = "product" },
        5 => .{ .name = "software_version", .scale = 100 },
        6 => .{ .name = "hardware_version" },
        7 => .{ .name = "cum_operating_time", .units = "s" },
        10 => .{ .name = "battery_voltage", .units = "V", .scale = 256 },
        11 => .{ .name = "battery_status" },
        25 => .{ .name = "source_type" },
        27 => .{ .name = "product_name" },
        else => null,
    };
}

fn event(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        253 => .{ .name = "timestamp", .kind = .date_time, .units = "s" },
        0 => .{ .name = "event" },
        1 => .{ .name = "event_type" },
        2 => .{ .name = "data16" },
        3 => .{ .name = "data" },
        4 => .{ .name = "event_group" },
        else => null,
    };
}

fn record(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        253 => .{ .name = "timestamp", .kind = .date_time, .units = "s" },
        0 => .{ .name = "position_lat", .kind = .semicircles, .units = "semicircles" },
        1 => .{ .name = "position_long", .kind = .semicircles, .units = "semicircles" },
        2 => .{ .name = "altitude", .units = "m", .scale = 5, .offset = 500 },
        3 => .{ .name = "heart_rate", .units = "bpm" },
        4 => .{ .name = "cadence", .units = "rpm" },
        5 => .{ .name = "distance", .units = "m", .scale = 100 },
        6 => .{ .name = "speed", .units = "m/s", .scale = 1000 },
        7 => .{ .name = "power", .units = "W" },
        9 => .{ .name = "grade", .units = "%", .scale = 100 },
        13 => .{ .name = "temperature", .units = "C" },
        39 => .{ .name = "vertical_oscillation", .units = "mm", .scale = 10 },
        40 => .{ .name = "stance_time_percent", .units = "%", .scale = 100 },
        41 => .{ .name = "stance_time", .units = "ms", .scale = 10 },
        42 => .{ .name = "activity_type" },
        53 => .{ .name = "fractional_cadence", .units = "rpm", .scale = 128 },
        73 => .{ .name = "enhanced_speed", .units = "m/s", .scale = 1000 },
        78 => .{ .name = "enhanced_altitude", .units = "m", .scale = 5, .offset = 500 },
        83 => .{ .name = "vertical_ratio", .units = "%", .scale = 100 },
        84 => .{ .name = "stance_time_balance", .units = "%", .scale = 100 },
        85 => .{ .name = "step_length", .units = "mm", .scale = 10 },
        else => null,
    };
}

fn lap(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        254 => .{ .name = "message_index" },
        253 => .{ .name = "timestamp", .kind = .date_time, .units = "s" },
        0 => .{ .name = "event" },
        1 => .{ .name = "event_type" },
        2 => .{ .name = "start_time", .kind = .date_time, .units = "s" },
        3 => .{ .name = "start_position_lat", .kind = .semicircles, .units = "semicircles" },
        4 => .{ .name = "start_position_long", .kind = .semicircles, .units = "semicircles" },
        5 => .{ .name = "end_position_lat", .kind = .semicircles, .units = "semicircles" },
        6 => .{ .name = "end_position_long", .kind = .semicircles, .units = "semicircles" },
        7 => .{ .name = "total_elapsed_time", .units = "s", .scale = 1000 },
        8 => .{ .name = "total_timer_time", .units = "s", .scale = 1000 },
        9 => .{ .name = "total_distance", .units = "m", .scale = 100 },
        10 => .{ .name = "total_cycles", .units = "cycles" },
        11 => .{ .name = "total_calories", .units = "kcal" },
        13 => .{ .name = "avg_speed", .units = "m/s", .scale = 1000 },
        14 => .{ .name = "max_speed", .units = "m/s", .scale = 1000 },
        15 => .{ .name = "avg_heart_rate", .units = "bpm" },
        16 => .{ .name = "max_heart_rate", .units = "bpm" },
        17 => .{ .name = "avg_cadence", .units = "rpm" },
        18 => .{ .name = "max_cadence", .units = "rpm" },
        19 => .{ .name = "avg_power", .units = "W" },
        20 => .{ .name = "max_power", .units = "W" },
        21 => .{ .name = "total_ascent", .units = "m" },
        22 => .{ .name = "total_descent", .units = "m" },
        24 => .{ .name = "lap_trigger" },
        27 => .{ .name = "nec_lat", .kind = .semicircles, .units = "semicircles" },
        28 => .{ .name = "nec_long", .kind = .semicircles, .units = "semicircles" },
        29 => .{ .name = "swc_lat", .kind = .semicircles, .units = "semicircles" },
        30 => .{ .name = "swc_long", .kind = .semicircles, .units = "semicircles" },
        25 => .{ .name = "sport" },
        else => null,
    };
}

fn session(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        254 => .{ .name = "message_index" },
        253 => .{ .name = "timestamp", .kind = .date_time, .units = "s" },
        0 => .{ .name = "event" },
        1 => .{ .name = "event_type" },
        2 => .{ .name = "start_time", .kind = .date_time, .units = "s" },
        3 => .{ .name = "start_position_lat", .kind = .semicircles, .units = "semicircles" },
        4 => .{ .name = "start_position_long", .kind = .semicircles, .units = "semicircles" },
        5 => .{ .name = "sport" },
        6 => .{ .name = "sub_sport" },
        7 => .{ .name = "total_elapsed_time", .units = "s", .scale = 1000 },
        8 => .{ .name = "total_timer_time", .units = "s", .scale = 1000 },
        9 => .{ .name = "total_distance", .units = "m", .scale = 100 },
        10 => .{ .name = "total_cycles", .units = "cycles" },
        11 => .{ .name = "total_calories", .units = "kcal" },
        14 => .{ .name = "avg_speed", .units = "m/s", .scale = 1000 },
        15 => .{ .name = "max_speed", .units = "m/s", .scale = 1000 },
        16 => .{ .name = "avg_heart_rate", .units = "bpm" },
        17 => .{ .name = "max_heart_rate", .units = "bpm" },
        18 => .{ .name = "avg_cadence", .units = "rpm" },
        19 => .{ .name = "max_cadence", .units = "rpm" },
        20 => .{ .name = "avg_power", .units = "W" },
        21 => .{ .name = "max_power", .units = "W" },
        22 => .{ .name = "total_ascent", .units = "m" },
        23 => .{ .name = "total_descent", .units = "m" },
        25 => .{ .name = "first_lap_index" },
        26 => .{ .name = "num_laps" },
        28 => .{ .name = "trigger" },
        29 => .{ .name = "nec_lat", .kind = .semicircles, .units = "semicircles" },
        30 => .{ .name = "nec_long", .kind = .semicircles, .units = "semicircles" },
        31 => .{ .name = "swc_lat", .kind = .semicircles, .units = "semicircles" },
        32 => .{ .name = "swc_long", .kind = .semicircles, .units = "semicircles" },
        38 => .{ .name = "end_position_lat", .kind = .semicircles, .units = "semicircles" },
        39 => .{ .name = "end_position_long", .kind = .semicircles, .units = "semicircles" },
        110 => .{ .name = "sport_profile_name" },
        124 => .{ .name = "enhanced_avg_speed", .units = "m/s", .scale = 1000 },
        125 => .{ .name = "enhanced_max_speed", .units = "m/s", .scale = 1000 },
        else => null,
    };
}

fn activity(field_definition_number: u8) ?FieldProfile {
    return switch (field_definition_number) {
        253 => .{ .name = "timestamp", .kind = .date_time, .units = "s" },
        0 => .{ .name = "total_timer_time", .units = "s", .scale = 1000 },
        1 => .{ .name = "num_sessions" },
        2 => .{ .name = "type" },
        3 => .{ .name = "event" },
        4 => .{ .name = "event_type" },
        5 => .{ .name = "local_timestamp", .kind = .local_date_time, .units = "s" },
        6 => .{ .name = "event_group" },
        else => null,
    };
}

const testing = std.testing;

test "message_name: known and unknown numbers" {
    try testing.expectEqualStrings("file_id", message_name(0).?);
    try testing.expectEqualStrings("record", message_name(20).?);
    try testing.expectEqualStrings("developer_data_id", message_name(207).?);
    try testing.expectEqual(@as(?[]const u8, null), message_name(1));
    try testing.expectEqual(@as(?[]const u8, null), message_name(325));
    try testing.expectEqual(@as(?[]const u8, null), message_name(std.math.maxInt(u16)));
}

test "field_profile: lookups, including edge field numbers" {
    const heart_rate = field_profile(20, 3).?;
    try testing.expectEqualStrings("heart_rate", heart_rate.name);
    try testing.expectEqualStrings("bpm", heart_rate.units);
    try testing.expect(!heart_rate.is_scaled());

    const altitude = field_profile(20, 78).?;
    try testing.expectEqual(@as(u16, 5), altitude.scale);
    try testing.expectEqual(@as(i16, 500), altitude.offset);
    try testing.expect(altitude.is_scaled());

    try testing.expectEqualStrings("type", field_profile(0, 0).?.name);
    try testing.expectEqualStrings("message_index", field_profile(18, 254).?.name);

    // Unknown field, unknown message, and a named message that has no field table.
    try testing.expectEqual(@as(?FieldProfile, null), field_profile(20, 255));
    try testing.expectEqual(@as(?FieldProfile, null), field_profile(325, 0));
    try testing.expectEqual(@as(?FieldProfile, null), field_profile(3, 0));
}

test "field_profile: every entry is well-formed and names are unique per message" {
    var message_number: u32 = 0;
    // Bounded: the whole u16 message space times the whole u8 field space.
    while (message_number <= std.math.maxInt(u16)) : (message_number += 1) {
        const global: u16 = @intCast(message_number);
        if (message_name(global) == null) continue;

        var field_number: u32 = 0;
        while (field_number <= std.math.maxInt(u8)) : (field_number += 1) {
            const profile = field_profile(global, @intCast(field_number)) orelse continue;
            try testing.expect(profile.name.len > 0);
            try testing.expect(profile.scale >= 1);
            // A converted field is never also scaled, and its units describe the raw value.
            switch (profile.kind) {
                .number => {},
                .date_time, .local_date_time => {
                    try testing.expect(!profile.is_scaled());
                    try testing.expectEqualStrings("s", profile.units);
                },
                .semicircles => {
                    try testing.expect(!profile.is_scaled());
                    try testing.expectEqualStrings("semicircles", profile.units);
                },
            }
            for (profile.name) |character| {
                try testing.expect(std.ascii.isLower(character) or
                    std.ascii.isDigit(character) or character == '_');
            }

            var other_number: u32 = field_number + 1;
            while (other_number <= std.math.maxInt(u8)) : (other_number += 1) {
                const other = field_profile(global, @intCast(other_number)) orelse continue;
                try testing.expect(!std.mem.eql(u8, profile.name, other.name));
            }
        }
    }
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
