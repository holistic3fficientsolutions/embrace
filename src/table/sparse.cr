# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# key ideas
# - class that operates in linear time wrt. to number of used cells but supports quadratic access (i.e. by row and column)
# - iterator traverses the rows/columns/cells indices, _not_ the cell values (i.e. unlike normal crystal iterators)
# - class ensures that enumeration is always done in sorted order (forward or optionally backward)

require "./base"
require "../patch"

class Table::Sparse(T) < Table::Base(T) # e.g. T=Array(Int32)
    private class SortedSet(T)
        def initialize
            @array = Array(T).new
            @set = Hash(T,Bool).new # Set does not offer #last_key, so we use Hash
            @is_sorted = true
        end
        def initialize(array : Array(T))
            @array = array.sort
            @set = @array.each_with_object(SortedSet(T).new) {|el,set| set.add?(el)}
            @is_sorted = true
        end
        def add?(value : T) : Bool
            res = false
            if @set[value]?.nil?
                last = @set.last_key?
                res = @set[value] = true
                @array << value
                @is_sorted &&= !last || (last < value)
            end
            res
        end
        def includes?(value : T) : Bool
            @set[value]?
        end
        def delete(value : T) : Bool
            @is_sorted = false
            @set.delete(value)
        end
        def each : MyIterator(T)
            ensure_sorted
            MyIterator(T).new(@array)
        end
        def each(&block : T->)
            ensure_sorted
            MyIterator(T).new(@array).each(&block)
        end
        def each_starting_with(value : T) : MyIterator(T)
            ensure_sorted
            MyIterator(T).new(@array, value)
        end
        def each_starting_with(value : T, &block : T->)
            ensure_sorted
            MyIterator(T).new(@array, value).each(&block)
        end
        private def ensure_sorted
            if !@is_sorted
                @array = @set.keys.sort
                @is_sorted = true
            end
        end
        private class MyIterator(T)
            include Iterator(T)
            @step = 1
            @starting_with : T|Nil = nil
            @index : Int32 | Nil = nil
            def initialize(@array : Array(T))
            end
            def initialize(@array : Array(T), @starting_with : T)
            end
            def reverse
                @step = -@step
                self
            end
            def next
                index = @index
                if index.nil?
                    if starting_with = @starting_with
                        if @step > 0
                            index = @array.bsearch_index {|el,i| el>=starting_with} || @array.size
                        else
                            index = (@array.bsearch_index {|el,i| el>starting_with} || @array.size) - 1
                        end
                    else
                        index = (@step>0 ? 0 : @array.size-1)
                    end
                else
                    index = index.not_nil! + @step
                end
                @index = index
                if index < 0 || index >= @array.size
                    Iterator::Stop::INSTANCE
                else
                    @array[index]
                end
            end
        end
    end
    def initialize(@size : Index)
        assert(@size.size == 2)
        @cells = Hash(Index,T).new # this is sparse!
        @rows = Hash(Int32,SortedSet(Index)).new {|hash,key| hash[key] = SortedSet(Index).new}
        @cols = Hash(Int32,SortedSet(Index)).new {|hash,key| hash[key] = SortedSet(Index).new}
    end
    def size : Index
        @size
    end
    def row(index : Int32)
        @rows[index]
    end
    def col(index : Int32)
        @cols[index]
    end
    def rows # iterating over SortedSet(Index)
        SparseTableRowColIterator(SortedSet(Index)).new(@rows)
    end
    def cols
        SparseTableRowColIterator(SortedSet(Index)).new(@cols)
    end
    def []?(index : Index) : T|Nil
        assert(in_bounds?(index))
        @cells[index]?
    end
    def []=(index : Index, value : T) : Index
        assert(in_bounds?(index))
        @rows[index[0]].add?(index)
        @cols[index[1]].add?(index)
        @cells[index] = value
        index
    end
    private class SparseTableRowColIterator(T)
        include Iterator(T)
        @keys : Array(Int32)
        def initialize(@rowcol : Hash(Int32,T))
            @it = 0
            @keys = rowcol.keys
        end
        def next
            result = Iterator::Stop::INSTANCE
            if @it < @keys.size
                result = @rowcol[@keys[@it]]
                @it += 1
            end
            result
        end
    end
end
