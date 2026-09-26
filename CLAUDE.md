# fitz — project rules

## Project

Minimal Zig library + CLI for parsing FIT (Flexible and Interoperable Data Transfer) files,
the binary activity format written by Garmin, Suunto, Coros, Wahoo, etc. It grows one feature
at a time, not all at once.

- `src/fit.zig`: the core parser. It is pure and does no I/O: it parses an in-memory `[]const u8`.
- `src/main.zig`: the CLI (`zig build run -- [--dump [--all]] file.fit`). All I/O lives here.
  `--dump` is for reading (a block per message, known fields with data, dates and degrees);
  `--dump --all` is one grep-able line per message with every field as stored. Both decode
  developer fields the file describes (field_description, 206).
- `src/profile.zig`: FIT profile lookups (names, units, scale, offset, enum value names),
  exported as `fitz.profile`. Pure lookups over `src/profile_generated.zig`, which
  `tools/profile_generate.py` generates from Garmin's FIT Python SDK (see README). Never edit
  the generated file by hand: fix the generator and regenerate. It is Garmin-derived (FIT
  Protocol License), so keep its header notice.
- `src/root.zig`: the library entry point.
- `src/fixtures_test.zig` + `testdata/`: tests against real third-party FIT files, embedded by
  name (list them in `build.zig` `fixtures`). Expected values must come from outside fitz
  (fitparse's tests/CSV, or cross-checks within the file), not from fitz's own output. Never
  commit personal recordings (GPS and health data).
- `src/snapshots/`: approved CLI dumps of a few fixtures (`build.zig` `snapshot_fixtures`),
  compared by a test in `main.zig`. The one place where fitz's own output is the expected
  value: they catch regressions, they don't prove correctness. Regenerate them with the CLI
  (README, "Snapshots") only for an intended output change, and review the diff.
- **Current scope**: file header, chained files in one buffer (all verified in `Parser.init`,
  each with its own definitions; `file_index`/`file_count`, and `next_in_file`/`file_advance`
  to stop at each file), header and file CRC-16
  verification, normal and compressed-timestamp record headers (compressed timestamps are rebuilt against
  the latest field 253), definition messages, and data messages with base-type value decoding
  (`Field.element` returns a typed `Value`, or null for the base type's invalid sentinel).
  Messages, fields and enumerated values are named, scaled and given units by `profile.zig`,
  and `profile.data_field_profile` applies the subfield a message selects (first match wins).
  Developer field definitions are parsed and each data message's developer fields are split out
  as raw bytes. Each file's field_description (206) messages are collected in
  `Parser.developer_field_descriptions` (base type, name, units, scale, offset), and
  `DeveloperField.field(base_type)` decodes a field once its description is known.
- **Not yet supported**: profile components, and a field_description's array,
  components and native-field entries.
- **Error policy**: `FitError` is for invalid external bytes. An `assert` is for parser invariants,
  so a failed assert means a bug in fitz, never a bad file.
- **Targets Zig 0.16.0**: I/O needs an explicit `std.Io`, `main` takes `std.process.Init`,
  and containers are unmanaged (`.empty` + pass the allocator on each call).
  Don't write pre-0.16 idioms.

## Coding style: TigerBeetle (TIGER_STYLE)

Follow https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md. Key points:

- **Safety > performance > developer experience**, in that order.
- **Assertions everywhere**: at least 2 per function on average. Assert arguments, return values, pre/postconditions and invariants.
- **Paired assertions**: check the same property in two places (e.g. before writing data and after reading it back).
- **Memory allocation (relaxed vs. TigerBeetle)**: dynamic allocation after init is allowed.
  Pass allocators explicitly, make ownership clear, and pair every allocation with a
  `defer`/`errdefer` free. Sizes that come from untrusted input must still be bounded.
- **Put a limit on everything**: every loop and queue has a fixed upper bound. No unbounded recursion.
- **Explicit sized types** (`u32`, `u64`); avoid `usize` except for indexing.
- **Functions ≤ 70 lines**. Keep control flow simple, centralize branching in the parent, keep leaf functions pure.
- **Handle every error**; never discard one silently.
- **Naming**: `snake_case` for functions and variables. No abbreviations. Put units and qualifiers last, in descending significance (`latency_ms_max`, not `max_latency_ms`).
- **Line length ≤ 100**, and run `zig fmt`.
- **Comments explain why**, written as full sentences.
- **Declare variables in the smallest possible scope**, as close to use as possible.
- **Pass large args as `*const`** to avoid copies.

## Negative space programming

Assert what *must not* happen, in addition to what should:
- Assert the positive space (the expected valid state) **and** the negative space (invalid states that must be impossible).
- Assert at boundaries where valid data turns invalid (e.g. `assert(index < len)` and `assert(count <= count_max)`).
- Prefer `unreachable` for states that can't occur. Don't write silent fallbacks.
- Handle each case of a condition explicitly. A missing `else` should be a deliberate choice.

## Testing: required for every change

- **Every** feature, helper or function you add ships with unit tests (`test "..." {}` blocks) in the same change.
- Tests cover the valid space, the edge cases (0, 1, max, max+1) and the invalid space.
- Run `zig build test --summary all` and confirm it passes before calling any work done. Plain
  `zig build test` prints nothing on success, so the summary is what shows the pass counts.
- CI (`.github/workflows/ci.yml`) also checks `zig fmt`, the 100-column limit and ReleaseSafe,
  so run those locally too before pushing.
