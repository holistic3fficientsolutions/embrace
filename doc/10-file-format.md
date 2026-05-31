# File Format and Import/Export

Embrace persists data to `.embrace` files as zlib-compressed JSON — an open,
unencrypted format — and supports XLSX import/export for interoperability.

## The .embrace File Format

Implementation: `Generic::LoadSave(T)` mixin in `src/persistency.cr`.

### Save Pipeline

```
Persistency state
  → to_json            (JSON serialization of field2record2commit2value + lid2gid + special)
  → Compress::Zlib     (ZLIB compression)
  → Bytes              (written to .embrace file)
```

```crystal
def save : Bytes
    io = IO::Memory.new
    h = Compress::Zlib::Writer.new(io)
    h << to_json
    h.close
    io.rewind
    io.getb_to_end
end
```

### Load Pipeline

```
.embrace file bytes
  → ZLIB decompress
  → from_json           (reconstruct Persistency state)
  → replace(new_state)  (swap internal state)
```

**Note**: `load` does **not** set `context.current_commit` — the caller must navigate
to the desired commit after loading.

### What Gets Serialized

The JSON serialization of `Backend::Memory` includes:
- `"x"`: `field2record2commit2value` — all data and metadata across all commits
- `"y"`: `lid2gid` — LID-to-GID mappings
- `"z"`: `special` — key/value store for application-level metadata

Short JSON keys (`x`, `y`, `z`) are used to minimize file size. Fields marked with
`@[JSON::Field(ignore: true)]` are excluded (context stack, version counters, etc.).

After deserialization, `after_initialize` rebuilds the Hash default blocks (needed
for auto-vivification of nested hashes).

### No Encryption (open format)

`.embrace` files are **not** encrypted. The data is local and the source is
public, so an embedded cipher key would be security theatre. An open, transparent
format is the deliberate choice (portability, GDPR Art. 20). Where confidentiality
is needed, it is the job of the surrounding storage (full-disk encryption, file
permissions).

### File I/O in the GUI

In `src/gui/embrace.cr`:

| Method | Action |
|--------|--------|
| `do_save(name)` | Write `@persistency.save` bytes to file |
| `do_save_as()` | Open DirBrowser dialog with `*.embrace` wildcard |
| `do_load()` | Open DirBrowser, read file, call `@persistency.load(data)` |
| `do_newfile_empty()` | New persistency with one table, one field, one record |
| `do_newfile_demo()` | New persistency with demo dataset (Cities, Times, Projects, Persons, Allocations) |

## XLSX Import

Implementation: `Generic::ImExport(T)` mixin in `src/persistency.cr`.
Uses `xlsx-parser` shard.

`import(file, tablename)`:
1. Read the XLSX file with `XlsxParser::Book`
2. First row → field names (creates fields via `add_field`)
3. Subsequent rows → records (creates records, sets cell values)
4. Type conversion:
   - `Time` → `nil` (not supported)
   - `Int32` → `Int64`
   - `String`, `Float64`, `Bool`, `Nil` → preserved as-is

Returns the new `TableLID`.

## XLSX Export

`export(file, table_lid)`:
1. Create `Crexcel::Workbook`
2. Write field names as header row
3. Write all record values as data rows
4. Type conversion:
   - `true` → `1`, `false` → `0` (XLSX limitation)
   - `Float64`, `Int64`, `String`, `Nil` → preserved

## See Also

- [01-tables-fields-records](01-tables-fields-records.md) — the data model being serialized
- [09-history](09-history.md) — commit history included in serialization
- `src/persistency.cr` — `Generic::LoadSave`, `Generic::ImExport`
- `src/constants.cr` — application constants
- `src/gui/embrace.cr` — file I/O GUI methods
