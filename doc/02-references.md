# References — Connecting Tables

Reference fields are embrace's mechanism for creating typed relationships between tables.
They act as foreign keys: a reference field in one table points to records in another table.

## What is a Reference Field?

A reference field is a field whose `RefersTo` meta-field points to a target field in another table.
The reference field stores `RecordLID` values that identify records in the target table.

```
 Table "Persons"                     Table "Cities"
 +------+---------+--------+        +------+----------+---------+
 | Rank | Person  | City   |        | Rank | City     | Country |
 +------+---------+--------+        +------+----------+---------+
 |    1 | Alan    | *------|-------->|    1 | Boston   | USA     |
 |    2 | Denny   | *------|-------->|    1 | Boston   | USA     |
 |    3 | Hans    | *------|-------->|    2 | Munich   | Germany |
 +------+---------+--------+        +------+----------+---------+

 Persons.City (FieldLID=5) --RefersTo--> Cities.City (FieldLID=8)
```

In the persistency layer (`src/persistency.cr`):

- `RefersTo` meta-field: `set_value(MetaFieldLIDs::RefersTo, source_field_lid, target_field_lid)`
- Creating: `add_field(table_lid, name, refers_to_field_lid)` in `Generic::Basics`
- Querying: `get_outward_reference(field_lid)` returns the target FieldLID (or nil)
- Reverse: `get_inward_references(field_lid)` returns all fields referencing this one

References cannot point to other references (enforced by assert). This avoids
indirection chains and ensures the displayed value is always user data, not a RecordLID.

## Terminology (from glossary)

These terms are used consistently throughout the codebase:

| Term | Meaning |
|------|---------|
| **reference** (referencing field) | A typed field that stores RecordLIDs pointing to another table |
| **referenced field** | The target field; any ordinary field can be referenced |
| **reference tag** | The concrete value of the referenced field for one record |
| **reference tags** | The full set of values of the referenced field |
| **constrained reference tags** | The subset fulfilling the current hierarchical context |

## ReferenceCell(T)

`ReferenceCell(T)` in `src/referencecell.cr` is the runtime representation of a reference
value. It wraps a rank-based dropdown for picking which target record to point to.

Key properties:
- `rank : Int32` — which target record (0 = "(no reference)", 1..N = actual records)
- `values : Array(T)` — all available target values
- `value : T` — the currently pointed-to display value (`values[rank]`)
- `showall : Bool` — whether to show all reference tags or only defined ones

### Constraint-Aware Iteration

References can be **constrained** by hierarchical context. For example, if a pivot
groups by Country at level 0 and by City at level 1, only cities belonging to the
current country are valid.

```crystal
rc.constrain(constraints)       # set context constraints
rc.each_defined_fulfilling { }  # green items: valid for this context
rc.each_defined_breaking { }    # red items: violate constraints + "(no reference)"
```

The `constrainer` interface (`Interface::ReferenceConstrainer`) is implemented by
`VirtualTable` to compute which ranks are valid given the current header context.
See [07-pivot-hierarchic](07-pivot-hierarchic.md) for how constraints propagate.

## Creating References

### Top-Down: Factor Out

Factor-out extracts repeated values from a field into a new table and replaces
the original field with a reference. This is the approach shown in the primer:

1. Start with flat table: Persons has Person, City, Country
2. Factor out City → creates new table "Cities" with field "City"
3. Original City field becomes a reference to Cities.City
4. Duplicate city values are deduplicated in the new table

Implementation: `factor_out_reference` in `Generic::Refactoring` (`src/persistency.cr`).

### Bottom-Up: Add Reference Field

Alternatively, create the target table first, then add a reference field
to the source table:

```crystal
city_field_lid = persistency.add_field(persons_table, "City", cities_city_field_lid)
```

### Factor In (Reverse)

Factor-in absorbs a referenced table back, converting the reference field to a
plain value field with copies of the referenced values. This undoes a factor-out.

## What Happens on Delete

Embrace does not physically delete data (see [01-tables-fields-records](01-tables-fields-records.md)).
When a referenced record, field, or table is "removed":

- The reference field still stores the RecordLID
- The value can potentially be recovered (un-delete)
- Orphaned references map to rank 0 ("(no reference)") in the VirtualTable

## Self-References

A table can reference itself. Example from tutorial 11: a "Women" table with a
"Mother" reference field pointing to the same table's "Name" field. This creates
a tree structure within a single table.

## See Also

- [01-tables-fields-records](01-tables-fields-records.md) — the basic data model
- [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md) — how references shape the configurator tree
- [07-pivot-hierarchic](07-pivot-hierarchic.md) — constrained reference tags in nested pivots
- `src/persistency.cr` — `RefersTo` meta-field, `factor_out_reference`
- `src/referencecell.cr` — `ReferenceCell(T)` implementation
- `doc/references.md` — internal design notes on ReferenceCell
