# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../global"
require "../table/pivot"
require "../table/filter"
require "../persistency"
require "../virtualtable"
require "../fieldlist"
require "crymble-ui"

# the used widgets:
require "./tablefieldpicker"
require "./matrix"
require "./vhtree"
require "./fieldlist"
require "./cell"

# the windows:
require "./dialogues"

include Persistency

# === VHTree Drag Data ===

class VHTreeDragData < CrymbleUI::DragData
    getter adapter : SimpleVHTreeAdapter
    def initialize(@adapter); end
    def data_type : String; "vhtree_field"; end
    def display_text : String?; @adapter.get_display_texts[1]?; end
end

# === VHTree Adapter ===

module Interface::GUI::VHTreeAdapter
    abstract def each(&block : Interface::GUI::VHTreeAdapter ->)
    abstract def get_reference : Interface::GUI::VHTreeAdapter? # odd level node references odd-2 level node
    abstract def get_display_texts : Array(String)
    abstract def is_selected? : Bool | SomeStruct
    abstract def is_selectable? : Bool
    abstract def is_expandable? : Bool
    abstract def toggle_select : Nil
    abstract def toggle_expand : Nil
    abstract def drag : Bool # true, if draggable
    abstract def is_moveable?(from : Interface::GUI::VHTreeAdapter) : Bool
    abstract def move(from : Interface::GUI::VHTreeAdapter) : Nil
    abstract def node : Table::VirtualTable::Tree
    abstract def is_table? : Bool
    abstract def is_pseudo_field? : Bool
    abstract def field_lid : FieldLID?
    abstract def table_lid : TableLID?
end

class SimpleVHTreeAdapter
    include Interface::GUI::VHTreeAdapter
    @children2adapter = Hash(Table::VirtualTable::Tree, SimpleVHTreeAdapter).new
    @configurator : Table::VirtualTable::Configurator(Cell, BaseCell)
    protected getter node : Table::VirtualTable::Tree

    def initialize(@configurator, @context : Persistency::Context, node : Table::VirtualTable::Tree? = nil)
        @node = node || @configurator.tree
    end

    def each(&block : Interface::GUI::VHTreeAdapter ->)
        @node.each do |_, child|
            if !(own = @children2adapter[child]?)
                own = @children2adapter[child] = SimpleVHTreeAdapter.new(@configurator, @context, child)
            end
            yield(own)
        end
    end

    def get_reference : Interface::GUI::VHTreeAdapter?
        node2 = @configurator.get_reference(@node)
        node2 ? SimpleVHTreeAdapter.new(@configurator, @context, node2) : nil
    end

    def get_display_texts : Array(String)
        @configurator.display_name[@node].to_a
    end

    def is_selected? : Bool | SomeStruct
        @configurator.is_selected?(@node)
    end

    def is_selectable? : Bool
        @configurator.is_selectable?(@node)
    end

    def is_expandable? : Bool
        @configurator.is_expandable?(@node)
    end

    def toggle_select : Nil
        @configurator.toggle_select(@node)
    end

    def toggle_expand : Nil
        @configurator.toggle_expand(@node)
    end

    def drag : Bool
        is_field_node = (@configurator.level[@node] % 2 != 0)
        is_selectable = @configurator.is_selectable?(@node)
        is_real_field = !@node.value.is_a?(Table::VirtualTable::PseudoFields)
        is_field_node && is_selectable && is_real_field
    end

    def is_moveable?(from : Interface::GUI::VHTreeAdapter) : Bool
        !!calc_move(from)
    end

    def calc_move_info(from : Interface::GUI::VHTreeAdapter)
        calc_move(from)
    end

    private def calc_move(from : Interface::GUI::VHTreeAdapter) : {Symbol, TableLID, FieldLID, TableLID, FieldLID, Table::VirtualTable::Tree}?
        from = from.node # attention: we overwrite initial `from`
        from_p = from.parent
        from_pp = (from_p ? from_p.parent : nil)
        from_ppp = (from_pp ? from_pp.parent : nil)
        to = @node
        to_p = to.parent
        to_pp = (to_p ? to_p.parent : nil)
        if from_p && to_p && (to_p == from_p)
            if !to.value.is_a?(Table::VirtualTable::PseudoFields) && (to != from)
                # {direction, start_table, start_field, target_table, target_field}:
                {:internal, from_p.value.as(TableLID), from.value.as(FieldLID), to_p.value.as(TableLID), to.value.as(FieldLID), to}
            else
                nil
            end
        else
            # observation: "from" is always field, we need to check cases when "to" is table
            # calculate {direction, source_table, link_field, sink_table, move_field}
            if from_p && to_p && (from_p == to_pp)
                # "from" is on the left, "to" on the right -> in configurator move to the "right"
                if @configurator.is_expanded?(to) # target should be expanded
                    if @configurator.is_incoming[to]
                        {:outwards, from_p.value.as(TableLID), to_p.value.as(FieldLID), to.value.as(TableLID), from.value.as(FieldLID), to}
                    else
                        {:inwards, to.value.as(TableLID), to.edge_to_parent.as(FieldLID), from_p.value.as(TableLID), from.value.as(FieldLID), to}
                    end
                else
                    nil
                end
            elsif from_p && from_pp && (from_ppp == to)
                # "from" is on the right, "to" on the left -> in configurator move to the "left"
                if @configurator.is_incoming[from_p]
                    {:inwards, to.value.as(TableLID), from_pp.value.as(FieldLID), from_p.value.as(TableLID), from.value.as(FieldLID), to}
                else
                    {:outwards, from_p.value.as(TableLID), from_p.edge_to_parent.as(FieldLID), to.value.as(TableLID), from.value.as(FieldLID), to}
                end
            else
                nil
            end
        end
    end

    def move(from : Interface::GUI::VHTreeAdapter) : Nil
        # handled by EmbraceApp.handle_vhtree_drop
    end

    def is_table? : Bool
        @configurator.level[@node] % 2 == 0
    end

    def is_pseudo_field? : Bool
        @node.value.is_a?(Table::VirtualTable::PseudoFields)
    end

    def field_lid : FieldLID?
        v = @node.value
        v.is_a?(FieldLID) ? v : nil
    end

    def table_lid : TableLID?
        v = @node.value
        v.is_a?(TableLID) ? v : nil
    end

    def ==(other : Interface::GUI::VHTreeAdapter)
        @node == other.node
    end

    def hash(hasher)
        @node.hash(hasher)
    end
end

# === Matrix Adapter ===

class SimpleMatrixAdapter(T, U, V)
    include Interface::GUI::MatrixAdapter(T)
    include CrymbleUI::Widgets::VirtualMatrix::MatrixAdapter

    @shape : ShapeState?
    property on_data_changed : Proc(Nil)?
    property virtual_matrix : CrymbleUI::VirtualMatrix? = nil

    # Change animation state
    MONO_EPOCH = Time::Instant.allocate
    HIGHLIGHT_STAGES = [0.0, 0.5, 2.5, 3.0]
    @last_values = Hash({Int32, Int32}, String).new
    @current_values = Hash({Int32, Int32}, String).new
    @values_highlight_deadlines = Hash({Int32, Int32}, Float64).new
    @highlight_new_cells : Bool = false
    @highlight_changed_cells : Bool = false
    @virgin : Bool = true
    @frame_count : Int32 = 0
    @just_edited : Bool = false
    @highlight_timer_id : Int32? = nil

    def initialize(@matrix_rc : Table::Lazy::Pivot::Hierarchic(T, U, V), @persistency : Persistency::Default,
                   @shape : ShapeState? = nil)
    end

    # Swap underlying pivot (used when filter state changes so the VirtualMatrix
    # binding to this adapter stays stable across rebuilds).
    def matrix_rc=(new_rc : Table::Lazy::Pivot::Hierarchic(T, U, V)) : Nil
        @matrix_rc = new_rc
        invalidate_all!
    end

    # Push shape context for all persistency reads/writes.
    # Without this, @matrix_rc reads from the base context which doesn't
    # see commits created by the shape.
    private def with_shape_context(&)
        if shape = @shape
            @persistency.contexts.push(shape.context)
            result = yield
            shape.context = @persistency.contexts.pop
            result
        else
            yield
        end
    end

    # === CrymbleUI MatrixAdapter implementation ===

    def cell_paint(row : Int32, col : Int32) : CrymbleUI::Widget
        value = cell_read({row, col})
        is_header = !!cell_get_header_info({row, col})
        text_color = is_header ? CrymbleUI::Theme.current.ruler_label : nil
        # Diff-Shape highlight: if this cell was written at the diff target
        # commit, paint it with a colored background. No-op for normal shapes.
        diff_bg = diff_highlight_background(row, col)
        case value
        when ReferenceCell
            # Build dropdown list: fulfilling items first (green), then violating (red)
            constraint_ok  = CrymbleUI::Theme.current["constraint.ok"]
            constraint_nok = CrymbleUI::Theme.current["constraint.nok"]
            fulfilling = value.each_defined_fulfilling.to_a
            breaking = value.each_defined_breaking.to_a
            all_items = fulfilling + breaking
            items = all_items.map(&.value.to_s)
            item_colors = Array(CrymbleUI::Color).new(items.size) { |i| i < fulfilling.size ? constraint_ok : constraint_nok }
            selected_idx = all_items.index { |rc| rc.rank == value.rank } || 0
            # diff_bg (if set) tints the collapsed cell's background via the
            # ComboBox's background_color property, while per-item constraint
            # colours remain visible in the dropdown.
            CrymbleUI::ComboBox.new(items: items, selected: selected_idx,
                text_background_colors: item_colors, background_color: diff_bg,
                id: "rc_#{row}_#{col}") do |index, _val|
                if rc = all_items[index]?
                    cell_assign_reference(row, col, rc.rank)
                end
            end
        when Bool
            # Bool cells are checkboxes (as in the pre-crymbleui ImGui build):
            # the box visualises the value and Space / double-click toggle it.
            # The cursor cell's checkbox becomes the matrix proxy, so a Space
            # keypress is forwarded to Checkbox#trigger_click, which flips the
            # box and fires this callback. We persist the negation of the value
            # captured at build time (which equals the current cell value).
            captured = value
            CrymbleUI::Checkbox.new("", checked: captured, background_color: diff_bg, id: "bool_#{row}_#{col}") do
                cell_assign(row, col, captured ? "'false" : "'true")
            end
        when NilRecordStruct, NilDeadAreaStruct, Nil
            if diff_bg
                CrymbleUI::TextInput.new(value: "", mode: CrymbleUI::TextInputMode::QuickEntry, background_color: diff_bg)
            else
                CrymbleUI::Text.new("")
            end
        else
            cell_text = case value
            when String  then value
            when Int64   then value.to_s
            when Float64 then value.to_s
            else              ""
            end
            if diff_bg && text_color
                CrymbleUI::TextInput.new(value: cell_text, mode: CrymbleUI::TextInputMode::QuickEntry, text_color: text_color, background_color: diff_bg)
            elsif diff_bg
                CrymbleUI::TextInput.new(value: cell_text, mode: CrymbleUI::TextInputMode::QuickEntry, background_color: diff_bg)
            elsif text_color
                CrymbleUI::TextInput.new(value: cell_text, mode: CrymbleUI::TextInputMode::QuickEntry, text_color: text_color)
            else
                CrymbleUI::TextInput.new(value: cell_text, mode: CrymbleUI::TextInputMode::QuickEntry)
            end
        end
    end

    # Returns a highlight color if this cell should be diff-highlighted, nil
    # otherwise. Only fires for diff-Shapes (where shape.diff_target_commit
    # is set) and only for cells that have an entry at the target commit in
    # persistency.cells_written_at.
    # Soft yellow tint for diff-highlighted cells. Hardcoded for now — can be
    # promoted to a crymble-ui Theme entry if the color ever needs theming.
    DIFF_HIGHLIGHT_COLOR = CrymbleUI::Color.new(96_u8, 80_u8, 0_u8, 255_u8)

    private def diff_highlight_background(row : Int32, col : Int32) : CrymbleUI::Color?
        shape = @shape
        return nil unless shape
        changed = shape.diff_changed_cells
        return nil unless changed
        return nil unless changed.includes?({row, col})
        DIFF_HIGHLIGHT_COLOR
    end

    # Bridge methods: CrymbleUI uses separate params, embrace uses tuple params
    # Painting uses single-cell bounds for non-headers (cells rendered individually)
    def cell_get_bounding_box(row : Int32, col : Int32) : Tuple(Tuple(Int32, Int32), Tuple(Int32, Int32))
        if cell_get_header_info(row, col)
            cell_get_bounding_box({row, col})
        else
            { {row, col}, {row, col} }
        end
    end

    # Bridge: CrymbleUI adapter cell_read (row,col) → embrace tuple cell_read
    def cell_read(row : Int32, col : Int32) : String
        cell_read({row, col}).to_s
    end

    def has_active_highlights? : Bool
        !@values_highlight_deadlines.empty?
    end

    # Drag/cut uses real bounding box for ALL cells (spans full record region)
    def cell_get_drag_bounding_box(row : Int32, col : Int32) : Tuple(Tuple(Int32, Int32), Tuple(Int32, Int32))
        cell_get_bounding_box({row, col})
    end

    # Change animation: calculate alpha for white border based on elapsed time
    def cell_highlight_alpha(row : Int32, col : Int32) : UInt8
        deadline = @values_highlight_deadlines[{row, col}]?
        return 0_u8 unless deadline
        now = ((Time.instant - MONO_EPOCH).total_seconds)
        remaining = deadline - now
        return 0_u8 if remaining <= 0
        delta = HIGHLIGHT_STAGES.last - remaining
        stage = HIGHLIGHT_STAGES.bsearch_index { |x| x > delta } || HIGHLIGHT_STAGES.size
        stage -= 1
        v1 = HIGHLIGHT_STAGES[stage]
        v2 = HIGHLIGHT_STAGES[stage + 1]?
        gain = v2 ? (delta - v1) / (v2 - v1) : 0.0
        alpha = case stage
            when 0 then (255 * gain).to_i32       # fade in
            when 1 then 255                         # solid
            when 2 then (255 * (1 - gain)).to_i32   # fade out
            else 0
            end
        alpha.clamp(0, 255).to_u8
    end

    def cell_get_header_info(row : Int32, col : Int32) : Tuple(Bool, Int32)?
        cell_get_header_info({row, col})
    end

    def cell_get_name(row : Int32, col : Int32) : String
        cell_get_name({row, col})
    end

    def cell_has_content?(row : Int32, col : Int32) : Bool
        cell_has_content({row, col})
    end

    def cell_assign(row : Int32, col : Int32, value : String) : Tuple(Int32, Int32)
        # Read-only Shapes (e.g. diff-Shapes) refuse edits: editing a nil cell
        # in a diff view would write on top of the clamped context and confuse.
        return {row, col} if (sh = @shape) && sh.readonly?
        converted = CellHelper.convert(value)
        return {row, col} unless converted
        if shape = @shape
            @persistency.contexts.push(shape.context)
            begin
                result = cell_assign({row, col}, converted[0])
            rescue ConditionsNotMet
                result = {row, col}
            end
            shape.context = @persistency.contexts.pop
            shape.update
            invalidate_all!
            @on_data_changed.try &.call
            result
        else
            begin
                cell_assign({row, col}, converted[0])
            rescue ConditionsNotMet
                {row, col}
            end
        end
    end

    # Assign a reference cell by rank (used by ComboBox selection callback)
    def cell_assign_reference(row : Int32, col : Int32, rank : Int32) : Tuple(Int32, Int32)
        @just_edited = true
        if shape = @shape
            @persistency.contexts.push(shape.context)
            begin
                current = @matrix_rc[{row, col}.to_a]
                if current.is_a?(ReferenceCell)
                    current.rank = rank
                    result = cell_assign({row, col}, current)
                else
                    result = {row, col}
                end
            rescue ConditionsNotMet
                result = {row, col}
            end
            shape.context = @persistency.contexts.pop
            shape.update
            invalidate_all!
            @virtual_matrix.try &.set_cursor(result[0], result[1])
            @on_data_changed.try &.call
            result
        else
            {row, col}
        end
    end

    def cell_move(from_row : Int32, from_col : Int32, to_row : Int32, to_col : Int32) : Tuple(Int32, Int32)
        @just_edited = true
        with_shape_context { cell_move({from_row, from_col}, {to_row, to_col}) }
    end

    def version : Int32
        @matrix_rc.version
    end

    def start_frame : Nil
        @last_values, @current_values = @current_values, Hash({Int32, Int32}, String).new
        # Suppress highlights on the topmost (focused) panel — only show on background shapes
        is_top = false
        if vm = @virtual_matrix
            w = vm.as(CrymbleUI::Widget)
            while w = w.parent
                if w.is_a?(CrymbleUI::WindowPanel)
                    is_top = w.topmost?
                    break
                end
            end
        end
        if @virgin || @just_edited || is_top
            @highlight_new_cells = false
            @highlight_changed_cells = false
            @just_edited = false
        else
            @highlight_new_cells = true
            @highlight_changed_cells = true
        end
        @virgin = false
        # Garbage collect expired deadlines and manage animation timer
        @frame_count += 1
        now = ((Time.instant - MONO_EPOCH).total_seconds)
        if @frame_count % 100 == 0
            @values_highlight_deadlines.reject! { |_, v| v < now }
        end
        # Start animation timer when new highlights appear (self-cancels when done)
        has_active = !@values_highlight_deadlines.empty? && @values_highlight_deadlines.any? { |_, v| v > now }
        if has_active && @highlight_timer_id.nil?
            @highlight_timer_id = CrymbleUI::Widget.scheduler.schedule(100.milliseconds, repeating: true) do
                t = ((Time.instant - MONO_EPOCH).total_seconds)
                still_active = @values_highlight_deadlines.any? { |_, v| v > t }
                if still_active
                    # Only redraw during fade stages (0-0.5s and 2.5-3.0s), skip solid hold
                    needs_redraw = @values_highlight_deadlines.any? do |_, deadline|
                        elapsed = HIGHLIGHT_STAGES.last - (deadline - t)
                        elapsed < HIGHLIGHT_STAGES[1] || elapsed > HIGHLIGHT_STAGES[2]
                    end
                    @virtual_matrix.try &.mark_cursor_overlay_dirty if needs_redraw
                else
                    if tid = @highlight_timer_id
                        CrymbleUI::Widget.scheduler.cancel(tid)
                        @highlight_timer_id = nil
                    end
                    @virtual_matrix.try &.mark_cursor_overlay_dirty
                end
            end
        end
    end

    def get_scrollorder : {Array(Int32), Array(Int32)}
        with_shape_context { @matrix_rc.get_scrollorder }
    end

    def cell_get_header_info(index : {Int32, Int32}) : {Bool, Int32}?
        with_shape_context { @matrix_rc.get_header_info(index.to_a) }
    end

    def cell_get_bounding_box(index : {Int32, Int32}) : { {Int32, Int32}, {Int32, Int32} }
        with_shape_context do
            res = @matrix_rc.get_bounding_box(index.to_a)
            { {res[0][0], res[0][1]}, {res[1][0], res[1][1]} }
        end
    end

    def cell_get_name(index : {Int32, Int32}) : String
        with_shape_context { @matrix_rc.hyperplane_get_name(1, index.to_a) }
    end

    def cell_read(index : {Int32, Int32}) : T
        with_shape_context do
            res = @matrix_rc[index.to_a]
            # Normalize for change comparison (catches RC renames + header reorder)
            val = res.is_a?(ReferenceCell) ? "#{res.rank}-#{res.value}" : res.to_s
            @current_values[index] = val

            # Detect changes for highlight animation
            highlight = if !@last_values.has_key?(index) && !val.empty?
                @highlight_new_cells
            elsif @last_values[index]? != val
                @highlight_changed_cells
            else
                false
            end

            if highlight
                @values_highlight_deadlines[index] = ((Time.instant - MONO_EPOCH).total_seconds) + HIGHLIGHT_STAGES.last
            end

            case res
            when String, Int64, Float64, ReferenceCell, Bool
                res
            when Nil, NilDeadArea
                ""
            else
                ""
            end
        end
    end

    def cell_assign(index : {Int32, Int32}, value : T) : {Int32, Int32}
        @just_edited = true
        index_a = index.to_a
        case @matrix_rc.get_assignability(index_a)
        when Table::Lazy::Pivot::Assignability::Directly
            res = @matrix_rc[index_a] = value
        when Table::Lazy::Pivot::Assignability::Indirectly
            res = @matrix_rc.hyperplane_add(0, index_a)
            if @matrix_rc[res].is_a?(ReferenceCell) == value.is_a?(ReferenceCell)
                res = @matrix_rc[res] = value
            else
                @matrix_rc.hyperplane_remove(0, res)
                raise ConditionsNotMet.new("Can only assign Reference to Reference")
            end
        else
            raise ConditionsNotMet.new("No assignment possible")
        end
        {res[0], res[1]}
    end

    # Set cell to undefined: rank=0 for reference cells, nil for normal cells
    def cell_set_undefined(index : {Int32, Int32}) : {Int32, Int32}
        current = @matrix_rc[index.to_a]
        if current.is_a?(ReferenceCell)
            current.rank = 0
            cell_assign(index, current)
        else
            cell_assign(index, nil)
        end
    end

    def cell_insert(index : {Int32, Int32}) : {Int32, Int32}
        # Route the persistency write through the Shape's pinned context so
        # the new record lands on the Shape's open commit (not whatever
        # context happens to be on top of the global stack at click time).
        # Same fix as cell_assign / cell_move; without it diff-Shapes (which
        # read the Shape's @context) miss inserts done in another shape.
        with_shape_context { @matrix_rc.hyperplane_add(0, index.to_a) }
        {index[0], index[1]}
    end

    def cell_delete(index : {Int32, Int32}) : Nil
        with_shape_context { @matrix_rc.hyperplane_remove(0, index.to_a) }
    end

    def cell_transform_to_name(index : {Int32, Int32}) : Nil
        with_shape_context { @matrix_rc.hyperplane_remove(0, index.to_a, transform_to_names: true) }
    end

    def cell_has_content(index : {Int32, Int32}) : Bool
        with_shape_context do
            stat = @matrix_rc.get_assignability(index.to_a)
            stat == Table::Lazy::Pivot::Assignability::Directly || stat == Table::Lazy::Pivot::Assignability::Drilldown
        end
    end

    def cell_move(from : {Int32, Int32}, to : {Int32, Int32}) : {Int32, Int32}
        res = @matrix_rc.hyperplane_move(0, from.to_a, to.to_a)
        {res[0], res[1]}
    end
end

# === Fieldlist Adapter ===

class FieldlistAdapter
    include Interface::GUI::FieldlistAdapter(FieldlistCell)

    def initialize(@table : Table::Lazy::Raw::Base(FieldlistCell))
    end

    def version : Int32
        @table.version
    end

    def size : Int32
        @table.size[0]
    end

    def cell_read(index : Index) : FieldlistCell | RowClass
        ci = get_ci(index[1])
        cell = @table[[index[0], ci]]
        if index[1] == ColumnIndices::Class
            case cell
            when Table::Lazy::Pivot::Classes::Unused.value
                RowClass::Unused
            when Table::Lazy::Pivot::Classes::Column.value
                RowClass::ColumnHeader
            when Table::Lazy::Pivot::Classes::Row.value
                RowClass::RowHeader
            when Table::Lazy::Pivot::Classes::Aggregate.value
                RowClass::Aggregate
            end
        else
            cell
        end
    end

    def cell_assign(index : Index, value : FieldlistCell | RowClass) : Nil
        ci = get_ci(index[1])
        if index[1] == ColumnIndices::Class
            value = case value
            when RowClass::Unused
                Table::Lazy::Pivot::Classes::Unused.value.to_i64
            when RowClass::ColumnHeader
                Table::Lazy::Pivot::Classes::Column.value.to_i64
            when RowClass::RowHeader
                Table::Lazy::Pivot::Classes::Row.value.to_i64
            when RowClass::Aggregate
                Table::Lazy::Pivot::Classes::Aggregate.value.to_i64
            else
                assert(false)
            end
        end
        @table[[index[0], ci]] = value.as(FieldlistCell)
    end

    private def get_ci(index : ColumnIndices) : Int32
        case index
        when GUI::Widget::FieldlistConstants::ColumnIndices::Rank
            Table::Lazy::Fieldlist::ColumnIndices::Rank.value
        when GUI::Widget::FieldlistConstants::ColumnIndices::Class
            Table::Lazy::Fieldlist::ColumnIndices::Class.value
        when GUI::Widget::FieldlistConstants::ColumnIndices::Level
            Table::Lazy::Fieldlist::ColumnIndices::Level.value
        when GUI::Widget::FieldlistConstants::ColumnIndices::SortAscending
            Table::Lazy::Fieldlist::ColumnIndices::SortAscending.value
        when GUI::Widget::FieldlistConstants::ColumnIndices::Name
            Table::Lazy::Fieldlist::ColumnIndices::Name.value
        else
            assert(false)
        end
    end
end

# === Shape State ===
# Shape holds all business logic state for a database exploration view.
# Rendering is done by EmbraceApp.build() using CrymbleUI DSL.

class ShapeState
    BRANCH_TIPS_NAMES = ["Mainline"] + Array.mix(%w(Andes Atlantic Berlin Brooklyn Cairo Colorado Delhi Denali Dublin Everest Florida Geneva Giza Himalaya Hudson India Ireland Jamaica Jordan Kenya Kilimanjaro Kyoto Lisbon London Madrid Mars Milan Missouri Monaco Montana Moscow Munich Nairobi Nile Norway Oxford Pacific Paris Pisa Pluto Portland Prague Quebec Rhine Rome Sahara Saturn Seville Shanghai Sicily Sydney Thames Tokyo Toronto Tuscany Uganda Utah Vatican Venice Venus Vienna Wales Warsaw Yukon Zurich Alps Rockies Congo Danube Seine Tigris Euphrates Fuji Pyrenees Apennines Kalahari Mojave Ganges Yangtze Mekong Mississippi Victoria Ontario Erie Michigan Superior Baikal Caspian Jupiter Mercury Neptune Ceres Orion Polaris Sirius Andromeda Betelgeuse Cassiopeia Draco Pegasus Ursa Lyra Hydra Taurus Libra Virgo Gemini Scorpius Sagittarius Capricorn Aquarius Pisces Appalachia Baltic Caucasus Crimea Galilee Patagonia Savannah Tasmania Thessaly Tirol Zanzibar Aegean Appalachia Balkans Carpathians Dinarides Dolomites Jura Karakoram Kunlun Pamirs Pontic Rhodope Tian Urals Zagros Pyrenees Atlas Sierra K2 Annapurna Kangchenjunga Shasta Rainier Elbrus Kinabalu Mauna Montserrat Sunda Java Sumatra Borneo Newfoundlands Tasmania Madagascar Mallorca Greenland Corsica Crete Sardinia Maldives Bahamas Barbados Bermuda Fiji Samoa Tahiti Tonga Vanuatu Aruba Cayman Falkland Faroe Galápagos Canary Hawaii Kodiak Orkney Shetland Skye Mull Jura Capri Mykonos Rhodes Santorini Lesbos Ithaca Crete Malta Gozo Zanzibar Seychelles).uniq.group_by { |name| name[0] }.map { |k, v| v })

    property title : String
    property open : Bool = true
    getter id : String
    getter persistency : Persistency::Default
    property context : Persistency::Context

    @version : Int32? = nil
    @configurator : Table::VirtualTable::Configurator(Cell, BaseCell)? = nil
    @fieldlist : Table::Lazy::Fieldlist(FieldlistCell, Cell)? = nil
    getter fieldlist : Table::Lazy::Fieldlist(FieldlistCell, Cell)?
    @table_lid : TableLID? = nil
    @matrix_userdata_rc : Table::Lazy::Pivot::Hierarchic(Cell, BaseCell, FieldlistCell)? = nil
    @mirror_aggregates = true
    @commit_leaves = Array(CommitLID).new
    @commit_path = Array(CommitLID).new
    @commit_leaf_rank = -1
    @cursor_rc = {0, 0}
    @filter_state = [] of Table::Lazy::Filter::ColumnFilter

    getter filter_state : Array(Table::Lazy::Filter::ColumnFilter)

    def filter_add(column_index : Int32, values : Set(Cell) = Set(Cell).new) : Nil
        return if @filter_state.any? { |cf| cf.column_index == column_index }
        @filter_state << Table::Lazy::Filter::ColumnFilter.new(column_index, values)
        invalidate_filter
    end

    def filter_remove(column_index : Int32) : Nil
        @filter_state.reject! { |cf| cf.column_index == column_index }
        invalidate_filter
    end

    def filter_set_values(column_index : Int32, values : Set(Cell)) : Nil
        idx = @filter_state.index { |x| x.column_index == column_index }
        return unless idx
        # ColumnFilter is a struct — fetch, mutate, write back to actually persist
        cf = @filter_state[idx]
        cf.selected_values = values
        @filter_state[idx] = cf
        invalidate_filter
    end

    def filter_clear! : Nil
        return if @filter_state.empty?
        @filter_state = [] of Table::Lazy::Filter::ColumnFilter
        invalidate_filter
    end

    protected def invalidate_filter : Nil
        # Filter changed: rebuild just the pivot (new Partitioned view chain)
        # and swap it into the existing matrix_adapter — keeping the adapter
        # instance stable so the VirtualMatrix's binding isn't orphaned.
        cfg = @configurator
        fl = @fieldlist
        adapter = @matrix_adapter
        return unless cfg && fl && adapter
        vt = cfg.run
        @unfiltered_vt = vt
        filtered = Table::Lazy::Filter.apply(vt, @filter_state)
        new_rc = Table::Lazy::Pivot::Hierarchic(Cell, BaseCell, FieldlistCell).new(filtered, fl)
        @matrix_userdata_rc = new_rc
        adapter.matrix_rc = new_rc
    end

    getter widget_table_picker : GUI::Widget::TablePicker
    getter vhtree_adapter : SimpleVHTreeAdapter? = nil
    getter matrix_adapter : SimpleMatrixAdapter(Cell, BaseCell, FieldlistCell)? = nil
    getter fieldlist_adapter : FieldlistAdapter? = nil
    getter fieldlist_data : Table::Lazy::Fieldlist(FieldlistCell, Cell)? = nil
    def configurator_ref : Table::VirtualTable::Configurator(Cell, BaseCell)?
        @configurator
    end

    def initialize(@title : String, @persistency : Persistency::Default, @context : Context = Context.new, @table_lid : TableLID? = nil)
        @id = "shape_#{object_id}"
        # Pass @table_lid so callers (e.g. shape_add_for_table) that spawn a
        # Shape pre-selected on a specific table actually see that table —
        # otherwise the TablePicker defaulted to the prefill and @table_lid
        # was effectively ignored.
        @widget_table_picker = GUI::Widget::TablePicker.new(@persistency, @context, lid: @table_lid, allow_create: true, suppress_empty: true, prefill_table: true)
        update(true)
    end

    # Clone constructor for duplicating shapes
    protected def initialize(@title : String, other : ShapeState)
        @id = "shape_#{object_id}"
        @persistency = other.@persistency
        @context = other.@context.dup
        @widget_table_picker = GUI::Widget::TablePicker.new(@persistency, @context, lid: other.@table_lid, allow_create: true, suppress_empty: true, prefill_table: true)
        # Deep-copy filter state — duplicates start with the same filters but diverge on edit
        @filter_state = other.@filter_state.map(&.dup)
        if !other.@configurator.nil? && !other.@fieldlist.nil?
            @configurator = other.@configurator.not_nil!.clone(false)
            # Re-pin the cloned Configurator to THIS shape's context (not other's).
            @configurator.not_nil!.context = @context
            vt = @configurator.not_nil!.run
            @fieldlist = other.@fieldlist.not_nil!.clone(vt)
            setup_adapters(vt)
            # Copy user-adjusted column/row sizes from old adapter
            if old_adapter = other.@matrix_adapter
                if new_adapter = @matrix_adapter
                    new_adapter.custom_col_widths = old_adapter.custom_col_widths.try(&.dup)
                    new_adapter.custom_row_heights = old_adapter.custom_row_heights.try(&.dup)
                end
            end
        end
        update(true)
    end

    def dup_shape(newtitle : String) : ShapeState
        ShapeState.new(newtitle, self)
    end

    # Read-only diff marker. A diff-Shape is a view over the open commit's
    # pending writes; editing it makes no sense (would write on top of the
    # clamped view and confuse users). SimpleMatrixAdapter consults this.
    @readonly : Bool = false
    def readonly? : Bool; @readonly; end
    def mark_readonly_diff! : Nil; @readonly = true; end

    # Spawn a Shape whose matrix shows ONLY the cells modified in this Shape's
    # current open commit. Meta reads (records, fields, names, Rank) remain
    # fully visible so the matrix structure stays intact; net reads are clamped
    # to the single open commit so untouched cells render as nil.
    #
    # Returns nil if there's no open commit yet (fresh persistency).
    #
    # Semantics: diff-Shape is NOT context-clamped. Cells show their actual
    # values (including unchanged ones from earlier commits). Changed cells
    # get a coloured background in cell_paint. Optionally, rows are filtered
    # to records with writes at the target commit (default on; toggleable).
    # Fieldlist is normalized so each matrix row = one record (clean lookup).
    def spawn_diff_shape : ShapeState?
        open_commit = @context.current_commit
        return nil if open_commit == MetaFieldLIDs::RootCommit
        path = @persistency.get_commit_path(open_commit)
        return nil if path.size < 2
        parent_commit = path[-2]

        new_ctx = @context.clone
        diff = ShapeState.new("#{@title} ▸ diff", @persistency, new_ctx, @table_lid)
        diff.mark_readonly_diff!
        diff.diff_target_commit = open_commit
        diff.diff_parent_commit = parent_commit
        diff.fieldlist_normalize!    # detail view: Rank=Row, others=Aggregate
        diff.invalidate_filter
        diff.precompute_diff_state!(parent_commit)
        diff.apply_diff_record_filter!
        diff
    end

    # Diff state (set by spawn_diff_shape on the drilled instance).
    @diff_target_commit : CommitLID? = nil
    # Parent commit of @diff_target_commit, captured at spawn. Stable: even
    # if subsequent commits extend the chain, the diff stays "target vs its
    # original parent". Reused on auto-refresh.
    @diff_parent_commit : CommitLID? = nil
    @diff_show_changed_only : Bool = true
    getter diff_target_commit : CommitLID?
    getter diff_show_changed_only : Bool

    # Precomputed by spawn_diff_shape. Nil on non-diff-Shapes.
    # (row, col) matrix coordinates whose value at open differs from parent.
    @diff_changed_cells : Set({Int32, Int32})? = nil
    getter diff_changed_cells : Set({Int32, Int32})?
    # RecordLIDs with ≥1 changed cell (for the VT-level row filter).
    @diff_changed_records : Set(RecordLID)? = nil
    getter diff_changed_records : Set(RecordLID)?
    # Records present at parent but not at open — rendered as a sibling
    # "Records deleted" section below the matrix.
    @diff_deleted_records : Array({RecordLID, Hash(FieldLID, Cell)})? = nil
    getter diff_deleted_records : Array({RecordLID, Hash(FieldLID, Cell)})?
    # Parent-commit cell values, keyed by {RecordLID, FieldLID}. Missing key
    # ⇒ record didn't exist at parent. Enables a future editable diff-Shape
    # to recompute @diff_changed_cells in O(1) on each write.
    @diff_parent_values : Hash({RecordLID, FieldLID}, Cell)? = nil
    getter diff_parent_values : Hash({RecordLID, FieldLID}, Cell)?

    # Internal setter used by spawn_diff_shape to configure the freshly-created
    # diff-Shape. Not meant for general external use.
    protected def diff_target_commit=(c : CommitLID) : CommitLID
        @diff_target_commit = c
    end

    protected def diff_parent_commit=(c : CommitLID) : CommitLID
        @diff_parent_commit = c
    end

    def diff_show_changed_only=(v : Bool) : Bool
        @diff_show_changed_only = v
        apply_diff_record_filter!
        v
    end

    # When diff_target_commit is set and diff_show_changed_only is true, add
    # a ColumnFilter on the Rank pseudo-column (column 0 in the VT the pivot
    # sees) whose values are the ranks of the records in @diff_changed_records.
    # Remove the filter when toggled off. Idempotent.
    #
    # NOTE: the VT's user column 0 is Rank (1-based), not RecordLID — the
    # RecordLID pseudo-column isn't exposed as a user column. So we translate
    # the changed-records set to the 1-based ranks (positions in the table's
    # ordered record list at the open context).
    def apply_diff_record_filter! : Nil
        return unless @diff_target_commit
        return unless table_lid = @table_lid
        rank_filter_column = 0
        existing_idx = @filter_state.index { |cf| cf.column_index == rank_filter_column }
        if @diff_show_changed_only && (changed_records = @diff_changed_records)
            @persistency.contexts.push(@context)
            begin
                all_records = @persistency.get_record_lids(table_lid)
                ranks = Set(Cell).new
                all_records.each_with_index do |rec, idx|
                    ranks.add((idx + 1).to_i64.as(Cell)) if changed_records.includes?(rec)
                end
                if existing_idx
                    @filter_state[existing_idx] = Table::Lazy::Filter::ColumnFilter.new(rank_filter_column, ranks)
                else
                    @filter_state << Table::Lazy::Filter::ColumnFilter.new(rank_filter_column, ranks)
                end
            ensure
                @persistency.contexts.pop
            end
        else
            @filter_state.delete_at(existing_idx) if existing_idx
        end
        invalidate_filter
    end

    # Walk the open pivot once at spawn, compare each cell's value against the
    # parent-commit value for the same `(RecordLID, FieldLID)`, and populate
    # the four diff-state collections. Cost: O(F² + R·F) one-time at spawn.
    # After this runs, per-cell highlight lookup is O(1).
    #
    # Pre-conditions:
    # - spawn_diff_shape has already called fieldlist_normalize! + invalidate_filter,
    #   so @matrix_userdata_rc reflects the normalized fieldlist with an empty
    #   diff filter (i.e. all records visible).
    # - @diff_target_commit is set.
    # - @table_lid is set.
    def precompute_diff_state!(parent_commit : CommitLID) : Nil
        return unless table_lid = @table_lid
        return unless rc = @matrix_userdata_rc
        return unless @diff_target_commit

        parent_ctx = @context.clone
        parent_ctx.current_commit = parent_commit

        # The whole walk below reads rc and queries the persistency. rc.size,
        # rc[[r,c]], and hyperplane_get_name are all lazy and context-dependent:
        # reading them without the Shape's context on the stack returns stale /
        # empty results (exactly how the render path fails in SimpleMatrixAdapter
        # without the with_shape_context guard). Push once, pop at the end.
        @persistency.contexts.push(@context)
        begin
        row_count = rc.size[0]
        col_count = rc.size[1]

        # Fields and open records are resolved under the OPEN context — fields
        # may not yet exist at the parent commit (e.g. a freshly-loaded demo
        # writes all fields into commit 1, leaving commit 0 / root empty).
        # Record existence is queried at both contexts independently: records
        # at parent drive the rank map + deleted-set, records at open drive
        # the walk and the lookup into open_records.
        @persistency.contexts.push(@context)
        begin
            open_records = @persistency.get_record_lids(table_lid).dup
            open_field_lids = @persistency.get_field_lids(table_lid).dup
        ensure
            @persistency.contexts.pop
        end

        @persistency.contexts.push(parent_ctx)
        begin
            parent_records = @persistency.get_record_lids(table_lid).dup
        ensure
            @persistency.contexts.pop
        end
        parent_rank_map = Hash(RecordLID, Int32).new
        parent_records.each_with_index { |r, i| parent_rank_map[r] = i + 1 }
        parent_record_set = parent_records.to_set

        # Deleted records: in parent, not in open. Read their last-known field
        # values under parent context so the rendering layer has everything it
        # needs without re-querying.
        open_record_set = open_records.to_set
        deleted = [] of {RecordLID, Hash(FieldLID, Cell)}
        @persistency.contexts.push(parent_ctx)
        begin
            # For deleted-record field values, walk the fields that existed at
            # parent. If parent's field list is empty (e.g. root commit before
            # anything was defined), fall back to open's — those are the fields
            # the diff-Shape renders in its matrix anyway.
            parent_fields_for_deleted = @persistency.get_field_lids(table_lid)
            parent_fields_for_deleted = open_field_lids if parent_fields_for_deleted.empty?
            parent_records.each do |r|
                next if open_record_set.includes?(r)
                vals = Hash(FieldLID, Cell).new
                parent_fields_for_deleted.each do |f|
                    vals[f] = @persistency.get_value(f, r)
                end
                deleted << {r, vals}
            end
        ensure
            @persistency.contexts.pop
        end

        # Column → FieldLID map + detection of the Rank pseudo-column.
        # Built once; used as O(1) lookup during the cell walk.
        # Uses a "name scan" approach, but only F² times (not F² × R × F):
        # once per column rather than once per cell.
        col_to_field = Hash(Int32, FieldLID).new
        rank_col : Int32? = nil
        if row_count >= 2
            @persistency.contexts.push(@context)
            begin
                col_count.times do |col|
                    name = rc.hyperplane_get_name(1, [1, col])
                    next if name.empty?
                    if name == "Rank"
                        rank_col = col
                        next
                    end
                    field_lid = open_field_lids.find { |f|
                        @persistency.get_value(MetaFieldLIDs::Names, f) == name
                    }
                    col_to_field[col] = field_lid if field_lid
                end
            ensure
                @persistency.contexts.pop
            end
        end

        changed_cells = Set({Int32, Int32}).new
        changed_records = Set(RecordLID).new
        parent_values = Hash({RecordLID, FieldLID}, Cell).new

        # Walk the open pivot. In the normalized detail view
        # (fieldlist_normalize! sets Rank=Row, everything else Aggregate),
        # each row corresponds to one rank value. There is no dedicated
        # column-header row — the Rank column carries {true, _} in
        # get_header_info (it's a row-label) while data cols carry nil.
        # Use the rank column's VALUE as the lookup into open_records
        # (rank 1 ⇒ open_records[0], etc.) rather than row-index-minus-one;
        # that's robust to whether a column-header row is synthesized.
        probe_col = col_to_field.keys.first? || 0
        (0...row_count).each do |row|
            # Skip genuine column-header rows (those where a non-rank cell
            # reports header-info truthy). Data rows report nil for those.
            next if rc.get_header_info([row, probe_col])
            next unless rc_col = rank_col
            rank_raw = rc[[row, rc_col]]
            rank_i : Int32 = case rank_raw
                when Int32 then rank_raw - 1
                when Int64 then (rank_raw - 1).to_i32
                else next
                end
            next if rank_i < 0 || rank_i >= open_records.size
            record_lid = open_records[rank_i].as(RecordLID)
            parent_has_record = parent_record_set.includes?(record_lid)

            (0...col_count).each do |col|
                if col == rank_col
                    value_open = (rank_i + 1).to_i64
                    value_parent = parent_rank_map[record_lid]?.try &.to_i64
                    if value_open != value_parent
                        changed_cells.add({row, col})
                        changed_records.add(record_lid)
                    end
                elsif field_lid = col_to_field[col]?
                    @persistency.contexts.push(@context)
                    value_open = begin
                        @persistency.get_value(field_lid, record_lid)
                    ensure
                        @persistency.contexts.pop
                    end
                    if parent_has_record
                        @persistency.contexts.push(parent_ctx)
                        value_parent = begin
                            @persistency.get_value(field_lid, record_lid)
                        ensure
                            @persistency.contexts.pop
                        end
                        parent_values[{record_lid, field_lid}] = value_parent
                    else
                        value_parent = nil
                    end
                    if value_open != value_parent
                        changed_cells.add({row, col})
                        changed_records.add(record_lid)
                    end
                end
                # Columns we can't map to a FieldLID (e.g. rank_col was nil;
                # unknown aggregate columns) are left unannotated — safer than
                # marking them changed by accident.
            end
        end

        @diff_changed_cells = changed_cells
        @diff_changed_records = changed_records
        @diff_deleted_records = deleted
        @diff_parent_values = parent_values
        ensure
            @persistency.contexts.pop
        end
    end

    def close
        @open = false
    end

    # === History ===

    def commit_leaves : Array(CommitLID)
        @commit_leaves
    end

    def commit_path : Array(CommitLID)
        @commit_path
    end

    def commit_leaf_rank : Int32
        @commit_leaf_rank
    end

    def branch_names : Array(String)
        BRANCH_TIPS_NAMES[0...@commit_leaves.size]
    end

    def current_commit_index : Int32
        return 0 if @commit_path.empty?
        @persistency.contexts.push(@context)
        idx = @commit_path.index(@persistency.context.current_commit) || 0
        @persistency.contexts.pop
        idx
    end

    def is_last_commit? : Bool
        current_commit_index == @commit_path.size - 1
    end

    def navigate_history(delta : Int32) : Nil
        @persistency.contexts.push(@context)
        commit_index = @commit_path.index!(@persistency.context.current_commit)
        new_index = (commit_index + delta).clamp(0, @commit_path.size - 1)
        if new_index != commit_index
            @persistency.context.current_commit = @commit_path[new_index]
            @context = @persistency.contexts.pop
            update(true)
        else
            @context = @persistency.contexts.pop
        end
    end

    def select_branch(index : Int32) : Nil
        @persistency.contexts.push(@context)
        @persistency.context.current_commit = @commit_leaves[index]
        @commit_leaf_rank = index
        @context = @persistency.contexts.pop
        update(true)
    end

    # Commit the open commit. If defer_tables is non-empty, writes for those
    # tables are floated to the new open commit (selective commit) — only the
    # checked tables' writes land in the commit being closed.
    def do_commit(defer_tables : Set(TableLID) = Set(TableLID).new) : Nil
        @persistency.contexts.push(@context)
        closing = @persistency.context.current_commit
        @persistency.close_and_add_commit
        new_open = @persistency.context.current_commit
        unless defer_tables.empty?
            @persistency.float_writes(from: closing, to: new_open, defer_tables: defer_tables)
        end
        @context = @persistency.contexts.pop
        update
    end

    # === Table selection ===

    def table_changed? : Bool
        @widget_table_picker.changed?
    end

    # === Data operations ===

    def add_record : Nil
        if mrc = @matrix_userdata_rc
            @persistency.contexts.push(@context)
            mrc.hyperplane_add(0)
            @context = @persistency.contexts.pop
        end
    end

    def add_field_simple : Nil
        if mrc = @matrix_userdata_rc
            @persistency.contexts.push(@context)
            mrc.hyperplane_add(1)
            @context = @persistency.contexts.pop
        end
    end

    def add_field_custom(name : String, ref_field_lid : FieldLID? = nil) : Nil
        if mrc = @matrix_userdata_rc
            @persistency.contexts.push(@context)
            mrc.hyperplane_add(1, name: name, refers_to_field_lid: ref_field_lid)
            @context = @persistency.contexts.pop
        end
    end

    # === Fieldlist operations ===

    def fieldlist_empty! : Nil
        @fieldlist.not_nil!.empty! if @fieldlist
    end

    def fieldlist_normalize! : Nil
        @fieldlist.not_nil!.normalize! if @fieldlist
    end

    def fieldlist_mirror_horizontal! : Nil
        if fl = @fieldlist
            fl.mirror_horizontal_header!
            fl.mirror_horizontal_aggregate! if @mirror_aggregates
        end
    end

    def fieldlist_mirror_vertical! : Nil
        if fl = @fieldlist
            fl.mirror_vertical_header!
            fl.mirror_vertical_aggregate! if @mirror_aggregates
        end
    end

    def fieldlist_mirror_diagonal! : Nil
        if fl = @fieldlist
            fl.mirror_diagonal_header!
            fl.mirror_diagonal_aggregate! if @mirror_aggregates
        end
    end

    property mirror_aggregates : Bool

    # === VHTree helpers (for building tree in UI) ===

    def dfs_tree(&block : Interface::GUI::VHTreeAdapter, Int32 ->)
        if adapter = @vhtree_adapter
            dfs(adapter, &block)
        end
    end

    private def dfs(node : Interface::GUI::VHTreeAdapter, level = 0, &block : Interface::GUI::VHTreeAdapter, Int32 ->)
        yield(node, level)
        list = Array(Interface::GUI::VHTreeAdapter).new
        node.each { |c| list << c }
        list.each do |child|
            dfs(child, level + 1, &block)
        end
    end

    # === Context Menu Support ===

    def get_table_lid_for_field(node : Interface::GUI::VHTreeAdapter) : TableLID?
        # A field node's parent is a table node in the configurator tree
        if (field_lid = node.field_lid) && (configurator = @configurator)
            # Walk the configurator tree to find which table this field belongs to
            result = nil.as(TableLID?)
            dfs_find_parent_table(configurator.tree, field_lid) do |parent_table_lid|
                result = parent_table_lid
            end
            result
        else
            nil
        end
    end

    private def dfs_find_parent_table(tree_node : Table::VirtualTable::Tree, target_field_lid : FieldLID, &block : TableLID ->)
        tree_node.each do |_, child|
            v = child.value
            if v.is_a?(FieldLID) && v == target_field_lid
                # This child is the field - parent's value should be a TableLID
                pv = tree_node.value
                yield pv.as(TableLID) if pv.is_a?(TableLID)
                return
            end
            dfs_find_parent_table(child, target_field_lid, &block)
        end
    end

    # === Internal ===

    def update(force_update = false) : Nil
        @persistency.contexts.push(@context)
        new_table = @widget_table_picker.changed?
        version = @persistency.version + @persistency.context.version
        if force_update || new_table || (@version != version)
            # update branching information
            current_commit = @persistency.context.current_commit
            new_branch = false
            leaf = current_commit
            if @commit_path.index(leaf)
                leaf = @commit_path[-1]  # Current commit is in path → use path's leaf (stay on branch)
            else
                new_branch = true
            end
            @commit_leaves = @persistency.get_ordered_commit_leaves
            if leaf = @persistency.get_leaf(leaf)
                @commit_leaf_rank = @commit_leaves.index!(leaf)
            else
                @commit_leaf_rank = 0
                leaf = @commit_leaves[0]
            end
            @commit_path = @persistency.get_commit_path(leaf)
            if new_branch
                @persistency.context.current_commit = @commit_leaves[@commit_leaf_rank]
            end
            @table_lid = @widget_table_picker.lid
            if table_lid = @table_lid
                # Set up adapters when the user picked a different table (new_table),
                # OR on first-run of this Shape (@configurator still nil — e.g. the
                # constructor passed an explicit table_lid that the picker reported
                # as "not changed" because it was set at construction time).
                if new_table || @configurator.nil?
                    # Pin the Configurator to this Shape's context so meta reads
                    # (post-commit / history navigation / deferred-table float)
                    # always use this Shape's view regardless of what's on the
                    # global context stack.
                    configurator = Table::VirtualTable::Configurator(Cell, BaseCell).new(@persistency, table_lid, @context)
                    configurator.toggle_select(configurator.tree)
                    vt = configurator.run
                    @configurator = configurator
                    @fieldlist = Table::Lazy::Fieldlist(FieldlistCell, Cell).new(vt)
                    setup_adapters(vt)
                end
            else
                @vhtree_adapter = nil
                @matrix_adapter = nil
                @fieldlist_adapter = nil
                @matrix_userdata_rc = nil
            end
            @version = version
            # Invalidate matrix adapter so VirtualMatrix refreshes cached cells
            @matrix_adapter.try &.invalidate_all!
            # Diff-Shape: refresh the precomputed diff state and row filter so
            # edits made elsewhere (in another shape, on the same open commit)
            # are reflected. Cheap: O(R·F) on the diff-Shape's table only.
            refresh_diff_state! if @diff_target_commit
        end
        @context = @persistency.contexts.pop
    end

    # Re-run precompute_diff_state! against the cached parent commit and
    # re-apply the row filter. Strips any prior diff filter first so
    # precompute walks the unfiltered pivot (matches spawn-time order).
    private def refresh_diff_state! : Nil
        return unless parent_commit = @diff_parent_commit
        rank_filter_idx = @filter_state.index { |cf| cf.column_index == 0 }
        if rank_filter_idx
            @filter_state.delete_at(rank_filter_idx)
            invalidate_filter
        end
        precompute_diff_state!(parent_commit)
        apply_diff_record_filter!
    end

    private def setup_adapters(vt : Table::Lazy::Raw::Base(Cell))
        # Fieldlist sees the unfiltered VirtualTable (column schema is not affected
        # by row filters); Pivot sees the filtered view so the matrix shows fewer rows.
        @unfiltered_vt = vt
        filtered = Table::Lazy::Filter.apply(vt, @filter_state)
        @matrix_userdata_rc = Table::Lazy::Pivot::Hierarchic(Cell, BaseCell, FieldlistCell).new(filtered, @fieldlist.not_nil!)
        if configurator = @configurator
            @vhtree_adapter = SimpleVHTreeAdapter.new(configurator, @context)
        end
        @matrix_adapter = SimpleMatrixAdapter(Cell, BaseCell, FieldlistCell).new(@matrix_userdata_rc.not_nil!, @persistency, self)
        @fieldlist_adapter = FieldlistAdapter.new(@fieldlist.not_nil!)
    end

    @unfiltered_vt : Table::Lazy::Raw::Base(Cell)? = nil
    getter unfiltered_vt : Table::Lazy::Raw::Base(Cell)?
    getter matrix_userdata_rc : Table::Lazy::Pivot::Hierarchic(Cell, BaseCell, FieldlistCell)?

    # Build a new Shape representing the drill-down of a Drilldown cell.
    # Returns nil if the cell isn't Drilldown (or the shape has no pivot yet).
    # The drilled shape is a "detail view" of the basic rows under the cell:
    #   - Fieldlist normalized (Rank=Row, others=Aggregate) so the user sees
    #     one matrix row per basic row, not a re-pivoted aggregate.
    #   - Cluster {column → value} pairs from the cell added as filters so
    #     exactly those basic rows are visible.
    # If the cell has no clusters (no row/col header in the parent pivot), drill
    # still succeeds — new shape is a flat view of the same rows, which is
    # still useful (e.g. "#15" becomes 15 visible rows).
    def drill_from_cell(index : {Int32, Int32}) : ShapeState?
        rc = @matrix_userdata_rc
        return nil unless rc
        return nil unless rc.get_assignability(index.to_a) == Table::Lazy::Pivot::Assignability::Drilldown
        clusters = rc.get_cell_clusters(index.to_a)
        new_shape = dup_shape("#{@title} ▸ drill")
        new_shape.fieldlist_normalize!
        clusters.each do |col_idx, value_rank|
            value = value_rank[0].as(Cell)
            values = Set{value}
            if new_shape.filter_state.any? { |cf| cf.column_index == col_idx }
                new_shape.filter_set_values(col_idx, values)
            else
                new_shape.filter_add(col_idx, values)
            end
        end
        # Fieldlist change alone doesn't touch filter_state, so invalidate_filter
        # wasn't triggered — force a matrix refresh so the adapter picks up the
        # normalized pivot even in the empty-cluster case.
        new_shape.matrix_adapter.try &.invalidate_all!
        new_shape
    end

    # Column names of the underlying VirtualTable (unfiltered). Used by the Filter UI
    # to show column choices and label per-filter rows. O(num_columns).
    def column_names : Array(String)
        vt = @unfiltered_vt
        return [] of String unless vt
        n = vt.size[1]
        (0...n).map { |c| vt.hyperplane_get_name(1, [0, c]) }
    end

    # Distinct values appearing in a column of the unfiltered VirtualTable, with their
    # counts. O(rows) via Partitioned. Used by the Filter UI's value picker.
    def column_distinct_values(column_index : Int32) : Array({Cell, Int32})
        vt = @unfiltered_vt
        return [] of {Cell, Int32} unless vt
        part = Table::Lazy::Raw::Partitioned(Cell).new(vt, 0, column_index)
        part.keys.map { |k| {k, part.get_selection(k).size} }
    end
end
