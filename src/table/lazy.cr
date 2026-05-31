# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../patch"
require "./base"

# key ideas
# - concept for chained lazy reference table classes (necessary because _all_ the original data needs to come out of the DB!)
# - again: all of the Table subclasses are lazily evaluated!
# - to have a cell abstraction between the chained tables (vs. dealing all the time with row_id-references)
# - all of the classes here work for arbitrary number of dimensions
# - there is an abstract base class with minimum interface
# - all more sophisticated classes inherit from this base _and_ have constructors linking to such a predecessor base class

# be aware
# - cells for editing
# - rows for adding/deleting/moving
# - both are operating on the base table only, the rest is just reference "sugar"
# specialized table classes need several tables as input (e.g. logical pivot table)
# - all modifying methods (#[]=, #hyperplane_{add|move|remove}) all (need to) return Index due to sticky cursor requirement (exception: #hyperplane_remove)

# Table terminology
# - dimension k
# - size: tuple or array of size k, every element specifying the size of the corresponding dimension index
# - (full) index: referring to a specific cell
# - cell: user defined type and value at the table intersection given by the corresponding index
# - dimension index: e.g. row index, column index
# - vs. row id or line number; those concepts appear at a higher abstraction level

# very basic class interface; we use this to define chained lazy tables
abstract class Table::Lazy::Base(T) < Table::Base(T) # T shall be later String?|Int32|...
    # those two abstract methods are really independent and need to be specified for all non-root tables
    protected abstract def map_cell(index : Index) : {Table::Lazy::Base(T),Index}
    protected abstract def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Base(T),Int32,Index}|Nil

    abstract def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
    private abstract def update # the update mechanism, should be called at the beginning in every method that gets/sets some data
    protected abstract def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
    protected abstract def multiassign_end
    protected abstract def is_multiassign? : Bool # if locked, #update should not be called (for all non-root tables)

    def []?(index : Index) : T|Nil # can be overridden, if necessary
        assert(in_bounds?(index))
        table, index2 = map_cell(index)
        table[index2]?
    end
    def []=(index : Index, value : T) : Index # can be overridden, if necessary
        assert(in_bounds?(index))
        table, index2 = map_cell(index)
        table[index2] = value
        index
    end
    def hyperplane_is_rank(norm_dimension : Int32, index : Index) : Bool # must be overridden by root tables
        assert(in_bounds?(index))
        table, index2 = map_cell(index)
        table.hyperplane_is_rank(norm_dimension, index2)
    end
    def hyperplane_get_rank(norm_dimension : Int32, index : Index) : Int32? # must be overridden by root tables
        assert(in_bounds?(index))
        table, index2 = map_cell(index)
        table.hyperplane_get_rank(norm_dimension, index2)
    end
    def hyperplane_add(dimension : Int32, index=Index.new(size.size, -1), **args) : Index # append hyperplane globally (with nil values); need not necessarily show up in "self" table; must be overridden by root tables
        # we need "args" to be able to pass optional args in same cases (e.g. field names, field type)
        res = map_hyperplane(dimension, index).not_nil!
        res[0].hyperplane_add(res[1], res[2], **args)
        # be aware: hyperplane_add does not make an automatic move of the hyperplane to the proper position (indicated by "index")
    end
    def hyperplane_remove(dimension : Int32, index : Index, **args) # remove hyperplane globally; must be overridden by root tables
        res = map_hyperplane(dimension, index).not_nil!
        res[0].hyperplane_remove(res[1], res[2], **args)
    end
    # move ensures that the "from" hyperplane has the "to" dimension index at the end; must be overridden by root tables
    def hyperplane_move(dimension : Int32, index_from : Index, index_to : Index) : Index
        root_from = hyperplanes(dimension, index_from).last
        root_to = hyperplanes(dimension, index_to).last
        table = root_from[0]
        assert(table == root_to[0])
        assert(dimension == root_to[1])
        table.hyperplane_move(dimension, root_from[2], root_to[2]) # needs to be overridden by root table
        index_to
    end
    def hyperplane_get_ids(norm_dimension : Int32) # must be overridden by root tables
        table, _ = map_cell(Array(Int32).new(size.size, 0))
        table.hyperplane_get_ids(norm_dimension)
    end
    def hyperplane_get_name(dimension : Int32, index : Index) : String # must be overridden by root tables
        table, index2 = map_cell(index)
        table.hyperplane_get_name(dimension, index2)
    end
    def hyperplane_get_default(dimension : Int32, index : Index) : T|Nil # must be overridden by root tables
        res = map_hyperplane(dimension, index).not_nil!
        res[0].hyperplane_get_default(res[1], res[2])
    end
    protected def hyperplanes(dimension : Int32, index : Index)
        HyperplaneIterator(Table::Lazy::Base(T)).new(self, dimension, index)
    end
    private class HyperplaneIterator(U)
        include Iterator({U, Int32, Index})
        def initialize(@table : U, @dimension : Int32, @index : Index)
        end
        def next
            res = {@table, @dimension, @index}
            if res = @table.map_hyperplane(@dimension, @index)
                @table, @dimension, @index = res[0], res[1], res[2] # crystal bug (at least 1.4.1), needs explicit tuple-dereferencing
            else
                res = Iterator::Stop::INSTANCE
            end
            res
        end
    end
    private def dimindex2index(dimension : Int32, dimindex : Int32)
        (0...size.size).map_with_index {|_,i| i==dimension ? dimindex : 0}
    end
end
