# Embrace — The Big Picture

Embrace is a multi-perspective pivot table application for relational data, written in Crystal.
Instead of maintaining multiple redundant spreadsheets, embrace stores one normalized database
and lets you create unlimited "Shapes" — editable perspectives on the same underlying data.

## Core Principle

> Freedom from redundancy, ductile data manipulation, multi-perspective editing with time-travel.

The same data can be viewed simultaneously as a flat table, a pivoted allocation matrix,
a Kanban board, a floor plan, or any other 2D arrangement — all live, all editable.

## The Data Pipeline

Every Shape in embrace is the result of a pipeline that transforms raw relational data
into a rendered 2D grid:

```
 Persistency          raw tables, fields, records, commits
      |                (src/persistency.cr)
      v
 Configurator         select tables & fields, follow references
      |                (src/virtualtable.cr — Configurator)
      v
 VirtualTable         composite view joining multiple tables
      |                (src/virtualtable.cr — VirtualTable)
      v
 Fieldlist            assign fields to Row / Column / Aggregate / Unused
      |                (src/fieldlist.cr)
      v
 Pivot                cluster records by header values, aggregate
      |                (src/table/pivot.cr — Simple, Hierarchic)
      v
 Matrix               rendered 2D grid with sticky headers
                       (GUI: SimpleMatrixAdapter in src/gui/shape.cr)
```

Each stage is lazy and version-aware: changes at any level propagate automatically.

## Key Concepts

| Concept | Meaning | See |
|---------|---------|-----|
| **Table** | A collection of fields and records (like a DB table) | [01-tables-fields-records](01-tables-fields-records.md) |
| **Field** | A named column in a table (untyped, except references) | [01-tables-fields-records](01-tables-fields-records.md) |
| **Record** | An unnamed row in a table | [01-tables-fields-records](01-tables-fields-records.md) |
| **Reference** | A typed foreign key connecting two tables | [02-references](02-references.md) |
| **Configurator** | Tree structure selecting which tables/fields to include | [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md) |
| **VirtualTable** | Composite view joining data from related tables | [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md) |
| **Fieldlist** | Configuration: which fields become rows, columns, aggregates | [05-fieldlist](05-fieldlist.md) |
| **Pivot** | Clustering engine that groups records into a 2D grid | [06-pivot-simple](06-pivot-simple.md), [07-pivot-hierarchic](07-pivot-hierarchic.md) |
| **Shape** | A complete perspective: configurator + fieldlist + pivot + context | [08-shapes](08-shapes.md) |
| **Commit** | A sealed snapshot of all data at a point in time | [09-history](09-history.md) |


## The Demo Dataset

Most examples in these docs use the "demo" dataset that embrace creates via
File > New demo (see `do_newfile_demo` in `src/gui/embrace.cr`):

```
 Persons          Cities           Times            Projects
 +---------+      +----------+     +---------+      +-----------+
 | Person  |      | City     |     | Time    |      | Project   |
 | City  --|----->| Country  |     +---------+      +-----------+
 | Time  --|----->|          |     Present
 | Project-|--+   Boston     |     Past
 | Alloc   |  |   Munich     |    Future
 +---------+  |   +----------+
              |
              +-->+-----------+
                  | Project   |
                  +-----------+
```

Tables are connected through **reference fields** (arrows). This structure lets you
view the same allocation data from any angle: person/project, city/project, etc.

## What's Persistent vs. Volatile

| Persistent (saved to .embrace file) | Volatile (rebuilt on load) |
|--------------------------------------|--------------------------|
| Tables, fields, records | Shape configurations |
| Cell values at every commit | Configurator tree state |
| Commit history (DAG) | Fieldlist assignments |
| Reference relationships | Pivot caches |
| Field/table names and ordering | GUI layout |

Shape configurations are volatile — they are part of the GUI state, not the database.

## See Also

- [01-tables-fields-records](01-tables-fields-records.md) — next: the basic data model
- `src/persistency.cr` — the core data layer
- `src/gui/embrace.cr` — the main application class
