# fitz

Minimal Zig parser for the FIT (Flexible and Interoperable Data Transfer)
binary format. FIT was authored by Garmin but is an open protocol used
across the industry — Suunto, Coros, Wahoo and others read and write it
too, so this isn't Garmin-specific. Library + CLI, built to grow feature
by feature rather than all at once.

## Build

```sh
zig build            # builds lib + cli into zig-out/
zig build test       # runs unit tests and the tests against testdata/; silent on success
zig build test --summary all   # same, listing each test binary and its pass count
zig build run -- path/to/file.fit
zig build run -- --dump path/to/file.fit > dump.txt
zig build run -- --dump --all path/to/file.fit > dump-all.txt
```

Without flags the CLI prints the header and a per-message-type count
summary to stderr. `--dump` also writes each data message to stdout as a
block meant for reading, one field per line, blocks separated by a blank
line:

```
record
  timestamp             2026-09-24T10:12:54Z
  position_lat          45.026082°
  position_long         -0.808959°
  enhanced_altitude     24.2 m
  heart_rate            107 bpm
```

It shows only the fields the built-in profile knows and that hold data,
with scale and offset applied, and skips a message with nothing to show
(the summary still counts it). To pull out one kind of message, use awk's
paragraph mode: `awk -v RS= '/^session\n/' dump.txt`. Dates are
ISO 8601: UTC with a `Z`, local time (`local_timestamp`) without one, and
a date_time below `0x10000000` (seconds since the device powered on)
stays in seconds. Positions are in degrees.

`--dump --all` prints one line per message, easy to grep, e.g.
`DATA local=2 global_msg=record timestamp=1159179174s … power=- 140=0`.
It shows every field as stored, for debugging: `-` for a
base type's invalid ("no data") sentinel, unknown messages and fields by
number, and dates and positions in raw seconds and semicircles. Scale and
offset still apply. Developer fields come last, as their stored bytes:
`dev:0:3=0x5fba8940` is developer data index 0, field 3. The readable
dump leaves them out. In both modes, arrays are in brackets, strings quoted
and byte fields hex. A message with a compressed-timestamp header gets
its rebuilt timestamp printed first, and the summary counts how many
there were.

Targets Zig 0.16.0 (explicit `std.Io`, `std.process.Init` main,
unmanaged containers). Only `main.zig` does I/O; `fit.zig` parses an
in-memory `[]const u8`, so the core parser is independent of I/O APIs.

## Design note: negative space

Types are structured so invalid states can't be constructed at all,
rather than being checked for at runtime:

- `RecordHeader` is a tagged union (`normal` / `compressed_timestamp`),
  not a flat struct with fields that are "only meaningful if kind is
  X" — there's no bit pattern that produces a compressed header with
  `is_definition` set, because that field doesn't exist on that branch.
- `CompressedTimestampHeader.local_message_type` is `u2`, matching the
  2 bits the spec actually gives it, not `u4` with 12 values that are
  simply never used.
- `FileHeader.crc` is `?u16` instead of a `has_crc: bool` paired with a
  `u16` that has to be kept in sync with it.
- `FieldDefinition.base_type` is a `BaseType` enum of the 17 canonical
  bytes, validated when the definition is parsed, and a field's size is
  checked to be a nonzero multiple of its base type's size. Decoding a
  data message therefore never meets an unknown type or a misaligned
  element.
- `Field.element` returns `?Value`: a base type's "invalid" sentinel
  (`0xFF`, `0x7FFF`, all-zero for the `z` types, …) comes back as null,
  not as a magic number the caller must remember.

Error returns (`FitError.*`) are reserved for things that legitimately
vary in untrusted external bytes — a truncated file, an unknown local
message type, an unsupported record shape. Anything the parser itself
guarantees internally (e.g. a local message type always fits the 16-slot
definitions table because its type is `u4`) is enforced by the types or
by an `assert`. A failed assert means a bug in fitz, never a bad file.

## What it does

- Parses the 12/14-byte file header (`.FIT` signature, sizes, versions)
- Parses record headers: normal headers and compressed-timestamp headers
- Rebuilds compressed timestamps (`DataMessage.compressed_timestamp`):
  the parser keeps the latest full timestamp (field 253 of any message,
  or the last rebuilt one) and applies each header's 5-bit offset to it,
  moving to the next 32-second window when the offset wraps
- Parses definition messages (local message type table, endianness,
  global message number, field definitions, developer field definitions)
- Splits developer fields out of each data message
  (`DataMessage.developer_fields_iterator()` → `DeveloperField`: developer
  data index, field number and raw bytes). Their base type lives in a
  field_description message (206), which fitz doesn't interpret yet; a
  caller that has it calls `DeveloperField.field(base_type)` to get a
  `Field` that decodes like any other, with the size checked against the
  base type there
- Parses data messages per the matching definition, and decodes each
  field's base type (`DataMessage.fields_iterator()` → `Field.element(i)`
  → `Value`: unsigned, signed, float, string or bytes). Numeric fields
  whose size is a multiple of the base type size are arrays.
- Streaming `Parser.next()` — no upfront allocation of the whole record
  list, only definition field tables are heap-allocated
- Verifies CRC-16 (CRC-16/ARC, as in the FIT SDK) in `Parser.init`,
  before any record is returned: the 14-byte header's CRC when it is
  nonzero, and the required 2-byte file CRC after the data section, which
  covers the header and data. The CLI prints `header_crc=ok|absent
  file_crc=ok(0x…)`
- A small built-in profile (`fitz.profile`): names for well-known global
  messages, and name, units, scale and offset for the common fields of
  file_id, file_creator, device_info, event, record, lap, session and
  activity. `message_name(global)`, `field_profile(global, field)`, and
  `FieldProfile.scaled(value)` = raw / scale − offset. `FieldProfile.kind`
  marks dates (UTC or local) and positions, converted with
  `date_time_unix_s` and `semicircles_degrees`

## What it deliberately doesn't do yet

- Only a curated slice of the FIT profile, not the full generated one.
  Enum values stay numeric (`sport=1`, not `running`)
- Strict on base types: a non-canonical base type byte (e.g. `0x04`
  instead of `0x84`) or a field size that isn't a multiple of its base
  type size is rejected, where the FIT SDK falls back to a byte array
- Strict on compressed timestamps: a compressed header before any full
  timestamp, one whose definition also has field 253, or one that would
  overflow `u32` is an error, where the FIT SDK assumes a reference of 0
- Developer fields stay raw bytes: field_description (206) and
  developer_data_id (207) messages are parsed like any other message, but
  not used to name, type or scale developer fields
- Strict on CRCs, with no opt-out: a mismatched header or file CRC, or a
  missing file CRC, rejects the whole file, so a damaged file can't be
  partially read
- No support for chained/concatenated FIT files in one buffer: only the
  first file is read, and the bytes after its CRC are ignored, even when
  they aren't valid FIT (`testdata/activity-settings-corruptheader.fit`)

## Rough next steps

1. Decode developer fields through their field_description messages
   (name, base type, units, scale, offset)

## Layout

```
build.zig / build.zig.zon
src/
  fit.zig    core parser (Parser, FileHeader, DefinitionMessage, DataMessage, Record)
             and base-type decoding (BaseType, FieldIterator, Field, Value), developer
             fields (DeveloperFieldIterator, DeveloperField)
  profile.zig  curated FIT profile slice: message/field names, units, scale, offset
  root.zig   library re-exports (`@import("fitz")`)
  main.zig   CLI: header info, per-message-type counts, `--dump` of decoded fields
  fixtures_test.zig  tests against the real files in testdata/
testdata/    third-party FIT fixtures (python-fitparse, MIT); see testdata/README.md
```
