# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

alias Table::Index = Array(Int32)

abstract class Table::Base(T)
    abstract def size : Index
    abstract def []?(index : Index) : T|Nil
    abstract def []=(index : Index, value : T) : Index # near-user assignment needs to return Index due to sticky cursor requirement
    def [](index : Index) : T
        self[index]?.as(T) # can also be nil, but only if T.nilable?
    end
    def each # construct an iterator
        TableIterator(T).new(self).each {|el| yield(el)}
    end
    def each # construct an iterator
        TableIterator(T).new(self)
    end
    def to_csv # works only for <= 3 dimensions
        assert(!(size.size>3))
        seps = StaticArray["\n", ";", "/"]
        String.build do |str|
            virgin = true
            each.with_dim do |el, dim|
                sep = virgin ? "" : seps[dim]
                str << "#{sep}#{el}"
                virgin = false
            end
        end
    end
    def to_a
        res = Array(T).new
        each do |el|
            res << el
        end
        res
    end
    def to_a2 # 2-dim only due to Crystal's static typing; TODO(table): could generalise to a fixed number of dimensions via macros
        assert(!(size.size!=2))
        res = Array(Array(T)).new
        if size.min > 0 # convention: we only fill in subarrays if all dimensions have values
            res << Array(T).new # start with a first row
            each.with_dim do |el,dim|
                res << Array(T).new if dim==0
                res[-1] << el
            end
        end
        res
    end
    def to_s # works only for 2 dimensions (due to layouting) and only for T==String
        assert(!(size.size>2))
        to_a2.to_s2
    end
    protected def in_bounds?(index : Index) : Bool # helper method for subclasses
        s = size
        res = (index.size == s.size)
        s.size.times do |i|
            res = false if index[i]<0
            res = false if index[i]>=s[i]
        end
        res
    end
    # (standard) iterator for base table
    private class TableIterator(T)
        include Iterator(T)

        # adapted from iterator.cr
        def with_index2 # w/o block; index is Array(Int32), opposed to standard Int32; therefore postfix "2"
            WithIndex2(typeof(self), T).new(self)
        end
        def with_index2 # w/ block
            each do |value|
                yield(value, @index)
            end
        end
        private class WithIndex2(I, T)
            include Iterator({T, Index})
            include IteratorWrapper
            def initialize(@iterator : I)
            end
            def next
                {wrapped_next, @iterator.index}
            end
        end

        # adapted from iterator.cr; this is mainly used to provide a one-liner generic Table#to_csv
        def with_dim # w/o block
            WithDim(self.class, T).new(self)
        end
        def with_dim # w/ block
            each do |value|
                yield(value, @dim)
            end
        end
        private class WithDim(I, T)
            include Iterator({T, Int32})
            include IteratorWrapper
            def initialize(@iterator : I)
            end
            def next
                {wrapped_next, @iterator.dim}
            end
        end

        def initialize(@parent : Base(T))
            @index = Index.new(@parent.size.size, 0)
            @index[-1] = -1
            @index_valid = (@parent.size.min > 0)
            @dim = 0
        end
        def index
            @index
        end
        def dim
            @dim
        end
        def next
            if @index_valid
                s = @parent.size
                i = @index.size-1
                while i>=0
                    @index[i] += 1
                    break if @index[i] < s[i]
                    i -= 1
                end
                if i>=0
                    @dim = i
                    while i<s.size-1
                        i += 1
                        @index[i] = 0
                    end
                else
                    @dim = 0
                    @index_valid = false
                end
            end
            if @index_valid
                @parent[@index]
            else
                Iterator::Stop::INSTANCE
            end
        end
    end
end
