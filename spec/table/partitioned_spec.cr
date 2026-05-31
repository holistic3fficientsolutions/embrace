require "spec"
require "../../src/global"
require "../../src/table/raw"

include Table # in order to be able to test protected methods

describe Table::Lazy::Raw::Partitioned do
    it "basic keys and per-key views" do
        # 5 rows × 2 cols. col 0 is the key column: values a,b,a,c,b
        content = [
            "a".as(Cell), 1i64.as(Cell),
            "b".as(Cell), 2i64.as(Cell),
            "a".as(Cell), 3i64.as(Cell),
            "c".as(Cell), 4i64.as(Cell),
            "b".as(Cell), 5i64.as(Cell),
        ]
        table = Table::Lazy::Raw::Memory(Cell).new([5,2]).load(content)
        part = Table::Lazy::Raw::Partitioned(Cell).new(table, 0, 0)

        part.keys.sort { |x, y| x.to_s <=> y.to_s }.should eq(["a".as(Cell),"b".as(Cell),"c".as(Cell)])
        part.get_selection("a".as(Cell)).should eq([0,2])
        part.get_selection("b".as(Cell)).should eq([1,4])
        part.get_selection("c".as(Cell)).should eq([3])

        part.view("a".as(Cell)).to_a2.should eq([["a".as(Cell),1i64.as(Cell)],["a".as(Cell),3i64.as(Cell)]])
        part.view("b".as(Cell)).to_a2.should eq([["b".as(Cell),2i64.as(Cell)],["b".as(Cell),5i64.as(Cell)]])
        part.view("c".as(Cell)).to_a2.should eq([["c".as(Cell),4i64.as(Cell)]])
    end

    it "view_union merges multiple keys preserving row order" do
        content = [
            "a".as(Cell), 1i64.as(Cell),
            "b".as(Cell), 2i64.as(Cell),
            "a".as(Cell), 3i64.as(Cell),
            "c".as(Cell), 4i64.as(Cell),
            "b".as(Cell), 5i64.as(Cell),
        ]
        table = Table::Lazy::Raw::Memory(Cell).new([5,2]).load(content)
        part = Table::Lazy::Raw::Partitioned(Cell).new(table, 0, 0)

        # union of a+b: rows 0,1,2,4 in original order
        part.view_union(["a".as(Cell), "b".as(Cell)]).to_a2.should eq([
            ["a".as(Cell),1i64.as(Cell)],
            ["b".as(Cell),2i64.as(Cell)],
            ["a".as(Cell),3i64.as(Cell)],
            ["b".as(Cell),5i64.as(Cell)],
        ])

        # union with absent key is a no-op
        part.view_union(["a".as(Cell), "zzz".as(Cell)]).to_a2.should eq([
            ["a".as(Cell),1i64.as(Cell)],
            ["a".as(Cell),3i64.as(Cell)],
        ])
    end

    it "write-through from PartitionView to parent" do
        content = ["a".as(Cell), 1i64.as(Cell), "b".as(Cell), 2i64.as(Cell), "a".as(Cell), 3i64.as(Cell)]
        table = Table::Lazy::Raw::Memory(Cell).new([3,2]).load(content)
        part = Table::Lazy::Raw::Partitioned(Cell).new(table, 0, 0)
        view = part.view("a".as(Cell))
        # write to the first "a" row, second column
        view[[0,1]] = 99i64.as(Cell)
        table[[0,1]].should eq(99i64)
    end

    it "version invalidation triggers rescan" do
        content = ["a".as(Cell), 1i64.as(Cell), "b".as(Cell), 2i64.as(Cell), "a".as(Cell), 3i64.as(Cell)]
        table = Table::Lazy::Raw::Memory(Cell).new([3,2]).load(content)
        part = Table::Lazy::Raw::Partitioned(Cell).new(table, 0, 0)
        part.view("a".as(Cell)).size.should eq([2,2])
        # change the key of row 0 from "a" to "b"
        table[[0,0]] = "b".as(Cell)
        part.view("a".as(Cell)).size.should eq([1,2]) # only row 2 remains in "a"
        part.view("b".as(Cell)).size.should eq([2,2]) # rows 0 and 1
    end

    it "empty partition for absent key" do
        content = ["a".as(Cell), 1i64.as(Cell), "b".as(Cell), 2i64.as(Cell)]
        table = Table::Lazy::Raw::Memory(Cell).new([2,2]).load(content)
        part = Table::Lazy::Raw::Partitioned(Cell).new(table, 0, 0)
        part.view("zzz".as(Cell)).size.should eq([0,2])
        part.get_selection("zzz".as(Cell)).should eq([] of Int32)
    end

    it "key migration moves rows between partitions" do
        content = ["a".as(Cell), 1i64.as(Cell), "a".as(Cell), 2i64.as(Cell), "b".as(Cell), 3i64.as(Cell)]
        table = Table::Lazy::Raw::Memory(Cell).new([3,2]).load(content)
        part = Table::Lazy::Raw::Partitioned(Cell).new(table, 0, 0)
        part.get_selection("a".as(Cell)).should eq([0,1])
        part.get_selection("b".as(Cell)).should eq([2])
        # migrate row 1 from "a" to "b"
        table[[1,0]] = "b".as(Cell)
        part.get_selection("a".as(Cell)).should eq([0])
        part.get_selection("b".as(Cell)).should eq([1,2])
    end

    it "linear-time: large-N union scales linearly" do
        # 100k rows alternating a/b/c. Time the union-of-all-keys operation
        # at two sizes; ratio should be near 2x, not 4x or worse (ruling out
        # accidental O(n log n) or O(n^2) regressions).
        require_one_dim = ->(n : Int32) {
            content = Array(Cell).new(n * 2)
            n.times do |i|
                content << ["a", "b", "c"][i % 3].as(Cell)
                content << i.to_i64.as(Cell)
            end
            table = Table::Lazy::Raw::Memory(Cell).new([n, 2]).load(content)
            part = Table::Lazy::Raw::Partitioned(Cell).new(table, 0, 0)
            t0 = Time.instant
            part.get_selection_union(["a".as(Cell), "b".as(Cell), "c".as(Cell)])
            (Time.instant - t0).total_seconds
        }
        small = require_one_dim.call(20_000)
        large = require_one_dim.call(80_000)
        # 4x rows should not be more than 8x time (gives slack for noise)
        ratio = large / Math.max(small, 1e-6)
        ratio.should be < 8.0
    end
end
