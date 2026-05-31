# Shapes — Multiple Perspectives

A Shape is a complete, standalone perspective on the data. Each Shape combines a
data context, a schema configuration, a fieldlist, and a pivot table into an editable
view. Multiple Shapes can exist simultaneously, each showing the same underlying data
from a different angle.

## ShapeState

`ShapeState` in `src/gui/shape.cr` holds all the state for one perspective:

| Field | Type | Purpose |
|-------|------|---------|
| `@persistency` | `Persistency::Default` | The shared data backend |
| `@context` | `Persistency::Context` | Which commit version to view |
| `@configurator` | `Configurator(Cell, BaseCell)` | Schema tree (which tables/fields) |
| `@fieldlist` | `Fieldlist(FieldlistCell, Cell)` | Row/Col/Agg assignment |
| `@vt` | `VirtualTable(Cell, BaseCell)` | Composite data view |
| `@matrix_userdata_rc` | `Pivot::Hierarchic(...)` | The rendered 2D pivot |

All Shapes share the same `@persistency` instance — editing data in one Shape
changes the underlying database visible to all Shapes. However, each Shape has
its own `@context`, `@configurator`, and `@fieldlist`, so perspectives are independent.

**Key principle**: changing perspective does NOT change data. Only cell edits,
record/field additions, and structural operations (factor-out, etc.) modify data.

## The Three Adapters

Shapes bridge the data model to CrymbleUI widgets through three adapter interfaces:

### SimpleMatrixAdapter

`src/gui/shape.cr` — wraps `Pivot::Hierarchic` for the VirtualMatrix grid widget.

| Method | Purpose |
|--------|---------|
| `cell_read(index)` | Returns cell value for display |
| `cell_assign(index, value)` | Writes cell value back to persistency |
| `cell_insert(index)` | `hyperplane_add(0, index)` — inserts record |
| `cell_delete(index)` | `hyperplane_remove(0, index)` — removes record |
| `cell_move(from, to)` | `hyperplane_move(0, from, to)` — drag-and-drop |
| `cell_get_header_info(index)` | Returns `{is_row?, level}` or nil |
| `cell_get_bounding_box(index)` | Merged cell boundaries for rendering |
| `get_scrollorder` | Priorities for sticky header scrolling |
| `cell_paint(index)` | Builds the widget: ComboBox for references, TextInput for data |

The adapter also handles assignability checks — it queries
`Hierarchic.get_assignability(index)` to determine whether a cell is editable,
insertable, or read-only.

### SimpleVHTreeAdapter

`src/gui/shape.cr` — wraps Configurator nodes for the VHTree layout widget.

| Method | Purpose |
|--------|---------|
| `get_display_texts` | `{prefix, main, postfix}` for node labels |
| `is_selected?` / `toggle_select` | Field selection state |
| `is_expandable?` / `toggle_expand` | Node expansion |
| `get_reference` | Cross-reference arrows between nodes |
| `drag` / `move` | Field drag-and-drop between tables |
| `is_table?` / `is_pseudo_field?` | Node type queries |

Drag-and-drop on the VHTree supports three move types (computed by `calc_move`):
- **Internal**: reorder fields within the same table
- **Inwards**: promote a field from parent to child table
- **Outwards**: demote a field from child to parent table

### FieldlistAdapter

`src/gui/shape.cr` — wraps the Fieldlist table for the fieldlist grid widget.

| Method | Purpose |
|--------|---------|
| `cell_read(index)` | Read fieldlist cell (Class, Level, Sort, Name) |
| `cell_assign(index, value)` | Change field classification |
| `version` | Change tracking for GUI invalidation |
| `size` | Fieldlist dimensions |

## Shape Lifecycle

1. **Create**: User selects a table via menu or TablePicker
2. **Initialize**: `ShapeState` creates Configurator, VirtualTable, Fieldlist, Hierarchic
3. **Configure**: User expands/selects fields in VHTree, assigns Row/Col/Agg in Fieldlist
4. **View/Edit**: Matrix renders the pivot; user edits cells, adds records, drags rows
5. **Update**: Changes propagate: Persistency → VT → Fieldlist → Hierarchic → Matrix
   (all lazy, driven by `version` checks)

## Shape Operations

Available from the GUI (`src/gui/embrace.cr`):

| Operation | Effect |
|-----------|--------|
| **Duplicate Shape** | Clones ShapeState with same config (new Configurator + Fieldlist copies) |
| **Close Shape** | Removes the Shape from the GUI |
| **Maximize** | Toggles full-window mode for one Shape |
| **Transpose** | Swaps row and column headers (diagonal mirror on fieldlist) |

## Data vs. Perspective Changes

| Changes data (visible to all Shapes) | Changes perspective (this Shape only) |
|---------------------------------------|--------------------------------------|
| Editing a cell value | Expanding/collapsing VHTree nodes |
| Adding/removing records or fields | Changing fieldlist Row/Col/Agg/Unused |
| Drag-and-drop (reassigns clusters) | Changing fieldlist levels |
| Factor-out / factor-in | Changing sort direction |
| Import table | Duplicating or closing Shapes |

## See Also

- [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md) — the Configurator tree
- [05-fieldlist](05-fieldlist.md) — the Fieldlist configuration
- [07-pivot-hierarchic](07-pivot-hierarchic.md) — the Hierarchic pivot
- [09-history](09-history.md) — how each Shape can view different commits
- `src/gui/shape.cr` — ShapeState and all three adapters
- `src/gui/embrace.cr` — EmbraceApp integrating Shapes
