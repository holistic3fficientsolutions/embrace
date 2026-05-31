# The Table Abstraction Layer

All data views in embrace — from raw in-memory storage to hierarchic pivot tables —
share a common table abstraction defined in `src/table/`. This document covers the
full class hierarchy. See also `src/table/table.md` for the UML diagram.

## Class Hierarchy

```
Table::Base(T)                              src/table/base.cr
├── Table::Sparse(T)                        src/table/sparse.cr
└── Table::Lazy::Base(T)                    src/table/lazy.cr
    ├── Table::Lazy::Raw::Base(T)           src/table/raw.cr
    │   ├── Raw::Sliced(T)
    │   ├── Raw::Reduced(T)
    │   ├── Raw::Derived(T)
    │   ├── Raw::Combined(T)
    │   ├── Raw::Memory(T)
    │   ├── Raw::Indexed(T)
    │   └── Raw::Permuted(T)
    ├── Table::Lazy::Aggregate(T)           src/table/pivot.cr
    ├── Table::Lazy::Fieldlist(T,U)         src/fieldlist.cr
    ├── Table::Lazy::Pivot::Base(T)         src/table/pivot.cr
    │   ├── Pivot::Simple(T)
    │   └── Pivot::Hierarchic(T)
    └── Table::VirtualTable(T,U)            src/virtualtable.cr
```

## Table::Base(T) — The Root Abstraction

`src/table/base.cr` — the abstract root of all tables.

Every table has:
- `size : Index` — dimensions as `Array(Int32)` (e.g. `[3, 5]` for a 3-row, 5-column table)
- `[]?(index) : T|Nil` — read a cell (returns nil if undefined)
- `[]=(index, value) : Index` — write a cell (returns Index for sticky cursor support)

Iterators:
- `each` — traverses all cells in dimension order (innermost dimension varies fastest)
- `each.with_index2` — yields `{value, Array(Int32) index}` (vs. standard `with_index` which gives flat Int32)
- `each.with_dim` — yields `{value, Int32 dimension}` indicating which dimension just advanced (used by `to_csv`)

Convenience:
- `to_a` — flat array of all cells
- `to_a2` — 2D array (only for 2D tables)
- `to_csv` — CSV string (up to 3D; separators: `\n`, `;`, `/`)

The `TableIterator` handles arbitrary-dimensional iteration with a rolling index.

## Table::Sparse(T) — Sparse 2D Matrix

`src/table/sparse.cr` — a 2D matrix that stores only defined cells.

Used internally by `Pivot::Simple` for intersection cells. Key design:
- Uses `SortedSet(T)` (internal class, not Crystal stdlib) for O(n) sorted iteration
- `SortedSet` maintains both an `Array` (for ordered access) and a `Hash` (for O(1) lookup)
- Lazy sorting: insertion appends; `ensure_sorted` only runs before iteration
- Supports `each_starting_with(value)` for efficient range iteration

## Table::Lazy::Base(T) — Chained Lazy Tables

`src/table/lazy.cr` — the abstract base for all lazily-evaluated tables.

**Key insight**: all Lazy subclasses do index mappings to a parent table, chained
arbitrarily. No data is copied — every `[]?` call traces through the chain to
the root table's actual storage.

Abstract interface every Lazy table must implement:

```crystal
protected abstract def map_cell(index : Index) : {Table::Lazy::Base(T), Index}
protected abstract def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T), Int32, Index}|Nil
abstract def version : Int32
private abstract def update
```

- `map_cell` — given a local index, return `{parent_table, parent_index}` to delegate to
- `map_hyperplane` — map a hyperplane operation (add/remove/move) to the parent
- `version` — increments on every data change; used for cache invalidation
- `update` — lazily recompute caches when parent version changes

### Multi-Assignment Protocol

For tables that span multiple data sources (like VirtualTable):

```crystal
protected abstract def multiassign_begin
protected abstract def multiassign_end
protected abstract def is_multiassign? : Bool
```

`multiassign_begin` queues writes; `multiassign_end` executes them in the correct
(topologically sorted) order. See [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md).

## Table::Lazy::Raw Subclasses — Dense Raw Tables

`src/table/raw.cr` — dense tables that transform parent table indices.

All Raw tables work for arbitrary dimensions. Hyperplane operations (`hyperplane_add`,
`hyperplane_remove`, `hyperplane_move`) always operate on the **root** table level,
even when called on a wrapper. The `hyperplanes(dimension, index)` method traces
the chain to find the root.

### Raw::Memory(T)

The only table that actually stores values. Arbitrary dimensions, dense storage.
`load(content)` fills from a flat array; `linearize_index` converts multi-dim index to flat offset.

### Raw::Sliced(T)

Selects a contiguous region, possibly reducing dimensions. Supports negative indices
and ranges in the slice specification. `nil` in a slice position means "full dimension".

```crystal
table.slice([nil, 3])  # all rows, column 3 only → 1D table
table.slice([1..5, nil])  # rows 1-5, all columns
```

**Caveat**: Sliced does not auto-update when the parent changes size or ordering.
The using instance must recreate the Sliced.

### Raw::Reduced(T)

Arbitrary reduction of one dimension — selects a subset of indices (not necessarily contiguous).
Like Sliced, does not auto-update.

### Raw::Derived(T)

A table computed from a parent via a block. Dimensions and sizes may differ arbitrarily.
Auto-updates: caching is fully recalculated on parent version change.

### Raw::Combined(T)

Glues two tables along a given dimension. The second table must be a `Raw::Derived`
(otherwise hyperplane semantics would be ambiguous). Auto-updates (no caching).

### Raw::Indexed(T)

Adds auto-indexed dimensions to a parent. One dimension is "not indexed" — the user
writes to it. All other dimensions get automatic sequential indices. Writing to an
indexed axis triggers `move_hyperplane`. The index includes a root cell at position 0.

### Raw::Permuted(T)

Arbitrary permutation of dimensions. `@permutation` maps new dimension → old dimension.

## Hyperplanes — The Uniform Interface

All table types expose the same hyperplane interface (defined in `Table::Lazy::Base`):

| Method | Effect |
|--------|--------|
| `hyperplane_add(dimension, index)` | Add a new row/column/hyperplane |
| `hyperplane_remove(dimension, index)` | Remove a row/column/hyperplane |
| `hyperplane_move(dimension, from, to)` | Reorder a row/column/hyperplane |

The `dimension` parameter specifies which axis (0 = rows, 1 = columns, etc.).
The `index` specifies where in the table.

**Behaviour varies by table type** — see `doc/hyperplanes.md` for the full comparison:
- `Raw::Base`: operates on full hyperplanes at root level
- `VirtualTable`: dimension 0 = add/remove records, dimension 1 = add/remove fields; `hyperplane_move` not supported (use rank assignment instead)
- `Pivot::Hierarchic`: cells can be as small as single intersections; `hyperplane_move` reassigns clusters; `hyperplane_add` creates siblings or clones

## Pivot Tables

`src/table/pivot.cr` — sparse pivot tables that cluster records into a 2D grid.
These are covered in detail in their own documents:

- [06-pivot-simple](06-pivot-simple.md) — `Pivot::Simple`: single-level grouping
- [07-pivot-hierarchic](07-pivot-hierarchic.md) — `Pivot::Hierarchic`: nested multi-level pivot

### Aggregate(T)

`Table::Lazy::Aggregate(T)` is a companion to the pivot tables. Given a parent table
and a set of column groups, it displays aggregated values:

- Single record: shows the actual value
- Multiple records: shows `#count` or `#count/Σsum` (if the column is numeric)
- Sums are cached in `@sums_cache` per cell index

## Design Principles

1. **Lazy evaluation**: No data is copied through the chain. `[]?` traces to the root.
2. **Version-based invalidation**: Each table has a `version` counter. Children check
   `parent.version` in `update` and recompute caches only when needed.
3. **Dimension-agnostic**: The abstraction supports arbitrary dimensions, even though
   most practical uses are 2D.
4. **Index returns**: All mutating methods (`[]=`, `hyperplane_add`, `hyperplane_move`)
   return an `Index` for sticky cursor support — the GUI needs to know where the
   cursor should end up after an operation.

## See Also

- [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md) — VirtualTable builds on this hierarchy
- [06-pivot-simple](06-pivot-simple.md) — Pivot::Simple details
- [07-pivot-hierarchic](07-pivot-hierarchic.md) — Pivot::Hierarchic details
- `src/table/table.md` — UML class diagram
- `doc/hyperplanes.md` — hyperplane behaviour comparison across table types
