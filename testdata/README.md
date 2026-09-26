# Test fixtures

Real FIT files, written by devices and tools other than fitz. `src/fixtures_test.zig` embeds
them, so `zig build test` runs against them. Each file is listed in `build.zig` (`fixtures`),
because `@embedFile` can't reach outside `src/` by path.

All files come from the test suite of python-fitparse
(<https://github.com/dtcooper/python-fitparse>, `tests/files/`), MIT-licensed. Its license is in
`LICENSE-python-fitparse`. Some of them were first published as FIT SDK examples.

| File | What it checks |
|---|---|
| `DeveloperData.fit` | Developer fields in a big-endian file, decoded through their field_description (doughnuts_earned 1, 2, 3) |
| `20170518-191602-1740899583.fit` | 8317 developer field values, each one the size its field_description's base type needs |
| `compressed-speed-distance.fit` | 755 compressed-timestamp records; timestamps and heart rates match the CSV |
| `compressed-speed-distance-records.csv` | fitparse's expected values for the file above: timestamp, heart rate, speed, distance, cadence |
| `Activity.fit` | A plain SDK example activity |
| `activity-filecrc.fit` | Rejected: file CRC mismatch |
| `activity-unexpected-eof.fit` | Rejected: truncated |
| `coros-pace-2-cycling-misaligned-fields.fit` | Rejected by the strict base-type policy: an event field declared uint32 with size 1. The SDK and fitparse read it as bytes |
| `activity-settings.fit` | Two chained files; fitz reads the first |
| `sample_mulitple_header.fit` | Chained files, 3023 data messages in all (fitparse's count) |
| `activity-settings-corruptheader.fit` | Chained files where the second header's signature is `.GIT` |

Don't add FIT files you recorded yourself: they hold GPS tracks and health data. `.gitignore`
ignores `*.fit` everywhere except here.
