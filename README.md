# fitz

Minimal Zig parser for the FIT (Flexible and Interoperable Data Transfer)
binary format. FIT was authored by Garmin but is an open protocol used
across the industry — Suunto, Coros, Wahoo and others read and write it
too, so this isn't Garmin-specific. Library + CLI, built to grow feature
by feature rather than all at once.

Not compile-tested against a live Zig toolchain (sandbox has no network
access to ziglang.org) — build it locally and report back any errors.

## Build

```sh
zig build            # builds lib + cli into zig-out/
zig build test       # runs unit tests
zig build run -- path/to/file.fit
```

Written and adjusted for Zig 0.16.0. That release shipped a large
breaking change: **all I/O now requires an explicit `Io` instance**
(`std.fs` moved to `std.Io`), `main` can take a `std.process.Init`
parameter ("Juicy Main") for the allocator/Io/args instead of reaching
for globals, and containers like `ArrayList` dropped their managed
(allocator-as-field) form in favor of `.empty` + passing the allocator
to each call.

This only actually touches `main.zig` and the build script — `fit.zig`
does no I/O of its own (it parses an in-memory `[]const u8`), so the
core parser is unaffected by any of this churn. If `zig build` still
complains, the likely spots are:

- `build.zig.zon` may need a `.fingerprint` field the compiler will
  suggest a value for on first build — paste it in if asked.
- `std.AutoHashMap(u16, u32).getOrPutValue(...)` in `main.zig`: if this
  container also lost its managed form, it'll want `gpa` passed as the
  first argument.

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
definitions table because its type is `u4`) isn't re-checked at runtime.

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
