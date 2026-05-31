# Pivot::Simple — Single-Level Pivot

`Pivot::Simple(T,U)` in `src/table/pivot.cr` groups records from a parent table into
a 2D grid with row headers, column headers, and intersection cells. It is the building
block used internally by `Pivot::Hierarchic`.

## Overview

Given a parent table and a fieldlist that marks some columns as Row headers and others
as Column headers, `Pivot::Simple` produces:

```
                        Column headers
                     Project A   Project B
                    +----------+----------+
 Row        Alan    |  100     |          |     <- intersection cells
 headers    Denny   |   50     |   75     |
            Hans    |          |  120     |
                    +----------+----------+
```

The grid is sparse: most intersections may be empty.

## Grid Layout

The Simple pivot's `size` is `[@ch + @rw, @rh + @cw]`, where:

| Variable | Meaning |
|----------|---------|
| `@ch` | Column header height (number of column header levels) |
| `@rh` | Row header width (number of row header levels) |
| `@rw` | Number of distinct row clusters (leaves of the row tree) |
| `@cw` | Number of distinct column clusters (leaves of the column tree) |

The grid has four quadrants:

```
     0..@rh-1          @rh..@rh+@cw-1
    +-----------+--------------------+
    | Dead area | Column headers     |  0..@ch-1
    | (NilDead) | (top-right)        |
    +-----------+--------------------+
    | Row hdrs  | Intersection cells |  @ch..@ch+@rw-1
    | (bot-left)| (bottom-right)     |
    +-----------+--------------------+
```

Top-left quadrant returns `NilDeadArea`. Intersection cells return `nil` when empty (sparse).

## Clustering

The `cluster_row_ids` method groups parent rows into a tree:

1. **Row-by-row insertion**: For each parent row, read the header column values and
   push the row ID down the tree. Each unique value creates a branch.

   ```
   Row tree for headers [Person]:
   root
   ├── "Alan"  → {row_ids: [0]}
   ├── "Denny" → {row_ids: [1]}
   └── "Hans"  → {row_ids: [2]}
   ```

2. **ShowAll expansion**: If a header column is a reference field with `showall=true`,
   all reference tags (including unreferenced ones) are added as branches. Tags are
   constrained by parent headers (see [07-pivot-hierarchic](07-pivot-hierarchic.md)).

3. **Sorting**: `sort_cluster` sorts branches at each level according to `sort_asc?`
   from the fieldlist.

4. **Simplification**: `simplify_tree` converts the clustering tree into a
   `RootedTree({Int32,Int32}, T)` where each leaf gets a `{start_index, end_index}` pair
   for mapping back to grid positions.

## Intersection Cells

`calculate_intersections` maps every parent row to its `{row_cluster, col_cluster}`
position, then stores the row IDs in a sparse table:

```crystal
@tables[{row, col}] = Raw::Reduced(T).new(@parent, 0, row_ids)
```

Each intersection cell is a `Reduced` view of the parent — containing only the rows
that belong to both the row cluster and column cluster. This means:
- Reading an intersection reads from the original parent table (no copies)
- Writing an intersection writes back to the parent

Iteration order in `@tables` is: 1. row, 2. col, 3. row_id — this matters for
`#rows` and `#cols` iterators that `Hierarchic` relies on.

## Header Cells

Header cells display the cluster value (the distinct field value that defines the group).
They are stored in `@headers` as `RootedTree(T,T)` nodes, which preserves the parent-child
relationship for hierarchical navigation.

Each header also has a companion table in `@tables` — a 1D `Reduced` slice of the
parent containing all rows in that cluster. This enables:
- Getting the rank for constraint propagation
- Writing to a header cell (changes all values in the cluster)

## Key Methods

| Method | Purpose |
|--------|---------|
| `[]?(index)` | Read a cell: header value, `NilDeadArea`, or `nil` (empty intersection) |
| `[]=(index, value)` | Write to a header cell (updates all rows in the cluster) |
| `get_table(index)` | Get the `Reduced` sub-table for any cell |
| `get_clusters(index)` | Get `{column_index → {value, rank}}` for all headers at an index |
| `get_index(clusters, is_leaf)` | Reverse lookup: clusters → grid index |
| `get_siblings(index)` | All sibling header values at the same level |
| `dig(index)` | (via `Hierarchic`) Drill down to the underlying table |
| `rows` / `cols` | Sparse iterators over intersection cells |

## Constraints

`Pivot::Simple` receives a `@constraints : Hash(Int32, Int32)` at construction.
These constraints are column_index → rank mappings that restrict which reference
tags appear during `cluster_row_ids`. The constraints are propagated downward
during tree construction:

```crystal
value.constrain(constraints) if value.is_a?(Interface::Referenceable)
constraints[col_id] = rank  # propagate to next level
```

This ensures that in a hierarchic context, only valid reference tags appear
(e.g., only cities of the current country).

## Padding

`Hierarchic` may call `Simple` with indices slightly out of bounds — this is the
"padding" mechanism. `Simple` handles this gracefully:
- `[]?` returns `nil` for out-of-bounds indices (up to one past the end)
- `get_table` returns `@empty_table` for missing cells

## See Also

- [05-fieldlist](05-fieldlist.md) — how the fieldlist drives header selection
- [07-pivot-hierarchic](07-pivot-hierarchic.md) — how multiple Simple pivots are nested
- [04-table-classes](04-table-classes.md) — the table abstraction Simple builds on
- `src/table/pivot.cr` — implementation
- `src/table/sparse.cr` — `Sparse(T)` used for `@headers` and `@tables`
