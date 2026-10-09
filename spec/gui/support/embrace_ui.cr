require "./fixtures"
require "crymble-ui/testing/driver"

# EmbraceUI - embrace's use-case specs in embrace's words, over crymble-ui's Testing::Driver.
#
#     ui = EmbraceUI.tables("People\nName | City\nAnna | Graz")
#     shape = ui.shape("People")
#     ui.right_click ui.configurator_field(shape, "People", "City")
#     ui.context_menu :rename_field
#     ui.dialog(:rename) { |d| d.fill :name, "Town"; d.click :ok }
#     ui.status.should contain "Town"
#
# A spec names things the way the screen shows them; this file turns those names into the logical
# widget ids embrace carries (GUI::Ids, doc/modules/07-app.md) and raises in the same words when
# a name does not resolve. It never reopens EmbraceApp and reads nothing a user could not see
# (except to FIND a grid cell, whose value it then reads from the screen).
#
# NAME PATHS follow the configurator rows as the user sees them, the Shape's table first:
#     "People", "City"                                    a field of the Shape's table
#     "People", "Home", "Cities", "Country"               through an outward reference (Home -> Cities)
#     "People", "Name", inward("Visits", via: "Mother"), "Day"
#                                                         through an inward one: Visits.Mother -> People.Name
# A field has at most one outward reference, so an outward hop needs only its table; a field can
# be referenced by several fields of one table, so an inward hop names the referencing field too.

class EmbraceUI
    # One inward hop of a name path: the referencing table and its field that points back.
    record Inward, table : String, via : String do
        def to_s(io : IO) : Nil
            io << "inward(" << table.inspect << ", via: " << via.inspect << ")"
        end
    end

    alias Segment = String | Inward

    getter ui : CrymbleUI::Testing::Driver
    delegate click, right_click, drag, type, press, keys, text, present?, enabled?, checked?, focused_id,
        find, advance, hover, renderer, to: @ui

    # Drive this app. A spec that built its app with Fixtures keeps its renderer size here, and reads
    # `ui.renderer` - never a second renderer on one app.
    def initialize(@app : EmbraceApp, width : Int32 = 1400, height : Int32 = 1000)
        @ui = CrymbleUI::Testing::Driver.new(@app, width, height)
    end

    def app : EmbraceApp
        @app
    end

    # === Starting points ===

    # The app as it starts: its opening document, nothing unsaved.
    def self.start : EmbraceUI
        new(EmbraceApp.new)
    end

    # An app with these tables (TableReader text; a referenced table comes first), one Shape on
    # `open` - the first table unless named (Fixtures.app).
    def self.tables(text : String, open : String? = nil) : EmbraceUI
        new(Fixtures.app(text, open: open)[0])
    end

    # The open Shape showing this table (the only one - with several, use app.shapes).
    def shape(table : String) : ShapeState
        on = @app.shapes.select { |s| table_of(s) == table }
        return on.first if on.size == 1
        raise ArgumentError.new("#{on.size} Shapes show '#{table}'; open: #{@app.shapes.map(&.display_title).join("; ")}")
    end

    private def table_of(shape : ShapeState) : String?
        shape.table_lid.try { |lid| @app.persistency.display_name(lid) }
    end

    # === Menus, context menus, dialogs ===

    # A main-menu item: menu(:file_load), menu(:view_new_shape) (doc/modules/07-app.md, mi_*).
    def menu(item : Symbol) : Nil
        act("mi_#{item}", "no menu item :#{item}")
    end

    # A Shape's menu item: shape_menu(shape, :commit), (:copy_tsv), (:add_record), ...
    def shape_menu(shape : ShapeState, item : Symbol) : Nil
        act("mi_#{item}_#{shape.id}", "Shape '#{table_of(shape)}' has no menu item :#{item}")
    end

    # The open context menu's entry for this action (rename_field, delete_table, cut_cell, ...).
    def context_menu(action : Symbol) : Nil
        raise ArgumentError.new("no context menu is open (asked for :#{action})") unless @ui.present?("context_menu")
        return @ui.click("ctx_#{action}") if @ui.present?("ctx_#{action}")
        offered = @ui.find("context_menu").find_all { |w| w.id.try(&.starts_with?("ctx_")) || false }
            .compact_map(&.id).map(&.lchop("ctx_"))
        raise ArgumentError.new("the open context menu has no :#{action}; it offers: #{offered.join(", ")}")
    end

    # Close the open context menu, as Escape does. Needed before opening another one: a menu opens
    # at the clicked row, so the next row's centre can lie inside it - a real click would land on the
    # menu there, and an act by id (no hit test) does not dismiss it.
    def close_menu : Nil
        @ui.press("Escape")
        raise ArgumentError.new("the context menu is still open after Escape") if @ui.present?("context_menu")
    end

    DIALOG_KINDS = {load: "dirbrowser_", save_as: "dirbrowser_", rename: "renamer_", create: "creator_",
                    import: "importtable_", add_field: "addfield_", decide: "decider_"}

    # The one open dialog of this kind - load, save_as, rename, create, import, add_field, decide.
    def dialog(kind : Symbol, & : Dialog ->) : Nil
        prefix = DIALOG_KINDS[kind]? || raise ArgumentError.new("no dialog kind :#{kind}; kinds: #{DIALOG_KINDS.keys.join(", ")}")
        widget = begin
            @ui.only(prefix)
        rescue ex : ArgumentError
            raise ArgumentError.new("no single :#{kind} dialog is open (#{ex.message})")
        end
        yield Dialog.new(@ui, widget.id.not_nil!)
    end

    # A dialog's parts by name: d.type(:name, "x"), d.click(:ok), d.press(:name, "Enter"), d.open_file("sub/x.embrace").
    class Dialog
        def initialize(@ui : CrymbleUI::Testing::Driver, @id : String)
        end

        def click(part : Symbol) : Nil
            @ui.click("#{@id}_#{part}")
        end

        # Type at the end of what the field holds.
        def type(part : Symbol, text : String) : Nil
            @ui.type("#{@id}_#{part}", text)
        end

        # Replace what the field holds, as a user does: select all, then type.
        def fill(part : Symbol, text : String) : Nil
            @ui.press("Ctrl+A", on: "#{@id}_#{part}")
            @ui.type("#{@id}_#{part}", text)
        end

        # A key chord with the keyboard on one of its parts: d.press(:name, "Enter").
        def press(name : Symbol, chord : String) : Nil
            @ui.press(chord, on: part(name))
        end

        # A part's widget id, for reading it: ui.ui.text(d.part(:name)).
        def part(name : Symbol) : String
            "#{@id}_#{name}"
        end

        def open_file(path : String) : Nil
            @ui.open_file("#{@id}_files", path)
        end
    end

    # === The configurator (by name path) ===

    # A configurator row's handle - right-click it for its context menu.
    def configurator_field(shape : ShapeState, *path : Segment) : String
        "cfg_name_#{shape.id}_#{key(shape, path)}"
    end

    def configurator_table(shape : ShapeState, *path : Segment) : String
        configurator_field(shape, *path)
    end

    # Tick or untick a configurator row's selection box.
    def select_field(shape : ShapeState, *path : Segment) : Nil
        @ui.click("cfg_sel_#{shape.id}_#{key(shape, path)}")
    end

    # Whether a configurator row's selection box is ticked - read from the box the user sees.
    def configurator_selected?(shape : ShapeState, *path : Segment) : Bool
        @ui.checked?("cfg_sel_#{shape.id}_#{key(shape, path)}")
    end

    def expand(shape : ShapeState, *path : Segment) : Nil
        @ui.click("cfg_links_#{shape.id}_#{key(shape, path)}")
    end

    # A reference field's arrow in a referenced table: ► outward, ◄ back to the table above.
    def configurator_arrow(shape : ShapeState, *path : Segment) : String
        "cfg_exp_#{shape.id}_#{key(shape, path)}"
    end

    # A configurator row to drag, and one to drop onto (moving or merging fields).
    def configurator_drag(shape : ShapeState, *path : Segment) : String
        "cfg_drag_#{shape.id}_#{key(shape, path)}"
    end

    def configurator_drop(shape : ShapeState, *path : Segment) : String
        "cfg_dz_#{shape.id}_#{key(shape, path)}"
    end

    # === The fieldlist ===

    # A field in the fieldlist - drag it onto a zone.
    def fieldlist_field(shape : ShapeState, *path : Segment) : String
        "fl_drag_#{shape.id}_#{key(shape, path)}"
    end

    {% for section in %w(columns rows aggregates unused) %}
        # The {{section.id}} section's drop zone at `level` (counted from 1, as the hover text shows it).
        def {{section.id}}_zone(shape : ShapeState, level : Int32 = 1) : String
            "fl_zone_#{shape.id}_{{section.id}}_#{level}"
        end
    {% end %}

    # The zone that opens a new level: the fieldlist always draws one empty level below the used ones
    # (a new line, for Aggregates), so it is the last zone of the section. Unused has one level only.
    {% for section in %w(columns rows aggregates) %}
        def new_{{section.id}}_level(shape : ShapeState) : String
            {{section.id}}_zone(shape, last_level(shape, "{{section.id}}"))
        end
    {% end %}

    # Which section and level (from 1) show the field - read from the widgets on screen:
    # fieldlist_section(shape, "People", "City") # => {:rows, 1}
    def fieldlist_section(shape : ShapeState, *path : Segment) : {Symbol, Int32}
        field = @ui.find("fl_field_#{shape.id}_#{key(shape, path)}")
        prefix = "fl_section_#{shape.id}_"
        current = field.parent
        while current
            if (id = current.id) && id.starts_with?(prefix)
                section, level = id.lchop(prefix).split('_')
                return {section_symbol(section), level.to_i}
            end
            current = current.parent
        end
        raise ArgumentError.new("#{describe(path)} is shown in no fieldlist section")
    end

    # === Grid cells (the detail layout: one record per row) ===

    # Type into the cell of the record with this Rank and this field, and commit it with Enter.
    def type_into_cell(shape : ShapeState, rank : Int32, field : String | Tuple, text : String) : Nil
        type_in_cell(shape, rank, field, text)
        @ui.press("Enter", on: grid(shape))
    end

    # What the grid shows in that cell.
    def cell_text(shape : ShapeState, rank : Int32, field : String | Tuple) : String
        r, c = cell(shape, rank, field)
        @ui.cell_text(grid(shape), r, c)
    end

    # Drag the record's cell in this field onto the row of the record with Rank `onto_rank` (a move
    # reorders the records).
    def drag_cell(shape : ShapeState, rank : Int32, field : String | Tuple, onto_rank : Int32) : Nil
        drag(shape, cell(shape, rank, field), cell(shape, onto_rank, field))
    end

    # Ctrl+X on the record's cell in this field: the cell is marked, to be moved by a paste.
    def cut_cell(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        on_cell(shape, rank, field) { @ui.press("Ctrl+X", on: grid(shape)) }
    end

    # Ctrl+V on the record's cell in this field: the cut cell moves here.
    def paste_cell(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        on_cell(shape, rank, field) { @ui.press("Ctrl+V", on: grid(shape)) }
    end

    # A key or chord on the Shape's grid, at its cursor cell.
    def press_in_grid(shape : ShapeState, chord : String) : Nil
        @ui.press(chord, on: grid(shape))
    end

    # Text typed into the Shape's grid, at its cursor cell - an edit begun, nothing committed.
    def type_in_grid(shape : ShapeState, text : String) : Nil
        @ui.type(grid(shape), text)
    end

    # The grid's cursor on the `part`-th grid cell of the header showing `text` - a header spanning several
    # rows or columns has one part per cell it spans, the first its top-left.
    def focus_header_part(shape : ShapeState, text : String, part : Int32) : Nil
        rows, cols = shape.matrix_adapter.not_nil!.size
        parts = (0...rows).flat_map { |r| (0...cols).map { |c| {r, c} } }.select do |rc|
            shape.matrix_adapter.not_nil!.cell_get_header_info(rc) && shown(shape, rc[0], rc[1]) == text
        end
        r, c = parts[part]? || raise ArgumentError.new("the header #{text.inspect} has #{parts.size} parts in Shape '#{table_of(shape)}'")
        @ui.focus_cell(grid(shape), r, c)
    end

    # The header the cut marker is on, by its text - nil when no header is marked.
    def cut_marked_header(shape : ShapeState) : String?
        vm = @ui.find(grid(shape)).as(CrymbleUI::VirtualMatrix)
        return nil if vm.drag_source_provisional?
        cell = vm.drag_source_cell || return nil
        pivot_view(shape).headers.find { |top, _| top == cell }.try(&.[1])
    end

    # Put the grid's cursor on the record's cell (focused, brought into view) - nothing else.
    def focus_cell(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        on_cell(shape, rank, field) { }
    end

    # Right-click the record's cell: its context menu opens (then `context_menu :action`).
    def context_menu_on(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        r, c = cell(shape, rank, field)
        @ui.right_click_cell(grid(shape), r, c)
    end

    # Click the record's cell, as the mouse does.
    def click_cell(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        r, c = cell(shape, rank, field)
        @ui.click_cell(grid(shape), r, c)
    end

    # Delete on the record's cell (the record goes), as the Delete key does on a cell nothing is typed in.
    def delete_record(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        on_cell(shape, rank, field) { @ui.press("Delete", on: grid(shape)) }
    end

    # Press a key or chord on the record's cell (Enter, Escape, Ctrl+T, ...).
    def press_on_cell(shape : ShapeState, rank : Int32, field : String | Tuple, chord : String) : Nil
        on_cell(shape, rank, field) { @ui.press(chord, on: grid(shape)) }
    end

    # Drag the record's cell onto another Shape's record cell - its centre, where a drop lands; refused as the
    # Driver refuses (covered, off screen, or the grid does not take it).
    def drag_cell(shape : ShapeState, rank : Int32, field : String | Tuple, *, onto other : ShapeState,
                  onto_rank : Int32, onto_field : String | Tuple) : Nil
        from, to = cell(shape, rank, field), cell(other, onto_rank, onto_field)
        @ui.drag_cell(grid(shape), from[0], from[1], onto: {grid(other), to[0], to[1]})
    end

    # Move the Shape's panel by (dx, dy): a real drag of its title bar.
    def move_panel(shape : ShapeState, dx : Float64, dy : Float64) : Nil
        panel = @ui.find(shape.id).as(CrymbleUI::WindowPanel)
        at = panel.viewport_bounds
        x, y = at.x + 60.0, at.y + panel.title_bar_height / 2 # in the title bar, clear of its left-hand buttons
        @ui.renderer.simulate_drag(x, y, x + dx, y + dy)
        @ui.settle
    end

    # Drag the record's cell off every grid and let go over nothing: a drag that drops nowhere.
    def drag_away(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        r, c = cell(shape, rank, field)
        @ui.focus_cell(grid(shape), r, c)
        from = @ui.find(grid(shape)).as(CrymbleUI::VirtualMatrix).active_cells[{r, c}].viewport_bounds.center
        @ui.renderer.simulate_drag(from.x, from.y, @ui.renderer.backend.width - 4.0, @ui.renderer.backend.height - 4.0)
        @ui.settle
    end

    # Insert on the record's cell (a new record there), as the Insert key does.
    def insert_record(shape : ShapeState, rank : Int32, field : String | Tuple) : Nil
        on_cell(shape, rank, field) { @ui.press("Insert", on: grid(shape)) }
    end

    # Type into the cell WITHOUT committing - the editor stays open. Reading a cell's text afterwards moves
    # the cursor (and so commits); read the cut marker (cut_marked) first.
    def type_in_cell(shape : ShapeState, rank : Int32, field : String | Tuple, text : String) : Nil
        on_cell(shape, rank, field) { type_in_grid(shape, text) }
    end

    # The cell the cut marker is on, as {Rank, field} - nil when no cell is marked. Read from the grid:
    # the committed (non-provisional) drag source its overlay draws. (The grid's state, not the drawn
    # pixels: a cancel that forgot to repaint the overlay would not show here.)
    def cut_marked(shape : ShapeState) : {Int32, String}?
        vm = @ui.find(grid(shape)).as(CrymbleUI::VirtualMatrix)
        return nil if vm.drag_source_provisional?
        vm.drag_source_cell.try { |(r, c)| record_cell(shape, r, c) }
    end

    # === Grid cells (a pivot) ===
    #
    # A pivot's data cell is named by ALL the header texts in its row and in its column, as displayed,
    # outermost first - an aggregate's name header included whenever the grid shows one; a header
    # spanning several rows or columns counts once:
    #     ui.pivot_text(shape, rows: ["A"], cols: ["Al"])    Group A, Name Al

    record PivotCell, rows : Array(String), cols : Array(String) do
        def to_s(io : IO) : Nil
            io << "rows: " << rows << ", cols: " << cols
        end
    end

    # Drag one pivot cell onto another.
    def drag_cell(shape : ShapeState, rows : Array(String), cols : Array(String),
                  onto_rows : Array(String), onto_cols : Array(String)) : Nil
        drag(shape, pivot_cell(shape, PivotCell.new(rows, cols)), pivot_cell(shape, PivotCell.new(onto_rows, onto_cols)))
    end

    # Drag one pivot cell onto the header cell showing `onto_header`.
    def drag_cell(shape : ShapeState, rows : Array(String), cols : Array(String), onto_header : String) : Nil
        headers = pivot_view(shape).headers
        to = one(shape, headers.select { |_, text| text == onto_header }, "header", onto_header.inspect, "Headers") do
            headers.map { |_, text| text.inspect }.uniq
        end
        drag(shape, pivot_cell(shape, PivotCell.new(rows, cols)), to[0])
    end

    # What the grid shows in that pivot cell.
    def pivot_text(shape : ShapeState, rows : Array(String), cols : Array(String)) : String
        r, c = pivot_cell(shape, PivotCell.new(rows, cols))
        @ui.cell_text(grid(shape), r, c)
    end

    # Where the grid's cursor is: {Rank, field} in the detail layout, else a PivotCell. Read it before
    # a cell's text - reading one brings that cell into view, cursor and all.
    # In the detail layout it names fields of the Shape's own table, the form cell_text takes back.
    def cursor_cell(shape : ShapeState) : {Int32, String} | PivotCell
        at = @ui.cursor(grid(shape))
        unless shape.detail_layout?
            return pivot_view(shape).cells.find { |rc, _| rc == at }.try(&.[1]) ||
                   raise ArgumentError.new("the cursor is on a header cell of Shape '#{table_of(shape)}'")
        end
        record_cell(shape, at[0], at[1])
    end

    # === History ===

    # One commit back (:back, the "<" button) or forward (:forward, ">") in the Shape's history.
    def history(shape : ShapeState, step : Symbol) : Nil
        case step
        when :back    then act("hist_back_#{shape.id}", "Shape '#{table_of(shape)}' shows no history buttons")
        when :forward then act("hist_fwd_#{shape.id}", "Shape '#{table_of(shape)}' shows no history buttons")
        else               raise ArgumentError.new("a history step is :back or :forward, not :#{step}")
        end
    end

    # An act the app refuses: its exception reaches the status bar, as real input's does, and must
    # match `message` (crymble-ui Driver#expect_reported).
    def expect_reported(message : Regex | String, &) : Nil
        @ui.expect_reported(message) { yield }
    end

    # The status bar's text.
    def status : String
        @ui.text("statusbar")
    end

    # === Resolution ===

    # The configurator row a name path names, as its key; raises listing the valid paths.
    private def key(shape : ShapeState, path) : String
        segments = path.to_a.map(&.as(Segment))
        all = named_rows(shape)
        one(shape, all.select { |row_path, _| row_path == segments }, "configurator row", describe(segments), "Valid paths") do
            all.map { |row_path, _| row_path.map(&.to_s).join(", ") }
        end[1]
    end

    # The one match, else an ArgumentError saying there is none or how many, listing what there is -
    # the listing built only then.
    private def one(shape : ShapeState, matches : Array(T), what : String, name : String, title : String,
                    & : -> Array(String)) : T forall T
        return matches.first if matches.size == 1
        reason = matches.empty? ? "no #{what}" : "#{matches.size} #{what}s"
        raise ArgumentError.new("#{reason} #{name} in Shape '#{table_of(shape)}'. #{title}:\n  " + yield.join("\n  "))
    end

    # Every configurator row of the Shape as {name path, key}, in tree order.
    private def named_rows(shape : ShapeState) : Array({Array(Segment), String})
        stack = [] of Segment
        Fixtures.tree_rows(shape).map do |node, level|
            stack = stack[0, level]
            stack << segment(shape, node)
            {stack.dup, node.key}
        end
    end

    # A row's name: its label; a table reached through an INWARD reference (VHTreeAdapter#inward_via)
    # also names the referencing field of that table - taken from the tree, not from the ◄ drawn.
    private def segment(shape : ShapeState, node) : Segment
        label = node.get_display_texts[1]
        return label unless via = node.inward_via
        Inward.new(label, shape.persistency.with_context(shape.context) { shape.persistency.display_name(via) })
    end

    private def grid(shape : ShapeState) : String
        "matrix_grid_#{shape.id}"
    end

    # Grid cell {r, c} of the detail layout as {Rank, field of the Shape's own table}.
    private def record_cell(shape : ShapeState, r : Int32, c : Int32) : {Int32, String}
        path = named_rows(shape).find { |_, key| key == shape.cell_key(r, c) }.try(&.[0]) ||
               raise ArgumentError.new("grid cell #{r},#{c} is on no field's column")
        unless path.size == 2 && path[0] == table_of(shape)
            raise ArgumentError.new("grid cell #{r},#{c} is on #{describe(path)}, not a field of the Shape's own table")
        end
        {shape.cell_value(r, columns(shape).index("Rank").not_nil!).as(Int64).to_i32, path[1].to_s}
    end

    # The record's cell in this field, focused (brought into view, the cursor on it), then the act.
    private def on_cell(shape : ShapeState, rank : Int32, field : String | Tuple, &) : Nil
        r, c = cell(shape, rank, field)
        @ui.focus_cell(grid(shape), r, c)
        yield
    end

    private def drag(shape : ShapeState, from : {Int32, Int32}, to : {Int32, Int32}) : Nil
        @ui.drag_cell(grid(shape), from[0], from[1], onto: {grid(shape), to[0], to[1]})
    end

    private def cell(shape : ShapeState, rank : Int32, field : String | Tuple) : {Int32, Int32}
        raise ArgumentError.new("Shape '#{table_of(shape)}' is not in the detail layout (one record per row)") unless shape.detail_layout?
        want = field.is_a?(String) ? key(shape, {table_of(shape).not_nil!, field}) : key(shape, field)
        rows = shape.matrix_adapter.not_nil!.size[0]
        keys = columns(shape)
        rank_col = keys.index("Rank") || raise ArgumentError.new("Shape '#{table_of(shape)}' shows no Rank column")
        col = keys.index(want) || raise ArgumentError.new("Shape '#{table_of(shape)}' shows no column #{field}")
        row = (0...rows).find { |r| shape.cell_value(r, rank_col) == rank.to_i64 } ||
              raise ArgumentError.new("Shape '#{table_of(shape)}' shows no record with Rank #{rank}")
        {row, col}
    end

    # Each grid column's key, from the first of its cells that is not dead.
    private def columns(shape : ShapeState) : Array(String?)
        rows, cols = shape.matrix_adapter.not_nil!.size
        (0...cols).map { |c| (0...rows).each.compact_map { |r| shape.cell_key(r, c) }.first? }
    end

    # The data cell a PivotCell names; raises listing the names the grid shows.
    private def pivot_cell(shape : ShapeState, name : PivotCell) : {Int32, Int32}
        raise ArgumentError.new("Shape '#{table_of(shape)}' is in the detail layout; name a cell by Rank and field") if shape.detail_layout?
        cells = pivot_view(shape).cells
        one(shape, cells.select { |_, n| n == name }, "cell", name.to_s, "Cells") { cells.map { |_, n| n.to_s }.uniq }[0]
    end

    # A pivot as the screen names it: every data cell with its PivotCell, every header cell with its
    # text - a spanned header once, by its top-left. Each row's and each column's headers are read
    # once, so naming the whole grid costs one pass over it.
    record PivotView, cells : Array({ {Int32, Int32}, PivotCell }), headers : Array({ {Int32, Int32}, String })

    private def pivot_view(shape : ShapeState) : PivotView
        adapter = shape.matrix_adapter.not_nil!
        rows, cols = adapter.size
        top = {} of {Int32, Int32} => {Int32, Int32} # header cell -> its merge's top-left
        rows.times { |r| cols.times { |c| top[{r, c}] = adapter.cell_get_bounding_box({r, c})[0] if adapter.cell_get_header_info({r, c}) } }
        text = top.values.uniq.to_h { |(r, c)| { {r, c}, shown(shape, r, c) } }
        along = ->(line : Array({Int32, Int32})) { line.compact_map { |rc| top[rc]? }.uniq.map { |t| text[t] } }
        row_names = (0...rows).map { |r| along.call((0...cols).map { |c| {r, c} }) }
        col_names = (0...cols).map { |c| along.call((0...rows).map { |r| {r, c} }) }
        cells = (0...rows).flat_map do |r|
            (0...cols).reject { |c| top.has_key?({r, c}) }.map { |c| { {r, c}, PivotCell.new(row_names[r], col_names[c]) } }
        end
        PivotView.new(cells, text.to_a)
    end

    # What a cell shows, read from the pivot (never the adapter's recording cell_read).
    private def shown(shape : ShapeState, r : Int32, c : Int32) : String
        shape.matrix_adapter.not_nil!.display_string(shape.cell_value(r, c))
    end

    private def last_level(shape : ShapeState, section : String) : Int32
        level = 0
        while @ui.present?("fl_zone_#{shape.id}_#{section}_#{level + 1}")
            level += 1
        end
        raise ArgumentError.new("Shape '#{table_of(shape)}' shows no #{section} zone") if level == 0
        level
    end

    private def section_symbol(word : String) : Symbol
        case word
        when "columns"    then :columns
        when "rows"       then :rows
        when "aggregates" then :aggregates
        when "unused"     then :unused
        else                   raise ArgumentError.new("unknown fieldlist section '#{word}'")
        end
    end

    private def act(id : String, missing : String) : Nil
        raise ArgumentError.new(missing) unless @ui.present?(id)
        @ui.click(id)
    end

    private def describe(path) : String
        path.to_a.map(&.to_s).join(" > ")
    end
end

def inward(table : String, via : String) : EmbraceUI::Inward
    EmbraceUI::Inward.new(table, via)
end
