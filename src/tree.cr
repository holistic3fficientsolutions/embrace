# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# a simple tree class that allows...
# - user defined child indexing
# - user defined node attribute

class RootedTree(NodeType, EdgeType)
    property parent : RootedTree(NodeType, EdgeType) | Nil
    property edge_to_parent : EdgeType | Nil
    property value : NodeType
    @children : Hash(EdgeType, RootedTree(NodeType, EdgeType)) # the key is mutable, but not a recursive data structure
    @hook : Proc(Nil)?
    def initialize(@value = NodeType.new)
        @parent = nil
        @edge_to_parent = nil
        @children = Hash(EdgeType, RootedTree(NodeType, EdgeType)).new
        @hook = nil
    end
    def initialize(@value = NodeType.new, &hook)
        @parent = nil
        @edge_to_parent = nil
        @children = Hash(EdgeType, RootedTree(NodeType, EdgeType)).new
        @hook = hook
    end
    def add_subtree(name : EdgeType, subtree = RootedTree(NodeType, EdgeType).new) # links trees in both directions (i.e. modifies both)
        hook
        @children[name] = subtree
        raise("already someone's child!") if subtree.parent != nil
        subtree.parent = self
        subtree.edge_to_parent = name
        subtree
    end
    def remove_subtree(name : EdgeType)
        hook
        subtree = @children.delete(name).not_nil!
        subtree.parent = nil
        subtree.edge_to_parent = nil
        subtree
    end
    def size
        hook
        @children.size
    end
    def [](index : EdgeType)
        hook
        @children[index]
    end
    def []?(index : EdgeType)
        hook
        @children[index]?
    end
    def sort_children!(ascending : Bool = true)
        hook
        @children = @children.to_a.sort {|x,y| (ascending ? 1 : -1)*(mycmp(x[0],y[0]))}.to_h
    end
    def sort_children!(&block : EdgeType, EdgeType -> Int32)
        hook
        @children = @children.to_a.sort do |x,y|
            block.call(x[0], y[0])
        end.to_h
    end
    def map(&block : EdgeType,RootedTree(NodeType, EdgeType)->T) forall T
        hook
        @children.map do |e,t|
            yield(e, t)
        end
    end
    def each(&block : EdgeType,RootedTree(NodeType, EdgeType)->)
        hook
        @children.each do |e,t|
            yield(e, t)
        end
    end
    # some convenience methods
    def height
        hook
        depth = 0
        dfs_down {|_,_,level| depth = [depth,level].max}
        depth
    end
    def width
        hook
        last_level = 0
        width = 0
        dfs_up do |_,_,level|
            width += 1 if level >= last_level
            last_level = level
        end
        width
    end
    # the dfs methods traverse all the _edges_ (along with the _target_ node, i.e. child) incl. a virtual (nil) edge to the root node
    def dfs_downup(&block : Bool,EdgeType?,RootedTree(NodeType, EdgeType),Int32 ->)
        hook
        yield(true, nil, self, 0) # artificial yield for root node
        dfs_downup(1, &block)
        yield(false, nil, self, 0) # artificial yield for root node
    end
    protected def dfs_downup(level : Int32, &block : Bool,EdgeType?,RootedTree(NodeType, EdgeType),Int32 ->)
        hook
        each do |edge, child|
            yield(true, edge, child, level) # down; first arg. is `is_down?`
            child.dfs_downup(level+1, &block)
            yield(false, edge, child, level) # false
        end
    end
    def dfs_down(&block : EdgeType?,RootedTree(NodeType, EdgeType),Int32 ->)
        hook
        yield(nil, self, 0) # artificial yield for root node
        dfs_down(1, &block)
    end
    def inspect(io : IO) : Nil # used for p'ing a RC (e.g. when debugging)
        hook
        dfs_down do |edge, child, level|
            edge ||= "(root)" if level==0
            io << ("  "*level + "edge=" + edge.inspect + ", node=" + child.value.inspect)
            io.puts
        end
    end
    protected def dfs_down(level : Int32, &block : EdgeType?,RootedTree(NodeType, EdgeType),Int32 ->)
        hook
        each do |edge, child|
            yield(edge, child, level)
            child.dfs_down(level+1, &block)
        end
    end
    def dfs_up(&block : EdgeType?,RootedTree(NodeType,EdgeType),Int32 ->)
        hook
        dfs_up(1, &block)
        yield(nil, self, 0) # artificial yield for root node
    end
    protected def dfs_up(level : Int32, &block : EdgeType?,RootedTree(NodeType, EdgeType),Int32 ->)
        hook
        each do |edge, child|
            child.dfs_up(level+1, &block)
            yield(edge, child, level)
        end
    end
    protected def hook
        hook = @hook
        hook.call if hook
    end
end
