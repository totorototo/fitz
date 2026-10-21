//! Robustness: whatever the bytes, fitz answers with records or a `FitError`, never a panic or
//! a failed assert. A failed assert is a bug in fitz (see the error policy), and in the apps'
//! ReleaseSmall WASM it is undefined behaviour, so these tests look for exactly that.
//!
//! Random bytes almost never get past the file CRC, so both tests wrap their bytes in a valid
//! header and CRCs (`file_wrap`): the parser then reaches the records, where the work is.
//!
//! - `zig build test` runs the mutation test: each fixture's records, damaged in a fixed,
//!   seeded way, then parsed and decoded in full. Deterministic, so a failure reproduces.
//! - `zig build test --fuzz` runs the fuzz test with coverage guidance, from the fixtures. Outside
//!   fuzz mode it runs its corpus once, so it is checked to compile and pass on every run.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fitz = @import("fitz");

const header_size = 14;
const crc_size = 2;
/// The header's protocol version byte (2.0) and profile version: any valid values will do.
const protocol_version = 0x20;
const profile_version: u16 = 2132;
/// The fuzz test's records size. Large enough for several definitions and their data.
const body_size_max = 4096;

/// The records in `body`, as a complete FIT file in `out`: a 14-byte header with its CRC, the
/// records, and the file CRC. Returns the file's bytes, a view into `out`.
fn file_wrap(out: []u8, body: []const u8) []u8 {
    assert(out.len >= header_size + body.len + crc_size);
    assert(body.len <= std.math.maxInt(u32));
    const header = out[0..header_size];
    header[0] = header_size;
    header[1] = protocol_version;
    std.mem.writeInt(u16, header[2..4], profile_version, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(body.len), .little);
    @memcpy(header[8..12], ".FIT");
    const header_crc = std.hash.crc.@"CRC-16/ARC".hash(header[0..12]);
    std.mem.writeInt(u16, header[12..14], header_crc, .little);

    @memcpy(out[header_size..][0..body.len], body);
    const content = out[0 .. header_size + body.len];
    const file_crc = std.hash.crc.@"CRC-16/ARC".hash(content);
    std.mem.writeInt(u16, out[content.len..][0..crc_size], file_crc, .little);
    const file = out[0 .. content.len + crc_size];
    assert(file.len == header_size + body.len + crc_size);
    return file;
}

/// The records of the first file in a fixture: what follows its header, up to its CRC.
fn fixture_body(file: []const u8) []const u8 {
    assert(file.len >= 12 + crc_size);
    const size = file[0];
    const data_size = std.mem.readInt(u32, file[4..8], .little);
    assert(size == 12 or size == 14);
    assert(size + data_size + crc_size <= file.len);
    return file[size..][0..data_size];
}

/// Parses `file` in both field-size modes and decodes everything a consumer would: every element
/// of every field, its profile (value names, masks, scaling), and each developer field the file
/// describes. Any `FitError` is an acceptable answer; only a panic or a failed assert is not.
/// Returns how many data messages the lenient pass decoded, which tells how deep the file got.
fn file_parse_everything(file: []const u8) u32 {
    var data_messages: u32 = 0;
    for ([_]fitz.FieldSizeMismatch{ .reject, .bytes }) |mode| {
        var parser = fitz.Parser.init_options(testing.allocator, file, .{
            .field_size_mismatch = mode,
        }) catch continue;
        defer parser.deinit();
        var records: usize = 0;
        // Bounded: every record consumes at least its one header byte.
        while (parser.next() catch null) |record| {
            records += 1;
            assert(records <= file.len);
            switch (record) {
                .definition => {},
                .data => |data| {
                    data_decode_everything(&parser, &data);
                    if (mode == .bytes) data_messages += 1;
                },
            }
        }
        assert(mode == .bytes or parser.field_size_mismatch_count == 0);
    }
    assert(data_messages <= file.len);
    return data_messages;
}

fn data_decode_everything(parser: *const fitz.Parser, data: *const fitz.DataMessage) void {
    var fields = data.fields_iterator();
    // Bounded by the definition's field count, at most 255.
    while (fields.next()) |field| {
        const profile = fitz.profile.data_field_profile(data, field.field_definition_number);
        field_decode_everything(&field, if (profile) |*known| known else null);
    }
    var developer_fields = data.developer_fields_iterator();
    // Bounded by the definition's developer field count, at most 255.
    while (developer_fields.next()) |developer| {
        const description = parser.developer_field_descriptions.get(&developer) orelse continue;
        const field = developer.field(description.base_type) catch continue;
        const profile = fitz.profile.developer_field_profile(&description);
        field_decode_everything(&field, &profile);
    }
}

fn field_decode_everything(
    field: *const fitz.Field,
    profile: ?*const fitz.profile.FieldProfile,
) void {
    const count = field.element_count();
    assert(count >= 1);
    for (0..count) |index| {
        const value = field.element(@intCast(index)) orelse continue;
        const known = profile orelse continue;
        _ = known.value_name(value);
        _ = known.masked(value);
        _ = known.scaled(value);
    }
}

/// The fixtures the mutation test damages: every valid file in testdata/ (the ones fitz rejects
/// as a whole are covered by fixtures_test.zig).
const fixtures = [_][]const u8{
    @embedFile("20170518-191602-1740899583.fit"),
    @embedFile("Activity.fit"),
    @embedFile("DeveloperData.fit"),
    @embedFile("activity-settings.fit"),
    @embedFile("compressed-speed-distance.fit"),
    @embedFile("coros-pace-2-cycling-misaligned-fields.fit"),
    @embedFile("sample_mulitple_header.fit"),
};

const Mutation = enum { byte_set, bit_flip, bytes_set, truncate, slice_repeat };
const mutations_per_fixture = 300;
/// Fixed, so a failure reproduces: the failing fixture and mutation index are in the trace.
const mutation_seed = 0x5eed_f17a;

/// Damages a copy of `body` in place, one `Mutation`, and returns the damaged length.
fn body_mutate(random: std.Random, body: []u8) usize {
    assert(body.len > 0);
    switch (random.enumValue(Mutation)) {
        .byte_set => body[random.uintLessThan(usize, body.len)] = random.int(u8),
        .bit_flip => {
            const index = random.uintLessThan(usize, body.len);
            body[index] ^= @as(u8, 1) << random.int(u3);
        },
        .bytes_set => for (0..random.intRangeAtMost(usize, 2, 16)) |_| {
            body[random.uintLessThan(usize, body.len)] = random.int(u8);
        },
        .truncate => return random.uintLessThan(usize, body.len),
        .slice_repeat => {
            // Copies a run of records over another: definitions and data out of order.
            const length = random.intRangeAtMost(usize, 1, @min(64, body.len));
            const from = random.uintLessThan(usize, body.len - length + 1);
            const to = random.uintLessThan(usize, body.len - length + 1);
            std.mem.copyForwards(u8, body[to..][0..length], body[from..][0..length]);
        },
    }
    return body.len;
}

test "mutation: damaged fixtures answer with records or a FitError, never a panic" {
    var prng = std.Random.DefaultPrng.init(mutation_seed);
    const random = prng.random();
    for (fixtures) |fixture| {
        const original = fixture_body(fixture);
        const body = try testing.allocator.dupe(u8, original);
        defer testing.allocator.free(body);
        const out = try testing.allocator.alloc(u8, header_size + body.len + crc_size);
        defer testing.allocator.free(out);

        // Undamaged first: the wrapper itself must give a file fitz reads.
        var parser = try fitz.Parser.init(testing.allocator, file_wrap(out, original));
        parser.deinit();
        var reached_data: u32 = 0;
        for (0..mutations_per_fixture) |_| {
            @memcpy(body, original);
            const length = body_mutate(random, body);
            if (file_parse_everything(file_wrap(out, body[0..length])) > 0) reached_data += 1;
        }
        // Most damage lands mid-file, after messages that still decode: the test exercises the
        // record parser and the decoders, not only the first check that refuses a file.
        try testing.expect(reached_data * 2 > mutations_per_fixture);
    }
}

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var body: [body_size_max]u8 = undefined;
    const length = smith.slice(&body);
    var out: [header_size + body_size_max + crc_size]u8 = undefined;
    _ = file_parse_everything(file_wrap(&out, body[0..length]));
}

test "fuzz: any records answer with records or a FitError, never a panic" {
    // A corpus input is what `Smith.slice` reads: a little-endian u32 length, then the bytes.
    var corpus: [fixtures.len][]const u8 = undefined;
    var inputs: [fixtures.len][4 + body_size_max]u8 = undefined;
    for (fixtures, &corpus, &inputs) |fixture, *entry, *input| {
        const body = fixture_body(fixture);
        const length = @min(body.len, body_size_max);
        std.mem.writeInt(u32, input[0..4], @intCast(length), .little);
        @memcpy(input[4..][0..length], body[0..length]);
        entry.* = input[0 .. 4 + length];
    }
    try testing.fuzz({}, fuzz_one, .{ .corpus = &corpus });
}
