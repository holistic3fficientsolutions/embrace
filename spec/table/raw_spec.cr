require "spec"
require "../../spec/spec_helper"
require "../../src/table/raw"
require "../../src/global"

include Table # in order to be able to test protected methods

describe Table::Lazy::Raw do
    it "special sizes" do
        # - special tables with table[row][col]; num_rows=table.size, num_cols=table[0].size
        #     - 1x2: [[1,2]]
        #     - 2x1: [[1],[2]]
        #     - 2x3: [[1,2,3],[4,5,6]]
        #     - 2x0: [] of Array(T)
        #     - 0x?: [] of Array(T); no way to tell how many columns, we just define it like this
        table = Table::Lazy::Raw::Memory(Cell).new([0,0])
        table.to_a.should eq([] of Cell)
        table.to_a2.should eq([] of Array(Cell))
        table = Table::Lazy::Raw::Memory(Cell).new([2,0])
        table.to_a.should eq([] of Cell)
        table.to_a2.should eq([] of Array(Cell))
        table = Table::Lazy::Raw::Memory(Cell).new([0,2])
        table.to_a.should eq([] of Cell)
        table.to_a2.should eq([] of Array(Cell))
    end
    it "multiple types" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,2]).load(toBaseCellsArray([1,"one",2.0,true,false,nil]))
        table.to_a2.should eq([[1,"one"],[2.0,true],[false,nil]])
    end
    it "converting to csv" do
        table = Table::Lazy::Raw::Memory(Cell).new([2,2]).load(toBaseCellsArray((11..14).to_a))
        table.to_csv.chomp.should eq(<<-EOT)
            11;12
            13;14
            EOT
    end
    it "converting to string" do
        table = Table::Lazy::Raw::Memory(Cell).new([2,2]).load(toBaseCellsArray((11..14).to_a))
        table.to_s.chomp.should eq(<<-EOT)
            -------
            11 | 12
            13 | 14
            -------
            EOT
    end
    it "slicing" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,3]).load(toBaseCellsArray((11..19).to_a))
        table.slice([(1..2),nil]).to_a2.should eq([[14,15,16],[17,18,19]])
    end
    it "slicing again" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,3]).load(toBaseCellsArray((11..19).to_a))
        table.slice([(1..-1),2]).each.to_a.should eq([16,19])
    end
    it "slicing yet again" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,3]).load(toBaseCellsArray((11..19).to_a))
        table.slice([0,nil]).each.with_index.to_h[12i64].should eq(1)
    end
    it "derivedtable" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,3]).load(toBaseCellsArray((11..19).to_a))
        x = Table::Lazy::Raw::Derived(Cell).new(table) {|parent| Table::Lazy::Raw::Memory(Cell).new([1]).load([parent[[0,0]]].map(&.as(Cell)))}
        x.to_a.should eq([11])
        table[[0,0]] = "xxx"
        x.to_a.should eq(["xxx"])
    end
    it "combine two cubes" do
        x1 = Table::Lazy::Raw::Memory(Cell).new([3,2]).load(%w(one two three four five six).map(&.as(Cell)))
        x2 = Table::Lazy::Raw::Derived(Cell).new(x1) {
            Table::Lazy::Raw::Memory(Cell).new([2,2]).load(%w(1 2 3 4).map(&.as(Cell)))}
        x = Table::Lazy::Raw::Combined(Cell).new(x1, 0, x2)
        x.size.should eq([5, 2])
        x.to_a2.should eq([%w(one two),%w(three four),%w(five six),%w(1 2),%w(3 4)])
        x1[[1,1]] = "vier"
        x.to_a2.should eq([%w(one two),%w(three vier),%w(five six),%w(1 2),%w(3 4)])
    end
    it "combine cube and hyperplane" do
        x1 = Table::Lazy::Raw::Memory(Cell).new([3,2]).load(%w(one two three four five six).map(&.as(Cell)))
        x2 = Table::Lazy::Raw::Derived(Cell).new(x1) {
            Table::Lazy::Raw::Memory(Cell).new([3]).load(%w(1 2 3).map(&.as(Cell)))}
        x = Table::Lazy::Raw::Combined(Cell).new(x1, 1, x2)
        x.size.should eq([3, 3])
        x.to_a2.should eq([%w(one two 1),%w(three four 2),%w(five six 3)])
        x1[[1,1]] = "vier"
        x.to_a2.should eq([%w(one two 1),%w(three vier 2),%w(five six 3)])
    end
    it "reducedtable" do
        table = Table::Lazy::Raw::Memory(Cell).new([5,3]).load(toBaseCellsArray((11..25).to_a))
        redtab = Table::Lazy::Raw::Reduced.new(table, 0, [0,2,4])
        redtab.to_a2.should eq([[11,12,13],[17,18,19],[23,24,25]])
    end
    it "basic moves" do
        table = Table::Lazy::Raw::Memory(Cell).new([4,2]).load(toBaseCellsArray((1..8).to_a))
        table.hyperplane_move(0,[1,0],[0,0])
        table.to_a.should eq([3,4,1,2,5,6,7,8])
        table.hyperplane_move(0,[0,0],[1,0])
        table.to_a.should eq([1,2,3,4,5,6,7,8])
        table.hyperplane_move(0,[2,0],[3,0])
        table.to_a.should eq([1,2,3,4,7,8,5,6])
        table.hyperplane_move(0,[3,0],[2,0])
        table.to_a.should eq([1,2,3,4,5,6,7,8])
        table.hyperplane_move(0,[1,0],[3,0])
        table.to_a.should eq([1,2,5,6,7,8,3,4])
        table.hyperplane_move(0,[3,0],[1,0])
        table.to_a.should eq([1,2,3,4,5,6,7,8])
    end
    it "boundary cases" do
        table = Table::Lazy::Raw::Memory(Cell).new([0,0])
        table.hyperplane_add(0,[-1,-1]) # index is ignored
        table.size.should eq([1,0])
        table.to_a.should eq([] of Cell)
        table.to_a2.should eq([] of Array(Cell))
        table.hyperplane_add(1,[-1,-1])
        table.size.should eq([1,1])
        table.to_a.should eq([nil])
        table.to_a2.should eq([[nil]])
        table = Table::Lazy::Raw::Memory(Cell).new([0,0])
        table.hyperplane_add(1,[-1,-1]) # index is ignored
        table.size.should eq([0,1])
        table.to_a.should eq([] of Cell)
        table.to_a2.should eq([] of Array(Cell))
    end
    it "moving in chained tables" do
        table1 = Table::Lazy::Raw::Memory(Cell).new([4,4]).load(toBaseCellsArray((1..16).to_a))
        table2 = table1.slice([nil,(1..2)])
        table3 = Table::Lazy::Raw::Reduced(Cell).new(table2, 0, [0,3])
        table3.size.should eq([2,2])
        table1.to_a.should eq((1..16).to_a)
        table3.hyperplane_move(0,[1,0,0,0],[0,0,0,0])
        table1.to_a.should eq([13,14,15,16,1,2,3,4,5,6,7,8,9,10,11,12])
    end
    it "adding a hyperplane in 3D" do
        table = Table::Lazy::Raw::Memory(Cell).new([2,3,4]).load(toBaseCellsArray((1..24).to_a))
        table.hyperplane_add(0).should eq([2,0,0])
        table.to_a.should eq([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil])
        table = Table::Lazy::Raw::Memory(Cell).new([2,3,4]).load(toBaseCellsArray((1..24).to_a))
        table.hyperplane_add(1).should eq([0,3,0]) # should make no difference if table2 or table
        table.to_a.should eq([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, nil, nil, nil, nil, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, nil, nil, nil, nil])
        table = Table::Lazy::Raw::Memory(Cell).new([2,3,4]).load(toBaseCellsArray((1..24).to_a))
        table.hyperplane_add(2).should eq([0,0,4])
        table.to_a.should eq([1, 2, 3, 4, nil, 5, 6, 7, 8, nil, 9, 10, 11, 12, nil, 13, 14, 15, 16, nil, 17, 18, 19, 20, nil, 21, 22, 23, 24, nil])
    end
    it "adding and removing a hyperplane" do
        table = Table::Lazy::Raw::Memory(Cell).new([2,2]).load(toBaseCellsArray((1..4).to_a))
        table2 = Table::Lazy::Raw::Reduced(Cell).new(table, 0, [0])
        table2.hyperplane_add(0, x: 42).should eq([2,0]) # should make no difference if table2 or table; optional args are passed to root table (will be ignored for Memory here)
        table.to_a.should eq([1,2,3,4,nil,nil])
        table.hyperplane_remove(0,[2,0])
        table2.hyperplane_add(1).should eq([0,2])
        table.to_a.should eq([1,2,nil,3,4,nil])
        table.hyperplane_remove(0,[0,0])
        table.hyperplane_remove(0,[0,0]) # checking for singularity
        table.to_a.should eq([] of Cell)
    end
    it "indexed table" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,3]).load(toBaseCellsArray((11..19).to_a))
        table.to_a2.should eq([[11,12,13],[14,15,16],[17,18,19]])
        table2 = Table::Lazy::Raw::Indexed(Cell).new(table, 1)
        table2.to_a2.should eq([[0,11,12,13],[1,14,15,16],[2,17,18,19]])
        table.hyperplane_move(0,[2,0],[1,0])
        table2.to_a2.should eq([[0,11,12,13],[1,17,18,19],[2,14,15,16]])
        table2[[2,0]] = 1i64 # writing to index results in a (global) move
        table2.to_a2.should eq([[0,11,12,13],[1,14,15,16],[2,17,18,19]])
        table2[[0,0]] = 1i64 # writing to index results in a (global) move
        table2.to_a2.should eq([[0,14,15,16],[1,11,12,13],[2,17,18,19]])
    end
    it "permuted table" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,3]).load(toBaseCellsArray((11..19).to_a))
        table2 = Table::Lazy::Raw::Permuted(Cell).new(table, [1,0])
        table2.to_a2.should eq([[11,14,17],[12,15,18],[13,16,19]])
    end
    it "multiassignment" do
        table = Table::Lazy::Raw::Memory(Cell).new([3,3]).load(toBaseCellsArray((11..19).to_a))
        table.to_a2.should eq([[11,12,13],[14,15,16],[17,18,19]])
        table2 = Table::Lazy::Raw::Indexed(Cell).new(table, 1)
        table2.to_a2.should eq([[0,11,12,13],[1,14,15,16],[2,17,18,19]])
        table2.multiassign_begin
        table2[[1,0]] = 2i64
        table2[[1,1]] = 41i64
        table2.multiassign_end
        table2.to_a2.should eq([[0,11,12,13],[1,17,18,19],[2,41,15,16]])
    end
end # describe

{% if false %}
{% end %}
