# Basic Tables: Tables, Fields, and Records

The relational data model in embrace is implemented in `src/persistency.cr`.
All data lives in tables, which consist of fields (named columns) and records (unnamed rows).

## Tables, Fields, Records

```
 Table "Persons" (TableLID = 3)
 +------+---------+----------+---------+
 | Rank | Person  | City     | Country |
 +------+---------+----------+---------+
 |    1 | Alan    | Boston   | USA     |
 |    2 | Denny   | Boston   | USA     |
 |    3 | Hans    | Munich   | Germany |
 +------+---------+----------+---------+
   auto   FieldLID  FieldLID   FieldLID
   field    = 4       = 5        = 6
```

- **Table**: a collection of fields and records, identified by a `TableLID` (Int64)
- **Field**: a named column, identified by a `FieldLID` (Int64)
- **Record**: an unnamed row, identified by a `RecordLID` (Int64)
- **Rank**: a special auto-generated field every table has — like a line number

These type aliases are defined in `src/persistency.cr`:

```crystal
alias FieldLID = Int64
alias RecordLID = Int64
alias CommitLID = Int64
alias TableLID = Int64
```

## Cell Types

Cells are untyped by default. A cell can hold any of these values:

```crystal
alias Cell = String | Int64 | Float64 | Bool | Nil   # src/persistency.cr
```

- `Nil` means "undefined" — the cell has no value, not that it is an empty string
- There is no `Int32` — embrace uses `Int64` exclusively
- Reference fields are the only typed fields (see [02-references](02-references.md))

User input is parsed by `CellHelper.convert` in `src/gui/cell.cr`: `"42"` becomes `42i64`,
`"3.14"` becomes `3.14f64`, and anything else stays a `String` (so plain `true` is the
*string* `"true"`). The Bool and undefined literals are entered with a leading apostrophe:
`'true` → `true`, `'false` → `false`, `'nil` → `nil`. Surrounding whitespace is tolerated
(`" 'true "` → `true`). A selected Bool cell can also be flipped with the Space key (see
tutorial #2, "space for toggling bools").

## LIDs — Local IDs

Every table, field, record, and commit gets a unique `Int64` identifier called a LID.
LIDs are assigned consecutively by `get_new_lid` in `Backend::Memory`.
Each LID also has a corresponding GID (Global ID, 256-bit random) for inter-instance communication,
stored in `@lid2gid`.

Names are user-defined sugar stored in the `Names` meta-field — the system works identically
if all names are empty strings.

## Sparse 3D Storage

All data is stored in a single nested hash in `Backend::Memory`:

```crystal
@field2record2commit2value : Hash(FieldLID, Hash(RecordLID, Hash(CommitLID, T)))
```

The three dimensions are:
1. **FieldLID** — which column
2. **RecordLID** — which row
3. **CommitLID** — at which point in time (see [09-history](09-history.md))

Only defined cells are stored — everything else is `nil` by default. This sparse
representation means empty tables cost nothing.

Reading a value (`get_value` in `Backend::Memory`) finds the most recent commit
along the current commit path that has a value for that (field, record) pair.

Writing a value (`set_value`) stores it at the current commit. If the current commit
is already closed, a new commit is automatically created first.

## Meta-Fields

System metadata is stored alongside user data using **negative FieldLIDs**.
These are defined in the `MetaFieldLIDs` pseudo-enum in `src/persistency.cr`:

| MetaFieldLID | Value | Purpose |
|-------------|-------|---------|
| `RootCommit` | 0 | Commit predecessors (commit DAG) |
| `Predecessors` | -1 | Linked list ordering for fields/records/tables |
| `Names` | -2 | Display names (String) for fields and tables |
| `TableLastTable` | -3 | Sequence anchor over all tables |
| `TableLastField` | -4 | `table_lid → last_field_lid` in ordering chain |
| `TableLastRecord` | -5 | `table_lid → last_record_lid` in ordering chain |
| `RefersTo` | -6 | `source_field_lid → target_field_lid` (reference typing) |
| `BelongsTo` | -7 | `field_lid or record_lid → table_lid` (ownership) |

The `@meta_version` counter in `Backend` increments on every meta-field write,
separately from `@version` which increments on every write. This distinction
lets the GUI know when structure (not just data) has changed.

## Ordering via Linked Lists

Fields and records within a table are ordered using doubly-linked lists via the
`Predecessors` meta-field. The `TableLastField` and `TableLastRecord` meta-fields
point to the tail of each list.

To get all records of a table in order, `get_ancestors(last_record_lid)` traverses
the `Predecessors` chain from the tail back to the head, then reverses the result.

Moving a record (`move_record_by_rank`) re-links the predecessor chain.

`move_records(record_lids, source_table, target_table)` re-homes a set of records
into another, structure-matching table (`Generic::Basics`): each record keeps its
`RecordLID` but is unlinked from the source chain, spliced into the target's, its
`BelongsTo` rewritten, and its cells re-keyed onto the target's position-matched
fields (single copy — the source cell is cleared). It is **its own inverse** (move the
records back to restore), and it is the only operation that changes a record's table —
so **`BelongsTo[record]` is no longer write-once**. Inbound references to a moved record
collapse to `"(no reference)"` while it is out and resolve again when it is moved back;
they are *not* healed across the move (see [02-references](02-references.md)). `changes_in_open_commit`
(the History diff) renders a move faithfully — a removal from the source plus an addition
to the target, with the cell re-keys suppressed (T-010); the selective-commit router
(`records_with_writes_at`, `table_of`/`float_writes`) still routes a moved record's writes
by table without special move-awareness (value-preserving, a known refinement).

## Higher-Level Operations

The `Layer01` class (built on `Backend::Memory` via `Backend::Cacher`) provides
table-level operations through several mixins:

| Mixin | Purpose |
|-------|---------|
| `Generic::Basics` | `add_table`, `add_field`, `add_record`, `remove_*`, `move_*`, `get_table`, `get_field`, `complex_query` |
| `Generic::ImExport` | XLSX import/export (see [10-file-format](10-file-format.md)) |
| `Generic::LoadSave` | AES-encrypted save/load (see [10-file-format](10-file-format.md)) |
| `Generic::Refactoring` | `factor_out_reference`, `associate_fields`, `dissociate_fields` |
| `Generic::Branches` | `get_commit_path`, `get_ordered_commit_leaves` |

The class hierarchy:

```
Backend::Memory(T)          raw hash storage + commit logic
  Backend::Cacher(T)        adds caching layer
    Layer01(T)              includes all 5 Generic mixins

alias Default = Layer01(Cell)   # the standard persistency type
```

## Design Principles

1. **No physical delete**: `remove_table`/`remove_field`/`remove_record` only modify metadata.
   The underlying cell values remain, making un-delete possible.
2. **Untyped by default**: only reference fields have a type. This maximizes flexibility.
3. **Names are optional**: the system addresses everything by LID, never by name.
4. **Sparse by default**: undefined cells cost no storage.

## See Also

- [00-overview](00-overview.md) — the big picture
- [02-references](02-references.md) — next: connecting tables with typed references
- [09-history](09-history.md) — the commit system that provides the third storage dimension
- `src/persistency.cr` — full implementation
- `src/gui/cell.cr` — cell input parsing
