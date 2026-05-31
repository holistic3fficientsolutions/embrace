# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../patch"
require "./lazy"

# Raw tables (in addition to Lazy) are dense and have no headers

# robustness of "laziness"
# - Sliced: slice is given in terms of "row"/"column"/"other_dim" values, so if original size changes or e.g. rows get reordered, the update cannot work (-> no update implemented!)
#     -> the update needs to be triggered by the _using_ instance of the Sliced to recalculate it
# - Reduced: like Sliced
# - Derived: automatically works, also if parents change size; because caching is fully recalculated on change lazily
# - Combined: automatically works, also if parents change size; because there is no caching
# - Memory: fine since has no caching

# #move works as follows:
# - works on a hyperplane specified by an index and the dimension integer
# - always works on root table level
# - be aware that always the _full_ hyperplanes are moved, independent if some parts might only be visible in higher layer tables; otherwise it would not be well-defined

abstract class Table::Lazy::Raw::Base(T) < Table::Lazy::Base(T)
    def slice(index : Array) : Raw::Sliced(T) # just for convenience (to enable functional style programming)
        Table::Lazy::Raw::Sliced(T).new(self, index)
    end
    # Walks through any row-subsetting wrappers (e.g. Filter::Filtered) to
    # return the underlying unfiltered table. Default: returns self. Wrappers
    # whose size differs from their underlying raw source override this so
    # consumers that receive raw-frame indices (e.g. Pivot::Hierarchic's
    # post-write cluster reads) can read past the filtered size.
    def raw_parent : Table::Lazy::Raw::Base(T)
        self
    end
end

# class for supporting quick and easy k-dim slicing & iterating
# slicing supports negative indices, also in ranges (similar to normal array indexing)
class Table::Lazy::Raw::Sliced(T) < Table::Lazy::Raw::Base(T)
    def initialize(@parent : Table::Lazy::Base(T), slice : Array)
        @slice = Array(Int32|Range(Int32,Int32)).new
        s = @parent.size
        slice.each.with_index do |el, i|
            case el
            when nil
                el = (0...s[i]) # nil as a shorthand for full dimension!
            when Range(Int32,Int32) # we also allow negative indices in ranges!
                b = (el.begin >= 0 ? el.begin : el.begin+s[i])
                e = (el.end >= 0 ? el.end : el.end+s[i])
                el = Range(Int32,Int32).new(b, e, el.exclusive?)
            when Int32
                # nothing to be translated
            else
                assert(false)
            end
            @slice << el
        end
    end
    def size : Index
        s = Array(Int32).new
        j = 0
        @slice.each.with_index do |el,i|
            case el
            when Int32
                # nothing to do
            when Range(Int32,Int32)
                s << el.size
                j += 1
            else
                assert(false)
            end
        end
        s
    end
    def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
        @parent.version
    end
    private def update # the update mechanism
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        index2 = Index.new
        j = 0
        @slice.each do |el|
            case el
            when Int32
                index2 << el
            when Range(Int32,Int32)
                index2 << el.begin + index[j]
                j += 1
            else
                assert(false)
            end
        end
        {@parent, index2}
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        i = j = 0
        @slice.each do |el|
            case el
            when Range(Int32,Int32)
                break if j == dimension
                j += 1
            end
            i += 1
        end
        {@parent, i, map_cell(index)[1]}
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end

# class for arbitrary reduction (and/or permutation) of one given dimension
class Table::Lazy::Raw::Reduced(T) < Table::Lazy::Raw::Base(T)
    def initialize(@parent : Table::Lazy::Base(T), @dimension : Int32, @selection : Array(Int32))
    end
    def size : Index
        @parent.size.map_with_index {|el,i| i==@dimension ? @selection.size : el}
    end
    def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
        @parent.version
    end
    private def update # the update mechanism
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        index2 = index.map_with_index {|el,i| i==@dimension ? @selection[el] : el}
        {@parent, index2}
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        {@parent, dimension, map_cell(index)[1]}
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end

# partition-view: a Raw::Base for one key's selection inside a Partitioned owner.
# Structurally mirrors Reduced, but reads its selection from the owner instead of storing it.
class Table::Lazy::Raw::PartitionView(T) < Table::Lazy::Raw::Base(T)
    def initialize(@parent : Table::Lazy::Base(T), @dimension : Int32, @owner : Partitioned(T), @key : T)
    end
    def size : Index
        @parent.size.map_with_index {|el,i| i==@dimension ? @owner.get_selection(@key).size : el}
    end
    def version : Int32
        @owner.version
    end
    private def update
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        sel = @owner.get_selection(@key)
        index2 = index.map_with_index {|el,i| i==@dimension ? sel[el] : el}
        {@parent, index2}
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        {@parent, dimension, map_cell(index)[1]}
    end
    protected def multiassign_begin
        update if !is_multiassign?
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool
        @parent.is_multiassign?
    end
end

# value-based 1D partitioning of a parent table along one dimension.
# Not a table subclass — acts as a factory for per-key PartitionView (or union-view via Reduced).
# Performs one O(n) scan on first use (or after parent.version changes), grouping row indices
# by the value of @key_column. Per-key views are O(1) to construct.
class Table::Lazy::Raw::Partitioned(T)
    @partitions : Hash(T, Array(Int32)) = Hash(T, Array(Int32)).new
    @version : Int32? = nil
    def initialize(@parent : Table::Lazy::Base(T), @dimension : Int32, @key_column : Int32)
    end
    def version : Int32
        @parent.version
    end
    private def update
        return if @version == @parent.version
        @partitions = Hash(T, Array(Int32)).new
        # The "key" lives at @key_column in the first axis orthogonal to @dimension.
        # For a 2D table with @dimension=0 (scan rows), key is at column @key_column.
        key_axis = orthogonal_dim
        cell_index = Index.new(@parent.size.size, 0)
        cell_index[key_axis] = @key_column
        @parent.size[@dimension].times do |i|
            cell_index[@dimension] = i
            value = @parent[cell_index]?.as(T)
            (@partitions[value] ||= Array(Int32).new) << i
        end
        @version = @parent.version
    end
    private def orthogonal_dim : Int32
        @parent.size.size.times do |d|
            return d if d != @dimension
        end
        assert(false)
        0
    end

    def keys : Array(T)
        update
        @partitions.keys
    end
    def get_selection(key : T) : Array(Int32)
        update
        @partitions[key]? || ([] of Int32)
    end
    # Merged (sorted, deduped) selection across multiple keys. Preserves ascending row order.
    # Linear-time: O(n + m) using a boolean mask, no sort.
    def get_selection_union(keys : Array(T)) : Array(Int32)
        update
        n = @parent.size[@dimension]
        keep = Array(Bool).new(n, false)
        keys.each do |k|
            if sel = @partitions[k]?
                sel.each { |i| keep[i] = true }
            end
        end
        result = Array(Int32).new
        n.times { |i| result << i if keep[i] }
        result
    end
    def view(key : T) : PartitionView(T)
        update
        PartitionView(T).new(@parent, @dimension, self, key)
    end
    # A union view across multiple keys is represented as a plain Reduced over the union selection.
    def view_union(keys : Array(T)) : Table::Lazy::Raw::Reduced(T)
        Table::Lazy::Raw::Reduced(T).new(@parent, @dimension, get_selection_union(keys))
    end
    def each_view(& : (T, PartitionView(T)) -> Nil) : Nil
        update
        @partitions.each_key { |k| yield k, view(k) }
    end
end

# calculating a new table based on a given one; dimensions and sizes may differ arbitrarily
class Table::Lazy::Raw::Derived(T) < Table::Lazy::Raw::Base(T)
    @version : Int32?
    @derived : Table::Lazy::Base(T)?
    def initialize(@parent : Table::Lazy::Base(T), &@deriver : Table::Lazy::Base(T) -> Table::Lazy::Base(T))
        @version = nil
    end
    def size : Index
        update
        @derived.not_nil!.size
    end
    def []?(index : Index) : T|Nil
        update
        assert(in_bounds?(index))
        @derived.not_nil![index]?
    end
    def []=(index : Index, value : T) : Index
        assert(false)
    end
    def version : Int32
        update if !@version
        @version.not_nil!
    end
    private def update # the update mechanism, should be called at the beginning in every method that gets/sets some data
        if !is_multiassign? && (@version != @parent.version)
            @derived = @deriver.call(@parent)
            @version = @parent.version
        end
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        assert(false) # dummy method
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        assert(false) # dummy method
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end

# glueing two tables along a given dimension; number of dimensions does not change, but size increases
# second table may have one dimension less, i.e. being just a hyperplane (e.g. adding a 1D column or row to a 2D table)
# restriction: second table must be a Raw::Derived, otherwise the concept of slicing hyperplanes is not well defined on Raw level
class Table::Lazy::Raw::Combined(T) < Table::Lazy::Raw::Base(T)
    def initialize(@parent : Table::Lazy::Base(T), @dimension : Int32, @derived : Table::Lazy::Raw::Derived(T))
    end
    def size : Index
        case @parent.size.size - @derived.size.size
        when 0 # adding two proper tables/hypercubes
            (0...@parent.size.size).map do |i|
                if i==@dimension
                    @parent.size[i]+@derived.size[i]
                elsif @parent.size[i]==@derived.size[i]
                    @parent.size[i]
                else
                    assert(false)
                end
            end
        when 1 # adding a hyperplane to a table/hypercube
            j = 0
            (0...@parent.size.size).map do |i|
                if i==@dimension
                    @parent.size[i]+1
                elsif @parent.size[i]==@derived.size[j]
                    j += 1
                    @parent.size[i]
                else
                    assert(false)
                end
            end
        else
            assert(false)
        end
    end
    def version : Int32
        @parent.version
    end
    private def update # the update mechanism, should be called at the beginning in every method that gets/sets some data
        # nothing to do
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        case @parent.size.size - @derived.size.size
        when 0 # adding two proper tables/hypercubes
            delta = index[@dimension] - @parent.size[@dimension]
            if delta < 0
                {@parent, index}
            elsif delta < @derived.size[@dimension]
                {@derived, index.map_with_index {|s,i| i==@dimension ? delta : s}}
            else
                assert(false)
            end
        when 1 # adding a hyperplane to a table/hypercube
            delta = index[@dimension] - @parent.size[@dimension]
            if delta < 0
                {@parent, index}
            elsif delta == 0
                {@derived, index.select_with_index {|s,i| i!=@dimension}}
            else
                assert(false)
            end
        else
            assert(false)
        end
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        if (dimension == @dimension) && (index[dimension] >= @parent.size[dimension])
            # the hyperplane is inside Raw::Derived only
            assert(false)
        end
        {@parent, dimension, map_cell(index)[1]}
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end

# table storing real values
# arbitrary number of dimensions, arbitrary size, dense table
class Table::Lazy::Raw::Memory(T) < Table::Lazy::Raw::Base(T)
    @size : Array(Int32)
    @multiassign_count = 0
    @version = 0
    @multiassignments_cell = Array({Index,T}).new
    @multiassignments_hyperplane = Array({Symbol,Int32,Index?,Index|Nil}).new
    def initialize(size : Index)
        @size = size.to_a
        @content = Array(T?).new(@size.product, nil)
    end
    def initialize(origin : Table::Lazy::Base(T)) # cloning any other table
        @size = origin.size
        @content = Array(T?).new(@size.product, nil)
        origin.each.with_index2 do |el, index|
            self[index] = el
        end
    end
    def load(content : Array(T))
        assert(!(content.size != @size.product))
        @content = content
        self
    end
    def size : Index
        @size.dup
    end
    def []?(index : Index) : T|Nil
        assert(in_bounds?(index))
        @content[linearize_index(index)]
    end
    def []=(index : Index, value : T) : Index
        assert(in_bounds?(index))
        if is_multiassign?
            @multiassignments_cell << {index, value}
        else
            @version += 1
            @content[linearize_index(index)] = value
        end
        index
    end
    def hyperplane_is_rank(norm_dimension : Int32, index : Index) : Bool # must be overridden by root tables
        false
    end
    def hyperplane_get_rank(norm_dimension : Int32, index : Index) : Int32? # must be overridden by root tables
        nil
    end
    def hyperplane_add(dimension : Int32, index=Index.new(size.size, -1), **args) : Index # append hyperplane globally (with nil values); need not necessarily show up in "self" table; must be overridden by root tables
        # will always be appended / no move done here ("index" ignored)
        if is_multiassign?
            @multiassignments_hyperplane << {:add, dimension, nil, nil}
        else
            size = @size.dup
            modulus = size[dimension...size.size].product # always working at the smaller table
            offset = size[dimension+1...size.size].product
            size[dimension] += 1 # making bigger
            content = Array(T?).new(size.product, nil)
            j = 0
            # fast copy
            @size.product.times do |i|
                content[j] = @content[i]
                j += 1
                j += offset if (i+1)%modulus == 0
            end
            assert((j==0) || (size.product==j)) # special handling when starting from empty table
            @version += 1
            @content, @size = content, size
        end
        Index.new(self.size.size, 0).map_with_index {|_,i| i==dimension ? self.size[i]-1 : 0}
    end
    def hyperplane_remove(dimension : Int32, index : Index, **args) # remove hyperplane globally
        if is_multiassign?
            @multiassignments_hyperplane << {:remove, dimension, index, nil}
        else
            hyperplane_move(dimension, index, dimindex2index(dimension, size[dimension]-1)) # bring hyperplane to the back
            size = @size.dup
            size[dimension] -= 1 # making smaller
            modulus = size[dimension...size.size].product # always working at the smaller table
            offset = size[dimension+1...size.size].product
            content = Array(T?).new(size.product, nil)
            j = 0
            # fast copy
            size.product.times do |i|
                content[i] = @content[j]
                j += 1
                j += offset if (i+1)%modulus == 0
            end
            j += offset if size.product == 0 # needed for singulatity
            assert(!(@size.product!=j))
            @version += 1
            @content, @size = content, size
        end
    end
    def hyperplane_move(dimension : Int32, index_from : Index, index_to : Index) : Index # not fast, but works
        if is_multiassign?
            @multiassignments_hyperplane << {:move, dimension, index_from, index_to}
        else
            dimindex_from = index_from[dimension]
            dimindex_to = index_to[dimension]
            move_up = dimindex_from < dimindex_to # moving to a higher index
            dimindex_from, dimindex_to = dimindex_to, dimindex_from if !move_up
            hyperplane_rotate(dimension, move_up, dimindex_from, dimindex_to)
            @version += 1
        end
        index_to
    end
    def hyperplane_get_default(dimension : Int32, index : Index) : T|Nil # must be overridden by root tables
        nil
    end
    def version : Int32
        @version
    end
    private def update
        # nothing to do
    end
    protected def hyperplane_rotate(dimension : Int32, up : Bool, dimindex1 : Int32, dimindex2 : Int32)
        # locally rotates hyperplanes in self either up or down in the given dimension
        # "up" in the sense that rotating in direction of higher index
        assert((dimindex1 <= dimindex2)) # crystal bug: needs double parenthesis
        range = (dimindex1...dimindex2)
        iterator = up ? range.each : range.reverse_each
        iterator.each do |i|
            hyperplane_swap(dimension, i, i+1)
        end
    end
    protected def hyperplane_swap(dimension : Int32, dimindex1 : Int32, dimindex2 : Int32)
        table1 = slice((0...size.size).map {|i| i==dimension ? dimindex1 : nil})
        table2 = slice((0...size.size).map {|i| i==dimension ? dimindex2 : nil})
        table1.each.with_index2 do |_, index|
            table1[index], table2[index] = table2[index], table1[index]
        end
    end
    private def linearize_index(index : Index)
        assert(!(index.size != @size.size))
        lin = 0
        index.size.times do |i|
            assert(!(index[i]>=@size[i]))
            lin *= @size[i]
            lin += index[i]
        end
        lin
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        assert(false) # dummy method
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        nil # root table has to return nil
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @multiassign_count += 1
    end
    protected def multiassign_end : Index?
        @multiassign_count -= 1
        index = nil
        if is_multiassign?
            nil
        else
            @version += 1
            if @multiassignments_cell.size > 0
                # we just make all stored assignments visible at the same time (easy)
                assert(@multiassignments_hyperplane.size == 0)
                while head = @multiassignments_cell.shift?
                    index, value = head
                    self[index] = value
                end
                index # we return the last index (only in direct assignment mode)
            else
                # we need to perform all stored hyperplane operations at once
                # be aware: all are referencing the original size (hard)
                # first, we eliminate (consecutive) hyperplane_removes that refer to same hyperplane -- TODO(table): this dedup sits awkwardly here
                @multiassignments_hyperplane = (0...@multiassignments_hyperplane.size).select do |i|
                    if i == 0
                        true
                    else
                        action = @multiassignments_hyperplane[i-1][0]
                        dim = @multiassignments_hyperplane[i-1][1]
                        is_same_action = (@multiassignments_hyperplane[i-1][0]) == (@multiassignments_hyperplane[i][0])
                        is_same_dim = (@multiassignments_hyperplane[i-1][1]) == (@multiassignments_hyperplane[i][1])
                        is_same_dimindex = (@multiassignments_hyperplane[i-1][2].not_nil![dim]) == (@multiassignments_hyperplane[i][2].not_nil![dim])
                        !((action==:remove) && is_same_action && is_same_dim && is_same_dimindex)
                    end
                end.map {|i| @multiassignments_hyperplane[i]}
                # now for the rest
                while head = @multiassignments_hyperplane.shift?
                    action, dimension, index1, index2 = head
                    case action
                    when :add # has no index; cannot be referenced from original sized table (easy)
                        hyperplane_add(dimension)
                    when :remove # has index1; we need to correct some consecutive hyperplane operations
                        raise("static assert") if index1.nil?
                        @multiassignments_hyperplane.map! do |el|
                            indices = [el[2], el[3]]
                            indices.map! do |index|
                                if index && (index[dimension] > index1[dimension])
                                    index[dimension] -= 1
                                end
                                index
                            end
                            {el[0], el[1], indices[0], indices[1]}
                        end
                        hyperplane_remove(dimension, index1)
                    when :move # has both indices
                        assert(false) # TODO(table): :move not supported yet
                    else
                        assert(false)
                    end
                    # TODO(table): revisit this branch
                end
                nil
            end
        end
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @multiassign_count > 0
    end
end

# class for automatically indexed dimensions (except one), by adding the proper hyperplane;
# the axes in the hyperplane can also be written to (but not the root or the rest of the hyperplane); this results in a move_hyperplane;
# index considers root cell as 0
# depending if table has headers, the root cell can be given a proper name (e.g. "index"), or (if not) just 0
class Table::Lazy::Raw::Indexed(T) < Table::Lazy::Raw::Base(T)
    def initialize(@parent : Table::Lazy::Base(T), @dimension_not_indexed : Int32, @default_norm = 0)
        @multiassignments = Array({Index,Int64}).new
    end
    def set_norm(norm)
        @default_norm = norm # this dimension is being used as a hyperplane norm vector when confronted with Index all zeros (origin)
    end
    def size : Index
        @parent.size.map_with_index {|el,i| i==@dimension_not_indexed ? el+1 : el}
    end
    def []?(index : Index) : T|Nil
        assert(in_bounds?(index))
        if index[@dimension_not_indexed] == 0
            get_virtual_index(index)[1]
        else
            table, index2 = map_cell(index)
            table[index2]
        end
    end
    def []=(index : Index, value : T) : Index
        assert(in_bounds?(index))
        if index[@dimension_not_indexed] == 0
            assert(value.is_a?(Int))
            if is_multiassign?
                @multiassignments << {index, value}
                index
            else
                source = get_virtual_index(index)
                dimension = source[0]
                value = [0,value].max
                value = [size[source[0]]-1,value].min
                value = value.to_i64
                assert(value.is_a?(Int64)) # helping the compiler
                hyperplane_move(dimension, dimindex2index(dimension,source[1].to_i32), dimindex2index(dimension,value.to_i32))
                index.map_with_index {|el,i| i==dimension ? value.as(Int64).to_i32 : el}
            end
        else
            table, index2 = map_cell(index)
            table[index2] = value
            index
        end
    end
    def hyperplane_is_rank(norm_dimension : Int32, index : Index) : Bool # must be overridden by root tables
        if (@dimension_not_indexed == norm_dimension) && (index[norm_dimension] == 0)
            true
        else
            super
        end
    end
    def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
        @parent.version
    end
    private def update # the update mechanism
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        index2 = index.map_with_index {|el,i| i==@dimension_not_indexed ? el-1 : el}
        {@parent, index2}
    end
    def hyperplane_get_default(dimension : Int32, index : Index) : T|Nil # must be overridden by root tables
        if dimension != @dimension_not_indexed
            super
        else
            nil
        end
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        assert(dimension != @dimension_not_indexed)
        {@parent, dimension, map_cell(index)[1]}
    end
    private def get_virtual_index(index : Index)
        axes = index.map_with_index {|el,i| (i==@dimension_not_indexed)||(el==0) ? nil : {i,el.to_i64}}.select{|el| !el.nil?}
        case axes.size
        when 0
            {@default_norm, 0i64} # all dimension indices are 0
        when 1
            axes[0].not_nil! # one index dimension is non-0, we return {dimension,dim_index}
        else
            assert(false)
        end
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @parent.multiassign_begin
    end
    protected def multiassign_end : Index?
        index = @parent.multiassign_end # first, let e.g. Memory empty its buffer...
        if !is_multiassign? #  ... then we do the moves
            while head = @multiassignments.shift?
                index, value = head
                index = (self[index] = value)
            end
        end
        index
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end

# class for arbitrary permutation of dimensions
class Table::Lazy::Raw::Permuted(T) < Table::Lazy::Raw::Base(T)
    def initialize(@parent : Table::Lazy::Base(T), @permutation : Array(Int32)|{Int32})
        assert(!(@permutation.size != @parent.size.size))
        assert(!(@permutation.to_a.uniq.size != @parent.size.size))
    end
    def size : Index
        s = @parent.size
        s.map_with_index {|_,i| s[@permutation[i]]}
    end
    def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
        @parent.version
    end
    private def update # the update mechanism
    end
    protected def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
        index2 = index.map_with_index {|_,i| index[@permutation[i]]}
        {@parent, index2}
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil
        {@parent, dimension, map_cell(index)[1]}
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update if !is_multiassign? # sort of flushing the cache
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if multiassign is active, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end
