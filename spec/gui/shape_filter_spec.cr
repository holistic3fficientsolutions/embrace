require "spec"
require "../../spec/spec_helper"
require "../../src/gui/shape"
require "../../src/debug-helper"
require "../../src/constants"

include Persistency

# Helper: persistency with one table containing region+product+amount over multiple rows.
# Schema: Sales[Region, Product, Amount] — duplicate values across rows so filtering
# has something to do. Returns {persistency, table_lid}.
private def make_sales_setup : {Persistency::Default, TableLID}
    persistency = Persistency::Default.new
    hash = Hash(String, FieldLID | TableLID | RecordLID).new
    help = TableReader(Persistency::Default, Persistency::Cell).new(persistency, hash)
    help << <<-EOT
        Sales
        Region | Product | Amount
        north | widget | 10
        south | widget | 20
        north | gadget | 30
        south | gadget | 40
        north | widget | 50
    EOT
    {persistency, hash["Sales"].as(TableLID)}
end

private def make_filter_shape : ShapeState
    persistency, table_lid = make_sales_setup
    context = persistency.context.clone
    ShapeState.new("Sales", persistency, context, table_lid)
end

describe "ShapeState filter" do
    it "starts with empty filter_state" do
        shape = make_filter_shape
        shape.filter_state.empty?.should be_true
    end

    it "filter_add appends a column filter" do
        shape = make_filter_shape
        shape.filter_add(0, Set{"north".as(Cell)})
        shape.filter_state.size.should eq(1)
        shape.filter_state[0].column_index.should eq(0)
        shape.filter_state[0].selected_values.should eq(Set{"north".as(Cell)})
    end

    it "filter_add is idempotent on column_index (no duplicate row)" do
        shape = make_filter_shape
        shape.filter_add(0, Set{"north".as(Cell)})
        shape.filter_add(0, Set{"south".as(Cell)})
        shape.filter_state.size.should eq(1)
        # First call wins; later filter_set_values is the way to update
        shape.filter_state[0].selected_values.should eq(Set{"north".as(Cell)})
    end

    it "filter_set_values replaces values for a column" do
        shape = make_filter_shape
        shape.filter_add(0, Set{"north".as(Cell)})
        shape.filter_set_values(0, Set{"south".as(Cell), "north".as(Cell)})
        shape.filter_state[0].selected_values.should eq(Set{"south".as(Cell), "north".as(Cell)})
    end

    it "filter_set_values is no-op for unknown column" do
        shape = make_filter_shape
        shape.filter_set_values(99, Set{"x".as(Cell)})
        shape.filter_state.empty?.should be_true
    end

    it "filter_remove drops a column filter" do
        shape = make_filter_shape
        shape.filter_add(0, Set{"north".as(Cell)})
        shape.filter_add(1, Set{"widget".as(Cell)})
        shape.filter_remove(0)
        shape.filter_state.size.should eq(1)
        shape.filter_state[0].column_index.should eq(1)
    end

    it "filter_clear! drops everything" do
        shape = make_filter_shape
        shape.filter_add(0, Set{"north".as(Cell)})
        shape.filter_add(1, Set{"widget".as(Cell)})
        shape.filter_clear!
        shape.filter_state.empty?.should be_true
    end

    it "exposes column_names from the underlying VirtualTable" do
        shape = make_filter_shape
        # 3 user columns + leading meta columns (RecordLID, Rank). Names should
        # include "Region", "Product", "Amount" somewhere in the list.
        names = shape.column_names
        names.should contain("Region")
        names.should contain("Product")
        names.should contain("Amount")
    end

    it "exposes column_distinct_values with counts" do
        shape = make_filter_shape
        region_idx = shape.column_names.index("Region").not_nil!
        values = shape.column_distinct_values(region_idx)
        # 3 north + 2 south rows
        h = values.to_h
        h["north".as(Cell)].should eq(3)
        h["south".as(Cell)].should eq(2)
    end

    it "applying a filter actually reduces the matrix row count" do
        shape = make_filter_shape
        adapter_before = shape.matrix_adapter.not_nil!
        rows_before = adapter_before.size[0]
        rows_before.should be > 0

        region_idx = shape.column_names.index("Region").not_nil!
        shape.filter_add(region_idx, Set{"north".as(Cell)})

        adapter_after = shape.matrix_adapter.not_nil!
        rows_after = adapter_after.size[0]
        rows_after.should be < rows_before
    end

    it "duplicating a shape deep-copies the filter state" do
        shape = make_filter_shape
        shape.filter_add(0, Set{"north".as(Cell)})
        shape.filter_add(1, Set{"widget".as(Cell)})

        clone = shape.dup_shape("Clone")
        clone.filter_state.size.should eq(2)
        clone.filter_state.should eq(shape.filter_state)

        # Mutate clone — original untouched
        clone.filter_set_values(0, Set{"south".as(Cell)})
        shape.filter_state[0].selected_values.should eq(Set{"north".as(Cell)})
        clone.filter_state[0].selected_values.should eq(Set{"south".as(Cell)})

        # Mutate original — clone untouched
        shape.filter_remove(1)
        shape.filter_state.size.should eq(1)
        clone.filter_state.size.should eq(2)
    end
end
