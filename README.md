# fitz

[![CI](https://github.com/totorototo/fitz/actions/workflows/ci.yml/badge.svg)](https://github.com/totorototo/fitz/actions/workflows/ci.yml)

A small Zig library and CLI for reading **FIT** files, the binary activity format written by
Garmin, Suunto, Coros, Wahoo and most other sports devices.

- Strict: every CRC is checked before anything is returned, so a damaged file is rejected,
  never half-read.
- Named: messages, fields, units and enum values come from Garmin's official profile.
- Zero-copy and streaming: records are views into your buffer, and nothing is decoded
  until you ask.

Requires **Zig 0.17.0**.

## Quick start

```sh
zig build
zig-out/bin/fitz activity.fit                     # summary: header, CRCs, message counts
zig-out/bin/fitz --dump activity.fit              # every message, readable
zig-out/bin/fitz --dump --all activity.fit        # every field as stored, one line each
```

`--dump` prints a block per message, with values scaled, named and converted
(dates in ISO 8601, positions in degrees):

```
event
  timestamp             2012-04-09T21:22:26Z
  timer_trigger         manual
  event                 timer
  event_type            start

record
  timestamp             2012-04-09T21:22:26Z
  position_lat          41.513926°
  position_long         -73.148591°
  altitude              278.2 m
  speed                 0 m/s
```

To keep one kind of message: `fitz --dump file.fit | awk -v RS= '/^session\n/'`.

`--dump --all` is meant for grep and debugging: one line per message, every field, raw dates
and positions, `-` for "no data", unknown fields by number:

```
DATA local=1 global_msg=event timestamp=702940946s timer_trigger=0 event=0 event_type=0
```

## Using the library

Add it to your project:

```sh
zig fetch --save git+https://github.com/totorototo/fitz
```

```zig
// build.zig
const fitz = b.dependency("fitz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("fitz", fitz.module("fitz"));
```

Then walk the records:

```zig
const std = @import("std");
const fitz = @import("fitz");

/// Prints every record message's fields, named, scaled and with units.
fn records_print(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parser = try fitz.Parser.init(allocator, bytes); // checks every CRC first
    defer parser.deinit();

    while (try parser.next()) |record| {
        const data = switch (record) {
            .data => |data| data,
            .definition => continue,
        };
        if (data.global_message_number != 20) continue; // 20 is `record`

        var fields = data.fields_iterator();
        while (fields.next()) |field| {
            const number = field.field_definition_number;
            const profile = fitz.profile.data_field_profile(&data, number) orelse continue;
            const value = field.element(0) orelse continue; // null means "no data"
            const scaled = profile.scaled(value) orelse continue;
            std.debug.print("{s} = {d} {s}\n", .{ profile.name, scaled, profile.units });
        }
    }
}
```

Useful next steps from there:

| You want | Use |
| --- | --- |
| An enum value's name (`sport` 1 → `running`) | `profile.value_name(value)` |
| A date or a position | `profile.kind`, `fitz.profile.date_time_unix_s`, `semicircles_degrees` |
| Developer fields (Stryd, Connect IQ apps) | `data.developer_fields_iterator()`, `parser.developer_field_descriptions.get(&field)` |
| Several FIT files chained in one buffer | `parser.file_index` / `file_count`, or `next_in_file()` + `file_advance()` |
| A message's name | `fitz.profile.message_name(number)` |

The parser does no I/O: you pass it bytes, and a record stays valid until `deinit`.

## What's supported

- File header, header and file CRC-16, chained files
- Normal and compressed-timestamp record headers (timestamps rebuilt)
- Definition and data messages, all base types, arrays, "no data" sentinels
- Garmin FIT profile 21.217.0: message, field and value names, units, scale and offset,
  and subfields (event `data` becomes `timer_trigger` in a timer event)
- Developer fields, decoded through the file's field_description messages

**Not yet:** profile components (`speed` → `enhanced_speed`, bit-packed
`compressed_speed_distance`, accumulated fields).

**Stricter than Garmin's SDK**, on purpose. Each of these is an error rather than a guess:

- a field whose size doesn't match its base type (this rejects a real Coros Pace 2 file,
  `testdata/coros-pace-2-cycling-misaligned-fields.fit`)
- a compressed timestamp with no earlier full timestamp to build on
- a malformed field_description
- any CRC mismatch, or bytes after the last file

## Development

```sh
zig build test --summary all        # unit tests, real-file fixtures and CLI snapshots
```

CI also checks `zig fmt`, a 100-column line limit, and runs the tests in Debug and ReleaseSafe
on Linux, macOS and Windows. The code follows
[TigerBeetle's style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md):
`FitError` means a bad file, and a failed `assert` means a bug in fitz.

```
src/fit.zig                 the parser: bytes in, records out, no I/O
src/profile.zig             profile lookups (names, units, scaling, subfields)
src/profile_generated.zig   profile tables, generated: don't edit
src/main.zig                the CLI
src/fixtures_test.zig       tests against real files in testdata/
src/snapshots/              approved CLI output, compared byte for byte
tools/profile_generate.py   regenerates the profile tables
```

**Snapshots** catch unintended output changes, not correctness (that's `fixtures_test.zig`).
After an intended change, regenerate and review:

```sh
zig build
for f in Activity DeveloperData activity-settings; do
  zig-out/bin/fitz --dump testdata/$f.fit > src/snapshots/$f.dump.txt
  zig-out/bin/fitz --dump --all testdata/$f.fit > src/snapshots/$f.dump-all.txt
done
git diff src/snapshots
```

**The profile** is generated from `profile.py` in Garmin's
[FIT Python SDK](https://github.com/garmin/fit-python-sdk). To move to a new version:

```sh
git clone --depth 1 https://github.com/garmin/fit-python-sdk /tmp/fit-python-sdk
tools/profile_generate.py /tmp/fit-python-sdk > src/profile_generated.zig
zig fmt src/profile_generated.zig
zig build test --summary all
```

## Licenses

`src/profile_generated.zig` is derived from the FIT SDK and covered by Garmin's FIT Protocol
License. The files in `testdata/` come from
[python-fitparse](https://github.com/dtcooper/python-fitparse) (MIT); see `testdata/README.md`.
