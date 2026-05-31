# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "./global"

# this file is strongly bound to virtualtable.cr

module Interface::ReferenceModifier(T)
    abstract def modify(rank : Int32, value : T)
end

module Interface::ReferenceConstrainer(T)
    abstract def constrain(constraints : Hash(Int32,Int32)) : {Array(Int32), Int32} # array of {column,rank} pairs -> {ordered rank indices, first breaking index}
end

# TODO(refcell): this maps to a searchable dropdown widget (a plain String maps to a text input)
# beware: the rank here is starting from 0 (GUI rank from 1)!
# workflow:
# - gets constructed by somebody calling VT#[]
# - updates VT by somebody calling VT#[]=(index,self); since "somebody" is done from outside: no need to store index here
# - should only deal with rank and value here (VT takes care about recordLID)
# be aware: rank==0 is for "(no reference)"
class ReferenceCell(T)
    include Interface::Referenceable
    @constraints = Hash(Int32,Int32).new
    @constraints_ranks : Array(Int32)
    def initialize(@rank : Int32, @showall : Bool, @values : Array(T),
        @modifier : Interface::ReferenceModifier(T),
        @constrainer : Interface::ReferenceConstrainer(T))

        assert(@rank < @values.size)
        @constraints_ranks = (1...@values.size).to_a + [0] # elements are (1:1) indices into @values; unconstrained at beginning
        @constraints_first_broken_index = @values.size - 1 # only special handling of rank 0 "(no reference)"
        @constraints_dirty = false
    end
    def hash(hasher) # needed since struct doesn't work (in class two "identical" instances are treated as not equal)
        @rank.hash(hasher) # attention: assuming only instances of the same ReferenceCell(T)s are put into a Hash!
    end
    def ==(other : ReferenceCell(T))
        rank == other.rank
    end
    property rank : Int32 # gets read (a) from widget or (b) when somebody calls VT#[]= (which modifies DB)
    getter values
    def showall : Bool
        @showall
    end
    protected getter modifier, constrainer, constraints, constraints_ranks, constraints_first_broken_index
    def constrain(constraints : Hash(Int32,Int32)) # constraints are only used for iterators!
        @constraints = constraints.dup # need to dup because of lazy evaluation
        @constraints_dirty = true
    end
    def value : T # the value to be displayed
        @values[@rank]
    end
    def value=(v : T) : T # directly modifies DB (renames the pointed-to cell)
        @modifier.modify(@rank, v)
        v
    end
    def inspect(io : IO) : Nil # used for p'ing a RC (e.g. when debugging)
        io << "\"#{rank}-#{value}\""
    end
    def each_defined_fulfilling(&) # enumerates all but the undefined ReferenceCell(T)s (e.g. not {0, "(no reference)"}) _and_ not breaking constraints
        update_constraints
        ReferenceCellIterator(T).new(self, 0, @constraints_first_broken_index).each {|el| yield(el)}
    end
    def each_defined_fulfilling
        update_constraints
        ReferenceCellIterator(T).new(self, 0, @constraints_first_broken_index).each
    end
    def each_defined_breaking(&) # enumerates all breaking constraints and the undefined ReferenceCell(T)s (e.g. not {0, "(no reference)"})
        update_constraints
        ReferenceCellIterator(T).new(self, @constraints_first_broken_index, @values.size).each {|el| yield(el)}
    end
    def each_defined_breaking
        update_constraints
        ReferenceCellIterator(T).new(self, @constraints_first_broken_index, @values.size).each
    end
    private def update_constraints
        if @constraints_dirty
            @constraints_ranks, @constraints_first_broken_index = @constrainer.constrain(@constraints)
            @constraints_dirty = false
        end
    end
    private class ReferenceCellIterator(T)
        include Iterator(ReferenceCell(T))
        def initialize(@refcell : ReferenceCell(T), first : Int32, @last : Int32) # last is exclusive
            @index = first
        end
        def next
            if @index < @last
                index = @refcell.constraints_ranks[@index] # indirection over constraints to get real index
                @index += 1
                rc = ReferenceCell(T).new(index, @refcell.showall, @refcell.values, @refcell.modifier, @refcell.constrainer)
                rc.constrain(@refcell.constraints)
                rc
            else
                stop
            end
        end
    end
end
