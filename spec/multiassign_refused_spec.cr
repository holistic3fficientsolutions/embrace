require "spec"
require "./spec_helper"
require "../src/persistency"
require "../src/virtualtable"
require "../src/debug-helper"

include Persistency

# A multiassign the VirtualTable refuses stores nothing - and leaves the table showing what is stored. Its check pass
# patches each buffered row in place to try the assignments out; a refusal there must put every row back.

# The batch is what a pivot write opens through its parent (multiassign_begin / _end are protected: a pivot is
# the only caller). Exposed here, and only here, to drive one batch directly.
class Table::VirtualTable::VirtualTable(T, U)
    def batch(& : ->) : Index?
        multiassign_begin
        yield
        multiassign_end
    end
end

private def table : {Persistency::Default, Table::VirtualTable::VirtualTable(Cell, BaseCell)}
    p = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    TableReader(Persistency::Default, Persistency::Cell).new(p, hash) << "T\nA | B\na1 | b1\na2 | b2\n"
    c = Table::VirtualTable::Configurator(Cell, BaseCell).new(p, hash["T"].as(TableLID))
    c.toggle_select(c.tree)
    {p, c.run}
end

private def rows(vt) : Array(Array(Cell | BaseCell))
    (0...vt.size[0]).map { |r| (0...vt.size[1]).map { |c| vt[[r, c]] } }
end

describe "a multiassign the VirtualTable refuses" do
    it "leaves the row it tried out as stored" do
        p, vt = table
        rank = (0...vt.size[1]).find! { |c| vt.hyperplane_is_rank(1, [0, c]) }
        a = (0...vt.size[1]).find! { |c| vt[[0, c]] == "a1" }
        before, version = rows(vt), p.version
        expect_raises(ConditionsNotMet, /ranks can only be assigned to integer values/) do
            vt.batch { vt[[0, a]] = "PATCHED"; vt[[0, rank]] = "not a rank" }
        end
        p.version.should eq(version) # control: nothing was stored
        rows(vt).should eq(before)   # and nothing is shown that was not
    end

    it "leaves every row it tried out as stored, when a later row is refused" do
        p, vt = table
        rank = (0...vt.size[1]).find! { |c| vt.hyperplane_is_rank(1, [0, c]) }
        a = (0...vt.size[1]).find! { |c| vt[[0, c]] == "a1" }
        before = rows(vt)
        expect_raises(ConditionsNotMet) do
            vt.batch { vt[[0, a]] = "ONE"; vt[[1, a]] = "TWO"; vt[[1, rank]] = "not a rank" }
        end
        rows(vt).should eq(before)
    end
end
