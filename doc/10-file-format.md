# File Format and Import/Export

Embrace persists data to `.embrace` files as zlib-compressed JSON — an open,
unencrypted format — and interoperates through XLSX import/export and clipboard (TSV)
copy/paste.

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

In `src/gui/embrace_file_ops.cr`. The three lifecycle operations are **atomic-or-no-op**: a
failure leaves both the on-disk file and the in-memory document exactly as they were.

| Method | Action |
|--------|--------|
| `save_document(name) : Bool` | Serialize to memory first, write a sibling temp file, `fsync`, then atomically `rename` it over the target — so a serialization or write failure never damages the file already on disk. |
| `load_document(name) : Bool` | Parse into a **scratch** persistency; swap it in only on full success — so a failed load leaves the current document (and the good file it names) untouched, never a half-loaded/empty split-brain. |
| `import_document(shape, file, table) : Bool` | Import wrapped in a `transaction`; a failed import adds nothing (no half-table) and leaks no context frame. |
| `do_save` / `do_save_as` / `do_load` | Thin dialog wrappers over the above; `do_load` also gates on `protect_unsaved_changes`. |
| `do_newfile_empty` / `do_newfile_demo` | New persistency (empty / demo dataset). |

Failures report a short, user-facing cause via `file_error_cause` (never a Crystal exception class
name or an internal path); the raw exception goes to stderr for debugging.

## XLSX Import

Implementation: `Generic::ImExport(T)` mixin in `src/persistency.cr`.
Uses `xlsx-parser` shard.

`import(file, tablename)` — requires a **header row plus at least one data row**; the header cells
must be **text**, and no data row may be wider than the header. A failed import leaves the document
unchanged.
1. Read the XLSX file with `XlsxParser::Book`
2. Parse and validate the whole sheet FIRST — header text check, type normalisation
   (`Time` → `nil`, `Int32` → `Int64`; `String`/`Float64`/`Bool`/`Nil` preserved). A rejected file
   therefore never mutates anything, rather than relying on a rollback to undo a half-table.
3. Hand the parsed rows and the header to `import_rows`, which builds the table inside a
   `transaction` (defence for a failure during the writes themselves).

Rows stay **ragged**: a short spreadsheet row leaves its trailing cells *undefined*, not empty —
padding them would write an explicit value where the source had none, which a diff-Shape would
highlight and the commit summary would count.

Returns the new `TableLID`.

`import_rows(rows, tablename, field_names)` — the shared table-building step, also used by the
clipboard paste below. `field_names` defines the width (`""` for an unnamed field); a row may be
shorter but never wider. It is deliberately policy-free about blanks, because its two callers
disagree: a blank `.xlsx` cell must stay undefined, a blank TSV field is the empty string.

## XLSX Export

`export(file, table_lid)`:
1. Create `Crexcel::Workbook`
2. Write field names as header row
3. Write all record values as data rows
4. Type conversion:
   - `true` → `1`, `false` → `0` (XLSX limitation)
   - `Float64`, `Int64`, `String`, `Nil` → preserved

## Clipboard (TSV)

Implementation: `TSV` in `src/tsv.cr`; the walk is `SimpleMatrixAdapter#to_tsv`
(`src/gui/shape.cr`), the two commands are in `src/gui/embrace_file_ops.cr`.

**Copy Shape to clipboard** puts the Shape's *rendered rectangle* on the system
clipboard — every cell the user sees, header bands and dead pivot intersections
included, with no header/data separation. A Shape may be a pivot, a Kanban board or
a floor plan, so it has no canonical header row to split off; filtering per cell
would drop a different number of cells from each row and destroy the alignment.

**Paste clipboard as new table** creates a table whose fields are unnamed and opens
a Shape on it. Where the first row does hold column names, "Take field names from
record" (cell context menu) promotes them — that operation also *consumes* the row.

Note the asymmetry with XLSX above: `export` writes **table truth with headers**,
the clipboard carries the **rendered grid without them**.

### Format

Tab-separated, because that is what spreadsheets put on the clipboard: it pastes
into Calc or Excel cells directly, with no separator dialog and no locale ambiguity
(a German locale uses `;` for CSV and `,` as the decimal mark). A field is quoted
iff it contains a tab, a line break or a quote, and an inner quote is doubled — the
same convention those applications emit and accept, so a cell containing a tab
survives instead of silently becoming two fields.

### Fidelity — what does NOT round-trip

| Written as | Comes back as |
|---|---|
| Bool | Bool — exported as the `'true` / `'false` literal, which `CellHelper.convert` parses back |
| Reference cell | plain text: the **relation is lost** (it is flattened to the referenced value) |
| Aggregate cell | plain text of the display artifact (`#5`, `#5/Σ123`), not a value |
| `"007"` | `Int64 7` — pasted text is parsed like typed input |
| undefined | the empty string — TSV cannot distinguish "no value" from "empty" |
| a merged header spanning N columns | its label repeated N times (the screen shows one merged box) |
| the Rank column | an ordinary data field, beside the new table's own live Rank |
| field names | **not carried at all** — a detail Shape shows them in the Field List, not in the grid, so a copy of embrace's own Shape never contains a name row |

A non-tabular payload (prose from a browser, a URL) is accepted and becomes a
one-column table. There is no undo; the recovery is "Delete table".

## See Also

- [01-tables-fields-records](01-tables-fields-records.md) — the data model being serialized
- [09-history](09-history.md) — commit history included in serialization
- `src/persistency.cr` — `Generic::LoadSave`, `Generic::ImExport`
- `src/constants.cr` — application constants
- `src/gui/embrace.cr` — file I/O GUI methods
