# Shapes — Multiple Perspectives

A Shape is a complete, standalone perspective on the data. Each Shape combines a
data context, a schema configuration, a fieldlist, and a pivot table into an editable
perspective. Multiple Shapes can exist simultaneously, each showing the same underlying data
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
| `cell_read(index)` | Returns cell value for display. **Not a pure accessor** — it records every cell it touches in `@current_values` and arms the change-highlight deadlines, so a bulk walk must not use it (`to_tsv` reads `@matrix_rc` directly). Its `String` bridge overload's return is consumed only for change detection, which is why it keeps `to_s` rather than the display mapper: the comparison key carries a reference cell's `rank`, and dropping that would silently stop rank-only changes from highlighting. |
| `display_string(value)` | The text the user sees, as a pure mapper over an already-read value (a Bool renders as the `'true` literal so it survives a clipboard round trip) |
| `to_tsv` | The whole rendered rectangle as TSV — see [10-file-format](10-file-format.md) |
| `cell_natural_size(index)` | The width, height and line count the cell's content wants, for auto-sizing. Reads `@matrix_rc` **directly** — going through `cell_read` would mark the whole grid "seen" and swallow the next edit's highlight, the same trap that row documents |
| `cell_assign(index, value)` | Writes cell value back to persistency. **Not a pure write**: it also records which assignability branch it took and whether it mutated anything, which the write bridge reads afterwards to decide how to announce |
| `cell_insert(index)` | `hyperplane_add(0, index)` — inserts record |
| `cell_delete(index)` | `hyperplane_remove(0, index)` — removes record |
| `cell_move(from, to)` | `hyperplane_move(0, from, to)` — drag-and-drop |
| `cell_get_header_info(index)` | Returns `{is_row?, level}` or nil |
| `cell_get_bounding_box(index)` | Merged cell boundaries for rendering |
| `get_scrollorder` | Priorities for sticky header scrolling |
| `cell_paint(index)` | Builds the widget: ComboBox for references, TextInput for data |

The adapter also handles assignability checks — it queries
`Hierarchic.get_assignability(index)` to determine whether a cell is editable (and, since
multi-line values, whether its editor may author a line break — the writable cases, which is
why an empty cell can be given one),
insertable, or read-only. A structurally empty cell (a non-assignable dead
pivot intersection) is rendered with a dimmed `cell.empty` background, so an
area where no value can go stays visually distinct from a live cell.

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

`ShapeState#update`'s change gate sums **persistency + context + the fieldlist's raw
memory version**. The fieldlist term is essential: a Field-list drop writes only the
fieldlist's own memory table (class/level/rank), not persistency, yet it changes the
pivot's structure. The gate is what fires `matrix_adapter.invalidate_all!` — the push
signal that makes the VirtualMatrix clear its cached content buffer — for every change
*except* a single-cell write, which announces for itself (see below). Without it, a
structure change that keeps the same grid dimensions (e.g. merged cells splitting after
a field move) leaves ghost pixels in the vacated separator bands: crymbleui's reconcile
clear is keyed on adapter-instance identity, which embrace holds stable (one adapter
reused across rebuilds), so it never auto-clears here — the push is required. The
regression is guarded by `spec/gui/fieldlist_move_stale_separator_spec.cr`. It is deliberately the raw memory
version, not `Fieldlist#version`, which would pull the VirtualTable's update at gate
time — before the gate body has repaired the context mid-history-navigation.

**A single-cell write announces for itself.** Editing one cell says so precisely —
`invalidate_cell!` instead of the whole-grid push — so the matrix repaints that cell rather
than clearing all five of its layers. The write suppresses only *its own* gate announcement;
every other Shape showing the same table still gets the full push, which is how they learn of
the edit. Five things send a write back to the whole-grid push: it created a record; it landed
on a header (which can re-group rows); it happened in a Shape that pulls fields in **across a
reference**; the write landed somewhere other than where it was aimed; or the row/column order
moved — which is how a plain data edit still gets a full push when, say, renaming a value
re-sorts the pivot around it. That last one is the interesting case: when a referenced table's field is shown,
one stored record paints into several rows at once — Alan and Melanie both showing Boston's
country — so repainting a single cell would leave its twins showing the old value. Such a Shape
therefore keeps the whole-grid push on every edit. Nothing about this is visible in the
interface; it costs a little more work per edit in those Shapes and nothing anywhere else.
Guarded by `spec/gui/announce_precision_spec.cr`.

## Shape Operations

Available from the GUI (`src/gui/embrace.cr`):

| Operation | Effect |
|-----------|--------|
| **Duplicate Shape** | Clones ShapeState with same config (new Configurator + Fieldlist copies) |
| **Close Shape** | Removes the Shape from the GUI |
| **Maximize** | Toggles full-window mode for one Shape |
| **Auto-size perspective cells** | View menu, per Shape. Sizes columns and rows to their content; while it is on they cannot be dragged. Off by default, and not saved with the document. |
| **Transpose** | Swaps row and column headers (diagonal mirror on fieldlist) |

## Data vs. Perspective Changes

| Changes data (visible to all Shapes) | Changes perspective (this Shape only) |
|---------------------------------------|--------------------------------------|
| Editing a cell value | Expanding/collapsing VHTree nodes |
| Adding/removing records or fields | Changing fieldlist Row/Col/Agg/Unused |
| Drag-and-drop (reassigns clusters) | Changing fieldlist levels |
| Factor-out / factor-in | Changing sort direction |
| Import table | Duplicating or closing Shapes |

## When a Cell Cannot Show Its Whole Value

Unless **Auto-size perspective cells** is on (see below), a column is rarely as wide as its
widest value, so cells cut their text — and even with it on, the row-header column keeps its own
width. Two things now make
that visible rather than silent.

**A cut cell is marked.** Where the text runs past the space it has, a small vertical band is
drawn along that edge, behind the glyphs. It is passive — nothing to click, nothing that
blinks — and it appears in text cells, reference cells and list rows. Its purpose is narrow
but important: without it, `Ashcroft` and `Ashcroft-Winterbourne` look identical in a narrow
column, and nothing tells you which one you are reading.

The band **adapts its lightness to the cell it sits on**: dark on a light cell, light on a dark
one. So on a diff-highlighted cell it flips polarity and appears light, while the cell beside
it shows a dark band. That is deliberate — a fixed colour cannot stay legible across the
backgrounds cells actually carry (diff highlighting, empty cells, constraint colours, the
header shades per pivot level), and a marker you cannot see is worse than none.

**Where bands exist, and where their absence proves nothing.** Bands appear in text cells,
collapsed reference cells and dropdown rows. They do NOT appear on the field list, the
shape/branch tree, or the `c1`/`c2` ruler strip — text there can still be cut with no band to
say so. A multi-select summary signals the same fact with an ellipsis (`…`) instead. So read a
band as "there is more here", never read its absence as "this is the whole value".

Bands mark cuts on both axes, and always as a full bar along the cut edge: down the side when
a line runs past the cell's width, and across the bottom or top when a multi-line value has
lines the row is too short to show. A vertical bar stays lit until the line it is about is
*completely* visible — it does not go out the moment that line starts to appear — and every
hidden line counts, upwards and downwards alike, empty ones included: a break you typed is part
of the value, so a value cut off after its first lines is marked even when what follows is
blank. A value of one single line is never marked downwards, whatever the row height. A referenced (dropdown) cell holding a multi-line
value shows its first line with no *downward* band — reference cells clip to their own
height — though it is still marked sideways if that line is too wide.

**Reading a marked cell.** Press `Enter` on it: the cell opens for editing and the view scrolls
to the end of the value, so the tail becomes readable. Note that this *is* an edit session —
`Escape` leaves it unchanged. Clicking a cell does not reveal it, and on a drill-down cell
`Enter` opens a new Shape instead. Widening the column always works — unless **Auto-size perspective cells** is on, which takes the
drag away from the columns it sizes; there, read a cut value with `Enter` (as just described), or
switch the toggle off, which gives those handles back so you can widen the column past what the
mode fits. The row-header column keeps its handle throughout, because the mode never sizes it.

## Multi-line cell values

A cell value can hold hard line breaks. Press **`Alt`+`Enter`** (as in Excel) or
**`Ctrl`+`Enter`** (as in Calc) while a cell is selected: the cell opens for editing and a
break is inserted at the cursor. Plain `Enter` still accepts the value and leaves the cell, so
neither chord collides with committing. Nothing in the interface announces these keys — this
paragraph is where they are documented.

Breaks also arrive without being typed: pasting a table from a spreadsheet keeps them, and an
`.xlsx` cell wrapped with `Alt`+`Enter` keeps them through import. However a multi-line cell
copied from a spreadsheet and pasted *into an open editor* arrives with the quotes the
spreadsheet wrote around it, because that is how spreadsheets encode a break on the clipboard;
paste a whole table instead to have them decoded.

**Reading one back.** A row shows as many lines as it has height for, and marks the rest —
see the band rules above. Drag the row taller on the row ruler to read the whole value — or switch on **Auto-size
perspective cells**, which grows the row for you to fit the whole value. While that is on the
row ruler cannot be dragged. Note
that row heights are **not saved**: they last for the session (and survive duplicating a
Shape), but reopening the document restores the default height. Unless **Auto-size perspective cells** is on, rows do not grow to fit a
value on their own, so while you are typing past the first visible line the view scrolls with
the cursor rather than the row expanding.

## Auto-size perspective cells

**Shape → View → Auto-size perspective cells** hands the sizing over to the content. Every
column becomes as wide as the widest value in it, and a row grows when its value has line breaks.
Row headers and header rows follow one extra rule — see below. It is per Shape and off by default; duplicating a Shape keeps it, and it is not saved
with the document, so reopening starts with it off again.

While it is on, **columns and rows cannot be dragged** — a drag would only be overwritten the
next time anything is measured, so the handles are withdrawn rather than left to lie. Switch the
toggle off and the sizes it measured stay: nothing on screen moves, the handles come back, and you
drag on from the fitted layout. Switching off means "I will take it from here", so the widths you
had dragged before turning it on are not kept — the fitted ones replace them.

**A tall row makes the perspective scroll, not the Shape grow.** A value that needs more room than
the panel has gets its room, and the panel scrolls to the rest — the Shape does not stretch itself
to fit one cell. With the drag handles withdrawn from the sized lines, resizing the Shape's panel
(or **Maximize**) is how you see more of the grid at once.

**A cell you are typing into grows as you type.** That is the point of the mode: the value stays
readable while you write it, instead of scrolling away past the right edge. It only grows
mid-edit — the shrink, if the value ends up shorter, happens when you commit.

**Limits, and what they look like.** There is no ceiling on how wide a column or how tall a row
the mode will make: a value gets the room it needs and you scroll to the rest of the sheet. It
does not shrink a column past its own `c1`/`c2` ruler label, though — a cut label carries no
marker of its own, so that would be a silent loss. The one upper stop is technical: a cell
cannot be drawn beyond about 16000 pixels, so a value longer than that gets a cell that wide and
the ordinary "content is cut" marker for the remainder. The mode fits what it can, and says so
where it cannot.

**Empty lines count as lines.** A row grows for every break in the value, trailing ones
included — you typed them, so they are part of what the mode fits.

**Three things it deliberately does not size.** A cell that *spans* several columns or rows — a
grouped header — does not vote on any one of them; otherwise a header covering eight columns
would dump its whole width into the first, so a wide group header may still show its own cut
marker. A referenced (dropdown) cell contributes its width but not its line count: a multi-line
referenced value keeps showing its first line, exactly as it does without the mode. And a Bool cell
is a checkbox, which has no text to measure, so it votes no width at all.

**Row headers and header rows shrink but never grow.** They stay put while you scroll, so
anything the mode pushed past the panel's edge could never be reached: not by scrolling, because
they do not scroll, and not by the cut marker, which asks whether the *cell* fits its text and would
see nothing wrong. Narrowing one hides nothing, so the mode compacts them like any other line — it
simply never widens one. A long record name is therefore cut there, and is read the way any cut
value is: the band lights and `Enter` opens the value and scrolls to the rest of it. The mode does
widen a row-header column that sits too narrow to show its own `c1`/`c2` label, because that label
is drawn in the ruler strip, which paints no cut marker of its own.

A field *name* is shown on one line wherever it is displayed, even if the stored name
contains a break — which
can happen when an `.xlsx` header cell was wrapped. The stored name is left as it is, and the
rename box deliberately shows it raw so that renaming round-trips what is actually there.

**What changed for existing sheets.** Cell text now stops at its own box instead of running a
few pixels into the cell's padding and border. At the default column width that is about 5px
of ~92 — roughly one character in thirteen — but the loss is a fixed 5px against a shrinking
box, so it is ~16% at a two-frame column and ~42% at the narrowest. Values that just fitted
before may therefore show a band now. That is the marker telling the truth about a cut that
was already happening; it was simply drawn over the cell's own border before.

## See Also

- [03-configurator-and-virtual-table](03-configurator-and-virtual-table.md) — the Configurator tree
- [05-fieldlist](05-fieldlist.md) — the Fieldlist configuration
- [07-pivot-hierarchic](07-pivot-hierarchic.md) — the Hierarchic pivot
- [09-history](09-history.md) — how each Shape can view different commits
- `src/gui/shape.cr` — ShapeState and all three adapters
- `src/gui/embrace.cr` — EmbraceApp integrating Shapes
