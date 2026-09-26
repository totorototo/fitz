# fitz

Minimal Zig parser for the FIT (Flexible and Interoperable Data Transfer)
binary format. FIT was authored by Garmin but is an open protocol used
across the industry — Suunto, Coros, Wahoo and others read and write it
too, so this isn't Garmin-specific. Library + CLI, built to grow feature
by feature rather than all at once.

## Build

```sh
zig build            # builds lib + cli into zig-out/
zig build test       # runs unit tests
zig build run -- path/to/file.fit
zig build run -- --dump path/to/file.fit > dump.txt
```

Without flags the CLI prints the header and a per-message-type count
summary to stderr. `--dump` also writes one line per data message to
stdout, e.g.

```
DATA local=3 global_msg=record timestamp=1147594034s enhanced_altitude=1241.8m heart_rate=146bpm vertical_oscillation=- 140=0
```

A message with a compressed-timestamp header gets its rebuilt
`timestamp=…s` printed first, and the summary counts how many there were.
Fields the built-in profile knows print as `name=value` plus units, with
scale and offset applied. Unknown messages and fields keep their numbers
and raw values. Arrays are in brackets, strings quoted, byte fields hex,
and `-` marks a base type's invalid ("no data") sentinel.

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
  global message number, field definitions)
- Parses data messages per the matching definition, and decodes each
  field's base type (`DataMessage.fields_iterator()` → `Field.element(i)`
  → `Value`: unsigned, signed, float, string or bytes). Numeric fields
  whose size is a multiple of the base type size are arrays.
- Streaming `Parser.next()` — no upfront allocation of the whole record
  list, only definition field tables are heap-allocated
- A small built-in profile (`fitz.profile`): names for well-known global
  messages, and name, units, scale and offset for the common fields of
  file_id, file_creator, device_info, event, record, lap, session and
  activity. `message_name(global)`, `field_profile(global, field)`, and
  `FieldProfile.scaled(value)` = raw / scale − offset

## What it deliberately doesn't do yet

- Only a curated slice of the FIT profile, not the full generated one.
  Enum values stay numeric (`sport=1`, not `running`), timestamps stay
  seconds since the FIT epoch (1989-12-31 UTC), and positions stay in
  semicircles rather than degrees
- Strict on base types: a non-canonical base type byte (e.g. `0x04`
  instead of `0x84`) or a field size that isn't a multiple of its base
  type size is rejected, where the FIT SDK falls back to a byte array
- Strict on compressed timestamps: a compressed header before any full
  timestamp, one whose definition also has field 253, or one that would
  overflow `u32` is an error, where the FIT SDK assumes a reference of 0
- No developer field support (returns `DeveloperFieldsUnsupported` if
  encountered)
- No CRC validation (file-level or record-level)
- No support for chained/concatenated FIT files in one buffer

## Rough next steps

1. CRC-16 validation (file header CRC and trailing file CRC)
2. Developer field definitions

## Layout

```
build.zig / build.zig.zon
src/
  fit.zig    core parser (Parser, FileHeader, DefinitionMessage, DataMessage, Record)
             and base-type decoding (BaseType, FieldIterator, Field, Value)
  profile.zig  curated FIT profile slice: message/field names, units, scale, offset
  root.zig   library re-exports (`@import("fitz")`)
  main.zig   CLI: header info, per-message-type counts, `--dump` of decoded fields
```
