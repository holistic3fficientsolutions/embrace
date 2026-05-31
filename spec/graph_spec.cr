require "spec"
require "../src/graph"
require "../src/graphalgos"

include DiGraph

module SpecHelpers::Digraph
    # put any auxiliary classes/methods here
end

describe DiGraph::Graph do
    it "works" do
        g = Graph.new
        n1 = g.add_node
        n2 = g.add_node
        n3 = g.add_node
        e12 = g.add_edge(n1, n2)
        g.add_edge(n1, n3)
        g.add_edge(n3, n2)
        g.to_s.should eq("0->1\n0->2\n2->1\n")
        na = WeakKeyMap(Node, Int32).new
        na[n1] = 12
        na[n1]?.should eq(12)
        na[n2]?.should eq(nil)
        DiGraph::Algorithms::TopSort.new(g).do.map(&.[:node]).should eq ([n1,n3,n2])
        DiGraph::Algorithms::DFS.new(g, true, false, false).do.map(&.[:node]).should eq ([n1,n3,n2])
        g.node_edges[n1].size.should eq(2)
        g.add_edge(n1,n2).should eq(e12)
        g.node_edges[n1].size.should eq(2) # no multiple edges
    end
    it "overlay works" do
        g = Graph.new
        n1 = g.add_node
        n2 = g.add_node
        g.add_edge(n1, n2)
        h = Graph.new
        h.add_node(n1)
        n3 = h.add_node
        keys = WeakKeyMap(Node, Int32).new
        h.add_edge(n1, n3)
        keys[n1] = 1
        keys[n2] = 2
        keys[n3] = 3
        n1.out_edges.map {|e| keys[e.target]}.should eq [2]
        h[n1].out_edges.map {|e| keys[e.target]}.should eq [3] # with h[] we switch to the overlay graph h
    end
    it "edge sorting works" do
        g = Graph.new
        n1 = g.add_node
        n2 = g.add_node
        n3 = g.add_node
        e1 = g.add_edge(n1, n2)
        e2 = g.add_edge(n1, n3)
        e3 = g.add_edge(n3, n1)
        g.node_edges[n1].size.should eq(3)
        g.add_edge(n1, n2).should eq(e1) # no multigraph
        g.node_edges[n1].size.should eq(3)
        map = WeakKeyMap(Edge,Int32).new
        map[e1] = 2
        map[e2] = 3
        map[e3] = 1
        g.node_edges[n1].to_a.should eq([e1,e2,e3])
        g.sort_edges!(n1) {|x,y| map[y]<=>map[x]}
        g.node_edges[n1].to_a.should eq([e2,e1,e3])
    end
    it "update neighbours works" do
        g = Graph.new
        n1 = g.add_node
        n2 = g.add_node
        n3 = g.add_node
        e1 = g.add_edge(n1, n2)
        e2 = g.add_edge(n1, n3)
        edge2key = WeakKeyMap(Edge, Int32).new
        edge2key[e1] = 2
        edge2key[e2] = 1
        upt = DiGraph::Algorithms::UpdateNeighbours.new(g, edge2key)
        e3 = nil
        upt.do(n1, n1.edges, [3,1]) do |key,n1,n2| # this forces n1 to get exactly two neighbours (those with keys 3 and 1, in this order); 2 gets removed, 3 gets created on the fly
            e3 = g.add_edge(n1,n2) # forward direction, and returned
        end
        n1.edges.size.should eq(2)
        n1.edges.to_a.should eq([e3,e2])
    end
    it "DFS works (at least on a tree)" do
        g = Graph.new
        n1 = g.add_node
        n2 = g.add_node
        n3 = g.add_node
        e12 = g.add_edge(n1, n2)
        e23 = g.add_edge(n2, n3)
        # be aware that we always want to also get the edges enumerated (instead of all nil)!
        DiGraph::Algorithms::DFS.new(g, true, false, true).do.should eq([{edge: nil, node: n3}, {edge: e23, node: n2}, {edge: e12, node: n1}])
        DiGraph::Algorithms::DFS.new(g, true, false, false).do.should eq([{edge: e12, node: n1}, {edge: e23, node: n2}, {edge: nil, node: n3}])
        DiGraph::Algorithms::DFS.new(g, false, true, true).do.should eq([{edge: nil, node: n1}, {edge: e12, node: n2}, {edge: e23, node: n3}])
        DiGraph::Algorithms::DFS.new(g, false, true, false).do.should eq([{edge: e23, node: n3}, {edge: e12, node: n2}, {edge: nil, node: n1}])
        DiGraph::Algorithms::DFS.new(g, true, true, true).do.should eq([{edge: nil, node: n1}, {edge: e12, node: n2}, {edge: e23, node: n3}])
        DiGraph::Algorithms::DFS.new(g, true, true, false).do.should eq([{edge: e23, node: n3}, {edge: e12, node: n2}, {edge: nil, node: n1}])
    end
end
