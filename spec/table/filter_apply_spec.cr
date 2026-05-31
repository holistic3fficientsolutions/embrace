require "spec"
require "../../src/global"
require "../../src/table/raw"
require "../../src/table/filter"

include Table # for protected method access

# 5 rows × 3 cols. col 0 = region, col 1 = product, col 2 = amount.
private def make_filter_table : Table::Lazy::Raw::Memory(Cell)
    content = [
        "north".as(Cell), "widget".as(Cell), 10i64.as(Cell),
        "south".as(Cell), "widget".as(Cell), 20i64.as(Cell),
        "north".as(Cell), "gadget".as(Cell), 30i64.as(Cell),
        "south".as(Cell), "gadget".as(Cell), 40i64.as(Cell),
        "north".as(Cell), "widget".as(Cell), 50i64.as(Cell),
    ]
    Table::Lazy::Raw::Memory(Cell).new([5, 3]).load(content)
end

describe Table::Lazy::Filter do

    it "empty filter is pass-through" do
        table = make_filter_table
        filtered = Table::Lazy::Filter.apply(table, [] of Table::Lazy::Filter::ColumnFilter)
        # Identity: same object reference (no wrapping when no filters)
        filtered.should be(table.as(Table::Lazy::Raw::Base(Cell)))
        filtered.size.should eq([5, 3])
    end

    it "single-value filter: rows with one specific value" do
        table = make_filter_table
        cf = Table::Lazy::Filter::ColumnFilter.new(0, Set{"north".as(Cell)})
        filtered = Table::Lazy::Filter.apply(table, [cf])
        filtered.size.should eq([3, 3])
        filtered.to_a2.should eq([
            ["north".as(Cell), "widget".as(Cell), 10i64.as(Cell)],
            ["north".as(Cell), "gadget".as(Cell), 30i64.as(Cell)],
            ["north".as(Cell), "widget".as(Cell), 50i64.as(Cell)],
        ])
    end

    it "OR within column: multiple values selected" do
        table = make_filter_table
        cf = Table::Lazy::Filter::ColumnFilter.new(0, Set{"north".as(Cell), "south".as(Cell)})
        filtered = Table::Lazy::Filter.apply(table, [cf])
        # All rows match (OR over all distinct values)
        filtered.size.should eq([5, 3])
    end

    it "AND between columns: composes filters" do
        table = make_filter_table
        cf_region = Table::Lazy::Filter::ColumnFilter.new(0, Set{"north".as(Cell)})
        cf_product = Table::Lazy::Filter::ColumnFilter.new(1, Set{"widget".as(Cell)})
        filtered = Table::Lazy::Filter.apply(table, [cf_region, cf_product])
        filtered.size.should eq([2, 3])
        filtered.to_a2.should eq([
            ["north".as(Cell), "widget".as(Cell), 10i64.as(Cell)],
            ["north".as(Cell), "widget".as(Cell), 50i64.as(Cell)],
        ])
    end

    it "filter with empty selected_values means zero rows (user unchecked everything)" do
        table = make_filter_table
        cf = Table::Lazy::Filter::ColumnFilter.new(0, Set(Cell).new)
        filtered = Table::Lazy::Filter.apply(table, [cf])
        filtered.size.should eq([0, 3])
    end

    it "ColumnFilter equality" do
        a = Table::Lazy::Filter::ColumnFilter.new(0, Set{"x".as(Cell)})
        b = Table::Lazy::Filter::ColumnFilter.new(0, Set{"x".as(Cell)})
        c = Table::Lazy::Filter::ColumnFilter.new(0, Set{"y".as(Cell)})
        d = Table::Lazy::Filter::ColumnFilter.new(1, Set{"x".as(Cell)})
        a.should eq(b)
        a.should_not eq(c)
        a.should_not eq(d)
    end

    it "ColumnFilter dup is deep (independent set)" do
        a = Table::Lazy::Filter::ColumnFilter.new(0, Set{"x".as(Cell)})
        b = a.dup
        b.selected_values.add("y".as(Cell))
        a.selected_values.includes?("y".as(Cell)).should be_false
    end

    it "reactivity: filter reflects parent edits on next access" do
        table = make_filter_table
        cf = Table::Lazy::Filter::ColumnFilter.new(0, Set{"north".as(Cell)})
        filtered = Table::Lazy::Filter.apply(table, [cf])
        filtered.size.should eq([3, 3])
        # Change row 1 (was "south") to "north"
        table[[1, 0]] = "north".as(Cell)
        filtered = Table::Lazy::Filter.apply(table, [cf]) # rebuild on each call (no caching in MVP)
        filtered.size.should eq([4, 3])
    end
end
