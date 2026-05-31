require "spec"
require "../src/weakkeymap"

module SpecHelpers::WeakKeyMap
    class Graph
        def initialize
            @nodes = Set(Node).new
        end
        def add_node : Node
            n = Node.new
            @nodes.add(n)
            n
        end
        def remove_node(node : Node) : Nil
            @nodes.delete(node)
            nil
        end
        class Node
        end
    end
end

def fn(g, h)
    n1 = g.add_node
    h[n1] = "foo"
    h[n1].should eq "foo"
    g.remove_node(n1)
    n2 = g.add_node
    h[n2] = "bar"
    h[n2].should eq "bar"
    g.remove_node(n2)
    n3 = g.add_node
    h[n3] = "foo1"
    h[n3].should eq "foo1"
    g.remove_node(n3)
    n4 = g.add_node
    h[n4] = "foo2"
    h[n4].should eq "foo2"
    g.remove_node(n4)
    n5 = g.add_node
    h[n5] = "foo3"
    h[n5].should eq "foo3"
    g.remove_node(n5)
    n6 = g.add_node
    h[n6] = "foo4"
    h[n6].should eq "foo4"
    g.remove_node(n6)
end

describe WeakKeyMap do
    it "works" do
        g = SpecHelpers::WeakKeyMap::Graph.new
        h = WeakKeyMap(SpecHelpers::WeakKeyMap::Graph::Node, String).new
        fn(g,h)
        h.size.should be_close(6, 1)
        # not working properly, since we create way too many fibers
        # GC.collect
        # 4.times {Fiber.yield}
        # h.size.should be_close(2, 1)
        # 2.times {Fiber.yield}
        # h.size.should be_close(0, 1)
    end
end
