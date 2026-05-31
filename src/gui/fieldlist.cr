# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../persistency"
require "crymble-ui"

# Fieldlist constants and adapter interface
# The widget implementation is in shape.cr as part of the CrymbleUI build tree.

module GUI::Widget::FieldlistConstants
    enum ColumnIndices
        Rank            # -> Int64
        Class           # -> RowClass
        Level           # -> Int64
        SortAscending   # -> Bool
        Name            # -> String
    end
    enum RowClass
        Unused
        ColumnHeader
        RowHeader
        Aggregate
    end
end

module Interface::GUI::FieldlistAdapter(T)
    include ::GUI::Widget::FieldlistConstants
    alias Index = {Int32, ColumnIndices}
    abstract def version : Int32
    abstract def size : Int32 # #rows
    abstract def cell_read(index : Index) : T | RowClass
    abstract def cell_assign(index : Index, value : T | RowClass) : Nil
end

# Drag data for fieldlist fields (payload = adapter row index)
class FieldDragData < CrymbleUI::DragData
    getter row_index : Int32

    def initialize(@row_index : Int32, @display : String)
    end

    def data_type : String
        "fieldlist_field"
    end

    def display_text : String?
        @display
    end
end

# Thin horizontal or vertical spacer bar for visual separation in the fieldlist grid
# Spacer widget with optional horizontal/vertical bars for visual separation
class FieldlistSpacer < CrymbleUI::Widget
    include CrymbleUI::PrimitiveBuilder

    def spacer_color; CrymbleUI::Theme.current["fieldlist.spacer"]; end
    def bg_color; CrymbleUI::Theme.current.panel_background; end
    MIN_SIZE     = 8.0
    BAR_WIDTH    = 4.0

    def initialize(@horizontal : Bool = false, @vertical : Bool = false)
        super(id: nil)
    end

    def measure(constraints : CrymbleUI::BoxConstraints) : CrymbleUI::Size
        constraints.constrain(CrymbleUI::Size.new(MIN_SIZE, MIN_SIZE))
    end

    def perform_layout(constraints : CrymbleUI::BoxConstraints, position : CrymbleUI::Vec2)
        size = measure(constraints)
        @bounds = CrymbleUI::Rect.new(position, size)
    end

    def to_primitives(bounds : CrymbleUI::Rect) : Array(CrymbleUI::DrawPrimitive)
        primitives do
            # Fill entire spacer area to prevent panel background bleed-through
            fill_rect(CrymbleUI::Rect.new(0.0, 0.0, bounds.width, bounds.height), bg_color)
            if @horizontal
                y = (bounds.height - BAR_WIDTH) / 2.0
                fill_rect(CrymbleUI::Rect.new(0.0, y, bounds.width, BAR_WIDTH), spacer_color)
            end
            if @vertical
                x = (bounds.width - BAR_WIDTH) / 2.0
                fill_rect(CrymbleUI::Rect.new(x, 0.0, BAR_WIDTH, bounds.height), spacer_color)
            end
        end
    end
end

# Module mixin: gives fieldlist build methods access to CrymbleUI::App DSL
# (text, widget, request_rebuild, etc.) when included into EmbraceApp.
module FieldlistGrid
    # --- Theme-aware colors (from JSON extensible tokens) ---
    private def fl_col_bg;   CrymbleUI::Theme.current["fieldlist.col_bg"]; end
    private def fl_row_bg;   CrymbleUI::Theme.current["fieldlist.row_bg"]; end
    private def fl_free_bg;  CrymbleUI::Theme.current["fieldlist.free_bg"]; end
    private def fl_agg_bg;   CrymbleUI::Theme.current["fieldlist.agg_bg"]; end
    private def fl_drag_hl;  CrymbleUI::Theme.current["fieldlist.drag_hl"]; end
    private def fl_spacer;   CrymbleUI::Theme.current["fieldlist.spacer"]; end

    # Slightly shift a color for even-level distinction
    private def fl_shift_color(base : CrymbleUI::Color, level : Int32) : CrymbleUI::Color
        return base if level.even?
        CrymbleUI::Color.new(
            (base.r.to_i + 15).clamp(0, 255).to_u8,
            (base.g.to_i + 15).clamp(0, 255).to_u8,
            (base.b.to_i + 15).clamp(0, 255).to_u8,
            base.a
        )
    end

    # Field data extracted from adapter for grid building
    private record FieldInfo, ri : Int32, name : String, row_class : GUI::Widget::FieldlistConstants::RowClass, level : Int32, rank : Int32, sort_ascending : Bool

    # Convert CamelCase field name to space-separated display name
    # e.g. "PersonTimeProjectAllocation" → "Person Time Project Allocation"
    private def display_name(name : String) : String
        name.gsub(/(?<=[a-z])(?=[A-Z])/, " ")
    end

    private def build_fieldlist_grid(shape : ShapeState, adapter : FieldlistAdapter) : Nil
        num_rows = adapter.size

        if num_rows == 0
            text("(empty fieldlist)")
            return
        end

        # Read all fields from adapter
        fields = (0...num_rows).map do |ri|
            name = adapter.cell_read({ri, GUI::Widget::FieldlistConstants::ColumnIndices::Name}).to_s
            row_class = adapter.cell_read({ri, GUI::Widget::FieldlistConstants::ColumnIndices::Class}).as(GUI::Widget::FieldlistConstants::RowClass)
            level = adapter.cell_read({ri, GUI::Widget::FieldlistConstants::ColumnIndices::Level}).as(Int64).to_i
            rank = adapter.cell_read({ri, GUI::Widget::FieldlistConstants::ColumnIndices::Rank}).as(Int64).to_i
            sort_val = adapter.cell_read({ri, GUI::Widget::FieldlistConstants::ColumnIndices::SortAscending})
            is_asc = sort_val == true || sort_val == 1_i64
            FieldInfo.new(ri: ri, name: name, row_class: row_class, level: level, rank: rank, sort_ascending: is_asc)
        end

        # Max level from col/row fields only (+ 1 extra empty level for expansion)
        max_level = fields.select { |f|
            f.row_class.column_header? || f.row_class.row_header?
        }.max_of?(&.level) || -1

        # Build inside-out: start with aggregates, then wrap each level
        inner = build_fl_aggregates(shape, adapter, fields)
        (max_level + 1).downto(0) do |lvl|
            inner = build_fl_level(shape, adapter, fields, lvl, inner, max_level)
        end

        widget(inner)
    end

    # Build the aggregates section as nested RecursiveGrid.
    # Outer grid: Nx1 (one row per level). Each cell: inner RecursiveGrid with that level's fields.
    # Column alignment across levels via unified measurement in RecursiveGrid.
    private def build_fl_aggregates(shape : ShapeState, adapter : FieldlistAdapter, fields : Array(FieldInfo)) : CrymbleUI::Widget
        agg_fields = fields.select(&.row_class.aggregate?).sort_by(&.rank)

        if agg_fields.empty?
            return build_fl_section("Aggregates", agg_fields, fl_agg_bg, shape, adapter,
                GUI::Widget::FieldlistConstants::RowClass::Aggregate, 0, show_sort: false)
        end

        # Group by level
        lines = Hash(Int32, Array(FieldInfo)).new { |h, k| h[k] = [] of FieldInfo }
        agg_fields.each { |f| lines[f.level] << f }
        sorted_levels = lines.keys.sort
        outer_level = sorted_levels.last + 1

        # Build each level as its own inner RecursiveGrid (single row of fields + trailing)
        outer_rows = sorted_levels.map do |level|
            line_fields = lines[level]
            insert_rank = line_fields.last.rank + 1

            cells = line_fields.map do |field|
                field_handler = make_fl_drop_handler(adapter, shape,
                    GUI::Widget::FieldlistConstants::RowClass::Aggregate, field.level, field.rank)

                drop_zone = CrymbleUI::DropZoneBox.new(
                    accept_types: ["fieldlist_field"],
                    on_drop_handler: field_handler,
                    background_color: fl_agg_bg,
                    hover_color: fl_drag_hl,
                )

                drag_data = FieldDragData.new(field.ri, field.name)
                draggable = CrymbleUI::DraggableBox.new(drag_data)
                padded = CrymbleUI::HStack.new(padding: 3.0)
                padded.add_child(CrymbleUI::Text.new(display_name(field.name), font_scale: -1))
                draggable.add_child(padded)
                drop_zone.add_child(draggable)
                drop_zone.hover_text = "Aggregates block"

                drop_zone.as(CrymbleUI::Widget)
            end

            # Trailing drop target for appending to this level
            line_handler = make_fl_drop_handler(adapter, shape,
                GUI::Widget::FieldlistConstants::RowClass::Aggregate, level, insert_rank)
            trailing = CrymbleUI::DropZoneBox.new(
                accept_types: ["fieldlist_field"],
                on_drop_handler: line_handler,
                background_color: nil,
                hover_color: fl_drag_hl,
            )
            trailing.add_child(CrymbleUI::Text.new("  ", font_scale: -1))
            trailing.hover_text = "Aggregates block"
            cells << trailing.as(CrymbleUI::Widget)

            # Wrap this level's cells in its own RecursiveGrid (single row)
            inner_grid = CrymbleUI::RecursiveGrid.new(content: [cells], spacing: 4.0)
            [inner_grid.as(CrymbleUI::Widget)]
        end

        # Trailing empty row (drop target to create new level)
        empty_handler = make_fl_drop_handler(adapter, shape,
            GUI::Widget::FieldlistConstants::RowClass::Aggregate, outer_level, 0)
        empty_cell = CrymbleUI::DropZoneBox.new(
            accept_types: ["fieldlist_field"],
            on_drop_handler: empty_handler,
            background_color: nil,
            hover_color: fl_drag_hl,
        )
        empty_cell.add_child(CrymbleUI::Text.new("  ", font_scale: -1))
        empty_cell.hover_text = "Aggregates block"
        trailing_grid = CrymbleUI::RecursiveGrid.new(content: [[empty_cell.as(CrymbleUI::Widget)]], spacing: 4.0)
        outer_rows << [trailing_grid.as(CrymbleUI::Widget)]

        # Outer grid: Nx1 — each row is a single-column cell containing a level's inner grid
        CrymbleUI::RecursiveGrid.new(content: outer_rows, spacing: 4.0)
    end

    # Build a single level as a 3x3 RecursiveGrid:
    #   [TL]        [v_spacer] [Columns]
    #   [h_spacer]  [cross]    [h_spacer]
    #   [Rows]      [v_spacer] [inner]
    private def build_fl_level(shape : ShapeState, adapter : FieldlistAdapter, fields : Array(FieldInfo),
                               level : Int32, inner : CrymbleUI::Widget, max_level : Int32) : CrymbleUI::Widget
        col_fields = fields.select { |f| f.row_class.column_header? && f.level == level }.sort_by(&.rank)
        row_fields = fields.select { |f| f.row_class.row_header? && f.level == level }.sort_by(&.rank)

        col_bg = fl_shift_color(fl_col_bg, level)
        row_bg = fl_shift_color(fl_row_bg, level)

        # Top-left: Unused at level 0, empty label otherwise
        tl = if level == 0
            free_fields = fields.select(&.row_class.unused?).sort_by(&.rank)
            build_fl_section("Unused", free_fields, fl_free_bg, shape, adapter,
                GUI::Widget::FieldlistConstants::RowClass::Unused, 0, show_sort: false)
        else
            # Empty placeholder at non-zero levels (no bars, just occupies minimum space)
            FieldlistSpacer.new(horizontal: false, vertical: false)
        end

        columns_section = build_fl_section("Columns L#{level}", col_fields, col_bg, shape, adapter,
            GUI::Widget::FieldlistConstants::RowClass::ColumnHeader, level)
        rows_section = build_fl_section("Rows L#{level}", row_fields, row_bg, shape, adapter,
            GUI::Widget::FieldlistConstants::RowClass::RowHeader, level)

        # Spacers with oriented bars (matching demo SpacerWidget)
        h_spacer1 = FieldlistSpacer.new(horizontal: true, vertical: false)
        h_spacer2 = FieldlistSpacer.new(horizontal: true, vertical: false)
        v_spacer1 = FieldlistSpacer.new(horizontal: false, vertical: true)
        v_spacer2 = FieldlistSpacer.new(horizontal: false, vertical: true)
        cross     = FieldlistSpacer.new(horizontal: true, vertical: true)

        content = [
            [tl.as(CrymbleUI::Widget), v_spacer1.as(CrymbleUI::Widget), columns_section.as(CrymbleUI::Widget)],
            [h_spacer1.as(CrymbleUI::Widget), cross.as(CrymbleUI::Widget), h_spacer2.as(CrymbleUI::Widget)],
            [rows_section.as(CrymbleUI::Widget), v_spacer2.as(CrymbleUI::Widget), inner.as(CrymbleUI::Widget)],
        ]

        CrymbleUI::RecursiveGrid.new(content: content, spacing: 2.0)
    end

    # Build a section: outer DropZoneBox (append catch-all) with per-cell DropZoneBoxes inside
    # Uses RecursiveGrid for field rows (aligns checkboxes) inside VStack (prevents stretching)
    # show_sort: false for Unused/Aggregate sections (no sort checkmarks)
    private def build_fl_section(label : String, section_fields : Array(FieldInfo), bg : CrymbleUI::Color,
                                 shape : ShapeState, adapter : FieldlistAdapter,
                                 target_class : GUI::Widget::FieldlistConstants::RowClass,
                                 target_level : Int32, show_sort : Bool = true) : CrymbleUI::Widget
        insert_rank = section_fields.empty? ? 0 : section_fields.last.rank + 1
        outer_handler = make_fl_drop_handler(adapter, shape, target_class, target_level, insert_rank)

        # Hover info string
        section_info = case target_class
            when GUI::Widget::FieldlistConstants::RowClass::Aggregate    then "Aggregates block"
            when GUI::Widget::FieldlistConstants::RowClass::Unused       then "Unused block"
            when GUI::Widget::FieldlistConstants::RowClass::ColumnHeader then "Columns cluster block, level #{target_level + 1}"
            when GUI::Widget::FieldlistConstants::RowClass::RowHeader    then "Rows cluster block, level #{target_level + 1}"
            else label
            end

        content_widget = if section_fields.empty?
            # Empty sections: minimum-size placeholder for meaningful natural size
            min_cell = CrymbleUI::HStack.new(padding: 3.0)
            min_cell.add_child(CrymbleUI::Text.new("      ", font_scale: -1))
            min_cell.as(CrymbleUI::Widget)
        else
            # Build field rows as RecursiveGrid: each row = [DropZone>Draggable>Text, Checkbox]
            rows = section_fields.map do |field|
                field_handler = make_fl_drop_handler(adapter, shape, target_class, target_level, field.rank)
                drop_zone = CrymbleUI::DropZoneBox.new(
                    accept_types: ["fieldlist_field"],
                    on_drop_handler: field_handler,
                    background_color: nil,
                    hover_color: fl_drag_hl,
                )

                drag_data = FieldDragData.new(field.ri, field.name)
                draggable = CrymbleUI::DraggableBox.new(drag_data)
                name_text = CrymbleUI::Text.new(display_name(field.name), font_scale: -1)
                draggable.add_child(name_text)
                drop_zone.add_child(draggable)
                drop_zone.hover_text = section_info

                if show_sort
                    # Sort checkbox
                    captured_ri = field.ri
                    captured_asc = field.sort_ascending
                    sort_cb = CrymbleUI::Checkbox.new(
                        "",
                        checked: field.sort_ascending,
                        font_scale: -2,
                        box_scale: -1,
                    ) do
                        adapter.cell_assign({captured_ri, GUI::Widget::FieldlistConstants::ColumnIndices::SortAscending}, !captured_asc)
                        request_rebuild
                    end
                    sort_cb.hover_text = "#{section_info}, sort ascending?"
                    [drop_zone.as(CrymbleUI::Widget), sort_cb.as(CrymbleUI::Widget)]
                else
                    [drop_zone.as(CrymbleUI::Widget)]
                end
            end

            # VStack with background color — no wrapper needed so Expanded gets tight height
            grid = CrymbleUI::RecursiveGrid.new(content: rows, spacing: 4.0)
            vs = CrymbleUI::VStack.new(padding: 4.0, spacing: 2.0, background_color: bg)
            vs.add_child(grid)

            # Trailing drop zone for appending — fills remaining vertical+horizontal space
            append_handler = make_fl_drop_handler(adapter, shape, target_class, target_level, insert_rank)
            append_drop = CrymbleUI::DropZoneBox.new(
                accept_types: ["fieldlist_field"],
                on_drop_handler: append_handler,
                background_color: nil,
                hover_color: fl_drag_hl,
            )
            append_drop.add_child(CrymbleUI::Text.new("  ", font_scale: -1))
            append_drop.hover_text = section_info
            # Expanded in VStack fills remaining vertical space
            expanded_append = CrymbleUI::Expanded.new(fill_area: true)
            expanded_append.add_child(append_drop)
            vs.add_child(expanded_append)

            vs.as(CrymbleUI::Widget)
        end

        if section_fields.empty?
            # Empty sections: DropZoneBox as catch-all drop target
            section_drop = CrymbleUI::DropZoneBox.new(
                accept_types: ["fieldlist_field"],
                on_drop_handler: outer_handler,
                background_color: bg,
                hover_color: fl_drag_hl,
            )
            section_drop.add_child(content_widget)
            section_drop.hover_text = section_info
            section_drop
        else
            # Non-empty: content_widget already has background_color set
            content_widget
        end
    end

    # Create a drop handler that moves a field to the target section/position
    private def make_fl_drop_handler(adapter : FieldlistAdapter, shape : ShapeState,
                                     target_class : GUI::Widget::FieldlistConstants::RowClass,
                                     target_level : Int32,
                                     insert_rank : Int32) : Proc(CrymbleUI::DragData, CrymbleUI::Vec2, Nil)
        ->(data : CrymbleUI::DragData, _pos : CrymbleUI::Vec2) {
            if data.is_a?(FieldDragData)
            source_ri = data.row_index
            old_class = adapter.cell_read({source_ri, GUI::Widget::FieldlistConstants::ColumnIndices::Class})
            old_level = adapter.cell_read({source_ri, GUI::Widget::FieldlistConstants::ColumnIndices::Level}).as(Int64).to_i
            old_rank = adapter.cell_read({source_ri, GUI::Widget::FieldlistConstants::ColumnIndices::Rank}).as(Int64).to_i

            rank_target = insert_rank
            # When moving from a different section, adjust rank if source was before target
            if {old_class, old_level.to_i64} != {target_class, target_level.to_i64}
                rank_target -= 1 if old_rank < rank_target
            end

            adapter.cell_assign({source_ri, GUI::Widget::FieldlistConstants::ColumnIndices::Class}, target_class)
            adapter.cell_assign({source_ri, GUI::Widget::FieldlistConstants::ColumnIndices::Level}, target_level.to_i64)
            adapter.cell_assign({source_ri, GUI::Widget::FieldlistConstants::ColumnIndices::Rank}, rank_target.to_i64) # must be last
            request_rebuild
            end
        }
    end
end
