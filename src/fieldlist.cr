# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "./global"
require "./table/raw"
require "./debug-helper"
require "./permutation"
require "./table/pivot" # for Table::Lazy::Pivot::Classes

# overview of the different column meanings
#
# gui/fieldlist.cr; uses internal types (i.e. independent of Hierarchic) and does not need column_index
# enum GUI::Widget::FieldlistConstants::ColumnIndices
#     Rank            # -> Int64
#     Class           # -> RowClass
#     Level           # -> Int64
#     SortAscending   # -> Bool
#     Name            # -> String
# end
#
# pivot.cr
# enum Table::Lazy::Pivot::FieldlistColumns
#     Rank            # TODO(fieldlist): calculated level; couples this enum to Indexed usage
#     Column          # index
#     PivotClass
#     Level
#     IsRowColSortAsc
# end
#
# fieldlist.cr; inline with pivot.cr; needs template parameters to include Int64, Bool and String
# enum Table::Lazy::Fieldlist::ColumnIndices # TODO(fieldlist): not used yet
#     Rank                    # (by Indexed) -> Int64
#     Column                  # -> Int64; internally column_id, but will be replaced by column_index externally
#     Class                   # -> Int64, has to be a .value'ed enum by using class
#     Level                   # -> Int64
#     SortAscending           # -> Bool
#     Name                    # (by Derived) -> String
#     InternalColumnIndex     # (by Derived) -> will be mapped to Column for outside, as noted above
# end

# T is template type of fieldlist itself (i.e. Int64|Bool|String)
# U is template type of @parent, i.e. user data VirtualTable
class Table::Lazy::Fieldlist(T,U) < Table::Lazy::Raw::Base(T)
    enum ColumnIndices
        Rank                    # (by Indexed) -> Int64
        Column                  # -> Int64; internally column_id, but will be replaced by column_index externally
        Class                   # -> Int64, has to be a .value'ed enum by using class
        Level                   # -> Int64
        SortAscending           # -> Bool
        LastMemory = SortAscending
        Name                    # (by Derived) -> String
        InternalColumnIndex     # (by Derived) -> will be mapped to Column for outside, as noted above
        LastDerived = InternalColumnIndex
    end
    @version : Int32? = nil
    @last_parent_version : Int32? = nil
    getter table_memory : Table::Lazy::Raw::Memory(T)
    @table_internal : Table::Lazy::Raw::Base(T) # indexed, needed for assignment to Rank
    @table : Table::Lazy::Raw::Base(T) # for user
    def initialize(@parent : Table::Lazy::Raw::Base(U), @table_memory : Table::Lazy::Raw::Memory(T) =
            Table::Lazy::Raw::Memory(T).new([0, ColumnIndices::LastMemory.value])) # @parent is typically a VirtualTable
        @table_internal = Table::Lazy::Raw::Indexed(T).new(@table_memory, 1)
        @table = create_table
    end
    def clone(parent) : Table::Lazy::Fieldlist(T,U)
        Fieldlist(T,U).new(parent, Table::Lazy::Raw::Memory(T).new(self.table_memory)) # cloning the @table_memory
    end
    def size : Index
        update
        @table.size
    end
    def []?(index : Index) : FieldlistCell?
        update
        @table[index]?
    end
    def []=(index : Index, value : FieldlistCell) : Index
        update
        @table[index] = value
        index
    end
    def empty!
        update
        @table_internal.size[0].times do |row_i|
            @table_internal[[row_i, ColumnIndices::Class.value]] = Table::Lazy::Pivot::Classes::Unused.value.to_i64
            @table_internal[[row_i, ColumnIndices::Level.value]] = 0i64
        end
    end
    def normalize!
        update
        @table_internal.size[0].times do |row_i|
            ci = @table[[row_i, ColumnIndices::Column.value]].as(Int64).to_i32
            is_rank = @parent.hyperplane_is_rank(1, [0,ci])
            class_value = (is_rank ? Table::Lazy::Pivot::Classes::Row.value : Table::Lazy::Pivot::Classes::Aggregate.value)
            @table_internal[[row_i, ColumnIndices::Class.value]] = class_value.to_i64
            @table_internal[[row_i, ColumnIndices::Level.value]] = 0i64
            @table_internal[[row_i, ColumnIndices::SortAscending.value]] = true
        end
    end
    def mirror_horizontal_header!
        update
        @table_internal.size[0].times do |row_i|
            if @table_internal[[row_i, ColumnIndices::Class.value]] == Table::Lazy::Pivot::Classes::Column.value
                @table_internal[[row_i, ColumnIndices::SortAscending.value]] = !@table_internal[[row_i, ColumnIndices::SortAscending.value]]
            end
        end
        arr = (0...@table_internal.size[0]).select do |row_i|
            @table_internal[[row_i, ColumnIndices::Class.value]] == Table::Lazy::Pivot::Classes::Row.value
        end
        fieldlist_from_a2([arr.reverse], false)
    end
    def mirror_horizontal_aggregate!
        update
        fieldlist_from_a2(agg_to_a2.map(&.reverse), true)
    end
    def mirror_vertical_header!
        update
        @table_internal.size[0].times do |row_i|
            if @table_internal[[row_i, ColumnIndices::Class.value]] == Table::Lazy::Pivot::Classes::Row.value
                @table_internal[[row_i, ColumnIndices::SortAscending.value]] = !@table_internal[[row_i, ColumnIndices::SortAscending.value]]
            end
        end
        arr = (0...@table_internal.size[0]).select do |row_i|
            @table_internal[[row_i, ColumnIndices::Class.value]] == Table::Lazy::Pivot::Classes::Column.value
        end
        fieldlist_from_a2([arr.reverse], false)
    end
    def mirror_vertical_aggregate!
        update
        fieldlist_from_a2(agg_to_a2.reverse, true)
    end
    def mirror_diagonal_header!
        update
        @table_internal.size[0].times do |row_i|
            class_value = @table_internal[[row_i, ColumnIndices::Class.value]].as(Int64)
            case class_value
            when Table::Lazy::Pivot::Classes::Row.value
                class_value = Table::Lazy::Pivot::Classes::Column.value
            when Table::Lazy::Pivot::Classes::Column.value
                class_value = Table::Lazy::Pivot::Classes::Row.value
            end
            @table_internal[[row_i, ColumnIndices::Class.value]] = class_value.to_i64
        end
    end
    def mirror_diagonal_aggregate!
        update
        fieldlist_from_a2(agg_to_a2.transpose, true)
    end
    def hyperplane_is_rank(norm_dimension : Int32, index : Index) : Bool # must be overridden by root tables
        update
        @table.hyperplane_is_rank(norm_dimension, index)
    end
    def hyperplane_get_rank(norm_dimension : Int32, index : Index) : Int32? # must be overridden by root tables
        update
        @table.hyperplane_get_rank(norm_dimension, index)
    end
    def hyperplane_add(dimension : Int32, index=Index.new(size.size, -1), **args) : Index
        assert(false)
    end
    def hyperplane_remove(dimension : Int32, index : Index, **args)
        assert(false)
    end
    def hyperplane_move(dimension : Int32, index_from : Index, index_to : Index) : Index
        assert(false)
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        @table.map_cell(index)
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        @table.map_hyperplane(dimension, index)
    end
    def hyperplane_get_name(dimension : Int32, index : Index) : String
        "" # TODO(fieldlist): stub — returns an empty name
    end
    def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
        update
        @parent.version + @table_internal.version
    end
    private def update # the update mechanism, should be called at the beginning in every method that gets/sets some data
        version = @parent.version + @table_internal.version
        if !is_multiassign? && (@version != version)
            parent_columnids = @parent.hyperplane_get_ids(0)
            id2i = parent_columnids.map_with_index {|el,i| {el,i}}.to_h
            own_columnids = @table_internal.size[0].times.map {|ri| @table_internal[[ri,ColumnIndices::Column.value]].as(Int64).to_i32}.to_set
            ids_to_remove = own_columnids - parent_columnids
            # first, remove outdated entries
            (0...@table_internal.size[0]).reverse_each do |row_i|
                column_id = @table_internal[[row_i, ColumnIndices::Column.value]].as(Int64).to_i32
                if (column_id!=NilRecord) && ids_to_remove.includes?(column_id)
                    @table_internal.hyperplane_remove(0, [row_i,0])
                end
            end
            # second, add new entries
            (parent_columnids - own_columnids).each do |id|
                new_row = @table_internal.hyperplane_add(0)[0]
                @table_internal[[new_row, ColumnIndices::Column.value]] = id.to_i64
                is_rank = @parent.hyperplane_is_rank(1, [0,id2i[id]])
                class_value = (is_rank ? Table::Lazy::Pivot::Classes::Row.value : Table::Lazy::Pivot::Classes::Aggregate.value)
                @table_internal[[new_row, ColumnIndices::Class.value]] = class_value.to_i64
                @table_internal[[new_row, ColumnIndices::Level.value]] = 0i64
                @table_internal[[new_row, ColumnIndices::SortAscending.value]] = true
            end
            @version = version
        end
        # The Name column is derived from @parent's field names, but the inner
        # Derived table is keyed to @table_internal only. A rename in @parent
        # (Names meta-field write) never touches @table_internal, so without this
        # the names would stay stale until the next fieldlist memory write (a
        # drag/sort). Rebuilding the view whenever @parent changes resets the
        # Derived cache so the names re-derive. O(#fields), only on parent change.
        if !is_multiassign? && (@last_parent_version != @parent.version)
            @table = create_table
            @last_parent_version = @parent.version
        end
    end
    private def create_table : Table::Lazy::Raw::Base(T)
        all = Table::Lazy::Raw::Combined(T).new(@table_internal, 1, Table::Lazy::Raw::Derived(T).new(@table_internal) do |table|
            # will be called only on #update
            num_cols = ColumnIndices::LastDerived.value - ColumnIndices::LastMemory.value
            col_index_name = ColumnIndices::Name.value - ColumnIndices::LastMemory.value - 1
            col_index_index = ColumnIndices::InternalColumnIndex.value - ColumnIndices::LastMemory.value - 1
            combined = Table::Lazy::Raw::Memory(T).new([table.size[0],num_cols])
            # synchronize columnids with columnindices
            columnid2index = @parent.hyperplane_get_ids(0).each_with_index.to_h
            table.size[0].times do |ri|
                if column_id = table[[ri,ColumnIndices::Column.value]]
                    # if nil, not set (yet)
                    if column_id == nil
                        combined[[ri,col_index_name]] = nil
                        combined[[ri,col_index_index]] = nil
                    else
                        if column_index = columnid2index[column_id]? # net data in @parent may already have less fields
                            combined[[ri,col_index_name]] = @parent.hyperplane_get_name(1, [0,column_index])
                            combined[[ri,col_index_index]] = column_index.to_i64
                        end
                    end
                end
            end
            combined
        end)
        Table::Lazy::Raw::Reduced(T).new(all, 1, [
            ColumnIndices::Rank,
            ColumnIndices::InternalColumnIndex,
            ColumnIndices::Class,
            ColumnIndices::Level,
            ColumnIndices::SortAscending,
            ColumnIndices::Name
        ].map(&.value))
    end
    private def agg_to_a2 : Array(Array(Int32?))
        a2 = Array(Array(Int32?)).new
        # extract all aggregate row_i's into a2
        @table_internal.size[0].times do |row_i|
            if @table_internal[[row_i, ColumnIndices::Class.value]] == Table::Lazy::Pivot::Classes::Aggregate.value
                level = @table_internal[[row_i, ColumnIndices::Level.value]].as(Int64)
                while a2.size <= level
                    a2 << Array(Int32?).new
                end
                a2[level] << row_i
            end
        end
        # BTW: row_i in a2 (in zigzag) are strictly monotonous rising
        # since a2 is not necessarily rectangular, we pad with nil (so that it can be transposed)
        s = a2.map(&.size).max? || 0
        a2.map {|el| el + Array(Int32?).new(s-el.size, nil)}
    end
    private def fieldlist_from_a2(a2 : Array(Array(Int32?)), do_set_hierarchy : Bool) : Nil
        # rearrange all aggregates|rows|columns according to row_i in a2 (nils are skipped)
        # primitive is #[[row,ColumnIndices::Rank.value or ColumnIndices::Level.value]]=
        a2 = a2.map(&.reject(&.nil?).map(&.as(Int32))) # get rid of paddings, might "shift" to the left, since left gaps are not allowed; #map is for helping compiler
        a2_flat = a2.flatten # e.g. [4, 3, 7, 8]; not consecutive, with gaps
        # first, set levels (the _entries_ in a2 are wrt. _old_ rows; vs. _positions_ in a2; hence: first)
        if do_set_hierarchy
            a2.each_with_index do |row,level|
                row.each do |el|
                    @table_internal[[el,ColumnIndices::Level.value]] = level.to_i64
                end
            end
        end
        # second, reorder aggregates
        ranks_new2old = a2_flat.sort. # e.g. [3, 4, 7, 8]
            map_with_index {|el,i| {el, a2_flat[i]}}.to_h. # e.g. {3=>4, 4=>3, 7=>7, 8=>8}
            merge((0...@table_internal.size[0]).map {|el| {el,el}}.to_h) {|k,v1,v2| v1}. # e.g. {0=>0, 1=>1, 2=>2, 3=>4, 4=>3, 5=>5, ...}
            to_a.sort {|x,y| x[0]<=>y[0]}.map(&.[1]) # e.g. [0, 1, 2, 4, 3, 5, 6, 7, 8]
        # ranks_new2old = a2_flat.map_with_index {|el,i| {el,i}}.sort {|x,y| x[0]<=>y[0]}.map(&.[1]) # e.g. [1, 0, 2, 3]
        Permutation.new(true, ranks_new2old).apply_with_move do |i,j| # "new2old" mode
            # i, j = a2_flat[i], a2_flat[j]
            j -= 1 if i < j # forward move, with strict "move_before" Permutation semantics (vs. VT has "move_instead" semantics); see booklet 16.6.2024
            @table_internal[[i,ColumnIndices::Rank.value]] = (j+0).to_i64 # VT rank always starts with 1, but Raw::Indexed with 0
        end
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @table.multiassign_begin
    end
    protected def multiassign_end
        @table.multiassign_end
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @table.is_multiassign?
    end
end
