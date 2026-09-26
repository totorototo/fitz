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
```

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

Error returns (`FitError.*`) are reserved for things that legitimately
vary in untrusted external bytes — a truncated file, an unknown local
message type, an unsupported record shape. Anything the parser itself
guarantees internally (e.g. a local message type always fits the 16-slot
definitions table because its type is `u4`) is enforced by the types or
by an `assert`. A failed assert means a bug in fitz, never a bad file.

## What v0.1 does

- Parses the 12/14-byte file header (`.FIT` signature, sizes, versions)
- Parses record headers: normal headers and compressed-timestamp headers
- Parses definition messages (local message type table, endianness,
  global message number, field definitions)
- Parses data messages as raw bytes per the matching definition
- Streaming `Parser.next()` — no upfront allocation of the whole record
  list, only definition field tables are heap-allocated

## What it deliberately doesn't do yet

- No semantic decoding: field numbers and base types are exposed as raw
  integers, not resolved against Garmin's message/field profile (e.g.
  global_msg 20 isn't yet labeled "record", field 253 isn't yet labeled
  "timestamp")
- No developer field support (returns `DeveloperFieldsUnsupported` if
  encountered)
- Compressed-timestamp headers are parsed structurally (local message
  type + 5-bit offset) but the offset isn't yet resolved into an actual
  timestamp against a running clock
- No CRC validation (file-level or record-level)
- No support for chained/concatenated FIT files in one buffer

## Rough next steps

1. Base-type value decoding (uint8/16/32, sint variants, float32/64,
   string, the `z` "invalid if all-1s" variants) so data messages yield
   typed values instead of raw bytes
2. A small table of well-known global message numbers / field numbers
   (record, session, lap, event, device_info — whatever your dataset
   actually uses) rather than the full FIT SDK profile
3. Compressed-timestamp reconstruction
4. CRC-16 validation (file header CRC and trailing file CRC)
5. Developer field definitions

## Layout

```
build.zig / build.zig.zon
src/
  fit.zig    core parser (Parser, FileHeader, DefinitionMessage, DataMessage, Record)
  root.zig   library re-exports (`@import("fitz")`)
  main.zig   CLI: dumps header info + a per-message-type count summary
```
