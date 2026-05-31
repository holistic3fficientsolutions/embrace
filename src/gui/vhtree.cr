# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../patch"
require "crymble-ui"

# VHTree adapter interface
# The implementation is in shape.cr (SimpleVHTreeAdapter).
# The widget rendering is in embrace.cr (build_vhtree method).

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
    abstract def field_lid : Persistency::FieldLID?
    abstract def table_lid : Persistency::TableLID?
end

# VHTree 2D columnar layout widget
# Positions children in a 2D grid based on tree depth (halflevel = level // 2),
# with connecting lines between referenced nodes and colored row backgrounds.
class VHTreeLayout < CrymbleUI::DecoratedContainer
  SPACE_H    =   5.0 # horizontal gap between columns (in row-height multiples)
  LINE_WIDTH =   3.0
  # Theme-aware colors (read from JSON via extensible color hash)
  def self.line_color;     CrymbleUI::Theme.current["vhtree.line"]; end
  def self.unselected_bg;  CrymbleUI::Theme.current["vhtree.unselected_bg"]; end
  def self.selected_bg;    CrymbleUI::Theme.current["vhtree.selected_bg"]; end
  def self.text_color;     CrymbleUI::Theme.current["vhtree.text"]; end
  def self.text_color_dim; CrymbleUI::Theme.current["vhtree.text_dim"]; end

  # Metadata per child: {node, level, is_selected, is_table}
  @node_infos = Array({Interface::GUI::VHTreeAdapter, Int32, Bool, Bool}).new
  @node_positions = Hash(Interface::GUI::VHTreeAdapter, CrymbleUI::Vec2).new
  @row_size = CrymbleUI::Size.new(0.0, 0.0)

  def initialize(id : String? = nil)
    super(id: id, padding: 0.0, spacing: 0.0)
  end

  def add_node_info(node : Interface::GUI::VHTreeAdapter, level : Int32)
    selected = node.is_selected?
    is_sel = (selected == true || selected == Some)
    @node_infos << {node, level, is_sel, node.is_table?}
  end

  # Compute uniform row size from children, then 2D bounding box
  def measure(constraints : CrymbleUI::BoxConstraints) : CrymbleUI::Size
    return CrymbleUI::Size.new(0.0, 0.0) if @children.empty?

    # Measure all children to find uniform row size (max width, max height)
    max_w = 0.0
    max_h = 0.0
    @children.each do |child|
      child_size = child.measure(CrymbleUI::BoxConstraints.new(
        min_width: 0.0, max_width: constraints.max_width,
        min_height: 0.0, max_height: constraints.max_height
      ))
      max_w = Math.max(max_w, child_size.width)
      max_h = Math.max(max_h, child_size.height)
    end
    # Ceil to integer to ensure row positions are integers — prevents sub-pixel seams
    @row_size = CrymbleUI::Size.new(max_w.ceil, max_h.ceil)
    row_height = max_h.ceil

    # Compute 2D extent using halflevel algorithm
    halflevel2y = Hash(Int32, Int32).new { |h, k| h[k] = 0 }
    max_halflevel = 0

    @node_infos.each do |_node, level, _sel, _tbl|
      halflevel = level // 2
      max_halflevel = Math.max(max_halflevel, halflevel)
      # Extra row gap before tables (even level, not first in column)
      halflevel2y[halflevel] += 1 if halflevel2y[halflevel] > 0 && level % 2 == 0
      halflevel2y[halflevel] += 1
    end

    max_rows = halflevel2y.values.max? || 1
    total_width = (@row_size.width + SPACE_H * row_height) * (max_halflevel + 1) - SPACE_H * row_height
    total_height = max_rows * row_height

    constraints.constrain(CrymbleUI::Size.new(total_width, total_height))
  end

  # Position each child at computed {x, y}
  def perform_layout(constraints : CrymbleUI::BoxConstraints, position : CrymbleUI::Vec2)
    size = measure(constraints)
    @bounds = CrymbleUI::Rect.new(position.x, position.y, size.width, size.height)
    @node_positions.clear

    return if @children.empty?

    row_height = @row_size.height
    halflevel2y = Hash(Int32, Int32).new { |h, k| h[k] = 0 }

    @node_infos.each_with_index do |(node, level, _sel, _tbl), i|
      break if i >= @children.size

      halflevel = level // 2
      halflevel2y[halflevel] += 1 if halflevel2y[halflevel] > 0 && level % 2 == 0

      x = (@row_size.width + SPACE_H * row_height) * halflevel
      y = halflevel2y[halflevel] * row_height
      halflevel2y[halflevel] += 1

      child = @children[i]
      child_constraints = CrymbleUI::BoxConstraints.new(
        min_width: @row_size.width, max_width: @row_size.width,
        min_height: row_height, max_height: row_height
      )
      child.layout(child_constraints, CrymbleUI::Vec2.new(x, y))

      @node_positions[node] = CrymbleUI::Vec2.new(x, y)
    end
  end

  # Draw connecting lines with arrowheads ON TOP of children.
  # Uses actual child bounds for accurate line placement.
  def draw_foreground(bounds : CrymbleUI::Rect) : Array(CrymbleUI::DrawPrimitive)
    return [] of CrymbleUI::DrawPrimitive if @node_infos.empty? || @children.empty?

    row_height = @row_size.height
    arrow_size = row_height * 0.25
    primitives do
      @node_infos.each_with_index do |(node, _level, _sel, _tbl), i|
        next if i >= @children.size
        ref = node.get_reference
        next unless ref

        # Find target child index
        ref_idx = @node_infos.index { |n, _, _, _| n == ref }
        next unless ref_idx && ref_idx < @children.size

        src = @children[i].bounds
        tgt = @children[ref_idx].bounds

        # Ensure line goes left→right: from right edge of left node to left edge of right node
        if src.x < tgt.x
          left, right = src, tgt
        else
          left, right = tgt, src
        end
        from = CrymbleUI::Vec2.new(left.x + left.width, left.y + left.height / 2)
        to = CrymbleUI::Vec2.new(right.x, right.y + right.height / 2)
        draw_line(from, to, VHTreeLayout.line_color, LINE_WIDTH)

        # Arrowhead at target end (pointing right)
        fill_triangle(
          to,
          CrymbleUI::Vec2.new(to.x - arrow_size, to.y - arrow_size / 2),
          CrymbleUI::Vec2.new(to.x - arrow_size, to.y + arrow_size / 2),
          VHTreeLayout.line_color
        )
      end
    end
  end
end
