# ZipCause

ZipCause is a read-only MoonBit command-line tool for explaining why two ZIP build artifacts differ. It compares archive bytes, decoded member contents, compression, timestamps, metadata, comments, and entry order.

## Run

With the MoonBit toolchain installed:

```sh
moon run --target native cmd/main -- compare old.zip new.zip
moon run --target native cmd/main -- compare old.zip new.zip --format json
```

The CLI currently targets native hosts. The core was built and tested with MoonBit compiler 0.10.14.

Exit codes are stable for scripts:

- `0`: archives are byte-identical
- `1`: both archives are valid but differ
- `2`: invalid input, unsupported ZIP feature, or incorrect command usage

Example text output:

```text
Archives differ:
- member_content_changed: app/config.json — uncompressed entry data differs
- timestamp_changed: app/config.json — DOS timestamp differs between archive entries
```

JSON output has a `byte_identical` boolean and a `findings` array. Each finding contains `kind`, `path`, and `detail` fields.

## Supported input

- Single-volume classic ZIP archives
- STORE and DEFLATE entries
- ASCII and UTF-8 entry names
- Up to 64 MiB input, 10,000 entries, 32 MiB uncompressed per entry, and 128 MiB total uncompressed data

ZIP64, encrypted entries, duplicate names, other compression methods, and multi-volume archives are rejected with an explicit error. The tool does not rewrite archives, validate signatures, or infer source-code or build-environment equivalence. ZIP container fields not yet recognized are reported as `unclassified_container_difference` rather than silently ignored.

## Development

```sh
moon update
moon info
moon fmt
moon check --target native --deny-warn
moon build --target native
moon test --target native
python scripts/cli_smoke.py
```

The comparison core uses [`moonbit-community/flate`](https://github.com/moonbit-community/flate) for bounded ZIP decoding and CRC verification. ZipCause is licensed under Apache-2.0.
