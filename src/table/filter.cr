# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../patch"
require "./raw"

# Value-based row filtering for tables. A FilterState is an ordered list of
# per-column ColumnFilters; selected values within one column are OR'ed,
# distinct columns are AND'ed (autofilter semantics).
#
# `Filter.apply` wraps the raw table in a `Filtered` view that:
# - recomputes its row selection on every parent version change (so live
#   reactivity works: if a row in the raw table changes its key-column value
#   to match the filter, the view picks it up automatically);
# - exposes `raw_parent` so consumers (notably `Pivot::Hierarchic`) can read
#   cluster values at raw-VT-frame indices even for rows not in the current
#   filtered selection (post-write / new-record cases);
# - auto-populates single-value filter columns on `hyperplane_add(0)` so new
#   rows land in the filtered view.
#
# Unlike the earlier `Reduced(Partitioned)` chain, `Filtered` does NOT
# snapshot row indices at construction — the selection is always derived
# from the current parent data.

module Table::Lazy::Filter
    # One column's filter: which values to keep. Empty selected_values = no-op.
    struct ColumnFilter
        property column_index : Int32
        property selected_values : Set(Cell)

        def initialize(@column_index : Int32, @selected_values : Set(Cell) = Set(Cell).new)
        end

        def ==(other : ColumnFilter)
            @column_index == other.column_index && @selected_values == other.selected_values
        end

        # Independent copy: caller can mutate either side without aliasing.
        def dup : ColumnFilter
            ColumnFilter.new(@column_index, @selected_values.dup)
        end
    end

    class Filtered(T) < Table::Lazy::Raw::Base(T)
        getter raw : Table::Lazy::Raw::Base(T)
        getter filters : Array(ColumnFilter)
        @version : Int32? = nil
        @selection : Array(Int32) = [] of Int32

        def initialize(@raw : Table::Lazy::Raw::Base(T), @filters : Array(ColumnFilter))
        end

        # Walks past this filter wrapper. Used by Pivot::Hierarchic to read at
        # raw-frame indices (post-write cluster lookups, new-row reads).
        def raw_parent : Table::Lazy::Raw::Base(T)
            @raw
        end

        def version : Int32
            @raw.version
        end

        private def update
            return if @version == @raw.version
            @selection = compute_selection
            @version = @raw.version
        end

        # One pass over @raw: keep rows whose every filter passes.
        # Semantics: empty `selected_values` = user explicitly unchecked every
        # value for that column → zero rows pass. (Non-existence of a filter
        # for a column is handled by the caller simply omitting it from the
        # filter list, not by passing an empty-set ColumnFilter.)
        private def compute_selection : Array(Int32)
            # Short-circuit: any filter with empty selected_values kills all rows.
            return [] of Int32 if @filters.any? { |cf| cf.selected_values.empty? }
            n = @raw.size[0]
            sel = Array(Int32).new
            n.times do |row|
                keep = true
                @filters.each do |cf|
                    val = @raw[[row, cf.column_index]]?
                    unless cf.selected_values.includes?(val.as(T))
                        keep = false
                        break
                    end
                end
                sel << row if keep
            end
            sel
        end

        def size : Index
            update
            s = @raw.size
            s.map_with_index { |el, i| i == 0 ? @selection.size : el }
        end

        def []?(index : Index) : T | Nil
            update
            return nil if index[0] < 0 || index[0] >= @selection.size
            @raw[[@selection[index[0]], index[1]]]?
        end

        def []=(index : Index, value : T) : Index
            update
            @raw[[@selection[index[0]], index[1]]] = value
            index
        end

        protected def map_cell(index : Index) : {Table::Lazy::Base(T), Index}
            update
            {@raw, [@selection[index[0]], index[1]]}
        end

        protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T), Int32, Index}?
            update
            if dimension == 0
                return nil if index[0] < 0 || index[0] >= @selection.size
                {@raw, 0, [@selection[index[0]], index[1]]}
            else
                {@raw, dimension, index}
            end
        end

        # Add a record on dimension 0. Auto-populate single-value filter
        # columns so the new row lands in the selection. Return the index in
        # the FILTER-FRAME — Hierarchic writes back through parent_table[i] =
        # immediately after, and needs a filter-frame index for that to hit
        # the right raw row via our []=/[]? translation.
        def hyperplane_add(dimension : Int32, index=Index.new(size.size, -1), **args) : Index
            if dimension == 0
                new_raw_index = @raw.hyperplane_add(0, index, **args)
                @filters.each do |cf|
                    next unless cf.selected_values.size == 1
                    @raw[[new_raw_index[0], cf.column_index]] = cf.selected_values.first
                end
                # Force @selection rebuild so the new row is visible (if it
                # matches — with single-value filters we just ensured it does).
                @version = nil
                update
                filter_row = @selection.index(new_raw_index[0])
                if filter_row.nil?
                    # New row is not in view (multi-value or empty filter).
                    # Fall back to raw-frame index; callers who translate will
                    # hit an IndexError — make the misuse loud.
                    raise IndexError.new("hyperplane_add: new row not in filter view (multi-value filter couldn't auto-populate)")
                end
                [filter_row, new_raw_index[1]]
            else
                @raw.hyperplane_add(dimension, index, **args)
            end
        end

        def hyperplane_remove(dimension : Int32, index : Index, **args)
            update
            if dimension == 0
                @raw.hyperplane_remove(0, [@selection[index[0]], index[1]], **args)
            else
                @raw.hyperplane_remove(dimension, index, **args)
            end
        end

        def hyperplane_move(dimension : Int32, index_from : Index, index_to : Index) : Index
            update
            if dimension == 0
                from_raw = [@selection[index_from[0]], index_from[1]]
                to_raw = [@selection[index_to[0]], index_to[1]]
                @raw.hyperplane_move(dimension, from_raw, to_raw)
                index_to
            else
                @raw.hyperplane_move(dimension, index_from, index_to)
            end
        end

        def hyperplane_get_rank(norm_dimension : Int32, index : Index) : Int32?
            update
            @raw.hyperplane_get_rank(norm_dimension, [@selection[index[0]], index[1]])
        end

        def hyperplane_is_rank(norm_dimension : Int32, index : Index) : Bool
            update
            @raw.hyperplane_is_rank(norm_dimension, [@selection[index[0]], index[1]])
        end

        def hyperplane_get_ids(norm_dimension : Int32)
            @raw.hyperplane_get_ids(norm_dimension)
        end

        def hyperplane_get_name(dimension : Int32, index : Index) : String
            if dimension == 0
                update
                @raw.hyperplane_get_name(dimension, [@selection[index[0]], index[1]])
            else
                @raw.hyperplane_get_name(dimension, index)
            end
        end

        protected def multiassign_begin
            @raw.multiassign_begin
        end
        protected def multiassign_end
            @raw.multiassign_end
        end
        protected def is_multiassign? : Bool
            @raw.is_multiassign?
        end
    end

    # Apply an ordered chain of ColumnFilters to a parent table. Empty filter
    # list → returns parent unchanged. Otherwise wraps in a Filtered view
    # whose selection recomputes on every parent version change.
    def self.apply(parent : Table::Lazy::Raw::Base(Cell),
                   filters : Array(ColumnFilter)) : Table::Lazy::Raw::Base(Cell)
        return parent if filters.empty?
        Filtered(Cell).new(parent, filters)
    end
end
