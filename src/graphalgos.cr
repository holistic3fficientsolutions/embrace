# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "./graph"
require "./weakkeymap"
require "./patch" # for having #sort for Hash and Set

# DFS (depth first search)
class DiGraph::Algorithms::DFS
    def initialize(@g : Graph, @follow_in_edges : Bool, @follow_out_edges : Bool, @hook_before_recursion : Bool)
        @visited = WeakKeyMap(DiGraph::Node, Bool).new
        @output = Array({edge: DiGraph::Edge?, node: DiGraph::Node}).new
    end
    # for all nodes
    def do : Array({edge: DiGraph::Edge?, node: DiGraph::Node}) # returns nodes in proper order, can be used for further #each or #map
        @g.nodes.each do |n|
            if (@follow_out_edges && (n.in_edges.size==0)) ||
                (@follow_in_edges && (n.out_edges.size==0))
                recurse(nil, n)
            end
        end
        @g.nodes.each do |n|
            recurse(nil, n)
        end
        @output
    end
    # for a given node
    def do(node : DiGraph::Node) : Array({edge: DiGraph::Edge?, node: DiGraph::Node})
        recurse(nil, node)
        @output
    end
    private def recurse(edge : DiGraph::Edge?, node : DiGraph::Node)
        if !@visited[node]?
            @visited[node] = true # we do not check for cycles, i.e. assume an acyclic graph
            @output << {edge: edge, node: node} if @hook_before_recursion
            if @follow_in_edges
                node.in_edges.each {|e| recurse(e, e.source)}
            end
            if @follow_out_edges
                node.out_edges.each {|e| recurse(e, e.target)}
            end
            @output << {edge: edge, node: node} if !@hook_before_recursion
        end
    end
end

# topological sorting
class DiGraph::Algorithms::TopSort < DiGraph::Algorithms::DFS
    def initialize(@g : Graph)
        super(g, false, true, false)
    end
    def do : Array({edge: DiGraph::Edge?, node: DiGraph::Node})
        res = super
        res.reverse
    end
end

# generic way for updating all neighbours of a node, fulfiling those requirements
# (type T `key` is from a node point of view a unique value associated with an edge):
# - for a new key: gets sorted in the proper order (i.e. at the end all the edges of the node have the same order as `next_keys`); block can assign any attributes to custom values and create edge in arbitrary direction
# - for a removed key: node gets removed as well
# - for an unchanged key: all Nodes and Edges stay unchanged, i.e. all WeakKeyMaps still have their original values
# makes mostly sense for tree like graphs
# user needs to provide the edge set (i.e. either all, incoming or outgoing edges)
class DiGraph::Algorithms::UpdateNeighbours(T)
    def initialize(@g : Graph, @current_keys : WeakKeyMap(Edge,T))
    end
    def do(node : Node, edge_set : Set(Edge), new_keys : Array(T), &block : T,Node,Node -> Edge)
        # 1. mark all current keys as unused
        is_key_used = edge_set.map {|edge| {@current_keys[edge],false}}.to_h
        # 2. for all new keys: (a) insert edge (if not existing) and (b) mark as used
        new_keys.each do |key|
            if !is_key_used.has_key?(key)
                node2 = @g.add_node
                e = block.call(key, node, node2) # block can create edge in any direction (needs to return it!) and initialize all attributes
                @current_keys[e] = key
            end
            is_key_used[key] = true
        end
        # 3. remove outdated nodes/edges
        edge_set.each do |edge|
            key = @current_keys[edge]
            if !is_key_used[key]
                node2 = {edge.source,edge.target}.select(&.!=(node))[0]
                @g.remove(node2)
            end
        end
        # 4. sort new edges according to order in `new_keys`
        key2order = new_keys.map_with_index {|k,i| {k,i}}.to_h
        @g.sort_edges!(node, edge_set) {|x,y| key2order[@current_keys[x]] <=> key2order[@current_keys[y]]}
    end
end
