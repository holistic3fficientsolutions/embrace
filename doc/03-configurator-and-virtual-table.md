# Configurator and VirtualTable — Compositing Data

The Configurator and VirtualTable work together to compose data from multiple related
tables into a single virtual view. Both are defined in `src/virtualtable.cr`.

## The Configurator Tree

`Configurator(T,U)` maintains a rooted tree that represents the schema of related tables
and fields. The tree structure alternates between TableLID and FieldLID nodes at each level:

```
 Level 0: TableLID      "Allocations"
 Level 1: FieldLID        Person, City, Time, Project, Alloc, [ShowAll], [Rank]
 Level 2: TableLID          "Persons" (via Person ref)    "Cities" (via City ref)
 Level 3: FieldLID            Name, Age, ...                City, Country, ...
 Level 4: TableLID              ...                           "Countries" (via Country ref)
```

The tree type is `RootedTree(FieldLID|PseudoFields, FieldLID|PseudoFields)` — both
node values and edge labels are either FieldLIDs or pseudo-fields.

### Pseudo-Fields

Two special pseudo-fields appear at every expanded table level:

```crystal
enum PseudoFields
    RecordLID   # only used by VirtualTable
    ShowAll     # controls whether to show all reference tags
    Rank        # the auto-generated line-number field
end
```

### Node States

Each tree node has three boolean states, stored externally in `WeakKeyMap`s
(not in the tree nodes themselves, to avoid issues with mutable records):

| State | Stored in | Meaning |
|-------|-----------|---------|
| `is_expanded` | `@is_expanded` | Whether the node's children are visible |
| `is_selected` | `@is_selected` | Whether the field is active in the view (`Bool\|SomeStruct` for tristate) |
| `is_used` | `@is_used` | Whether the node or any descendant is selected (computed cache) |

### Display Names

Each node gets a `{prefix, main, postfix}` triple stored in `@display_name`:

- **prefix**: `◄` (outgoing reference), `►` (incoming reference), or space
- **main**: field/table name from the `Names` meta-field
- **postfix**: `◄in,►out +/-` showing reference counts and expand/collapse state

### Tree Updates

The Configurator rebuilds its tree lazily when `@persistency.meta_version` changes.
`update` calls `update_table` and `update_field` recursively, using a stash of
previous tree nodes (keyed by `{parent, edge}`) to preserve `is_expanded` and
`is_selected` states across rebuilds.

The `update_caches` method computes `is_used` bottom-up via `dfs_up`: a node is
"used" if it or any descendant is selected.

### Selection Logic

`toggle_select(node)` handles cascading selection:
- Selecting a table node selects all its field children
- Deselecting a table deselects all children
- If some (but not all) children are selected, the table shows `Some` (tristate)
- `dependable_select` propagates changes upward to parent tables

### Expanding and Collapsing

`toggle_expand(node)` shows or hides children:
- Expanding a table reveals its fields and pseudo-fields (ShowAll, Rank)
- Expanding a field reveals its referenced tables (both outgoing and incoming)
- Collapsing a table clears all selection states of its children

## VirtualTable

`VirtualTable(T,U)` is a lazy table (`Table::Lazy::Raw::Base(U)`) that composites data
from the persistency layer based on the Configurator's selections.

### Row Semantics

A VirtualTable row may span records from multiple physical tables. For example, if
Persons references Cities, a single VT row contains both the Persons record and the
corresponding Cities record.

When a reference has no value (rank 0), the Cities portion shows `NilRecord` —
indicating "there is no record here" (distinct from `nil` which means "cell is undefined").

### Column Semantics

Each VT column corresponds to a field in a specific table. The column ordering is
determined by a depth-first traversal of the Configurator tree, collecting only
selected fields. Column IDs are managed by `IDContainer` (`@user_id_mgr`).

### Multi-Assignment

When editing a cell in a VT row that spans multiple tables, assignments must be
executed in the correct order. For example, if Persons.City references Cities and
Cities.Country references Countries, changing the city in a row must update the
city reference before the country can be resolved.

The protocol:

```crystal
vt.multiassign_begin
  vt[index1] = value1   # queued, not applied yet
  vt[index2] = value2   # queued
vt.multiassign_end       # applies in topological order
```

`multiassign_end` uses topological sorting (via `graphalgos.cr`) to determine the
correct execution order based on the table reference chain. Assignments are applied
only until the chain is broken (i.e., consecutive referenced tables).

### ShowAll

The `ShowAll` pseudo-field controls how reference fields behave:

- **ShowAll = true**: All reference tags appear in the VT, including those not
  currently referenced by any record. This is useful for floor plans or Kanban boards
  where you want to see empty slots.
- **ShowAll = false** (default): Only actually referenced values appear.

### Map Cell and Map Hyperplane

As a `Table::Lazy::Raw::Base(U)`, VirtualTable implements the core lazy table interface:

- `map_cell(index)` — resolves a VT cell index to the underlying `(field_lid, record_lid)`
  pair in the persistency layer, returning a `{parent_table, mapped_index}` pair
- `map_hyperplane(dimension, index)` — maps row/column hyperplane operations back to
  the persistency layer (add/remove record, add/remove field)

### ReferenceCell Construction

When `VirtualTable#[]?` encounters a reference field, it constructs a `ReferenceCell(U)`
with:
- All available target values
- A `ReferenceModifier` that writes back to the persistency layer
- A `ReferenceConstrainer` that computes valid ranks given constraints

The VT itself does **not** store constraints — constraints are applied externally
(by `Pivot::Hierarchic` or the GUI layer).

## See Also

- [01-tables-fields-records](01-tables-fields-records.md) — the underlying data model
- [02-references](02-references.md) — reference fields that create the tree structure
- [04-table-classes](04-table-classes.md) — the Table abstraction VirtualTable inherits from
- [05-fieldlist](05-fieldlist.md) — next: how VT columns become row/column/aggregate headers
- `src/virtualtable.cr` — full implementation (~1000 lines)
- `src/tree.cr` — `RootedTree` data structure
- `src/weakkeymap.cr` — `WeakKeyMap` for node states
- `src/graphalgos.cr` — topological sort for multi-assignment
