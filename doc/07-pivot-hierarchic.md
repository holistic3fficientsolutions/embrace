# Pivot::Hierarchic — Multi-Level Nested Pivot

`Pivot::Hierarchic(T,U,V)` in `src/table/pivot.cr` is the fully editable multi-layered
pivot table. It chains multiple `Pivot::Simple` instances to create nested groupings,
enabling views like "Country → City → Person" with aggregated values at each level.

## Architecture

Hierarchic maintains a tree (`@tree`) where:
- **Inner nodes** are `Pivot::Simple(T,U)` instances — one per level pair
- **Leaves** are `Aggregate(T)` instances — displaying aggregated data

```
@tree (RootedTree):
  root: Simple(L0)   [Country rows × Project cols]
    ├─ {r0,c0}: Simple(L1)   [City rows × SubProject cols]
    │   ├─ {r0,c0}: Aggregate  [Person×Allocation values]
    │   └─ {r1,c0}: Aggregate  [Person×Allocation values]
    ├─ {r1,c0}: Simple(L1)   [City rows × SubProject cols]
    │   └─ ...
    └─ {r0,c1}: ...
```

Edges are `{Int32, Int32}` tuples representing the `{row_index, col_index}` within the
parent Simple's intersection cells.

## Initialization

Hierarchic takes two inputs:
- `@parent : Table::Lazy::Raw::Base(T)` — typically a VirtualTable
- `@fields : Table::Lazy::Raw::Base(V)` — typically a Fieldlist

The lazy `update` method:

1. **`parse_fieldlist`** — reads the fieldlist to populate:
   - `@row_headers[level]` — array of `{column, sort_asc?}` per level
   - `@col_headers[level]` — same for column headers
   - `@aggregates[level]` — arrays of column indices per level
   - Enforces: `@row_headers.size == @col_headers.size` (padded with empty arrays)

2. **`populate_hierarchy_tree`** — builds the tree top-down:
   - Level 0: Creates root `Simple` with `@row_headers[0]` and `@col_headers[0]`
   - For each intersection cell of the root Simple:
     - Gets the `Reduced` sub-table (rows in that cluster)
     - Collects constraints from parent headers
     - Level < max: Creates a child `Simple` with next level's headers and constraints
     - Level = max: Creates a leaf `Aggregate`
   - Recursion stops when no more levels exist

3. **`calc_offsets`** — bottom-up size calculation for 2D positioning

4. **`calc_projections`** — computes scroll ordering priorities

## Index Mapping

`map_index(index)` is the central method — it converts a flat 2D `[row, col]` index
into the correct position within the nested tree:

```
Global index [row, col]
  → Walk down @tree using @offsets
    → At each level: subtract parent offset, find which child contains this index
    → Return: {leaf_table, local_index, path_of_{table,index}_pairs}
```

The `@offsets` hash maps each tree node to `{height_offsets, width_offsets}` arrays,
enabling O(log n) lookup.

## Constrained Reference Tags

In a hierarchic pivot, reference tags at inner levels must respect the grouping at
outer levels. For example:

```
Level 0 Row: Country
Level 1 Row: City     ← only cities of the current country should appear
```

This is implemented via the `@constraints` hash passed to each `Simple`:

1. Root `Simple` gets empty constraints
2. For each intersection cell, `get_clusters(cell)` extracts `{column_index → rank}`
3. Child `Simple` receives these constraints
4. `Simple.cluster_row_ids` calls `value.constrain(constraints)` on reference cells
5. `ShowAll` expansion only enumerates `each_defined_fulfilling` (constrained subset)

For non-header cells, Hierarchic lazily constrains references in `[]?`:
```crystal
constraints = get_clusters(index).map { |col, vr| {col, vr[1]} }
value.constrain(constraints)
@constrained_references[index] = value  # cached per frame
```

## Clusters vs Constraints

From `doc/cluster.md`, these are distinct concepts:

|              | Clusters | Constraints |
|-------------|----------|-------------|
| **Relation to ReferenceCell** | Independent | Requires RC |
| **Used at** | `hyperplane_move` (drag-and-drop) | `ShowAll` clustering, dropdown prep |
| **Headers used** | All headers ≤ current level | Predecessor headers < current level (topological) |
| **Need from headers** | column index + value | column index + rank |

## Drag-and-Drop — hyperplane_move

`hyperplane_move(dimension, from, to)` reassigns the source cell's records to the
target cell's clusters:

1. Get `clusters` from the target index (all `{column → {value, rank}}` pairs)
2. Merge with source clusters (target takes priority on conflict)
3. Get the underlying `Reduced` table for the source cell
4. Call `cluster_according_to(table, clusters)` — assigns each record in the table
   to the target's cluster values via `multiassign_begin/end`

This handles both:
- Moving between intersection cells (within same level)
- Moving between header cells (re-clustering)

## Insert — hyperplane_add

`hyperplane_add(0, index)` behaviour depends on cell type:

| Cell state | Assignability | Action |
|-----------|---------------|--------|
| Out of bounds | `nil` | Global `@parent.hyperplane_add(0)` — adds record to the underlying table |
| Has content | `Directly` | **Clone** or **create sibling** (see below) |
| Empty | `Indirectly` | Create new record, assign target clusters |
| Dead area | `Not` | Raise `ConditionsNotMet` |
| Drilldown | `Drilldown` | Raise `ConditionsNotMet` |

### Directly assignable cells

**Header cell** — creates a sibling:
- If ReferenceCell: picks first unused `each_defined_fulfilling` value, or creates new reference tag
- If Rank: creates new rank (handled by VT)
- If BaseCell: creates `~new_value_001` style unique value

**Non-header cell** — clones all values:
- Creates new record in `@parent`
- Copies all cell values from the source row (not just clusters)

This matches the semantics from `doc/cluster.md`:
- `hyperplane_move` = **move** (only target clusters applied)
- `hyperplane_add` on non-empty intersection = **copy** (all source cells copied)

## Aggregate Display

At the leaves, `Aggregate(T)` in `src/table/pivot.cr` shows:
- **Single record**: the actual cell value (editable)
- **Multiple records**: `#count` or `#count/Σsum` (if numeric; sum cached in `@sums_cache`)
- **No aggregate columns**: `#count` of the full sub-table

Column classification is stripped before aggregation: `create_reduced_aggregate` removes
all row/column header columns via `Reduced`, leaving only aggregate columns.

## Assignability

`get_assignability(index)` determines what operations are valid on a cell:

| Assignability | Meaning | Operations |
|--------------|---------|------------|
| `Directly` | Cell has exactly one record, or is a header | `[]=`, `hyperplane_add` (clone/sibling) |
| `Indirectly` | Empty intersection (no records yet) | `hyperplane_add` (create new) |
| `Drilldown` | Multiple records, not a header | Read-only aggregate display |
| `Not` | NilDeadArea or NilRecord | No operations |

## Scroll Ordering

`get_scrollorder` returns `{vertical, horizontal}` arrays of priorities, computed by
`calc_projections`. Headers at outer levels have higher priority (scroll out last),
inner levels scroll out first. This enables the "sticky header" effect in the GUI:
outer headers remain visible while scrolling through inner content.

## Concrete Example

Given the demo dataset with fieldlist:
```
Level 0 Row: Country    Level 0 Col: Project
Level 1 Row: City       Aggregate: Allocation
```

The resulting grid:

```
                   Project A        Project B
                 +-------+--------+-------+--------+
                 | Alan  | #2/Σ150| Denny | #1/Σ75 |
   USA    Boston +-------+--------+-------+--------+
                 | Alan  |  100   |       |        |
                 | Denny |   50   | Denny |   75   |
                 +-------+--------+-------+--------+
   Germany Munich| Hans  | #1/Σ120|       | #0     |
                 +-------+--------+-------+--------+
                 | Hans  |  120   |       |        |
                 +-------+--------+-------+--------+
```

The tree structure:
```
Simple(L0): Country×Project
  ├─ {USA,ProjA}: Simple(L1): City×∅
  │   └─ {Boston,∅}: Aggregate [Alan:100, Denny:50]
  ├─ {USA,ProjB}: Simple(L1): City×∅
  │   └─ {Boston,∅}: Aggregate [Denny:75]
  ├─ {Germany,ProjA}: Simple(L1): City×∅
  │   └─ {Munich,∅}: Aggregate [Hans:120]
  └─ {Germany,ProjB}: (empty — sparse)
```

## See Also

- [06-pivot-simple](06-pivot-simple.md) — the Simple pivot this builds on
- [05-fieldlist](05-fieldlist.md) — how levels and classes drive the nesting
- [02-references](02-references.md) — constrained reference tags
- [08-shapes](08-shapes.md) — how Hierarchic connects to the GUI
- `src/table/pivot.cr` — full implementation
- `doc/cluster.md` — clusters vs constraints, move vs copy semantics
- `doc/hyperplanes.md` — hyperplane behaviour for Hierarchic
