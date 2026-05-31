# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

# directed graph, allowing loops, but no multiple edges; nodes can be overlayed to several graphs by using Graph#[](Node)
module DiGraph
    class Graph
        @hook : Proc(Nil)?
        def initialize
            @nodes = Set(Node).new
            @edges = Set(Edge).new
            @node_edges = Hash(Node, Set(Edge)).new
            @node_in_edges = Hash(Node, Set(Edge)).new
            @node_out_edges = Hash(Node, Set(Edge)).new
            @node_edges_matrix = Hash(Node, Hash(Node,Edge)).new
            @hook = nil
        end
        def initialize(&hook) # constructor that allows giving a lazy hook (gets called before structure querying methods)
            @nodes = Set(Node).new
            @edges = Set(Edge).new
            @node_edges = Hash(Node, Set(Edge)).new
            @node_in_edges = Hash(Node, Set(Edge)).new
            @node_out_edges = Hash(Node, Set(Edge)).new
            @node_edges_matrix = Hash(Node, Hash(Node,Edge)).new
            @hook = hook
        end
        def size
            @nodes.size
        end
        def add_node(n = Node.new(self))
            # attention: n can be an overlay node with another graph in it (and it will stay like this)
            # for switching contexts you have to use `[n]`
            @nodes.add(n)
            @node_edges[n] ||= Set(Edge).new
            @node_in_edges[n] ||= Set(Edge).new
            @node_out_edges[n] ||= Set(Edge).new
            @node_edges_matrix[n] ||= Hash(Node,Edge).new
            n
        end
        def remove(node : Node)
            check(node)
            node.in_edges {|e| remove(e)}
            node.out_edges {|e| remove(e)}
            @nodes.delete(node)
        end
        def add_edge(source : Node, target : Node)
            edge = @node_edges_matrix[source][target]?
            if !edge
                edge = Edge.new(self, source, target)
                @node_edges[source].add(edge)
                @node_edges[target].add(edge)
                @node_in_edges[target].add(edge)
                @edges.add(edge)
                @node_out_edges[source].add(edge)
                @node_edges_matrix[source][target] = edge
            end
            edge
        end
        def remove(edge : Edge)
            check(edge)
            @node_edges[edge.source].delete(edge)
            @node_edges[edge.target].delete(edge)
            @node_in_edges[edge.target].delete(edge)
            @edges.delete(edge)
            @node_out_edges[edge.source].delete(edge)
            @node_edges_matrix[edge.source].delete(edge.target)
        end
        def [](node : Node) : Node # for overlay nodes
            hook
            node.overlay(self)
        end
        def nodes(&block)
            hook
            @nodes.each {|n| yield(n)}
        end
        def to_s
            s = ""
            ni = WeakKeyMap(Node,Int32).new
            i = 0
            nodes do |n|
                ni[n] = i
                i += 1
            end
            nodes do |n|
                n.out_edges do |e|
                    s += "#{ni[e.source]}->#{ni[e.target]}\n"
                end
            end
            s
        end
        def sort_edges!(node : Node, edge_set : Set(Edge) = node.edges, &block : Edge,Edge -> Int32)
            case edge_set
            when node.edges # we sort all edges of node (or if node has only one type of edges, this is also the default then - which is fine)
                @node_edges[node] = @node_edges[node].sort {|x,y| block.call(x,y)}
                @node_in_edges[node].clear
                @node_out_edges[node].clear
                @node_edges[node].each do |e|
                    @node_in_edges[e.target].add(e)
                    @node_out_edges[e.source].add(e)
                end
            when node.in_edges # we sort only incoming edges to this node
                @node_in_edges[node] = @node_in_edges[node].sort {|x,y| block.call(x,y)}
                @node_edges[node] = @node_edges[node].select {|e| !@node_in_edges[node].includes?(e)}.to_set
                @node_edges[node] += @node_in_edges[node]
            when node.out_edges # we sort only outgoing edges from this node
                @node_out_edges[node] = @node_out_edges[node].sort {|x,y| block.call(x,y)}
                @node_edges[node] = @node_edges[node].select {|e| !@node_out_edges[node].includes?(e)}.to_set
                @node_edges[node] += @node_out_edges[node]
            else
                assert(false)
            end
        end
        getter nodes, edges
        protected getter node_edges, node_in_edges, node_out_edges
        protected def hook
            hook = @hook
            hook.call if hook
        end
        private def check(node : Node)
            raise("no such node") if !@nodes.includes?(node)
        end
        private def check(edge : Edge)
            raise("no such edge") if !@node_out_edges[edge.source].includes?(edge)
        end
    end

    class Node
        protected def initialize(@graph : Graph)
        end
        protected def overlay(@graph)
            self
        end
        def edges : Set(Edge)
            @graph.hook
            @graph.node_edges[self]
        end
        def in_edges : Set(Edge)
            @graph.hook
            @graph.node_in_edges[self]
        end
        def out_edges : Set(Edge)
            @graph.hook
            @graph.node_out_edges[self]
        end
        def edges(&block)
            @graph.hook
            edges.each {|e| yield(e)}
        end
        def in_edges(&block)
            @graph.hook
            in_edges.each {|e| yield(e)}
        end
        def out_edges(&block)
            @graph.hook
            out_edges.each {|e| yield(e)}
        end
        def inspect(io : IO) : Nil # used for p'ing (e.g. when debugging)
            io << "some node"
        end
    end
    class Edge
        protected def initialize(@graph : Graph, @source : Node, @target : Node)
        end
        getter source, target
    end
end
