require "spec"
require "../src/tree"

describe RootedTree do
    it "dynamic node creation works" do
        tree = RootedTree(Int32, Int32).new(0)
        tree.dfs_down do |e,n,l|
            case l
            when 0
                n.add_subtree(10, RootedTree(Int32, Int32).new(0))
                n.add_subtree(20, RootedTree(Int32, Int32).new(0))
                n.add_subtree(30, RootedTree(Int32, Int32).new(0))
            when 1
                n.add_subtree(100, RootedTree(Int32, Int32).new(0))
                n.add_subtree(200, RootedTree(Int32, Int32).new(0))
                n.add_subtree(300, RootedTree(Int32, Int32).new(0))
            end
        end
        num = 0
        tree.dfs_down { num += 1 }
        num.should eq(13) # 1x level 0, 3x level 1, 9x level 2 -> 13
    end
end
