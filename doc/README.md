# Embrace Inner Workings — Concept Documentation

Progressive documentation of embrace's architecture, from basic data model
through hierarchic pivot tables. Each document builds on the previous.

## Documents

| # | Document | Topic |
|---|----------|-------|
| 0 | [00-overview](00-overview.md) | The big picture: pipeline, terminology, demo dataset |
| 1 | [01-tables-fields-records](01-tables-fields-records.md) | Basic data model: tables, fields, records, LIDs, sparse 3D storage |
| 2 | [02-references](02-references.md) | Reference fields: foreign keys, ReferenceCell, constraints |
| 3 | [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md) | Schema tree and composite data views |
| 4 | [04-table-classes](04-table-classes.md) | The `src/table/` class hierarchy: Base, Lazy, Raw, Sparse |
| 5 | [05-fieldlist](05-fieldlist.md) | Row/Column/Aggregate/Unused assignment and mirror operations |
| 6 | [06-pivot-simple](06-pivot-simple.md) | Single-level pivot: clustering, headers, intersections |
| 7 | [07-pivot-hierarchic](07-pivot-hierarchic.md) | Multi-level nested pivot: constraints, drag-and-drop, insert |
| 8 | [08-shapes](08-shapes.md) | Shapes: multiple perspectives, adapters, data vs. perspective |
| 9 | [09-history](09-history.md) | Commits, branching, time travel |
| 10 | [10-file-format](10-file-format.md) | .embrace format, XLSX import/export |
