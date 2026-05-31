require "spec"
require "../../src/table/sparse"

describe Table::Sparse do
    it "works" do
        x = Table::Sparse(Array(Int32)).new([3,4])
        x[[1,1]] ||= Array(Int32).new
        x[[1,2]] ||= Array(Int32).new
        x[[1,3]] ||= Array(Int32).new
        x[[2,1]] ||= Array(Int32).new
        x[[2,2]] ||= Array(Int32).new
        x[[2,3]] ||= Array(Int32).new
        x[[1,1]] << 1
        x[[1,1]] << 2
        x[[1,1]] << 3
        x[[1,1]] << 4
        x[[1,1]] << 5
        x[[1,2]] << 6
        x[[1,2]] << 7
        x[[1,3]] << 8
        x[[1,3]] << 9
        x[[1,3]] << 10
        x[[2,1]] << 11
        x[[2,2]] << 12
        x[[2,2]] << 13
        x[[2,3]] << 14

        result = [[[1, 1], [1, 2, 3, 4, 5]],
            [[1, 2], [6, 7]],
            [[1, 3], [8, 9, 10]],
            [[2, 1], [11]],
            [[2, 2], [12, 13]],
            [[2, 3], [14]]]
        i = 0
        x.rows.each do |row| # row is a Set(Index)
            row.each do |cell| # cell is an Index
                [cell, x[cell]].should eq(result[i])
                i += 1
            end
        end
        x[[2,2]].should eq([12,13])
    end
    it "iterator works" do
        x = Table::Sparse(Int32).new([3,5])
        x[[0,2]] = 20
        x[[0,4]] = 10
        x[[0,0]] = 30
        # normal forward & backward:
        x.row(0).each.to_a.map {|i| x[i]}.should eq([30,20,10])
        x.row(0).each.reverse.to_a.map {|i| x[i]}.should eq([10,20,30])
        # forward & backward with existing starting values:
        x.row(0).each_starting_with([0,2]).to_a.map {|i| x[i]}.should eq([20,10])
        x.row(0).each_starting_with([0,2]).reverse.to_a.map {|i| x[i]}.should eq([20,30])
        # forward & backward with missing starting values:
        x.row(0).each_starting_with([0,3]).to_a.map {|i| x[i]}.should eq([10])
        x.row(0).each_starting_with([0,3]).reverse.to_a.map {|i| x[i]}.should eq([20,30])
        # non-existing values:
        x.row(0).each_starting_with([0,6]).to_a.map {|i| x[i]}.should eq([] of Int32)
        x.row(0).each_starting_with([0,-1]).reverse.to_a.map {|i| x[i]}.should eq([] of Int32)
    end
    it "implicit sorting works" do
        x = Table::Sparse(Array(Int32)).new([3,4])
        x[[1,3]] ||= Array(Int32).new
        x[[1,1]] ||= Array(Int32).new
        x[[1,2]] ||= Array(Int32).new
        x[[2,1]] ||= Array(Int32).new
        x[[2,2]] ||= Array(Int32).new
        x[[2,3]] ||= Array(Int32).new
        x[[2,3]] << 14
        x[[1,1]] << 1
        x[[1,2]] << 6
        x[[1,1]] << 2
        x[[1,1]] << 3
        x[[1,1]] << 4
        x[[1,3]] << 8
        x[[1,3]] << 9
        x[[1,3]] << 10
        x[[2,1]] << 11
        x[[2,2]] << 12
        x[[2,2]] << 13
        x[[1,1]] << 5
        x[[1,2]] << 7
        all = Hash(Array(Int32),Array(Int32)).new
        x.rows.each do |row| # row is a Set(Index)
            row.each do |cell| # cell is an Index
                all[cell] = x[cell]
            end
        end
        all.to_a.should eq([{[1, 1], [1, 2, 3, 4, 5]}, {[1, 2], [6, 7]}, {[1, 3], [8, 9, 10]}, {[2, 1], [11]}, {[2, 2], [12, 13]}, {[2, 3], [14]}])
    end
end
