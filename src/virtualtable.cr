# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "./referencecell" # this file is strongly bound to referencecell.cr
require "./weakkeymap"
require "./tree"
require "./persistency"
require "./table/base"
require "./table/raw"
require "./exception"
require "./bidirhash"
require "./constants"
require "./graph"
require "./graphalgos"
require "./idcontainer"

# rules for Configurator
# - tree
#     - level 0 node is a TableLID, alternating per level FieldLID or TableLID as node
#     - FieldLID|PseudoFields as edge
# - a table is always expandable
# - a field is expandable only if its table is expanded _and_ if the field has at least one downward link
# - in an expanded table its upward linked field will stay the first mentioned field
# - fields should always look like
#     - ?? person # if its table is not expanded yet _or_ if the field has no downward link
#     - ?? person (2,0) +/- # if its table is expanded _and_ field has at least one downward link
#     - <- # if it has an upward outgoing link
#     - -> # if it has an upward incoming link
#     -    # if no upward link
# - tables should always look like
#     -   mytable +/- # and be on same indentation as its following field(s)
#     - tables should be boxed (implies potentially large empty areas) with table name boxed by itself
# - a table or its fields can only be selected if table is expanded
# - a collapsed table loses all its selections statuses

# design decisions for algorithms & data structures
# - when fields are created or removed: (a) #is_selected? and #is_expanded? should be preserved, (b) field order should be reflected in tree
#   -> we need an update procedure, which preserves the field DB order
#   -> this update procedure needs a cache for prior tree nodes (incl. all attributes); the key to the cache is the edge FieldLID to the parent
#   -> update should only run when DB changes its meta data (otherwise huge performance penalty; some unit test already took several seconds)
# - the states of #is_* could be part of the tree nodes, since the key for the cache is the FieldLID (not the tree node)
#   - however, records (or mutable_records) led to some issues -> still going for external storage with WeakKeyMap
# - multiple assignments needed; needs to work on topologically sorted tables
#   - consider use case "person","city"->"state","country"; where both "city" and "country" are used as clusters; "city" needs to always be assigned first
#   - also consider that assignment needs to be deterministic in the sense that independent of exploration order in Configurator the outcome of a move should always be the same
# - ReferenceCell is used in VirtualTable, and also supported by #constrain_reference for constraining, but remember:
#   - VT itself does not store the constraints (i.e. #[]? will always return unconstrained references), they are only stored outside (e.g. in Hierarchic or in other ReferenceCells)

# (further) observations for VirtualTable
# - VT has no global rank (only subtables have local ranks)
# - Configurator defines tables (nodes) and references (directed edges)
#   - this defines a directed (non-rooted) tree
#   - this could be topologically sorted, starting with nodes having only out-edges
# - (even) root node rows can show up multiple times in VT

module Table::VirtualTable # part of Table so that e.g. pivot tables can call our protected #version

include Persistency # e.g. for FieldLID
# include Table # e.g. for Table::Index

# from Cantarell-Regular.otf, all have to have equal width
module FieldAffixes
    Empty = " "
    Left = "◄" # e.g. via `font-manager Cousine-Regular.ttf`
    Right = "►" # neither latin nor greek; needs a special glyph range in the font
    Collapsed = "+"
    Expanded = "-"
end

enum PseudoFields
    RecordLID   # only used by VirtualTable (not by Configurator)
    ShowAll     # used by both
    Rank        # used by both
end
PseudoFieldNames = {PseudoFields::Rank => Constant::Rank, PseudoFields::ShowAll => Constant::ShowAll}

alias Tree = RootedTree(FieldLID|PseudoFields, FieldLID|PseudoFields)
# class Tree < RootedTree(FieldLID|PseudoFields, FieldLID|PseudoFields) # FieldLID|PseudoFields as edge, alternating per level FieldLID or TableLID as node
# end

class Configurator(T,U) # TODO(vtable): collapse this Configurator namespace into VirtualTable
    def is_expanded?(node : Tree) : Bool
        update
        @is_expanded[node]
    end
    def is_selected?(node : Tree) : Bool|SomeStruct
        update
        @is_selected[node]
    end

    getter display_name = WeakKeyMap(Tree, {String,String,String}).new # {prefix, main, postfix}
    getter tree : Tree # beware: gets updated by Tree hook mechanism
    @meta_version = 0
    @version = 0
    getter level = WeakKeyMap(Tree, Int32).new
    getter is_incoming = WeakKeyMap(Tree, Bool).new # TODO(vtable): exposed (was protected); only set for table nodes, i.e. every even level
    protected getter user_ids = Set(Int32).new # owned by Configurator, but populated by VT (since VT knows the column order)
    protected getter user_id_mgr = IDContainer(Array(TableLID|FieldLID|PseudoFields)).new # dito
    getter persistency : Persistency::Default
    @is_expanded = WeakKeyMap(Tree, Bool).new
    @is_selected = WeakKeyMap(Tree, Bool|SomeStruct).new
    @is_used = WeakKeyMap(Tree, Bool).new
    @dirty = true
    # If set, update() pushes this context onto the persistency stack before
    # reading. Keeps the Configurator's view pinned to a specific context
    # (e.g. a Shape's context) regardless of what's on top globally — needed
    # after do_commit when Shape's context advances but the app's default
    # context stays behind.
    @context : Persistency::Context? = nil
    def context=(ctx : Persistency::Context) : Persistency::Context
        @context = ctx
        @dirty = true
        ctx
    end
    def initialize(@persistency : Persistency::Default, table : TableLID, @context : Persistency::Context? = nil)
        @block_update = true
        @tree = Tree.new(table) {update}
        @display_name[@tree] = {"", @persistency.get_value(MetaFieldLIDs::Names, table).as(String), ""}
        @level[@tree] = 0
        @is_expanded[@tree] = true
        @is_selected[@tree] = false
        @block_update = false
        update(@tree)
    end
    protected def initialize(other : Configurator(T,U), persistency : Persistency::Default)
        @block_update = true
        @tree = Tree.new(0i64) # dummy
        @meta_version = 0
        @persistency = persistency
        old2new = Hash(Tree,Tree).new
        other.tree.dfs_down do |e,nold,_|
            # first, clone tree
            nnew = Tree.new(nold.value) {update}
            old2new[nold] = nnew
            if pold = nold.parent
                old2new[pold].add_subtree(e.not_nil!, nnew)
            else
                @tree = nnew
            end
            # second, clone data
            @is_expanded[nnew] = other.is_expanded?(nold)
            @is_selected[nnew] = other.is_selected?(nold)
            @level[nnew] = other.@level[nold]
            @is_incoming[nnew] = other.@is_incoming[nold] if !other.@is_incoming[nold]?.nil?
            @display_name[nnew] = other.@display_name[nold]
            @is_used[nnew] = other.@is_used[nold]
        end
        @meta_version = other.@meta_version
        @version = other.@version
        @user_ids = other.@user_ids.clone
        @user_id_mgr = other.@user_id_mgr.clone
        @block_update = false
    end
    def clone(clone_persistency : Bool) : Configurator(T,U)
        persistency = (clone_persistency ? @persistency.clone : @persistency)
        Configurator(T,U).new(self, persistency)
    end
    def toggle_expand(node : Tree)
        update
        if is_expandable?(node) && (node != @tree) # root always expanded by initialize
            @is_expanded[node] ^= true
            @version += 1
            update(node) # needs to be done afterwards, since otherwise new tree cannot be referenced from outside (since we don't change metadata, general `update` does not help)
        end
        @dirty = true
    end
    def toggle_select(node : Tree)
        update
        if is_selectable?(node)
            @is_selected[node] = case @is_selected[node]
            when true
                false
            when false
                true
            when Some
                true
            else
                assert(false)
            end
            dependable_select(node)
            @version += 1
        end
        @dirty = true
    end
    private def dependable_select(node : Tree)
        is_table = (@level[node] % 2 == 0)
        if is_table # copy selection state from table to (most) children fields
            node.each do |_,n|
                @is_selected[n] = @is_selected[node] if n.value != PseudoFields::ShowAll
            end
        else # field node
            # copy selection state from (most) sibling fields to parent table
            none_selected = all_selected = true
            node.parent.not_nil!.each do |_,n|
                if n.value != PseudoFields::ShowAll
                    if @is_selected[n]
                        none_selected = false
                    else
                        all_selected = false
                    end
                end
            end
            @is_selected[node.parent.not_nil!] = (none_selected ? false : (all_selected ? true : Some))
        end
    end
    def is_used?(node : Tree) : Bool
        update
        @is_used[node]
    end
    def is_expandable?(node : Tree) : Bool
        update
        is_table = (@level[node] % 2 == 0)
        # a table is always expandable
        # a field is expandable iff its table is expanded _and_ has at least one downward link
        is_table || (@is_expanded[node.parent.not_nil!] && @display_name[node][2]!="") # TODO(vtable): infers "has a reference" from the display postfix; query the reference directly
    end
    def is_selectable?(node : Tree) : Bool
        update
        if @level[node] % 2 == 0 # table
            @is_expanded[node]
        else # field
            @is_expanded[node.parent.not_nil!]
        end
    end
    def get_reference(node : Tree) : Tree?
        update
        level = @level[node]
        if (level % 2 == 1) && (level > 1)
            # field node (vs. table node) of second or later table
            if node.edge_to_parent == node.parent.not_nil!.edge_to_parent
                node.parent.not_nil!.parent.not_nil!
            else
                nil
            end
        else
            nil
        end
    end
    def get_fqn(node : Tree) : String
        # return fully qualified name
        # format: field1->table2:field2<-table3:field3 (initial table name is omitted)
        assert(@level[node] % 2 == 1) # we assume we only get called on fields
        is_field = true
        res = [] of String
        while !node.nil?
            if node != @tree
                name = @display_name[node][1]
                if !is_field
                    is_incoming = @is_incoming[node]
                    name = " #{is_incoming ? FieldAffixes::Right : FieldAffixes::Left} #{name}:"
                end
                res << name
            end
            is_field ^= true
            node = node.parent
        end
        res.reverse.join
    end
    def run
        update
        VirtualTable(T,U).new(@persistency, self)
    end
    def version : Int32
        update
        @version
    end
    protected def update
        if !@block_update
            if ctx = @context
                @persistency.contexts.push(ctx)
            end
            begin
                meta_version = @persistency.version + @persistency.context.version
                if (@meta_version != meta_version) || @dirty
                    @meta_version = meta_version # TODO(vtable): this reset may belong at the end of #update, not here — unverified
                    @dirty = false # TODO(vtable): this reset may belong at the end of #update, not here — unverified
                    update(@tree)
                    update_caches
                end
            ensure
                @persistency.contexts.pop if @context
            end
        end
    end
    protected def force_update : Nil
        @version += 1
    end
    protected def to_a # only for testing
        update
        arr = Array({Int32,String}).new
        @tree.dfs_down do |_,node,level|
            text = (level%2==0 ? "  " : "") + @display_name[node].join
            arr << {level,text}
        end
        arr
    end
    protected def multiassign_begin
        @block_update = true
    end
    protected def multiassign_end
        @block_update = false
    end
    private def update(node : Tree, path = Array(FieldLID|TableLID|PseudoFields).new)
        # triggers the recursive recalculation of all subtrees...
        # ... while preserving the selection status (if possible) and using the current field ordering
        stash = Hash({Tree,FieldLID|PseudoFields}, Tree).new # {parent,field} => child
        node.each do |e,_|
            stash[{node,e}] = node.remove_subtree(e)
        end
        # now update next level
        is_table = (@level[node] % 2 == 0)
        if is_table
            update_table(node, stash)
        else
            update_field(node, path, stash)
        end
        # now recurse to next level
        node.each do |field, child|
            update(child, path + [field])
        end
    end
    private def update_table(node : Tree, stash)
        name = @persistency.get_value(MetaFieldLIDs::Names, node.value.as(TableLID)).as(String)
        postfix = ""
        if @is_expanded[node]
            update_node(node, PseudoFields::ShowAll, PseudoFields::ShowAll, stash)
            update_node(node, PseudoFields::Rank, PseudoFields::Rank, stash)
            @persistency.get_field_lids(node.value.as(FieldLID)).each do |field|
                update_node(node, field, field, stash)
            end
            postfix = " "+FieldAffixes::Expanded
        elsif @level[node] > 0
            @is_selected[node] = false
            field = node.edge_to_parent.as(FieldLID)
            child = update_node(node, field, field, stash)
            # need to override:
            @is_expanded[child] = false
            @is_selected[child] = false
            postfix = " "+FieldAffixes::Collapsed
        end
        @display_name[node] = {"", name, postfix}
    end
    private def update_field(node : Tree, path : Array(FieldLID|TableLID|PseudoFields), stash)
        field = node.value
        if field.is_a?(PseudoFields)
            @display_name[node] = {FieldAffixes::Empty+" ", PseudoFieldNames[field], ""}
        else # FieldLID
            if node.edge_to_parent == node.parent.not_nil!.edge_to_parent
                if @is_incoming[node.parent.not_nil!]
                    prefix = FieldAffixes::Right+" "
                else
                    prefix = FieldAffixes::Left+" "
                end
            else
                prefix = FieldAffixes::Empty+" "
            end
            field_name = @persistency.get_value(MetaFieldLIDs::Names, field).as(String)
            postfix = ""
            if @is_expanded[node.parent.not_nil!] # we only show the numbers if the parent table is expanded
                num_outs = @persistency.get_outward_reference(field) ? 1 : 0
                num_ins = @persistency.get_inward_references(field).size
                if num_ins+num_outs > 0
                    postfix = " #{FieldAffixes::Left}#{num_ins},#{FieldAffixes::Right}#{num_outs}"
                    postfix += (@is_expanded[node] ? " "+FieldAffixes::Expanded : " "+FieldAffixes::Collapsed)
                end
            else
                @is_expanded[node] = false # field might have been erroneously set as expanded
            end
            @display_name[node] = {prefix, field_name, postfix}
        end
        if @is_expanded[node]
            out_ref = @persistency.get_outward_reference(node.value.as(FieldLID))
            update_field_node(node, true, out_ref ? [out_ref] : [] of FieldLID, stash)
            update_field_node(node, false, @persistency.get_inward_references(node.value.as(FieldLID)), stash)
        end
        dependable_select(node) # we need this in case of newly created fields in order to propagate the (maybe) changed selection status to the table
    end
    private def update_field_node(node : Tree, is_downward : Bool, fields : Array(FieldLID), stash)
        prefix = (is_downward ? FieldAffixes::Right+" " : FieldAffixes::Left+" ")
        fields.each do |field|
            table = @persistency.get_table_lid(field)
            if !table.nil?
                child = update_node(node, field, table, stash)
                @is_incoming[child] = is_downward
            end
        end
    end
    private def update_node(parent : Tree, edge : FieldLID|PseudoFields, child_value : FieldLID|PseudoFields, stash) : Tree
        # preserving @is_selected and @is_expanded
        if !(child = stash[{parent,edge}]?)
            child = Tree.new(child_value) {update}
            @is_selected[child] = false
            @is_expanded[child] = false
        end
        @level[child] = @level[parent] + 1
        parent.add_subtree(edge, child)
    end
    private def update_caches
        # "cutting off" unused subtrees
        @tree.dfs_up do |_,n,_|
            is_used = (@is_selected[n] != false)
            n.each do |_,n2|
                is_used ||= @is_used[n2] # collecting from children
            end
            @is_used[n] = is_used
        end
    end
end

struct ReferenceModifier(T,U)
    include Interface::ReferenceModifier(U)
    def initialize(@vt : VirtualTable(T,U), @field_lid : FieldLID)
    end
    def modify(rank : Int32, value : U)
        @vt.modify_reference(@field_lid, rank, value)
    end
end

struct ReferenceConstrainer(T,U)
    include Interface::ReferenceConstrainer(U)
    def initialize(@vt : VirtualTable(T,U), @int_col : Int32)
    end
    def constrain(constraints : Hash(Int32,Int32)) : {Array(Int32), Int32} # array of {column,rank} pairs -> {ordered rank indices, first breaking index}
        @vt.constrain_reference(@int_col, constraints)
    end
end

# always 2D table, rows are records, cols are fields
# we assume that ReferenceCell(T) is (indirectly) part of T
# U separately specifies the ReferenceCell(T)
class VirtualTable(T, U) < Table::Lazy::Raw::Base(T)
    @version : Int32? = nil
    private struct MyTree(T,U) # used for grouping; bookkeeping for Configurator related data
        property configurator : Configurator(T,U)
        property tables = BidirHash(Int32, Tree).new # for mapping; necessary e.g. for #join
        property indices = BidirHash({Tree,FieldLID|PseudoFields}, Int32).new # => flat column
        property user_columns = Array(Int32).new # UserColumn => FlatInternalColumn
        def initialize(@configurator : Configurator(T,U))
        end
    end
    private struct MyGraph # used for grouping; bookkeeping for table related data (coarser than Tree above)
        property graph = DiGraph::Graph.new # only for used parts of the tree; needed to do topologic sorting for multiassignment
        property table_lids = WeakKeyMap(DiGraph::Node, TableLID?).new # incl. Nil (orphaned field might not have a referencing table anymore)
        property field_lids = WeakKeyMap(DiGraph::Edge, {FieldLID, FieldLID}).new # source and target FieldLID
        property reference_rank_maps = WeakKeyMap(DiGraph::Edge, Hash(Int32, Int32)).new # for constraining; source rank => target rank
    end
    private struct Multiassign(T) # used for grouping
        property count = 0
        property buffer = Hash(Int32, Array({Index,T})).new # row => [assignment1, assignment2, ...]
    end
    def initialize(@persistency : Persistency::Default, configurator : Configurator(T,U))
        @tree = MyTree(T,U).new(configurator)
        @graph = MyGraph.new
        @tree2graph = BidirHash(Tree, DiGraph::Node).new
        @multiassign = Multiassign(T).new
        @query = {table_lids: Array(TableLID).new, field_lids: Array(Array(FieldLID)).new, table_joins: Array({Int32,Int32}).new, where_not_nil_columns: Array(Int32).new}
        @table_raw = Array(Array(T)).new # the result of the DB query, including hidden fields
        @referencing = Hash(FieldLID, FieldLID).new # referencing=>referenced FieldLID
        @references = Hash(FieldLID, {BidirHash(RecordLID, Int32), Array(U)}?).new # (referenced) FieldLID => {record2rank, rank2value}
        @field2recordlidvalues = Hash(FieldLID,Array({RecordLID,T})).new # cache for non-reference clusters
        update
    end
    def size : Index
        update
        [@table_raw.size, @tree.user_columns.size]
    end
    def []?(index : Index) : T|Nil
        update
        row, col = index[0], @tree.user_columns[index[1]]
        row_arr = @table_raw[row]?
        if row_arr
            cell = row_arr[col]
            if cell.is_a?(ReferenceCell(U))
                cell.dup
            else
                cell
            end
        else
            nil
        end
    end
    def []=(index : Index, value : T) : Index
        if is_multiassign?
            # in parallel assign mode we just first just store all the assignments
            @multiassign.buffer[index[0]] ||= Array({Index,T}).new
            @multiassign.buffer[index[0]] << {index, value}
            index
        else
            update
            old_row = @table_raw[index[0]].dup
            raw_assignment(index, value) # no update inside, but patching
            fingerprint = fingerprint_patch_and_get(old_row, @table_raw[index[0]]) # continue patching, return fresh fingerprint
            update
            [fingerprint_match(fingerprint).not_nil!, index[1]] # find fingerprint
        end
    end
    def hyperplane_is_rank(norm_dimension : Int32, index : Index) : Bool # must be overridden by root tables
        update
        col = @tree.user_columns[index[1]]
        table, _ = @tree.indices.bwd(col)
        rank_column = @tree.indices[{table,PseudoFields::Rank}]
        (norm_dimension == 1) && (col == rank_column)
    end
    def hyperplane_get_rank(norm_dimension : Int32, index : Index) : Int32? # must be overridden by root tables
        if norm_dimension == 1 # columns are the norm vector
            update
            row, col = index[0], @tree.user_columns[index[1]]
            table, _ = @tree.indices.bwd(col)
            rank_column = @tree.indices[{table,PseudoFields::Rank}]
            row_arr = @table_raw[row]?
            if row_arr
                value = row_arr[rank_column]
                case value
                when Int64
                    value.to_i32
                when nil, NilRecordStruct # only user columns are NilRecord, RecordLID (and Rank, if hidden) columns stay nil
                    nil
                else
                    assert(false)
                end
            else
                nil
            end
        else
            nil
        end
    end
    def hyperplane_add(dimension : Int32, index=Index.new(size.size, -1), **args) : Index # append hyperplane globally (with nil values); need not necessarily show up in "self" table; must be overridden by root tables
        # `index` only selects _table_
        # will always be appended, independent of "index" (hence no move done here)
        update
        col = index[1]
        res = [-1,-1]
        case dimension
        when 0 # row, hence record; might set PseudoFields::ShowAll
            col = 0 if (col < 0) || (col >= @tree.user_columns.size) # default is first user column
            internal_col = @tree.user_columns[col]
            node = @tree.indices.bwd(internal_col)[0]
            table_lid = node.value.as(TableLID)
            is_showall = was_showall = @tree.configurator.is_selected?(node[PseudoFields::ShowAll])
            begin
                @persistency.transaction do
                    if (candidates = args[:candidates]?) && (clusters = args[:clusters]?)
                        # special case, we try to make a record on a lower level, _indirectly_ creating a higher level entry in VT
                        ri = make_sibling(index, clusters, candidates) # this is more complex...
                        is_showall = @tree.configurator.is_selected?(node[PseudoFields::ShowAll])
                    else # "normal" #hyperplane_add
                        record_lid_new = @persistency.add_record(table_lid)
                        # finally, switch on ShowAll, if needed
                        if (@tree.tables.size > 1) && !is_showall
                            # needed to enforce actually showing the new record
                            @tree.configurator.toggle_select(node[PseudoFields::ShowAll])
                            is_showall = true
                        end
                        # now construct a new index (to return)
                        update
                        record_lid_column = @tree.indices[{node, PseudoFields::RecordLID}]
                        new_rows = @table_raw.map_with_index {|row,ri| {row[record_lid_column], ri}}.select {|record_lid,ri| record_lid==record_lid_new}
                        assert(new_rows.size >= 1) # TODO(vtable): verify whether new_rows.size is always exactly 1
                        ri = new_rows[0][1]
                    end
                    if clusters = args[:clusters]? # column => value
                        if !clusters.empty?
                            multiassign_begin
                            clusters.each do |col,value|
                                self[[ri,col]] = value
                            end
                            index2 = multiassign_end.not_nil!
                            ri = index2[0]
                        end
                    end
                    res = [ri,col] # default result (the new index)
                    if is_showall && !was_showall # in this case we try to reduce again
                        fingerprint = fingerprint_patch_and_get(@table_raw[ri])
                        @tree.configurator.toggle_select(node[PseudoFields::ShowAll]) # disable ShowAll
                        update # need to call manually since we're operating lowlevel
                        if ri = fingerprint_match(fingerprint)
                            res = [ri, col] # the better match
                        else
                            @tree.configurator.toggle_select(node[PseudoFields::ShowAll]) # not found, need to re-enable
                            update
                            # we stick with the default index
                        end
                    end
                end
            rescue ex
                if is_showall && !was_showall # in case of exception we revert again (both in case for #make_sibling and the non-referencecell)
                    @tree.configurator.toggle_select(node[PseudoFields::ShowAll])
                end
                @tree.configurator.force_update # TODO(vtable): forced here because some boundary conditions otherwise let this exception resurface later as an IndexError in referencecell.cr during Shape/Cell painting
                # TODO(vtable): some ConditionsNotMet paths appear to leave the VirtualTable partly patched, which is why #force_update is needed
                raise(ex)
            end
        when 1 # col, hence field
            if (col < 0) || (col >= @tree.user_columns.size)
                node = @tree.configurator.tree # we default to the first table here
                internal_col = nil
            else
                internal_col = @tree.user_columns[col]
                node = @tree.indices.bwd(internal_col)[0]
            end
            table_lid = node.value.as(TableLID)
                name = args[:name]? || Constant::Unnamed
            refers_to_field_lid = args[:refers_to_field_lid]? || nil
            # finally, mark in Configurator
            field_lid = @persistency.add_field(table_lid, name, refers_to_field_lid)
            # @tree.configurator.update # done implicitly by tree hook in Configurator
            field_node = node[field_lid] # relies on updated (internal, vs. root) `node` after the persistency call!
            assert(!@tree.configurator.is_selected?(field_node))
            @tree.configurator.toggle_select(field_node)
            # now construct a new index (to return)
            update
            ci = @tree.indices[{node,field_lid}] # internal column
            user_ci = @tree.user_columns.map_with_index {|el,i| {el,i}}.select {|el,i| el==ci}
            assert(user_ci.size == 1)
            res = [index[0],user_ci[0][1]] # we return the user column index
        else
            assert(false)
        end
        res
    end
    def hyperplane_remove(dimension : Int32, index : Index, **args)
        # `index` only selects table and either record or field
        update
        internal_col = @tree.user_columns[index[1]]
        case dimension
        when 0 # row, hence record
            row = index[0]
            node = @tree.indices.bwd(internal_col)[0]
            table_lid = node.value.as(TableLID)
            record_lid_col = @tree.indices[{node, PseudoFields::RecordLID}]
            record_lid = @table_raw[row][record_lid_col].as(RecordLID)
            if args[:transform_to_names]? # special side effect requested?
                node.each do |field_lid,child|
                    if field_lid.is_a?(FieldLID) && @tree.configurator.is_selected?(child)
                        col = @tree.indices[{node, field_lid}]
                        name = @table_raw[row][col]
                        if !name.is_a?(ReferenceCell(U))
                            @persistency.set_value(MetaFieldLIDs::Names, field_lid, name.to_s)
                        end
                    end
                end
            end
            @persistency.remove_record(table_lid, record_lid)
        when 1 # col, hence field
            node, field_lid = @tree.indices.bwd(internal_col)
            table_lid = node.value.as(TableLID)
            if field_lid.is_a?(FieldLID)
                @persistency.remove_field(table_lid, field_lid)
            else
                raise ConditionsNotMet.new("Cannot remove pseudo fields")
            end
        else
            assert(false)
        end
    end
    def hyperplane_move(dimension : Int32, index_from : Index, index_to : Index) : Index
        assert(false)
    end
    def hyperplane_get_name(dimension : Int32, index : Index) : T
        assert(dimension == 1)
        col = @tree.user_columns[index[1]]
        tree, field_lid = @tree.indices.bwd(col)
        @tree.configurator.get_fqn(tree[field_lid])
    end
    def hyperplane_get_default(dimension : Int32, index : Index) : T|Nil
        assert(dimension == 1) # only columns have types
        col = @tree.user_columns[index[1]]
        _, field_lid = @tree.indices.bwd(col)
        if @referencing[field_lid]? # are we a reference?
            create_reference(col, nil)
        else
            nil
        end
    end
    def hyperplane_get_ids(norm_dimension : Int32)
        assert(norm_dimension == 0)
        user_ids = @tree.configurator.user_ids
        assert(@tree.user_columns.size == user_ids.size)
        user_ids
    end
    protected def map_cell(index : Index) : {Table::Lazy::Raw::Base(T),Index}
        assert(false)
    end
    protected def map_hyperplane(dimension : Int32, index : Index) : {Table::Lazy::Raw::Base(T),Int32,Index}|Nil
        nil # root table has to return nil
    end
    def version : Int32
        update
        @version.not_nil!
    end
    # called from next layer table
    # be aware: multiassignment only resolves column conflicts in single rows, not conflicts between rows!
    # i.e. multiple rank assignments to different rows are not recommended
    protected def multiassign_begin # typically passed on to parent; root keeps track of multiassign_begin
        if !is_multiassign? # sort of flushing the cache
            update
            @tree.configurator.multiassign_begin
        end
        @multiassign.count += 1
    end
    # called from next layer table
    protected def multiassign_end : Index?
        @multiassign.count -= 1
        res = nil
        if !is_multiassign?
            @tree.configurator.multiassign_end
            all_assignments = Array({Index,T}).new
            # reordering, checking and flushing @multiassign.buffer
            begin
                @multiassign.buffer.each_value do |assignments| # row by row
                    # bring assignments in proper (topological) order
                    sorted_nodes = DiGraph::Algorithms::TopSort.new(@graph.graph).do.map {|el| {@tree2graph.bwd?(el[:node]), [] of {Index, T}}}.to_h
                    assignments.each do |index,value| # all assignments in current row
                        row, col = index[0], @tree.user_columns[index[1]]
                        table, _ = @tree.indices.bwd(col)
                        sorted_nodes[table] << {index, value}
                    end
                    # check assignments in topological order
                    # TODO(vtable): extra checking needed here because Persistency isn't ACID yet
                    # BTW: this is all necessary, despite #fingerprint_* below! example: #hyperplane_move changes NilRecord to a defined record, along with dependent assigment
                    row_old = @table_raw[assignments[0][0][0]].dup # first assignment, first tuple element (Index), first element (row)
                    patch_checker = Hash(Int32,T).new
                    sorted_nodes.each_value do |assignments|
                        assignments.each do |index, value|
                            all_assignments << {index, value}
                            row, col = index[0], @tree.user_columns[index[1]]
                            if @table_raw[row][col].is_a?(NilRecord)
                                raise ConditionsNotMet.new("Cannot assign to a non-existant record")
                            end
                            if value.is_a?(NilRecord)
                                raise ConditionsNotMet.new("Cannot indirectly unreference a record")
                            end
                            raw_assignment(index, value, true) # dryrun (mostly to catch non-Int64 assignments to Ranks)
                            row_old2 = @table_raw[row].dup
                            @table_raw[row][col] = value
                            fingerprint_patch_and_get(row_old2, @table_raw[row], patch_checker) # we just want to patch here (and check for incompatibilities)
                        end
                    end
                    @table_raw[assignments[0][0][0]] = row_old # needed to restore; we're doing the real thing after passing all checks
                end
            rescue ex
                raise ex # forward exception, flush buffer, but do not execute any assignment
            else
                # now we can execute all assignments, no more exceptions will happen
                all_assignments.each_with_index do |index_value, i|
                    index, value = index_value
                    row_old = @table_raw[index[0]].dup
                    raw_assignment(index, value)
                    fingerprint = fingerprint_patch_and_get(row_old, @table_raw[index[0]])
                    if i == all_assignments.size-1
                        update
                        row_id = fingerprint_match(fingerprint)
                        if row_id.nil?
                            # can e.g. get nil if user sets a reference to "(no reference)" and table is not "(Show all)"
                            col = index[1]
                            internal_col = @tree.user_columns[col]
                            node = @tree.indices.bwd(internal_col)[0]
                            if !@tree.configurator.is_selected?(node[PseudoFields::ShowAll])
                                @tree.configurator.toggle_select(node[PseudoFields::ShowAll])
                                update
                            end
                            row_id = fingerprint_match(fingerprint).not_nil! # with "(Show all)" it has to show up now
                        end
                        res = [row_id, index[1]]
                    end
                end
            ensure
                @multiassign.buffer.clear # finally flush
            end
            res
        end
    end
    # called from next layer table
    protected def is_multiassign? : Bool # if locked, #update should not be called (for all non-root tables)
        @multiassign.count > 0
    end
    # called from ReferenceModifier
    protected def modify_reference(field_lid : FieldLID, rank : Int32, value : U)
        record_lid = @references[field_lid].not_nil![0].bwd(rank)
        @persistency.set_value(field_lid, record_lid, value.as(Persistency::Cell))
    end
    # called from ReferenceConstrainer
    protected def constrain_reference(int_col : Int32, constraints : Hash(Int32,Int32)) : {Array(Int32), Int32}
        # `int_col` is the (already) internal column index of the reference to be constrained
        # `constraints` maps user column indices to ranks
        # if column is a RC, we constrain the referenced table; otherwise the original one (there is no referenced anyhow :))
        # first, convert to @graph based constraints (and already Sets)
        constraints = constrain_translate_constraints(constraints)
        # second, do constraint propagation
        constraints = constrain_all(constraints)
        # third, navigate to needed node
        node, field_lid = @tree.indices.bwd(int_col)
        referenced_field_lid = @referencing[field_lid.as(FieldLID)]
        node = @tree2graph[node].out_edges.select {|e| @graph.field_lids[e] == {field_lid.as(FieldLID), referenced_field_lid}} [0].target # need to operate on @graph (more leaves)
        # finally, calculate fulfilling ranks
        ranks = constraints[node]?
        size = @references[referenced_field_lid].not_nil![1].size
        if ranks.nil? # now we resolve shorthand `nil` for all ranks (but at the end excl. 0 for "(no reference)")
            ranks = (1...size).to_a + [0]
            {ranks, size-1}
        else
            breaking_ranks = (0...size).to_set - ranks
            {ranks.to_a + breaking_ranks.to_a, ranks.size}
        end
    end
    private def constrain_translate_constraints(constraints : Hash(Int32,Int32)) : Hash(DiGraph::Node,Array(Set(Int32)))
        constraints.to_a.map do |col,rank|
            node, field_lid = @tree.indices.bwd(@tree.user_columns[col]) # rooted tree node, referencing field_lid
            node = @tree2graph[node] # convert tree node into graph node
            if referenced_field_lid = @referencing[field_lid]?
                edge = node.out_edges.select {|e| @graph.field_lids[e] == {field_lid.as(FieldLID), referenced_field_lid}} [0]
                {edge.target, [Set{rank}]} # now referenced graph node
            elsif field_lid == PseudoFields::Rank
                {node, [Set{rank}]}
            else
                field_lid = field_lid.as(FieldLID)
                recordlidvalues = (@field2recordlidvalues[field_lid] ||= @persistency.get_field(field_lid, false).map{|k,v| {k,v.as(T)}})
                value = recordlidvalues[rank-1][1] # rank starts with 1 (0==noref, in case of RC)
                set = recordlidvalues.map_with_index {|kv,i| {kv[1]==value,i} }.select {|match,i| match}.map {|el| el[1]+1}.to_set
                {node, [set]}
            end
        end.to_h
    end
    private def constrain_all(constraints : Hash(DiGraph::Node,Array(Set(Int32)))) : Hash(DiGraph::Node,Set(Int32))
        res = constraints.map {|node,sets| {node, constrain_fusion(sets)}}.to_h
        # propagates constraints to all edge.source nodes (i.e. not to outside leaves)
        DiGraph::Algorithms::DFS.new(@graph.graph, false, true, false).do.each do |el|
            # we traverse all _outgoing_ edges and get called _after_ node was fully visited (like in top. sort.)
            if edge = el[:edge] # all but root/source ("left hand side") nodes
                if target_ranks = res[edge.target]?
                    # there is a (real) constraint on the target node, i.e. could impact source node
                    # first, we need to do a _backward_ mapping
                    if rank_mapping = @graph.reference_rank_maps[edge]? # (forward) rank mapping (if not orphaned)
                        bwd_rank_mapping = Hash(Int32, Set(Int32)).new
                        rank_mapping.each do |k,v|
                            bwd_rank_mapping[v] ||= Set(Int32).new
                            bwd_rank_mapping[v].add(k)
                        end
                        # names = {edge.source,edge.target}.map {|node| @persistency.get_value(MetaFieldLIDs::Names, @graph.table_lids[node].not_nil!).as(String)}
                        empty = Set(Int32).new
                        source_ranks = Array(Set(Int32)).new
                        source_ranks << res[edge.source] if res.has_key?(edge.source)
                        source_ranks << (target_ranks.map {|rank| bwd_rank_mapping[rank]? || empty}.reduce? {|s1, s2| s1+s2} || empty) # #reduce yields nil in case of empty input container
                        # second, we fusion with current source ranks
                        res[edge.source] = constrain_fusion(source_ranks)
                    end
                end
            end
        end
        res
    end
    private def constrain_fusion(ranks : Array(Set(Int32))) : Set(Int32)
        ranks.reduce do |s1, s2|
            s1 & s2
        end
    end
    # main update handler
    private def update
        parent_version = @persistency.version + @persistency.context.version + @tree.configurator.version
        if !is_multiassign? && (@version != parent_version)
            old_user_ids = @tree.configurator.user_ids.to_a

            @tree = typeof(@tree).new(@tree.configurator)
            @graph = typeof(@graph).new
            @tree2graph = typeof(@tree2graph).new
            @query = {table_lids: Array(TableLID).new, field_lids: Array(Array(FieldLID)).new, table_joins: Array({Int32,Int32}).new, where_not_nil_columns: Array(Int32).new}
            @tree.configurator.user_id_mgr.age
            @tree.configurator.user_ids.clear
            @field2recordlidvalues.clear
            # now we start to build the table
            update_push(@tree.configurator.tree) # pushing the root table and then...
            update_recurse(@tree.configurator.tree) # ... starting the recursion (pushing and joining all relevant tables)
            # drop empty subtables on request
            # (the logic is documented 4.7.2023 in booklet; see also spec/virtualtable_spec.cr)
            # (slightly extended, since tables with only ShowAll have got separate meaning and are excluded here)
            proper_table_nodes = @tree.tables.fwd.values.select do |tree|
                select_count = tree.map {|_,child| @tree.configurator.is_selected?(child) ? 1 : 0}.sum
                select_count -= 1 if @tree.configurator.is_selected?(tree[PseudoFields::ShowAll])
                select_count > 0
            end
            showall_table_nodes = proper_table_nodes.select {|tree| @tree.configurator.is_selected?(tree[PseudoFields::ShowAll])}
            if showall_table_nodes.size == 0
                record_lid_cols = proper_table_nodes.map {|tree| @tree.indices[{tree, PseudoFields::RecordLID}]}
                where_not_nil_anding = true
            else
                record_lid_cols = showall_table_nodes.map {|tree| @tree.indices[{tree, PseudoFields::RecordLID}]}
                where_not_nil_anding = false
            end
            @query[:where_not_nil_columns].replace(record_lid_cols)

            # finally, launch the complex query
            @table_raw = @persistency.complex_query(@query, where_not_nil_anding).map(&.map(&.as(T)))

            update_references
            update_rework_table

            # Stabilize user_ids/user_columns order: preserve the old insertion
            # order so that fieldlist column mapping stays stable after configurator
            # field moves. New fields are appended; removed fields are dropped.
            if !old_user_ids.empty? && @tree.user_columns.size > 0
                new_id_to_col = @tree.configurator.user_ids.to_a.zip(@tree.user_columns).to_h
                @tree.configurator.user_ids.clear
                @tree.user_columns.clear
                old_user_ids.each do |id|
                    if col = new_id_to_col.delete(id)
                        @tree.configurator.user_ids.add(id)
                        @tree.user_columns << col
                    end
                end
                new_id_to_col.each do |id, col|
                    @tree.configurator.user_ids.add(id)
                    @tree.user_columns << col
                end
            end

            @version = parent_version
        end
    end
    private def update_recurse(node table1 : Tree, path = Array(FieldLID|TableLID|PseudoFields).new)
        if @tree.configurator.is_used?(table1)
            table1.each do |field1,node_field1| # all field nodes
                node_field1.each do |field2,table2| # all table nodes, so table node.value is expanded to table n2.value
                    if @tree.configurator.is_used?(table2)
                        path = path + [field1,field2]
                        update_push(table2, path)

                        # make proper edge in table graph
                        graph_nodes = {table2, table1}.map {|el| @tree2graph[el]}
                        graph_fields = {field2.as(FieldLID), field1.as(FieldLID)}
                        if @tree.configurator.is_incoming[table2]
                            graph_nodes = graph_nodes.reverse
                            graph_fields = graph_fields.reverse
                        end
                        e = @graph.graph.add_edge(*graph_nodes)
                        @graph.field_lids[e] = graph_fields

                        update_join(table1, table2)
                        update_recurse(table2, path) # the real recursion
                    end
                end
            end
        end
    end
    private def update_push(table : Tree, path = Array(FieldLID|TableLID|PseudoFields).new)
        @query[:table_lids] << table.value.as(TableLID)
        @query[:field_lids] << Array(FieldLID).new
        n = @graph.graph.add_node
        @graph.table_lids[n] = table.value.as(TableLID)
        @tree2graph[table] = n
        @tree.tables[@tree.tables.size] = table
        # populate @tree.indices, first one is always record_lid
        @tree.indices[{table,PseudoFields::RecordLID}] = @tree.indices.size
        @tree.indices[{table,PseudoFields::Rank}] = @tree.indices.size
        if @tree.configurator.is_incoming[table]? != false # root tree doesn't have this set
            extra_field = nil # need to go in here in case of "nil" and also "is_incoming"
        else
            extra_field = table.edge_to_parent.not_nil! # we need an auto-select for proper incoming fields
        end
        table.each do |_,n|
            f = n.value
            if f != PseudoFields::ShowAll # treated elsewhere
                if @tree.configurator.is_selected?(n) || @tree.configurator.is_used?(n) || (f == extra_field)
                    case f
                    when PseudoFields::Rank
                        user_column = @tree.indices[{table,PseudoFields::Rank}]
                        # no join, since rank is already part of lhs above
                        # likewise no @tree.indices_*
                    when PseudoFields
                        assert(false) # we already caught that outside
                    else
                        @query[:field_lids][-1] << f.as(FieldLID)
                        user_column = @tree.indices.size
                        @tree.indices[{table,f}] = user_column
                    end
                    if @tree.configurator.is_selected?(n) # user requested field
                        @tree.configurator.user_ids.add(@tree.configurator.user_id_mgr.get_id(path + [f])) # we populate in Configurator in the order of VT
                        @tree.user_columns << user_column # those columns need IDs; we need to pass the "path" as an arg Array
                    end
                end
            end
        end
        # now we have the full table in this form: %w(record_lid rank value1 value2 ...)
    end
    private def update_join(table1 : Tree, table2 : Tree)
        is_downward = @tree.configurator.is_incoming[table2]
        # be aware: table2 is not yet joined, hence its indices start counting at 0
        if is_downward
            field_lid = table2.parent.not_nil!.value # of table1
            table1_joinfield = @tree.indices[{table1, field_lid}] # index of field_lid in table1
            table2_joinfield = 0 # position of record_lid in table2
        else
            field_lid = table2.edge_to_parent.not_nil! # of table2
            table1_joinfield = @tree.indices[{table1, PseudoFields::RecordLID}] # index of record_lid in table1
            table2_joinfield = @tree.indices[{table2, field_lid}] - @tree.indices[{table2, PseudoFields::RecordLID}] # index of field_lid of table2
        end
        # we always need to do a full join first (and later drop empty subtables)
        @query[:table_joins] << {table1_joinfield, table2_joinfield}
    end
    private def update_references
        # first, we need to extend @graph.graph for all "leaf" referenced nodes (but _incl. indirect_ references)
        @graph.graph.nodes.each do |node| # #each on Set runs on an iterator, _not_ incl. new elements
            # first, we collect all outgoing fields
            table_lid = @tree2graph.bwd(node).value.as(TableLID)
            edges = Set({FieldLID,FieldLID}).new
            @persistency.get_field_lids(table_lid).each do |field_lid|
                if referenced_field_lid = @persistency.get_outward_reference(field_lid)
                    edges.add({field_lid, referenced_field_lid})
                end
            end
            # now we align with @graph
            node.out_edges.each do |e|
                edges.delete(@graph.field_lids[e])
            end
            edges.each do |edge|
                node2 = @graph.graph.add_node
                @graph.table_lids[node2] = @persistency.get_table_lid(edge[1])
                edge2 = @graph.graph.add_edge(node, node2)
                @graph.field_lids[edge2] = edge
            end
        end
        # TODO(vtable): factor out / simplify the edge-set construction above and below
        edges = Set({FieldLID,FieldLID}).new
        # if we have a reference in the graph, we have at least one edge now
        @graph.graph.edges.each.each do |edge| # #each.each on Set runs on an iterator, _incl._ new elements
            node = edge.target
            if !@tree2graph.bwd?(node) # an edge not part of Configurator?
                field_lid = @graph.field_lids[edge][1]
                if referenced_field_lid = @persistency.get_outward_reference(field_lid)
                    edge = {field_lid, referenced_field_lid}
                    if edges.add?(edge)
                        node2 = @graph.graph.add_node # be aware: these new nodes are processed in the outer loop as well!
                        @graph.table_lids[node2] = @persistency.get_table_lid(edge[1])
                        edge2 = @graph.graph.add_edge(node, node2)
                        @graph.field_lids[edge2] = edge
                    end
                end
            end
        end

        # second, we can populate data associated to @graph according to its edges
        @references = Hash(FieldLID, {BidirHash(RecordLID, Int32), Array(U)}?).new
        @referencing = Hash(FieldLID, FieldLID).new
        @graph.graph.edges.each do |edge|
            field_lids = @graph.field_lids[edge] # mark as reference
            @referencing[field_lids[0]] = field_lids[1]

            # first, we calculate @referencing and @references
            if @persistency.get_table_lid(field_lids[1]).nil?
                @references[field_lids[1]] = nil # mark as invalid (reference)
            else
                res = @persistency.get_field(field_lids[1], false) # %w(record_lid value), all reference tags
                record2rank = BidirHash(RecordLID,Int32).new
                rank2value = Array(U).new
                rank2value << Constant::NoReference # rank 0
                res.each do |row|
                    record_lid, value = row[0].as(Int64), row[1].as(U)
                    record2rank[record_lid] = rank2value.size
                    rank2value << value
                end
                @references[field_lids[1]] = {record2rank, rank2value}
            end

            # second, we calculate @graph.reference_rank_maps
            table_lids = field_lids.map {|f| @persistency.get_table_lid(f)}.to_a
            if !table_lids.includes?(nil)
                table_lids = table_lids.map(&.not_nil!)
                query = {table_lids: table_lids, field_lids: [[field_lids[0]], [] of FieldLID], table_joins: [{2,0}], where_not_nil_columns: [1,4]}
                res = @persistency.complex_query(query, true) # the full result (5 columns), but...
                res = res.transpose.select_with_index {|_,ci| (ci==1)||(ci==4)}.transpose # ... we only need rank pairs from source and target table
                res = res.map(&.map {|el| el.as(Int64).to_i32})
                @graph.reference_rank_maps[edge] = res.to_h
            end
        end
    end
    private def update_rework_table
        # we do this for faster querying by #[]?; updates on all columns
        @tree.indices.size.times do |col| # TODO(vtable): revisit — this was breaking tests
            tree, field_lid = @tree.indices.bwd(col)
            record_lid_col = @tree.indices[{tree, PseudoFields::RecordLID}]
            @table_raw.each_index do |row|
                record_lid = @table_raw[row][record_lid_col]
                if record_lid.nil? || record_lid==NilRecord # is the record_lid nil?
                    @table_raw[row][col] = NilRecord
                elsif @referencing[field_lid]? # are we a reference?
                    record_lid_ref = @table_raw[row][col].as(FieldLID|Nil) # we replace the record_lid with...
                    @table_raw[row][col] = create_reference(col, record_lid_ref) # ... the proper ReferenceCell (or NilRecord)
                end
            end
        end
    end
    private def create_reference(col : Int32, record_lid_ref : FieldLID?) : ReferenceCell(U)|NilRecordStruct
        node, field = @tree.indices.bwd(col)
        referenced_field_lid = @referencing[field.as(FieldLID)]

        if @references[referenced_field_lid].nil?
            # we return NilRecord in case of a fully orphaned reference!
            NilRecord
        else
            record2rank, rank2value = @references[referenced_field_lid].not_nil!
            # showall is true if the referencing field points to a table that has ShowAll set (double meaning of ShowAll)
            showall = @tree.configurator.is_expanded?(node[field]) &&
                @tree.configurator.is_expanded?(node[field][referenced_field_lid]) &&
                (@tree.configurator.is_selected?(node[field][referenced_field_lid][PseudoFields::ShowAll]) != false)
            if record_lid_ref.nil?
                rank = nil
            else
                rank = record2rank[record_lid_ref]? # #[]? because we could have a (locally) orphaned reference
            end
            rank = 0 if rank.nil? # ReferenceCell's rank==0 stands for "(no reference)"
            modifier = ReferenceModifier(T,U).new(self, referenced_field_lid.as(FieldLID))
            constrainer = ReferenceConstrainer(T,U).new(self, col)
            ReferenceCell(U).new(rank, showall, rank2value, modifier, constrainer)
        end
    end
    private def raw_assignment(index : Index, value : T, dryrun = false) : Nil
        row, col = index[0], @tree.user_columns[index[1]]
        table, field_lid = @tree.indices.bwd(col)
        cell = @table_raw[row][col]
        assert(!cell.is_a?(NilRecord)) # we can assign to cells iff they are not NilRecords
        table_lid = table.value.as(TableLID)
        if field_lid == PseudoFields::Rank
            raise ConditionsNotMet.new("ranks can only be assigned to integer values") if !value.is_a?(Int64)
            rank = cell.as(Int64).to_i32
            if !dryrun
                new_rank = @persistency.move_record_by_rank(table_lid, rank, value.to_i32!) # the proper (limited) new rank
                @table_raw[row][col] = new_rank.to_i64 # patching
            end
        else
            if !dryrun
                @table_raw[row][col] = value # patching
                field_lid = field_lid.as(FieldLID)
                record_lid_column = @tree.indices[{table,PseudoFields::RecordLID}]
                record_lid = @table_raw[row][record_lid_column].as(RecordLID)
                if value.is_a?(ReferenceCell(U))
                    referenced_field_lid = @referencing[field_lid]
                    record2rank, _ = @references[referenced_field_lid].not_nil!
                    value = record2rank.bwd?(value.rank) # rank 0 is not in -> ? and nil
                end
                @persistency.set_value(field_lid, record_lid, value.as(Persistency::Cell))
            end
        end
    end
    private def fingerprint_patch_and_get(row_old : Array(T), row : Array(T) = row_old, patch_checker = Hash(Int32,T).new) : Array(RecordLID|NilRecordStruct|Nil) # also propagates any pending local changes (patching)
        # patches the argument `row` as a side-effect
        # result is record_lids of all root nodes plus _source_ reference cells (since _target_ cells might not be in @tree, only in @graph!)
        # function should also cope with several changes in `row`
        # observation: @graph.reference_rank_maps does not work in general, since unreferenced entries are not stored there!
        fingerprint_columns do |source_record_lid_col, source_reference_cell_col, target_record_lid_col|
            # patching follows in this block
            referencing_field_lid = @tree.indices.bwd(source_reference_cell_col)[1].as(FieldLID)
            if (row_old[source_record_lid_col] != row[source_record_lid_col])
                # source RecordLID cells differ -> the source ReferenceCell is outdated (also in `row`), we need to read the proper one
                record_lid = row[source_record_lid_col] # we can only trust this one
                if record_lid.nil? || (record_lid == NilRecord)
                    record_lid = nil
                elsif record_lid.is_a?(RecordLID)
                    record_lid = record_lid.as(RecordLID)
                else
                    assert(false)
                end
                value_new = nil
                if !record_lid.nil?
                    value_new = @persistency.get_value(referencing_field_lid, record_lid) # it's safe to call since record_lid is defined
                end
                value_new = create_reference(source_reference_cell_col, value_new.as(RecordLID?))
                if (patch_checker[source_reference_cell_col]? || value_new) != value_new
                    raise ConditionsNotMet.new("Cannot assign incompatible values")
                end
                patch_checker[source_reference_cell_col] = value_new
                row[source_reference_cell_col] = value_new # the actual patching of the source ReferenceCell
            end
            # now we can trust the source data in `row`
            if row_old[source_reference_cell_col] != row[source_reference_cell_col]
                # source ReferenceCells differ -> we have to update the target RecordLID cell
                referenced_field_lid = @referencing[referencing_field_lid]
                rank = row[source_reference_cell_col].as(ReferenceCell(U)?) # not a rank yet...
                if rank.is_a?(ReferenceCell(U))
                    rank = rank.rank
                    record_lid = @references[referenced_field_lid].not_nil![0].bwd?(rank) # the target table RecordLID to which the (new) source ReferenceCell refers to
                    rank = rank.to_i64
                else
                    record_lid = nil
                    rank = NilRecord
                end
                record_lid = NilRecord if !record_lid
                if (patch_checker[target_record_lid_col]? || record_lid) != record_lid
                    raise ConditionsNotMet.new("Cannot assign incompatible values")
                end
                patch_checker[target_record_lid_col] = record_lid
                row[target_record_lid_col] = record_lid # the actual patching for the target RecordLID # included in loop below; needed for fingerprint
                # the following is for patching for proper multi-assignment handling (not for fingerprinting)
                table, _ = @tree.indices.bwd(target_record_lid_col)
                target_rank_col = @tree.indices[{table, PseudoFields::Rank}]
                row[target_rank_col] = rank
                table.each do |field_lid|
                    if field_lid.is_a?(FieldLID) && (col = @tree.indices[{table, field_lid}]?) && (row[col] == NilRecord)
                        row[col] = nil
                    end
                end
            end
        end.map do |col_i|
            row[col_i].as(RecordLID|NilRecordStruct|Nil)
        end
    end
    private def fingerprint_match(fingerprint : Array(RecordLID|NilRecordStruct|Nil)) : Int32? # returns matching row id
        columns = fingerprint_columns {}
        res = nil
        assert(fingerprint.size == columns.size)
        @table_raw.each_with_index do |row, row_i|
            row_fingerprint = columns.map {|col_i| row[col_i].as(RecordLID|NilRecordStruct|Nil)}
            if row_fingerprint == fingerprint
                res = row_i
                break
            end
        end
        res
    end
    private def fingerprint_columns(&) : Array(Int32) # block can do patching, if needed
        columns = Array(Int32).new
        DiGraph::Algorithms::TopSort.new(@graph.graph).do.map do |el|
            node = el[:node]
            if @tree2graph.bwd?(node) # we ignore the extra graph nodes
                if edge = el[:edge] # internal node, patching might be needed
                    assert(node == edge.target) # TopSort works this way and we need it like this
                    field_lids = @graph.field_lids[edge]
                    source_reference_col = @tree.indices[{@tree2graph.bwd(edge.source), field_lids[0]}] # we need the column of the reference cell in the source table
                    source_record_lid_col = @tree.indices[{@tree2graph.bwd(edge.source), PseudoFields::RecordLID}] # we need the column of the RecordLID cell in the source table...
                    target_record_lid_col = @tree.indices[{@tree2graph.bwd(edge.target), PseudoFields::RecordLID}] # ... and also in the target table
                    yield(source_record_lid_col, source_reference_col, target_record_lid_col)
                end
                columns << @tree.indices[{@tree2graph.bwd(node), PseudoFields::RecordLID}] # we always take the record lid for the fingerprint
            end
        end
        columns
    end
    private def make_sibling(index : Index, constraints : Hash(Int32, T), candidates : Array(T)) : Int32 # returns row index
        # task is to _indirectly_ create a sibling on high level; the real new record(s) to achieve this should be as low level as possible
        # self[index].as(ReferenceCell).each_defined_fulfilling.to_a # be aware this doesn't work here, since constraining is visible only in Hierarchic
        row = @table_raw[index[0]].dup # for fingerprinting
        fingerprint0 = fingerprint_patch_and_get(row)
        candidates = candidates.map {|el| el.as(ReferenceCell).rank}.to_set # now: Set(Int32), possibly empty

        # first, translating constraints
        constraints.delete(index[1]) # could be in, needs to be taken out
        reference_constraints = constraints.select {|col,el| el.is_a?(ReferenceCell)}.map {|col,el| {col, el.as(ReferenceCell).rank}}.to_h
        value_constraints = constraints.select {|col,el| !el.is_a?(ReferenceCell)} # treated differently, see below
        constraints = constrain_translate_constraints(reference_constraints) # now: Node=>Array(Set(Int32))
        value_constraints.each do |col, el|
            int_col = @tree.user_columns[col]
            node, field_lid = @tree.indices.bwd(int_col) # rooted tree node
            node = @tree2graph[node] # graph node
            if field_lid.is_a?(FieldLID)
                recordlidvalues = (@field2recordlidvalues[field_lid] ||= @persistency.get_field(field_lid, false).map{|k,v| {k,v.as(T)}})
                set = recordlidvalues.map_with_index {|kv,i| {kv[1]==el,i} }.select {|match,i| match}.map {|el| el[1]+1}.to_set
            elsif field_lid == PseudoFields::Rank
                set = Set{el.as(Int64).to_i32}
            else
                assert(false)
            end
            constraints[node] ||= Array(Set(Int32)).new
            constraints[node] << set
        end
        # second, replacing current constraint with candidates
        int_col = @tree.user_columns[index[1]]
        node, field_lid = @tree.indices.bwd(int_col) # rooted tree node, referencing field_lid
        referenced_field_lid = @referencing[field_lid.as(FieldLID)]
        node = @tree2graph[node].out_edges.select {|e| @graph.field_lids[e] == {field_lid.as(FieldLID), referenced_field_lid}} [0].target # need to operate on @graph (more leaves)
        constraints[node] ||= Array(Set(Int32)).new
        constraints[node] << candidates

        # third, propagate constraints
        constraints = constrain_all(constraints)

        # fourth, all ancestor nodes wrt. "node" (incl. "node" itself): in case of empty constraint: need to define a new record and link according to edge
        # we calculate the number of ranks per graph node (we don't have this readily stored somewhere...)
        ranks = Hash(DiGraph::Node, Int32).new
        @graph.graph.edges.each do |e|
            field_lids = @graph.field_lids[e] # {source, target} FieldLIDs
            ranks[e.source] ||= @graph.reference_rank_maps[e].size
            ranks[e.target] ||= @references[field_lids[1]].not_nil![0].size
        end
        DiGraph::Algorithms::DFS.new(@graph.graph, true, false, true).do(node).each do |el|
            # we go _back_, starting from "node", always calling this block _before_ recursion
            row_old = row.dup
            constraint = constraints[el[:node]].not_nil! # always (really) constrained
            if constraint.empty?
                # make record...
                if table_lid = @graph.table_lids[el[:node]]
                    record_lid = @persistency.add_record(table_lid)
                    if treenode = @tree2graph.bwd?(el[:node])
                        record_lid_col = @tree.indices[{treenode,PseudoFields::RecordLID}]
                        row[record_lid_col] = record_lid # for fingerprinting
                    end
                    new_rank = ranks[el[:node]] + 1 # since these ranks (from Persistency) start with 1, we need to increment
                    ranks[el[:node]] += 1
                    constraint.add(new_rank) # also add new rank to constraints
                    # ... and fulfill value_constraints...
                    value_constraints.each do |col,el|
                        treenode2, field_lid = @tree.indices.bwd(@tree.user_columns[col])
                        if treenode == treenode2 # in same table?
                            if field_lid == PseudoFields::Rank
                                new_rank = @persistency.move_record_by_rank(table_lid, new_rank, el.as(Int64).to_i32!) # the proper (limited) new rank
                                # no patching done here (not necessary?)
                            elsif field_lid.is_a?(FieldLID)
                                @persistency.set_value(field_lid.as(FieldLID), record_lid, el.as(Persistency::Cell))
                            else
                                assert(false)
                            end
                        end
                        # we need not update "row", since this part is not used for fingerprinting
                    end
                    # ... and remember the record/rank pair
                    el[:node].in_edges.each do |e| # TODO(vtable): clumsy — no direct per-node data structure for this
                        field_lids = @graph.field_lids[e]
                        if !@references[field_lids[1]].not_nil![0][record_lid]?
                            @references[field_lids[1]].not_nil![0][record_lid] = new_rank
                            @references[field_lids[1]].not_nil![1] << nil # need to keep balance
                        end
                    end
                end
            else
                rank = constraint.first
                el[:node].in_edges.each do |e| # TODO(vtable): clumsy — no direct per-node data structure for this yet
                    field_lids = @graph.field_lids[e]
                    record_lid = @references[field_lids[1]].not_nil![0].bwd(rank)
                    break
                end
            end
            if edge = el[:edge]
                # make reference between those ranks, thus fulfilling constraints
                assert(el[:node] == edge.source) # this time it works like this
                graphnodes = {edge.source, edge.target}
                treenode = @tree2graph.bwd(graphnodes[0])
                field_lids = @graph.field_lids[edge]
                ranks2 = graphnodes.map {|n| constraints[n].not_nil!.first} # we just (arbitrarily) link the first ranks
                referenced_record_lid = @references[field_lids[1]].not_nil![0].bwd(ranks2[1])
                @persistency.set_value(field_lids[0], record_lid.not_nil!, referenced_record_lid.as(Persistency::Cell))
                col = @tree.indices[{treenode,field_lids[0]}]
                row[col] = create_reference(col, referenced_record_lid) # ... the proper ReferenceCell
            end
            fingerprint_patch_and_get(row_old, row) # propagate, if necessary
        end

        # fifth, construct fingerprint
        fingerprint = fingerprint_patch_and_get(row)
        # switch on ShowAll, if needed
        node, field_lid = @tree.indices.bwd(int_col) # rooted tree node, referencing field_lid
        is_showall = was_showall = @tree.configurator.is_selected?(node[PseudoFields::ShowAll])
        if (@tree.tables.size > 1) && !is_showall
            # needed to enforce actually showing the new record
            @tree.configurator.toggle_select(node[PseudoFields::ShowAll])
            is_showall = true
        end
        update
        if is_showall && !was_showall # in this case we try to reduce again
            @tree.configurator.toggle_select(node[PseudoFields::ShowAll]) # disable ShowAll
            update # need to call manually since we're operating lowlevel
            if fingerprint_match(fingerprint).nil?
                @tree.configurator.toggle_select(node[PseudoFields::ShowAll]) # not found, need to re-enable
                update
                # we stick with the default index
            end
        end
        fingerprint_match(fingerprint).not_nil!
    end
end

end # module
