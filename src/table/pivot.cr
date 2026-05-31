# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../global"
require "../tree"
require "./base"
require "./raw"
require "./lazy"
require "./sparse"
require "../patch"
require "../exception"

# Pivot tables (in addition to Lazy and in contrast to Raw) are sparse and can have container as cells

# design considerations ("->" denotes taken choices)
# - Pivot::Simple has both external dependencies and internal caches (sparse cells with arrays of row_ids)
#     -> so it has to _use_ SparseTable internally
#         - "using" e.g. also means that it has to re-initialize the SparseTable on an update "event"; this would be hard if subclassed
#     - and also provide a sparse iterator interface to the outside (needed by Pivot::Hierarchic)
#     - so it has to _subclass_ Table
#     - so even if the #[] et al are redirected to the SparseTable, it's not a subclass of SparseTable
#     - important for later use: the #rows iterator return the intersection cells in order of 1. row, 2. col, 3. row_id (1 and 2 are switched for the #cols iterator)
# - Pivot::Hierarchic also has both external dependencies and internal caches
#     -> it also _uses_ Pivot::Simple internally
#     - but does _not_ expose a sparse iterator interface to the outside
#     - so it has to _subclass_ Table as well
# - interface of Pivot::Simple and Pivot::Hierarchic
#     - Pivot::Simple and Pivot::Hierarchic both get a table plus an array of row_ids which need to be considered
#     vs.
#     -> both get tables containing exactly the rows to be considered -> needs a Reduced(T) that takes a row_id array in the constructor and has O(1) setup time
# - #[] : T; but doesn't work well for Pivot::Simple
# - return type T works also for pivots, _if_ union type T gets developed iteratively like this:
#    - String, +Nil, +Float64, ...

# currently single value or "(<count>)"
# be aware that this class inherits from normal lazy tables

class Table::Lazy::Aggregate(T) < Table::Lazy::Base(T)
    @version : Int32? = nil
    @sums_cache = Hash(Index,Int64|Float64|Nil).new
    def initialize(@parent : Table::Lazy::Raw::Base(T), @columns : Array(Array(Int32)))
        @empty_table = Table::Lazy::Raw::Memory(T).new([0])
    end
    def size : Index
        update
        if @columns.size == 0
            [1,1]
        else
            [@columns.size, @columns.map(&.size).max]
        end
    end
    def []?(index : Index) : T|Nil
        update
        assert(in_bounds?(index))
        s = @parent.size[0]
        res = mymap_cell(index)
        if res
            if res[1].nil?
                "##{s}" # no aggregate columns defined at all
            elsif s!=1
                if !@sums_cache.has_key?(index)
                    table = get_table(index)
                    assert(table.size.size == 1)
                    sum = table.each.reduce(0i64) do |acc,el|
                        case el
                        when Int64, Float64
                            acc.nil? ? nil : acc + el
                        else
                            nil
                        end
                    end
                    @sums_cache[index] = sum
                end
                sum = @sums_cache[index]
                if sum.nil?
                    "##{s}"
                else
                    "##{s}/\u03a3#{sum}"
                end
            else
                res[0][res[1].not_nil!]
            end
        else
            NilDeadArea
        end
    end
    def []=(index : Index, value : T) : Nil
        update
        assert(in_bounds?(index))
        res = mymap_cell(index)
        if !(res && !res[1].nil?)
            raise ConditionsNotMet.new("No assignment possible")
        end
        res[0][res[1].not_nil!] = value
    end
    protected def get_table(index : Index) : Table::Lazy::Raw::Base(T)
        update
        assert(in_bounds?(index))
        if @columns.size == 0 # no aggregate at all defined?
            @parent # full table
        elsif (row = @columns[index[0]]?) && (c = row[index[1]]?) # valid index?
            @parent.slice([nil,c])
        else
            @empty_table # "unused aggregate index"
        end
    end
    protected def map_cell(index : Index) : {Table::Lazy::Raw::Base(T),Index}
        update
        res = mymap_cell(index)
        assert(res && !res[1].nil?)
        {res[0], res[1].not_nil!}
    end
    private def mymap_cell(index : Index) : {Table::Lazy::Raw::Base(T),Index|Nil} | Nil
        s = @parent.size[0]
        c = nil
        (row = @columns[index[0]]?) && (c = row[index[1]]?)
        if @columns.size > 0 # aggregates defined, so we need to obey them
            if c
                # valid aggregate region
                if s == 1
                    # in case there is (a) at least one aggregate column defined and (b) exactly one parent row, we can yield the original value
                    {@parent, [0,c]}
                else
                    {@parent, [0,c]} # just the first candidate, most notably for #hyperplane_get_name
                end
            else
                nil
            end
        else
            {@parent, nil} # the full table, not an artificial singularity
        end
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Raw::Base(T),Int32,Index}|Nil
        update
        res = mymap_cell(index)
        assert(res && !res[1].nil?)
        {res[0], dimension, res[1].not_nil!} # we just pass on the dimension
    end
    protected def version : Int32
        @parent.version
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if locked, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
    private def update
        if !is_multiassign? && (@version != @parent.version)
            @sums_cache.clear
            @version = @parent.version
        end
    end
end

# T being type of input table cell
# U being type of input table reference cell
# **important**: Hierarchic may call us with index out of bounds! this happens when Hierarchic needs to resize the Simple's rectangle to a bigger one
# we need to react properly, e.g. return nil or empty tables etc; so this is a sort of padding.
# TODO(pivot): awkward responsibility split — Hierarchic makes the split but never defines the padding value, so Simple supplies it here
class Table::Lazy::Pivot::Simple(T,U) < Table::Lazy::Raw::Base(T)
    @version : Int32?
    protected def initialize(@parent : Table::Lazy::Raw::Base(T), @constraints : Hash(Int32,Int32), @row_headers : Array({column: Int32, sort_asc?: Bool}), @col_headers : Array({column: Int32, sort_asc?: Bool}))
        @headers = Table::Sparse(RootedTree(T, T)).new([0,0]) # node is the header value, edge is the child header value
        @tables = Table::Sparse(Table::Lazy::Raw::Base(T)).new([0,0]) # will have subtables of @parent; header cells will just have 1-dim tables, having all representant cells of the corresponding @parent column; intersection cells have 2-dim with only some rows removed, no columns
        @version = nil
        # dummy initializers follow
        @tree_row = RootedTree({Int32,Int32}, T).new({0,0}) # actually we are only interested in the edge structure, not the node values (rest would work with automatic variables)
        @tree_col = RootedTree({Int32,Int32}, T).new({0,0}) # dito
        @rw = @cw = @rh = @ch = 0
        @empty_table = Table::Lazy::Raw::Memory(T).new([0])
        @empty_tree = RootedTree(T,T).new(nil) # info: due to this nil needs to be part of T
        # update not here, only lazily; this is also safer, since e.g. "self" is not ready yet
    end
    def size : Index
        update
        [@ch+@rw, @rh+@cw] # space for headers plus intersection cells respectively
    end
    def size_headers : Index
        update
        [@ch, @rh]
    end
    def []?(index : Index) : T|Nil
        # actually gets called for header cells...
        # ... as well as for empty (nil) intersection cells (if there's no Aggregate leaf in the Hierarchic tree due to sparse storage)
        # ... or if this subblock gets padded (i.e. Hierarchic reserves more space than it actually has)
        update
        s = size
        assert((index[0]<=s[0]) && (index[1]<=s[1])) # we allow out of bounds, but at most by one
        if in_header_bounds?(index)
            if (index[0] < @ch) && (index[1] < @rh)
                NilDeadArea
            else
                (@headers[index]? || @empty_tree).value # mostly non-sparse (only not in constricted VT cases)
            end
        else
            nil # either #in_bounds? (i.e. sparse "hole") or padding (slightly out of bounds)
        end
    end
    def []=(index : Index, value : T) : Nil
        # actually gets called only for header cells and for empty (nil) intersection cells;
        # but only in the former case it is well defined
        update
        if !in_header_bounds?(index)
            # we should only be called for header cells; can happen in edge cases, e.g. spec/table/vt-pivot_spec.cr, "hunting bugs #14"
            raise ConditionsNotMet.new("No assignment possible")
        end
        cell = (@headers[index]? || @empty_tree).value
        # in the non-reference case, we manually change all values in this (local) cluster
        cell = @tables[index] # always dense for headers
        (0...cell.size[0]).each do |i|
            cell[[i]] = value
        end
    end
    protected def get_siblings(index : Index) : Array(T)
        update
        assert(in_header_bounds?(index))
        assert((index[0] >= @ch) || (index[1] >= @rh))
        res = Array(T).new
        if tree = @headers[index]?
            tree.parent.not_nil!.each {|e,n| res << n.value} # up one level, then all children
        end
        res
    end
    protected def map_cell(index : Index) : {Table::Lazy::Raw::Base(T),Index}
        update
        assert(in_header_bounds?(index)) # we should only be called for header cells
        cell = @tables[index]
        assert(cell.size[0] > 0)
        {cell, [0]} # return first candidate of tabs
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Raw::Base(T),Int32,Index}|Nil
        raise EmbraceException.new("map_hyperplane on Simple not defined")
        # doesn't work since either (a) we have multiple header cells or (b) unused/nil intersection cells
    end
    protected def get_table(index : Index) : Table::Lazy::Raw::Base(T)
        update
        @tables[index]? || @empty_table
    end
    protected def rows
        update
        @tables.rows
    end
    protected def cols
        update
        @tables.cols
    end
    def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
        update if !@version
        @version.not_nil!
    end
    protected def get_clusters(index : Index) : Hash(Int32, {T, Int32?}) # column_index => {value, rank}
        res = Hash(Int32, {T, Int32?}).new
        [index[0]+1,@ch].min.times do |row|
            cl = get_cluster_single([row, index[1]])
            res[cl[0]] = cl[1..] if cl
        end
        [index[1]+1,@rh].min.times do |col|
            cl = get_cluster_single([index[0], col])
            res[cl[0]] = cl[1..] if cl
        end
        res
    end
    protected def get_index(clusters : Hash(Int32, {T, Int32?}), is_leaf : Bool, get_min = true) : Index
        # only returns correct index if points to intersection (i.e. will be slightly off in case of header index)
        values = @row_headers.select {|el| clusters[el[:column]]?} .map {|el| clusters[el[:column]][0]}
        row = get_index_part(values, @tree_row, get_min)
        values = @col_headers.select {|el| clusters[el[:column]]?} .map {|el| clusters[el[:column]][0]}
        column = get_index_part(values, @tree_col, get_min)
        if is_leaf # a header is referenced
            if row
                [row[1]+@ch, row[0]]
            elsif column
                [column[0], column[1]+@rh]
            else
                assert(false)
            end
        else # either we're a higher Simple or there's at least one Aggregate below still
            [row ? row[1]+@ch : @ch, column ? column[1]+@rh : @rh]
        end
    end
    private def get_index_part(values : Array(T), tree : RootedTree({Int32,Int32}, T), get_min : Bool) : {Int32,Int32}|Nil
        # all items in `values` need to match; we output the corresponding "column" index into `headers` that matches all
        # we return a tuple of {depth, width} of the match in the tree (or nil)
        # in case of `get_min==true` we return the (inclusive) minimum index, otherwise the (exclusive) maximum index
        if values.empty?
            nil
        else
            level = 0
            values.each do |v|
                level += 1
                tree2 = tree[v]?
                break if tree2.nil? # one of the clusters is not matching -> abort
                tree = tree2
            end
            if get_min
                {level-1, tree.value[0]} # we yield _inclusive_ values
            else
                {level, tree.value[1]} # we yield _exclusive_ values
            end
        end
    end
    private def get_cluster_single(index : Index) : {Int32, T, Int32?}|Nil
        col = nil
        if (index[0] < @ch) && (index[1] < @rh)
            # nothing, top left quadrant
        elsif (index[0] < @ch) && (index[1] >= @rh) # top right quadrant
            col = @col_headers[index[0]][:column]
        elsif (index[0] >= @ch) && (index[1] < @rh) # bottom left quadrant
            col = @row_headers[index[1]][:column]
        else
            # also nothing, bottom right quadrant
        end
        if col && in_bounds?(index)
            value = (@headers[index]? || @empty_tree).value
            if value.is_a?(Interface::Referenceable) # special handling, since table could still be empty in this case
                rank = value.rank
            else
                tab = get_table(index)
                rank = (tab.size[0] > 0) ? tab.hyperplane_get_rank(1, [0]) : nil
            end
            {col, value, rank}
        else
            nil
        end
    end
    private def update # the update mechanism, should be called at the beginning in every method that gets/sets some data
        if !is_multiassign? && (@version != @parent.version)
            # important: all the single steps have O(n), so overall runtime is still linear!
            # create the headers
            row_headers_indices = @row_headers.map(&.[:column])
            col_headers_indices = @col_headers.map(&.[:column])
            tree_row = cluster_row_ids(row_headers_indices)
            tree_col = cluster_row_ids(col_headers_indices)
            sort_cluster(tree_row, @row_headers)
            sort_cluster(tree_col, @col_headers)
            @tree_row = simplify_tree(tree_row)
            @tree_col = simplify_tree(tree_col)
            # save sizes
            @rw = tree_row.width
            @cw = tree_col.width
            @rh = tree_row.height
            @ch = tree_col.height
            # calculate all the intersection sets
            @tables = typeof(@tables).new([@ch+@rw, @rh+@cw])
            calculate_intersections(tree_row, tree_col)
            # calculate the header cells
            row_header_matrix = calc_headers(tree_row, row_headers_indices).transpose
            col_header_matrix = calc_headers(tree_col, col_headers_indices)
            @headers = typeof(@headers).new([@ch+@rw, @rh+@cw])
            copy_headers(row_header_matrix, {@ch, 0})
            copy_headers(col_header_matrix, {0, @rh})
            @version = @parent.version
        end
    end
    private def cluster_row_ids(column_ids : Array(Int32)) # column_ids: array of column _IDs_ (i.e. types), e.g. [1,3] meaning ["Quarter", "Name"]
        tree = RootedTree(Set(Int32), T).new
        # first, we insert row-by-row - we push every row_id down to the leaf
        (0...@parent.size[0]).each do |row|
            parent = tree # we always start with the root
            constraints = @constraints.dup # column_index => rank index; TODO(pivot): slow
            parent.value.add(row) # we add the rows to all nodes, also root node
            column_ids.each do |col_id|
                value = @parent[[row, col_id]]
                value.constrain(constraints) if value.is_a?(Interface::Referenceable) # we constrain header cells already here
                rank = value.is_a?(Interface::Referenceable) ? value.rank : @parent.hyperplane_get_rank(1, [row, col_id]) # important differentiation (this is inline with VT#constrain_reference)
                constraints[col_id] = rank if rank # prepare for next internal Simple level
                child = parent[value]?
                if child.nil?
                    child = parent.add_subtree(value)
                end
                child.value.add(row) # we add the rows to all nodes
                parent = child
            end
        end
        # second, we take care for `showall`, independent of any individual rows, but taking the tree as a whole
        constraints = @constraints.dup # column_index => rank index
        tree.dfs_downup do |isdown,edge,node,level|
            # first, managing constraints
            if level > 0 # root node is artificial
                col_id = column_ids[level-1]
                if edge.is_a?(Interface::Referenceable)
                    rank = edge.rank
                else
                    row = node.value.first?
                    rank = @parent.hyperplane_get_rank(1, [row, col_id]) if row
                end
                if rank
                    if isdown
                        constraints[col_id] = rank # prepare for next internal Simple level
                    else
                        constraints.delete(col_id)
                    end
                end
            end
            # second, creating new (constrained) children, if needed
            if level < column_ids.size # we create children, also for artificial root node
                col_id = column_ids[level]
                value = @parent.hyperplane_get_default(1, [0,col_id])
                if isdown
                    if value.is_a?(Interface::Referenceable) && value.showall
                        value.constrain(constraints)
                        value.each_defined_fulfilling do |value2|
                            child = node[value2]?
                            node.add_subtree(value2) if child.nil?
                        end
                    elsif !tree.value.empty? && node.value.empty?
                        node.add_subtree(nil) # make tree have uniform depth (again)
                    end
                end
            end
        end
        tree
    end
    private def simplify_tree(tree : RootedTree(Set(Int32), T)) : RootedTree({Int32, Int32}, T)
        res = RootedTree({Int32, Int32}, T).new({0,0})
        tree_mapper = {tree => res}
        count = 0
        tree.dfs_downup do |is_down,edge,child,level|
            # careful: edge is of type T and can be `nil` -> hence we use `level`
            if (level>0) && is_down
                child2 = RootedTree({Int32, Int32}, T).new({0,0})
                child2.value = {count,0}
                tree_mapper[child.parent.not_nil!].add_subtree(edge, child2)
                tree_mapper[child] = child2
                count += 1 if child.size == 0
            end
            if !is_down
                child2 = tree_mapper[child]
                child2.value = {child2.value[0],count}
            end
        end
        res
    end
    private def sort_cluster(tree : RootedTree(Set(Int32),T), headers : Array({column: Int32, sort_asc?: Bool}))
        tree.dfs_up do |_,node,level|
            node.sort_children!(headers[level][:sort_asc?]) if level<headers.size
        end
    end
    private def calculate_intersections(tree_row, tree_col)
        numrows = @parent.size[0]
        rowid2matrixindex = Table::Lazy::Raw::Memory(Int32).new([numrows,2]) # all the Arrays and StaticArrays don't work well
        augment_rows(rowid2matrixindex, tree_row, true)
        augment_rows(rowid2matrixindex, tree_col, false)
        cells = Hash({Int32,Int32},Array(Int32)).new
        (0...numrows).each do |rowid|
            r = rowid2matrixindex[[rowid,0]]
            c = rowid2matrixindex[[rowid,1]]
            cells[{@ch+r,@rh+c}] ||= Array(Int32).new
            cells[{@ch+r,@rh+c}] << rowid
        end
        cells.keys.sort.each do |k| # this way we store with prio 1. row, 2. col, 3. row_id! (which is important for #rows, #cols)
            v = cells[k]
            @tables[k.to_a] = Table::Lazy::Raw::Reduced(T).new(@parent, 0, v)
        end
    end
    # map the intersection cell position to the original row_ids (two calls necessary: one for row, one for col)
    private def augment_rows(rowid2matrixindex, tree, is_row)
        index = 0
        tree.dfs_down do |_,child|
            if child.size == 0 # we consider only leaves
                child.value.each {|rowid| rowid2matrixindex[[rowid,is_row ? 0 : 1]] = index}
                index += 1 # nevertheless we always advance to the next (matrix) index
            end
        end
    end
    private def calc_headers(tree : RootedTree(Set(Int32),T), column_ids : Array(Int32))
        # make matrix out of tree (fill up empty cells)
        # we need to calculate both the (singular) header as well as the subtables
        headers = Array(Array({RootedTree(T,T),Table::Lazy::Raw::Base(T)})).new
        ri = -1 # (last) rightmost index
        tree2tree = Hash(RootedTree(Set(Int32),T), RootedTree(T,T)).new # we use this embedded tree for easy Index=>RootedTree(T,T) nodes
        tree.dfs_up do |edge, node, level|
            while headers.size < level
                headers.push(Array({RootedTree(T,T),Table::Lazy::Raw::Base(T)}).new)
            end
            if level > 0 # exclude root
                level -= 1
                parent = (tree2tree[node.parent.not_nil!] ||= RootedTree(T,T).new(nil)) # value gets set correctly one level up in the tree (when parent is the "child")...
                child = (tree2tree[node] ||= RootedTree(T,T).new(edge))
                child.value = edge # ...here
                parent.add_subtree(edge, child)
                tab = @parent.slice([nil,column_ids[level]]) # slicing just the one header column
                tab = Table::Lazy::Raw::Reduced(T).new(tab, 0, node.value.to_a) # reducing to only the relevant rows
                headers[level].push({child, tab})
                i = headers[level].size - 1
                if ri > i # fill up conditionally
                    headers[level].concat([headers[level][i]]*(ri-i))
                end
                ri = [i, ri].max
            end
        end
        headers
    end
    private def copy_headers(header, offset)
        header.size.times do |row|
            header[row].size.times do |col|
                cell = header[row][col]
                @headers[[offset[0]+row,offset[1]+col]] = cell[0]
                @tables[[offset[0]+row,offset[1]+col]] = cell[1]
            end
        end
    end
    protected def in_header_bounds?(index : Index) : Bool # helper method for subclasses
        s = size_headers
        in_bounds?(index) && ((index[0]<s[0]) || (index[1]<s[1]))
    end
    protected def is_row_header?(index : Index) : Bool? # true: row header, false: column header, nil: else
        s = size_headers
        if in_header_bounds?(index)
            if (index[0]<s[0]) && (index[1]>=s[1]) # top headers
                false
            elsif (index[0]>=s[0]) && (index[1]<s[1]) # left headers
                true
            else
                nil
            end
        else
            nil
        end
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        @parent.multiassign_begin
    end
    protected def multiassign_end
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if locked, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end

# column indices in fieldlist
enum Table::Lazy::Pivot::FieldlistColumns
    Rank # TODO(pivot): calculated level; couples this enum to Indexed usage
    Column # index
    PivotClass
    Level
    IsRowColSortAsc
end

enum Table::Lazy::Pivot::Classes
    Unused
    Column
    Row
    Aggregate
end

enum Table::Lazy::Pivot::Assignability
    Directly      # i.e. #[]= works; only in case of a rank you need to take care to assign only Int64 (catch exception!)
    Indirectly    # i.e. #get_cell_type(#hyperplane_add(index)) == DirectlyAssignable
    Drilldown     # i.e. #get_table(index).size neither [0] nor [1]
    Not           # #[]= never works (i.e. NilDeadArea or NilRecord)
end

# @tree structure (see #populate_hierarchy_tree) is defining the pivoting hierarchy
# in the simplest ("normal") form, root is Simple(T,U) with children Aggregate(T) with the edges {row_idx,col_idx} for sparsely exiting intersections
# - @tree inner nodes are always Simple(T,U)
# - @tree leaves are Aggregate(T)
#
# T being type of input table cell
# U being type of input table reference cell
# V being type of input fieldlist table cell
class Table::Lazy::Pivot::Hierarchic(T,U,V) < Table::Lazy::Raw::Base(T)
    @version : Int32?
    @tree : Nil | RootedTree(Table::Lazy::Base(T),{Int32,Int32})
    def initialize(@parent : Table::Lazy::Raw::Base(T), @fields : Table::Lazy::Raw::Base(V))
        @version = nil
        @tree = nil
        # dummy initializers follow
        @offsets = {} of Table::Lazy::Base(T)=>{Array(Int32),Array(Int32)} # table => {offsets_height, offsets_width}
        # the following three get calculated by #parse_fieldlist
        @row_headers = Array(Array({column: Int32, sort_asc?: Bool})).new # [level][index]
        @col_headers = Array(Array({column: Int32, sort_asc?: Bool})).new # [level][index]
        @aggregates = Array(Array(Int32)).new # rows of [columnindex1, columnindex2, ...]
        # update not here, only lazily; this is also safer, since e.g. "self" is not ready yet
        @empty_table = Table::Lazy::Raw::Memory(T).new([0])
        # @projections is a flat view on both hyperplanes, giving the priorities of scrolling them out
        @projections = {Array(Int32).new,Array(Int32).new} # 0: vertical, 1: horizontal; then: levels or -1
        @scrollorder = {Array(Int32).new,Array(Int32).new} # 0: vertical, 1: horizontal; then: priority of hyperplane to be shifted out
        @constrained_references = Hash(Index,T).new # this is for (globally) caching (that constraints don't need to be recalculated all the time)
    end
    def size : Index
        update
        offsets = @offsets[@tree.not_nil!.value]
        [offsets[0][-1], offsets[1][-1]]
    end
    def []?(index : Index) : T|Nil
        update
        table, index2 = map_index(index)
        # table.in_bounds?(index2) may also be false, Simple will react accordingly (padding)
        value = table[index2]?
        if value.is_a?(Interface::Referenceable) && get_header_info(index).nil?
            if !@constrained_references.has_key?(index)
                constraints = Hash(Int32,Int32).new
                get_clusters(index).each do |col, value_rank| # constrain, if necessary
                    rank = value_rank[1]
                    constraints[col] = rank if rank
                end
                value.constrain(constraints) # here we (lazily) constrain only non-header cells
                @constrained_references[index.dup] = value # in addition we are caching, since GUI later on queries constraints on every frame
            end
            value = @constrained_references[index]
        end
        value
    end
    def []=(index : Index, value : T) : Index
        update
        if self[index].is_a?(ReferenceCell) != value.is_a?(ReferenceCell)
            raise ConditionsNotMet.new("Can only assign Reference to Reference")
        end
        clusters = get_clusters(index) # column index wrt. @parent (e.g. VT or Memory)
        begin
            multiassign_begin
            table2, index2, tables = map_index(index) # index wrt. table (Hierarchic -> leaf Aggregate or Simple)
            table2[index2] = value # the actual assignment
        ensure
            index3 = multiassign_end # coming directly from @parent, from the last individual assignment (#[]=)
        end
        if index3
            clusters2 = get_parent_clusters(index3[0]) # the real cluster of the last individual assignment
            clusters2.select! {|k,_| clusters.has_key?(k)} # we keep the real cluster values, but only for the initial columns
            index4 = get_index(clusters2, tables.size) # TODO(pivot): level argument unverified (tables.size vs @row_headers.size+1); common paths are spec-covered — see get_index
            offset4 = get_aggregate_offset(index)
            (0..1).map {|i| (index4[i]+offset4[i]).as(Int32)} # return new position
        else
            @version = nil # force update, esp. for case where Persistency stays unchanged but we mixed up our caches
            index
        end
    end
    # #get_table cannot be integrated into #[]? because we should keep #[]? : T
    # similar to #[], but more versatile
    def get_table(index : Index) : Table::Lazy::Raw::Base(T)
        update
        table, index2 = map_index(index)
        if table.in_bounds?(index2)
            if table.responds_to?(:get_table)
                table.get_table(index2)
            else
                assert(false)
            end
        else
            # can also be called when the (hierarchic) corresponding Pivot::Simple is actually smaller (padding)
            @empty_table
        end
    end
    def hyperplane_add(dimension : Int32, index=Index.new(size.size, -1), **args) : Index # append hyperplane globally (with nil values); need not necessarily show up in "self" table; must be overridden by root tables
        update
        case dimension
        when 0 # adding a record; BTW: underlying table takes care that it will be visible
            case get_assignability(index)
            when nil # index out of bounds; this also means we cannot assign any clusters
                # globally add record, e.g. also to empty table
                index2 = @parent.hyperplane_add(0) # index wrt. @parent
                # BTW: if there is no field, then also Hierarchic will still be empty
                clusters = get_parent_clusters(index2[0])
                get_index(clusters, @row_headers.size+1) # we assume to have @aggregate
            when Assignability::Directly
                # directly editable cell (i.e. there is "something" available) -> cloning the cell, showing up as a sibling to `index`
                # distinguish between header and non-header cell
                is_header = !get_header_info(index).nil?
                value = self[index]?

                # first we make a regular clone (different for header and non-header Hierarchic cells)
                # then we treat header target cells special
                # be aware: cluster (clone header cells) != cloning (clone all cells)
                _, _, tables = map_index(index)
                table = get_table(index)
                if table.size[0] == 0 # there is "something" available
                    raise ConditionsNotMet.new("Currently not working on empty EnumerateAlls")
                end
                parent_table, parent_index = get_parent_index(table, [0,0]) # get to @parent
                clusters = get_clusters(index) # for new assignment further down in case of header cell
                values = (0...parent_table.size[1]).map {|i| {i, parent_table[[parent_index[0], i]]}}.to_h # dito in case of non-header cell
                candidates = nil
                if is_header # -> we only clone the clusters
                    new_values = clusters.map {|k,v| {k,v[0]}}.to_h # get rid of rank
                    if value.is_a?(Interface::Referenceable)
                        # so the existing cell is a reference cell header (three preconditions)
                        # we create a clone that's fulfilling it's constraints _and_ is unique; if not possible: create a new reference tag
                        siblings = get_siblings(index) # if we define `siblings` in #hyperplane_add below, VT takes care for creating the proper hyperplane(s)
                        candidates = value.each_defined_fulfilling.to_a - siblings
                    else
                        if !parent_table.hyperplane_is_rank(1, parent_index) # if not rank, _we_ need to make unique
                            pat = /\A~new_value_(\d\d\d)/ # TODO(pivot): this matching is currently rather cheap
                            val = (0...parent_table.size[0]).map do |i|
                                parent_table[[i,parent_index[1]]].to_s
                            end.select {|el| el =~ pat}.max? || "~new_value_000"
                            value_new = val.succ
                            new_values[parent_index[1]] = value_new
                            clusters[parent_index[1]] = {value_new, nil} # dummy rank
                        end
                    end
                else # no header -> we clone _all_ values from the @parent table
                    new_values = values
                end
                # now we're prepared: we first make the hyperplane_add, then fill the new hyperplane with the proper values
                new_values.reject! {|k,v| v==NilRecord} # for #hyperplane_add we do not try to assign these
                index2 = parent_table.hyperplane_add(0, parent_index, clusters: new_values, candidates: candidates) # clusters and candidates are handed over for information; no guarantee that it is used...
                if candidates.nil?
                    multiassign_begin
                    new_values.each do |i,value|
                        parent_table[[index2[0],i]] = value # ... hence we assign ourselves
                    end
                    multiassign_end
                else
                    clusters[parent_index[1]] = {parent_table[index2], nil} # dummy rank
                end
                # at the end we need to find the proper index of this hyperplane in the updated Hierarchic
                index3 = get_index(clusters, tables.size) # TODO(pivot): level argument unverified for the sibling/candidates case (tables.size vs @row_headers.size+1); common paths are spec-covered — see get_index
                offset3 = get_aggregate_offset(index)
                (0..1).map {|i| (index3[i]+offset3[i]).as(Int32)} # new Index
            when Assignability::Indirectly
                # empty cell -> creating a new one, at position `index` (or nearby)
                clusters = get_clusters(index)
                index2 = @parent.hyperplane_add(0) # index wrt. @parent; attention: this is neglecting any potential `index` information wrt. (non-existing) Aggregate
                table2 = Table::Lazy::Raw::Reduced(T).new(@parent, 0, [index2[0]]) # scratch Reduced table, only to reuse #cluster_according_to
                begin
                    cluster_according_to(table2, clusters)
                rescue ex : ConditionsNotMet
                    @parent.hyperplane_remove(0, index2) # undo
                    raise(ConditionsNotMet.new("Adding not possible, cannot properly assign clusters")) # passing on
                ensure
                end
                # `clusters` (the values at the clicked position) locate the new
                # record in a row-hierarchy pivot (non-Kanban). For a column pivot
                # (Kanban: a field on the column axis — e.g. state pivoted across
                # columns) the column-axis header values are NOT in `clusters`; they
                # only exist on the freshly created row, so read the full header set
                # back from the parent:
                clusters2 = get_parent_clusters(index2[0])
                # Merge into one complete header coordinate that get_index can resolve
                # in either layout; the clicked values (v1) win on conflict. Both paths
                # are exercised by the Kanban / non-Kanban specs (spec/table/pivot_spec
                # + vt-pivot_spec).
                clusters3 = clusters.merge(clusters2) {|k,v1,v2| v1}
                get_index(clusters3, @row_headers.size+1) # we assume to have @aggregate
            else # Assignability::Not or Assignability::Drilldown; TODO(pivot): we might change this
                raise ConditionsNotMet.new("Not defined on this cell type")
            end
        when 1 # adding a field -> we make it a (visible) aggregate
            case get_assignability(index)
            when Assignability::Directly
                # TODO(pivot): append field at index position (wrt. table, aggregate and cursor)
                [-1,-1]
            else # nil, `Assignability::Indirectly`, `Assignability::Not` or `Assignability::Drilldown`
                # globally add field
                index2 = @parent.hyperplane_add(1, **args) # index wrt. @parent
                clusters = get_parent_clusters(index2[0])
                get_index(clusters, @row_headers.size+1) # we assume to have @aggregate
            end
        else
            assert(false)
        end
    end
    def hyperplane_remove(dimension : Int32, index : Index, **args) # remove hyperplane globally; must be overridden by root tables
        if get_assignability(index) == Assignability::Not
            raise ConditionsNotMet.new("Not defined on this cell type")
        end
        tab = get_table(index)
        tab.each.with_index2 do |_, index2|
            raise ConditionsNotMet.new("Not defined on this cell type") if tab[index2] == NilRecord
        end
        multiassign_begin # not really a multiassign, but prevents update mechanism
        tab.each.with_index2 do |_, index2|
            tab.hyperplane_remove(dimension, index2, **args)
        end
        multiassign_end
        # BTW: fields in fieldlist get automatically removed by update channels
    end
    # move ensures that the "from" hyperplane has the "to" dimension index at the end; must be overridden by root tables
    def hyperplane_move(dimension : Int32, index_from : Index, index_to : Index) : Index
        # we ignore `dimension`, because two indices fully qualify already
        # `index_to` may point to an empty cell (i.e. just having several Simple, but no Aggregate)
        # `index_from` must point to at least one entry
        update
        _, _, tables = map_index(index_from) # index wrt. table (Hierarchic -> leaf Aggregate or Simple)
        offset2 = get_aggregate_offset(index_from)
        clusters = get_clusters(index_to) # Hash: column_index => {value, rank}
        clusters.merge!(get_clusters(index_from)) {|k,v1,v2| v1}
        tab = get_table(index_from) # Table::Lazy::Raw::Base(T)
        cluster_according_to(tab, clusters)
        index2 = get_index(clusters, tables.size)
        (0..1).map {|i| (index2[i]+offset2[i]).as(Int32)} # return new position
    end
    def hyperplane_get_name(dimension : Int32, index : Index) : String
        # dimension gets ignored for Hierarchic
        table, index2 = map_index(index) # to Simple or Aggregate
        begin
            table2, index3 = table.map_cell(index2) # to next underlying table
            table2.hyperplane_get_name(1, index3) # will be routed to root table (VirtualTable)
        rescue # since we have some "dead" cells
            ""
        end
    end
    def get_assignability(index : Index) : Assignability | Nil
        update
        if in_bounds?(index)
            value = self[index]?
            size2 = get_table(index).size
            if size2 == [0]
                case value
                when Nil
                    # Simple has no table entries (this can happen at any level; Hierarchic tree is not having uniform depth!)
                    Assignability::Indirectly
                when NilDeadArea
                    Assignability::Not
                when Interface::Referenceable # can only happen when using VirtualTable, with at least one "ShowAll"; headers might be assignable even if the cell has no tables
                    Assignability::Directly
                else
                    assert(false)
                end
            else
                case value
                when NilRecord # only with VirtualTable and at least one "ShowAll" # TODO(pivot): missing case — >=2 values where one is NilRecord
                    Assignability::Not
                else
                    # header is always assignable, also if ">" [1]
                    if (size2 == [1]) || get_header_info(index)
                        Assignability::Directly
                    else
                        Assignability::Drilldown
                    end
                end
            end
        else
            nil
        end
    end
    def get_scrollorder : {Array(Int32),Array(Int32)}
        update
        @scrollorder
    end
    def get_header_info(index : Index) : {Bool, Int32}? # is_row?, level (only counting hierarchies!) - or nil
        update
        table, index2, tables = map_index(index)
        if table.is_a?(Simple)
            h = table.is_row_header?(index2)
            if h.nil?
                nil
            else
                {h, tables.size-1}
            end
        else
            nil
        end
    end
    def get_bounding_box(index : Index) : {Index,Index}
        update
        map_index(index)[3]
    end
    protected def get_siblings(index : Index) : Array(T)
        update
        table, index2 = map_index(index)
        if table.is_a?(Simple)
            table.get_siblings(index2)
        else
            [] of T
        end
    end
    protected def get_clusters(index : Index) : Hash(Int32, {T, Int32?})
        res = Hash(Int32, {T, Int32?}).new
        _, _, tables = map_index(index) # Array({Simple(T,U)|Aggregate(T),Index})
        tables.each do |t,i|
            if t.responds_to?(:get_clusters) # Aggregate doesn't have; `t.in_bounds?(i) && ` Simple tolerates out of bounds
                res.merge!(t.get_clusters(i))
            end
        end
        res
    end
    # Public accessor for get_clusters — used by GUI drill-down.
    def get_cell_clusters(index : Index) : Hash(Int32, {T, Int32?})
        update
        get_clusters(index)
    end
    protected def map_cell(index : Index) : {Table::Lazy::Raw::Base(T),Index}
        assert(false) # we define #[]? and #[]= on our own
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Raw::Base(T),Int32,Index}|Nil
        assert(false) # we define #hyperplane_{add|remove|move} on our own
    end
    def version : Int32 # gets incremented for every #set; this is the trigger for updating caches
        update
        @version.not_nil!
    end
    private def update # the update mechanism, should be called at the beginning in every method that gets/sets some data
        version = @parent.version + @fields.version
        if !is_multiassign? && (version != @version)
            @constrained_references.clear
            parse_fieldlist
            # first, construct hierarchy tree top-down
            root = Simple(T,U).new(@parent, Hash(Int32,Int32).new, @row_headers[0], @col_headers[0]) # never empty
            @tree = RootedTree(Table::Lazy::Base(T),{Int32,Int32}).new(root)
            populate_hierarchy_tree(@tree.not_nil!, 1, Hash(Int32,Int32).new)
            # second, calculate sizes and offsets bottom-up
            calc_offsets
            # finally, we calculate the flat projections (again top-down)
            calc_projections
            # later, #map_index can calculate the index top-down again
            @version = version
        end
    end
    private def parse_fieldlist
        @row_headers.clear # [level][index] => {column_index,sort_asc?}
        @col_headers.clear # [level][index] => {column_index,sort_asc?}
        @aggregates.clear
        @row_headers << [] of {column: Int32, sort_asc?: Bool}
        @col_headers << [] of {column: Int32, sort_asc?: Bool}
        (0...@fields.size[0]).each do |i|
            container = nil
            level = @fields[[i,FieldlistColumns::Level.value]].as(Int64)
            case @fields[[i,FieldlistColumns::PivotClass.value]]
            when Classes::Row.value
                container = @row_headers
            when Classes::Column.value
                container = @col_headers
            when Classes::Aggregate.value
                while @aggregates.size <= level
                    @aggregates << Array(Int32).new
                end
                @aggregates[level] << @fields[[i,FieldlistColumns::Column.value]].as(Int64).to_i32
            when Classes::Unused.value
                # nothing
            else
                assert(false)
            end
            if container
                while container.size <= level
                    container << Array({column: Int32, sort_asc?: Bool}).new # one more
                end
                sort_asc = @fields[[i,FieldlistColumns::IsRowColSortAsc.value]]
                case sort_asc
                when Bool
                when Int32
                    sort_asc = (sort_asc==1)
                else # String
                    sort_asc = (sort_asc=="1")
                end
                container[level] << {column: @fields[[i,FieldlistColumns::Column.value]].as(Int64).to_i32, sort_asc?: sort_asc}
            end
        end
        # we enforce to have at least one element
        @row_headers << [] of {column: Int32, sort_asc?: Bool} if @row_headers.size == 0
        while (container = (@row_headers.size <=> @col_headers.size)) != 0
            container = StaticArray[@row_headers, @col_headers][(container+1)//2]
            container << [] of {column: Int32, sort_asc?: Bool}
        end
        assert(@row_headers.size == @col_headers.size)
    end
    private def populate_hierarchy_tree(tree : RootedTree(Table::Lazy::Base(T),{Int32,Int32}), level : Int32, constraints : Hash(Int32,Int32))
        table = tree.value.as(Simple(T,U))
        if level <= @row_headers.size # works since we ensured @row_headers.size == @col_headers.size
            table.rows.each do |row| # row is a Set(Index)
                row.each do |cell| # cell is an Index
                    # we populate @tree only where there is at least one row, i.e. some Aggregates or even Simples can be missing (sparse!)
                    if !table.in_header_bounds?(cell) # we only recurse on intersections (i.e. not header cells)
                        subtable = table.get_table(cell).not_nil!
                        constraints_local = constraints.dup
                        # convert subtable into pivot:
                        if level < @row_headers.size
                            # Pivot::Simple at the inner nodes
                            table.get_clusters(cell).each do |col, value_rank| # constrain, if necessary (but excl. current cell)
                                rank = value_rank[1]
                                constraints_local[col] = rank if rank
                            end
                            subtable = Simple(T,U).new(subtable, constraints_local, @row_headers[level], @col_headers[level]) # Simple doesn't modify constraints, no need to #dup
                        else
                            # Aggregate at the leaves
                            subtable = create_reduced_aggregate(subtable)
                        end
                        # make a tree and connect
                        subtree = RootedTree(Table::Lazy::Base(T),{Int32,Int32}).new(subtable)
                        tree.add_subtree({cell[0],cell[1]}, subtree)
                        populate_hierarchy_tree(subtree, level+1, constraints_local) if level < @row_headers.size
                    end
                end
            end
        end
    end
    private def create_reduced_aggregate(table : Table::Lazy::Raw::Base(T)) : Table::Lazy::Base(T)
        # first: remove classification columns
        row_headers_indices = @row_headers.flatten.map(&.[:column])
        col_headers_indices = @col_headers.flatten.map(&.[:column])
        reduced_table = Table::Lazy::Raw::Reduced(T).new(table, 1, (0...@parent.size[1]).to_a - (row_headers_indices + col_headers_indices))

        # second: adjust aggregate indices accordingly
        # example:
        #     dropped: [1,3,4,7]
        #     agg before:  [0, 2, 5,10]
        #     agg after:   [0, 1, 2, 6]
        #     helper 1: [ 0,-1, 0,-1,-1, 0, 0, 0,-1, 0, 0]
        #     helper 2: [ 0,-1,-1,-2,-3,-3,-3,-3,-4,-4,-4] # cumulated helper 1
        #     helper 3: [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10] # normal counting
        #     helper 4: [ 0, 0, 1, 1, 1, 2, 3, 4, 4, 5, 6] # helpers 2+3
        num_cols = @parent.size[1]
        dropped_columns = (@row_headers+@col_headers).flatten.map(&.[:column]).sort
        flags = Array.new(num_cols, 0)
        dropped_columns.each {|el| flags[el] = -1}
        flags = flags.accumulate
        mapper = (0...num_cols).to_a.map_with_index {|el,i| el+flags[i]}
        aggregates = @aggregates.map {|row| row.map {|el| mapper[el] } }

        Aggregate(T).new(reduced_table, aggregates)
    end
    private def calc_offsets
        tree = @tree.not_nil!
        @offsets.clear # table => {offsets_height, offsets_width}
        tree.dfs_up do |_,parenttree,level|
            parent = parenttree.value # the corresponding Table
            height = {} of Int32=>Array(Int32) # row index => [height1, height2, ...]
            width = {} of Int32=>Array(Int32) # column index => [width1, width2, ...]
            parenttree.each do |index, childtree|
                child = childtree.value # the corresponding Table
                height[index[0]] ||= Array(Int32).new
                height[index[0]] << @offsets[child][0][-1] # must already be in the cache
                width[index[1]] ||= Array(Int32).new
                width[index[1]] << @offsets[child][1][-1] # dito
            end
            if height.size == 0 # leaf
                s = parent.size
                offsets_h = (0..s[0]).to_a
                offsets_w = (0..s[1]).to_a
            else # internal node
                # height is sorted properly by design (#rows iterator in #populate_hierarchy_tree), but width has to be re-sorted
                width = width.to_a.sort {|x,y| x[0]<=>y[0]}.to_h
                # [1] is for every single header row/col
                # BTW: the values can be interpreted as the (exclusive) right/bottom boundary, i.e. the last value is equal to the size
                offsets_h = (0...parent.size[0]).map {|i| (height[i]? || [1]).max}.accumulate(0)
                offsets_w = (0...parent.size[1]).map {|i| (width[i]? || [1]).max}.accumulate(0)
            end
            @offsets[parent] = {offsets_h, offsets_w}
        end
    end
    private def calc_projections
        offsets = @offsets[@tree.not_nil!.value]
        size = [offsets[0][-1], offsets[1][-1]] # we cannot call #size yet, so we calc ourselves
        # first, we calculate helper arrays info @projections
        @projections = {Array(Int32).new(size[0],-1), Array(Int32).new(size[1],-1)} # 0: vertical, 1: horizontal; then: priority of hyperplane to be shifted out
        # @projections is prefilled with -1, for all the non-header hyperplanes (will not be filled during recursion)
        calc_projections_recurse(@tree.not_nil!)
        # second, we now really calculate the row/column order
        rows = tokenize_projection(@projections[0], @col_headers.map(&.size))
        cols = tokenize_projection(@projections[1], @row_headers.map(&.size))
        @scrollorder = {rows,cols}.map {|el| tokens_to_scrollorder(el)}
    end
    private def calc_projections_recurse(tree : RootedTree(Table::Lazy::Base(T),{Int32,Int32}), external_index = {0,0}, level = 0)
        # input: @tree = RootedTree(Table::Lazy::Base(T),{Int32,Int32}).new(root)
        # output: @projections = {Array(Int32).new(size[0],-1), Array(Int32).new(size[1],-1)} # 0: vertical, 1: horizontal
        # output will contain values >=0 for level related columns/rows, -1 for content related
        table = tree.value
        if table.is_a?(Simple(T,U)) # we're just interested in header cells
            offsets_h, offsets_w = @offsets[table]
            ch, rh = table.size_headers
            ch.times {|i| @projections[0][external_index[0]+i] = level} # the flat row priorities
            rh.times {|i| @projections[1][external_index[1]+i] = level} # the flat column priorities
            tree.each do |subindex,n| # subindex are the indices into offsets_*
                # calculate next_index analogue to #map_index
                next_index = [external_index[0]+offsets_h[subindex[0]], external_index[1]+offsets_w[subindex[1]]]
                calc_projections_recurse(n, next_index, level+1)
            end
        end
    end
    private def tokenize_projection(projection : Array(Int32), levels : Array(Int32)) : Array({Int32,Range(Int32,Int32),Range(Int32,Int32)}) # level, Range header, Range content; range is over column indices in `projection`
        res = Array({Int32,Range(Int32,Int32),Range(Int32,Int32)}).new
        i = 0
        while i < projection.size
            l = projection[i]
            header = (0...0)
            if l >= 0
                repetitions = levels[l]
                # repetitions.times {|j| assert(projection[i+j] == l)} # TODO(pivot): fails for ShowAll enumeration with an empty table
                header = (i...i+repetitions)
                i += repetitions
            end
            j = i
            while (j < projection.size) && (projection[j] < 0)
                j += 1
            end
            content = (i...j)
            res << {l, header, content}
            i = j
        end
        res << {-1, (0...0), (0...0)} # for flushing level 0
        res
    end
    private def tokens_to_scrollorder(tokens : Array({Int32,Range(Int32,Int32),Range(Int32,Int32)})) : Array(Int32)
        stack = [] of {Int32,Range(Int32,Int32),Range(Int32,Int32)}
        res = [] of Array(Int32)
        tokens.each do |token|
            while (!stack.empty?) && (token[0] <= stack[-1][0])
                el = stack.pop
                res << el[2].to_a # first content
                res << el[1].to_a # then header
            end
            stack << token
        end
        res.flatten
    end
    private def map_index(index : Index)
        # beware - this method is actually quite tricky (and did involve quite some TAE)
        tables = Array({Simple(T,U)|Aggregate(T),Index}).new
        level = 0
        tree = @tree.not_nil!
        bounding = {[0,0], [0,0]} # since we have at least one Simple, only [0] here is important ([1] will be calculated further down)
        while true
            table = tree.value
            offsets_h, offsets_w = @offsets[table]
            row_raw = offsets_h.bsearch_index {|el,i| el>index[0]}
            col_raw = offsets_w.bsearch_index {|el,i| el>index[1]}
            row = (row_raw || offsets_h.size) - 1 # we limit by size (just outside boundary), used for padding in Simple
            col = (col_raw || offsets_w.size) - 1 # dito
            if table.is_a?(Simple)
                if table.is_row_header?([row,col]).nil? # no header
                    # now we dive into the next level for bounding calculation
                    padding = {col_raw.nil?, row_raw.nil?} # beware order (swapped)
                    if !padding[0] && !padding[1]
                        2.times {|i| bounding[1][i] = bounding[0][i] + @offsets[table][i][i==0 ? row+1 : col+1] - 1}
                    end
                    2.times do |i|
                        if !padding[i]
                            bounding[0][i] += @offsets[table][i][i==0 ? row : col]
                        end
                    end
                else # we are a header, there will be no child in the tree
                    # special handling for Simple header cells
                    clusters = table.get_clusters([row,col])
                    bound1 = table.get_index(clusters, true, true) # leaf, get_min (incl.)
                    bound2 = table.get_index(clusters, true, false) # leaf, get_max (excl.)
                    2.times {|i| bounding[1][i] = bounding[0][i] + @offsets[table][i][bound2[i]] - 1}
                    2.times {|i| bounding[0][i] += @offsets[table][i][bound1[i]]}
                end
            end
            tables << {table, [row,col]}
            break if !(subtree = tree[{row,col}]?)
            tree = subtree
            index = {index[0]-offsets_h[row], index[1]-offsets_w[col]}
            level += 1
        end
        {table, [row,col], tables, bounding}
    end
    protected def get_index(clusters : Hash(Int32, {T, Int32?}), level : Int32) : Index
        # doing top-down traversal like #map_index
        # using Simple#get_index for getting local indices
        # be aware: aggregate offset is missing!
        update
        index = [0, 0]
        tree = @tree.not_nil!
        table = nil
        while !tree.nil?
            level -= 1
            table = tree.value.not_nil!
            if table.is_a?(Simple)
                is_leaf = (level<=0)
                local_index = table.get_index(clusters, is_leaf)
                local_index = {Int32,Int32}.from(local_index)
                offsets_h, offsets_w = @offsets[table]
                index[0] += offsets_h[local_index[0]]
                index[1] += offsets_w[local_index[1]]
                tree = tree[local_index]?
            else
                break
            end
        end
        index
    end
    private def get_aggregate_offset(index : Index) : Index
        res = [0,0]
        _, _, tables = map_index(index)
        if tables.size > 0
            table = tables.last
            if table[0].is_a?(Aggregate(T))
                res = table[1]
            end
        end
        res
    end
    private def get_parent_clusters(row_index : Int32) : Hash(Int32, {T, Int32?})
        # `row_index` is in the RAW VT's frame (it came from multiassign_end or
        # hyperplane_add). If @parent is a filter wrapper (size < raw size),
        # some rows — including new additions or rows moved out of the filter —
        # are legitimately not in @parent's frame. Reading from
        # @parent.raw_parent bypasses the filter so cluster values are readable
        # regardless. Default implementation of `raw_parent` returns self, so
        # this is a no-op for unfiltered pivots.
        raw = @parent.raw_parent
        res = Hash(Int32, {T, Int32?}).new
        [@row_headers, @col_headers].each do |container|
            container.flatten.each do |tup| # {column: Int32, sort_asc?: Bool}
                col_index = tup[:column]
                index = [row_index, col_index]
                res[col_index] = {raw[index]?, raw.hyperplane_get_rank(1, index)}
            end
        end
        res
    end
    private def cluster_according_to(table : Table::Lazy::Raw::Base(T), clusters : Hash(Int32, {T, Int32?}))
        multiassign_begin
        # atomically change all fields in `table` (vs. #[]= is not atomic, since it always makes update at beginning)
        table.size[0].times do |row_index|
            parent_table, parent_index = get_parent_index(table, [row_index,0])
            parent_row_index = parent_index[0]
            clusters.each do |flat_col, value_rank|
                # if parent_table[[parent_row_index, flat_col]] != NilRecord # TODO(pivot): remove this and handle in VirtualTable
                    parent_table[[parent_row_index, flat_col]] = value_rank[0]
                # end
            end
        end
        multiassign_end
    end
    private def get_parent_index(table : Table::Lazy::Raw::Base(T), index : Index) : {Table::Lazy::Base(T), Index}
        parent_table = parent_index = nil
        table.hyperplanes(0, index).each do |tup|
            parent_table, _, parent_index = tup
            break if parent_table == @parent
        end
        assert(!parent_table.nil?)
        assert(!parent_index.nil?)
        {parent_table, parent_index}
    end
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        update # sort of flushing the cache
        @parent.multiassign_begin
    end
    protected def multiassign_end : Index?
        @parent.multiassign_end
    end
    protected def is_multiassign? : Bool # if locked, #update should not be called (for all non-root tables)
        @parent.is_multiassign?
    end
end
